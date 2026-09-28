import SwiftUI

struct ConnectionLibraryView: View {
    @ObservedObject var store: ProfileStore
    let activeCount: (UUID) -> Int
    let onOpen: (ConnectionProfile) -> Void
    let onCreate: () -> Void
    let onEdit: (ConnectionProfile) -> Void
    let onDelete: (ConnectionProfile) -> Void

    @State private var query = ""
    @State private var selectedGroup = "@recent"
    @State private var selectedProfileID: UUID?
    @State private var groupToRename: String?
    @State private var newGroupName = ""
    @State private var groupToDelete: String?
    @State private var groupError: String?
    @State private var profileToDelete: ConnectionProfile?

    private var visibleProfiles: [ConnectionProfile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = selectedGroup == "@recent" ? store.recentlyConnectedProfiles : store.profiles.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let grouped = source.filter { profile in
            if selectedGroup == "@recent" { return true }
            if selectedGroup == "*" { return true }
            if selectedGroup.isEmpty { return profile.groupPath == nil || profile.groupPath == "" }
            return profile.groupPath == selectedGroup || profile.groupPath?.hasPrefix(selectedGroup + "/") == true
        }
        guard !term.isEmpty else { return grouped }
        return grouped.filter {
            $0.name.localizedCaseInsensitiveContains(term) ||
            $0.host.localizedCaseInsensitiveContains(term) ||
            $0.username.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            groupSidebar.frame(width: 150)
                .background(.ultraThinMaterial, ignoresSafeAreaEdges: [])
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("快速连接").font(.system(size: 14, weight: .semibold))
                    Text("双击条目连接").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("新建连接", systemImage: "plus", action: onCreate)
                        .buttonStyle(.bordered)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索名称、主机或用户名", text: $query)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).frame(height: 32)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14).padding(.bottom, 12)

                HStack(spacing: 12) {
                    Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("主机").frame(width: 140, alignment: .leading)
                    Text("用户名").frame(width: 80, alignment: .leading)
                    Color.clear.frame(width: 72, height: 1)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).frame(height: 28)
                .background(Color.secondary.opacity(0.06))

                if visibleProfiles.isEmpty {
                    ContentUnavailableView(store.profiles.isEmpty ? "还没有连接" : "没有找到连接",
                                           systemImage: store.profiles.isEmpty ? "server.rack" : "magnifyingglass",
                                           description: Text(store.profiles.isEmpty ? "新建一个 SSH 连接开始使用" : "试试其他名称、主机或用户名"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visibleProfiles) { profile in
                                profileRow(profile)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor), ignoresSafeAreaEdges: [])
        .alert("重命名分组", isPresented: Binding(
            get: { groupToRename != nil }, set: { if !$0 { groupToRename = nil } }
        )) {
            TextField("分组名称", text: $newGroupName)
            Button("取消", role: .cancel) { groupToRename = nil }
            Button("保存") {
                guard let path = groupToRename else { return }
                do {
                    try store.renameGroup(path, to: newGroupName)
                    let parent = path.split(separator: "/").dropLast().joined(separator: "/")
                    let name = newGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let destination = parent.isEmpty ? name : parent + "/" + name
                    if selectedGroup == path || selectedGroup.hasPrefix(path + "/") {
                        selectedGroup = destination + selectedGroup.dropFirst(path.count)
                    }
                } catch { groupError = error.localizedDescription }
                groupToRename = nil
            }
        }
        .confirmationDialog("删除分组及其子分组？", isPresented: Binding(
            get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("删除分组", role: .destructive) {
                guard let path = groupToDelete else { return }
                do {
                    try store.removeGroup(path)
                    if selectedGroup == path || selectedGroup.hasPrefix(path + "/") { selectedGroup = "" }
                } catch { groupError = error.localizedDescription }
                groupToDelete = nil
            }
            Button("取消", role: .cancel) { groupToDelete = nil }
        } message: {
            Text("分组中的连接和密码会保留，连接将移至“未分组”。")
        }
        .alert("分组操作失败", isPresented: Binding(
            get: { groupError != nil }, set: { if !$0 { groupError = nil } }
        )) {
            Button("好", role: .cancel) { groupError = nil }
        } message: { Text(groupError ?? "") }
        .confirmationDialog("删除保存的连接？", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        ), titleVisibility: .visible) {
            if let profile = profileToDelete {
                Button("删除 \(profile.name)", role: .destructive) {
                    onDelete(profile)
                    profileToDelete = nil
                }
            }
            Button("取消", role: .cancel) { profileToDelete = nil }
        } message: {
            Text("此连接在本地保险库中的密码也会删除。旧版钥匙串条目需在系统中单独清理。")
        }
    }

    private var groupSidebar: some View {
        let paths = store.availableGroups
        return VStack(alignment: .leading, spacing: 0) {
            Text("连接分组").font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 44)
            List(selection: $selectedGroup) {
                Label("全部连接", systemImage: "server.rack").tag("*")
                Label("最近连接", systemImage: "clock.arrow.circlepath").tag("@recent")
                Label("未分组", systemImage: "tray").tag("")
                OutlineGroup(SavedConnectionGroup.tree(paths), children: \.children) { group in
                    Label(group.name, systemImage: "folder").lineLimit(1)
                        .help(group.id).tag(group.id)
                        .contextMenu {
                            Button("重命名分组", systemImage: "pencil") {
                                newGroupName = group.name
                                groupToRename = group.id
                            }
                            Button("删除分组", systemImage: "trash", role: .destructive) {
                                groupToDelete = group.id
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .font(.system(size: 11))
        }
    }

    private func profileRow(_ profile: ConnectionProfile) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.tint)
                Text(profile.name).lineLimit(1)
                if activeCount(profile.id) > 0 {
                    Circle().fill(.green).frame(width: 5, height: 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(profile.port == 22 ? profile.host : "\(profile.host):\(profile.port)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 140, alignment: .leading)
            Text(profile.username).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 80, alignment: .leading)
            HStack(spacing: 10) {
                Button("连接") { onOpen(profile) }.buttonStyle(.plain)
                Menu {
                    Button("编辑连接", systemImage: "pencil") { onEdit(profile) }
                    Button("删除连接", systemImage: "trash", role: .destructive) {
                        profileToDelete = profile
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 26)
                }
                .menuStyle(.borderlessButton).help("更多操作")
            }
            .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).frame(height: 36)
        .background(selectedProfileID == profile.id ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(profile) }
        .onTapGesture { selectedProfileID = profile.id }
        .contextMenu {
            Button("连接", systemImage: "terminal") { onOpen(profile) }
            Button("编辑连接", systemImage: "pencil") { onEdit(profile) }
            Button("删除连接", systemImage: "trash", role: .destructive) { profileToDelete = profile }
        }
    }
}

private struct SavedConnectionGroup: Identifiable {
    let id: String
    let name: String
    let children: [SavedConnectionGroup]?

    static func tree(_ paths: [String], parent: String = "") -> [SavedConnectionGroup] {
        let prefix = parent.isEmpty ? "" : parent + "/"
        let names = Set(paths.filter { $0.hasPrefix(prefix) }.compactMap { path in
            path.dropFirst(prefix.count).split(separator: "/").first.map(String.init)
        })
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let id = prefix + name
            let children = tree(paths.filter { $0.hasPrefix(id + "/") }, parent: id)
            return SavedConnectionGroup(id: id, name: name, children: children.isEmpty ? nil : children)
        }
    }
}
