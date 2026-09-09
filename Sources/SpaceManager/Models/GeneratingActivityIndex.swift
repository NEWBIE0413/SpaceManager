import Foundation

/// Expiration is an in-memory operation. Only discovery or a filesystem event
/// supplies a fresh mtime; an idle app never stats all transcripts on a fast timer.
struct GeneratingActivityIndex {
    struct Entry {
        let cwd: String
        let modified: Date
    }
    var entries: [String: Entry] = [:]

    func directories(now: Date = Date()) -> Set<String> {
        Set(entries.values.compactMap {
            let age = now.timeIntervalSince($0.modified)
            return age >= 0 && age <= RecentActivityScanner.generatingWindow ? $0.cwd : nil
        })
    }

    func nextExpiration(now: Date = Date()) -> Date? {
        entries.values.map { $0.modified.addingTimeInterval(RecentActivityScanner.generatingWindow) }
            .filter { $0 >= now }.min()
    }
}
