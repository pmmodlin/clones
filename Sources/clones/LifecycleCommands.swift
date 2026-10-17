import ArgumentParser
import ClonesCore
import Foundation

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: tr("Start a profile (or bring its window forward if it is running).", "Запустить инстанс профиля (если уже запущен — показать его окно).")
    )

    @Argument(help: help("Profile name (“default” is plain Claude).", "Имя профиля («default» — обычный Claude)."), completion: profileNameCompletion(includeDefault: true))
    var name: String

    @Flag(help: .hidden)
    var fromLauncher = false

    func run() throws {
        do {
            try open()
        } catch {
            if fromLauncher { showAlert("\(error)") }
            throw error
        }
    }

    private func open() throws {
        let ctx = try Context()
        let profile = try ctx.store.profile(named: name)
        let app = try ctx.claudeApp()

        if !profile.isDefault && !FileManager.default.fileExists(atPath: profile.dataDir.path) {
            try FileManager.default.createDirectory(at: profile.dataDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            ctx.warn(tr("the data folder of “\(profile.name)” was missing and was recreated (empty profile)", "папка данных «\(profile.name)» отсутствовала и создана заново (пустой профиль)"))
        }

        let map = ctx.instances(app: app)
        if let pid = map.pid(for: profile) {
            Launcher.focus(pid: pid)
            if !fromLauncher { print(tr("“\(profile.name)” is already running (PID \(pid)); window brought forward.", "«\(profile.name)» уже запущен (PID \(pid)) — окно активировано.")) }
            return
        }

        let firstRun = !profile.isDefault && !FileManager.default.fileExists(atPath: profile.dataDir.appendingPathComponent("Local State").path)
        let others = map.processes.count

        let pid = try Launcher.launch(profile, app: BundleCopy.launchApp(for: profile, paths: ctx.paths, original: app))
        if !fromLauncher {
            print(tr("“\(ctx.style.bold(profile.name))” started (PID \(pid)).", "«\(ctx.style.bold(profile.name))» запущен (PID \(pid))."))
            if firstRun && others > 0 {
                ctx.note(tr("First start of this profile while \(others) other instance(s) run. If Google sign-in does not complete, use: clones login \(profile.name)", "Первый запуск профиля при \(others) других инстансах. Если вход через Google не завершится — используйте: clones login \(profile.name)"))
            }
        }
    }

    private func showAlert(_ message: String) {
        #if os(macOS)
        let title = tr("clones: could not open “\(name)”", "clones: не удалось открыть «\(name)»")
        let script = "display alert \(appleScriptString(title)) message \(appleScriptString(message)) as critical"
        _ = try? Shell.run("/usr/bin/osascript", ["-e", script])
        #endif
    }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

struct Login: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Sign in to a profile: quit the other instances so claude:// reaches the right one.",
                     "Первый вход в аккаунт: закрыть остальные инстансы, чтобы claude:// дошёл до нужного."),
        discussion: tr("""
        Google sign-in returns to the app through a claude:// link, and macOS hands it to an arbitrary \
        running Claude (they all share one bundle id). If it lands in another instance, that instance shows \
        a sign-in code instead of signing in the profile you wanted. This command quits the other instances, \
        starts the right one and, after you sign in and press Enter, starts the others again.
        Email-code and SSO sign-in work without it — see the README.
        """, """
        Вход через Google на macOS возвращается в приложение ссылкой claude://, а macOS отдаёт её \
        произвольному из запущенных Claude (у всех один bundle id). Если ссылка попадёт в другой инстанс, \
        он покажет код для входа, а нужный профиль так и не войдёт. Эта команда закрывает остальные инстансы, \
        запускает нужный, а после входа (Enter) запускает закрытые обратно.
        Вход по email-коду и через SSO работает и без этого — см. README.
        """)
    )

    @Argument(help: help("Profile name.", "Имя профиля."), completion: profileNameCompletion(includeDefault: true))
    var name: String

    @Flag(name: .shortAndLong, help: help("Do not ask before quitting the other instances.", "Не спрашивать подтверждение перед закрытием других инстансов."))
    var yes = false

    @Flag(help: help("Do not restart the closed instances after sign-in.", "Не перезапускать закрытые инстансы после входа."))
    var noRestore = false

    func run() throws {
        let ctx = try Context()
        let profile = try ctx.store.profile(named: name)
        let app = try ctx.claudeApp()
        let map = ctx.instances(app: app)

        let others = ctx.store.allProfiles().filter { $0.name != profile.name && map.pid(for: $0) != nil }
        let unmanaged = map.unmanaged
        if !others.isEmpty || !unmanaged.isEmpty {
            let names = others.map(\.name) + unmanaged.map { "PID \($0.pid)" }
            if !yes, !(try Prompt.confirm(tr("Quit the other instances (\(names.joined(separator: ", "))) while you sign in?", "Закрыть другие инстансы (\(names.joined(separator: ", "))) на время входа?"), what: tr("quit other instances", "закрыть другие инстансы"))) {
                throw ExitCode.failure
            }
            let pids = others.flatMap { map.processes(for: $0).map(\.pid) } + unmanaged.map(\.pid)
            let stuck = Launcher.terminate(pids, timeout: 20, force: false)
            if !stuck.isEmpty {
                throw ClonesError.other(tr("PIDs did not quit: \(stuck.map(String.init).joined(separator: ", ")). Quit them manually or run: clones kill --all --force", "Не закрылись PID \(stuck.map(String.init).joined(separator: ", ")). Закройте их вручную или: clones kill --all --force"))
            }
            print(tr("Closed: ", "Закрыто: ") + names.joined(separator: ", ") + ".")
        }

        if let pid = map.pid(for: profile) {
            Launcher.focus(pid: pid)
            print(tr("“\(profile.name)” is already running (PID \(pid)) and is now the only instance.", "«\(profile.name)» уже запущен (PID \(pid)) и теперь единственный инстанс."))
        } else {
            let pid = try Launcher.launch(profile, app: BundleCopy.launchApp(for: profile, paths: ctx.paths, original: app))
            print(tr("“\(profile.name)” started (PID \(pid)) as the only instance.", "«\(profile.name)» запущен (PID \(pid)) — единственный инстанс."))
        }
        print(tr("""
        Sign in in the Claude window. The most reliable way is email: type the code from the message into the app \
        (do not open the link from the email in a browser). Google/SSO sign-in also works while this is the only instance.
        """, """
        Войдите в аккаунт в окне Claude. Надёжнее всего — по email: введите код из письма в окне приложения \
        (не открывайте ссылку из письма в браузере). Вход через Google/SSO тоже сработает, пока запущен только этот инстанс.
        """))

        guard !noRestore, !others.isEmpty, isatty(STDIN_FILENO) == 1 else { return }
        FileHandle.standardError.write(Data(tr("Press Enter after signing in to restart: \(others.map(\.name).joined(separator: ", ")) (Ctrl+C to skip) ", "Нажмите Enter после входа — запущу обратно: \(others.map(\.name).joined(separator: ", ")) (Ctrl+C — не запускать) ").utf8))
        guard readLine() != nil else { return }
        for other in others {
            do {
                let pid = try Launcher.launch(other, app: BundleCopy.launchApp(for: other, paths: ctx.paths, original: app))
                print(tr("“\(other.name)” started (PID \(pid)).", "«\(other.name)» запущен (PID \(pid))."))
            } catch {
                ctx.warn("“\(other.name)”: \(error)")
            }
        }
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Quit an instance gracefully (like ⌘Q).", "Корректно закрыть инстанс (как ⌘Q)."),
        discussion: tr("clones kill work  •  clones kill --all  •  clones kill test --force (if it does not quit)",
                       "clones kill work  •  clones kill --all  •  clones kill test --force (если не закрывается)")
    )

    @Argument(help: help("Profile name.", "Имя профиля."), completion: profileNameCompletion(includeDefault: true))
    var name: String?

    @Flag(help: help("Quit every running Claude instance, including default.", "Закрыть все запущенные инстансы Claude, включая default."))
    var all = false

    @Flag(help: help("Kill (SIGKILL) if it does not quit within --timeout seconds.", "Если не закрылся за --timeout секунд — убить принудительно (SIGKILL)."))
    var force = false

    @Option(help: help("Seconds to wait for a graceful quit.", "Сколько секунд ждать корректного завершения."))
    var timeout: Double = 15

    func validate() throws {
        if all == (name != nil) { throw ValidationError(tr("Give a profile name or --all.", "Укажите имя профиля или --all.")) }
    }

    func run() throws {
        let ctx = try Context()
        let app = try? ctx.claudeApp()
        let map = ctx.instances(app: app)

        var targets: [(String, [Int32])] = []
        if all {
            targets = ctx.store.allProfiles().compactMap { profile in
                let pids = map.processes(for: profile).map(\.pid)
                return pids.isEmpty ? nil : (profile.name, pids)
            }
            targets += map.unmanaged.map { ("PID \($0.pid)", [$0.pid]) }
            if targets.isEmpty {
                print(tr("No instances are running.", "Запущенных инстансов нет."))
                return
            }
        } else {
            let profile = try ctx.store.profile(named: name!)
            let pids = map.processes(for: profile).map(\.pid)
            if pids.isEmpty { throw ClonesError.notRunning(profile.name) }
            targets = [(profile.name, pids)]
        }

        try Kill.terminate(targets, timeout: timeout, force: force, style: ctx.style)
    }

    static func terminate(_ targets: [(String, [Int32])], timeout: Double, force: Bool, style: Style) throws {
        let alive = Launcher.terminate(targets.flatMap(\.1), timeout: timeout, force: force)
        for (label, group) in targets {
            if let stuck = group.first(where: alive.contains) {
                FileHandle.standardError.write(Data((style.red("✗ ") + ClonesError.killTimedOut(label, pid: stuck).description + "\n").utf8))
            } else {
                print(style.green("✓ ") + tr("\(label) closed", "\(label) закрыт"))
            }
        }
        if !alive.isEmpty { throw ExitCode.failure }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: tr("Remove a profile and all its data (sign-in, settings, MCP config, cache).", "Удалить профиль и все его данные (логин, настройки, MCP-конфиг, кэш)."),
        aliases: ["remove"]
    )

    @Argument(help: help("Profile name.", "Имя профиля."), completion: profileNameCompletion(includeDefault: false))
    var name: String

    @Flag(name: .shortAndLong, help: help("No confirmation; a running instance is quit.", "Без подтверждения; запущенный инстанс будет закрыт."))
    var force = false

    func run() throws {
        let ctx = try Context()
        let profile = try ctx.store.profile(named: name)
        if profile.isDefault { throw ClonesError.reservedProfile(profile.name, action: tr("removed", "удалить")) }

        let app = try? ctx.claudeApp()
        let pids = ctx.instances(app: app).processes(for: profile).map(\.pid)
        if let pid = pids.first, !force { throw ClonesError.profileRunning(profile.name, pid: pid) }

        if !force {
            let size = DiskUsage.format(DiskUsage.size(of: profile.dataDir))
            let question = tr("Remove profile “\(profile.name)” and \(ctx.paths.abbreviate(profile.dataDir)) (\(size))? This cannot be undone.", "Удалить профиль «\(profile.name)» и \(ctx.paths.abbreviate(profile.dataDir)) (\(size))? Это нельзя отменить.")
            guard try Prompt.confirm(question, what: tr("removing a profile", "удаление профиля")) else {
                print(tr("Cancelled.", "Отменено."))
                return
            }
        }
        if !pids.isEmpty {
            try Kill.terminate([(profile.name, pids)], timeout: 10, force: true, style: ctx.style)
        }

        for launcher in AppBuilder.existingLaunchers(paths: ctx.paths) where launcher.profile == profile.name {
            if let app {
                try AppBuilder(paths: ctx.paths, app: app, clonesExecutable: Context.executablePath).remove(launcher: launcher.url)
            } else {
                try FileManager.default.removeItem(at: launcher.url)
            }
            print(tr("Removed launcher ", "Удалён лаунчер ") + ctx.paths.abbreviate(launcher.url))
        }
        if BundleCopy.existing(for: profile, paths: ctx.paths) != nil {
            try BundleCopy.remove(profile.name, paths: ctx.paths)
            print(tr("Removed the profile's Claude copy", "Удалена копия Claude профиля"))
        }
        try ctx.store.remove(profile.name)
        print(tr("Profile “\(profile.name)” removed.", "Профиль «\(profile.name)» удалён."))
    }
}

