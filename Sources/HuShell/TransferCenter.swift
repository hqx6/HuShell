import SwiftUI
import Foundation

enum TransferDirection: String {
    case upload = "上传"
    case download = "下载"
}

enum TransferPhase: String {
    case waiting = "等待中"
    case running = "传输中"
    case completed = "已完成"
    case failed = "失败"
    case cancelled = "已终止"
}

enum TransferDestination {
    case remote(profile: ConnectionProfile, filePath: String)
    case remoteDirectory(profile: ConnectionProfile, path: String)
    case local(fileURL: URL)
}

private final class DirectoryUploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: Int64?
    private var localBytes: Int64?

    func prepare(profile: ConnectionProfile, local: URL, path: String, cancellation: TransferCancellation) {
        let total = LocalTransferSize.directory(local)
        lock.lock()
        localBytes = total
        lock.unlock()
        let size = (try? SSHService.remoteDirectorySize(profile: profile, path: path,
                                                        cancellation: cancellation)) ?? 0
        lock.lock()
        baseline = size
        lock.unlock()
    }

    var totalBytes: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return localBytes
    }

    func bytesUploaded(profile: ConnectionProfile, path: String) -> Int64? {
        lock.lock()
        let initial = baseline
        lock.unlock()
        guard let initial, let current = try? SSHService.remoteDirectorySize(profile: profile, path: path) else {
            return nil
        }
        return max(current - initial, 0)
    }
}

private final class SudoUploadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let isDirectory: Bool
    private var stagingPath: String?
    private var size: Int64?

    init(isDirectory: Bool) { self.isDirectory = isDirectory }

    func prepare(local: URL) {
        let total = isDirectory ? LocalTransferSize.directory(local)
            : ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? 0
        lock.lock()
        size = total
        lock.unlock()
    }

    func setStagingPath(_ path: String) {
        lock.lock()
        stagingPath = path
        lock.unlock()
    }

    var totalBytes: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return size
    }

    func bytesUploaded(profile: ConnectionProfile) -> Int64? {
        lock.lock()
        let path = stagingPath
        lock.unlock()
        guard let path else { return nil }
        if isDirectory { return try? SSHService.remoteDirectorySize(profile: profile, path: path) }
        return try? SSHService.remoteFileSize(profile: profile, path: path)
    }
}

struct TransferRecord: Identifiable {
    let id: UUID
    let direction: TransferDirection
    let profileName: String
    let fileName: String
    let destination: TransferDestination
    var totalBytes: Int64
    var completedBytes: Int64 = 0
    var bytesPerSecond: Double = 0
    var phase: TransferPhase = .waiting
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?
    var lastSampleAt: Date?
    var lastSampleBytes: Int64 = 0

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    func estimatedRemainingSeconds() -> Int? {
        guard phase == .running, totalBytes > completedBytes, bytesPerSecond > 1 else { return nil }
        let seconds = Double(totalBytes - completedBytes) / bytesPerSecond
        guard seconds.isFinite, seconds < 365 * 24 * 60 * 60 else { return nil }
        return max(Int(ceil(seconds)), 1)
    }
}

@MainActor final class TransferCenter: ObservableObject {
    @Published private(set) var items: [TransferRecord] = []
    private var cancellations: [UUID: TransferCancellation] = [:]
    private struct PendingTransfer {
        let id: UUID
        let launch: () -> Void
        let completion: @MainActor (Result<Void, Error>) -> Void
    }
    private var pending: [PendingTransfer] = []
    private var running: Set<UUID> = []
    private let maximumConcurrentTransfers = 2

    var activeCount: Int { items.filter { $0.phase == .waiting || $0.phase == .running }.count }

