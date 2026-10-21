import ArgumentParser
import ClonesCore
import Foundation

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: tr("Create a profile.", "Создать профиль."),
        discussion: tr("""
        Examples:
          clones add work                          profile, “Claude Work” launcher in /Applications and a Claude copy
          clones add test --clone-mcp-from work    with the MCP servers of work
          clones add personal --color '#30A46C'    custom badge color on the icon
          clones add lab --no-isolate-claude-code  share ~/.claude (Claude Code skills/settings) with plain Claude
        """, """
        Примеры:
          clones add work                          профиль, лаунчер «Claude Work» в /Applications и копия Claude
          clones add test --clone-mcp-from work    с MCP-серверами из work
          clones add personal --color '#30A46C'    свой цвет плашки на иконке
          clones add lab --no-isolate-claude-code  общий с обычным Claude ~/.claude (скилы и настройки Claude Code)
        """)
    )

    @Argument(help: help("Profile name: Latin letters, digits, “-”, “_”, “.”.", "Имя профиля: латиница, цифры, «-», «_», «.»."))
    var name: String

    @Option(help: help("Badge color on the launcher icon, hex (#RRGGBB).", "Цвет плашки на иконке лаунчера, hex (#RRGGBB)."))
    var color: String?

    @Option(help: help("Custom launcher icon (.png, .icns, .jpg).", "Своя иконка для лаунчера (.png, .icns, .jpg)."), completion: .file())
    var icon: String?

    @Option(help: help("Launcher name (default “Claude <Name>”).", "Имя .app-лаунчера (по умолчанию «Claude <Name>»)."))
    var title: String?

    @Option(name: .customLong("clone-mcp-from"), help: help("Copy mcpServers from another profile's claude_desktop_config.json.", "Скопировать mcpServers из claude_desktop_config.json другого профиля."),
            completion: profileNameCompletion(includeDefault: true))
    var cloneMCPFrom: String?

    @Flag(inversion: .prefixedNo,
          help: help("Own Claude Code folder for the Code tab (CLAUDE_CONFIG_DIR: skills, settings, sessions); --no-isolate-claude-code shares ~/.claude (on by default).",
                     "Своя папка Claude Code для вкладки Code (CLAUDE_CONFIG_DIR: скилы, настройки, сессии); --no-isolate-claude-code — общий ~/.claude (по умолчанию да)."))
    var isolateClaudeCode = true

    @Flag(inversion: .prefixedNo,
          help: help("Create a launcher in /Applications for the Dock and Spotlight (on by default).", "Создать .app-лаунчер в /Applications для Dock/Spotlight (по умолчанию да)."))
    var app = true

    @Flag(inversion: .prefixedNo,
          help: help("Make a Claude.app copy named after the profile so it has its own name in the Dock (on by default).", "Сделать копию Claude.app под именем профиля, чтобы в Dock он назывался по-своему (по умолчанию да)."))
    var copy = true

    func validate() throws {
        if let color, HexColor(color) == nil { throw ValidationError(ClonesError.invalidColor(color).description) }
    }

    func run() throws {
        let ctx = try Context()
        var env: [String: String]?
        if isolateClaudeCode {
            env = ["CLAUDE_CONFIG_DIR": ctx.store.dataDir(for: name).appendingPathComponent(Profile.claudeCodeDirName).path]
        }
        let profile = try ctx.store.create(name: name, color: color, iconPath: icon, title: title,
                                           env: env, cloneMCPFrom: cloneMCPFrom)
        print(tr("Profile \(ctx.style.bold(profile.displayName(style: ctx.style))) created: \(ctx.paths.abbreviate(profile.dataDir))", "Профиль \(ctx.style.bold(profile.displayName(style: ctx.style))) создан: \(ctx.paths.abbreviate(profile.dataDir))"))
        if let source = cloneMCPFrom {
            let names = MCPConfig.serverNames(in: profile.mcpConfigFile) ?? []
            print(tr("MCP servers from “\(source)”: ", "MCP-серверы из «\(source)»: ") + (names.isEmpty ? tr("none", "нет") : names.joined(separator: ", ")))
        }
        if app {
            // The profile already exists: a launcher problem must not roll it back.
            do {
                try ctx.installApps(for: profile, app: try ctx.claudeApp(), copy: copy, overwrite: false)
            } catch {
                ctx.warn(tr("launcher not created: \(error)\nCreate it later: clones app \(profile.name)", "лаунчер не создан: \(error)\nСоздать позже: clones app \(profile.name)"))
            }
            // With the first profile, plain Claude gets its own “Claude Default” icon too: once profiles
            // run, opening Claude.app itself would just activate an arbitrary running instance.
            let isFirstProfile = ctx.store.allProfiles().filter { !$0.isDefault }.count == 1
            let hasDefaultLauncher = AppBuilder.existingLaunchers(paths: ctx.paths).contains { $0.profile == Profile.defaultName }
            if isFirstProfile, !hasDefaultLauncher, let claude = try? ctx.claudeApp() {
                print(tr("First profile: adding “Claude Default” for plain Claude — use it instead of Claude.app",
                         "Первый профиль: добавляю «Claude Default» для обычного Claude — открывайте его вместо Claude.app"))
                do {
                    try ctx.installApps(for: ctx.store.defaultProfile, app: claude, copy: copy, overwrite: false)
                } catch {
                    ctx.warn("“default”: \(error)")
                }
            }
        }
        print(ctx.style.dim(tr("Start: clones run \(profile.name)   •   first sign-in: clones login \(profile.name)", "Запуск: clones run \(profile.name)   •   первый вход в аккаунт: clones login \(profile.name)")))
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: tr("List profiles: running or not, PID, size on disk.", "Список профилей: запущен ли, PID, размер на диске."),
        aliases: ["list"]
    )

    @Flag(help: help("JSON output for scripts.", "Вывод в JSON для скриптов."))
    var json = false

    @Flag(help: help("Skip folder sizes (faster).", "Не считать размер папок (быстрее)."))
    var noSize = false

    struct Row: Encodable {
        let name: String
        let isDefault: Bool
        let running: Bool
        let pids: [Int32]
        let dataDir: String
        let exists: Bool
        let sizeBytes: UInt64?
        let color: String?
        let mcpServers: [String]?
        let launcher: String?
        /// The Claude.app copy the profile starts with (nil: the original Claude.app).
        let bundleCopy: String?
        let bundleVersion: String?
    }

    struct Output: Encodable {
        let claudeApp: String?
        let claudeVersion: String?
        let profiles: [Row]
        let unmanaged: [Unmanaged]
    }

    struct Unmanaged: Encodable {
        let pid: Int32
        let userDataDir: String?
    }

    func run() throws {
        let ctx = try Context()
        let app = try? ctx.claudeApp()
        let map = ctx.instances(app: app)
        let launchers = Dictionary(AppBuilder.existingLaunchers(paths: ctx.paths).map { ($0.profile, $0.url.path) },
                                   uniquingKeysWith: { first, _ in first })

        let rows: [Row] = ctx.store.allProfiles().map { profile in
            let exists = FileManager.default.fileExists(atPath: profile.dataDir.path)
            let pids = map.processes(for: profile).map(\.pid)
            let copy = BundleCopy.existing(for: profile, paths: ctx.paths)
            return Row(name: profile.name, isDefault: profile.isDefault, running: !pids.isEmpty, pids: pids,
                       dataDir: profile.dataDir.path, exists: exists,
                       sizeBytes: (noSize || !exists) ? nil : DiskUsage.size(of: profile.dataDir),
                       color: profile.meta?.color ?? (profile.isDefault ? nil : HexColor.automatic(for: profile.name).hexString),
                       mcpServers: MCPConfig.serverNames(in: profile.mcpConfigFile),
                       launcher: launchers[profile.name],
                       bundleCopy: copy?.bundleURL.path, bundleVersion: (copy ?? app)?.version)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let output = Output(claudeApp: app?.bundleURL.path, claudeVersion: app?.version, profiles: rows,
                                unmanaged: map.unmanaged.map { Unmanaged(pid: $0.pid, userDataDir: $0.userDataDir) })
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
            return
        }

        let s = ctx.style
        var table = Table(headers: ["NAME", "STATUS", "PID", "SIZE", "MCP", "APP", "DATA"])
        table.rightAligned = [2, 3, 4]
        for row in rows {
            let profile = try ctx.store.profile(named: row.name)
            let status: String
            if row.pids.count > 1 { status = s.red("CONFLICT") }
            else if row.running { status = s.green("running") }
            else if !row.exists { status = s.yellow("no data") }
            else { status = s.dim("stopped") }
            table.add([
                profile.displayName(style: s),
                status,
                row.pids.isEmpty ? s.dim("-") : row.pids.map(String.init).joined(separator: ","),
                row.sizeBytes.map(DiskUsage.format) ?? s.dim("-"),
                row.mcpServers.map { String($0.count) } ?? s.dim("-"),
                row.launcher.map { ctx.paths.abbreviate(URL(fileURLWithPath: $0)) } ?? s.dim("-"),
                s.dim(ctx.paths.abbreviate(profile.dataDir)),
            ])
        }
        print(table.render(style: s))

        let watcher = CopyGuard(paths: ctx.paths) { _ in }
        for process in map.processes(for: ctx.store.defaultProfile) {
            if let owner = watcher.strayOwner(process) {
                ctx.warn(tr("PID \(process.pid): the “\(owner)” copy is running without its profile (on the default data). Quit it: kill \(process.pid) — then run clones run \(owner)", "PID \(process.pid): копия «\(owner)» запущена без профиля (на данных default). Закройте её: kill \(process.pid) — и запустите clones run \(owner)"))
            }
        }
        for process in map.unmanaged {
            ctx.warn(tr("Claude PID \(process.pid) runs with a folder that is not a profile: ", "Claude PID \(process.pid) запущен с чужой папкой: ") + (process.userDataDir ?? "?"))
        }
        for (name, processes) in map.conflicts {
            ctx.warn(tr("profile “\(name)” is running twice (PID \(processes.map { String($0.pid) }.joined(separator: ", "))); its data may get corrupted, quit one: kill \(processes.last!.pid)", "профиль «\(name)» запущен дважды (PID \(processes.map { String($0.pid) }.joined(separator: ", "))) — данные могут повредиться, закройте лишний: kill \(processes.last!.pid)"))
        }
        if app == nil { ctx.warn(tr("Claude.app not found; process status may be inaccurate (clones doctor)", "Claude.app не найден — статус процессов может быть неточным (clones doctor)")) }
    }
}

