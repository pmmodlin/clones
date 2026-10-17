import Foundation

/// Profiles on disk plus their metadata. `default` is built in: it is plain
/// `~/Library/Application Support/Claude` and cannot be removed or renamed.
public final class ProfileStore {
    public let paths: Paths
    public private(set) var config: ConfigFile
    private let fm = FileManager.default

    public init(paths: Paths = .current()) throws {
        self.paths = paths
        self.config = try ConfigFile.load(from: paths.configFile)
    }

    public func save() throws {
        try config.save(to: paths.configFile)
    }

    // MARK: - Reading

    public var defaultProfile: Profile {
        Profile(name: Profile.defaultName, dataDir: paths.defaultUserData, meta: config.profiles[Profile.defaultName])
    }

    public func dataDir(for name: String) -> URL {
        paths.profilesDir.appendingPathComponent(name, isDirectory: true)
    }

    /// `default` first, the rest alphabetically.
    public func allProfiles() -> [Profile] {
        let named = config.profiles.keys
            .filter { $0 != Profile.defaultName }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { Profile(name: $0, dataDir: dataDir(for: $0), meta: config.profiles[$0]) }
        return [defaultProfile] + named
    }

    public var profileNames: [String] { allProfiles().map(\.name) }

    public func profile(named rawName: String) throws -> Profile {
        let name = try resolveName(rawName)
        if name == Profile.defaultName { return defaultProfile }
        return Profile(name: name, dataDir: dataDir(for: name), meta: config.profiles[name])
    }

    /// Exact match, otherwise case-insensitive (APFS is case-insensitive by default).
    public func resolveName(_ rawName: String) throws -> String {
        if rawName.lowercased() == Profile.defaultName { return Profile.defaultName }
        if config.profiles[rawName] != nil { return rawName }
        let matches = config.profiles.keys.filter { $0.lowercased() == rawName.lowercased() }
        if matches.count == 1 { return matches[0] }
        throw ClonesError.profileNotFound(rawName)
    }

    func exists(_ name: String) -> Bool {
        name.lowercased() == Profile.defaultName
            || config.profiles.keys.contains { $0.lowercased() == name.lowercased() }
    }

