import Foundation
#if os(macOS)
import AppKit
#endif

/// The installed Claude.app. clones only reads and launches it; the bundle and signature are never modified.
public struct ClaudeApp: Sendable {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"

    public let bundleURL: URL
    public let executableURL: URL
    public let version: String?
    public let bundleID: String?
    public let teamID: String?

    public init(bundleURL: URL) throws {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw ClonesError.notAClaudeBundle(bundleURL.path) }

        let executableName = plist["CFBundleExecutable"] as? String ?? "Claude"
        let executable = bundleURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw ClonesError.notAClaudeBundle(bundleURL.path)
        }
        self.bundleURL = bundleURL
        self.executableURL = executable
        self.version = plist["CFBundleShortVersionString"] as? String
        self.bundleID = plist["CFBundleIdentifier"] as? String
        self.teamID = plist["ElectronTeamID"] as? String
    }

    /// Lookup order: CLONES_CLAUDE_APP → config.json → /Applications → ~/Applications → LaunchServices.
    public static func locate(configured: String?, paths: Paths,
                              environment env: [String: String] = ProcessInfo.processInfo.environment) throws -> ClaudeApp {
        var candidates: [String] = []
        if let fromEnv = env["CLONES_CLAUDE_APP"], !fromEnv.isEmpty { candidates.append(fromEnv) }
        if let configured, !configured.isEmpty { candidates.append(configured) }
        candidates.append("/Applications/Claude.app")
        candidates.append(paths.home.appendingPathComponent("Applications/Claude.app").path)
        #if os(macOS)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            candidates.append(url.path)
        }
        #endif

        var seen = Set<String>()
        let unique = candidates
            .map { ($0 as NSString).expandingTildeInPath }
            .filter { seen.insert($0).inserted }
        for path in unique where FileManager.default.fileExists(atPath: path) {
            if let app = try? ClaudeApp(bundleURL: URL(fileURLWithPath: path, isDirectory: true)) {
                return app
            }
        }
        throw ClonesError.claudeNotFound(searched: unique)
    }
}
