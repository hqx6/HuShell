import SwiftUI
import AppKit

private enum FileBrowserMode: String, CaseIterable {
    case columns, list
}

enum FilePanelPosition: String {
    case bottom, right
}

private struct DeleteRequest {
    let file: RemoteFile
    let fast: Bool
}

struct ConnectionPane: View {
    @ObservedObject var tab: ConnectionTab
    @ObservedObject private var transferCenter: TransferCenter
    let showsFiles: Bool
    let filePanelPosition: FilePanelPosition
    @State private var showsNewFolder = false
    @State private var newFolderName = ""
    @State private var browserMode: FileBrowserMode = .list
    @State private var columnWidths: [String: CGFloat] = [:]
    @State private var fileSort = RemoteFileSort()
    @State private var showsTransfers = false
    @State private var isDropTargeted = false
    @State private var editingPath = false
    @State private var pathInput = ""
    @FocusState private var pathFocused: Bool
    @State private var newFileName = ""
    @State private var showsNewFile = false
    @State private var renameFile: RemoteFile?
    @State private var renameName = ""
    @State private var permissionsFile: RemoteFile?
    @State private var permissionsMode = ""
    @State private var deleteRequest: DeleteRequest?
    @State private var openingFile = false

    init(tab: ConnectionTab, showsFiles: Bool, filePanelPosition: FilePanelPosition) {
        _tab = ObservedObject(wrappedValue: tab)
        _transferCenter = ObservedObject(wrappedValue: tab.transferCenter)
        self.showsFiles = showsFiles
        self.filePanelPosition = filePanelPosition
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsFiles {
                    if filePanelPosition == .right {
                        ResizableSplit(axis: .horizontal, minimumFirst: 400, minimumSecond: 500) {
                            terminalPanel
                        } second: { filePanel }
                    } else {
                        ResizableSplit(axis: .vertical, minimumFirst: 260, minimumSecond: 210) {
                            terminalPanel
                        } second: { filePanel }
                    }
                } else {
                    terminalPanel
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
        }
        .alert("操作失败", isPresented: Binding(get: { tab.errorMessage != nil }, set: { if !$0 { tab.errorMessage = nil } })) {
            Button("好", role: .cancel) { tab.errorMessage = nil }
        } message: { Text(tab.errorMessage ?? "") }
        .alert("新建文件夹", isPresented: $showsNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { tab.makeDirectory(newFolderName) }
            Button("取消", role: .cancel) { }
        } message: { Text("将在当前远端目录中创建") }
        .alert("新建文件", isPresented: $showsNewFile) {
            TextField("文件名", text: $newFileName)
            Button("创建") { tab.createFile(newFileName) }
            Button("取消", role: .cancel) { }
        } message: { Text("将在当前远端目录中创建空文件") }
        .alert("重命名", isPresented: Binding(get: { renameFile != nil }, set: { if !$0 { renameFile = nil } })) {
            TextField("新名称", text: $renameName)
            Button("保存") { if let file = renameFile { tab.rename(file, to: renameName) }; renameFile = nil }
            Button("取消", role: .cancel) { renameFile = nil }
        } message: { Text(renameFile?.name ?? "") }
        .alert("文件权限", isPresented: Binding(get: { permissionsFile != nil }, set: { if !$0 { permissionsFile = nil } })) {
            TextField("例如 644", text: $permissionsMode)
            Button("应用") { if let file = permissionsFile { tab.changePermissions(file, mode: permissionsMode) }; permissionsFile = nil }
            Button("取消", role: .cancel) { permissionsFile = nil }
        } message: { Text("输入 3 或 4 位八进制权限") }
        .confirmationDialog("确认删除", isPresented: Binding(get: { deleteRequest != nil }, set: { if !$0 { deleteRequest = nil } })) {
            Button(deleteRequest?.fast == true ? "快速删除" : "删除", role: .destructive) {
                if let request = deleteRequest { tab.remove(request.file, fast: request.fast) }
                deleteRequest = nil
            }
            Button("取消", role: .cancel) { deleteRequest = nil }
        } message: {
            Text(deleteRequest?.fast == true
                 ? "将用 rm -rf 永久删除“\(deleteRequest?.file.name ?? "")”及其内容。"
                 : "将永久删除“\(deleteRequest?.file.name ?? "")”。普通删除仅能删除空文件夹。")
        }
    }