    func upload(profile: ConnectionProfile, local: URL, remote: String,
                completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else {
            completion(.failure(SSHError.command("本地文件或文件夹已不存在")))
            return
        }
        if isDirectory.boolValue {
            let progress = DirectoryUploadProgress()
            let id = add(direction: .upload, profile: profile, fileName: local.lastPathComponent,
                         destination: .remoteDirectory(profile: profile, path: remote), totalBytes: 0)
            start(id: id, profile: profile, monitor: .remoteDirectory(remote, progress),
                  operation: { cancellation in
                      progress.prepare(profile: profile, local: local, path: remote, cancellation: cancellation)
                      try SSHService.uploadDirectory(profile: profile, local: local,
                                                     remoteParent: RemotePath.parent(remote),
                                                     cancellation: cancellation)
                  }, completion: completion)
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let id = add(direction: .upload, profile: profile, fileName: local.lastPathComponent,
                     destination: .remote(profile: profile, filePath: remote), totalBytes: size)
        start(id: id, profile: profile, monitor: .remote(remote),
              operation: { cancellation in
                  try SSHService.upload(profile: profile, local: local, remote: remote, cancellation: cancellation)
              },
              completion: completion)
    }

    func uploadWithSudo(profile: ConnectionProfile, local: URL, remote: String, password: String,
                        completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: local.path, isDirectory: &isDirectory) else {
            completion(.failure(SSHError.command("本地文件或文件夹已不存在")))
            return
        }
        let progress = SudoUploadProgress(isDirectory: isDirectory.boolValue)
        let destination: TransferDestination = isDirectory.boolValue
            ? .remoteDirectory(profile: profile, path: remote)
            : .remote(profile: profile, filePath: remote)
        let id = add(direction: .upload, profile: profile, fileName: local.lastPathComponent,
                     destination: destination, totalBytes: 0)
        start(id: id, profile: profile, monitor: .stagedUpload(progress),
              operation: { cancellation in
                  progress.prepare(local: local)
                  try SSHService.uploadWithSudo(profile: profile, local: local, remote: remote,
                                                password: password, cancellation: cancellation,
                                                onStaged: progress.setStagingPath)
              }, completion: completion)
    }

    func download(profile: ConnectionProfile, file: RemoteFile, remote: String, local: URL,
                  completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let id = add(direction: .download, profile: profile, fileName: file.name,
                     destination: .local(fileURL: local), totalBytes: Int64(file.size) ?? 0)
        start(id: id, profile: profile, monitor: .local(local),
              operation: { cancellation in
                  try SSHService.download(profile: profile, remote: remote, local: local, cancellation: cancellation)
              },
              completion: completion)
    }

    func clearFinished() {
        items.removeAll { $0.phase == .completed || $0.phase == .failed || $0.phase == .cancelled }
    }

