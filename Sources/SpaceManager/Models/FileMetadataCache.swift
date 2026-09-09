import Foundation

struct FileSignature: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64

    static func read(_ url: URL) -> Self? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return Self(size: size.uint64Value, modified: modified,
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
}

/// Queue-confined cache of parsed metadata, including files with no usable record.
/// Each discovery pass evicts files that have disappeared or aged out of its window.
struct FileMetadataCache<Value> {
    private struct Entry {
        let signature: FileSignature
        let value: Value?
    }
    private var entries: [String: Entry] = [:]
    private var visited = Set<String>()
    private(set) var loadCount = 0
    var count: Int { entries.count }

    mutating func beginPass() { visited.removeAll(keepingCapacity: true) }
    mutating func endPass() { entries = entries.filter { visited.contains($0.key) } }

    mutating func value(for url: URL, load: () -> Value?) -> Value? {
        guard let signature = FileSignature.read(url) else {
            entries[url.path] = nil
            return nil
        }
        visited.insert(url.path)
        if let entry = entries[url.path], entry.signature == signature { return entry.value }
        loadCount += 1
        let value = load()
        entries[url.path] = Entry(signature: signature, value: value)
        return value
    }
}

enum TranscriptJSON {
    // Immutable format styles can be shared by both scanner queues.
    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let integral = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    static func timestamp(_ raw: String) -> Date? {
        (try? fractional.parse(raw)) ?? (try? integral.parse(raw))
    }

    static func object(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    /// Split bytes before decoding so a tail starting inside a UTF-8 character
    /// only loses that partial record, rather than the entire read window.
    static func tail(_ file: URL, maxBytes: UInt64 = 131_072) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: size - min(size, maxBytes))) != nil else { return nil }
        return try? handle.read(upToCount: Int(min(size, maxBytes)))
    }
}
