import ArgumentParser
import ClonesCore
import Foundation

@main
struct Clones: ParsableCommand {
    static let version = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "clones",
        abstract: tr("Several isolated Claude Desktop instances side by side.",
                     "Несколько изолированных инстансов Claude Desktop одновременно."),
        discussion: tr("""
        Each profile is a separate Claude userData folder (--user-data-dir): its own sign-in, chats, \
        claude_desktop_config.json with MCP servers, settings and cache. The “default” profile is plain Claude.
        Profiles live in ~/.clones/<name> (with Claude Code in ~/.clones/<name>/claude-code).
        """, """
        Каждый профиль — отдельная userData-папка Claude (--user-data-dir): свой логин, чаты, \
        claude_desktop_config.json с MCP-серверами, настройки и кэш. Профиль «default» — обычный Claude.
        Профили лежат в ~/.clones/<name> (Claude Code профиля — в ~/.clones/<name>/claude-code).
        """),
        version: version,
        subcommands: [
            New.self, List.self, Open.self, Login.self, Kill.self, Remove.self, Rename.self,
            Dir.self, Config.self, MakeApp.self, Install.self, Agent.self, Doctor.self, Completion.self,
        ]
    )
}

/// Shared command dependencies.
struct Context {
    let store: ProfileStore
    let style: Style
    let errStyle: Style

    init() throws {
        style = Style.detect()
        errStyle = Style.detect(fd: STDERR_FILENO)
        store = try ProfileStore(paths: Context.resolvePaths(errStyle: errStyle))
    }

    /// `~/.clones`, migrating an early-build layout first when no Claude instance is open.
    static func resolvePaths(errStyle: Style) throws -> Paths {
        let paths = Paths.current()
        guard paths.isLegacy else { return paths }
        let target = LayoutMigration.target(for: paths)
        let app = try? ClaudeApp.locate(configured: nil, paths: paths)
        let running = ProcessScanner.claudeProcesses(app: app)
        if !running.isEmpty {
            FileHandle.standardError.write(Data((errStyle.yellow(tr("note: ", "примечание: ")) + tr(
                "clones now keeps its data in \(target.abbreviate(target.root)). Quit every Claude window (clones kill --all) and it will move there on the next run.",
                "clones теперь хранит данные в \(target.abbreviate(target.root)). Закройте все окна Claude (clones kill --all) — при следующем запуске данные переедут туда.") + "\n").utf8))
            return paths
        }
        let moved = try LayoutMigration.migrate(from: paths, to: target)
        FileHandle.standardError.write(Data((tr("Moved clones data to ", "Данные clones перенесены в ") + target.abbreviate(target.root)
            + (moved.isEmpty ? "" : ":\n  " + moved.joined(separator: "\n  ")) + "\n").utf8))
        #if os(macOS)
        // The background guard watches the copy folder it started with.
        GuardAgent.restartIfLoaded()
        #endif
        return target
    }

    var paths: Paths { store.paths }

    func claudeApp() throws -> ClaudeApp {
        try ClaudeApp.locate(configured: store.config.claudeApp, paths: paths)
    }

    func instances(app: ClaudeApp?) -> InstanceMap {
        store.instanceMap(app: app)
    }

    func warn(_ message: String) {
        FileHandle.standardError.write(Data((errStyle.yellow(tr("warning: ", "предупреждение: ")) + message + "\n").utf8))
    }

    func note(_ message: String) {
        FileHandle.standardError.write(Data((errStyle.dim(message) + "\n").utf8))
    }

    /// Absolute path of this clones binary, for launchers. Symlinks are kept as is:
    /// Homebrew's /opt/homebrew/bin/clones survives upgrades, Cellar/<version> does not.
    static var executablePath: String {
        let argv0 = CommandLine.arguments.first ?? "clones"
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0).standardizedFileURL.path
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/\(argv0)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).standardizedFileURL.path
            }
        }
        return argv0
    }
}