struct Rename: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: tr("Rename a profile (data and sign-in are kept).", "Переименовать профиль (данные и вход сохраняются)."))

    @Argument(help: help("Current name.", "Текущее имя."), completion: profileNameCompletion(includeDefault: false))
    var old: String

    @Argument(help: help("New name.", "Новое имя."))
    var new: String

    func run() throws {
        let ctx = try Context()
        let profile = try ctx.store.profile(named: old)
        if profile.isDefault { throw ClonesError.reservedProfile(profile.name, action: tr("renamed", "переименовать")) }
        let app = try? ctx.claudeApp()
        if let pid = ctx.instances(app: app).pid(for: profile) {
            throw ClonesError.profileRunning(profile.name, pid: pid)
        }

        let launchers = AppBuilder.existingLaunchers(paths: ctx.paths).filter { $0.profile == profile.name }
        let hadCopy = BundleCopy.existing(for: profile, paths: ctx.paths) != nil
        if (!launchers.isEmpty || hadCopy) && app == nil {
            throw ClonesError.other(tr("Claude.app is needed to rebuild the profile's launcher. Check: clones doctor", "Нужен Claude.app, чтобы пересоздать лаунчер профиля. Проверьте: clones doctor"))
        }
        try ctx.store.rename(profile.name, to: new)
        print("“\(profile.name)” → “\(new)”")

        if let app, !launchers.isEmpty || hadCopy {
            let builder = AppBuilder(paths: ctx.paths, app: app, clonesExecutable: Context.executablePath)
            for launcher in launchers { try builder.remove(launcher: launcher.url) }
            if hadCopy { try BundleCopy.remove(profile.name, paths: ctx.paths) }
            try ctx.installApps(for: try ctx.store.profile(named: new), app: app, copy: hadCopy, overwrite: true)
            print(ctx.style.dim(tr("Replace the old Dock icon with the new one.", "Старый ярлык в Dock придётся заменить новым.")))
        }
    }
}

