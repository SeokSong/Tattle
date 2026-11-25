import Foundation
import PCAPNG

/// demo only (`TATTLE_DEMO_LIVE`): hands on a capture file's packets at the pace they were recorded, so the pipeline,
/// its flush timer and the Live screen see them as they would from a phone
struct PacedPacketSource: PacketSource {
    let file: FilePacketSource

    func events() -> AsyncThrowingStream<PCAPNGEvent, Error> {
        let inner = file.events()
        return AsyncThrowingStream { continuation in
            let task = Task {
                var first: Date?
                let began = Date()
                do {
                    for try await event in inner {
                        if case .packet(let packet) = event {
                            let at = packet.timestamp
                            if first == nil { first = at }
                            let wait = at.timeIntervalSince(first!) - Date().timeIntervalSince(began)
                            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
