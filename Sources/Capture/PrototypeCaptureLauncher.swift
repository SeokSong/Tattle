import Foundation
import PCAPNG

// prototype stand-in for the privileged helper: one admin-password prompt per capture through osascript.
// the app never runs as root. the udid lives in the script file (0600, in a 0700 run directory) and in
// memory only; stop() deletes the directory. see md/APP.md.

private final class ExitFuture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    var status: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func fulfill(_ status: Int32) {
        lock.lock()
        value = status
        lock.unlock()
    }

    /// polls; a process exit is a rare event and the callers also poll other conditions
    func wait(timeout: TimeInterval) async -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while status == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return status
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

public actor PrototypeCaptureLauncher {
    /// how the privileged script is run: the executable and its arguments for a script path
    public typealias Runner = @Sendable (_ scriptPath: String) -> (executable: URL, arguments: [String])

    /// how long the admin password dialog may stay open
    public static let accessTimeout: TimeInterval = 60

    private let runRoot: URL
    private let tools: CaptureTools
    private let runner: Runner
    private let accessTimeout: TimeInterval

    private var directory: URL?
    private var process: Process?
    private var exit: ExitFuture?
    private var errorFile: URL?
    private var source: FileHandlePacketSource?
    private let logsDirectory: URL
    private var logURL: URL?

    /// where the last capture's script log was kept (never contains the udid), nil before the first stop
    public private(set) var lastLogURL: URL?
    /// tcpdump's "packets dropped by kernel" from the last capture's script log; nil when unknown (tcpdump
    /// was killed before it printed its summary) or before the first stop
    public private(set) var lastKernelDropped: Int?
    /// true when the last capture's script log has tcpdump's "interface disappeared" line (cable pull)
    public private(set) var lastLinkLost = false
    /// logs kept besides the newest
    static let logsToKeep = 10

    /// runRoot defaults to ~/Library/Application Support/Watch/run. runner and tools are for tests
    public init(
        runRoot: URL? = nil, tools: CaptureTools = .init(), accessTimeout: TimeInterval = PrototypeCaptureLauncher.accessTimeout,
        runner: Runner? = nil
    ) {
        self.runRoot = runRoot ?? Self.defaultRunRoot()
        self.logsDirectory = self.runRoot.deletingLastPathComponent().appendingPathComponent("logs", isDirectory: true)
        self.tools = tools
        self.accessTimeout = accessTimeout
        self.runner = runner ?? Self.osascriptRunner
    }

    public static func defaultRunRoot() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watch/run", isDirectory: true)
    }

    /// the run directory of the capture in progress, if any
    public var runDirectory: URL? { directory }

    // MARK: script

    /// the privileged script. absolute tool paths; stderr goes to log in the run directory
    public static func renderScript(udid: String, runDirectory: URL, tools: CaptureTools = .init()) -> String {
        let dir = shellQuote(runDirectory.path)
        let rvictl = shellQuote(tools.rvictl.path)
        let tcpdump = shellQuote(tools.tcpdump.path)
        let id = shellQuote(udid)
        // exit codes: 1 rvi failed, 2 tcpdump failed. the udid is only ever an argument, never echoed
        return """
            #!/bin/sh
            RUN=\(dir)
            RVICTL=\(rvictl)
            TCPDUMP=\(tcpdump)
            UDID=\(id)
            # nothing may inherit osascript's stdout pipe, or do shell script waits for it
            exec 1>/dev/null 2>>"$RUN/log"
            note() { echo "$(date '+%H:%M:%S') $1" >&2; }
            # tear rvi down on every exit path, including TERM and HUP
            trap '"$RVICTL" -x "$UDID" >/dev/null 2>&1; note "rvi down"' EXIT
            trap 'note "script got a signal"; exit 143' TERM HUP INT
            note "started"
            "$RVICTL" -x "$UDID" >/dev/null 2>&1 || true
            out=$("$RVICTL" -s "$UDID" 2>&1)
            case "$out" in
            *"[SUCCEEDED]"*) ;;
            *) note "rvictl did not report success"; exit 1 ;;
            esac
            iface=$(printf '%s\\n' "$out" | sed -n 's/.*with interface \\([A-Za-z0-9]*\\).*/\\1/p' | head -n 1)
            if [ -z "$iface" ]; then note "no interface name in rvictl output"; exit 1; fi
            note "rvi up $iface"
            # the privilege helper starts this script with INT and TERM ignored, and a shell cannot
            # un-ignore inherited signals, so tcpdump would only die from KILL. perl resets them
            # to their defaults before exec. job control also gives tcpdump its own process group
            set -m
            /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; $SIG{TERM} = "DEFAULT"; exec @ARGV or exit 127' \
              "$TCPDUMP" -i "$iface" -n -p -s 0 -U -P -w - > "$RUN/stream" 2>>"$RUN/log" </dev/null &
            pid=$!
            set +m
            note "tcpdump pid $pid started"
            why="loop ended"
            while :; do
              if [ -e "$RUN/stop" ]; then why="stop seen"; break; fi
              if [ ! -d "$RUN" ]; then why="dir gone"; break; fi
              if ! kill -0 $pid 2>/dev/null; then why="tcpdump exited"; break; fi
              sleep 0.2
            done
            note "$why"
            if kill -0 $pid 2>/dev/null; then
              kill -INT $pid 2>/dev/null; note "INT sent"
              # tcpdump acts on INT only once its read on rvi returns, which may never happen on a quiet
              # phone. packets are flushed as they arrive (-U), so escalating quickly loses nothing
              n=0; while kill -0 $pid 2>/dev/null && [ $n -lt 5 ]; do sleep 0.2; n=$((n+1)); done
              if kill -0 $pid 2>/dev/null; then
                kill -TERM $pid 2>/dev/null; note "TERM sent"
                n=0; while kill -0 $pid 2>/dev/null && [ $n -lt 3 ]; do sleep 0.2; n=$((n+1)); done
                if kill -0 $pid 2>/dev/null; then kill -KILL $pid 2>/dev/null; note "KILL sent"; fi
              fi
            fi
            wait $pid
            status=$?
            note "tcpdump status $status"
            # a signal exit (128+n) after we asked it to stop is the normal way a capture ends
            if [ "$why" = "tcpdump exited" ] && [ $status -ne 0 ]; then exit 2; fi
            exit 0

            """
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let osascriptRunner: Runner = { path in
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/sh \" & quoted form of \"\(escaped)\" with administrator privileges"
        return (URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", source])
    }

    // MARK: start

    /// shows the admin password dialog, runs the script and returns the stream once tcpdump is writing.
    /// on any failure everything is stopped and the run directory removed
    public func start(udid: String, tee: FileHandle? = nil) async throws -> FileHandlePacketSource {
        guard directory == nil else { throw CaptureError.alreadyRunning }
        lastKernelDropped = nil
        lastLinkLost = false
        do {
            return try await startInner(udid: udid, tee: tee)
        } catch {
            await stop()
            throw error
        }
    }

    private func startInner(udid: String, tee: FileHandle?) async throws -> FileHandlePacketSource {
        let fm = FileManager.default
        let dir = runRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        directory = dir
        do {
            try fm.createDirectory(at: runRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            // umask can narrow but never widen; set explicitly in case it widened nothing
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        } catch {
            throw CaptureError.runDirectoryFailed("\(error.localizedDescription)")
        }
        let scriptURL = dir.appendingPathComponent("script.sh")
        let streamURL = dir.appendingPathComponent("stream")
        let script = Self.renderScript(udid: udid, runDirectory: dir, tools: tools)
        guard fm.createFile(atPath: scriptURL.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.runDirectoryFailed("cannot write the script")
        }
        // created here so it stays owned by the user even though the root script appends to it
        let logFile = dir.appendingPathComponent("log")
        guard fm.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CaptureError.runDirectoryFailed("cannot create the log")
        }
        logURL = logFile
        guard mkfifo(streamURL.path, 0o600) == 0 else {
            throw CaptureError.runDirectoryFailed("cannot create the stream pipe")
        }

        // osascript's own output goes to a file, never a pipe a lingering child could hold open
        let errURL = dir.appendingPathComponent("osascript.err")
        guard fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            throw CaptureError.runDirectoryFailed("cannot create the output file")
        }
        errorFile = errURL
        defer { try? errHandle.close() }

        let (executable, arguments) = runner(scriptURL.path)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = errHandle
        process.standardError = errHandle
        let exit = ExitFuture()
        process.terminationHandler = { finished in exit.fulfill(finished.terminationStatus) }
        do { try process.run() } catch {
            throw CaptureError.tcpdumpLaunchFailed("could not run the privileged launcher")
        }
        self.process = process
        self.exit = exit

        // opening a FIFO for reading blocks until the writer opens it: do it on its own thread
        let opened = Flag()
        let path = streamURL.path
        let openTask = Task<Int32, Never> {
            await withCheckedContinuation { continuation in
                let thread = Thread {
                    let fd = open(path, O_RDONLY)
                    opened.set()
                    continuation.resume(returning: fd)
                }
                thread.start()
            }
        }
        let deadline = Date().addingTimeInterval(accessTimeout)
        var timedOut = false
        var scriptEnded = false
        while !opened.isSet {
            if exit.status != nil { scriptEnded = true }
            if Date() >= deadline { timedOut = true }
            if scriptEnded || timedOut {
                // opening the write end releases the blocked reader
                let writer = open(path, O_WRONLY | O_NONBLOCK)
                if writer >= 0 { close(writer) }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let fd = await openTask.value
        guard fd >= 0 else { throw CaptureError.runDirectoryFailed("cannot open the stream pipe") }
        if scriptEnded || timedOut {
            close(fd)
            if timedOut {
                // closes the password dialog
                if process.isRunning { process.terminate() }
                throw CaptureError.accessTimedOut
            }
            throw await failure(status: exit.status ?? 1)
        }
        let source = FileHandlePacketSource(
            handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), tee: tee, tolerateTruncation: true)
        self.source = source
        return source
    }

    /// maps the launcher's end state to an error. the log holds tool stderr, which never has the udid
    private func failure(status: Int32) async -> CaptureError {
        let err = errorFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if err.contains("User canceled") || err.contains("(-128)") { return .accessDenied }
        let log = directory.flatMap { try? String(contentsOf: $0.appendingPathComponent("log"), encoding: .utf8) } ?? ""
        let detail = log.trimmingCharacters(in: .whitespacesAndNewlines)
        // osascript reports the script's exit code as "(N)" at the end of its message
        if err.range(of: #"\(2\)\s*$"#, options: .regularExpression) != nil {
            return .tcpdumpExited(2)
        }
        return .rviStartFailed(detail.isEmpty ? "the capture script exited with status \(status)" : detail)
    }

    // MARK: stop

    /// asks the script to stop, waits for it, keeps its log and deletes the run directory. never hangs,
    /// safe at any point and any number of times.
    /// the script runs as root, so the app cannot signal tcpdump itself. what it can do: create the stop
    /// file, then (after 10 s) terminate osascript, and always close the reading end of the stream, so a
    /// tcpdump that survives dies of SIGPIPE on its next write
    public func stop() async {
        if let directory {
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent("stop").path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var scriptEnded = true
        if let exit {
            if await exit.wait(timeout: 15) == nil {
                scriptEnded = false
                if let process, process.isRunning { process.terminate() }
            }
        }
        if let source {
            // tcpdump is gone when the script ended, so the stream reaches EOF by itself; give it a moment
            if scriptEnded {
                let deadline = Date().addingTimeInterval(1)
                while !source.isFinished, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            source.close()
            let deadline = Date().addingTimeInterval(1)
            while !source.isFinished, Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        if let lines = logLines() {
            lastKernelDropped = CaptureController.droppedByKernel(in: lines)
            lastLinkLost = CaptureController.interfaceDisappeared(in: lines)
        }
        keepLog()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        process = nil
        exit = nil
        errorFile = nil
        source = nil
        logURL = nil
    }

    private func logLines() -> [String]? {
        guard let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) else { return nil }
        return text.components(separatedBy: "\n")
    }

    /// the drop count in the log right now, for a pipeline that stops before `stop()` runs here
    public func kernelDroppedNow() -> Int? { logLines().flatMap { CaptureController.droppedByKernel(in: $0) } }

    // MARK: stale run directories

    /// every file the launcher puts in a run directory. a directory holding anything else is not ours
    static let runDirectoryFiles: Set<String> = ["script.sh", "stream", "log", "osascript.err", "stop"]

    /// what a stale cleanup did, by directory name (a uuid; never a path, never file contents)
    public struct StaleRunResult: Sendable, Equatable {
        /// given the stop file
        public var stopped: [String] = []
        public var removed: [String] = []
        /// could not be removed (for example root-owned files); left in place
        public var failed: [String] = []
        public init() {}
    }

    /// the same cleanup for this launcher's run root, never touching the capture in progress
    public func cleanStaleRunDirectories(grace: TimeInterval = 10) async -> StaleRunResult {
        await Self.cleanStaleRunDirectories(runRoot: runRoot, ownDirectory: directory, grace: grace)
    }

    /// a crashed app can leave a run directory with a root tcpdump still writing to it. the script exits
    /// when its directory gets a `stop` file or disappears, and the app cannot signal root, so: create the
    /// stop file in each stale directory, wait `grace`, then remove the files and the directory.
    /// only directories Watch made are touched: a real directory (never a symlink) directly under the run
    /// root, named exactly like `UUID().uuidString`, owned by this user, holding only the launcher's own
    /// files. nothing is followed, nothing is removed recursively, the logs directory is never looked at,
    /// and no root is needed. a directory that cannot be cleared goes to `failed`
    public static func cleanStaleRunDirectories(
        runRoot: URL, ownDirectory: URL? = nil, grace: TimeInterval = 10
    ) async -> StaleRunResult {
        var result = StaleRunResult()
        var rootInfo = stat()
        guard lstat(runRoot.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { return result }
        let own = ownDirectory?.lastPathComponent
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: runRoot.path)) ?? []).sorted()
        let candidates = names.filter { $0 != own && staleCandidate(runRoot.appendingPathComponent($0, isDirectory: true)) }

        for name in candidates {
            let stop = runRoot.appendingPathComponent(name).appendingPathComponent("stop").path
            // no-follow, never overwrites: a leftover file or link named stop stays as it is
            let fd = open(stop, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd >= 0 { close(fd) }
            if fd >= 0 || errno == EEXIST { result.stopped.append(name) }
        }
        if !result.stopped.isEmpty, grace > 0 { try? await Task.sleep(nanoseconds: UInt64(grace * 1e9)) }

        for name in candidates {
            let dir = runRoot.appendingPathComponent(name, isDirectory: true)
            // checked again: the directory may have changed during the wait
            guard staleCandidate(dir) else { continue }
            var failed = false
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                // unlink removes a link itself, never what it points to
                if unlink(dir.appendingPathComponent(entry).path) != 0 && errno != ENOENT { failed = true }
            }
            if !failed && rmdir(dir.path) == 0 { result.removed.append(name) } else { result.failed.append(name) }
        }
        return result
    }

    private static func staleCandidate(_ dir: URL) -> Bool {
        let name = dir.lastPathComponent
        guard UUID(uuidString: name)?.uuidString == name else { return false }
        var info = stat()
        guard lstat(dir.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return false }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        return Set(entries).isSubset(of: runDirectoryFiles)
    }

    /// moves the script log (plus osascript's own output) to the logs directory, newest 10 kept
    private func keepLog() {
        guard let logURL, FileManager.default.fileExists(atPath: logURL.path) else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
            let target = logsDirectory.appendingPathComponent("capture-\(formatter.string(from: Date())).log")
            if let errorFile, let text = try? String(contentsOf: errorFile, encoding: .utf8), !text.isEmpty,
               let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(("--- osascript ---\n" + text).utf8))
                try? handle.close()
            }
            try fm.moveItem(at: logURL, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            lastLogURL = target
            let old = (try fm.contentsOfDirectory(atPath: logsDirectory.path))
                .filter { $0.hasPrefix("capture-") && $0.hasSuffix(".log") }.sorted()
            for name in old.dropLast(Self.logsToKeep) {
                try? fm.removeItem(at: logsDirectory.appendingPathComponent(name))
            }
        } catch {
            // a missing log must never block stopping
        }
    }
}
