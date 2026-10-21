import Foundation

/// clones 0.1.0 pointed a profile's CLAUDE_CONFIG_DIR at `<profile>/claude-code`. Claude Desktop keeps the Claude Code
/// versions it downloads in that very folder (`<userData>/claude-code/<version>`) and, after updating them, deletes
/// every other entry there: session transcripts, skills, settings. This moves such a profile to `<profile>/claude-config`.
/// Must only run while the profile is closed: its Claude Code sessions write into the folder.
public enum ClaudeCodeDirMigration {
    /// Claude Desktop's own folder inside a profile.
    public static func desktopDir(of profile: Profile) -> URL {
        profile.dataDir.appendingPathComponent("claude-code", isDirectory: true)
    }

    /// Profiles whose CLAUDE_CONFIG_DIR is Claude Desktop's folder.
    public static func affected(in store: ProfileStore) -> [Profile] {
        store.allProfiles().filter { profile in
            guard !profile.isDefault, let dir = profile.environment["CLAUDE_CONFIG_DIR"] else { return false }
            return URL(fileURLWithPath: dir).canonicalPath == desktopDir(of: profile).canonicalPath
        }
    }

    /// A folder Claude Desktop keeps there: a Claude Code version like `2.1.304`.
    static func isDesktopEntry(_ name: String) -> Bool {
        name.range(of: #"^\d+(\.\d+)+"#, options: .regularExpression) != nil
    }

    /// Moves everything but the Desktop's versions, switches CLAUDE_CONFIG_DIR and fixes the launcher's fallback line.
    /// Returns the names that could not be moved because they already exist in the new folder.
    @discardableResult
    public static func migrate(_ profile: Profile, store: ProfileStore) throws -> [String] {
        let fm = FileManager.default
        let old = desktopDir(of: profile)
        let new = profile.claudeCodeDir
        try fm.createDirectory(at: new, withIntermediateDirectories: true)

        var skipped: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where !isDesktopEntry(name) {
            let item = old.appendingPathComponent(name)
            // Symlinks are left alone: Claude Desktop skips them, and they may point into the new folder already.
            if (try? fm.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType) == .typeSymbolicLink { continue }
            let destination = new.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) {
                skipped.append(name)
                continue
            }
            try fm.moveItem(at: item, to: destination)
        }

        let oldValue = profile.environment["CLAUDE_CONFIG_DIR"] ?? old.path
        try store.update(profile.name) { meta in
            meta.env = (meta.env ?? [:]).merging(["CLAUDE_CONFIG_DIR": new.path]) { $1 }
        }

        // The launcher's fallback (used only without clones) passes the variable itself.
        for launcher in AppBuilder.existingLaunchers(paths: store.paths) where launcher.profile == profile.name {
            let script = launcher.url.appendingPathComponent("Contents/MacOS/launcher")
            let from = shellQuote("CLAUDE_CONFIG_DIR=\(oldValue)")
            if let text = try? String(contentsOf: script, encoding: .utf8), text.contains(from) {
                try? text.replacingOccurrences(of: from, with: shellQuote("CLAUDE_CONFIG_DIR=\(new.path)"))
                    .write(to: script, atomically: false, encoding: .utf8)
            }
        }
        return skipped
    }
}