struct MakeApp: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: tr("Create the profile's launcher in /Applications and a Claude.app copy named after it.",
                     "Создать лаунчер профиля в /Applications и копию Claude.app под его именем."),
        discussion: tr("""
        The launcher is a tiny bundle with a script that calls `clones run <name>`; it is what you pin to the Dock. \
        Its icon is the Claude icon with a colored badge and the profile's letter (or your own, --icon).
        The Claude.app copy (on by default) lives in ~/.clones/.bundles.noindex so that \
        the running profile is called “Claude <Name>” in the Dock and ⌘Tab. Nothing inside the copy changes and \
        the signature stays valid. --no-copy starts the profile with the original Claude.app.
        Rebuild the copy after a Claude update: clones app <name> (the profile must be closed).
        """, """
        Лаунчер — крошечный бандл со скриптом, который вызывает `clones run <name>`; его закрепляют в Dock. \
        Иконка — иконка Claude с цветной плашкой и буквой профиля (или ваша, --icon).
        Копия Claude.app (по умолчанию) лежит в ~/.clones/.bundles.noindex и нужна, \
        чтобы запущенный профиль в Dock и ⌘Tab назывался «Claude <Name>». Внутри копии ничего не меняется, \
        подпись остаётся действительной. --no-copy — запускать оригинальным Claude.app.
        Пересоздать копию после обновления Claude: clones app <name> (профиль должен быть закрыт).
        """)
    )

    @Argument(help: help("Profile name.", "Имя профиля."), completion: profileNameCompletion(includeDefault: true))
    var name: String?

    @Flag(help: help("For every profile (default only if it already has a launcher).", "Для всех профилей (default — только если у него уже есть лаунчер)."))
    var all = false

    @Flag(name: .shortAndLong, help: help("Overwrite an existing launcher.", "Перезаписать существующий лаунчер."))
    var force = false

    @Option(help: help("Badge color (saved in the profile).", "Цвет плашки (сохраняется в профиле)."))
    var color: String?

    @Option(help: help("Custom icon (saved in the profile).", "Своя иконка (сохраняется в профиле)."), completion: .file())
    var icon: String?

    @Option(help: help("Launcher name (saved in the profile).", "Имя лаунчера (сохраняется в профиле)."))
    var title: String?

    @Flag(inversion: .prefixedNo, help: help("Claude.app copy named after the profile (on by default).", "Копия Claude.app под именем профиля (по умолчанию да)."))
    var copy = true

    @Flag(help: help("Remove the profile's launcher and Claude copy (the profile and its data stay).", "Удалить лаунчер и копию Claude профиля (сам профиль и его данные остаются)."))
    var remove = false

    func validate() throws {
        if all == (name != nil) { throw ValidationError(tr("Give a profile name or --all.", "Укажите имя профиля или --all.")) }
        if remove && (color != nil || icon != nil || title != nil) {
            throw ValidationError(tr("--remove cannot be combined with --color/--icon/--title.", "--remove нельзя сочетать с --color/--icon/--title."))
        }
        if all && (color != nil || icon != nil || title != nil) {
            throw ValidationError(tr("--color/--icon/--title apply to a single profile.", "--color/--icon/--title задаются для одного профиля."))
        }
        if let color, HexColor(color) == nil { throw ValidationError(ClonesError.invalidColor(color).description) }
    }

    func run() throws {
        let ctx = try Context()
        let app = try ctx.claudeApp()
        let builder = AppBuilder(paths: ctx.paths, app: app, clonesExecutable: Context.executablePath)
        #if !os(macOS)
        ctx.warn(tr("not macOS: no icon is created", "не macOS: иконка не создаётся"))
        #endif

        // --all covers default only if it already has a launcher (it may have been removed on purpose).
        let defaultHasLauncher = AppBuilder.existingLaunchers(paths: ctx.paths).contains { $0.profile == Profile.defaultName }
        let profiles = all ? ctx.store.allProfiles().filter { !$0.isDefault || defaultHasLauncher }
                           : [try ctx.store.profile(named: name!)]
        if remove {
            for profile in profiles {
                if let pid = ctx.instances(app: app).pid(for: profile), BundleCopy.existing(for: profile, paths: ctx.paths) != nil {
                    throw ClonesError.profileRunning(profile.name, pid: pid)
                }
                for launcher in AppBuilder.existingLaunchers(paths: ctx.paths) where launcher.profile == profile.name {
                    try builder.remove(launcher: launcher.url)
                    print(tr("Removed launcher ", "Удалён лаунчер ") + ctx.paths.abbreviate(launcher.url))
                }
                if BundleCopy.existing(for: profile, paths: ctx.paths) != nil {
                    try BundleCopy.remove(profile.name, paths: ctx.paths)
                    print(tr("Removed the Claude copy of “\(profile.name)”", "Удалена копия Claude профиля «\(profile.name)»"))
                }
            }
            return
        }
        for var profile in profiles {
            if color != nil || icon != nil || title != nil {
                // The default profile is in config.json only for these settings.
                let previous = AppBuilder.existingLaunchers(paths: ctx.paths).filter { $0.profile == profile.name }
                if let icon { try ctx.store.setIcon(profile.name, from: icon) }
                try ctx.store.update(profile.name) { meta in
                    if let color { meta.color = HexColor(color)!.hexString }
                    if let title { meta.title = title }
                }
                profile = try ctx.store.profile(named: profile.name)
                for old in previous where old.url.standardizedFileURL.path != builder.launcherURL(for: profile).standardizedFileURL.path {
                    try builder.remove(launcher: old.url)
                }
            }
            if title != nil, ctx.instances(app: app).pid(for: profile) == nil {
                try BundleCopy.remove(profile.name, paths: ctx.paths)  // the copy is named after the title; rebuilt below
            }
            try ctx.installApps(for: profile, app: app, copy: copy,
                                overwrite: force || color != nil || icon != nil || title != nil)
        }
        print(ctx.style.dim(tr("Drag the launcher to the Dock or find it with Spotlight/Raycast.", "Перетащите лаунчер в Dock или найдите его через Spotlight/Raycast.")))
    }
}

