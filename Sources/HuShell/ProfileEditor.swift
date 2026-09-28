import SwiftUI
import AppKit

struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existingPassword: Bool
    let isEditing: Bool
    let groups: [String]
    let onSave: (ConnectionProfile, String?) -> Void
    @State private var profile: ConnectionProfile
    @State private var password = ""
    @State private var error: String?
    @State private var showsRevealPrompt = false
    @State private var showsPlainPassword = false

    init(profile: ConnectionProfile?, existingPassword: Bool, groups: [String] = [], onSave: @escaping (ConnectionProfile, String?) -> Void) {
        self.groups = groups
        self.existingPassword = existingPassword
        self.isEditing = profile != nil
        self.onSave = onSave
        _profile = State(initialValue: profile ?? ConnectionProfile(name: "", host: "", username: NSUserName()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(isEditing ? "编辑连接" : "新建连接").font(.title3.weight(.semibold))
                    Text("SSH 连接信息保存在此 Mac 上").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 13) {
                field("名称", text: $profile.name, prompt: "例如：生产服务器")
                VStack(alignment: .leading, spacing: 5) {
                    Text("分组").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        TextField("输入新分组，子分组用 / 分隔", text: Binding(
                            get: { profile.groupPath ?? "" },
                            set: { profile.groupPath = $0.isEmpty ? nil : $0 }
                        )).textFieldStyle(.roundedBorder)
                        Menu {
                            Button("未分组") { profile.groupPath = nil }
                            Divider()
                            ForEach(groups, id: \.self) { group in
                                Button(group) { profile.groupPath = group }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .frame(width: 24).help("选择已有分组")
                        .accessibilityLabel("选择已有分组")
                    }
                }
                field("主机", text: $profile.host, prompt: "IP 地址或域名")
                HStack(spacing: 12) {
                    field("用户名", text: $profile.username, prompt: "root")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("端口").font(.caption).foregroundStyle(.secondary)
                        TextField("22", value: $profile.port, format: .number).textFieldStyle(.roundedBorder)
                    }.frame(width: 88)
                }
                Toggle("使用密码登录", isOn: $profile.usesPassword).font(.system(size: 12))
                if profile.usesPassword {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("密码").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Group {
                                if showsPlainPassword {
                                    TextField("SSH 密码", text: $password)
                                } else {
                                    SecureField(existingPassword ? "留空则保留已保存的密码" : "输入 SSH 密码", text: $password)
                                }
                            }
                            .textFieldStyle(.roundedBorder)
                            if existingPassword {
                                Button(showsPlainPassword ? "隐藏" : "查看已保存密码") {
                                    if showsPlainPassword { showsPlainPassword = false }
                                    else { showsRevealPrompt = true }
                                }
                                .font(.caption)
                            }
                        }
                        Text("连接可直接使用已保存密码；查看密码时需验证主密码")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack {
                        field("私钥文件（可选）", text: $profile.identityFile, prompt: "留空使用 SSH Agent")
                        Button { chooseIdentity() } label: { Image(systemName: "folder") }.padding(.top, 16)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存连接") {
                    if let message = ProfileValidation.message(for: profile) { error = message; return }
                    if profile.usesPassword && password.isEmpty && !existingPassword { error = "请输入密码"; return }
                    profile.groupPath = profile.groupPath.map {
                        $0.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }.joined(separator: "/")
                    }
                    if profile.groupPath == "" { profile.groupPath = nil }
                    onSave(profile, password.isEmpty ? nil : password)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(25).frame(width: 430)
        .sheet(isPresented: $showsRevealPrompt) {
            VaultPromptView(mode: .reveal, onSuccess: {
                showsRevealPrompt = false
                do {
                    password = try LocalCredentialVault.shared.password(for: profile.id) ?? ""
                    showsPlainPassword = true
                } catch { self.error = error.localizedDescription }
            }, onCancel: { showsRevealPrompt = false })
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { profile.identityFile = panel.url?.path ?? "" }
    }
}
