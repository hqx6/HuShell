import Foundation

enum StoreError: LocalizedError {
    case invalidProfile(String)
    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message): return message
        }
    }
}

@MainActor final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    @Published private(set) var groupPaths: [String] = []
    @Published private(set) var recentConnections: [String: Date] = [:]

    private let directory: URL?

    private var fileURL: URL {
        let folder: URL
        if let directory {
            folder = directory
        } else if let override = ProcessInfo.processInfo.environment["HUSHELL_PROFILE_STORE_DIRECTORY"], !override.isEmpty {
            folder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HuShell", isDirectory: true)
        }
        return folder.appendingPathComponent("connections.json")
    }

    init(directory: URL? = nil) {
        self.directory = directory
        recentConnections = (try? JSONDecoder().decode([String: Date].self, from: Data(contentsOf: fileURL.deletingLastPathComponent().appendingPathComponent("recent-connections.json")))) ?? [:]
        groupPaths = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: fileURL.deletingLastPathComponent().appendingPathComponent("groups.json")))) ?? []
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return }
        profiles = saved
    }

    func save(_ profile: ConnectionProfile, password: String?) throws {
        if let message = ProfileValidation.message(for: profile) { throw StoreError.invalidProfile(message) }
        if profile.usesPassword {
            if let password { try LocalCredentialVault.shared.set(password, for: profile.id) }
            else if try !LocalCredentialVault.shared.hasPassword(for: profile.id) { throw VaultError.missingCredential }
        } else {
            try LocalCredentialVault.shared.remove(for: profile.id)
        }
        CredentialBroker.shared.invalidate(profile.id)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        try commitGroups(availableGroups, profiles: profiles)
    }

    func remove(_ profile: ConnectionProfile) throws {
        profiles.removeAll { $0.id == profile.id }
        try LocalCredentialVault.shared.remove(for: profile.id)
        CredentialBroker.shared.invalidate(profile.id)
        try persist()
    }

    func recordConnection(_ id: UUID, at date: Date = Date()) throws {
        var updated = recentConnections
        updated[id.uuidString] = date
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("recent-connections.json")
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        recentConnections = updated
    }

    var recentlyConnectedProfiles: [ConnectionProfile] {
        profiles.filter { recentConnections[$0.id.uuidString] != nil }.sorted {
            let first = recentConnections[$0.id.uuidString] ?? .distantPast
            let second = recentConnections[$1.id.uuidString] ?? .distantPast
            if first != second { return first > second }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var availableGroups: [String] {
        let paths = groupPaths + profiles.compactMap(\.groupPath)
        return Array(Set(paths.flatMap { path in
            let parts = path.split(separator: "/").map(String.init)
            return (1...max(1, parts.count)).compactMap { count in
                parts.isEmpty ? nil : parts.prefix(count).joined(separator: "/")
            }
        })).sorted()
    }

    func renameGroup(_ path: String, to name: String) throws {
        let leaf = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leaf.isEmpty, !leaf.contains("/"), leaf != ".", leaf != ".." else {
            throw StoreError.invalidProfile("请输入分组名称，名称不能包含 /。")
        }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let destination = parent.isEmpty ? leaf : parent + "/" + leaf
        guard destination != path else { return }
        guard !availableGroups.contains(destination) else {
            throw StoreError.invalidProfile("同一位置已有这个分组名称。")
        }
        func renamed(_ value: String) -> String {
            value == path || value.hasPrefix(path + "/") ? destination + value.dropFirst(path.count) : value
        }
        let updated = profiles.map { profile in
            var result = profile
            result.groupPath = profile.groupPath.map(renamed)
            return result
        }
        try commitGroups(availableGroups.map(renamed), profiles: updated)
    }

    func removeGroup(_ path: String) throws {
        func belongs(_ value: String) -> Bool { value == path || value.hasPrefix(path + "/") }
        let updated = profiles.map { profile in
            var result = profile
            if let group = profile.groupPath, belongs(group) { result.groupPath = nil }
            return result
        }
        try commitGroups(availableGroups.filter { !belongs($0) }, profiles: updated)
    }

    private func commitGroups(_ groups: [String], profiles updated: [ConnectionProfile]) throws {
        let folder = fileURL.deletingLastPathComponent()
        let groupsURL = folder.appendingPathComponent("groups.json")
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let oldConnections = try? Data(contentsOf: fileURL)
        let oldGroups = try? Data(contentsOf: groupsURL)
        let sorted = Array(Set(groups)).sorted()
        do {
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            try JSONEncoder().encode(sorted).write(to: groupsURL, options: .atomic)
            for url in [fileURL, groupsURL] {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        } catch {
            for (url, data) in [(fileURL, oldConnections), (groupsURL, oldGroups)] {
                if let data { try data.write(to: url, options: .atomic) }
                else if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            }
            throw error
        }
        profiles = updated
        groupPaths = sorted
    }

    /// Validate the complete source first, then commit with an encrypted backup and rollback.
    func importFinalShell(directory: URL) throws -> (connections: Int, passwords: Int, groups: Int) {
        let plan = try FinalShellImport(directory: directory)
        let folder = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        let backup = folder.appendingPathComponent("backups/finalshell-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
        try manager.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let filenames = ["connections.json", "groups.json", "credentials.vault", "credentials.key"]
        var original: [String: Data] = [:]
        for name in filenames {
            let url = folder.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                original[name] = data
                let copy = backup.appendingPathComponent(name)
                try data.write(to: copy, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
            }
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: backup.deletingLastPathComponent().path)
        var updated = profiles
        var passwords: [UUID: String] = [:]
        var added = 0
        for entry in plan.entries {
            // Reimport is idempotent; existing local connections and passwords remain intact.
            if updated.contains(where: { $0.importSourceID == entry.profile.importSourceID }) { continue }
            updated.append(entry.profile)
            passwords[entry.profile.id] = entry.password
            added += 1
        }
        let updatedGroups = Array(Set(groupPaths + plan.groups)).sorted()
        do {
            if !passwords.isEmpty { try LocalCredentialVault.shared.setMany(passwords) }
            try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            try JSONEncoder().encode(updatedGroups).write(to: folder.appendingPathComponent("groups.json"), options: .atomic)
            for name in filenames where manager.fileExists(atPath: folder.appendingPathComponent(name).path) {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent(name).path)
            }
            let reopened = LocalCredentialVault(directory: folder)
            for (id, password) in passwords {
                guard try reopened.password(for: id) == password else { throw VaultError.damaged }
            }
            guard try JSONDecoder().decode([ConnectionProfile].self, from: Data(contentsOf: fileURL)) == updated,
                  try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appendingPathComponent("groups.json"))) == updatedGroups else { throw VaultError.damaged }
        } catch {
            for name in filenames {
                let url = folder.appendingPathComponent(name)
                if let data = original[name] {
                    try data.write(to: url, options: .atomic)
                    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                } else if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            }
            LocalCredentialVault.shared.reload()
            throw error
        }
        profiles = updated
        groupPaths = updatedGroups
        return (added, passwords.count, plan.groups.count)
    }

    private func persist() throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
