import SwiftUI
import AppKit

/// 선택된 워크스페이스의 파일 브라우저 섹션.
/// 워크스페이스 이름은 위 WORKSPACES 목록의 선택 행이 이미 보여주므로
/// 여기서 반복하지 않는다 — 같은 정보가 두 번 보이면 패널이 소음이 된다.
struct ProjectListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if let workspace = appState.selectedWorkspace {
                    ProjectFileBrowser(rootPath: workspace.rootPath)
                        .id(workspace.id)
                } else {
                    SidebarSectionHeader(title: "FILES") { EmptyView() }
                    Text("Select a workspace")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ProjectFileBrowser: View {
    let rootPath: String
    @State private var items: [FileItem] = []
    @State private var isLoading = false
    @StateObject private var watcher = DirectoryWatcher()
    @State private var editorTarget: EditorTarget?
    @State private var refreshToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarSectionHeader(title: "FILES") {
                Menu {
                    Button("New File") {
                        createFile(in: URL(fileURLWithPath: rootPath))
                    }
                    Button("New Folder") {
                        createFolder(in: URL(fileURLWithPath: rootPath))
                    }
                    Divider()
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: rootPath)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("New File / Folder")
            }

            // 스피너는 최초 로드에만 보여준다 — 갱신 때마다 트리를 스피너로 갈아끼우면
            // 파일이 바뀔 때마다 패널 전체가 깜빡인다. 갱신은 항목 id(경로)가 안정적이라
            // 제자리 diff로 조용히 반영된다.
            if isLoading && items.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else if items.isEmpty {
                Text("No files")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        FileNodeView(
                            item: item,
                            depth: 0,
                            refreshToken: refreshToken,
                            onEdit: openEditor,
                            onRename: renameItem,
                            onCreateFile: createFile,
                            onCreateFolder: createFolder
                        )
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .onAppear {
            watcher.onChange = { loadItems() }
            watcher.start(path: rootPath)
            loadItems()
        }
        .onChange(of: rootPath) {
            watcher.start(path: rootPath)
            loadItems()
        }
        .onDisappear {
            watcher.stop()
        }
        .sheet(item: $editorTarget) { target in
            FileEditorSheet(
                fileURL: target.url,
                initialText: target.content,
                onSave: { text in
                    saveFile(target.url, text: text)
                    editorTarget = nil
                },
                onClose: {
                    editorTarget = nil
                }
            )
        }
    }

    private func loadItems() {
        guard FileManager.default.fileExists(atPath: rootPath) else {
            items = []
            return
        }
        if items.isEmpty { isLoading = true }
        let rootURL = URL(fileURLWithPath: rootPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = FileItem.loadChildren(of: rootURL)
            DispatchQueue.main.async {
                items = loaded
                isLoading = false
                refreshToken = UUID()
            }
        }
    }

    private func openEditor(_ item: FileItem) {
        guard !item.isExpandable else { return }
        do {
            let data = try Data(contentsOf: item.url)
            guard let content = String(data: data, encoding: .utf8) else {
                showAlert(title: "Unsupported File", message: "Only UTF-8 text files can be edited.")
                return
            }
            editorTarget = EditorTarget(url: item.url, content: content)
        } catch {
            showAlert(title: "Open Failed", message: error.localizedDescription)
        }
    }

    private func saveFile(_ url: URL, text: String) {
        do {
            try text.data(using: .utf8)?.write(to: url, options: .atomic)
        } catch {
            showAlert(title: "Save Failed", message: error.localizedDescription)
        }
    }

    private func renameItem(_ item: FileItem) {
        guard let newName = promptForName(title: "Rename", placeholder: item.name, value: item.name) else { return }
        guard isValidName(newName) else {
            showAlert(title: "Invalid Name", message: "Names cannot be empty or contain '/'.")
            return
        }
        let destination = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        if FileManager.default.fileExists(atPath: destination.path) {
            showAlert(title: "Rename Failed", message: "A file with that name already exists.")
            return
        }
        do {
            try FileManager.default.moveItem(at: item.url, to: destination)
        } catch {
            showAlert(title: "Rename Failed", message: error.localizedDescription)
        }
    }

    private func createFile(in directory: URL) {
        guard let name = promptForName(title: "New File", placeholder: "filename.txt") else { return }
        guard isValidName(name) else {
            showAlert(title: "Invalid Name", message: "Names cannot be empty or contain '/'.")
            return
        }
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            showAlert(title: "Create Failed", message: "A file with that name already exists.")
            return
        }
        let created = FileManager.default.createFile(atPath: target.path, contents: Data(), attributes: nil)
        if !created {
            showAlert(title: "Create Failed", message: "Unable to create the file.")
        }
    }

    private func createFolder(in directory: URL) {
        guard let name = promptForName(title: "New Folder", placeholder: "folder") else { return }
        guard isValidName(name) else {
            showAlert(title: "Invalid Name", message: "Names cannot be empty or contain '/'.")
            return
        }
        let target = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) {
            showAlert(title: "Create Failed", message: "A folder with that name already exists.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            showAlert(title: "Create Failed", message: error.localizedDescription)
        }
    }

    private func promptForName(title: String, placeholder: String, value: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = ""
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        input.stringValue = value
        input.placeholderString = placeholder
        alert.accessoryView = input

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func isValidName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/")
    }
}

