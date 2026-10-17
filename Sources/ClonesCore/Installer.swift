import Foundation

/// Installs and updates Claude Desktop from Anthropic's download server
/// (the same source as Homebrew's `claude` cask).
public enum Installer {
    public static let releasesURL = "https://downloads.claude.ai/releases/darwin/universal/RELEASES.json"
    /// Team ID in Claude.app's signature (Developer ID Anthropic PBC).
    public static let teamID = "Q6L2SF6YDW"

    public struct Release: Equatable {
        public let version: String
        public let url: URL
    }

    /// RELEASES.json: {"currentRelease": "2.x", "releases": [{"version": …, "updateTo": {"url": …}}]}
    public static func parseReleases(_ data: Data) throws -> Release {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let releases = json["releases"] as? [[String: Any]], !releases.isEmpty
        else { throw ClonesError.other(tr("Unexpected RELEASES.json format", "Неожиданный формат RELEASES.json")) }
        let current = json["currentRelease"] as? String
        let entry = releases.first { ($0["version"] as? String) == current } ?? releases[0]
        guard let version = entry["version"] as? String,
              let update = entry["updateTo"] as? [String: Any],
              let urlString = update["url"] as? String,
              let url = URL(string: urlString), url.scheme == "https",
              let host = url.host, ["claude.ai", "anthropic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { throw ClonesError.other(tr("RELEASES.json has no valid download link", "В RELEASES.json нет корректной ссылки на загрузку")) }
        return Release(version: version, url: url)
    }

    public static func latestRelease() throws -> Release {
        let result = try Shell.run("/usr/bin/curl", ["-fsSL", "--max-time", "30", releasesURL])
        guard result.status == 0 else {
            throw ClonesError.other(tr("Could not fetch Claude versions (\(releasesURL)): ", "Не удалось получить список версий Claude (\(releasesURL)): ")
                + result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parseReleases(Data(result.stdout.utf8))
    }

    /// Downloads, verifies signature and notarization, and puts Claude.app into `directory` (replacing the old one).
    public static func install(_ release: Release, into directory: URL, log: (String) -> Void) throws -> ClaudeApp {
        #if os(macOS)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: directory.path) else {
            throw ClonesError.other(tr("No write access to \(directory.path) (a Mac administrator account is needed).", "Нет прав на запись в \(directory.path) (нужна учётная запись администратора Mac)."))
        }

        let work = fm.temporaryDirectory.appendingPathComponent("clones-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        log(tr("Downloading Claude \(release.version)…", "Скачиваю Claude \(release.version)…"))
        let zip = work.appendingPathComponent("Claude.zip")
        // curl draws its progress bar right in the terminal.
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-fL", "--progress-bar", "-o", zip.path, release.url.absoluteString]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else { throw ClonesError.other(tr("Download failed (curl exit code \(curl.terminationStatus)).", "Загрузка не удалась (curl, код \(curl.terminationStatus)).")) }

        log(tr("Unpacking…", "Распаковываю…"))
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        // ditto preserves signatures, framework symlinks and extended attributes.
        let unzip = try Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard unzip.status == 0 else { throw ClonesError.other(tr("Could not unpack the archive: \(unzip.stderr)", "Не удалось распаковать архив: \(unzip.stderr)")) }
        let newApp = unpacked.appendingPathComponent("Claude.app", isDirectory: true)
        guard fm.fileExists(atPath: newApp.path) else { throw ClonesError.other(tr("The archive has no Claude.app", "В архиве нет Claude.app")) }

        log(tr("Checking Anthropic's signature and notarization…", "Проверяю подпись Anthropic и нотаризацию…"))
        try verify(newApp)

        let target = directory.appendingPathComponent("Claude.app", isDirectory: true)
        let backup = work.appendingPathComponent("previous-Claude.app", isDirectory: true)
        let hadPrevious = fm.fileExists(atPath: target.path)
        if hadPrevious { try fm.moveItem(at: target, to: backup) }
        do {
            try fm.moveItem(at: newApp, to: target)
        } catch {
            if hadPrevious { try? fm.moveItem(at: backup, to: target) }
            throw ClonesError.other(tr("Could not move Claude.app into \(directory.path): \(error.localizedDescription)", "Не удалось положить Claude.app в \(directory.path): \(error.localizedDescription)"))
        }
        _ = try? Shell.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                           ["-f", target.path])
        return try ClaudeApp(bundleURL: target)
        #else
        throw ClonesError.unsupportedPlatform(tr("Installing Claude Desktop", "Установка Claude Desktop"))
        #endif
    }

    #if os(macOS)
    /// The signature is intact, it is Anthropic's, and the app is notarized (Gatekeeper accepts it).
    static func verify(_ app: URL) throws {
        let check = try Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else {
            throw ClonesError.other(tr("The downloaded Claude.app has an invalid signature: ", "Подпись скачанного Claude.app недействительна: ") + check.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let info = try Shell.run("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        let details = info.stderr + info.stdout
        guard details.contains("TeamIdentifier=\(teamID)"), details.contains("Identifier=\(ClaudeApp.bundleIdentifier)") else {
            throw ClonesError.other(tr("The downloaded Claude.app is not signed by Anthropic (expected Team ID \(teamID)). Installation cancelled.", "Скачанный Claude.app подписан не Anthropic (ожидался Team ID \(teamID)). Установка отменена."))
        }
        let gatekeeper = try Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else {
            throw ClonesError.other(tr("Gatekeeper rejects the downloaded Claude.app: ", "Gatekeeper не принимает скачанный Claude.app: ") + gatekeeper.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    #endif
}
