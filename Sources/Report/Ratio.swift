/// a metric printed as numerator, denominator and value; value is absent when the denominator is 0
public struct Ratio: Codable, Equatable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public var value: Double? {
        denominator > 0 ? Double(numerator) / Double(denominator) : nil
    }

    private enum CodingKeys: String, CodingKey { case numerator, denominator, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        numerator = try c.decode(Int.self, forKey: .numerator)
        denominator = try c.decode(Int.self, forKey: .denominator)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(numerator, forKey: .numerator)
        try c.encode(denominator, forKey: .denominator)
        if let value { try c.encode(value, forKey: .value) }
    }
}
