import SwiftUI

struct VaultPromptView: View {
    enum Mode { case create, migrate, reveal }
    let mode: Mode
    let onSuccess: () -> Void
    let onCancel: () -> Void
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Image(systemName: "lock.shield")
                .font(.system(size: 27, weight: .medium))
                .foregroundStyle(.tint)
            Text(mode == .create ? "设置主密码" : mode == .migrate ? "升级密码文件" : "验证主密码")
                .font(.title3.weight(.semibold))
            Text(mode == .create
                 ? "SSH 密码加密保存在本机。主密码仅用于查看已保存的密码。"
                 : mode == .migrate
                 ? "输入一次旧主密码升级现有密码文件。升级后连接无需验证。"
                 : "输入主密码后显示此连接已保存的 SSH 密码。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("主密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if mode == .create {
                SecureField("确认主密码", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button(mode == .create ? "创建" : mode == .migrate ? "升级" : "验证", action: submit)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 390)
    }

    private func submit() {
        if mode == .create && password != confirmation {
            error = "两次输入的主密码不一致"
            return
        }
        do {
            switch mode {
            case .create: try LocalCredentialVault.shared.create(masterPassword: password)
            case .migrate: try LocalCredentialVault.shared.migrate(masterPassword: password)
            case .reveal: try LocalCredentialVault.shared.verify(masterPassword: password)
            }
            password = ""
            confirmation = ""
            onSuccess()
        } catch { self.error = error.localizedDescription }
    }
}
