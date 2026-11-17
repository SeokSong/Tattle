import CommonCrypto
import CryptoKit
import Foundation

// reads the ClientHello out of a quic client Initial packet (RFC 9001 section 5, RFC 9369 for v2).
// initial keys derive from the destination connection id, so anyone on the path can read them.

public enum QUICInitial {
    struct Keys {
        let key: SymmetricKey
        let iv: [UInt8]
        let hp: [UInt8]
    }

    static let saltV1: [UInt8] = [
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3, 0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
        0xcc, 0xbb, 0x7f, 0x0a,
    ]
    static let saltV2: [UInt8] = [
        0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb, 0x81, 0x93, 0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb,
        0xf9, 0xbd, 0x2e, 0xd9,
    ]

    /// one datagram. the server name once the crypto stream holds a whole ClientHello
    public static func serverName(inDatagram datagram: ArraySlice<UInt8>) -> SNIResult {
        serverName(inDatagrams: [datagram])
    }

    /// datagrams in arrival order, all from the same client. crypto frames are reassembled by offset across them
    public static func serverName(inDatagrams datagrams: [ArraySlice<UInt8>]) -> SNIResult {
        var pieces: [Int: [UInt8]] = [:]
        var decrypted = false
        for datagram in datagrams {
            guard let frames = cryptoFrames(inDatagram: Array(datagram)) else { continue }
            decrypted = true
            for (offset, data) in frames where (pieces[offset]?.count ?? 0) < data.count {
                pieces[offset] = data
            }
        }
        guard decrypted else { return .notHandshake }

        var stream: [UInt8] = []
        for offset in pieces.keys.sorted() {
            guard offset <= stream.count else { break }
            let data = pieces[offset]!
            if offset + data.count > stream.count {
                stream.append(contentsOf: data[(stream.count - offset)...])
            }
        }
        return TLSClientHello.serverName(inHandshake: stream[...])
    }

    // MARK: keys

    static func deriveKeys(dcid: [UInt8], version: UInt32) -> Keys {
        let v2 = version == 0x6b33_43cf
        // hkdf-extract is a single hmac; cryptokit only exposes it through the full hkdf
        let prk = HMAC<SHA256>.authenticationCode(
            for: dcid, using: SymmetricKey(data: v2 ? saltV2 : saltV1))
        let secret = SymmetricKey(data: expandLabel(SymmetricKey(data: prk), "client in", 32))
        return Keys(
            key: SymmetricKey(data: expandLabel(secret, v2 ? "quicv2 key" : "quic key", 16)),
            iv: expandLabel(secret, v2 ? "quicv2 iv" : "quic iv", 12),
            hp: expandLabel(secret, v2 ? "quicv2 hp" : "quic hp", 16))
    }

    private static func expandLabel(_ secret: SymmetricKey, _ label: String, _ length: Int) -> [UInt8] {
        let full = Array("tls13 \(label)".utf8)
        var info: [UInt8] = [UInt8(length >> 8), UInt8(length & 0xFF), UInt8(full.count)]
        info += full
        info.append(0)
        let out = HKDF<SHA256>.expand(pseudoRandomKey: secret, info: info, outputByteCount: length)
        return out.withUnsafeBytes { Array($0) }
    }

    /// header protection mask: one AES-128-ECB block over the sample
    static func headerMask(hp: [UInt8], sample: [UInt8]) -> [UInt8]? {
        guard hp.count == 16, sample.count == 16 else { return nil }
        var out = [UInt8](repeating: 0, count: 16 + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
            hp, 16, nil, sample, 16, &out, out.count, &moved)
        guard status == kCCSuccess, moved >= 16 else { return nil }
        return Array(out[0..<16])
    }

    // MARK: packet

