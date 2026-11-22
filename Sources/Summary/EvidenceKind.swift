import Foundation

/// how the hostname behind a company label was learned. a label from a hint is shown as possible
/// and is never counted as named
public enum EvidenceKind: String, Sendable, Codable {
    /// the name was read from the connection itself (the server name in the handshake)
    case captureName
    /// the name came from a DNS answer or from another connection to the same server, and may differ
    case captureHint
}
