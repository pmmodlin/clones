import Foundation

/// Moves an installation made by an early development build (data in `~/Library/Application Support/clones`, metadata in
/// `~/.config/clones`) to the `~/.clones` layout. Must only run while no Claude instance is open:
/// moving the folder of a running Chromium would split its data between two places.
public enum LayoutMigration {
    /// The standard layout to migrate a legacy one to (same home and overrides).
    public static func target(for legacy: Paths) -> Paths {
        .standard(home: legacy.home, root: legacy.home.appendingPathComponent(".clones", isDirectory: true),
                  defaultUserData: legacy.defaultUserData, applicationsDir: legacy.applicationsDir,
                  legacyApplicationsDirs: legacy.legacyApplicationsDirs)
    }

    /// Moves everything and returns human-readable notes about what moved.
    @discardableResult
    public static func migrate(from old: Paths, to new: Paths) throws -> [String] {
        let fm = FileManager.default
        var config = try ConfigFile.load(from: old.configFile)
        var notes: [String] = []
        try fm.createDirectory(at: new.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Profiles: every folder in the old profiles dir (known to config.json or not).
        let oldProfiles = (try? fm.contentsOfDirectory(at: old.profilesDir, includingPropertiesForKeys: nil)) ?? []
        for dir in oldProfiles where !dir.lastPathComponent.hasPrefix(".") {
            let destination = new.profilesDir.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            if fm.fileExists(atPath: destination.path) {
                throw ClonesError.other(tr("Cannot move \(old.abbreviate(dir)): \(new.abbreviate(destination)) already exists.",
                                           "Не могу перенести \(old.abbreviate(dir)): \(new.abbreviate(destination)) уже существует."))
            }
            try fm.moveItem(at: dir, to: destination)
            notes.append("\(old.abbreviate(dir)) → \(new.abbreviate(destination))")
        }

        for (from, to) in [(old.bundlesDir, new.bundlesDir), (old.iconsDir, new.iconsDir)] where fm.fileExists(atPath: from.path) {
            if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
            try fm.moveItem(at: from, to: to)
        }
        reregisterCopies(from: old.bundlesDir, to: new.bundlesDir)

        // Absolute paths inside the metadata: custom icons and CLAUDE_CONFIG_DIR of each profile.
        func rewrite(_ path: String) -> String {
            for (from, to) in [(old.profilesDir.path, new.profilesDir.path), (old.iconsDir.path, new.iconsDir.path)] {
                if path == from || path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
            }
            return path
        }
        for (name, var meta) in config.profiles {
            meta.icon = meta.icon.map(rewrite)
            meta.env = meta.env?.mapValues(rewrite)
            config.profiles[name] = meta
        }
        try config.save(to: new.configFile)

        // The launcher scripts' fallback (used only without clones) points at the old copy location.
        for launcher in AppBuilder.existingLaunchers(paths: new) {
            let script = launcher.url.appendingPathComponent("Contents/MacOS/launcher")
            if let text = try? String(contentsOf: script, encoding: .utf8), text.contains(old.bundlesDir.path) {
                try? text.replacingOccurrences(of: old.bundlesDir.path, with: new.bundlesDir.path)
                    .write(to: script, atomically: true, encoding: .utf8)
            }
        }

        // Clean up what is left of the old layout (only if empty).
        try? fm.removeItem(at: old.configFile)
        for leftover in [old.configFile.deletingLastPathComponent(), old.profilesDir, old.root] {
            if let items = try? fm.contentsOfDirectory(atPath: leftover.path), items.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: leftover)
            }
        }
        return notes
    }

    private static func reregisterCopies(from old: URL, to new: URL) {
        #if os(macOS)
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let profiles = (try? FileManager.default.contentsOfDirectory(at: new, includingPropertiesForKeys: nil)) ?? []
        for profile in profiles {
            let apps = (try? FileManager.default.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil)) ?? []
            for app in apps where app.pathExtension == "app" {
                let oldApp = old.appendingPathComponent(profile.lastPathComponent).appendingPathComponent(app.lastPathComponent)
                _ = try? Shell.run(lsregister, ["-u", oldApp.path])
                _ = try? Shell.run(lsregister, ["-f", app.path])
            }
        }
        #endif
    }
}
