import Foundation

// lists devices through `xcrun devicectl list devices`. the udid is never printed: views and logs show the name only.

public struct DeviceSummary: Sendable, Equatable, CustomStringConvertible {
    public var name: String
    public var udid: String
    public var transport: String
    public var pairing: String
    public var tunnel: String

    public init(name: String, udid: String, transport: String, pairing: String, tunnel: String) {
        self.name = name
        self.udid = udid
        self.transport = transport
        self.pairing = pairing
        self.tunnel = tunnel
    }

    /// the name only, so interpolating a summary cannot leak the udid
    public var description: String { name }
}

public enum DeviceLookupError: Error, Sendable, CustomStringConvertible, LocalizedError {
    case failed(String)

    public var description: String {
        switch self {
        case .failed(let reason): return reason
        }
    }

    public var errorDescription: String? { description }
}

public enum DeviceSelection: Sendable, Equatable {
    case chosen(DeviceSummary)
    /// no device matched; lists the names of the devices that were available
    case notFound(available: [String])
    /// more than one device matched (or none was named and there are several); lists their names
    case ambiguous([String])
}

public struct DeviceLookup {
    /// picks a device by name. a name matches case-insensitively and ignoring apostrophe style
    /// (straight, curly, modifier); an exact match wins, otherwise a unique substring match.
    /// no name: the only device, or ambiguous when there are several
    public static func select(name: String?, from devices: [DeviceSummary]) -> DeviceSelection {
        let names = devices.map(\.name)
        guard let name else {
            if devices.isEmpty { return .notFound(available: []) }
            return devices.count == 1 ? .chosen(devices[0]) : .ambiguous(names)
        }
        let wanted = normalizedName(name)
        let exact = devices.filter { normalizedName($0.name) == wanted }
        if exact.count == 1 { return .chosen(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.map(\.name)) }
        guard !wanted.isEmpty else { return .notFound(available: names) }
        let partial = devices.filter { normalizedName($0.name).contains(wanted) }
        if partial.count == 1 { return .chosen(partial[0]) }
        if partial.count > 1 { return .ambiguous(partial.map(\.name)) }
        return .notFound(available: names)
    }

    private static func normalizedName(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces).lowercased()
        for variant in ["\u{2019}", "\u{2018}", "\u{02BC}", "\u{0060}", "\u{00B4}"] {
            result = result.replacingOccurrences(of: variant, with: "'")
        }
        return result
    }

    /// every device devicectl lists as wired. runs devicectl off the calling thread
    public static func wiredDevices() async throws -> [DeviceSummary] {
        let data = try await runDevicectl()
        return try wiredDevices(from: data)
    }

    /// decodes devicectl's JSON leniently; on a shape mismatch the error names the keys found
    public static func wiredDevices(from data: Data) throws -> [DeviceSummary] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DeviceLookupError.failed("devicectl output is not a JSON object")
        }
        guard let result = root["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]] else {
            let top = root.keys.sorted().joined(separator: ", ")
            let inner = ((root["result"] as? [String: Any])?.keys.sorted().joined(separator: ", ")) ?? "none"
            throw DeviceLookupError.failed("unexpected devicectl JSON: top-level keys [\(top)], result keys [\(inner)]")
        }

        var wired: [DeviceSummary] = []
        var sawKeys = Set<String>()
        for device in devices {
            let connection = device["connectionProperties"] as? [String: Any]
            let hardware = device["hardwareProperties"] as? [String: Any]
            let properties = device["deviceProperties"] as? [String: Any]
            sawKeys.formUnion(device.keys)
            guard connection?["transportType"] as? String == "wired" else { continue }
            guard let udid = hardware?["udid"] as? String, !udid.isEmpty else {
                let keys = (hardware?.keys.sorted() ?? []).joined(separator: ", ")
                throw DeviceLookupError.failed("wired device has no hardwareProperties.udid (hardwareProperties keys: [\(keys)])")
            }
            wired.append(DeviceSummary(
                name: properties?["name"] as? String ?? "wired device",
                udid: udid,
                transport: "wired",
                pairing: connection?["pairingState"] as? String ?? "unknown",
                tunnel: connection?["tunnelState"] as? String ?? "unknown"))
        }
        if wired.isEmpty && !devices.isEmpty {
            throw DeviceLookupError.failed(
                "no wired device among \(devices.count) listed (device keys: [\(sawKeys.sorted().joined(separator: ", "))])")
        }
        return wired
    }

    private static func runDevicectl() async throws -> Data {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "list", "devices", "--json-output", outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: DeviceLookupError.failed("could not run devicectl"))
            }
        }
        guard status == 0 else {
            throw DeviceLookupError.failed("devicectl list devices failed (status \(status))")
        }
        guard let data = try? Data(contentsOf: outputURL) else {
            throw DeviceLookupError.failed("devicectl wrote no output")
        }
        return data
    }
}