    /// decrypts the first Initial packet of the datagram and returns its crypto frames as (offset, data).
    /// nil when it is not a client Initial or does not decrypt
    static func cryptoFrames(inDatagram d: [UInt8]) -> [(Int, [UInt8])]? {
        guard d.count >= 7, d[0] & 0xC0 == 0xC0 else { return nil }
        let version = u32(d, 1)
        let typeBits = (d[0] >> 4) & 0x03
        switch version {
        case 1 where typeBits == 0: break
        case 0x6b33_43cf where typeBits == 1: break
        default: return nil
        }
        var pos = 5
        let dcidLen = Int(d[pos])
        pos += 1
        guard dcidLen <= 20, pos + dcidLen < d.count else { return nil }
        let dcid = Array(d[pos..<(pos + dcidLen)])
        pos += dcidLen
        let scidLen = Int(d[pos])
        pos += 1
        guard pos + scidLen <= d.count else { return nil }
        pos += scidLen
        guard let (tokenLen, a) = varint(d, pos), a + Int(tokenLen) <= d.count else { return nil }
        pos = a + Int(tokenLen)
        guard let (length, b) = varint(d, pos) else { return nil }
        let pnOffset = b
        let packetEnd = pnOffset + Int(length)
        guard length >= 20, packetEnd <= d.count, pnOffset + 4 + 16 <= packetEnd else { return nil }

        let keys = deriveKeys(dcid: dcid, version: version)
        guard let mask = headerMask(hp: keys.hp, sample: Array(d[(pnOffset + 4)..<(pnOffset + 20)])) else { return nil }
        let first = d[0] ^ (mask[0] & 0x0F)
        let pnLen = Int(first & 0x03) + 1
        guard pnOffset + pnLen + 16 <= packetEnd else { return nil }
        var header = Array(d[0..<(pnOffset + pnLen)])
        header[0] = first
        var pn: UInt64 = 0
        for i in 0..<pnLen {
            header[pnOffset + i] ^= mask[1 + i]
            pn = pn << 8 | UInt64(header[pnOffset + i])
        }
        var nonce = keys.iv
        for i in 0..<8 { nonce[11 - i] ^= UInt8((pn >> UInt64(8 * i)) & 0xFF) }

        let body = pnOffset + pnLen
        let ciphertext = Array(d[body..<(packetEnd - 16)])
        let tag = Array(d[(packetEnd - 16)..<packetEnd])
        guard let n = try? AES.GCM.Nonce(data: nonce),
            let box = try? AES.GCM.SealedBox(nonce: n, ciphertext: ciphertext, tag: tag),
            let plain = try? AES.GCM.open(box, using: keys.key, authenticating: header)
        else { return nil }
        return frames(Array(plain))
    }

    private static func frames(_ p: [UInt8]) -> [(Int, [UInt8])] {
        var out: [(Int, [UInt8])] = []
        var pos = 0
        while pos < p.count {
            guard let (type, next) = varint(p, pos) else { break }
            pos = next
            switch type {
            case 0, 1:
                continue
            case 2, 3:
                // largest, delay, range count, first range, then (gap, length) pairs, ecb counts for type 3
                guard let (_, a) = varint(p, pos), let (_, b) = varint(p, a),
                    let (count, c) = varint(p, b), let (_, d) = varint(p, c)
                else { return out }
                pos = d
                guard count <= UInt64(p.count) else { return out }
                for _ in 0..<count {
                    guard let (_, g) = varint(p, pos), let (_, l) = varint(p, g) else { return out }
                    pos = l
                }
                if type == 3 {
                    for _ in 0..<3 {
                        guard let (_, e) = varint(p, pos) else { return out }
                        pos = e
                    }
                }
            case 6:
                guard let (offset, a) = varint(p, pos), let (len, b) = varint(p, a),
                    len <= UInt64(p.count - b), offset < 1 << 24
                else { return out }
                out.append((Int(offset), Array(p[b..<(b + Int(len))])))
                pos = b + Int(len)
            default:
                return out
            }
        }
        return out
    }

    private static func u32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) << 24 | UInt32(d[i + 1]) << 16 | UInt32(d[i + 2]) << 8 | UInt32(d[i + 3])
    }

    static func varint(_ d: [UInt8], _ i: Int) -> (UInt64, Int)? {
        guard i < d.count else { return nil }
        let n = 1 << Int(d[i] >> 6)
        guard i + n <= d.count else { return nil }
        var v = UInt64(d[i] & 0x3F)
        for k in 1..<n { v = v << 8 | UInt64(d[i + k]) }
        return (v, i + n)
    }
}
