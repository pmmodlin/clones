import Foundation
#if os(macOS)
import AppKit
#endif

/// Launching, focusing and quitting instances.
public enum Launcher {
    /// Starts a new Claude process with the profile's arguments and waits for it to show up.
    /// Always a new instance: otherwise LaunchServices just activates any running Claude with the
    /// same bundle id, and you could get the `work` window instead of `default`.
    public static func launch(_ profile: Profile, app: ClaudeApp, timeout: TimeInterval = 20) throws -> Int32 {
        let before = Set(ProcessScanner.claudeProcesses(app: app).map(\.pid))
        try spawn(app: app, arguments: profile.launchArguments, environment: profile.environment)

        let deadline = Date().addingTimeInterval(timeout)
        let target = profile.dataDir.canonicalPath
        while Date() < deadline {
            let match = ProcessScanner.claudeProcesses(app: app).first { process in
                guard !before.contains(process.pid) else { return false }
                if profile.isDefault { return process.userDataDir == nil }
                return process.userDataDir.map(canonicalPath) == target
            }
            if let match { return match.pid }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw ClonesError.launchFailed(tr("the process did not appear within \(Int(timeout)) s. Details: clones doctor", "процесс не появился за \(Int(timeout)) с. Подробности: clones doctor"))
    }

    #if os(macOS)
    private static func spawn(app: ClaudeApp, arguments: [String], environment: [String: String]) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.activates = true
        configuration.addsToRecentItems = false
        if !environment.isEmpty { configuration.environment = environment }

        final class Outcome: @unchecked Sendable {
            let lock = NSLock()
            var error: Error?
        }
        let done = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: configuration) { _, error in
            outcome.lock.lock()
            outcome.error = error
            outcome.lock.unlock()
            done.signal()
        }
        // A timeout is not an error: the process may already be starting, and a second launch on the
        // same userData folder would corrupt it. launch() keeps waiting for the process instead.
        _ = done.wait(timeout: .now() + 30)
        outcome.lock.lock()
        let launchError = outcome.error
        outcome.lock.unlock()
        if let launchError {
            // Fallback: the same LaunchServices, via /usr/bin/open.
            var args = ["-n", "-a", app.bundleURL.path]
            for (key, value) in environment.sorted(by: { $0.key < $1.key }) { args += ["--env", "\(key)=\(value)"] }
            if !arguments.isEmpty { args += ["--args"] + arguments }
            let result = try Shell.run("/usr/bin/open", args)
            if result.status != 0 {
                let details = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw ClonesError.launchFailed("\(launchError.localizedDescription) \(details)")
            }
        }
    }

    /// Brings this particular process to the front. `open -a Claude` would pick an arbitrary
    /// instance with the same bundle id.
    @discardableResult
    public static func focus(pid: Int32) -> Bool {
        // "Reopen" (like a Dock click): the Electron app creates a window if all were closed.
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                            targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                            transactionID: AETransactionID(kAnyTransactionID))
        _ = try? reopen.sendEvent(options: [.noReply], timeout: 2)

        guard let running = NSRunningApplication(processIdentifier: pid) else { return false }
        if running.isHidden { running.unhide() }
        return running.activate(options: [.activateAllWindows])
    }

    /// Graceful quit: the "quit" Apple Event, like ⌘Q. SIGTERM if the app is not known to
    /// LaunchServices (started as a bare binary).
    public static func requestQuit(pid: Int32) {
        if let running = NSRunningApplication(processIdentifier: pid), running.terminate() { return }
        kill(pid, SIGTERM)
    }

    public static func forceQuit(pid: Int32) {
        if let running = NSRunningApplication(processIdentifier: pid), running.forceTerminate() { return }
        kill(pid, SIGKILL)
    }
    #else
    // Linux: only for testing the logic on CI without macOS; "Claude.app" there is a stub.
    private static func spawn(app: ClaudeApp, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/setsid")
        process.arguments = [app.executableURL.path] + arguments
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { $1 }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ClonesError.launchFailed(error.localizedDescription) }
    }

    @discardableResult
    public static func focus(pid: Int32) -> Bool { ProcessScanner.isAlive(pid) }
    public static func requestQuit(pid: Int32) { kill(pid, SIGTERM) }
    public static func forceQuit(pid: Int32) { kill(pid, SIGKILL) }
    #endif

    /// Escalating quit: "quit" (⌘Q) → SIGTERM (Chromium shuts down cleanly on it too)
    /// → SIGKILL only with `force`. Returns the PIDs still alive.
    public static func terminate(_ pids: [Int32], timeout: TimeInterval, force: Bool) -> [Int32] {
        pids.forEach(requestQuit)
        var alive = waitForExit(pids, timeout: timeout * 0.6)
        if !alive.isEmpty {
            alive.forEach { kill($0, SIGTERM) }
            alive = waitForExit(alive, timeout: timeout * 0.4)
        }
        if force && !alive.isEmpty {
            alive.forEach(forceQuit)
            alive = waitForExit(alive, timeout: 5)
        }
        return alive
    }

    /// Waits for the processes to exit. Returns the PIDs still alive.
    public static func waitForExit(_ pids: [Int32], timeout: TimeInterval) -> [Int32] {
        let deadline = Date().addingTimeInterval(timeout)
        var alive = pids.filter(ProcessScanner.isAlive)
        while !alive.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            alive = alive.filter(ProcessScanner.isAlive)
        }
        return alive
    }
}

public enum Shell {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
    }

    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }
}
