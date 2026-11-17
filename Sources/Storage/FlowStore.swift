import Domains
import Flows
import Foundation

// what the pipeline needs from a store. lets tests swap in a store that fails on demand.
public protocol FlowStore: AnyObject {
    func beginSession(_ s: CaptureSession) throws
    func save(flows: [Flow], domains: [DomainObservation], session: UUID) throws
    func endSession(id: UUID, at: Date, reason: String) throws
}

extension Store: FlowStore {}
