import AppKit
import Foundation

/// `sm` CLI 명령 라우터. UI가 할 수 있는 일은 전부 여기서도 할 수 있어야 한다 —
/// 새 UI 기능을 추가하면 같은 커밋에서 명령도 추가한다.
@MainActor
enum ControlCommands {
    static let socketPath = (NSHomeDirectory() as NSString).appendingPathComponent(".space-manager/control.sock")

    static func handle(_ request: ControlRequest, completion: @escaping (ControlResponse) -> Void) {
        do {
            if let deferred = try dispatchAsync(request, completion: completion) {
                _ = deferred
                return
            }
            completion(.ok(try dispatch(request)))
        } catch let error as CommandError {
            completion(.error(error.message))
        } catch {
            completion(.error("\(error)"))
        }
    }

    struct CommandError: Error { let message: String }
    private static func fail(_ message: String) -> CommandError { CommandError(message: message) }

    // MARK: - 동기 명령

    private static func dispatch(_ r: ControlRequest) throws -> Any {
        switch r.command {
        case "ping":
            return ["pid": ProcessInfo.processInfo.processIdentifier, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev"]

        case "windows.list":
            return liveWindows().map(describe)

        case "window.focus":
            let entry = try window(r)
            focus(entry)
            return describe(entry)

        case "window.close":
            let entry = try window(r)
            guard let nsWindow = entry.window else { throw fail("window has no NSWindow yet") }
            nsWindow.performClose(nil)
            return ["closed": entry.state.windowStateId.uuidString]

        case "window.appearance":
            let entry = try window(r)
            guard let value = r.string("value"), ["light", "dark", "system"].contains(value) else {
                throw fail("value must be light|dark|system")
            }
            entry.state.setAppearance(value)
            return describe(entry)

        case "ws.list":
            let targets = r.string("window") == nil ? liveWindows().filter { $0.state.windowKind == .workspace } : [try window(r)]
            return targets.flatMap { entry in entry.state.workspaces.map { describe($0, in: entry) } }

        case "ws.add":
            let entry = try workspaceWindow(r)
            guard let path = r.string("path") else { throw fail("path required") }
            let expanded = (path as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
            var host = r.string("host") ?? ""
            if ["local", "none", "-"].contains(host) { host = "" }
            if let error = entry.state.createWorkspace(rootPath: (absolute as NSString).standardizingPath, customName: r.string("name"), remoteHost: host) { throw fail(error) }
            guard let ws = entry.state.selectedWorkspace else { throw fail("workspace not created") }
            return describe(ws, in: entry)

        case "ws.rename":
            let (entry, ws) = try workspace(r)
            entry.state.renameWorkspace(ws, to: r.string("name"))
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.delete":
            let (entry, ws) = try workspace(r)
            entry.state.deleteWorkspace(ws)
            return ["deleted": ws.id.uuidString]

        case "ws.select":
            let (entry, ws) = try workspace(r)
            entry.state.selectWorkspace(ws)
            if r.bool("focus") ?? true { focus(entry) }
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.tmuxName":
            let (entry, ws) = try workspace(r)
            entry.state.setTmuxSessionName(ws, to: r.string("name") ?? "")
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.remote":
            let (entry, ws) = try workspace(r)
            var host = r.string("host") ?? ""
            if host == "none" || host == "local" || host == "-" { host = "" }
            if let error = entry.state.setRemoteHost(ws, to: host) { throw fail(error) }
            return describe(try refetch(ws, in: entry), in: entry)

        case "ws.move":
            let (entry, ws) = try workspace(r)
            guard let to = r.int("index"), let from = entry.state.workspaces.firstIndex(where: { $0.id == ws.id }) else {
                throw fail("index required")
            }
            entry.state.moveWorkspace(from: from, to: to > from ? to + 1 : to)
            return entry.state.workspaces.map { describe($0, in: entry) }

        case "project.add":
            let (entry, ws) = try workspace(r)
            guard let path = r.string("path") else { throw fail("path required") }
            entry.state.selectWorkspace(ws)
            entry.state.addProject(path: ((path as NSString).expandingTildeInPath as NSString).standardizingPath)
            return describe(try refetch(ws, in: entry), in: entry)

        case "project.remove":
            let (entry, ws) = try workspace(r)
            guard let path = r.string("path") else { throw fail("path required") }
            let target = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
            guard let project = ws.additionalProjects.first(where: { $0.path == target || $0.name == path }) else {
                throw fail("project not found: \(path)")
            }
            entry.state.selectWorkspace(ws)
            entry.state.removeProject(project)
            return describe(try refetch(ws, in: entry), in: entry)

        case "tab.list":
            let (entry, ws) = try workspaceOrSelected(r)
            return entry.state.sessions(for: ws).map { describe($0, selected: entry.state.selectedSession?.id == $0.id) }

        case "tab.shell", "tab.tmux":
            let (entry, ws) = try workspaceOrSelected(r)
            entry.state.selectWorkspace(ws)
            if r.command == "tab.shell" { entry.state.addShellTab() } else { entry.state.addTmuxTab() }
            guard let session = entry.state.selectedSession else { throw fail("tab not created") }
            return describe(session, selected: true)

        case "tab.select", "tab.close", "tab.reconnect":
            let (entry, session) = try tab(r)
            if r.command == "tab.reconnect" {
                session.reconnectIfNeeded()
                return describe(session, selected: entry.state.selectedSession?.id == session.id)
            }
            if r.command == "tab.select" {
                entry.state.selectSession(session)
                if r.bool("focus") ?? true { focus(entry) }
                return describe(session, selected: true)
            }
            guard session.kind != .tmuxMain else { throw fail("main tmux tab cannot be closed (it is recreated on next visit)") }
            entry.state.removeSession(session)
            return ["closed": session.id.uuidString]

        case "tab.next", "tab.prev":
            let entry = try window(r)
            if r.command == "tab.next" { entry.state.selectNextSession() } else { entry.state.selectPreviousSession() }
            guard let session = entry.state.selectedSession else { throw fail("no tabs") }
            return describe(session, selected: true)

        case "quick.list":
            let limit = r.int("limit") ?? 30
            let dir = QuickConversationScanner.defaultTranscriptsDirectory()
            let titles = QuickConversationScanner.scanAITitles(directory: dir)
            return QuickConversationScanner.scan(directory: dir).prefix(limit).map { c in
                ["id": c.id, "title": titles[c.id] ?? c.aiTitle ?? c.title, "modifiedAt": iso(c.modifiedAt), "transcript": c.transcriptURL.path]
            }

        case "quick.home":
            let entry = try quickWindow(r)
            entry.state.showQuickHome()
            return describe(entry)

        case "activity.list":
            let scanner = RecentActivityScanner.shared
            return [
                "sessions": scanner.sessions.map {
                    ["id": $0.id, "provider": $0.provider.rawValue, "cwd": $0.cwd, "name": $0.name,
                     "lastActivity": iso($0.lastActivity), "snippet": $0.snippet ?? "", "host": $0.host ?? ""]
                },
                "workspaceActivity": scanner.workspaceActivity.mapValues(iso),
                "generating": Array(scanner.generatingDirectories).sorted(),
            ]

        case "state.dump":
            let data = try JSONEncoder.pretty.encode(WorkspaceStorage.shared.windowStates)
            return try JSONSerialization.jsonObject(with: data)

        case "quick.new", "quick.resume", "window.new":
            throw fail("internal: async command reached sync dispatcher")
        default:
            throw fail("unknown command: \(r.command)")
        }
    }

    // MARK: - 비동기 명령 (창을 열고 기다려야 하는 것들)

    /// 처리했으면 non-nil. 창 생성은 SwiftUI가 다음 run loop에서 AppState를 만들기 때문에
    /// 레지스트리에 새 창이 등록될 때까지 폴링한 뒤 응답한다.
    private static func dispatchAsync(_ r: ControlRequest, completion: @escaping (ControlResponse) -> Void) throws -> Bool? {
        switch r.command {
        case "window.new":
            let kind: WindowKind = (r.string("kind") ?? "workspace") == "quick" ? .quick : .workspace
            openWindow(kind: kind) { result in
                completion(result.map { .ok(describe($0)) } ?? .error("window did not appear"))
            }
            return true

        case "quick.new", "quick.resume":
            let configuration = try quickConfiguration(r)
            let run: (WindowEntry) -> Void = { entry in
                if r.command == "quick.resume" {
                    guard let id = r.string("id") else { completion(.error("id required")); return }
                    entry.state.resumeQuickConversation(sessionId: id)
                } else {
                    entry.state.addQuickSession(initialPrompt: r.string("prompt"), configuration: configuration)
                }
                if r.bool("focus") ?? true { focus(entry) }
                guard let session = entry.state.selectedSession else { completion(.error("session not created")); return }
                completion(.ok(describe(session, selected: true)))
            }
            if let entry = try? quickWindow(r) {
                run(entry)
            } else {
                openWindow(kind: .quick) { entry in
                    guard let entry else { completion(.error("could not open quick window")); return }
                    run(entry)
                }
            }
            return true
        default:
            return nil
        }
    }

    private static func openWindow(kind: WindowKind, completion: @escaping (WindowEntry?) -> Void) {
        guard let open = WindowOpener.open else { completion(nil); return }
        let before = Set(liveWindows().map { $0.state.windowStateId })
        let id = UUID()
        open(kind.sceneID, id)
        NSApp.activate(ignoringOtherApps: true)
        var attempts = 0
        func poll() {
            if let entry = liveWindows().first(where: { $0.state.windowStateId == id || (!before.contains($0.state.windowStateId) && $0.state.windowKind == kind) }) {
                completion(entry); return
            }
            attempts += 1
            if attempts > 40 { completion(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: poll)
        }
        poll()
    }

    private static func quickConfiguration(_ r: ControlRequest) throws -> QuickSessionConfiguration {
        let base = QuickComposerPreferences.load()
        var effort = base.effort
        if let raw = r.string("effort") {
            guard let parsed = QuickEffort(rawValue: raw) else {
                throw fail("effort must be one of \(QuickEffort.allCases.map(\.rawValue).joined(separator: "|"))")
            }
            effort = parsed
        }
        return QuickSessionConfiguration(
            modelID: r.string("model") ?? base.modelID,
            effort: effort,
            proxyEnabled: r.bool("proxy") ?? base.proxyEnabled
        )
    }

    // MARK: - 대상 해석

    typealias WindowEntry = (state: AppState, window: NSWindow?)

    static func liveWindows() -> [WindowEntry] {
        WorkspaceWindowRegistry.shared.liveEntries()
    }

    private static func window(_ r: ControlRequest) throws -> WindowEntry {
        let entries = liveWindows()
        guard !entries.isEmpty else { throw fail("no windows open") }
        guard let query = r.string("window"), !query.isEmpty, query != "front", query != "key" else {
            return entries.first { $0.window?.isKeyWindow == true } ?? entries.first { $0.window != nil } ?? entries[0]
        }
        if let index = Int(query), entries.indices.contains(index) { return entries[index] }
        if let hit = entries.first(where: { $0.state.windowStateId.uuidString.lowercased().hasPrefix(query.lowercased()) }) { return hit }
        if let hit = entries.first(where: { $0.state.windowKind.rawValue == query.lowercased() }) { return hit }
        throw fail("window not found: \(query)")
    }

    private static func workspaceWindow(_ r: ControlRequest) throws -> WindowEntry {
        let entry = try window(r)
        if entry.state.windowKind == .workspace { return entry }
        guard let other = liveWindows().first(where: { $0.state.windowKind == .workspace }) else {
            throw fail("no workspace window open (sm window new)")
        }
        return other
    }

    private static func quickWindow(_ r: ControlRequest) throws -> WindowEntry {
        if let query = r.string("window"), !query.isEmpty, query != "front", query != "key" {
            let entry = try window(r)
            guard entry.state.windowKind == .quick else { throw fail("window \(query) is not a quick window") }
            return entry
        }
        let quicks = liveWindows().filter { $0.state.windowKind == .quick }
        guard let entry = quicks.first(where: { $0.window?.isKeyWindow == true }) ?? quicks.first else {
            throw fail("no quick window open")
        }
        return entry
    }

    /// 워크스페이스 질의: id 접두사 / 이름 / tmux 세션명 / 경로 / 경로 마지막 요소.
    static func matchWorkspace(_ query: String, in workspaces: [Workspace]) -> Workspace? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let lower = q.lowercased()
        let expanded = ((q as NSString).expandingTildeInPath as NSString).standardizingPath
        return workspaces.first { $0.id.uuidString.lowercased() == lower }
            ?? workspaces.first { $0.name == q }
            ?? workspaces.first { $0.effectiveTmuxSessionName == q }
            ?? workspaces.first { $0.rootPath == expanded }
            ?? workspaces.first { $0.name.lowercased() == lower }
            ?? workspaces.first { ($0.rootPath as NSString).lastPathComponent.lowercased() == lower }
            ?? (q.count >= 4 ? workspaces.first { $0.id.uuidString.lowercased().hasPrefix(lower) } : nil)
    }

    private static func workspace(_ r: ControlRequest) throws -> (WindowEntry, Workspace) {
        guard let query = r.string("ws") else { throw fail("workspace required") }
        let candidates: [WindowEntry] = r.string("window") == nil
            ? liveWindows().filter { $0.state.windowKind == .workspace }
            : [try window(r)]
        for entry in candidates {
            if let ws = matchWorkspace(query, in: entry.state.workspaces) { return (entry, ws) }
        }
        throw fail("workspace not found: \(query)")
    }

    private static func workspaceOrSelected(_ r: ControlRequest) throws -> (WindowEntry, Workspace) {
        if r.string("ws") != nil { return try workspace(r) }
        let entry = try workspaceWindow(r)
        guard let ws = entry.state.selectedWorkspace else { throw fail("no workspace selected") }
        return (entry, ws)
    }

    private static func refetch(_ ws: Workspace, in entry: WindowEntry) throws -> Workspace {
        guard let fresh = entry.state.workspaces.first(where: { $0.id == ws.id }) else { throw fail("workspace vanished") }
        return fresh
    }

    private static func tab(_ r: ControlRequest) throws -> (WindowEntry, TerminalSession) {
        guard let query = r.string("tab") else { throw fail("tab required") }
        let lower = query.lowercased()
        for entry in liveWindows() {
            let sessions = entry.state.sessions
            if let hit = sessions.first(where: { $0.id.uuidString.lowercased() == lower })
                ?? sessions.first(where: { $0.name == query || $0.tmuxSessionName == query })
                ?? (Int(query).flatMap { sessions.indices.contains($0) ? sessions[$0] : nil })
                ?? (query.count >= 4 ? sessions.first { $0.id.uuidString.lowercased().hasPrefix(lower) } : nil) {
                return (entry, hit)
            }
        }
        throw fail("tab not found: \(query)")
    }

    private static func focus(_ entry: WindowEntry) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = entry.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 직렬화

    private static func describe(_ entry: WindowEntry) -> [String: Any] {
        [
            "id": entry.state.windowStateId.uuidString,
            "kind": entry.state.windowKind.rawValue,
            "isKey": entry.window?.isKeyWindow ?? false,
            "appearance": entry.state.preferredAppearance,
            "workspaceCount": entry.state.workspaces.count,
            "selectedWorkspace": entry.state.selectedWorkspace?.name ?? "",
            "tabCount": entry.state.sessions.count,
        ]
    }

    private static func describe(_ ws: Workspace, in entry: WindowEntry) -> [String: Any] {
        [
            "id": ws.id.uuidString,
            "name": ws.name,
            "rootPath": ws.rootPath,
            "tmuxSession": ws.effectiveTmuxSessionName,
            "customTmuxSession": ws.tmuxSessionName ?? "",
            "remoteHost": ws.remoteHost ?? "",
            "projects": ws.additionalProjects.map(\.path),
            "selected": entry.state.selectedWorkspace?.id == ws.id,
            "window": entry.state.windowStateId.uuidString,
        ]
    }

    private static func describe(_ s: TerminalSession, selected: Bool) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "kind": s.kind.rawValue,
            "name": s.name,
            "workingDirectory": s.workingDirectory,
            "tmuxSession": s.tmuxSessionName ?? "",
            "remoteHost": s.remoteHost ?? "",
            "running": s.isRunning,
            "reconnecting": s.isReconnecting,
            "error": s.startError ?? "",
            "selected": selected,
        ]
    }

    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e
    }
}