extension Context {
    /// The launcher in /Applications (pinned in the Dock) and, with `copy`, a Claude.app copy named after
    /// the profile, so the running profile shows up as “Claude Test1” rather than “Claude”.
    func installApps(for profile: Profile, app: ClaudeApp, copy: Bool, overwrite: Bool) throws {
        let builder = AppBuilder(paths: paths, app: app, clonesExecutable: Context.executablePath)
        let url = try builder.build(for: profile, overwrite: overwrite)
        print(tr("Launcher: \(paths.abbreviate(url)) — pin it to the Dock", "Лаунчер: \(paths.abbreviate(url)) — закрепите его в Dock"))

        if !copy {
            if BundleCopy.existing(for: profile, paths: paths) != nil, instances(app: app).pid(for: profile) == nil {
                try BundleCopy.remove(profile.name, paths: paths)
                print(tr("Claude copy removed: the profile will start with the original Claude.app", "Копия Claude удалена: профиль будет запускаться оригинальным Claude.app"))
            }
            return
        }
        if let pid = instances(app: app).pid(for: profile) {
            warn(tr("“\(profile.name)” is running (PID \(pid)), so its Claude copy was not rebuilt. Quit it and run: clones app \(profile.name)", "«\(profile.name)» запущен (PID \(pid)) — копию Claude не пересоздаю. Закройте его и повторите: clones app \(profile.name)"))
            return
        }
        do {
            let result = try BundleCopy.build(for: profile, from: app, paths: paths, icon: builder.iconFile(for: profile))
            print(tr("Claude copy: \(paths.abbreviate(result.url)) — the running profile shows up as “\(profile.appTitle)”", "Копия Claude: \(paths.abbreviate(result.url)) — в Dock запущенный профиль будет «\(profile.appTitle)»"))
            #if os(macOS)
            // Without the guard a Dock-pinned copy would open without a profile, on the default data.
            // CLONES_NO_AGENT: tests must not replace the real guard (same launchd label).
            if ProcessInfo.processInfo.environment["CLONES_NO_AGENT"] == nil, !GuardAgent.isLoaded() {
                do {
                    try GuardAgent.install(executable: Context.executablePath, paths: paths)
                    print(tr("Started the background copy guard (clones agent): Dock-pinned copies will open their profile", "Запущен фоновый страж копий (clones agent): закреплённые в Dock копии будут открывать свой профиль"))
                } catch {
                    warn(tr("the copy guard is not running (\(error)). Do not open copies directly, or run: clones agent install", "страж копий не запущен (\(error)). Не открывайте копии напрямую или выполните: clones agent install"))
                }
            }
            #endif
            #if os(macOS)
            if !result.iconApplied {
                note(tr("The badge icon could not be applied to the copy without breaking its signature; the Dock will show the regular Claude icon.", "Иконку с плашкой на копию поставить не удалось без поломки подписи — в Dock у неё будет обычная иконка Claude."))
            }
            #endif
        } catch {
            warn(tr("Claude.app copy not created (\(error)). The profile will start with the original Claude.app", "копия Claude.app не создана (\(error)). Профиль будет запускаться оригинальным Claude.app"))
        }
    }
}

enum Prompt {
    /// Yes/no prompt. Without a TTY it is an error: never delete data silently.
    static func confirm(_ question: String, what: String) throws -> Bool {
        guard isatty(STDIN_FILENO) == 1 else { throw ClonesError.confirmationRequired(what) }
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return ["y", "yes", "д", "да"].contains(answer)
    }
}

/// Profile name completion: the shell calls `clones ---completion …`, which reads config.json.
func profileNameCompletion(includeDefault: Bool) -> CompletionKind {
    .custom { _ in
        guard let store = try? ProfileStore() else { return [] }
        return store.profileNames.filter { includeDefault || $0 != Profile.defaultName }
    }
}

extension Profile {
    func displayName(style: Style) -> String {
        let color = meta?.color.flatMap(HexColor.init) ?? (isDefault ? nil : HexColor.automatic(for: name))
        return style.swatch(color) + name
    }
}

/// Localized help text for arguments, options and flags.
func help(_ english: String, _ russian: String) -> ArgumentHelp {
    ArgumentHelp(tr(english, russian))
}
