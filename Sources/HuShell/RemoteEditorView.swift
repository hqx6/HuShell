import SwiftUI
import AppKit

enum RemoteDocumentPolicy {
    static let maxEditableBytes: Int64 = 50_000_000
    private static let extensions: Set<String> = [
        "txt", "text", "md", "markdown", "log", "json", "jsonl", "yaml", "yml", "xml", "csv",
        "tsv", "html", "htm", "css", "js", "jsx", "ts", "tsx", "sh", "bash", "zsh",
        "py", "swift", "c", "h", "cpp", "hpp", "java", "go", "rs", "rb", "php",
        "sql", "toml", "ini", "conf", "cfg", "properties", "env", "gitignore", "dockerfile"
    ]

    static func canEdit(_ file: RemoteFile) -> Bool {
        guard !file.isDirectory, let size = Int64(file.size), size <= maxEditableBytes else { return false }
        let name = file.name.lowercased()
        let ext = (name as NSString).pathExtension
        return extensions.contains(ext) || extensions.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    }

    static func decode(_ data: Data) -> String? {
        guard Int64(data.count) <= maxEditableBytes, !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct RemoteEditorSession: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let path: String
    let fileName: String
    let localURL: URL
    let initialText: String
}

@MainActor final class RemoteEditorDocument: ObservableObject, Identifiable {
    let session: RemoteEditorSession
    let onSaved: () -> Void
    let id: UUID
    @Published var text: String
    @Published var savedText: String
    @Published var saving = false
    @Published var errorMessage: String?
    var hasChanges: Bool { text != savedText }

    init(session: RemoteEditorSession, onSaved: @escaping () -> Void) {
        self.id = session.id
        self.session = session
        self.onSaved = onSaved
        text = session.initialText
        savedText = session.initialText
    }

