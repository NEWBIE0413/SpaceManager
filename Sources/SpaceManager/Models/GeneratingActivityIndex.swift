import Foundation

/// Expiration is an in-memory operation. Only discovery or a filesystem event
/// supplies a fresh mtime; an idle app never stats all transcripts on a fast timer.
struct GeneratingActivityIndex {
    struct Entry: Equatable {
        let cwd: String
        let modified: Date
        var host: String? = nil
    }
    var entries: [String: Entry] = [:]

    func directories(now: Date = Date()) -> Set<String> {
        Set(directoriesByHost(now: now).values.flatMap { $0 })
    }

    func directoriesByHost(now: Date = Date()) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for entry in entries.values {
            let age = now.timeIntervalSince(entry.modified)
            if age >= 0 && age <= RecentActivityScanner.generatingWindow {
                result[entry.host ?? "", default: []].insert(entry.cwd)
            }
        }
        return result
    }

    func nextExpiration(now: Date = Date()) -> Date? {
        entries.values.map { $0.modified.addingTimeInterval(RecentActivityScanner.generatingWindow) }
            .filter { $0 >= now }.min()
    }
}
