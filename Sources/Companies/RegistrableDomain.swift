import Foundation

/// the registrable domain (public suffix plus one label) of a hostname, or nil when there is none.
/// lowercases, strips one trailing dot, and returns nil for ip literals, single labels, empty
/// labels, over-long names and names that are themselves a public suffix. punycode (xn--)
/// labels are matched by their unicode form and returned as given.
public func registrableDomain(of hostname: String) -> String? {
    registrableDomain(of: hostname, in: .bundled)
}

func registrableDomain(of hostname: String, in list: PublicSuffixList) -> String? {
    var name = hostname.lowercased()
    if name.hasSuffix(".") { name.removeLast() }
    guard !name.isEmpty, name.utf8.count <= 253, !isIPLiteral(name) else { return nil }

    let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return nil }

    let unicode = labels.map(Punycode.decodeLabel)
    let suffix = list.suffixLength(of: unicode)
    guard labels.count > suffix else { return nil }
    return labels.suffix(suffix + 1).joined(separator: ".")
}

private func isIPLiteral(_ name: String) -> Bool {
    // ipv6 (possibly bracketed, possibly with a zone)
    if name.contains(":") || name.hasPrefix("[") { return true }
    // ipv4 and its shorthands: dotted labels that are all digits (a tld is never numeric)
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    return !labels.isEmpty && labels.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }
}

// rfc 3492 decoder, only what matching needs. anything malformed is returned unchanged
enum Punycode {
    static func decodeLabel(_ label: String) -> String {
        guard label.hasPrefix("xn--") else { return label }
        return decode(String(label.dropFirst(4))) ?? label
    }

    static func decode(_ input: String) -> String? {
        let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
        var n = 128, i = 0, bias = 72
        var output: [UInt32] = []
        var digits = Array(input.unicodeScalars)
        if let delimiter = digits.lastIndex(of: "-") {
            output = digits[..<delimiter].map(\.value)
            guard output.allSatisfy({ $0 < 128 }) else { return nil }
            digits = Array(digits[(delimiter + 1)...])
        }
        var index = 0
        while index < digits.count {
            let oldI = i
            var w = 1, k = base
            while true {
                guard index < digits.count else { return nil }
                let c = digits[index].value
                index += 1
                let digit: Int
                switch c {
                case 48...57: digit = Int(c) - 22
                case 97...122: digit = Int(c) - 97
                case 65...90: digit = Int(c) - 65
                default: return nil
                }
                let (product, overflow) = digit.multipliedReportingOverflow(by: w)
                guard !overflow, i <= Int.max - product else { return nil }
                i += product
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if digit < t { break }
                let (nextW, wOverflow) = w.multipliedReportingOverflow(by: base - t)
                guard !wOverflow else { return nil }
                w = nextW
                k += base
            }
            // adapt the bias
            var delta = (i - oldI) / (oldI == 0 ? damp : 2)
            delta += delta / (output.count + 1)
            var k2 = 0
            while delta > ((base - tMin) * tMax) / 2 {
                delta /= base - tMin
                k2 += base
            }
            bias = k2 + (base - tMin + 1) * delta / (delta + skew)
            n += i / (output.count + 1)
            i %= output.count + 1
            guard n <= 0x10FFFF, !(0xD800...0xDFFF).contains(n) else { return nil }
            output.insert(UInt32(n), at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for value in output {
            guard let scalar = Unicode.Scalar(value) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }
}
