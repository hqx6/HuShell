import SwiftUI
import AppKit

private struct EditorRequest: Identifiable {
    let id = UUID()
    let profile: ConnectionProfile?
}

private enum WorkspaceTab: Identifiable {
    case library(UUID)
    case connection(ConnectionTab)

    var id: UUID {
        switch self {
        case .library(let id): return id
        case .connection(let tab): return tab.id
        }
    }
}

private struct WindowXProbe: NSViewRepresentable {
    @Binding var leadingX: CGFloat
    @Binding var windowWidth: CGFloat
    let layoutX: CGFloat

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.report = { value, width in
            if abs(leadingX - layoutX) > 0.5 { leadingX = layoutX }
            if abs(windowWidth - width) > 0.5 { windowWidth = width }
        }
        view.measure()
    }

    final class ProbeView: NSView {
        var report: ((CGFloat, CGFloat) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measure() }
        override func layout() { super.layout(); measure() }
        func measure() {
            guard let window else { return }
            let value = convert(.zero, to: nil).x
            DispatchQueue.main.async { [weak self] in self?.report?(value, window.frame.width) }
        }
    }
}

private struct TitlebarTabAccessory<Content: View, Controls: View>: NSViewRepresentable {
    let leadingX: CGFloat
    let windowWidth: CGFloat
    let tabWidth: CGFloat
    let stateSignature: [String]
    let content: Content
    let controls: Controls

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onWindow = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.update(leadingX: leadingX, windowWidth: windowWidth,
                                   tabWidth: tabWidth, stateSignature: stateSignature,
                                   content: content, controls: controls)
        if let window = view.window { context.coordinator.attach(to: window) }
    }
    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    final class Coordinator {
        private final class ClickThroughHostingView: NSHostingView<AnyView> {
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        }

        private let accessory = NSTitlebarAccessoryViewController()
        private let hosting = ClickThroughHostingView(rootView: AnyView(EmptyView()))
        private let trailingAccessory = NSTitlebarAccessoryViewController()
        private let trailingHosting = ClickThroughHostingView(rootView: AnyView(EmptyView()))
        private weak var window: NSWindow?
        private var leadingX: CGFloat = 0
        private var windowWidth: CGFloat = 960
        private var tabWidth: CGFloat = 150
        private var stateSignature: [String] = []
        private var content: AnyView = AnyView(EmptyView())
        private var controls: AnyView = AnyView(EmptyView())

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            let toolbar = NSToolbar(identifier: "WorkspaceTitlebar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
            window.toolbarStyle = .unifiedCompact
            window.titlebarSeparatorStyle = .none
            window.titlebarAppearsTransparent = false
            accessory.layoutAttribute = .left
            accessory.view = hosting
            window.addTitlebarAccessoryViewController(accessory)
            trailingAccessory.layoutAttribute = .right
            trailingAccessory.view = trailingHosting
            window.addTitlebarAccessoryViewController(trailingAccessory)
            refresh()
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        func update(leadingX: CGFloat, windowWidth: CGFloat, tabWidth: CGFloat,
                    stateSignature: [String], content: Content, controls: Controls) {
            let changed = self.stateSignature != stateSignature || abs(self.leadingX - leadingX) > 0.5
                || abs(self.windowWidth - windowWidth) > 0.5 || abs(self.tabWidth - tabWidth) > 0.5
            guard changed else { return }
            self.leadingX = leadingX
            self.windowWidth = windowWidth
            self.tabWidth = tabWidth
            self.stateSignature = stateSignature
            self.content = AnyView(content)
            self.controls = AnyView(controls)
            refresh()
        }
        private func refresh() {
            guard window != nil else { return }
            trailingHosting.frame = NSRect(x: 0, y: 0, width: 160, height: 40)
            trailingHosting.rootView = controls
            let accessoryX = hosting.convert(.zero, to: nil).x
            let inset = max(0, leadingX + 10 - accessoryX)
            let width = min(max(150, inset + tabWidth + 4), max(150, windowWidth - accessoryX - 170))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 40)
            hosting.rootView = AnyView(
                HStack(spacing: 0) {
                    Color.clear.frame(width: inset)
                        .allowsHitTesting(false)
                    content
                    Spacer(minLength: 0).allowsHitTesting(false)
                }
                .frame(width: width, height: 40, alignment: .leading)
            )
        }
        func detach() {
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === accessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            if let window,
               let index = window.titlebarAccessoryViewControllers.firstIndex(where: { $0 === trailingAccessory }) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            window = nil
        }
    }
}

