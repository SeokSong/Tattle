import Foundation

/// where the parser reads bytes from. a file in the app, a counting source in tests
public protocol LineSource {
    /// size known before reading (a regular file), so a file over the cap is refused unread
    var byteCount: Int? { get }
    /// the file name, used only to read the format version; never stored or put in an error
    var fileName: String? { get }
    /// up to `maxLength` bytes; empty data means the end
    func read(maxLength: Int) throws -> Data
}

/// reads a file in chunks (64 KB, as `FileHandlePacketSource` does), never all at once
public final class FileLineSource: LineSource {
    public static let chunkSize = 64 * 1024
    private let handle: FileHandle
    public let byteCount: Int?
    public let fileName: String?

    public init(url: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
            byteCount = size?.intValue
        } catch {
            throw ImportError.unreadable
        }
        fileName = url.lastPathComponent
    }

    public func read(maxLength: Int) throws -> Data {
        do {
            return try handle.read(upToCount: maxLength) ?? Data()
        } catch {
            throw ImportError.unreadable
        }
    }

    public func close() { try? handle.close() }
    deinit { try? handle.close() }
}
