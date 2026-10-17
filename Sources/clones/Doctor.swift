import ArgumentParser
import ClonesCore
import Foundation
#if os(macOS)
import AppKit
#endif

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Diagnostics: Claude.app, version, running instances, conflicts, configs.",
                     "Диагностика: Claude.app, версия, запущенные инстансы, конфликты, конфиги.")
    )

    /// The Claude version docs/RESEARCH.md was based on.
    static let researchedVersion = "2.42304.0"

    enum Level { case ok, info, warn, fail }

    func run() throws {
        let ctx = try Context()
        let s = ctx.style
        var failures = 0

        func report(_ level: Level, _ message: String) {
            let mark: String
            switch level {
            case .ok: mark = s.green("✓")
            case .info: mark = s.cyan("i")
            case .warn: mark = s.yellow("!")
            case .fail: mark = s.red("✗"); failures += 1
            }
            print("\(mark) \(message)")
        }
        func section(_ title: String) { print("\n" + s.bold(title)) }

        // MARK: System and Claude.app
        section("Claude.app")
        #if os(macOS)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        report(os.majorVersion >= 13 ? .ok : .fail, "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        #else
        report(.warn, tr("not macOS: launching and icons only work in test mode", "не macOS: запуск и иконки работают только в тестовом режиме"))
        #endif

        var app: ClaudeApp?
        do {
            let found = try ctx.claudeApp()
            app = found
            report(.ok, tr("found: \(found.bundleURL.path), version \(found.version ?? "?")",
                           "найден: \(found.bundleURL.path), версия \(found.version ?? "?")"))
            if found.bundleID != ClaudeApp.bundleIdentifier {
                report(.warn, tr("bundle id \(found.bundleID ?? "?") ≠ \(ClaudeApp.bundleIdentifier) — is this the original Claude?",
                                 "bundle id \(found.bundleID ?? "?") ≠ \(ClaudeApp.bundleIdentifier) — это точно оригинальный Claude?"))
            }
            if let version = found.version, version != Doctor.researchedVersion {
                report(.info, tr("isolation was researched on \(Doctor.researchedVersion); if something breaks, see docs/RESEARCH.md",
                                 "исследование изоляции проводилось на \(Doctor.researchedVersion); при сбоях сверьтесь с docs/RESEARCH.md"))
            }
            #if os(macOS)
            if let result = try? Shell.run("/usr/bin/codesign", ["--verify", found.bundleURL.path]) {
                report(result.status == 0 ? .ok : .warn,
                       result.status == 0 ? tr("Claude.app signature is valid", "подпись Claude.app в порядке")
                                          : "codesign --verify: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            #endif
        } catch {
            report(.fail, "\(error)")
        }

        // MARK: Processes
        section(tr("Running instances", "Запущенные инстансы"))
        let map = ctx.instances(app: app)
        let profiles = ctx.store.allProfiles()
        let guardCheck = CopyGuard(paths: ctx.paths) { _ in }
        var running = 0
        for profile in profiles {
            let processes = map.processes(for: profile)
            guard !processes.isEmpty else { continue }
            running += processes.count
            let pids = processes.map { String($0.pid) }.joined(separator: ", ")
            if processes.count > 1 {
                report(.fail, tr("“\(profile.name)” is running \(processes.count) times (PID \(pids)) on one folder; its data will get corrupted. Quit the extra ones.",
                                 "«\(profile.name)» запущен \(processes.count) раза (PID \(pids)) на одной папке — данные повредятся. Закройте лишние."))
            } else {
                report(.ok, "“\(profile.name)” PID \(processes[0].pid)")
            }
            // A profile copy opened directly (Finder, a pinned Dock icon) runs without --user-data-dir, on the default data.
            for process in processes {
                if let owner = guardCheck.strayOwner(process) {
                    report(.warn, tr("PID \(process.pid): the Claude copy of “\(owner)” was opened directly and runs on the default data. Quit it and open the profile with its launcher or clones run \(owner)",
                                     "PID \(process.pid): копия Claude профиля «\(owner)» запущена напрямую и работает на данных default. Закройте её и открывайте профиль лаунчером или clones run \(owner)"))
                }
            }
            if !profile.isDefault, !Doctor.looksInitialized(profile.dataDir) {
                report(.warn, tr("“\(profile.name)” is running but its folder is empty; Claude may have ignored --user-data-dir (see docs/RESEARCH.md)",
                                 "«\(profile.name)» запущен, но его папка пуста — возможно, Claude проигнорировал --user-data-dir (см. docs/RESEARCH.md)"))
            }
        }
        for process in map.unmanaged {
            report(.warn, tr("PID \(process.pid) runs with --user-data-dir=\(process.userDataDir ?? "?"), which belongs to no profile",
                             "PID \(process.pid) запущен с --user-data-dir=\(process.userDataDir ?? "?"), который не принадлежит ни одному профилю"))
        }
        if running + map.unmanaged.count == 0 { report(.info, tr("no instances are running", "ни одного инстанса не запущено")) }

        // MARK: Deep links
        section(tr("Sign-in and claude://", "Вход и claude://"))
        #if os(macOS)
        if let url = URL(string: "claude://"), let handler = NSWorkspace.shared.urlForApplication(toOpen: url) {
            let handlerID = Bundle(url: handler)?.bundleIdentifier
            if handlerID == ClaudeApp.bundleIdentifier {
                report(.ok, tr("claude:// handler: ", "обработчик claude:// — ") + handler.path)
            } else {
                report(.warn, tr("claude:// handler is \(handler.path) (\(handlerID ?? "?")), not Claude.app",
                                 "обработчик claude:// — \(handler.path) (\(handlerID ?? "?")), а не Claude.app"))
            }
        } else {
            report(.warn, tr("no claude:// handler registered; start plain Claude once",
                             "обработчик claude:// не зарегистрирован — запустите обычный Claude один раз"))
        }
        #endif
        if running + map.unmanaged.count > 1 {
            report(.info, tr("several instances are running: macOS hands claude:// links (Google sign-in, connector OAuth) to any of them. To sign in: clones login <name>",
                             "запущено несколько инстансов: claude://-ссылки (вход через Google, OAuth коннекторов) macOS отдаст любому из них. Для входа: clones login <name>"))
        }

        // MARK: Profiles
        section(tr("Profiles", "Профили"))
        report(.info, tr("metadata: ", "метаданные: ") + ctx.paths.abbreviate(ctx.paths.configFile)
            + tr(", data: ", ", данные: ") + ctx.paths.abbreviate(ctx.paths.profilesDir))
        for profile in profiles {
            let exists = FileManager.default.fileExists(atPath: profile.dataDir.path)
            if !exists {
                report(profile.isDefault ? .info : .warn,
                       tr("“\(profile.name)”: no folder \(ctx.paths.abbreviate(profile.dataDir))", "«\(profile.name)»: нет папки \(ctx.paths.abbreviate(profile.dataDir))")
                    + (profile.isDefault ? tr(" (plain Claude has not been started yet)", " (обычный Claude ещё не запускался)") : ""))
                continue
            }
            if FileManager.default.fileExists(atPath: profile.mcpConfigFile.path) {
                do {
                    let servers = try MCPConfig.servers(in: profile.mcpConfigFile)
                    let count = (servers as? [String: Any])?.count ?? 0
                    report(.ok, tr("“\(profile.name)”: claude_desktop_config.json is valid, MCP servers: \(count)",
                                   "«\(profile.name)»: claude_desktop_config.json валиден, MCP-серверов: \(count)"))
                } catch {
                    report(.fail, "“\(profile.name)”: \(error)")
                }
            } else {
                report(.ok, tr("“\(profile.name)”: no claude_desktop_config.json (no MCP servers)",
                               "«\(profile.name)»: claude_desktop_config.json нет (MCP-серверов нет)"))
            }
        }
        for orphan in ctx.store.orphanDirectories() {
            report(.warn, tr("folder \(ctx.paths.abbreviate(orphan)) belongs to no profile (remove it if you do not need it)",
                             "папка \(ctx.paths.abbreviate(orphan)) не принадлежит ни одному профилю (удалите вручную, если не нужна)"))
        }

        // MARK: Launchers
        let launchers = AppBuilder.existingLaunchers(paths: ctx.paths)
        if !launchers.isEmpty {
            section(tr("Launchers", "Лаунчеры"))
            let names = Set(ctx.store.profileNames)
            for launcher in launchers {
                let path = ctx.paths.abbreviate(launcher.url)
                if !names.contains(launcher.profile) {
                    report(.warn, tr("\(path) points to a profile that no longer exists: “\(launcher.profile)”",
                                     "\(path) ссылается на несуществующий профиль «\(launcher.profile)»"))
                } else if let script = try? String(contentsOf: launcher.url.appendingPathComponent("Contents/MacOS/launcher"), encoding: .utf8),
                          !script.contains(Context.executablePath) {
                    report(.info, tr("\(path) was made by another clones binary; rebuild: clones app \(launcher.profile)",
                                     "\(path) создан другим бинарником clones; пересоздать: clones app \(launcher.profile)"))
                } else {
                    report(.ok, "\(path) → “\(launcher.profile)”")
                }
            }
        }

        // MARK: Claude.app copies
        let copies = profiles.compactMap { profile in BundleCopy.existing(for: profile, paths: ctx.paths).map { (profile, $0) } }
        if !copies.isEmpty {
            section(tr("Claude.app copies", "Копии Claude.app"))
            for (profile, copy) in copies {
                if let app, let version = app.version, copy.version != version {
                    report(.warn, tr("“\(profile.name)”: the copy is \(copy.version ?? "?"), Claude.app is \(version). Update (the profile must be closed): clones update",
                                     "«\(profile.name)»: копия версии \(copy.version ?? "?"), а Claude.app — \(version). Обновить (профиль должен быть закрыт): clones update"))
                } else {
                    report(.ok, "“\(profile.name)”: \(ctx.paths.abbreviate(copy.bundleURL)) (\(copy.version ?? "?"))")
                }
            }
            #if os(macOS)
            if GuardAgent.isLoaded() {
                report(.ok, tr("copy guard is running: Dock-pinned copies open their own profile",
                               "страж копий запущен: закреплённые в Dock копии открывают свой профиль"))
            } else {
                report(.warn, tr("copy guard is not running: a Dock-pinned copy will open on the default data. Start it: clones agent install",
                                 "страж копий не запущен — закреплённая в Dock копия откроется на данных default. Запустить: clones agent install"))
            }
            #endif
        }

        // MARK: Shared locations
        section(tr("Shared by all profiles (not isolated)", "Общее для всех профилей (не изолируется)"))
        let shared: [(String, String)] = [
            ("~/.claude", tr("Claude Code of plain Claude, the terminal claude CLI and profiles made with --no-isolate-claude-code (other profiles have their own claude-code folder)",
                             "Claude Code обычного Claude, CLI claude в терминале и профилей, созданных с --no-isolate-claude-code (у остальных профилей своя папка claude-code)")),
            ("~/Documents/Claude", tr("Cowork files: scheduled tasks, live artifacts", "файлы Cowork: scheduled tasks, live artifacts")),
            ("~/Claude Projects", tr("Code/Cowork working folders (incl. MCP Exchange); Claude Code asks to trust them in each profile",
                                     "рабочие папки Code/Cowork (в т.ч. MCP Exchange) — Claude Code спрашивает доверие к ним в каждом профиле")),
            ("~/Library/Logs/Claude", tr("main.log of every instance goes to one place", "логи main.log всех инстансов пишутся в одно место")),
            (tr("Keychain “Claude Safe Storage”", "Keychain «Claude Safe Storage»"),
             tr("one encryption key for all; this is fine and does not break sessions", "один ключ шифрования на всех — это нормально, сессии не ломает")),
            ("~/Library/Preferences/com.anthropic.claudefordesktop.plist", tr("a couple of NSUserDefaults system flags", "пара системных флагов NSUserDefaults")),
        ]
        for (path, what) in shared { report(.info, "\(path) — \(what)") }

        print()
        if failures > 0 {
            print(s.red(tr("Problems found: \(failures)", "Найдено проблем: \(failures)")))
            throw ExitCode.failure
        }
        print(s.green(tr("No critical problems.", "Критичных проблем нет.")))
    }

    /// Claude creates “Local State” / “Preferences” in userData within seconds of starting.
    static func looksInitialized(_ dir: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.contains { $0 != "claude_desktop_config.json" && !$0.hasPrefix(".") }
    }
}