struct WorkspaceView: View {
    @ObservedObject var store: ProfileStore
    @StateObject private var transferCenter = TransferCenter()
    @State private var tabs: [WorkspaceTab] = [.library(UUID())]
    @State private var selectedTabID: UUID?
    @State private var editorRequest: EditorRequest?
    @State private var showsVaultPrompt = false
    @State private var vaultPromptMode: VaultPromptView.Mode = .migrate
    @State private var pendingVaultAction: (() -> Void)?
    @State private var connectAfterEditing: UUID?
    @State private var waitingToCreateVault = false
    @State private var errorMessage: String?
    @State private var showsSidebar = true
    @State private var showsFiles = true
    @AppStorage("filePanelPosition") private var filePanelPosition: FilePanelPosition = .bottom
    @State private var tabScrollAnchorID: UUID?
    @State private var mainLeadingX: CGFloat = 0
    @State private var windowWidth: CGFloat = 960
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var selectedItem: WorkspaceTab? { tabs.first { $0.id == selectedTabID } ?? tabs.first }
    private var selectedTab: ConnectionTab? {
        guard case .connection(let tab) = selectedItem else { return nil }
        return tab
    }
    private var connectionTabs: [ConnectionTab] {
        tabs.compactMap { if case .connection(let tab) = $0 { return tab }; return nil }
    }
    private var tabButtonWidth: CGFloat {
        return tabs.reduce(CGFloat(0)) { width, item in
            switch item {
            case .library: return width + 130
            case .connection(let tab):
                return width + connectionTabWidth(for: tab.profile.name)
            }
        } + CGFloat(max(0, tabs.count - 1)) * 5
    }
    private func connectionTabWidth(for name: String) -> CGFloat {
        let textWidth = (name as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]).width
        return min(240, max(145, textWidth + 60))
    }
    private var availableTabStripWidth: CGFloat { max(180, windowWidth - mainLeadingX - 190) }
    private var tabStripWidth: CGFloat { min(tabButtonWidth + 42, availableTabStripWidth) }
    private var tabStripOverflows: Bool { tabButtonWidth + 42 > availableTabStripWidth }
    private var titlebarSignature: [String] {
        tabs.map { item in
            switch item {
            case .library(let id): return "library:\(id)"
            case .connection(let tab): return "connection:\(tab.id):\(tab.connected)"
            }
        } + ["selected:\(selectedItem?.id.uuidString ?? "")", "sidebar:\(showsSidebar)",
             "files:\(showsFiles)", "position:\(filePanelPosition.rawValue)"]
    }

    var body: some View {
        Group {
            if showsSidebar {
                ResizableSplit(axis: .horizontal, minimumFirst: 285,
                               minimumSecond: selectedTab != nil && showsFiles && filePanelPosition == .right ? 940 : 630,
                               maximumFirst: 390, initialFirst: 330) {
                    Group {
                        if let selectedTab {
                            HostMonitorView(tab: selectedTab).id(selectedTab.id)
                        } else {
                            EmptyHostMonitorView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.ultraThinMaterial, ignoresSafeAreaEdges: [])
                } second: {
                    mainContent
                }
            } else {
                mainContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        .background {
            TitlebarTabAccessory(leadingX: mainLeadingX, windowWidth: windowWidth,
                                 tabWidth: tabStripWidth,
                                 stateSignature: titlebarSignature, content: tabStrip, controls: windowControls)
                .frame(width: 1, height: 1)
        }
        .focusedSceneValue(\.workspaceMenuActions, WorkspaceMenuActions(
            showLibrary: newLibraryTab,
            newConnection: { beginEditor(nil) },
            connect: { id in
                if let profile = store.profiles.first(where: { $0.id == id }) { openConnection(profile) }
            },
            findTerminal: { selectedTab?.findInTerminal() }
        ))
        .sheet(item: $editorRequest, onDismiss: {
            if !waitingToCreateVault { connectAfterEditing = nil }
        }) { request in
            ProfileEditor(profile: request.profile,
                          existingPassword: request.profile.map { (try? LocalCredentialVault.shared.hasPassword(for: $0.id)) ?? false } ?? false,
                          groups: store.availableGroups) { saved, password in
                saveEditedProfile(saved, password: password)
            }
        }
        .sheet(isPresented: $showsVaultPrompt) {
            VaultPromptView(mode: vaultPromptMode,
                            onSuccess: {
                                showsVaultPrompt = false
                                let action = pendingVaultAction
                                pendingVaultAction = nil
                                DispatchQueue.main.async { action?() }
                            },
                            onCancel: {
                                pendingVaultAction = nil
                                showsVaultPrompt = false
                                waitingToCreateVault = false
                                connectAfterEditing = nil
                            })
        }
        .alert("操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onReceive(refresh) { _ in
            if showsSidebar, let selectedTab, selectedTab.connected { selectedTab.loadStats() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            transferCenter.cancelAll()
        }
        .onDisappear {
            transferCenter.cancelAll()
            connectionTabs.forEach { $0.disconnect() }
        }
    }

    private var windowControls: some View {
            HStack(spacing: 6) {
                Button(action: newLibraryTab) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                    .help("新建标签页")
                    .accessibilityLabel("新建标签页")
                    .modifier(GlassSurface(radius: 8))

                Button { showsSidebar.toggle(); if showsSidebar { selectedTab?.loadStats() } } label: {
                    Image(systemName: "sidebar.left")
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .help(showsSidebar ? "隐藏主机信息" : "显示主机信息")
                .accessibilityLabel(showsSidebar ? "隐藏主机信息" : "显示主机信息")
                .modifier(GlassSurface(radius: 8))

                Button { showsFiles.toggle() } label: {
                    Image(systemName: filePanelPosition == .right ? "sidebar.right" : "rectangle.bottomthird.inset.filled")
                        .frame(width: 28, height: 28)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .help(showsFiles ? "隐藏文件栏" : "显示文件栏")
                .accessibilityLabel(showsFiles ? "隐藏文件栏" : "显示文件栏")
                .disabled(selectedTab == nil)
                .modifier(GlassSurface(radius: 8))

                Image(systemName: "slider.horizontal.3")
                .frame(width: 28, height: 28)
                .overlay {
                    TitlebarLayoutMenu(selected: filePanelPosition, enabled: selectedTab != nil) { position in
                        filePanelPosition = position
                        showsFiles = true
                    }
                    .frame(width: 28, height: 28)
                }
                .help("布局设置")
                .accessibilityLabel("布局设置")
                .foregroundStyle(selectedTab == nil ? Color.secondary.opacity(0.4) : Color.primary)
                .modifier(GlassSurface(radius: 8))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .frame(width: 160, height: 40, alignment: .trailing)
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if let selectedTab {
                ConnectionPane(tab: selectedTab, showsFiles: showsFiles,
                               filePanelPosition: filePanelPosition).id(selectedTab.id)
            } else {
                ConnectionLibraryView(store: store,
                                      activeCount: { id in connectionTabs.filter { $0.profile.id == id }.count },
                                      onOpen: openConnection,
                                      onCreate: { beginEditor(nil) },
                                      onEdit: { beginEditor($0) },
                                      onDelete: deleteProfile)
                    .id(selectedItem?.id)
            }
        }
        .frame(minWidth: selectedTab != nil && showsFiles && filePanelPosition == .right ? 920 : 630)
        .background(alignment: .topLeading) {
            GeometryReader { geometry in
                WindowXProbe(leadingX: $mainLeadingX, windowWidth: $windowWidth,
                             layoutX: geometry.frame(in: .global).minX)
                    .frame(width: 1, height: 1)
            }
        }
    }

    private var tabStrip: some View {
        ScrollViewReader { proxy in
            HStack(spacing: 4) {
                if tabStripOverflows {
                    tabScrollButton("chevron.left", help: "查看前面的标签页") {
                        scrollTabs(backward: true, using: proxy)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) { tabButtons }
                    .frame(width: max(70, tabStripWidth - (tabStripOverflows ? 56 : 0) - 34))
                if tabStripOverflows {
                    tabScrollButton("chevron.right", help: "查看后面的标签页") {
                        scrollTabs(backward: false, using: proxy)
                    }
                }
                Button(action: newLibraryTab) {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                    .buttonStyle(.plain)
                    .modifier(GlassSurface(radius: 8))
                    .help("新建标签页")
                    .accessibilityLabel("在标签后新建标签页")
            }
            .frame(width: tabStripWidth, height: 40, alignment: .leading)
            .onChange(of: selectedItem?.id) { _, id in
                guard let id else { return }
                tabScrollAnchorID = id
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .trailing) }
            }
            .onChange(of: tabStripOverflows) { _, overflowing in
                guard overflowing, let id = selectedItem?.id else { return }
                tabScrollAnchorID = id
                proxy.scrollTo(id, anchor: .trailing)
            }
        }
    }

    private func tabScrollButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .modifier(GlassSurface(radius: 8))
        .help(help)
        .accessibilityLabel(help)
    }

    private func scrollTabs(backward: Bool, using proxy: ScrollViewProxy) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(where: { $0.id == tabScrollAnchorID })
            ?? tabs.firstIndex(where: { $0.id == selectedItem?.id }) ?? 0
        let visibleCount = max(1, Int((tabStripWidth - 90) / 145) + 1)
        let index = min(tabs.count - 1, max(0, current + (backward ? -visibleCount : visibleCount)))
        let id = tabs[index].id
        tabScrollAnchorID = id
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: backward ? .leading : .trailing)
        }
    }

    private var tabButtons: some View {
            HStack(spacing: 5) {
                ForEach(tabs) { item in
                    Group {
                        switch item {
                        case .library:
                            LibraryTabButton(selected: selectedItem?.id == item.id,
                                             onSelect: { selectedTabID = item.id },
                                             onClose: { closeTab(item) })
                        case .connection(let tab):
                            ConnectionTabButton(tab: tab, selected: selectedItem?.id == item.id,
                                                width: connectionTabWidth(for: tab.profile.name),
                                                onSelect: { selectedTabID = item.id },
                                                onClose: { closeTab(item) },
                                                onReconnect: { runAfterMigration { tab.connect() } },
                                                onDuplicate: { duplicateTab(tab) })
                        }
                    }
                    .id(item.id)
                }
            }
            .padding(.horizontal, 4)
    }

    private func newLibraryTab() {
        let item = WorkspaceTab.library(UUID())
        tabs.append(item)
        selectedTabID = item.id
    }

    private func presentVaultPrompt(_ mode: VaultPromptView.Mode, action: @escaping () -> Void) {
        vaultPromptMode = mode
        pendingVaultAction = action
        showsVaultPrompt = true
    }

    private func runAfterMigration(_ action: @escaping () -> Void) {
        if LocalCredentialVault.shared.requiresMigration {
            presentVaultPrompt(.migrate, action: action)
        } else { action() }
    }

    private func beginEditor(_ profile: ConnectionProfile?) {
        runAfterMigration { editorRequest = EditorRequest(profile: profile) }
    }

    private func saveEditedProfile(_ profile: ConnectionProfile, password: String?) {
        if profile.usesPassword && !LocalCredentialVault.shared.exists {
            waitingToCreateVault = true
            editorRequest = nil
            DispatchQueue.main.async {
                presentVaultPrompt(.create) {
                    waitingToCreateVault = false
                    saveEditedProfile(profile, password: password)
                }
            }
            return
        }
        do {
            try store.save(profile, password: password)
            editorRequest = nil
            if connectAfterEditing == profile.id {
                connectAfterEditing = nil
                DispatchQueue.main.async { openUnlockedConnection(profile) }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func openConnection(_ profile: ConnectionProfile) {
        runAfterMigration { openUnlockedConnection(profile) }
    }

    private func openUnlockedConnection(_ profile: ConnectionProfile) {
        if profile.usesPassword && ((try? LocalCredentialVault.shared.hasPassword(for: profile.id)) != true) {
            connectAfterEditing = profile.id
            editorRequest = EditorRequest(profile: profile)
            return
        }
        let tab = ConnectionTab(profile: profile, transferCenter: transferCenter)
        tab.onConnect = { try? store.recordConnection(profile.id) }
        if let index = tabs.firstIndex(where: { $0.id == selectedItem?.id }),
           case .library = tabs[index] {
            tabs[index] = .connection(tab)
        } else {
            tabs.append(.connection(tab))
        }
        selectedTabID = tab.id
        tab.connect()
    }

    private func duplicateTab(_ original: ConnectionTab) {
        runAfterMigration { duplicateUnlockedTab(original) }
    }

    private func duplicateUnlockedTab(_ original: ConnectionTab) {
        let tab = ConnectionTab(profile: original.profile, transferCenter: transferCenter)
        tab.onConnect = { try? store.recordConnection(original.profile.id) }
        tabs.append(.connection(tab))
        selectedTabID = tab.id
        tab.connect()
    }

    private func closeTab(_ item: WorkspaceTab) {
        guard let index = tabs.firstIndex(where: { $0.id == item.id }) else { return }
        if case .connection(let tab) = item { tab.disconnect() }
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [.library(UUID())] }
        if selectedTabID == item.id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    private func deleteProfile(_ profile: ConnectionProfile) {
        runAfterMigration { deleteUnlockedProfile(profile) }
    }

    private func deleteUnlockedProfile(_ profile: ConnectionProfile) {
        do {
            for item in tabs {
                if case .connection(let tab) = item, tab.profile.id == profile.id { closeTab(item) }
            }
            try store.remove(profile)
        } catch { errorMessage = error.localizedDescription }
    }
}

private struct LibraryTabButton: View {
    let selected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                Label("连接", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭标签页")
        }
        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 11).frame(width: 130, height: 28)
        .modifier(GlassSurface(radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1))
        .contextMenu {
            Button("关闭标签页", systemImage: "xmark", action: onClose)
        }
    }
}

private struct ConnectionTabButton: View {
    @ObservedObject var tab: ConnectionTab
    let selected: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void
    let onDuplicate: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    Circle().fill(tab.connected ? .green : .gray).frame(width: 6, height: 6)
                    Text(tab.profile.name).lineLimit(1).frame(maxWidth: 180)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭标签页")
        }
        .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
        .padding(.horizontal, 11).frame(width: width, height: 28)
        .modifier(GlassSurface(radius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.15), lineWidth: 1))
        .contextMenu {
            Button("重新连接", systemImage: "arrow.clockwise", action: onReconnect)
            Button("复制标签页", systemImage: "plus.square.on.square", action: onDuplicate)
            if tab.connected { Button("断开连接", systemImage: "power") { tab.disconnect() } }
            Divider()
            Button("关闭标签页", systemImage: "xmark", action: onClose)
        }
    }
}
