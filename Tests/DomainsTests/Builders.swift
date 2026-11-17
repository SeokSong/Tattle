import CryptoKit
import Foundation
@testable import Domains

// byte builders shared by the domains tests

func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(v >> UInt32(24 - 8 * $0) & 0xFF) } }

// MARK: dns

func dnsName(_ name: String) -> [UInt8] {
    name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
}

struct DNSRecord {
    var type: Int
    var ttl: UInt32
    var rdata: [UInt8]
    /// name bytes for the owner; default is a pointer to the question at offset 12
    var owner: [UInt8] = [0xC0, 12]
}

func dnsResponse(question: String, records: [DNSRecord], flags: Int = 0x8180, qdcount: Int = 1) -> [UInt8] {
    var m: [UInt8] = be16(0x1234) + be16(flags) + be16(qdcount) + be16(records.count) + be16(0) + be16(0)
    m += dnsName(question) + be16(1) + be16(1)
    for r in records {
        m += r.owner + be16(r.type) + be16(1) + be32(r.ttl) + be16(r.rdata.count) + r.rdata
    }
    return m
}

// MARK: tls

func clientHello(sni: String?, extraExtensions: [(Int, [UInt8])] = [], sessionID: Int = 32) -> [UInt8] {
    var exts: [UInt8] = []
    if let sni {
        let name = Array(sni.utf8)
        let list = [0] + be16(name.count) + name
        exts += be16(0) + be16(list.count + 2) + be16(list.count) + list
    }
    // supported_versions, to look like a real hello
    exts += be16(43) + be16(3) + [2, 3, 4]
    for (type, body) in extraExtensions { exts += be16(type) + be16(body.count) + body }
    var body: [UInt8] = [3, 3] + [UInt8](repeating: 7, count: 32)
    body += [UInt8(sessionID)] + [UInt8](repeating: 9, count: sessionID)
    body += be16(4) + [0x13, 0x01, 0x13, 0x02] + [1, 0]
    body += be16(exts.count) + exts
    return [1, UInt8(body.count >> 16), UInt8(body.count >> 8 & 0xFF), UInt8(body.count & 0xFF)] + body
}

func tlsRecord(_ fragment: [UInt8], type: UInt8 = 22) -> [UInt8] {
    [type, 3, 1] + be16(fragment.count) + fragment
}

// MARK: quic

func quicVarint2(_ v: Int) -> [UInt8] { [UInt8(0x40 | (v >> 8)), UInt8(v & 0xFF)] }

func cryptoFrame(offset: Int, _ data: [UInt8]) -> [UInt8] {
    [0x06] + quicVarint2(offset) + quicVarint2(data.count) + data
}

/// builds a protected client initial. mirrors RFC 9001 section 5 using the library's key derivation
func quicInitial(
    dcid: [UInt8], version: UInt32 = 1, pn: UInt16 = 0, frames: [UInt8], padTo: Int = 1200
) -> [UInt8] {
    let keys = QUICInitial.deriveKeys(dcid: dcid, version: version)
    let type: UInt8 = version == 1 ? 0 : 1
    let pnLen = 2
    var payload = frames
    var header: [UInt8] = [0xC0 | type << 4 | UInt8(pnLen - 1)] + be32(version)
    header += [UInt8(dcid.count)] + dcid + [0, 0]
    let overhead = header.count + 2 + pnLen + 16
    if payload.count + overhead < padTo { payload += [UInt8](repeating: 0, count: padTo - overhead - payload.count) }
    header += quicVarint2(pnLen + payload.count + 16)
    let pnOffset = header.count
    header += be16(Int(pn))

    var nonce = keys.iv
    nonce[10] ^= UInt8(pn >> 8)
    nonce[11] ^= UInt8(pn & 0xFF)
    let box = try! AES.GCM.seal(payload, using: keys.key, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
    var packet = header + Array(box.ciphertext) + Array(box.tag)

    let mask = QUICInitial.headerMask(hp: keys.hp, sample: Array(packet[(pnOffset + 4)..<(pnOffset + 20)]))!
    packet[0] ^= mask[0] & 0x0F
    for i in 0..<pnLen { packet[pnOffset + i] ^= mask[1 + i] }
    return packet
}

func hex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
        let j = s.index(i, offsetBy: 2)
        out.append(UInt8(s[i..<j], radix: 16)!)
        i = j
    }
    return out
}