    func save() {
        guard !saving else { return }
        let snapshot = text
        let session = session
        saving = true
        Task {
            let result = await Task.detached { Result {
                try snapshot.write(to: session.localURL, atomically: true, encoding: .utf8)
                try SSHService.upload(profile: session.profile, local: session.localURL, remote: session.path)
            } }.value
            saving = false
            switch result {
            case .success:
                savedText = snapshot
                onSaved()
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor final class RemoteEditorWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = RemoteEditorWindow()
    @Published private(set) var documents: [RemoteEditorDocument] = []
    @Published var selectedID: UUID? {
        didSet { updateTitle(); showsFind = false }
    }
    @Published var showsFind = false
    @Published var showsInfoBar = false
    private var window: NSWindow?
    private var confirmingClose = false

    func activate(profileID: UUID, path: String) -> Bool {
        guard let document = documents.first(where: { $0.session.profile.id == profileID && $0.session.path == path }) else { return false }
        selectedID = document.id
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func open(_ session: RemoteEditorSession, onSaved: @escaping () -> Void) {
        if activate(profileID: session.profile.id, path: session.path) { return }
        let document = RemoteEditorDocument(session: session, onSaved: onSaved)
        documents.append(document)
        selectedID = document.id
        if window == nil {
            let editor = RemoteTextWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            editor.commandHandler = { [weak self] key in
                guard let self, let selected = self.documents.first(where: { $0.id == self.selectedID }) else { return false }
                switch key {
                case "s": if selected.hasChanges { selected.save() }
                case "f": self.showsFind = true
                case "w": self.close(selected)
                default: return false
                }
                return true
            }
            editor.minSize = NSSize(width: 780, height: 560)
            editor.isReleasedWhenClosed = false
            editor.delegate = self
            editor.contentView = NSHostingView(rootView: RemoteEditorWorkspace(editor: self))
            editor.center()
            window = editor
        }
        updateTitle()
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateTitle() {
        guard let selected = documents.first(where: { $0.id == selectedID }) else {
            window?.title = "远端文本编辑器"
            return
        }
        window?.title = "远端文本编辑器 · \(selected.session.profile.name) · \(selected.session.path)"
    }

    func close(_ document: RemoteEditorDocument) {
        guard !document.saving, !confirmingClose else { return }
        if document.hasChanges {
            confirmDiscard(message: "“\(document.session.fileName)”尚未保存，关闭会丢失修改。") { [weak self] in
                self?.remove(document)
            }
        } else { remove(document) }
    }

    private func remove(_ document: RemoteEditorDocument) {
        guard let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        documents.remove(at: index)
        if selectedID == document.id {
            selectedID = documents.isEmpty ? nil : documents[min(index, documents.count - 1)].id
        }
        if documents.isEmpty { window?.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !confirmingClose else { return false }
        if documents.contains(where: \.saving) {
            let alert = NSAlert()
            alert.messageText = "文件正在保存"
            alert.informativeText = "请等待上传完成后再关闭编辑器。"
            alert.addButton(withTitle: "好")
            alert.beginSheetModal(for: sender)
            return false
        }
        let changed = documents.filter(\.hasChanges)
        guard !changed.isEmpty else { return true }
        confirmDiscard(message: "有 \(changed.count) 个文件尚未保存，关闭窗口会丢失这些修改。") { [weak self] in
            self?.documents.removeAll()
            self?.selectedID = nil
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        documents.removeAll()
        selectedID = nil
        window = nil
    }

    private func confirmDiscard(message: String, action: @escaping () -> Void) {
        guard let window else { return }
        confirmingClose = true
        let alert = NSAlert()
        alert.messageText = "文件尚未保存"
        alert.informativeText = message
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃修改")
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.confirmingClose = false
            if response == .alertSecondButtonReturn { action() }
        }
    }
}

private struct RemoteEditorWorkspace: View {
    @ObservedObject var editor: RemoteEditorWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(editor.documents) { document in
                        RemoteEditorTab(document: document, selected: editor.selectedID == document.id,
                                        onSelect: { editor.selectedID = document.id },
                                        onClose: { editor.close(document) })
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
            }
            Menu {
                Toggle("显示文件信息和工具栏", isOn: $editor.showsInfoBar)
                Button("查找（⌘F）") { editor.showsFind = true }
                Button("保存（⌘S）") {
                    editor.documents.first(where: { $0.id == editor.selectedID })?.save()
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 24).padding(.trailing, 12).help("编辑器选项")
            }
            Divider()
            if let document = editor.documents.first(where: { $0.id == editor.selectedID }) {
                RemoteEditorView(document: document, onClose: { editor.close(document) }, showsFind: $editor.showsFind, showsInfoBar: editor.showsInfoBar)
                    .id(document.id)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct RemoteEditorTab: View {
    @ObservedObject var document: RemoteEditorDocument
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(document.session.fileName).lineLimit(1)
                    if document.hasChanges { Circle().frame(width: 5, height: 5) }
                    if document.saving { ProgressView().controlSize(.mini) }
                }.frame(minWidth: 110, maxWidth: 220, alignment: .leading)
            }.buttonStyle(.plain)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).disabled(document.saving).help("关闭文件")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10).frame(height: 30)
        .background(selected ? Color.accentColor.opacity(0.13) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        .help("\(document.session.profile.name) · \(document.session.path)")
    }
}

struct RemoteEditorView: View {
    @ObservedObject var document: RemoteEditorDocument
    let onClose: () -> Void
    @Binding var showsFind: Bool
    let showsInfoBar: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsInfoBar {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(document.session.fileName).font(.system(size: 14, weight: .semibold))
                    Text("\(document.session.profile.name) · \(document.session.path)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if document.saving { ProgressView().controlSize(.small) }
                Button("查找", systemImage: "magnifyingglass") { showsFind = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("保存", systemImage: "square.and.arrow.down") { document.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(document.saving || !document.hasChanges)
                Button("关闭", action: onClose).disabled(document.saving)
            }
            .padding(.horizontal, 16).frame(height: 52)
            Divider()
            }
            if #available(macOS 26.0, *) {
                TextEditor(text: $document.text)
                    .font(.system(size: 12, design: .monospaced))
                    .findNavigator(isPresented: $showsFind).padding(8)
            } else {
                TextEditor(text: $document.text)
                    .font(.system(size: 12, design: .monospaced)).padding(8)
            }
        }
        .alert("保存失败", isPresented: Binding(get: { document.errorMessage != nil }, set: { if !$0 { document.errorMessage = nil } })) {
            Button("好", role: .cancel) { document.errorMessage = nil }
        } message: { Text(document.errorMessage ?? "") }
    }
}

private final class RemoteTextWindow: NSWindow {
    var commandHandler: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased(),
           commandHandler?(key) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
