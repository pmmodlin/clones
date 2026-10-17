import Foundation
#if os(macOS)
import AppKit
#endif

/// A copy of Claude.app named after the profile ("Claude Test1.app") so that the running instance
/// carries the profile name in the Dock and ⌘Tab. Nothing inside the bundle changes, so Anthropic's
/// signature stays valid (the .app folder name is not signed). On APFS the copy is a clone
/// (clonefile) and takes almost no space until Claude updates.
///
/// Copies live in `~/.clones/.bundles.noindex/<profile>/`; `.noindex`
/// hides them from Spotlight. Started without `--user-data-dir` a copy would open the default
/// profile's data, which is what CopyGuard fixes. `clones run` and the launcher start it properly.
public enum BundleCopy {
    public static func directory(for name: String, paths: Paths) -> URL {
        paths.bundlesDir.appendingPathComponent(name, isDirectory: true)
    }

    public static func url(for profile: Profile, paths: Paths) -> URL {
        directory(for: profile.name, paths: paths).appendingPathComponent(profile.appTitle + ".app", isDirectory: true)
    }

    /// The profile's existing copy (any .app in its folder; the name may change with the title).
    public static func existing(for profile: Profile, paths: Paths) -> ClaudeApp? {
        let dir = directory(for: profile.name, paths: paths)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return items.filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .lazy.compactMap { try? ClaudeApp(bundleURL: $0) }.first
    }

    /// What to launch the profile with: its copy if there is one, otherwise the original Claude.app.
    public static func launchApp(for profile: Profile, paths: Paths, original: ClaudeApp) -> ClaudeApp {
        existing(for: profile, paths: paths) ?? original
    }

    public struct Result {
        public let url: URL
        /// Whether the badge icon could be applied without breaking the signature.
        public let iconApplied: Bool
    }

    /// Creates (or recreates) the copy from the original Claude.app.
    /// `icon` is the profile's badge .icns (from the launcher); it is kept only if the signature still verifies.
    public static func build(for profile: Profile, from original: ClaudeApp, paths: Paths, icon: URL?) throws -> Result {
        let fm = FileManager.default
        let dir = directory(for: profile.name, paths: paths)
        let target = url(for: profile, paths: paths)
        try fm.createDirectory(at: paths.bundlesDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dir.path) { try remove(profile.name, paths: paths) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            // On APFS FileManager.copyItem uses clonefile: instant and space-free.
            try fm.copyItem(at: original.bundleURL, to: target)
        } catch {
            try? fm.removeItem(at: dir)
            throw ClonesError.other(tr("Could not copy Claude.app: \(error.localizedDescription)", "Не удалось скопировать Claude.app: \(error.localizedDescription)"))
        }

        var iconApplied = false
        #if os(macOS)
        if let problem = verifySignature(target) {
            try? fm.removeItem(at: dir)
            throw ClonesError.other(tr("The Claude.app copy failed signature verification (\(problem)); the copy was removed.", "Копия Claude.app не прошла проверку подписи (\(problem)); копия удалена."))
        }
        if let icon, let image = NSImage(contentsOf: icon), NSWorkspace.shared.setIcon(image, forFile: target.path, options: []) {
            if verifySignature(target) == nil {
                iconApplied = true
            } else {
                // The icon breaks the signature: roll back; the Dock still shows the profile name.
                _ = NSWorkspace.shared.setIcon(nil, forFile: target.path, options: [])
            }
        }
        _ = try? Shell.run(lsregister, ["-f", target.path])
        #endif
        return Result(url: target, iconApplied: iconApplied)
    }

    public static func remove(_ name: String, paths: Paths) throws {
        let dir = directory(for: name, paths: paths)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        #if os(macOS)
        if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for app in items where app.pathExtension == "app" { _ = try? Shell.run(lsregister, ["-u", app.path]) }
        }
        #endif
        try FileManager.default.removeItem(at: dir)
    }

    #if os(macOS)
    static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// nil if the signature is valid, otherwise the codesign error.
    public static func verifySignature(_ bundle: URL) -> String? {
        guard let result = try? Shell.run("/usr/bin/codesign", ["--verify", bundle.path]) else { return tr("codesign did not run", "codesign не запустился") }
        if result.status == 0 { return nil }
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? tr("codesign: exit code \(result.status)", "codesign: код \(result.status)") : text
    }
    #endif
}
