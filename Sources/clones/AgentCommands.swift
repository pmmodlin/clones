import ArgumentParser
import ClonesCore
import Foundation

struct Agent: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: tr("Background copy guard: a Dock-pinned Claude copy opens its own profile.",
                     "Фоновый страж копий: закреплённая в Dock копия Claude открывает свой профиль."),
        discussion: tr("""
        macOS starts a Dock-pinned “Claude <Name>.app” copy without arguments, so it would open the default \
        profile's data. The guard (LaunchAgent dev.clones.agent) kills such a process right away and starts \
        the profile properly. Installed automatically with the first copy. Log: ~/Library/Logs/clones-agent.log
        """, """
        macOS запускает закреплённую в Dock копию «Claude <Name>.app» без аргументов, и она открыла бы \
        данные default. Страж (LaunchAgent dev.clones.agent) сразу закрывает такой процесс и запускает \
        профиль правильно. Ставится автоматически при создании копии. Лог: ~/Library/Logs/clones-agent.log
        """),
        subcommands: [AgentStatus.self, AgentInstall.self, AgentUninstall.self, AgentRun.self]
    )

    /// `clones agent` without a subcommand is `clones agent status`.
    func run() throws {
        try AgentStatus().run()
    }
}

struct AgentStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: tr("Is the guard running?", "Запущен ли страж."))

    func run() throws {
        let ctx = try Context()
        #if os(macOS)
        let loaded = GuardAgent.isLoaded()
        print(loaded ? ctx.style.green(tr("✓ guard is running", "✓ страж запущен")) : ctx.style.yellow(tr("! guard is not running — clones agent install", "! страж не запущен — clones agent install")))
        print(ctx.style.dim(tr("Log: ", "Лог: ") + ctx.paths.abbreviate(GuardAgent.logURL(paths: ctx.paths))))
        if !loaded { throw ExitCode.failure }
        #else
        throw ClonesError.unsupportedPlatform(tr("The background guard", "Фоновый страж"))
        #endif
    }
}

struct AgentInstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: tr("Install and start the guard.", "Установить и запустить стража."))

    func run() throws {
        let ctx = try Context()
        #if os(macOS)
        try GuardAgent.install(executable: Context.executablePath, paths: ctx.paths)
        print(ctx.style.green("✓ ") + tr("guard started", "страж запущен") + " (\(ctx.paths.abbreviate(GuardAgent.plistURL(paths: ctx.paths))))")
        #else
        throw ClonesError.unsupportedPlatform(tr("The background guard", "Фоновый страж"))
        #endif
    }
}

struct AgentUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: tr("Stop and remove the guard.", "Остановить и удалить стража."))

    func run() throws {
        let ctx = try Context()
        #if os(macOS)
        try GuardAgent.uninstall(paths: ctx.paths)
        print(tr("Guard stopped and removed. Do not open Claude copies directly from the Dock.", "Страж остановлен и удалён. Не открывайте копии Claude напрямую из Dock."))
        #else
        throw ClonesError.unsupportedPlatform(tr("The background guard", "Фоновый страж"))
        #endif
    }
}

struct AgentRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: tr("Run the guard in this process (how launchd starts it).", "Работать стражем в этом процессе (так его запускает launchd)."), shouldDisplay: false
    )

    @Flag(help: ArgumentHelp(tr("One pass, then exit (for tests).", "Один проход и выход (для тестов).")))
    var once = false

    func run() throws {
        let paths = Paths.current()
        let formatter = ISO8601DateFormatter()
        let watcher = CopyGuard(paths: paths) { message in
            FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
        }
        if once {
            let fixed = watcher.sweep()
            print(tr("Launches fixed: \(fixed)", "Исправлено запусков: \(fixed)"))
            return
        }
        watcher.runForever()
    }
}
