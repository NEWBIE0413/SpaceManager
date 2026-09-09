import Foundation
import Combine

// Standalone harness; no application, CLI processes or user transcripts are opened.
enum QuickSessionPolicy { static let workingDirectory = "/tmp/benchmark-quick" }

@main
struct ScannerBenchmark {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let quick = root.appendingPathComponent("quick")
        let projects = root.appendingPathComponent("projects")
        let project = projects.appendingPathComponent("fixture")
        try fm.createDirectory(at: quick, withIntermediateDirectories: true)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let now = Date()
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let padding = String(repeating: "x", count: 2048)
        let tool = "{\"type\":\"assistant\",\"data\":\"\(padding)\"}\n"
        var quickFiles: [URL] = []
        var initialQuickBytes = 0
        for i in 0..<40 {
            let file = quick.appendingPathComponent("\(UUID().uuidString).jsonl")
            let data = Data(("{\"type\":\"ai-title\",\"aiTitle\":\"title \(i)\"}\n"
                + String(repeating: tool, count: 1024)).utf8)
            try data.write(to: file)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(-i))], ofItemAtPath: file.path)
            quickFiles.append(file)
            initialQuickBytes += data.count
        }
        let activityLine = "{\"type\":\"user\",\"cwd\":\"/tmp/fixture\",\"timestamp\":\"\(timestamp)\",\"message\":{\"content\":\"request\"},\"data\":\"\(padding)\"}\n"
        for i in 0..<100 {
            try Data(String(repeating: activityLine, count: 64).utf8)
                .write(to: project.appendingPathComponent("\(i).jsonl"))
        }
        var metrics: [String: Any] = [:]
        func timed(_ body: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            body()
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        var cwd: [String: String] = [:]
        #if OPTIMIZED
        var activityCache = FileMetadataCache<RecentActivityScanner.Tail>()
        func scanActivity() {
            _ = RecentActivityScanner.scan(projectsDir: projects, cwdCache: &cwd, tailCache: &activityCache, now: now)
        }
        var titleIndex = TranscriptTitleIndex()
        func scanQuick() {
            _ = QuickConversationScanner.scanClaude(directory: quick, limit: 31, tracked: [], index: &titleIndex)
        }
        #else
        func scanActivity() { _ = RecentActivityScanner.scan(projectsDir: projects, cwdCache: &cwd, now: now) }
        var quickCache: [String: QuickConversationScanner.CacheEntry] = [:]
        func scanQuick() { _ = QuickConversationScanner.scanResult(directory: quick, cache: &quickCache) }
        #endif
        metrics["activity_cold_ms"] = timed { scanActivity() }
        metrics["activity_10_unchanged_scans_ms"] = timed { for _ in 0..<10 { scanActivity() } }
        metrics["quick_cold_ms"] = timed { scanQuick() }
        #if OPTIMIZED
        let beforeAppendBytes = titleIndex.bytesRead
        metrics["quick_cold_bytes"] = beforeAppendBytes
        #else
        metrics["quick_cold_bytes"] = initialQuickBytes
        #endif
        let extra = Data("{\"type\":\"ai-title\",\"aiTitle\":\"updated title\"}\n".utf8)
        var appendTimes: [Double] = []
        var baselineAppendBytes = 0
        for i in 0..<10 {
            let handle = try FileHandle(forWritingTo: quickFiles[0])
            try handle.seekToEnd()
            try handle.write(contentsOf: extra)
            try handle.close()
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(Double(i + 1))], ofItemAtPath: quickFiles[0].path)
            baselineAppendBytes += (try fm.attributesOfItem(atPath: quickFiles[0].path)[.size] as! NSNumber).intValue
            appendTimes.append(timed { scanQuick() })
        }
        metrics["quick_10_appends_ms"] = appendTimes.reduce(0, +)
        #if OPTIMIZED
        metrics["quick_10_appends_bytes"] = titleIndex.bytesRead - beforeAppendBytes
        metrics["activity_total_parses"] = activityCache.loadCount
        precondition(titleIndex.bytesRead - beforeAppendBytes == extra.count * 10)
        precondition(activityCache.loadCount == 100)
        #else
        // The baseline parser uses Data(contentsOf:) for each changed transcript.
        metrics["quick_10_appends_bytes"] = baselineAppendBytes
        metrics["activity_total_parses"] = 100 * 11
        #endif
        print(String(decoding: try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
