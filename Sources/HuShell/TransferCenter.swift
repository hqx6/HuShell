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
}

struct TransferRecord: Identifiable {
    let id: UUID
    let direction: TransferDirection
    let profileName: String
    let fileName: String
    let totalBytes: Int64
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
}

@MainActor final class TransferCenter: ObservableObject {
    @Published private(set) var items: [TransferRecord] = []

    var activeCount: Int { items.filter { $0.phase == .waiting || $0.phase == .running }.count }

    func upload(profile: ConnectionProfile, local: URL, remote: String,
                completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: local.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let id = add(direction: .upload, profile: profile, fileName: local.lastPathComponent, totalBytes: size)
        start(id: id, profile: profile, monitor: .remote(remote),
              operation: { try SSHService.upload(profile: profile, local: local, remote: remote) },
              completion: completion)
    }

    func download(profile: ConnectionProfile, file: RemoteFile, remote: String, local: URL,
                  completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        let id = add(direction: .download, profile: profile, fileName: file.name,
                     totalBytes: Int64(file.size) ?? 0)
        start(id: id, profile: profile, monitor: .local(local),
              operation: { try SSHService.download(profile: profile, remote: remote, local: local) },
              completion: completion)
    }

    func clearFinished() {
        items.removeAll { $0.phase == .completed || $0.phase == .failed }
    }

    private func add(direction: TransferDirection, profile: ConnectionProfile,
                     fileName: String, totalBytes: Int64) -> UUID {
        let id = UUID()
        items.insert(TransferRecord(id: id, direction: direction, profileName: profile.name,
                                    fileName: fileName, totalBytes: totalBytes), at: 0)
        return id
    }

    private enum MonitorSource {
        case local(URL)
        case remote(String)
    }

    private func start(id: UUID, profile: ConnectionProfile, monitor: MonitorSource,
                       operation: @escaping () throws -> Void,
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            self.change(id) { item in
                item.phase = .running
                item.startedAt = Date()
                item.lastSampleAt = item.startedAt
            }
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
                        }
                    }.value
                    if let bytes { self?.sample(id, bytes: bytes) }
                }
            }
            let result = await Task.detached(priority: .userInitiated) { Result { try operation() } }.value
            poller.cancel()
            self.change(id) { item in
                item.phase = result.isSuccess ? .completed : .failed
                item.finishedAt = Date()
                if result.isSuccess {
                    item.completedBytes = item.totalBytes > 0 ? item.totalBytes : item.completedBytes
                    let duration = max(item.finishedAt!.timeIntervalSince(item.startedAt ?? item.finishedAt!), 0.001)
                    item.bytesPerSecond = Double(item.completedBytes) / duration
                } else if case .failure(let error) = result {
                    item.error = error.localizedDescription
                }
            }
            completion(result)
        }
    }

    private func sample(_ id: UUID, bytes: Int64) {
        change(id) { item in
            guard item.phase == .running else { return }
            let now = Date()
            let elapsed = max(now.timeIntervalSince(item.lastSampleAt ?? now), 0.001)
            let next = item.totalBytes > 0 ? min(max(bytes, 0), item.totalBytes) : max(bytes, 0)
            item.bytesPerSecond = max(Double(next - item.lastSampleBytes) / elapsed, 0)
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
    @ObservedObject var center: TransferCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文件传输").font(.system(size: 15, weight: .semibold))
                if center.activeCount > 0 {
                    Text("\(center.activeCount) 项进行中").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清除已完成") { center.clearFinished() }
                    .font(.system(size: 11)).disabled(center.items.allSatisfy { $0.phase == .running || $0.phase == .waiting })
            }
            .padding(15)
            Divider()
            if center.items.isEmpty {
                ContentUnavailableView("暂无传输", systemImage: "arrow.up.arrow.down", description: Text("拖入文件或使用上传、下载按钮开始传输"))
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
        .frame(width: 420, height: 390)
    }

    private func transferRow(_ item: TransferRecord) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: item.direction == .upload ? "arrow.up.doc" : "arrow.down.doc")
                .foregroundStyle(item.phase == .failed ? Color.red : Color.accentColor)
                .frame(width: 31, height: 31)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(item.phase.rawValue).foregroundStyle(item.phase == .failed ? .red : .secondary)
                }
                HStack {
                    Text("\(item.direction.rawValue) · \(item.profileName)")
                    Spacer()
                    Text(progressText(item))
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
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func progressText(_ item: TransferRecord) -> String {
        let done = ByteCountFormatter.string(fromByteCount: item.completedBytes, countStyle: .file)
        let total = item.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) : "—"
        let speed = item.phase == .running || item.phase == .completed
            ? ByteCountFormatter.string(fromByteCount: Int64(item.bytesPerSecond), countStyle: .file) + "/s"
            : "—"
        return "\(done) / \(total) · \(speed)"
    }
}
