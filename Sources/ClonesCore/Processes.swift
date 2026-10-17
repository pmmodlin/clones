import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A running main Claude process (not a Helper/Renderer/GPU process).
public struct ClaudeProcess: Equatable, Sendable {
    public let pid: Int32
    public let executable: String
    public let arguments: [String]

    /// The `--user-data-dir` value, if any. nil means plain Claude (the default profile).
    public var userDataDir: String? { ProcessScanner.userDataDir(in: arguments) }
}

public enum ProcessScanner {
    /// Extracts `--user-data-dir` from argv (both `--user-data-dir=X` and `--user-data-dir X`).
    public static func userDataDir(in arguments: [String]) -> String? {
        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            for prefix in ["--user-data-dir=", "-user-data-dir="] where arg.hasPrefix(prefix) {
                let value = String(arg.dropFirst(prefix.count))
                return value.isEmpty ? nil : value
            }
            if arg == "--user-data-dir" || arg == "-user-data-dir" {
                return iterator.next()
            }
        }
        return nil
    }

    /// Is this Claude's main executable? Compared with the located bundle, and by path suffix
    /// for another Claude.app elsewhere.
    static func isClaudeMainExecutable(_ path: String, app: ClaudeApp?) -> Bool {
        if let app, canonicalPath(path) == app.executableURL.canonicalPath { return true }
        if path.hasSuffix("/Claude.app/Contents/MacOS/Claude") { return true }
        // Profile copies ("Claude Test1.app"): same binary, same bundle id, different folder name.
        guard let app, let bundleID = app.bundleID,
              path.hasSuffix("/Contents/MacOS/" + app.executableURL.lastPathComponent)
        else { return false }
        let bundle = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app" else { return false }
        return (try? ClaudeApp(bundleURL: bundle))?.bundleID == bundleID
    }

    public static func claudeProcesses(app: ClaudeApp?) -> [ClaudeProcess] {
        allProcesses().compactMap { pid, executable, argv in
            #if os(macOS)
            guard isClaudeMainExecutable(executable, app: app) else { return nil }
            return ClaudeProcess(pid: pid, executable: executable, arguments: Array(argv.dropFirst()))
            #else
            // On Linux (tests only) "Claude" may be a script: argv = [/bin/sh, …/Contents/MacOS/Claude, args…].
            // Skip wrappers such as setsid: the real process has Claude or a shell as argv[0].
            guard let index = argv.firstIndex(where: { isClaudeMainExecutable($0, app: app) }),
                  index == 0 || (index == 1 && argv[0].hasSuffix("sh"))
            else { return nil }
            return ClaudeProcess(pid: pid, executable: argv[index], arguments: Array(argv[(index + 1)...]))
            #endif
        }
        .sorted { $0.pid < $1.pid }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        #if os(Linux)
        // In containers without an init process an exited child can stay a zombie forever.
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")"),
           stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z") {
            return false
        }
        #endif
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    // MARK: - Platform specific

    #if os(macOS)
    static func allProcesses() -> [(Int32, String, [String])] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimated) + 64)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        let me = getuid()
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, owner(of: pid) == me, let (exec, argv) = processArguments(pid) else { return nil }
            return (pid, exec, argv)
        }
    }

    private static func owner(of pid: Int32) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ucred.cr_uid
    }

    /// argv via sysctl KERN_PROCARGS2: unlike `ps`, paths with spaces ("Application Support")
    /// do not merge with neighbouring arguments.
    static func processArguments(_ pid: Int32) -> (String, [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs2(Array(buffer.prefix(size)))
    }
    #else
    static func allProcesses() -> [(Int32, String, [String])] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        let me = getuid()
        return entries.compactMap { entry in
            guard let pid = Int32(entry) else { return nil }
            var st = stat()
            guard stat("/proc/\(entry)", &st) == 0, st.st_uid == me,
                  let data = FileManager.default.contents(atPath: "/proc/\(entry)/cmdline"), !data.isEmpty
            else { return nil }
            let argv = data.split(separator: 0, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
                .dropLast(data.last == 0 ? 1 : 0)
            let exec = (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(entry)/exe")) ?? argv.first ?? ""
            return (pid, exec, Array(argv))
        }
    }
    #endif

    /// KERN_PROCARGS2 layout: int32 argc, executable path, NUL padding, argv[0..argc), env…
    public static func parseProcArgs2(_ bytes: [UInt8]) -> (String, [String])? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var index = 4

        func readCString() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count && bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }

        guard let exec = readCString() else { return nil }
        while index < bytes.count && bytes[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<max(argc, 0) {
            guard let arg = readCString() else { break }
            argv.append(arg)
        }
        return (exec, argv)
    }
}
