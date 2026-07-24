import AppKit
import Combine

/// 창별 AppState와 실제 NSWindow를 연결해 아일랜드의 cwd 점프를 앱 전체로 라우팅한다.
final class WorkspaceWindowRegistry: ObservableObject {
    static let shared = WorkspaceWindowRegistry()

    /// 다른 창의 워크스페이스 구성이 바뀌어도 모든 아일랜드가 활성 상태를 다시 계산한다.
    @Published private(set) var revision = 0

    private final class Entry {
        weak var state: AppState?
        weak var window: NSWindow?
        var observation: AnyCancellable?

        init(state: AppState) {
            self.state = state
        }
    }

    private var entries: [Entry] = []

    private init() {}

    func register(_ state: AppState) {
        removeDeadEntries()
        guard !entries.contains(where: { $0.state === state }) else { return }
        let entry = Entry(state: state)
        entry.observation = state.objectWillChange.sink { [weak self, weak state] _ in
            // objectWillChange는 값이 바뀌기 직전에 오므로 다음 main turn에서 갱신한다.
            DispatchQueue.main.async {
                guard state != nil else { return }
                self?.bumpRevision()
            }
        }
        entries.append(entry)
        bumpRevision()
    }

    func unregister(_ state: AppState) {
        entries.removeAll { $0.state == nil || $0.state === state }
        bumpRevision()
    }

    func attach(window: NSWindow, to state: AppState) {
        register(state)
        guard let entry = entries.first(where: { $0.state === state }), entry.window !== window else { return }
        entry.window = window
        bumpRevision()
    }

    func detach(window: NSWindow, from state: AppState) {
        guard let entry = entries.first(where: { $0.state === state }), entry.window === window else { return }
        entry.window = nil
        bumpRevision()
    }

    func canJump(to cwd: String, preferredState: AppState) -> Bool {
        target(for: cwd, preferredState: preferredState) != nil
    }

    @discardableResult
    func jump(to cwd: String, preferredState: AppState) -> Bool {
        guard let target = target(for: cwd, preferredState: preferredState),
              let state = target.entry.state,
              let window = target.entry.window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        state.selectWorkspace(target.workspace)
        // SwiftUI의 선택 갱신이 같은 run loop에서 창 순서를 다시 건드려도 목표 창을
        // key로 유지한다. 다른 Space에 있는 창도 orderFrontRegardless가 전면화한다.
        DispatchQueue.main.async { [weak window] in
            window?.makeKeyAndOrderFront(nil)
            window?.orderFrontRegardless()
        }
        return true
    }

    /// cwd를 포함하는 가장 깊은 root를 선택한다. `/foo`가 `/foobar`를 먹지 않도록
    /// 경로 구분자 경계까지 확인한다.
    static func deepestWorkspace(containing cwd: String, in workspaces: [Workspace]) -> Workspace? {
        workspaces
            .filter { cwd == $0.rootPath || cwd.hasPrefix($0.rootPath + "/") }
            .max { $0.rootPath.count < $1.rootPath.count }
    }

    /// 모든 창의 후보 중 가장 구체적인 root를 우선한다. 현재 창 우선은 같은 root가
    /// 여러 창에 중복된 경우의 안정적인 tie-breaker일 뿐, 더 깊은 다른 창 후보를
    /// 가로채지 않는다.
    static func bestRoute<Owner: Equatable>(
        containing cwd: String,
        candidates: [(owner: Owner, workspace: Workspace)],
        preferredOwner: Owner
    ) -> (owner: Owner, workspace: Workspace)? {
        candidates
            .filter { cwd == $0.workspace.rootPath || cwd.hasPrefix($0.workspace.rootPath + "/") }
            .max { lhs, rhs in
                if lhs.workspace.rootPath.count != rhs.workspace.rootPath.count {
                    return lhs.workspace.rootPath.count < rhs.workspace.rootPath.count
                }
                return lhs.owner != preferredOwner && rhs.owner == preferredOwner
            }
    }

    private func target(for cwd: String, preferredState: AppState) -> (entry: Entry, workspace: Workspace)? {
        removeDeadEntries()
        let candidates = entries.flatMap { entry -> [(owner: ObjectIdentifier, workspace: Workspace)] in
            guard let state = entry.state, entry.window != nil else { return [] }
            let owner = ObjectIdentifier(state)
            return state.workspaces.map { (owner, $0) }
        }
        guard let route = Self.bestRoute(
            containing: cwd,
            candidates: candidates,
            preferredOwner: ObjectIdentifier(preferredState)
        ), let entry = entries.first(where: {
            guard let state = $0.state else { return false }
            return ObjectIdentifier(state) == route.owner && $0.window != nil
        }) else { return nil }
        return (entry, route.workspace)
    }

    private func removeDeadEntries() {
        entries.removeAll { $0.state == nil }
    }

    private func bumpRevision() {
        revision &+= 1
    }
}