    func cancel(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }),
              item.phase == .waiting || item.phase == .running else { return }
        change(id) {
            $0.phase = .cancelled
            $0.finishedAt = Date()
            $0.bytesPerSecond = 0
        }
        cancellations[id]?.cancel()
        if let index = pending.firstIndex(where: { $0.id == id }) {
            let transfer = pending.remove(at: index)
            cancellations.removeValue(forKey: id)
            transfer.completion(.failure(SSHError.cancelled))
        }
    }

    func cancelAll() {
        let activeIDs = items.filter { $0.phase == .waiting || $0.phase == .running }.map(\.id)
        activeIDs.forEach(cancel)
    }

    private func add(direction: TransferDirection, profile: ConnectionProfile,
                     fileName: String, destination: TransferDestination, totalBytes: Int64) -> UUID {
        let id = UUID()
        items.insert(TransferRecord(id: id, direction: direction, profileName: profile.name,
                                    fileName: fileName, destination: destination, totalBytes: totalBytes), at: 0)
        return id
    }

    private enum MonitorSource {
        case local(URL)
        case remote(String)
        case remoteDirectory(String, DirectoryUploadProgress)
        case stagedUpload(SudoUploadProgress)

        var keepsProgressIncomplete: Bool {
            switch self {
            case .remoteDirectory, .stagedUpload: return true
            default: return false
            }
        }
    }

    private func start(id: UUID, profile: ConnectionProfile, monitor: MonitorSource,
                       operation: @escaping (TransferCancellation) throws -> Void,
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let cancellation = TransferCancellation()
        cancellations[id] = cancellation
        pending.append(PendingTransfer(id: id, launch: { [weak self] in
            self?.run(id: id, profile: profile, monitor: monitor, operation: operation,
                      completion: completion, cancellation: cancellation)
        }, completion: completion))
        startPendingTransfers()
    }

    private func startPendingTransfers() {
        while running.count < maximumConcurrentTransfers && !pending.isEmpty {
            let transfer = pending.removeFirst()
            guard items.contains(where: { $0.id == transfer.id && $0.phase == .waiting }) else { continue }
            running.insert(transfer.id)
            change(transfer.id) { item in
                item.phase = .running
                item.startedAt = Date()
                item.lastSampleAt = item.startedAt
            }
            transfer.launch()
        }
    }

    private func run(id: UUID, profile: ConnectionProfile, monitor: MonitorSource,
                     operation: @escaping (TransferCancellation) throws -> Void,
                     completion: @escaping @MainActor (Result<Void, Error>) -> Void,
                     cancellation: TransferCancellation) {
        Task { [weak self] in
            guard let self else { return }
            let poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if Task.isCancelled { break }
                    let bytes = await Task.detached(priority: .utility) { () -> Int64? in
                        switch monitor {
                        case .local(let url):
                            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
                        case .remote(let path):
                            return try? SSHService.remoteFileSize(profile: profile, path: path)
                        case .remoteDirectory(let path, let progress):
                            return progress.bytesUploaded(profile: profile, path: path)
                        case .stagedUpload(let progress):
                            return progress.bytesUploaded(profile: profile)
                        }
                    }.value
                    if case .remoteDirectory(_, let progress) = monitor,
                       let total = progress.totalBytes {
                        self?.change(id) { $0.totalBytes = total }
                    }
                    if case .stagedUpload(let progress) = monitor,
                       let total = progress.totalBytes {
                        self?.change(id) { $0.totalBytes = total }
                    }
                    if let bytes {
                        self?.sample(id, bytes: bytes, keepIncomplete: monitor.keepsProgressIncomplete)
                    }
                }
            }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try operation(cancellation) }
            }.value
            poller.cancel()
            self.cancellations.removeValue(forKey: id)
            if case .remoteDirectory(_, let progress) = monitor,
               let total = progress.totalBytes {
                self.change(id) { $0.totalBytes = total }
            }
            if case .stagedUpload(let progress) = monitor,
               let total = progress.totalBytes {
                self.change(id) { $0.totalBytes = total }
            }
            self.change(id) { item in
                item.phase = cancellation.isCancelled ? .cancelled : result.isSuccess ? .completed : .failed
                item.finishedAt = Date()
                if result.isSuccess && !cancellation.isCancelled {
                    item.completedBytes = item.totalBytes > 0 ? item.totalBytes : item.completedBytes
                    let duration = max(item.finishedAt!.timeIntervalSince(item.startedAt ?? item.finishedAt!), 0.001)
                    item.bytesPerSecond = Double(item.completedBytes) / duration
                } else if !cancellation.isCancelled, case .failure(let error) = result {
                    item.error = error.localizedDescription
                }
            }
            completion(cancellation.isCancelled ? .failure(SSHError.cancelled) : result)
            self.running.remove(id)
            self.startPendingTransfers()
        }
    }

    private func sample(_ id: UUID, bytes: Int64, keepIncomplete: Bool = false) {
        change(id) { item in
            guard item.phase == .running else { return }
            let now = Date()
            let elapsed = max(now.timeIntervalSince(item.lastSampleAt ?? now), 0.001)
            let limit = keepIncomplete && item.totalBytes > 0 ? item.totalBytes - 1 : item.totalBytes
            let next = item.totalBytes > 0 ? min(max(bytes, 0), limit) : max(bytes, 0)
            let instantSpeed = max(Double(next - item.lastSampleBytes) / elapsed, 0)
            item.bytesPerSecond = instantSpeed > 0
                ? (item.bytesPerSecond > 0 ? item.bytesPerSecond * 0.65 + instantSpeed * 0.35 : instantSpeed)
                : item.bytesPerSecond * 0.5
            item.completedBytes = next
            item.lastSampleBytes = next
            item.lastSampleAt = now
        }
    }

    private func change(_ id: UUID, _ action: (inout TransferRecord) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        action(&items[index])
    }
}

