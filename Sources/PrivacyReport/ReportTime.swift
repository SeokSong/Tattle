import Foundation

// parses the time stamps of the export: "2026-11-21T09:15:30.123-08:00" (md/PRIVACY_REPORT.md). the
// fraction is optional and the offset is "Z" or "+hh:mm". hand-written because a formatter object
// is far slower than the 100,000-line budget allows. a stamp with a bad shape or range gives nil
enum ReportTime {
    static func parse(_ s: String) -> Date? {
        var b = Array(s.utf8)[...]
        func digits(_ n: Int) -> Int? {
            guard b.count >= n else { return nil }
            var v = 0
            for c in b.prefix(n) {
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            b = b.dropFirst(n)
            return v
        }
        func expect(_ c: UInt8) -> Bool {
            guard b.first == c else { return false }
            b = b.dropFirst()
            return true
        }
        guard let y = digits(4), expect(45), let mo = digits(2), expect(45), let d = digits(2), expect(84),
              let h = digits(2), expect(58), let mi = digits(2), expect(58), let sec = digits(2) else { return nil }
        var fraction = 0.0
        if b.first == 46 {
            b = b.dropFirst()
            var scale = 0.1
            var any = false
            while let c = b.first, c >= 48, c <= 57 {
                fraction += Double(c - 48) * scale
                scale /= 10
                any = true
                b = b.dropFirst()
            }
            guard any else { return nil }
        }
        var offset = 0
        if b.first == 90 {
            b = b.dropFirst()
        } else {
            guard let sign = b.first, sign == 43 || sign == 45 else { return nil }
            b = b.dropFirst()
            guard let oh = digits(2), expect(58), let om = digits(2), oh <= 23, om <= 59 else { return nil }
            offset = (oh * 3600 + om * 60) * (sign == 45 ? -1 : 1)
        }
        guard b.isEmpty, (1970...9999).contains(y), (1...12).contains(mo), (1...daysIn(month: mo, year: y)).contains(d),
              h <= 23, mi <= 59, sec <= 59 else { return nil }
        let seconds = daysFromCivil(y, mo, d) * 86_400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: Double(seconds) + fraction)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // days since 1970-01-01 (howard hinnant's civil calendar algorithm)
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = y / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}