struct Completion: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Shell completion script.", "Скрипт автодополнения для shell."),
        discussion: tr("""
        zsh:  clones completion zsh > "${fpath[1]}/_clones"   (or: eval "$(clones completion zsh)" in ~/.zshrc)
        """, """
        zsh:  clones completion zsh > "${fpath[1]}/_clones"   (или: eval "$(clones completion zsh)" в ~/.zshrc)
        """)
    )

    @Argument(help: help("zsh, bash or fish.", "zsh, bash или fish."))
    var shell: String = "zsh"

    func run() throws {
        guard let kind = CompletionShell(rawValue: shell) else {
            throw ValidationError(tr("Unknown shell “\(shell)”: zsh, bash and fish are supported.", "Неизвестный shell «\(shell)»: поддерживаются zsh, bash, fish."))
        }
        print(Clones.completionScript(for: kind))
    }
}

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Download and install (or update) Claude Desktop in /Applications.",
                     "Скачать и установить (или обновить) Claude Desktop в /Applications."),
        discussion: tr("""
        Source: the official downloads.claude.ai (as used by Homebrew's cask). Anthropic's signature \
        (Team ID \(Installer.teamID)) and notarization are checked before installing. All Claude instances must be closed. \
        After an update the Claude.app copies of closed profiles are rebuilt from the new version.
        """, """
        Источник — официальный downloads.claude.ai (как у Homebrew-cask). Перед установкой проверяются \
        подпись Anthropic (Team ID \(Installer.teamID)) и нотаризация. Все инстансы Claude должны быть закрыты. \
        После обновления копии Claude.app закрытых профилей пересоздаются из новой версии.
        """),
        aliases: ["update"]
    )

    @Flag(name: .shortAndLong, help: help("Reinstall even if the latest version is installed.", "Переустановить, даже если уже стоит последняя версия."))
    var force = false

    @Option(help: help("Install location.", "Куда установить."), completion: .directory)
    var dir: String = "/Applications"

    func run() throws {
        let ctx = try Context()
        let target = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        let installed = try? ClaudeApp(bundleURL: target.appendingPathComponent("Claude.app", isDirectory: true))

        let release = try Installer.latestRelease()
        if let installed, installed.version == release.version, !force {
            print(tr("The latest Claude \(release.version) is already installed: ", "Уже установлена последняя версия Claude \(release.version): ") + installed.bundleURL.path)
            // Claude may have updated itself, leaving profile copies behind.
            for profile in ctx.store.allProfiles() {
                guard let copy = BundleCopy.existing(for: profile, paths: ctx.paths), copy.version != installed.version else { continue }
                print(tr("Copy of “\(profile.name)” is \(copy.version ?? "?"); updating to \(installed.version ?? "?")", "Копия «\(profile.name)» версии \(copy.version ?? "?") — обновляю до \(installed.version ?? "?")"))
                do {
                    try ctx.installApps(for: profile, app: installed, copy: true, overwrite: false)
                } catch {
                    ctx.warn("“\(profile.name)”: \(error)")
                }
            }
            return
        }

        let running = ProcessScanner.claudeProcesses(app: installed)
        if !running.isEmpty {
            throw ClonesError.other(tr("Quit Claude first (running: \(running.count), PID \(running.map { String($0.pid) }.joined(separator: ", "))): clones kill --all", "Сначала закройте Claude (запущено: \(running.count), PID \(running.map { String($0.pid) }.joined(separator: ", "))): clones kill --all"))
        }

        if let installed {
            print(tr("Updating Claude ", "Обновляю Claude ") + "\(installed.version ?? "?") → \(release.version)")
        }
        let app = try Installer.install(release, into: target) { print($0) }
        print(ctx.style.green("✓ ") + tr("Claude \(app.version ?? release.version) installed: ", "Claude \(app.version ?? release.version) установлен: ") + app.bundleURL.path)

        // Profile copies were made from the old version; rebuild them from the new one.
        for profile in ctx.store.allProfiles() where BundleCopy.existing(for: profile, paths: ctx.paths) != nil {
            do {
                try ctx.installApps(for: profile, app: app, copy: true, overwrite: false)
            } catch {
                ctx.warn("“\(profile.name)”: \(error)")
            }
        }
        if ctx.store.allProfiles().count == 1 {
            print(ctx.style.dim(tr("Next: clones add <name>   •   plain Claude: clones run default", "Дальше: clones add <name>   •   обычный Claude: clones run default")))
        }
    }
}
