import XCTest
@testable import ClonesCore

final class ClonesCoreTests: XCTestCase {
    var root: URL!
    var paths: Paths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clones-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = Paths.standard(home: root, root: root.appendingPathComponent(".clones"),
                               defaultUserData: root.appendingPathComponent("Claude"),
                               applicationsDir: root.appendingPathComponent("Applications"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Имена и цвета

    func testNameValidation() {
        XCTAssertNoThrow(try ProfileName.validate("work"))
        XCTAssertNoThrow(try ProfileName.validate("client-a_2.test"))
        XCTAssertThrowsError(try ProfileName.validate(""))
        XCTAssertThrowsError(try ProfileName.validate("default"))
        XCTAssertThrowsError(try ProfileName.validate("Default"))
        XCTAssertThrowsError(try ProfileName.validate("a/b"))
        XCTAssertThrowsError(try ProfileName.validate("рабочий"))
        XCTAssertThrowsError(try ProfileName.validate(".hidden"))
        XCTAssertThrowsError(try ProfileName.validate(String(repeating: "a", count: 33)))
    }

    func testHexColor() {
        XCTAssertEqual(HexColor("#e5484d")?.hexString, "#E5484D")
        XCTAssertEqual(HexColor("0f0")?.hexString, "#00FF00")
        XCTAssertNil(HexColor("#12345"))
        XCTAssertNil(HexColor("zzzzzz"))
        XCTAssertEqual(HexColor.automatic(for: "work"), HexColor.automatic(for: "work"))
    }

    func testAppTitle() {
        let p = Profile(name: "client-a", dataDir: root, meta: nil)
        XCTAssertEqual(p.appTitle, "Claude Client A")
        XCTAssertEqual(p.launchArguments, ["--user-data-dir=\(root.path)"])
        let d = Profile(name: "default", dataDir: root, meta: nil)
        XCTAssertEqual(d.launchArguments, [])
    }

    // MARK: argv

    func testUserDataDirParsing() {
        XCTAssertEqual(ProcessScanner.userDataDir(in: ["--user-data-dir=/a b/c"]), "/a b/c")
        XCTAssertEqual(ProcessScanner.userDataDir(in: ["-psn_0_1", "--user-data-dir", "/x"]), "/x")
        XCTAssertNil(ProcessScanner.userDataDir(in: ["--foo"]))
        XCTAssertNil(ProcessScanner.userDataDir(in: ["--user-data-dir="]))
    }

    func testProcArgs2Parsing() {
        var bytes: [UInt8] = [2, 0, 0, 0]
        bytes += Array("/Applications/Claude.app/Contents/MacOS/Claude".utf8) + [0, 0, 0, 0]
        bytes += Array("/Applications/Claude.app/Contents/MacOS/Claude".utf8) + [0]
        bytes += Array("--user-data-dir=/Users/me/Library/Application Support/clones/profiles/work".utf8) + [0]
        bytes += Array("HOME=/Users/me".utf8) + [0]
        let parsed = ProcessScanner.parseProcArgs2(bytes)
        XCTAssertEqual(parsed?.0, "/Applications/Claude.app/Contents/MacOS/Claude")
        XCTAssertEqual(parsed?.1.count, 2)
        XCTAssertEqual(ProcessScanner.userDataDir(in: parsed?.1 ?? []),
                       "/Users/me/Library/Application Support/clones/profiles/work")
    }

    func testInstanceMapping() throws {
        let store = try ProfileStore(paths: paths)
        try store.create(name: "work")
        let workDir = store.dataDir(for: "work").path
        let processes = [
            ClaudeProcess(pid: 10, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: []),
            ClaudeProcess(pid: 11, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["--user-data-dir=\(workDir)/"]),
            ClaudeProcess(pid: 12, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["--user-data-dir=/elsewhere"]),
            ClaudeProcess(pid: 13, executable: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["--user-data-dir", workDir]),
        ]
        let map = InstanceMap(profiles: store.allProfiles(), processes: processes)
        XCTAssertEqual(map.pid(for: store.defaultProfile), 10)
        XCTAssertEqual(map.processes(for: try store.profile(named: "work")).map(\.pid), [11, 13])
        XCTAssertEqual(map.unmanaged.map(\.pid), [12])
        XCTAssertEqual(map.conflicts.map(\.0), ["work"])
    }

    // MARK: Хранилище

    func testCreateRenameRemove() throws {
        let store = try ProfileStore(paths: paths)
        let work = try store.create(name: "work", color: "#ff0000")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.mcpConfigFile.path))
        XCTAssertEqual(work.meta?.color, "#FF0000")
        XCTAssertThrowsError(try store.create(name: "WORK")) { XCTAssertEqual($0 as? ClonesError, .profileExists("WORK")) }

        // Метаданные переживают перезагрузку.
        let reloaded = try ProfileStore(paths: paths)
        XCTAssertEqual(reloaded.profileNames, ["default", "work"])
        XCTAssertEqual(try reloaded.profile(named: "Work").name, "work")

        try reloaded.rename("work", to: "job")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.dataDir(for: "work").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reloaded.dataDir(for: "job").path))
        XCTAssertEqual(reloaded.profileNames, ["default", "job"])

        try reloaded.rename("job", to: "Job")
        XCTAssertEqual(reloaded.profileNames, ["default", "Job"])

        XCTAssertThrowsError(try reloaded.remove("default"))
        XCTAssertThrowsError(try reloaded.rename("default", to: "x"))
        try reloaded.remove("Job")
        XCTAssertEqual(reloaded.profileNames, ["default"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: reloaded.dataDir(for: "Job").path))
    }

    func testLayout() {
        XCTAssertEqual(paths.profilesDir, paths.root)
        XCTAssertEqual(paths.configFile.lastPathComponent, ".config.json")
        let store = try! ProfileStore(paths: paths)
        XCTAssertEqual(store.dataDir(for: "work").path, paths.root.appendingPathComponent("work").path)
    }

    func testMigrationFromLegacyLayout() throws {
        let fm = FileManager.default
        let legacy = Paths.legacy(home: root, defaultUserData: paths.defaultUserData, applicationsDir: paths.applicationsDir)
        let oldStore = try ProfileStore(paths: legacy)
        let work = try oldStore.create(name: "work", env: ["CLAUDE_CONFIG_DIR": oldStore.dataDir(for: "work").appendingPathComponent("claude-config").path])
        try Data("{}".utf8).write(to: work.dataDir.appendingPathComponent("Local State"))
        let iconSource = root.appendingPathComponent("me.png")
        try Data([1, 2, 3]).write(to: iconSource)
        try oldStore.setIcon("work", from: iconSource.path)
        try fm.createDirectory(at: legacy.bundlesDir.appendingPathComponent("work/Claude Work.app"), withIntermediateDirectories: true)

        let target = LayoutMigration.target(for: legacy)
        XCTAssertEqual(target.root.lastPathComponent, ".clones")
        try LayoutMigration.migrate(from: legacy, to: target)

        let store = try ProfileStore(paths: target)
        let moved = try store.profile(named: "work")
        XCTAssertTrue(fm.fileExists(atPath: moved.dataDir.appendingPathComponent("Local State").path))
        XCTAssertEqual(moved.environment["CLAUDE_CONFIG_DIR"], moved.dataDir.appendingPathComponent("claude-config").path)
        XCTAssertTrue(moved.meta?.icon?.hasPrefix(target.iconsDir.path) == true)
        XCTAssertTrue(fm.fileExists(atPath: moved.meta!.icon!))
        XCTAssertTrue(fm.fileExists(atPath: target.bundlesDir.appendingPathComponent("work/Claude Work.app").path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.root.path))
        XCTAssertFalse(fm.fileExists(atPath: legacy.configFile.path))
        XCTAssertTrue(store.orphanDirectories().isEmpty, "dot folders are not orphans")
    }

    func testRenameMovesClaudeCodeDir() throws {
        let store = try ProfileStore(paths: paths)
        try store.create(name: "work", env: ["CLAUDE_CONFIG_DIR": store.dataDir(for: "work").appendingPathComponent("claude-config").path])
        try store.rename("work", to: "job")
        XCTAssertEqual(try store.profile(named: "job").environment["CLAUDE_CONFIG_DIR"],
                       store.dataDir(for: "job").appendingPathComponent("claude-config").path)
    }

    func testClaudeCodeDirMovesOutOfDesktopFolder() throws {
        let fm = FileManager.default
        let store = try ProfileStore(paths: paths)
        let old = store.dataDir(for: "work").appendingPathComponent("claude-code")
        try store.create(name: "work", env: ["CLAUDE_CONFIG_DIR": old.path])
        try store.create(name: "fresh", env: ["CLAUDE_CONFIG_DIR": store.dataDir(for: "fresh").appendingPathComponent("claude-config").path])
        XCTAssertEqual(ClaudeCodeDirMigration.affected(in: store).map(\.name), ["work"])

        for dir in ["2.1.304", "projects/-Users-me-app", "skills/hig"] {
            try fm.createDirectory(at: old.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: old.appendingPathComponent("projects/-Users-me-app/s.jsonl"))
        try Data("{}".utf8).write(to: old.appendingPathComponent(".claude.json"))
        let launcher = paths.applicationsDir.appendingPathComponent("Claude Work.app/Contents")
        try fm.createDirectory(at: launcher.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": AppBuilder.bundleIDPrefix + "work", "ClonesProfile": "work"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: launcher.appendingPathComponent("Info.plist"))
        try "exec open --env 'CLAUDE_CONFIG_DIR=\(old.path)'\n".write(to: launcher.appendingPathComponent("MacOS/launcher"), atomically: false, encoding: .utf8)

        try ClaudeCodeDirMigration.migrate(try store.profile(named: "work"), store: store)
        let work = try store.profile(named: "work")
        XCTAssertEqual(work.environment["CLAUDE_CONFIG_DIR"], work.claudeCodeDir.path)
        XCTAssertTrue(fm.fileExists(atPath: work.claudeCodeDir.appendingPathComponent("projects/-Users-me-app/s.jsonl").path))
        XCTAssertTrue(fm.fileExists(atPath: work.claudeCodeDir.appendingPathComponent("skills/hig").path))
        XCTAssertTrue(fm.fileExists(atPath: work.claudeCodeDir.appendingPathComponent(".claude.json").path))
        XCTAssertTrue(fm.fileExists(atPath: old.appendingPathComponent("2.1.304").path), "Claude Desktop's versions stay")
        XCTAssertFalse(fm.fileExists(atPath: old.appendingPathComponent("projects").path))
        let script = try String(contentsOf: launcher.appendingPathComponent("MacOS/launcher"), encoding: .utf8)
        XCTAssertTrue(script.contains("CLAUDE_CONFIG_DIR=\(work.claudeCodeDir.path)'"))
        XCTAssertTrue(ClaudeCodeDirMigration.affected(in: store).isEmpty)
    }

    func testCloneMCP() throws {
        let store = try ProfileStore(paths: paths)
        let work = try store.create(name: "work")
        let config = """
        {"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]}},
         "globalShortcut": "Alt+Space"}
        """
        try config.write(to: work.mcpConfigFile, atomically: true, encoding: .utf8)

        let test = try store.create(name: "test", cloneMCPFrom: "work")
        XCTAssertEqual(MCPConfig.serverNames(in: test.mcpConfigFile), ["fs"])
        // Копируются только MCP-серверы, не остальные настройки.
        XCTAssertNil(try MCPConfig.readObject(test.mcpConfigFile)["globalShortcut"])

        // Источник с битым JSON — ошибка, и профиль не создаётся наполовину.
        try "{ broken".write(to: work.mcpConfigFile, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.create(name: "broken", cloneMCPFrom: "work"))
        XCTAssertFalse(store.profileNames.contains("broken"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.dataDir(for: "broken").path))

        XCTAssertThrowsError(try store.create(name: "nope", cloneMCPFrom: "missing")) {
            XCTAssertEqual($0 as? ClonesError, .profileNotFound("missing"))
        }
    }

    func testOrphans() throws {
        let store = try ProfileStore(paths: paths)
        try store.create(name: "work")
        try FileManager.default.createDirectory(at: store.dataDir(for: "stray"), withIntermediateDirectories: true)
        XCTAssertEqual(store.orphanDirectories().map(\.lastPathComponent), ["stray"])
        XCTAssertThrowsError(try store.create(name: "stray"))
    }

    // MARK: Вывод

    func testTableAlignmentIgnoresANSI() {
        var table = Table(headers: ["A", "B"])
        table.add(["\u{1B}[32mrunning\u{1B}[0m", "x"])
        table.add(["stopped", "y"])
        let lines = table.render(style: Style(enabled: false)).split(separator: "\n")
        XCTAssertEqual(lines[1].replacingOccurrences(of: "\u{1B}[32m", with: "").replacingOccurrences(of: "\u{1B}[0m", with: ""),
                       "running  x")
        XCTAssertEqual(lines[2], "stopped  y")
    }

    func testSizeFollowsSymlinkedRoot() throws {
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10_000).write(to: real.appendingPathComponent("blob"))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertGreaterThanOrEqual(DiskUsage.size(of: link), 10_000)
    }

    func testParseReleases() throws {
        let json = """
        {"currentRelease":"2.42304.0","releases":[{"version":"2.42304.0","updateTo":{"name":"Claude 2.42304.0",
        "version":"2.42304.0","url":"https://downloads.claude.ai/releases/darwin/universal/2.42304.0/Claude-e7f6.zip"}}]}
        """
        let release = try Installer.parseReleases(Data(json.utf8))
        XCTAssertEqual(release.version, "2.42304.0")
        XCTAssertEqual(release.url.host, "downloads.claude.ai")
        // Ссылка не на сервер Anthropic или не https — отказ.
        XCTAssertThrowsError(try Installer.parseReleases(Data(json.replacingOccurrences(of: "downloads.claude.ai", with: "evil.example").utf8)))
        XCTAssertThrowsError(try Installer.parseReleases(Data(json.replacingOccurrences(of: "https://", with: "http://").utf8)))
        XCTAssertThrowsError(try Installer.parseReleases(Data("{}".utf8)))
        XCTAssertThrowsError(try Installer.parseReleases(Data(json.replacingOccurrences(of: "downloads.claude.ai", with: "downloads.evilclaude.ai").utf8)))
    }

    func testLanguageDetection() {
        XCTAssertTrue(L10n.detectRussian(environment: ["CLONES_LANG": "ru"], preferredLanguages: ["en-US"]))
        XCTAssertFalse(L10n.detectRussian(environment: ["CLONES_LANG": "en", "LANG": "ru_RU.UTF-8"], preferredLanguages: ["ru-RU"]))
        #if os(macOS)
        XCTAssertTrue(L10n.detectRussian(environment: ["LANG": "en_US.UTF-8"], preferredLanguages: ["ru-RU", "en-US"]))
        XCTAssertFalse(L10n.detectRussian(environment: ["LANG": "ru_RU.UTF-8"], preferredLanguages: ["en-US"]))
        #else
        XCTAssertTrue(L10n.detectRussian(environment: ["LANG": "ru_RU.UTF-8"], preferredLanguages: []))
        XCTAssertTrue(L10n.detectRussian(environment: ["LC_ALL": "ru_RU.UTF-8", "LANG": "en_US.UTF-8"], preferredLanguages: []))
        XCTAssertFalse(L10n.detectRussian(environment: ["LANG": "en_US.UTF-8"], preferredLanguages: []))
        #endif
        XCTAssertFalse(L10n.detectRussian(environment: [:], preferredLanguages: []))
    }

    func testByteFormat() {
        XCTAssertEqual(DiskUsage.format(512), "512 B")
        XCTAssertEqual(DiskUsage.format(1536), "1.5 KB")
        XCTAssertEqual(DiskUsage.format(300 * 1024 * 1024), "300 MB")
    }

    // MARK: Лаунчер

    func testLauncherMovesFromLegacyDir() throws {
        let legacy = root.appendingPathComponent("HomeApplications")
        let paths = Paths.standard(home: root, root: self.paths.root, defaultUserData: self.paths.defaultUserData,
                                   applicationsDir: self.paths.applicationsDir, legacyApplicationsDirs: [legacy])
        let bundle = root.appendingPathComponent("Claude.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Claude"], format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: bundle.appendingPathComponent("Contents/MacOS/Claude").path, contents: Data())
        let app = try ClaudeApp(bundleURL: bundle)

        let store = try ProfileStore(paths: paths)
        let work = try store.create(name: "work")
        // Лаунчер, созданный старой версией в ~/Applications.
        let legacyPaths = Paths.standard(home: root, root: paths.root, defaultUserData: paths.defaultUserData,
                                         applicationsDir: legacy)
        try AppBuilder(paths: legacyPaths, app: app, clonesExecutable: "/x/clones").build(for: work, overwrite: false)
        XCTAssertEqual(AppBuilder.existingLaunchers(paths: paths).map(\.url.lastPathComponent), ["Claude Work.app"])

        let url = try AppBuilder(paths: paths, app: app, clonesExecutable: "/x/clones").build(for: work, overwrite: false)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, paths.applicationsDir.standardizedFileURL.path)
        XCTAssertEqual(AppBuilder.existingLaunchers(paths: paths).map(\.url.standardizedFileURL), [url.standardizedFileURL])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Claude Work.app").path))
    }

    func testLauncherScript() throws {
        let bundle = root.appendingPathComponent("Claude.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "Claude", "CFBundleIdentifier": "com.anthropic.claudefordesktop"], format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: bundle.appendingPathComponent("Contents/MacOS/Claude").path, contents: Data())
        let app = try ClaudeApp(bundleURL: bundle)

        let store = try ProfileStore(paths: paths)
        let work = try store.create(name: "work", title: "Claude Work", env: ["CLAUDE_CONFIG_DIR": "/x y"])
        let builder = AppBuilder(paths: paths, app: app, clonesExecutable: "/usr/local/bin/clones")
        let script = builder.launcherScript(for: work)
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertTrue(script.contains("PROFILE='work'"))
        XCTAssertTrue(script.contains("--env 'CLAUDE_CONFIG_DIR=/x y'"))
        XCTAssertTrue(script.contains("'--user-data-dir=\(work.dataDir.path)'"))

        let url = try builder.build(for: work, overwrite: false)
        XCTAssertEqual(url.lastPathComponent, "Claude Work.app")
        XCTAssertEqual(AppBuilder.existingLaunchers(in: paths.applicationsDir).map(\.profile), ["work"])
        // Повторная сборка своего лаунчера разрешена, чужой .app не трогаем.
        XCTAssertNoThrow(try builder.build(for: work, overwrite: false))
        let foreign = paths.applicationsDir.appendingPathComponent("Claude Foreign.app")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignProfile = try store.create(name: "foreign")
        XCTAssertThrowsError(try builder.build(for: foreignProfile, overwrite: false))
    }
}
