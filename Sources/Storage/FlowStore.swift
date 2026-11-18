import Domains
import Flows
import Foundation

// what the pipeline needs from a store. lets tests swap in a store that fails on demand.
public protocol FlowStore: AnyObject {
    func beginSession(_ s: CaptureSession) throws
    func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws
    func endSession(id: UUID, at: Date, reason: String) throws
    func recordSessionStats(id: UUID, _ stats: SessionStats) throws
}

extension Store: FlowStore {
    public func recordSessionStats(id: UUID, _ stats: SessionStats) throws {
        try setSessionStats(id: id, stats)
    }
}