struct Dir: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: tr("Print the profile's data folder.", "Путь к данным профиля."))

    @Argument(help: help("Profile name.", "Имя профиля."), completion: profileNameCompletion(includeDefault: true))
    var name: String

    func run() throws {
        let ctx = try Context()
        print(try ctx.store.profile(named: name).dataDir.path)
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Open the profile's claude_desktop_config.json in $EDITOR.", "Открыть claude_desktop_config.json профиля в $EDITOR."),
        discussion: tr("Without $VISUAL/$EDITOR the file opens in TextEdit. Claude reads it at startup, so restart the profile after editing.",
                       "Без $VISUAL/$EDITOR файл открывается в TextEdit. Claude читает файл при старте — после правки перезапустите профиль.")
    )

    @Argument(help: help("Profile name.", "Имя профиля."), completion: profileNameCompletion(includeDefault: true))
    var name: String

    @Flag(help: help("Only print the file path.", "Только напечатать путь к файлу."))
    var path = false

    func run() throws {
        let ctx = try Context()
        let profile = try ctx.store.profile(named: name)
        let file = profile.mcpConfigFile
        if path {
            print(file.path)
            return
        }
        try MCPConfig.ensureExists(file)

        let env = ProcessInfo.processInfo.environment
        let editor = [env["VISUAL"], env["EDITOR"]].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let editor {
            // Through sh so that EDITOR="code --wait" and the like work.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "\(editor) \"$1\"", "clones-editor", file.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw ClonesError.other(tr("Editor “\(editor)” exited with code \(process.terminationStatus)", "Редактор «\(editor)» завершился с кодом \(process.terminationStatus)"))
            }
        } else {
            #if os(macOS)
            try Shell.run("/usr/bin/open", ["-t", file.path])
            print(tr("Opened in the text editor: ", "Открыл в текстовом редакторе: ") + file.path)
            print(ctx.style.dim(tr("Set $EDITOR to use your own editor.", "Задайте $EDITOR, чтобы открывать в своём редакторе.")))
            return
            #else
            print(file.path)
            return
            #endif
        }

        do {
            let names = (try MCPConfig.servers(in: file) as? [String: Any])?.keys.sorted() ?? []
            print(tr("MCP servers of “\(profile.name)”: ", "MCP-серверы «\(profile.name)»: ") + (names.isEmpty ? tr("none", "нет") : names.joined(separator: ", ")))
        } catch {
            ctx.warn("\(error)")
        }
        let app = try? ctx.claudeApp()
        if ctx.instances(app: app).pid(for: profile) != nil {
            print(ctx.style.yellow(tr("The profile is running: Claude reloads the config after a restart (clones kill \(profile.name) && clones run \(profile.name)).", "Профиль запущен: Claude перечитает конфиг после перезапуска (clones kill \(profile.name) && clones run \(profile.name)).")))
        }
    }
}
