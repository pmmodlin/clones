import Foundation

/// Profile metadata stored in `~/.clones/.config.json`.
public struct ProfileMeta: Codable, Equatable, Sendable {
    /// Badge color on the launcher icon, `#RRGGBB`.
    public var color: String?
    /// Custom icon (a copy kept in `~/.clones/.icons`).
    public var icon: String?
    /// Launcher name, “Claude <Name>” by default.
    public var title: String?
    /// Extra environment for the Claude process (e.g. CLAUDE_CONFIG_DIR).
    public var env: [String: String]?
    public var createdAt: Date

    public init(color: String? = nil, icon: String? = nil, title: String? = nil,
                env: [String: String]? = nil, createdAt: Date = Date()) {
        self.color = color
        self.icon = icon
        self.title = title
        self.env = env
        self.createdAt = createdAt
    }
}

public struct ConfigFile: Codable, Equatable, Sendable {
    public var version: Int = 1
    /// Explicit Claude.app path; nil means look in the usual places.
    public var claudeApp: String?
    public var profiles: [String: ProfileMeta] = [:]

    public init() {}

    public static func load(from url: URL) throws -> ConfigFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return ConfigFile() }
        do {
            let data = try Data(contentsOf: url)
            if data.isEmpty { return ConfigFile() }
            return try makeDecoder().decode(ConfigFile.self, from: data)
        } catch {
            throw ClonesError.invalidConfig(path: url.path, reason: String(describing: error))
        }
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
