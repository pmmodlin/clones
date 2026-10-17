import Foundation
#if os(macOS)
import AppKit
#endif

/// Copy guard: macOS may start a profile's Claude.app copy ("Claude 1.app") without arguments —
/// from a pinned Dock icon, from Finder, via "Open With". Without `--user-data-dir` it would run on
/// the default profile's data. The guard kills such a process (SIGKILL, before Electron writes much)
/// and starts the profile properly. It runs in the background as a LaunchAgent (`clones agent`).
public struct CopyGuard {
    public let paths: Paths
    public var log: (String) -> Void

    public init(paths: Paths, log: @escaping (String) -> Void) {
        self.paths = paths
        self.log = log
    }

    /// The profile whose copy runs without `--user-data-dir`; nil if the process is fine.
    public func strayOwner(_ process: ClaudeProcess) -> String? {
        guard process.userDataDir == nil else { return nil }
        let bundles = paths.bundlesDir.canonicalPath + "/"
        let exec = URL(fileURLWithPath: process.executable).canonicalPath
        guard exec.hasPrefix(bundles),
              let owner = exec.dropFirst(bundles.count).split(separator: "/").first.map(String.init),
              owner != Profile.defaultName
        else { return nil }
        return owner
    }

    /// One pass: find copies running without a profile, kill them and start the profile properly.
    @discardableResult
    public func sweep() -> Int {
        guard let store = try? ProfileStore(paths: paths),
              let original = try? ClaudeApp.locate(configured: store.config.claudeApp, paths: paths)
        else { return 0 }
        let strays = ProcessScanner.claudeProcesses(app: original).compactMap { process in
            strayOwner(process).map { (process, $0) }
        }
        guard !strays.isEmpty else { return 0 }

        for (process, _) in strays { kill(process.pid, SIGKILL) }
        _ = Launcher.waitForExit(strays.map(\.0.pid), timeout: 3)

        for owner in Set(strays.map(\.1)) {
            guard let profile = try? store.profile(named: owner) else {
                log(tr("PID \(strays.first { $0.1 == owner }!.0.pid): copy of the removed profile “\(owner)” closed", "PID \(strays.first { $0.1 == owner }!.0.pid): копия профиля «\(owner)», которого больше нет, — закрыта"))
                continue
            }
            if let pid = store.instanceMap(app: original).pid(for: profile) {
                Launcher.focus(pid: pid)
                log(tr("“\(owner)”: copy without a profile closed, showing the running PID \(pid)", "«\(owner)»: копия без профиля закрыта, показан уже запущенный PID \(pid)"))
                continue
            }
            do {
                let pid = try Launcher.launch(profile, app: BundleCopy.launchApp(for: profile, paths: paths, original: original))
                Launcher.focus(pid: pid)
                log(tr("“\(owner)”: copy without a profile closed, profile started properly (PID \(pid))", "«\(owner)»: копия без профиля закрыта, профиль запущен правильно (PID \(pid))"))
            } catch {
                log(tr("“\(owner)”: could not restart the profile: \(error)", "«\(owner)»: не удалось перезапустить профиль: \(error)"))
            }
        }
        return strays.count
    }

    /// The LaunchAgent loop: react to Claude launches, plus an occasional poll just in case.
    public func runForever() -> Never {
        let watcher = self
        watcher.sweep()
        #if os(macOS)
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == ClaudeApp.bundleIdentifier { watcher.sweep() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in watcher.sweep() }
        RunLoop.main.run()
        exit(0)
        #else
        while true {
            Thread.sleep(forTimeInterval: 1)
            watcher.sweep()
        }
        #endif
    }
}

/// The LaunchAgent that keeps the copy guard running.
public enum GuardAgent {
    public static let label = "dev.clones.agent"

    public static func plistURL(paths: Paths) -> URL {
        paths.home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static func logURL(paths: Paths) -> URL {
        paths.home.appendingPathComponent("Library/Logs/clones-agent.log")
    }

    public static func plist(executable: String, paths: Paths) throws -> Data {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "agent", "run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "StandardOutPath": logURL(paths: paths).path,
            "StandardErrorPath": logURL(paths: paths).path,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    #if os(macOS)
    private static var domain: String { "gui/\(getuid())" }

    public static func isLoaded() -> Bool {
        (try? Shell.run("/bin/launchctl", ["print", "\(domain)/\(label)"]))?.status == 0
    }

    /// Installs (or reinstalls if the clones path changed) and starts the agent.
    public static func install(executable: String, paths: Paths) throws {
        let url = plistURL(paths: paths)
        let data = try plist(executable: executable, paths: paths)
        if isLoaded(), (try? Data(contentsOf: url)) == data { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let result = try Shell.run("/bin/launchctl", ["bootstrap", domain, url.path])
        if result.status != 0 && !isLoaded() {
            throw ClonesError.other("launchctl bootstrap: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// Restarts a running agent so it picks up new paths.
    public static func restartIfLoaded() {
        guard isLoaded() else { return }
        _ = try? Shell.run("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"])
    }

    public static func uninstall(paths: Paths) throws {
        _ = try? Shell.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        let url = plistURL(paths: paths)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    #endif
}
