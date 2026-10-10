import SwiftUI
import AppKit

struct HostMonitorView: View {
    @ObservedObject var tab: ConnectionTab
    var body: some View {
        HostMonitorContent(stats: tab.stats, host: tab.profile.host,
                           connected: tab.connected, onRefresh: { tab.refresh() })
    }
}

struct EmptyHostMonitorView: View {
    var body: some View {
        HostMonitorContent(stats: HostStats(), host: "—", connected: false, onRefresh: {})
    }
}

private struct HostMonitorContent: View {
    let stats: HostStats
    let host: String
    let connected: Bool
    let onRefresh: () -> Void
    @State private var receiveHistory: [Double] = []
    @State private var sendHistory: [Double] = []


    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text("同步状态").font(.system(size: 11, weight: .semibold))
                    Circle().fill(connected ? .green : .gray).frame(width: 6, height: 6)
                    Spacer()
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("刷新主机信息").disabled(host == "—")
                }
                .padding(.bottom, 6)

                HStack(spacing: 5) {
                    Text("IP").foregroundStyle(.secondary)
                    Text(host).textSelection(.enabled).lineLimit(1)
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(host, forType: .string)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(host == "—")
                }
                .font(.system(size: 11))
                sectionTitle("系统信息")

                HStack(spacing: 4) {
                    Text("运行").foregroundStyle(.secondary)
                    Text(stats.uptime).lineLimit(1)
                }
                .font(.system(size: 10.5)).padding(.vertical, 3)
                HStack(spacing: 4) {
                    Text("负载").foregroundStyle(.secondary)
                    Text(stats.load).lineLimit(1)
                    Spacer()
                    Text("\(stats.cpu) 核").foregroundStyle(.secondary)
                }
                .font(.system(size: 10.5)).padding(.top, 3).padding(.bottom, 11)

                usage("CPU", value: stats.cpuUsage, detail: String(format: "%.0f%%", stats.cpuUsage), tint: .green)
                usage("内存", value: stats.memoryFraction * 100,
                      detail: "\(stats.memoryUsed) / \(stats.memoryTotal) MB", tint: .orange)
                usage("交换", value: stats.swapFraction * 100,
                      detail: "\(stats.swapUsed) / \(stats.swapTotal) MB", tint: .brown)

                sectionTitle("进程")
                HStack(spacing: 0) {
                    Text("内存").frame(width: 48, alignment: .trailing)
                    Text("CPU").frame(width: 51, alignment: .trailing)
                    Text("命令").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.10))
                ForEach(stats.processes) { process in
                    HStack(spacing: 0) {
                        Text(process.memory).frame(width: 48, alignment: .trailing)
                        Text(process.cpu + "%").frame(width: 51, alignment: .trailing)
                        Text(process.command).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .frame(height: 21)
                    .background((Int(process.pid).map { $0 % 2 == 0 } == true) ? Color.secondary.opacity(0.045) : .clear)
                }
                if stats.processes.isEmpty { placeholder("连接后显示 CPU 占用最高的进程") }

                sectionTitle("GPU")
                ForEach(stats.gpus) { gpu in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("GPU \(gpu.index)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(gpu.name).font(.system(size: 10, weight: .medium))
                                .lineLimit(2).help(gpu.name)
                        }
                        gpuMetric("显存", fraction: gpu.memoryFraction,
                                  detail: gpu.memoryText, tint: .cyan)
                        gpuMetric("利用率", fraction: (gpu.utilization ?? 0) / 100,
                                  detail: gpu.utilizationText, tint: .green)
                    }
                    .padding(.vertical, 6)
                    Divider().opacity(0.35)
                }
                if stats.gpus.isEmpty {
                    placeholder(connected ? "未检测到 NVIDIA GPU" : "连接后显示 GPU 信息")
                }

                sectionTitle("网络")
                HStack {
                    Label("↓ \(rate(stats.networkReceive))", systemImage: "arrow.down")
                        .foregroundStyle(.green)
                    Spacer()
                    Label("↑ \(rate(stats.networkSend))", systemImage: "arrow.up")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 10, design: .monospaced))
                .padding(.vertical, 5)
                NetworkHistory(receive: receiveHistory, send: sendHistory)
                    .frame(height: 55)

                sectionTitle("磁盘")
                HStack {
                    Text("路径").frame(maxWidth: .infinity, alignment: .leading)
                    Text("已用 / 总量")
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.vertical, 5)
                ForEach(stats.disks) { disk in
                    HStack(spacing: 6) {
                        Text(disk.path).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(disk.used) / \(disk.total)G").monospacedDigit()
                            .background(alignment: .leading) {
                                GeometryReader { geometry in
                                    Color.accentColor.opacity(0.12)
                                        .frame(width: geometry.size.width * min(max(disk.fraction, 0), 1))
                                }
                            }
                    }
                    .font(.system(size: 10))
                    .frame(height: 20)
                    Divider().opacity(0.35)
                }
                if stats.disks.isEmpty { placeholder("连接后显示磁盘挂载点") }
            }
            .padding(.horizontal, 11).padding(.top, 10).padding(.bottom, 18)
        }
        .onChange(of: stats.networkReceive) { _, value in
            if let sample = Double(value) { receiveHistory = Array((receiveHistory + [max(sample, 0)]).suffix(28)) }
        }
        .onChange(of: stats.networkSend) { _, value in
            if let sample = Double(value) { sendHistory = Array((sendHistory + [max(sample, 0)]).suffix(28)) }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 24)
            .background(Color.accentColor.opacity(0.065))
            .overlay(Rectangle().strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.5))
            .padding(.top, 11).padding(.bottom, 8)
    }

    private func usage(_ label: String, value: Double, detail: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 28, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.09))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.48))
                            .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
                    }
            }
            .frame(height: 13)
            .overlay(alignment: .leading) {
                Text(detail).font(.system(size: 9, design: .monospaced))
                    .padding(.leading, 4).lineLimit(1)
            }
        }
        .font(.system(size: 10)).padding(.bottom, 8)
    }

    private func gpuMetric(_ label: String, fraction: Double, detail: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 35, alignment: .leading)
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.09))
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.55))
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
            }
            .frame(height: 12)
            Text(detail).monospacedDigit().frame(width: 102, alignment: .trailing)
        }
        .font(.system(size: 9.5))
        .frame(height: 15)
    }

    private func rate(_ value: String) -> String {
        guard let bytes = Double(value) else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "/s"
    }

    private func placeholder(_ message: String) -> some View {
        Text(message).font(.system(size: 10)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}

private struct NetworkHistory: View {
    let receive: [Double]
    let send: [Double]

    var body: some View {
        GeometryReader { geometry in
            let top = max((receive + send).max() ?? 1, 1)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.045))
                Path { path in
                    for fraction in [0.33, 0.66] {
                        let y = geometry.size.height * fraction
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }
                .stroke(Color.secondary.opacity(0.14), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                line(receive, top: top, size: geometry.size).stroke(.green, lineWidth: 1.5)
                line(send, top: top, size: geometry.size).stroke(.orange, lineWidth: 1.5)
            }
        }
    }

    private func line(_ values: [Double], top: Double, size: CGSize) -> Path {
        Path { path in
            for (index, value) in values.enumerated() {
                let point = CGPoint(x: CGFloat(index) / 27 * size.width,
                                    y: size.height * (1 - value / top))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}