    private var terminalPanel: some View {
        TerminalView(content: tab.terminalText, findRequest: tab.findRequest,
                     onInput: { tab.terminal.send($0) },
                     onResize: { columns, rows in tab.terminal.resize(columns: columns, rows: rows) })
        .padding(.bottom, 14)
        .background(Color(red: 0.055, green: 0.105, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var pathBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.tint)
            if editingPath {
                TextField("输入远端文件夹路径", text: $pathInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .focused($pathFocused)
                    .onSubmit {
                        editingPath = false
                        tab.goToDirectory(pathInput)
                    }
                    .onExitCommand { editingPath = false }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(RemotePath.breadcrumbs(tab.directory), id: \.path) { crumb in
                            Text(crumb.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(crumb.path == tab.directory ? Color.primary : Color.accentColor)
                                .padding(.horizontal, 3).padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .overlay(FileRowClickObserver(onSelect: {
                                    tab.goToDirectory(crumb.path)
                                }, onDoubleClick: { beginPathEdit() }))
                            if crumb.path != tab.directory {
                                Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .help("单击路径节点跳转；双击输入或粘贴路径")
                Button { beginPathEdit() } label: { fileToolbarIcon("pencil.line") }
                    .buttonStyle(.plain)
                    .modifier(GlassSurface(radius: 8))
                    .help("输入远端路径")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginPathEdit() {
        pathInput = tab.directory
        editingPath = true
        DispatchQueue.main.async { pathFocused = true }
    }

    private var filePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                pathBar
                Spacer()
                if tab.busy || openingFile { ProgressView().controlSize(.small) }
                HStack(spacing: 2) {
                    viewModeButton(.columns, symbol: "rectangle.split.3x1", label: "分栏视图")
                    viewModeButton(.list, symbol: "list.bullet", label: "列表视图")
                }
                .padding(2)
                .modifier(GlassSurface(radius: 9))
                .help("切换分栏或列表视图")
                Menu {
                    ForEach(RemoteFileSortKey.allCases, id: \.self) { key in
                        Button {
                            fileSort.select(key)
                        } label: {
                            if fileSort.key == key {
                                Label(key.rawValue, systemImage: fileSort.ascending ? "arrow.up" : "arrow.down")
                            } else { Text(key.rawValue) }
                        }
                    }
                } label: {
                    fileToolbarIcon("arrow.up.arrow.down")
                }
                .buttonStyle(.plain)
                .modifier(GlassSurface(radius: 8))
                .help("排序：\(fileSort.key.rawValue)\(fileSort.ascending ? "升序" : "降序")")
                Button { showsTransfers = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down.circle")
                        if transferCenter.activeCount > 0 {
                            Text("\(transferCenter.activeCount)").font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .frame(minWidth: 28).frame(height: 28)
                    .background(Color.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .modifier(GlassSurface(radius: 8))
                .help("上传与下载列表")
                .accessibilityLabel("传输列表")
                .popover(isPresented: $showsTransfers) { TransferCenterView(center: transferCenter) }
                fileButton("arrow.up.doc", help: "上传文件", enabled: tab.connected && !tab.busy, action: upload)
                fileButton("arrow.down.doc", help: "下载选中文件", enabled: tab.connected && tab.selectedFile != nil && !tab.busy, action: downloadSelected)
                fileButton("folder.badge.plus", help: "新建文件夹", enabled: tab.connected && !tab.busy) {
                    newFolderName = ""; showsNewFolder = true
                }
                fileButton("arrow.clockwise", help: "刷新文件", enabled: tab.connected && !tab.busy) { tab.loadFiles() }
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            if browserMode == .columns { columnBrowser }
            else { listBrowser }
        }
        .onChange(of: browserMode) { _, mode in tab.setColumnMode(mode == .columns) }
        .onChange(of: tab.connected) { _, connected in
            if connected && browserMode == .columns { tab.showColumns() }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isDropTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .overlay {
            if isDropTargeted {
                Text("松开以上传文件")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .allowsHitTesting(false)
            }
        }
    }

    private var listBrowser: some View {
        VStack(spacing: 0) {
            HStack {
                sortHeader(.name).frame(maxWidth: .infinity, alignment: .leading)
                sortHeader(.size).frame(width: 85, alignment: .trailing)
                sortHeader(.modified).frame(width: 150, alignment: .trailing)
                Text("权限").frame(width: 96, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).frame(height: 30)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if tab.directory != "/" && tab.directory != "." {
                        fileRow(RemoteFile(name: "..", isDirectory: true, size: "", modified: "", permissions: ""))
                    }
                    ForEach(fileSort.files(tab.files)) { file in fileRow(file) }
                    if tab.connected && tab.files.isEmpty && !tab.busy {
                        ContentUnavailableView("目录为空", systemImage: "folder", description: Text("可以将文件拖到此处上传"))
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                    if !tab.connected {
                        ContentUnavailableView("尚未连接", systemImage: "folder", description: Text("连接后可浏览、上传和下载文件"))
                            .frame(maxWidth: .infinity, minHeight: 130)
                    }
                }
                .background(CompactScrollIndicators())
            }
        }
    }

    private var columnBrowser: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(Array(tab.columns.enumerated()), id: \.element.id) { index, column in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                if tab.loadingDirectories.contains(column.path) && column.files.isEmpty {
                                    ProgressView("正在加载…").controlSize(.small)
                                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                                } else if let error = tab.directoryErrors[column.path] {
                                    Text(error).font(.caption).foregroundStyle(.secondary).padding(8)
                                    Button("重试") { tab.retryDirectory(column.path) }.buttonStyle(.borderless)
                                } else if column.files.isEmpty {
                                    Text("目录为空").font(.caption).foregroundStyle(.secondary).padding(.vertical, 20)
                                }
                                ForEach(fileSort.files(column.files)) { file in
                                    columnRow(file, index: index, selected: column.selectedName == file.name)
                                }
                            }
                            .padding(.vertical, 5)
                            .background(CompactScrollIndicators())
                        }
                        .frame(width: columnWidth(for: column.path))
                        .id(column.path)
                        SplitResizeHandle(axis: .horizontal, size: columnWidth(for: column.path)) { width in
                            columnWidths[column.path] = min(520, max(140, width))
                        }
                        .frame(width: 5)
                        .frame(maxHeight: .infinity)
                        .help("拖动调整目录宽度")
                        .accessibilityElement()
                        .accessibilityLabel("调整目录宽度")
                    }
                }
                .frame(maxHeight: .infinity)
                .background(CompactScrollIndicators())
            }
            .onChange(of: tab.columns.count) { _, _ in
                if let last = tab.columns.last { withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.path, anchor: .trailing) } }
            }
        }
    }

    private func columnWidth(for path: String) -> CGFloat {
        columnWidths[path] ?? 220
    }

    private func columnRow(_ file: RemoteFile, index: Int, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 17)
            Text(file.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if file.isDirectory { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 10).frame(height: 27)
        .background(selected ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .overlay(FileRowClickObserver(onSelect: {
            if file.isDirectory { tab.openColumnFolder(file, at: index) }
            else { tab.selectColumnFile(file, at: index) }
        }, onDoubleClick: {
            if !file.isDirectory { open(file) }
        }))
        .contextMenu { fileContextMenu(file, columnIndex: index) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard tab.connected else { return false }
        let group = DispatchGroup()
        var dropped: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { dropped.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            tab.upload(dropped)
            if !dropped.isEmpty { showsTransfers = true }
        }
        return true
    }

    private func fileButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { fileToolbarIcon(symbol) }
            .buttonStyle(.plain)
            .modifier(GlassSurface(radius: 8))
            .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
            .disabled(!enabled).help(help)
    }

    private func fileToolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(0.001), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func viewModeButton(_ mode: FileBrowserMode, symbol: String, label: String) -> some View {
        Button { browserMode = mode } label: {
            Image(systemName: symbol)
                .frame(width: 46, height: 24)
                .background(browserMode == mode ? Color.primary.opacity(0.12) : Color.primary.opacity(0.001),
                            in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func fileRow(_ file: RemoteFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(file.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(file.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(file.isDirectory ? "—" : formattedSize(file.size)).frame(width: 85, alignment: .trailing)
            Text(file.modified).frame(width: 150, alignment: .trailing)
            Text(file.permissions).frame(width: 96, alignment: .trailing)
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 18).frame(height: 29)
        .background(tab.selectedFile == file.name && file.name != ".." ? Color.accentColor.opacity(0.13) : .clear)
        .contentShape(Rectangle())
        .overlay(FileRowClickObserver(onSelect: {
            tab.selectedFile = file.name == ".." ? nil : file.name
        }, onDoubleClick: { open(file) }))
        .contextMenu { fileContextMenu(file) }
    }

    private func formattedSize(_ raw: String) -> String {
        guard let bytes = Int64(raw) else { return raw }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func sortHeader(_ key: RemoteFileSortKey) -> some View {
        Button {
            fileSort.select(key)
        } label: {
            HStack(spacing: 3) {
                Text(key.rawValue)
                if fileSort.key == key {
                    Image(systemName: fileSort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: key == .name ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(key.rawValue)排序")
    }

    @ViewBuilder private func fileContextMenu(_ file: RemoteFile, columnIndex: Int? = nil) -> some View {
        if file.name == ".." {
            Button("上一级") { tab.navigate("..") }
            Button("刷新", systemImage: "arrow.clockwise") { tab.loadFiles() }
        } else {
        Button("刷新", systemImage: "arrow.clockwise") { tab.loadFiles() }
        Button("打开", systemImage: "arrow.up.right.square") {
            selectForAction(file, columnIndex: columnIndex)
            open(file)
        }
        if !file.isDirectory {
            Menu("打开方式") {
                Button("本机默认应用") {
                    selectForAction(file, columnIndex: columnIndex)
                    openExternal(file, with: nil)
                }
                Button("选择本机应用…") {
                    selectForAction(file, columnIndex: columnIndex)
                    chooseApplication(for: file)
                }
            }
            Button("选择文本编辑器") {
                selectForAction(file, columnIndex: columnIndex)
                open(file)
            }
        }
        Divider()
        Button("复制路径", systemImage: "document.on.document") {
            selectForAction(file, columnIndex: columnIndex)
            let path = RemotePath.joined(tab.directory, file.name)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        if !file.isDirectory {
            Button("下载…", systemImage: "arrow.down.doc") {
                selectForAction(file, columnIndex: columnIndex)
                download(file)
            }
        }
        Button("上传…", systemImage: "arrow.up.doc") {
            selectForAction(file, columnIndex: columnIndex)
            upload()
        }
        Button("打包传输…", systemImage: "archivebox") {
            selectForAction(file, columnIndex: columnIndex)
            archiveTransfer(file)
        }
        Menu("新建") {
            Button("文件夹") { selectForAction(file, columnIndex: columnIndex); newFolderName = ""; showsNewFolder = true }
            Button("空文件") { selectForAction(file, columnIndex: columnIndex); newFileName = ""; showsNewFile = true }
        }
        Divider()
        Button("重命名…", systemImage: "pencil") {
            selectForAction(file, columnIndex: columnIndex)
            renameName = file.name
            renameFile = file
        }
        Button("删除…", systemImage: "trash", role: .destructive) {
            selectForAction(file, columnIndex: columnIndex)
            deleteRequest = DeleteRequest(file: file, fast: false)
        }
        Button("快速删除（rm 命令）…", role: .destructive) {
            selectForAction(file, columnIndex: columnIndex)
            deleteRequest = DeleteRequest(file: file, fast: true)
        }
        Button("文件权限…", systemImage: "lock") {
            selectForAction(file, columnIndex: columnIndex)
            permissionsMode = file.isDirectory ? "755" : "644"
            permissionsFile = file
        }
        }
    }

    private func selectForAction(_ file: RemoteFile, columnIndex: Int?) {
        if let columnIndex { tab.selectColumnFile(file, at: columnIndex) }
        else { tab.selectedFile = file.name }
    }

    private func open(_ file: RemoteFile) {
        if file.isDirectory { tab.navigate(file.name) }
        else if RemoteDocumentPolicy.canEdit(file) { openDownloaded(file, application: nil, tryEditor: true) }
        else { openExternal(file, with: nil) }
    }

    private func openExternal(_ file: RemoteFile, with application: URL?) {
        openDownloaded(file, application: application, tryEditor: false)
    }

    private func chooseApplication(for file: RemoteFile) {
        let panel = NSOpenPanel()
        panel.message = "选择用于打开 \(file.name) 的本机应用"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        guard panel.runModal() == .OK, let application = panel.url else { return }
        openExternal(file, with: application)
    }

    private func openDownloaded(_ file: RemoteFile, application: URL?, tryEditor: Bool) {
        guard tab.connected, !openingFile else { return }
        let profile = tab.profile
        let remote = RemotePath.joined(tab.directory, file.name)
        if tryEditor, RemoteEditorWindow.shared.activate(profileID: profile.id, path: remote) { return }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HuShell/Open/\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { tab.errorMessage = error.localizedDescription; return }
        let local = folder.appendingPathComponent(file.name)
        openingFile = true
        transferCenter.download(profile: profile, file: file, remote: remote, local: local) { result in
            switch result {
            case .failure(let error):
                openingFile = false
                tab.errorMessage = error.localizedDescription
            case .success:
                if tryEditor {
                    Task {
                        let text = await Task.detached { () -> String? in
                            guard let data = try? Data(contentsOf: local) else { return nil }
                            return RemoteDocumentPolicy.decode(data)
                        }.value
                        openingFile = false
                        if let text {
                            RemoteEditorWindow.shared.open(
                                RemoteEditorSession(profile: profile, path: remote,
                                                    fileName: file.name, localURL: local, initialText: text),
                                onSaved: { tab.loadFiles() })
                        } else { launchLocal(local, with: application) }
                    }
                } else {
                    openingFile = false
                    launchLocal(local, with: application)
                }
            }
        }
    }

    private func launchLocal(_ local: URL, with application: URL?) {
        if let application {
            NSWorkspace.shared.open([local], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { DispatchQueue.main.async { tab.errorMessage = error.localizedDescription } }
            }
        } else if !NSWorkspace.shared.open(local) {
            tab.errorMessage = "本机没有可打开此文件的应用"
        }
    }

    private func archiveTransfer(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name + ".tar.gz"
        guard panel.runModal() == .OK, let local = panel.url else { return }
        let profile = tab.profile
        let source = RemotePath.joined(tab.directory, file.name)
        openingFile = true
        Task {
            let result = await Task.detached { Result { () -> (String, Int64) in
                let remote = try SSHService.createArchive(profile: profile, source: source)
                let size = (try? SSHService.remoteFileSize(profile: profile, path: remote)) ?? 0
                return (remote, size)
            } }.value
            openingFile = false
            switch result {
            case .failure(let error): tab.errorMessage = error.localizedDescription
            case .success(let (remote, size)):
                let archive = RemoteFile(name: panel.nameFieldStringValue, isDirectory: false,
                                         size: String(size), modified: "", permissions: "")
                transferCenter.download(profile: profile, file: archive, remote: remote, local: local) { result in
                    Task.detached { SSHService.removeArchive(profile: profile, path: remote) }
                    if case .failure(let error) = result {
                        if let sshError = error as? SSHError, case .cancelled = sshError { return }
                        tab.errorMessage = error.localizedDescription
                    }
                }
                showsTransfers = true
            }
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        tab.upload(panel.urls)
        showsTransfers = true
    }

    private func downloadSelected() {
        guard let selected = tab.selectedFile, let file = tab.files.first(where: { $0.name == selected }) else { return }
        download(file)
    }

    private func download(_ file: RemoteFile) {
        guard !file.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tab.download(file, to: url)
        showsTransfers = true
    }
}
