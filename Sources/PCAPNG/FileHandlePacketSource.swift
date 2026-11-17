import Foundation

/// reads a file descriptor (a FIFO, a pipe or a file) through PCAPNGStreamParser in 64 KB chunks.
/// events() may be called once; the handle is closed when the stream ends.
public final class FileHandlePacketSource: PacketSource, @unchecked Sendable {
    public static let chunkSize = 64 * 1024

    private let handle: FileHandle
    private let tee: FileHandle?
    private let tolerateTruncation: Bool
    private let lock = NSLock()
    private var streamEnd: PCAPNGEnd?
    private var finished = false
    private let cancelFlag = CancelFlag()

    /// tee receives every raw byte read (diagnostic capture) and is closed at the end.
    /// tolerateTruncation: a last block cut short by the writer being stopped ends the stream cleanly
    /// instead of throwing
    public init(handle: FileHandle, tee: FileHandle? = nil, tolerateTruncation: Bool = false) {
        self.handle = handle
        self.tee = tee
        self.tolerateTruncation = tolerateTruncation
    }

    /// how the stream ended, set when the parser finishes
    public var end: PCAPNGEnd? {
        lock.lock()
        defer { lock.unlock() }
        return streamEnd
    }

    /// true once the stream has ended (EOF, error or close())
    public var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// stops reading: a blocked read wakes within about 100 ms, the stream ends with .cleanEnd and the
    /// handle is closed. safe to call at any time and more than once
    public func close() { cancelFlag.set() }

    public func events() -> AsyncThrowingStream<PCAPNGEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancelled = self.cancelFlag
            continuation.onTermination = { _ in cancelled.set() }
            // blocking reads stay off the cooperative pool
            // a dedicated thread, so blocked readers never take workers from the shared pool
            let thread = Thread { self.pump(continuation, cancelled) }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    private func pump(_ continuation: AsyncThrowingStream<PCAPNGEvent, Error>.Continuation, _ cancelled: CancelFlag) {
        defer {
            try? tee?.close()
            try? handle.close()
            lock.lock()
            finished = true
            lock.unlock()
        }
        let fd = handle.fileDescriptor
        var parser = PCAPNGStreamParser()
        var buffer = [UInt8](repeating: 0, count: Self.chunkSize)

        do {
            while !cancelled.isSet {
                // wake regularly so close() works while the writer is silent
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if n == 0 { break }
                if let tee { try? tee.write(contentsOf: buffer[0..<n]) }
                for event in try parser.append(buffer[0..<n]) { continuation.yield(event) }
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }

        if cancelled.isSet {
            setEnd(.cleanEnd)
            continuation.yield(.end(.cleanEnd))
            continuation.finish()
            return
        }
        do {
            let end = try parser.finish()
            setEnd(end)
            continuation.yield(.end(end))
        } catch {
            if tolerateTruncation {
                setEnd(.cleanEnd)
                continuation.yield(.end(.cleanEnd))
            } else {
                continuation.finish(throwing: error)
                return
            }
        }
        continuation.finish()
    }

    private func setEnd(_ value: PCAPNGEnd) {
        lock.lock()
        streamEnd = value
        lock.unlock()
    }
}

private final class CancelFlag: @unchecked Sendable {
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
