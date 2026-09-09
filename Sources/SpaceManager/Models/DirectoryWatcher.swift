import Foundation
import CoreServices

final class DirectoryWatcher: ObservableObject {
    private var stream: FSEventStreamRef?
    private var currentPaths: [String] = []
    private var pendingReload: DispatchWorkItem?
    private var pendingPaths = Set<String>()
    private var needsFullRescan = false
    private var needsRestart = false

    var onChange: (() -> Void)?
    var onPathsChange: ((Set<String>, Bool) -> Void)?
    var isWatching: Bool { stream != nil }

    func start(path: String) {
        start(paths: [path])
    }

    /// Call on the main queue, as with SwiftUI's existing project-tree watcher.
    /// Missing roots are retried by the scanners' low-frequency reconciliation.
    func start(paths: [String]) {
        let paths = Array(Set(paths.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })).sorted()
        if currentPaths == paths, stream != nil, !needsRestart { return }

        stop()
        currentPaths = paths
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.handleEvent,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )

        guard let stream else { return }
        // Start, stop, event handling and batching share a queue. The old watcher
        // mutated pendingReload on both its private queue and the main queue.
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        pendingReload?.cancel()
        pendingReload = nil
        pendingPaths.removeAll()
        needsFullRescan = false
        needsRestart = false
    }

    deinit {
        stop()
    }

    private func scheduleReload() {
        // Keep the project tree's trailing debounce during builds. Transcript
        // consumers use bounded batching so continuous writes cannot starve them.
        if onPathsChange == nil {
            pendingReload?.cancel()
            pendingReload = nil
        }
        guard pendingReload == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil
            let paths = self.pendingPaths
            let fullRescan = self.needsFullRescan
            self.pendingPaths.removeAll(keepingCapacity: true)
            self.needsFullRescan = false
            self.onPathsChange?(paths, fullRescan)
            self.onChange?()
        }
        pendingReload = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private static let handleEvent: FSEventStreamCallback = { _, info, count, rawPaths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
        let rescanFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagRootChanged)
        for index in 0..<count {
            if watcher.onPathsChange != nil { watcher.pendingPaths.insert(String(cString: paths[index])) }
            if flags[index] & rescanFlags != 0 { watcher.needsFullRescan = true }
            if flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                watcher.needsRestart = true
            }
        }
        watcher.scheduleReload()
    }
}