    /// Folders in profiles/ that config.json does not know about.
    public func orphanDirectories() -> [URL] {
        guard let items = try? fm.contentsOfDirectory(at: paths.profilesDir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        return items.filter { url in
            !url.lastPathComponent.hasPrefix(".")  // .icons, .bundles.noindex and other clones files
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && config.profiles[url.lastPathComponent] == nil
        }
    }

    // MARK: - Changing

    @discardableResult
    public func create(name: String, color: String? = nil, iconPath: String? = nil,
                       title: String? = nil, env: [String: String]? = nil,
                       cloneMCPFrom source: String? = nil) throws -> Profile {
        try ProfileName.validate(name)
        if exists(name) { throw ClonesError.profileExists(name) }

        var meta = ProfileMeta(title: title, env: env)
        if let color {
            guard let parsed = HexColor(color) else { throw ClonesError.invalidColor(color) }
            meta.color = parsed.hexString
        }

        // Validate the MCP source before creating anything on disk.
        var mcpServers: Any = [String: Any]()
        if let source {
            let sourceProfile = try profile(named: source)
            mcpServers = try MCPConfig.servers(in: sourceProfile.mcpConfigFile)
        }

        let dir = dataDir(for: name)
        if fm.fileExists(atPath: dir.path) {
            throw ClonesError.other(tr("Folder \(paths.abbreviate(dir)) already exists, but there is no profile “\(name)” in config.json. Remove or rename the folder.",
                                       "Папка \(paths.abbreviate(dir)) уже существует, но профиля «\(name)» нет в config.json. Удалите или переименуйте папку вручную."))
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        do {
            if let iconPath {
                meta.icon = try importIcon(from: iconPath, for: name).path
            }
            try MCPConfig.write(servers: mcpServers, to: dir.appendingPathComponent("claude_desktop_config.json"))
            config.profiles[name] = meta
            try save()
        } catch {
            try? fm.removeItem(at: dir)
            config.profiles[name] = nil
            throw error
        }
        return try profile(named: name)
    }

    public func update(_ name: String, _ change: (inout ProfileMeta) throws -> Void) throws {
        let resolved = try resolveName(name)
        var meta = config.profiles[resolved] ?? ProfileMeta()
        try change(&meta)
        config.profiles[resolved] = meta
        try save()
    }

    public func setIcon(_ name: String, from path: String) throws {
        let resolved = try resolveName(name)
        let stored = try importIcon(from: path, for: resolved)
        try update(resolved) { $0.icon = stored.path }
    }

    public func remove(_ rawName: String) throws {
        let name = try resolveName(rawName)
        if name == Profile.defaultName { throw ClonesError.reservedProfile(name, action: tr("removed", "удалить")) }
        let dir = dataDir(for: name)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        if let icon = config.profiles[name]?.icon, icon.hasPrefix(paths.iconsDir.path) {
            try? fm.removeItem(atPath: icon)
        }
        config.profiles[name] = nil
        try save()
    }

    public func rename(_ rawOld: String, to new: String) throws {
        let old = try resolveName(rawOld)
        if old == Profile.defaultName { throw ClonesError.reservedProfile(old, action: tr("renamed", "переименовать")) }
        try ProfileName.validate(new)
        let caseOnlyChange = old.lowercased() == new.lowercased()
        if exists(new) && !caseOnlyChange { throw ClonesError.profileExists(new) }

        let from = dataDir(for: old), to = dataDir(for: new)
        if fm.fileExists(atPath: from.path) {
            if caseOnlyChange {
                // On a case-insensitive file system “work” → “Work” goes through a temporary name.
                let tmp = paths.profilesDir.appendingPathComponent(".rename-\(UUID().uuidString)")
                try fm.moveItem(at: from, to: tmp)
                try fm.moveItem(at: tmp, to: to)
            } else {
                try fm.moveItem(at: from, to: to)
            }
        }

        var meta = config.profiles[old]
        if let icon = meta?.icon, icon.hasPrefix(paths.iconsDir.path) {
            let newIcon = paths.iconsDir.appendingPathComponent(new + "." + (icon as NSString).pathExtension)
            if (try? fm.moveItem(atPath: icon, toPath: newIcon.path)) != nil { meta?.icon = newIcon.path }
        }
        // Environment paths into the profile folder (CLAUDE_CONFIG_DIR) move with it.
        let movedEnv = meta?.env?.mapValues { value in
            value == from.path || value.hasPrefix(from.path + "/") ? to.path + value.dropFirst(from.path.count) : value
        }
        meta?.env = movedEnv
        config.profiles[old] = nil
        config.profiles[new] = meta
        try save()
    }

    /// Keep our own copy of the icon so launchers can be rebuilt even if the original is gone.
    private func importIcon(from path: String, for name: String) throws -> URL {
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard fm.fileExists(atPath: source.path) else { throw ClonesError.fileNotFound(source.path) }
        try fm.createDirectory(at: paths.iconsDir, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let target = paths.iconsDir.appendingPathComponent("\(name).\(ext)")
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
        return target
    }
}

/// claude_desktop_config.json helpers. Keys other than mcpServers are left alone.
public enum MCPConfig {
    public static func servers(in file: URL) throws -> Any {
        guard FileManager.default.fileExists(atPath: file.path) else { return [String: Any]() }
        let object = try readObject(file)
        return object["mcpServers"] ?? [String: Any]()
    }

    public static func readObject(_ file: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClonesError.invalidConfig(path: file.path, reason: tr("the top level must be a JSON object", "верхний уровень должен быть JSON-объектом"))
            }
            return object
        } catch let error as ClonesError {
            throw error
        } catch {
            throw ClonesError.invalidConfig(path: file.path, reason: tr("invalid JSON (\(error.localizedDescription))", "невалидный JSON (\(error.localizedDescription))"))
        }
    }

    public static func write(servers: Any, to file: URL) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            object = try readObject(file)
        }
        object["mcpServers"] = servers
        var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A)
        try data.write(to: file, options: .atomic)
    }

    /// Creates `{"mcpServers": {}}` if the file does not exist yet.
    public static func ensureExists(_ file: URL) throws {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(servers: [String: Any](), to: file)
    }

    public static func serverNames(in file: URL) -> [String]? {
        guard let servers = try? servers(in: file) as? [String: Any] else { return nil }
        return servers.keys.sorted()
    }
}
