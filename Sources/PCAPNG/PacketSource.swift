import Foundation

// sources of pcapng events. each runs its bytes through a PCAPNGStreamParser

public protocol PacketSource: Sendable {
    /// yields events as they become available; ends on EOF
    func events() -> AsyncThrowingStream<PCAPNGEvent, Error>
}

/// reads a file in 256 KB chunks
public struct FilePacketSource: PacketSource {
    public static let chunkSize = 256 * 1024

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func events() -> AsyncThrowingStream<PCAPNGEvent, Error> {
        let url = url
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }

                    var parser = PCAPNGStreamParser()

                    while !Task.isCancelled, let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                        for event in try parser.append(chunk) {
                            continuation.yield(event)
                        }
                    }

                    continuation.yield(.end(try parser.finish()))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// feeds in-memory bytes in chunks; for tests
public struct DataPacketSource: PacketSource {
    public let data: [UInt8]
    public let chunkSize: Int

    public init(_ data: [UInt8], chunkSize: Int = FilePacketSource.chunkSize) {
        self.data = data
        self.chunkSize = max(1, chunkSize)
    }

    public func events() -> AsyncThrowingStream<PCAPNGEvent, Error> {
        let data = data
        let chunkSize = chunkSize
        return AsyncThrowingStream { continuation in
            do {
                var parser = PCAPNGStreamParser()

                for start in stride(from: 0, to: data.count, by: chunkSize) {
                    for event in try parser.append(data[start..<min(start + chunkSize, data.count)]) {
                        continuation.yield(event)
                    }
                }

                continuation.yield(.end(try parser.finish()))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