private extension Result where Success == Void {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

struct TransferCenterView: View {
    private static let completionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @ObservedObject var center: TransferCenter
    let onOpenRemote: (ConnectionProfile, String) -> Void
    @State private var locationError: String?
    @State private var hoveredItem: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件传输").font(.system(size: 15, weight: .semibold))
                if center.activeCount > 0 {
                    Text("\(center.activeCount) 项进行中").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("全部终止") { center.cancelAll() }
                    .font(.system(size: 11)).disabled(center.activeCount == 0)
                Button("清除记录") { center.clearFinished() }
                    .font(.system(size: 11)).disabled(center.items.allSatisfy { $0.phase == .running || $0.phase == .waiting })
            }
            .padding(15)
            Divider()
            if center.items.isEmpty {
                ContentUnavailableView("暂无传输", systemImage: "arrow.up.arrow.down", description: Text("拖入文件或文件夹，或使用上传、下载按钮开始传输"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(center.items) { item in
                            transferRow(item)
                            Divider().padding(.leading, 54)
                        }
                    }
                }
            }
        }
        .frame(width: 470, height: 420)
        .background(Color(nsColor: NSColor.windowBackgroundColor.withAlphaComponent(1)))
        .alert("无法打开所在目录", isPresented: Binding(get: { locationError != nil },
                                                set: { if !$0 { locationError = nil } })) {
            Button("好", role: .cancel) { locationError = nil }
        } message: { Text(locationError ?? "") }
    }

    private func transferRow(_ item: TransferRecord) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button { openLocation(of: item) } label: {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: item.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                        .foregroundStyle(item.phase == .failed ? Color.red : Color.accentColor)
                        .frame(width: 31, height: 31)
                        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            if item.phase == .completed, let finishedAt = item.finishedAt {
                                Text(Self.completionTimeFormatter.string(from: finishedAt))
                                    .font(.system(size: 10))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            }
                            Text(item.phase.rawValue).foregroundStyle(item.phase == .failed ? .red : .secondary)
                            Image(systemName: "folder").foregroundStyle(.secondary)
                                .font(.system(size: 10))
                        }
                        HStack {
                            Text("\(item.direction.rawValue) · \(item.profileName)")
                            Spacer()
                            Text(progressText(item)).lineLimit(1)
                        }
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        if item.phase == .running || item.phase == .waiting {
                            if let fraction = item.fraction { ProgressView(value: fraction) }
                            else { ProgressView() }
                        } else if item.phase == .completed {
                            ProgressView(value: 1)
                        }
                        if let error = item.error {
                            Text(error).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开文件所在目录")
            .accessibilityLabel("打开 \(item.fileName) 所在目录")
            if item.phase == .running || item.phase == .waiting {
                Button("终止") { center.cancel(item.id) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("终止 \(item.fileName)")
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(hoveredItem == item.id ? Color.accentColor.opacity(0.07) : .clear)
        .onHover { hoveredItem = $0 ? item.id : nil }
    }

    private func openLocation(of item: TransferRecord) {
        switch item.destination {
        case .remote(let profile, let filePath):
            onOpenRemote(profile, RemotePath.parent(filePath))
        case .remoteDirectory(let profile, let path):
            onOpenRemote(profile, path)
        case .local(let fileURL):
            let directory = fileURL.deletingLastPathComponent()
            guard FileManager.default.fileExists(atPath: directory.path) else {
                locationError = "本地目录已不存在：\(directory.path)"
                return
            }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            } else if !NSWorkspace.shared.open(directory) {
                locationError = "无法打开本地目录：\(directory.path)"
            }
        }
    }

    private func progressText(_ item: TransferRecord) -> String {
        let done = ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)
        let total = item.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) : "—"
        let speed = item.phase == .running || item.phase == .completed
            ? ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file) + "/s"
            : "—"
        let remaining = remainingText(item).map { " · \($0)" } ?? ""
        return "\(done) / \(total) · \(speed)\(remaining)"
    }

    private func remainingText(_ item: TransferRecord) -> String? {
        if item.phase == .waiting { return "等待开始" }
        guard item.phase == .running else { return nil }
        guard item.totalBytes > 0 else { return "剩余未知" }
        guard let seconds = item.estimatedRemainingSeconds() else { return "剩余计算中" }
        if seconds >= 86_400 {
            let hours = (seconds % 86_400) / 3_600
            return "剩余约 \(seconds / 86_400)天" + (hours > 0 ? "\(hours)小时" : "")
        }
        if seconds >= 3_600 {
            let minutes = (seconds % 3_600) / 60
            return "剩余约 \(seconds / 3_600)小时" + (minutes > 0 ? "\(minutes)分" : "")
        }
        if seconds >= 60 {
            let remainder = seconds % 60
            return "剩余约 \(seconds / 60)分" + (remainder > 0 ? "\(remainder)秒" : "")
        }
        return "剩余约 \(seconds)秒"
    }
}
