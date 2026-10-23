import Foundation

struct SudoChallenge: Identifiable {
    let id = UUID()
    let action: String
    let target: String
}

@MainActor final class ConnectionTab: ObservableObject, Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let terminal = TerminalSession()
    let transferCenter: TransferCenter
    @Published var connected = false
    @Published var terminalText = ""
    @Published var findRequest = 0
    @Published var stats = HostStats()
    @Published var monitoredSections = HostMonitorSection.defaultExpanded
    @Published var files: [RemoteFile] = []
    @Published var columns: [RemoteColumn] = []
    @Published var directory = "/"
    @Published var selectedFile: String?
    @Published var busy = false
    @Published var status = "准备连接"
    @Published var errorMessage: String?
    @Published private(set) var sudoChallenge: SudoChallenge?
    private var sudoRetries: [(String) -> Void] = []
    var onConnect: (() -> Void)?
    var preferredDirectory: (() -> String?)?
    var onDirectoryChanged: ((String) -> Void)?
    private var generation = 0
    private var statsLoading = false
    @Published private(set) var loadingDirectories: Set<String> = []
    @Published private(set) var directoryErrors: [String: String] = [:]
    private var usesColumns = false
    private struct CachedDirectory {
        let files: [RemoteFile]
        let date: Date
    }
    private var directoryCache: [String: CachedDirectory] = [:]
    private var directoryRequests: [String: UUID] = [:]
    private let directoryLoader: @Sendable (ConnectionProfile, String) async throws -> [RemoteFile]
    private var homeDirectory = "/"
    private var homeDirectoryReady = false
    private var pendingRevealDirectory: String?

    func findInTerminal() { findRequest &+= 1 }

    init(profile: ConnectionProfile, transferCenter: TransferCenter,
         directoryLoader: @escaping @Sendable (ConnectionProfile, String) async throws -> [RemoteFile] = { profile, path in
             try await Task.detached { try SSHService.listDirectory(profile: profile, path: path) }.value
         }) {
        self.profile = profile
        self.transferCenter = transferCenter
        self.directoryLoader = directoryLoader
    }

    func connect() {
        disconnect()
        onConnect?()
        generation += 1
        terminalText = "正在连接 \(profile.endpoint)…\r\n"
        status = "正在连接"
        let generation = generation
        let profile = profile
        Task { [weak self] in
            let result = await Task.detached { Result { try CredentialBroker.shared.prepare(profile) } }.value
            guard let self, self.generation == generation else { return }
            switch result {
            case .success: self.startPreparedConnection()
            case .failure(let error):
                self.status = "需要密码"
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func startPreparedConnection() {
        terminal.onOutput = { [weak self] output in
            guard let self else { return }
            self.terminalText += output
            if self.terminalText.count > 250_000 { self.terminalText = String(self.terminalText.suffix(200_000)) }
            if self.connected { self.status = "已连接" }
        }
        terminal.onExit = { [weak self] code in
            guard let self else { return }
            self.connected = false
            self.status = "连接已断开"
            self.terminalText += "\r\n[连接结束，状态码 \(code)]\r\n"
        }
        do {
            try terminal.start(profile: profile)
            connected = true
            status = "已连接"
            directory = "/"
            stats = HostStats()
            files = []
            columns = []
            loadStats()
            loadHomeDirectory()
        } catch {
            connected = false
            status = "连接失败"
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        generation += 1
        directoryRequests.removeAll()
        directoryCache.removeAll()
        loadingDirectories.removeAll()
        directoryErrors.removeAll()
        statsLoading = false
        homeDirectoryReady = false
        pendingRevealDirectory = nil
        sudoChallenge = nil
        sudoRetries.removeAll()
        terminal.stop()
        connected = false
        status = "未连接"
        files = []
        columns = []
        stats = HostStats()
        busy = false
    }

    func refresh() { loadStats(); loadFiles() }

    func loadStats() {
        guard connected, !statsLoading, !monitoredSections.isEmpty else { return }
        statsLoading = true
        let profile = profile
        let generation = generation
        let sections = monitoredSections
        Task { [weak self] in
            let result = await Task.detached { Result { try SSHService.stats(profile: profile, sections: sections) } }.value
            guard let self, self.generation == generation, self.connected else { return }
            self.statsLoading = false
            guard self.monitoredSections == sections else { self.loadStats(); return }
            if case .success(let value) = result { self.stats = value }
        }
    }

    func toggleMonitorSection(_ section: HostMonitorSection) {
        if monitoredSections.contains(section) { monitoredSections.remove(section) }
        else { monitoredSections.insert(section) }
        loadStats()
    }

    func loadFiles() {
        guard connected else { return }
        // Explicit refresh and file mutations must not reuse stale ancestor listings.
        directoryCache.removeAll()
        requestDirectory(directory, force: true)
    }

    private func requestDirectory(_ path: String, force: Bool = false) {
        guard connected else { return }
        if !force {
            if directoryRequests[path] != nil { return }
            if let cached = directoryCache[path], Date().timeIntervalSince(cached.date) < 30 { return }
        }
        let request = UUID()
        directoryRequests[path] = request
        loadingDirectories.insert(path)
        directoryErrors[path] = nil
        busy = loadingDirectories.contains(directory)
        let generation = generation
        let profile = profile
        let loader = directoryLoader
        Task { [weak self] in
            let result: Result<[RemoteFile], Error>
            do { result = .success(try await loader(profile, path)) }
            catch { result = .failure(error) }
            guard let self, self.generation == generation,
                  self.directoryRequests[path] == request else { return }
            self.directoryRequests[path] = nil
            self.loadingDirectories.remove(path)
            self.busy = self.loadingDirectories.contains(self.directory)
            switch result {
            case .success(let value):
                self.directoryCache[path] = CachedDirectory(files: value, date: Date())
                if self.directoryCache.count > 64,
                   let oldest = self.directoryCache.min(by: { $0.value.date < $1.value.date })?.key {
                    self.directoryCache[oldest] = nil
                }
                if self.directory == path {
                    self.files = value
                    if let selected = self.selectedFile, !value.contains(where: { $0.name == selected }) {
                        self.selectedFile = nil
                    }
                }
                if let index = self.columns.firstIndex(where: { $0.path == path }) {
                    self.columns[index].files = value
                }
            case .failure(let error):
                self.directoryErrors[path] = error.localizedDescription
                if self.directory == path { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func retryDirectory(_ path: String) { requestDirectory(path, force: true) }

    private func loadHomeDirectory() {
        let profile = profile
        let generation = generation
        busy = true
        Task { [weak self] in
            let result = await Task.detached { Result { try SSHService.workingDirectory(profile: profile) } }.value
            guard let self, self.generation == generation else { return }
            self.busy = false
            switch result {
            case .success(let path):
                self.restoreDirectory(home: path)
            case .failure(let error):
                self.homeDirectoryReady = true
                let revealDirectory = self.pendingRevealDirectory
                self.pendingRevealDirectory = nil
                let destination = revealDirectory ?? self.preferredDirectory?()
                if let destination { self.goToDirectory(destination, remember: revealDirectory != nil) }
                else { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func restoreDirectory(home: String) {
        homeDirectory = home
        homeDirectoryReady = true
        let revealDirectory = pendingRevealDirectory
        pendingRevealDirectory = nil
        goToDirectory(revealDirectory ?? preferredDirectory?() ?? home, remember: revealDirectory != nil)
    }

    func revealDirectory(_ path: String) {
        if connected { goToDirectory(path) }
        if !homeDirectoryReady { pendingRevealDirectory = path }
    }

    func navigate(_ name: String) {
        goToDirectory(name)
    }

    func goToDirectory(_ input: String, remember: Bool = true) {
        guard connected else { return }
        guard let path = RemotePath.resolved(input, relativeTo: directory, home: homeDirectory) else {
            errorMessage = "请输入有效的文件夹路径"; return
        }
        if path == directory {
            if remember { onDirectoryChanged?(path) }
            if usesColumns { rebuildColumns() }
            requestDirectory(path)
            return
        }
        // Change the visible path immediately; SSH completion only supplies its contents.
        directory = path
        if remember { onDirectoryChanged?(path) }
        files = directoryCache[path]?.files ?? columns.first(where: { $0.path == path })?.files ?? []
        selectedFile = nil
        if usesColumns { rebuildColumns() }
        else { columns = [] }
        busy = loadingDirectories.contains(path)
        requestDirectory(path)
    }

    func setColumnMode(_ enabled: Bool) {
        usesColumns = enabled
        if enabled { showColumns() }
        else { columns = [] }
    }

    func showColumns() {
        usesColumns = true
        if directoryCache[directory] == nil && !files.isEmpty {
            directoryCache[directory] = CachedDirectory(files: files, date: Date())
        }
        rebuildColumns()
    }

    private func rebuildColumns() {
        let crumbs = RemotePath.breadcrumbs(directory)
        let previous = columns
        columns = crumbs.enumerated().map { index, crumb in
            RemoteColumn(path: crumb.path,
                         files: directoryCache[crumb.path]?.files
                            ?? (crumb.path == directory ? files : previous.first(where: { $0.path == crumb.path })?.files ?? []),
                         selectedName: index + 1 < crumbs.count ? crumbs[index + 1].name : selectedFile)
        }
        for crumb in crumbs { requestDirectory(crumb.path) }
    }

    func openColumnFolder(_ file: RemoteFile, at index: Int) {
        guard file.isDirectory, columns.indices.contains(index) else { return }
        goToDirectory(RemotePath.joined(columns[index].path, file.name))
    }

    func selectColumnFile(_ file: RemoteFile, at index: Int) {
        guard columns.indices.contains(index) else { return }
        columns = Array(columns.prefix(index + 1))
        columns[index].selectedName = file.name
        let path = columns[index].path
        if directory != path {
            directory = path
            onDirectoryChanged?(path)
        }
        files = columns[index].files
        selectedFile = file.name
        busy = loadingDirectories.contains(directory)
    }

    func upload(_ urls: [URL]) {
        guard connected, !urls.isEmpty else { return }
        let files = urls.filter { $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { errorMessage = "没有可上传的文件或文件夹"; return }
        let generation = generation
        status = "正在上传 \(files.count) 项"
        for url in files {
            let remote = RemotePath.joined(directory, url.lastPathComponent)
            transferCenter.upload(profile: profile, local: url, remote: remote) { [weak self] result in
                self?.finishUpload(result, local: url, remote: remote, generation: generation, allowSudo: true)
            }
        }
    }

    private func finishUpload(_ result: Result<Void, Error>, local: URL, remote: String,
                              generation: Int, allowSudo: Bool) {
        guard self.generation == generation else { return }
        switch result {
        case .success:
            status = "上传完成"
            loadFiles()
        case .failure(let error):
            if let sshError = error as? SSHError, case .cancelled = sshError {
                status = "上传已终止"
                loadFiles()
            } else if allowSudo && RemotePermission.isDenied(error) {
                status = "上传需要 sudo 权限"
                requestSudo(action: "上传", target: local.lastPathComponent) { [weak self] password in
                    guard let self, self.generation == generation else { return }
                    self.status = "正在使用 sudo 上传 \(local.lastPathComponent)"
                    self.transferCenter.uploadWithSudo(profile: self.profile, local: local, remote: remote,
                                                       password: password) { [weak self] result in
                        self?.finishUpload(result, local: local, remote: remote,
                                           generation: generation, allowSudo: false)
                    }
                }
            } else {
                status = "上传失败"
                errorMessage = TransferErrorSummary.upload(error)
            }
        }
    }

    func requestSudo(action: String, target: String, retry: @escaping (String) -> Void) {
        sudoRetries.append(retry)
        if sudoChallenge == nil { sudoChallenge = SudoChallenge(action: action, target: target) }
    }

    func retryWithSudo(password: String) {
        guard !password.isEmpty else { return }
        let retries = sudoRetries
        sudoRetries.removeAll()
        sudoChallenge = nil
        retries.forEach { $0(password) }
    }

    func cancelSudoRetry() {
        sudoRetries.removeAll()
        sudoChallenge = nil
    }

    func download(_ file: RemoteFile, to local: URL) {
        guard connected, !file.isDirectory else { return }
        let remote = RemotePath.joined(directory, file.name)
        let generation = generation
        status = "正在下载 \(file.name)"
        transferCenter.download(profile: profile, file: file, remote: remote, local: local) { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case .success: self.status = "下载完成"
            case .failure(let error):
                if let sshError = error as? SSHError, case .cancelled = sshError {
                    self.status = "下载已终止"
                } else {
                    self.status = "下载失败"
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func makeDirectory(_ name: String) {
        guard connected, validNewName(name) else { errorMessage = "请输入有效的文件夹名称"; return }
        let profile = profile
        let path = RemotePath.joined(directory, name)
        performFileOperation(action: "新建文件夹", target: name,
                             operation: { try SSHService.makeDirectory(profile: profile, path: path) },
                             sudoOperation: { try SSHService.makeDirectoryWithSudo(profile: profile, path: path,
                                                                                   password: $0) })
    }

    func createFile(_ name: String) {
        guard connected, validNewName(name) else { errorMessage = "请输入有效的文件名"; return }
        let profile = profile
        let path = RemotePath.joined(directory, name)
        performFileOperation(action: "新建文件", target: name,
                             operation: { try SSHService.createFile(profile: profile, path: path) },
                             sudoOperation: { try SSHService.createFileWithSudo(profile: profile, path: path,
                                                                                password: $0) })
    }

    func rename(_ file: RemoteFile, to name: String, in directory: String) {
        guard validNewName(name) else { errorMessage = "请输入有效的新名称"; return }
        let profile = profile
        let from = RemotePath.joined(directory, file.name)
        let to = RemotePath.joined(directory, name)
        performFileOperation(action: "重命名", target: file.name,
                             operation: { try SSHService.rename(profile: profile, from: from, to: to) },
                             sudoOperation: { try SSHService.renameWithSudo(profile: profile, from: from, to: to,
                                                                             password: $0) })
    }

    func remove(_ file: RemoteFile, fast: Bool) {
        let profile = profile
        let path = RemotePath.joined(directory, file.name)
        performFileOperation(action: "删除", target: file.name, errorSummary: TransferErrorSummary.delete,
                             operation: {
                                 if fast { try SSHService.fastRemove(profile: profile, path: path) }
                                 else { try SSHService.remove(profile: profile, path: path,
                                                              isDirectory: file.isDirectory) }
                             }, sudoOperation: {
                                 try SSHService.removeWithSudo(profile: profile, path: path,
                                                               isDirectory: file.isDirectory, fast: fast,
                                                               password: $0)
                             })
    }

    func changePermissions(_ file: RemoteFile, mode: String) {
        let profile = profile
        let path = RemotePath.joined(directory, file.name)
        performFileOperation(action: "修改权限", target: file.name,
                             operation: { try SSHService.changePermissions(profile: profile, path: path, mode: mode) },
                             sudoOperation: { try SSHService.changePermissionsWithSudo(profile: profile,
                                                                                         path: path, mode: mode,
                                                                                         password: $0) })
    }

    private func validNewName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
        !name.contains("\n") && !name.contains("\r")
    }

    private func performFileOperation(action: String, target: String,
                                      errorSummary: ((Error) -> String)? = nil,
                                      operation: @escaping () throws -> Void,
                                      sudoOperation: @escaping (String) throws -> Void,
                                      password: String? = nil) {
        guard connected else { return }
        let generation = generation
        busy = true
        Task { [weak self] in
            let result = await Task.detached { Result {
                if let password { try sudoOperation(password) }
                else { try operation() }
            } }.value
            guard let self, self.generation == generation else { return }
            self.busy = false
            switch result {
            case .success: self.loadFiles()
            case .failure(let error):
                if password == nil && RemotePermission.isDenied(error) {
                    self.requestSudo(action: action, target: target) { [weak self] password in
                        self?.performFileOperation(action: action, target: target, errorSummary: errorSummary,
                                                   operation: operation, sudoOperation: sudoOperation,
                                                   password: password)
                    }
                } else {
                    self.errorMessage = errorSummary?(error) ?? TransferErrorSummary.operation(error, action: action)
                }
            }
        }
    }

    deinit { terminal.stop() }
}
