import Foundation

public enum SNIResult: Sendable, Equatable { case found(String), needMore, notHandshake, noSNI }

// reads the server_name extension out of a ClientHello. returns the name only; nothing else is kept.

public enum TLSClientHello {
    /// bytes start at a tls record header. fragments of consecutive handshake records are joined first
    public static func serverName(inRecords bytes: ArraySlice<UInt8>) -> SNIResult {
        let b = Array(bytes)
        var pos = 0
        var handshake: [UInt8] = []
        var first = true
        while pos < b.count {
            guard b.count - pos >= 5 else {
                if first { return b[0] == 22 ? .needMore : .notHandshake }
                break
            }
            guard b[pos] == 22, b[pos + 1] == 3 else {
                if first { return .notHandshake }
                break
            }
            first = false
            let length = Int(b[pos + 3]) << 8 | Int(b[pos + 4])
            let end = min(pos + 5 + length, b.count)
            handshake.append(contentsOf: b[(pos + 5)..<end])
            pos = end
        }
        if first { return .needMore }
        return serverName(inHandshake: handshake[...])
    }

    /// bytes start at a bare handshake message header (the quic crypto stream)
    public static func serverName(inHandshake bytes: ArraySlice<UInt8>) -> SNIResult {
        let h = Array(bytes)
        guard let type = h.first else { return .needMore }
        guard type == 1 else { return .notHandshake }
        guard h.count >= 4 else { return .needMore }
        let length = Int(h[1]) << 16 | Int(h[2]) << 8 | Int(h[3])
        guard h.count - 4 >= length else { return .needMore }

        var r = Reader(bytes: Array(h[4..<(4 + length)]))
        guard r.skip(2 + 32),
            let sidLen = r.u8(), r.skip(Int(sidLen)),
            let csLen = r.u16(), r.skip(Int(csLen)),
            let compLen = r.u8(), r.skip(Int(compLen)),
            let extLen = r.u16(), var ext = r.sub(Int(extLen))
        else { return .noSNI }

        while let extType = ext.u16(), let len = ext.u16(), var body = ext.sub(Int(len)) {
            guard extType == 0 else { continue }
            guard let listLen = body.u16(), var list = body.sub(Int(listLen)) else { return .noSNI }
            while let nameType = list.u8(), let nameLen = list.u16(), let name = list.take(Int(nameLen)) {
                guard nameType == 0 else { continue }
                return validated(name)
            }
            return .noSNI
        }
        // ech (0xFE0D) without a plain name lands here too
        return .noSNI
    }

    private static func validated(_ name: [UInt8]) -> SNIResult {
        guard !name.isEmpty, name.count <= 253,
            name.allSatisfy({ $0 > 0x20 && $0 < 0x7F })
        else { return .noSNI }
        return .found(String(decoding: name, as: UTF8.self).lowercased())
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skip(_ n: Int) -> Bool {
            guard n >= 0, bytes.count - pos >= n else { return false }
            pos += n
            return true
        }
        mutating func u8() -> UInt8? {
            guard pos < bytes.count else { return nil }
            defer { pos += 1 }
            return bytes[pos]
        }
        mutating func u16() -> UInt16? {
            guard bytes.count - pos >= 2 else { return nil }
            defer { pos += 2 }
            return UInt16(bytes[pos]) << 8 | UInt16(bytes[pos + 1])
        }
        mutating func take(_ n: Int) -> [UInt8]? {
            guard n >= 0, bytes.count - pos >= n else { return nil }
            defer { pos += n }
            return Array(bytes[pos..<(pos + n)])
        }
        mutating func sub(_ n: Int) -> Reader? {
            take(n).map { Reader(bytes: $0) }
        }
    }
}
