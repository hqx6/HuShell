import SwiftUI
import AppKit

@main struct HuShellApp: App {
    @StateObject private var store = ProfileStore()

    init() {
        _ = Askpass.handleIfRequested()
        if let index = CommandLine.arguments.firstIndex(of: "--import-finalshell"),
           CommandLine.arguments.count > index + 1 {
            do {
                let store = ProfileStore()
                let result = try store.importFinalShell(directory: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                print("Imported connections: \(result.connections), passwords: \(result.passwords), groups: \(result.groups)")
                exit(0)
            } catch {
                print("Import failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(store: store)
                .frame(minWidth: 960, minHeight: 620)
                .background(WindowZoomView().frame(width: 0, height: 0))
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            ConnectionCommands(store: store)
        }
    }
}

private struct WindowZoomView: NSViewRepresentable {
    func makeNSView(context: Context) -> ZoomView { ZoomView() }
    func updateNSView(_ view: ZoomView, context: Context) {}

    final class ZoomView: NSView {
        private var didZoom = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didZoom else { return }
            didZoom = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            DispatchQueue.main.async { [weak window] in
                MenuLocalization.localize()
                guard let window, !window.isZoomed else { return }
                window.zoom(nil)
            }
        }
    }
}

struct WorkspaceMenuActions {
    let showLibrary: () -> Void
    let newConnection: () -> Void
    let connect: (UUID) -> Void
}

private struct WorkspaceMenuActionsKey: FocusedValueKey {
    typealias Value = WorkspaceMenuActions
}

extension FocusedValues {
    var workspaceMenuActions: WorkspaceMenuActions? {
        get { self[WorkspaceMenuActionsKey.self] }
        set { self[WorkspaceMenuActionsKey.self] = newValue }
    }
}

private struct ConnectionCommands: Commands {
    @ObservedObject var store: ProfileStore
    @FocusedValue(\.workspaceMenuActions) private var actions

    var body: some Commands {
        CommandMenu("连接") {
            Button("连接列表") { actions?.showLibrary() }
                .keyboardShortcut("t", modifiers: .command)
            Button("新建连接…") { actions?.newConnection() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            if store.profiles.isEmpty {
                Text("暂无保存的连接")
            } else {
                ForEach(store.profiles) { profile in
                    Button(profile.name) { actions?.connect(profile.id) }
                }
            }
        }
    }
}

private enum MenuLocalization {
    static func localize() {
        guard let menu = NSApp.mainMenu else { return }
        let titles = [
            "File": "文件", "Edit": "编辑", "View": "视图", "Window": "窗口", "Help": "帮助",
            "About HuShell": "关于 HuShell", "Settings…": "设置…", "Settings...": "设置…",
            "Services": "服务", "Hide HuShell": "隐藏 HuShell", "Hide Others": "隐藏其他应用",
            "Show All": "显示全部", "Quit HuShell": "退出 HuShell", "Close Window": "关闭窗口",
            "Close": "关闭", "Undo": "撤销", "Redo": "重做", "Cut": "剪切", "Copy": "复制",
            "Paste": "粘贴", "Paste and Match Style": "粘贴并匹配样式", "Select All": "全选",
            "Find": "查找", "Find and Replace": "查找与替换", "Start Dictation": "开始听写",
            "Emoji & Symbols": "表情与符号", "Minimize": "最小化", "Zoom": "缩放",
            "Enter Full Screen": "进入全屏幕", "Exit Full Screen": "退出全屏幕",
            "Bring All to Front": "全部置于最前"
        ]
        func translate(_ menu: NSMenu) {
            for item in menu.items {
                if let replacement = titles[item.title] { item.title = replacement }
                if let submenu = item.submenu { translate(submenu) }
            }
        }
        translate(menu)
    }
}
