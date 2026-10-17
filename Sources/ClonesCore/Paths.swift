import Foundation

/// Every path clones works with.
///
/// Standard layout, everything under `~/.clones`:
///
///     ~/.clones/<profile>/              userData of the profile (sign-in, chats, settings, MCP config)
///     ~/.clones/<profile>/claude-code/  its Claude Code folder (CLAUDE_CONFIG_DIR)
///     ~/.clones/.config.json            metadata
///     ~/.clones/.bundles.noindex/       Claude.app copies named after profiles
///     ~/.clones/.icons/                 custom icons
///
/// Dot names never clash with profiles: a profile name must start with a letter or digit.
/// The legacy layout of early development builds is kept only to migrate from it, see `LayoutMigration`.
///
/// `CLONES_HOME` moves the root (tests, unusual setups); `CLONES_APPS_DIR`, `CLONES_DEFAULT_USER_DATA`
/// override the other locations.
public struct Paths: Sendable {
    public let home: URL
    /// `~/.clones` (or the legacy `~/Library/Application Support/clones`).
    public let root: URL
    public let profilesDir: URL
    public let iconsDir: URL
    /// Claude.app copies named after profiles; `.noindex` keeps them out of Spotlight.
    public let bundlesDir: URL
    public let configFile: URL
    /// userData of plain Claude: `~/Library/Application Support/Claude`.
    public let defaultUserData: URL
    /// Where launchers go: `/Applications`.
    public let applicationsDir: URL
    /// Where older versions put launchers (`~/Applications`).
    public let legacyApplicationsDirs: [URL]
    /// True for the early-build layout that still has to be migrated.
    public let isLegacy: Bool

    public var launcherDirs: [URL] { [applicationsDir] + legacyApplicationsDirs }

    public init(home: URL, root: URL, profilesDir: URL, iconsDir: URL, bundlesDir: URL, configFile: URL,
                defaultUserData: URL, applicationsDir: URL, legacyApplicationsDirs: [URL] = [], isLegacy: Bool = false) {
        self.home = home
        self.root = root
        self.profilesDir = profilesDir
        self.iconsDir = iconsDir
        self.bundlesDir = bundlesDir
        self.configFile = configFile
        self.defaultUserData = defaultUserData
        self.applicationsDir = applicationsDir
        self.legacyApplicationsDirs = legacyApplicationsDirs.filter { $0.standardizedFileURL != applicationsDir.standardizedFileURL }
        self.isLegacy = isLegacy
    }

    /// The standard layout with everything under `root`.
    public static func standard(home: URL, root: URL, defaultUserData: URL? = nil, applicationsDir: URL? = nil,
                                legacyApplicationsDirs: [URL] = []) -> Paths {
        Paths(home: home, root: root,
              profilesDir: root,
              iconsDir: root.appendingPathComponent(".icons", isDirectory: true),
              bundlesDir: root.appendingPathComponent(".bundles.noindex", isDirectory: true),
              configFile: root.appendingPathComponent(".config.json"),
              defaultUserData: defaultUserData ?? home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
              applicationsDir: applicationsDir ?? URL(fileURLWithPath: "/Applications", isDirectory: true),
              legacyApplicationsDirs: legacyApplicationsDirs)
    }

    /// The early-build layout: data in Application Support, metadata in ~/.config.
    public static func legacy(home: URL, defaultUserData: URL? = nil, applicationsDir: URL? = nil,
                              legacyApplicationsDirs: [URL] = []) -> Paths {
        let root = home.appendingPathComponent("Library/Application Support/clones", isDirectory: true)
        return Paths(home: home, root: root,
                     profilesDir: root.appendingPathComponent("profiles", isDirectory: true),
                     iconsDir: root.appendingPathComponent("icons", isDirectory: true),
                     bundlesDir: root.appendingPathComponent("bundles.noindex", isDirectory: true),
                     configFile: home.appendingPathComponent(".config/clones/config.json"),
                     defaultUserData: defaultUserData ?? home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
                     applicationsDir: applicationsDir ?? URL(fileURLWithPath: "/Applications", isDirectory: true),
                     legacyApplicationsDirs: legacyApplicationsDirs,
                     isLegacy: true)
    }

    /// `~/.clones`, unless only a not-yet-migrated early-build layout exists.
    public static func current(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)

        func dir(_ key: String) -> URL? {
            guard let value = env[key], !value.isEmpty else { return nil }
            return URL(fileURLWithPath: (value as NSString).expandingTildeInPath, isDirectory: true)
        }

        let appsOverride = dir("CLONES_APPS_DIR")
        let defaultUserData = dir("CLONES_DEFAULT_USER_DATA")
        let legacyApps = appsOverride == nil ? [home.appendingPathComponent("Applications", isDirectory: true)] : []

        if let root = dir("CLONES_HOME") {
            return .standard(home: home, root: root, defaultUserData: defaultUserData,
                             applicationsDir: appsOverride, legacyApplicationsDirs: legacyApps)
        }
        let standard = Paths.standard(home: home, root: home.appendingPathComponent(".clones", isDirectory: true),
                                      defaultUserData: defaultUserData, applicationsDir: appsOverride,
                                      legacyApplicationsDirs: legacyApps)
        let legacy = Paths.legacy(home: home, defaultUserData: defaultUserData, applicationsDir: appsOverride,
                                  legacyApplicationsDirs: legacyApps)
        let fm = FileManager.default
        if !fm.fileExists(atPath: standard.root.path),
           fm.fileExists(atPath: legacy.configFile.path) || fm.fileExists(atPath: legacy.root.path) {
            return legacy
        }
        return standard
    }

    /// `/Users/me/Library/...` → `~/Library/...` for display.
    public func abbreviate(_ url: URL) -> String {
        let path = url.path
        let homePath = home.path
        if path == homePath { return "~" }
        if path.hasPrefix(homePath + "/") { return "~" + path.dropFirst(homePath.count) }
        return path
    }
}

extension URL {
    /// Normalized path for comparisons: no `..`, no trailing slash, symlinks resolved.
    public var canonicalPath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// Normalizes a path taken from another process's argv.
func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).canonicalPath
}