private struct FileNodeView: View {
    let item: FileItem
    let depth: Int
    let refreshToken: UUID
    let onEdit: (FileItem) -> Void
    let onRename: (FileItem) -> Void
    let onCreateFile: (URL) -> Void
    let onCreateFolder: (URL) -> Void
    @State private var isExpanded = false
    @State private var children: [FileItem] = []
    @State private var didLoadChildren = false

    var body: some View {
        if item.isExpandable {
            DisclosureGroup(isExpanded: $isExpanded) {
                if isExpanded {
                    if !didLoadChildren {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 20)
                            .onAppear {
                                loadChildren()
                            }
                    } else if children.isEmpty {
                        Text("Empty")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.leading, 20)
                    } else {
                        ForEach(children) { child in
                            FileNodeView(
                                item: child,
                                depth: depth + 1,
                                refreshToken: refreshToken,
                                onEdit: onEdit,
                                onRename: onRename,
                                onCreateFile: onCreateFile,
                                onCreateFolder: onCreateFolder
                            )
                        }
                    }
                }
            } label: {
                FileRowView(
                    item: item,
                    depth: depth,
                    onOpen: onEdit,
                    onRename: onRename,
                    onCreateFile: onCreateFile,
                    onCreateFolder: onCreateFolder
                )
            }
            .onChange(of: refreshToken) {
                if isExpanded {
                    reloadChildren()
                }
            }
        } else {
            FileRowView(
                item: item,
                depth: depth,
                onOpen: onEdit,
                onRename: onRename,
                onCreateFile: onCreateFile,
                onCreateFolder: onCreateFolder
            )
        }
    }

    private func loadChildren() {
        didLoadChildren = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = FileItem.loadChildren(of: item.url)
            DispatchQueue.main.async {
                children = loaded
            }
        }
    }

    private func reloadChildren() {
        didLoadChildren = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = FileItem.loadChildren(of: item.url)
            DispatchQueue.main.async {
                children = loaded
            }
        }
    }
}

private struct FileRowView: View {
    let item: FileItem
    let depth: Int
    let onOpen: (FileItem) -> Void
    let onRename: (FileItem) -> Void
    let onCreateFile: (URL) -> Void
    let onCreateFolder: (URL) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.isExpandable ? "folder" : "doc.text")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 14)

            Text(item.name)
                .font(.system(size: 12))
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: Sidebar.rowCornerRadius)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !item.isExpandable {
                onOpen(item)
            }
        }
        .contextMenu {
            if item.isExpandable {
                Button("New File") {
                    onCreateFile(item.url)
                }
                Button("New Folder") {
                    onCreateFolder(item.url)
                }
                Divider()
            } else {
                Button("Edit") {
                    onOpen(item)
                }
                Divider()
            }

            Button("Rename") {
                onRename(item)
            }

            Divider()

            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.url.path)
            }
        }
        .help(item.url.path)
    }
}

private struct FileItem: Identifiable, Hashable {
    let id: String
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool

    var isExpandable: Bool { isDirectory && !isPackage }

    static func loadChildren(of url: URL) -> [FileItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            return []
        }

        let items = urls.compactMap { itemURL -> FileItem? in
            guard let values = try? itemURL.resourceValues(forKeys: keys) else { return nil }
            let isDirectory = values.isDirectory ?? false
            let isPackage = values.isPackage ?? false
            return FileItem(
                id: itemURL.path,
                url: itemURL,
                name: itemURL.lastPathComponent,
                isDirectory: isDirectory,
                isPackage: isPackage
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

private struct EditorTarget: Identifiable {
    let id: String
    let url: URL
    let content: String

    init(url: URL, content: String) {
        self.id = url.path
        self.url = url
        self.content = content
    }
}

private struct FileEditorSheet: View {
    let fileURL: URL
    let onSave: (String) -> Void
    let onClose: () -> Void
    @State private var text: String

    init(fileURL: URL, initialText: String, onSave: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.fileURL = fileURL
        self.onSave = onSave
        self.onClose = onClose
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(fileURL.lastPathComponent)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .padding(12)

            Divider()

            HStack {
                Button("Cancel") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    onSave(text)
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
