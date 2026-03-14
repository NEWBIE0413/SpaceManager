import Foundation
import CoreServices

final class DirectoryWatcher: ObservableObject {
    private var stream: FSEventStreamRef?
    private var currentPath: String?
    private let queue = DispatchQueue(label: "SpaceManager.DirectoryWatcher")
    private var pendingReload: DispatchWorkItem?

    var onChange: (() -> Void)?

    func start(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            stop()
            currentPath = path
            return
        }

        if currentPath == path, stream != nil {
            return
        }

        stop()
        currentPath = path

        var context = FSEventStreamContext(
            version: 0,
            info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [path] as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            DirectoryWatcher.handleEvent,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
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
    }

    deinit {
        stop()
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.onChange?()
            }
        }
        pendingReload = workItem
        queue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private static let handleEvent: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        watcher.scheduleReload()
    }
}
