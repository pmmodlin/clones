import Foundation

/// Every error the user can see: short, with a hint on what to do next.
public enum ClonesError: Error, CustomStringConvertible, LocalizedError, Equatable {
    case claudeNotFound(searched: [String])
    case notAClaudeBundle(String)
    case profileNotFound(String)
    case profileExists(String)
    case invalidName(String, reason: String)
    case reservedProfile(String, action: String)
    case profileRunning(String, pid: Int32)
    case notRunning(String)
    case invalidColor(String)
    case fileNotFound(String)
    case launchFailed(String)
    case killTimedOut(String, pid: Int32)
    case confirmationRequired(String)
    case invalidConfig(path: String, reason: String)
    case unsupportedPlatform(String)
    case other(String)

    public var description: String {
        switch self {
        case .claudeNotFound(let searched):
            return tr("Claude.app not found. Looked in:", "Claude.app не найден. Искал в:") + "\n"
                + searched.map { "  • \($0)" }.joined(separator: "\n") + "\n"
                + tr("Install Claude Desktop: clones install (or point to it: export CLONES_CLAUDE_APP=/path/to/Claude.app)",
                     "Установите Claude Desktop: clones install (или укажите путь: export CLONES_CLAUDE_APP=/path/to/Claude.app)")
        case .notAClaudeBundle(let path):
            return tr("\(path) does not look like Claude.app (no Contents/MacOS/Claude or Info.plist).",
                      "\(path) не похож на Claude.app (нет Contents/MacOS/Claude или Info.plist).")
        case .profileNotFound(let name):
            return tr("Profile “\(name)” not found. List profiles: clones ls",
                      "Профиль «\(name)» не найден. Список профилей: clones ls")
        case .profileExists(let name):
            return tr("Profile “\(name)” already exists.", "Профиль «\(name)» уже существует.")
        case .invalidName(let name, let reason):
            return tr("Invalid profile name “\(name)”: \(reason)", "Недопустимое имя профиля «\(name)»: \(reason)")
        case .reservedProfile(let name, let action):
            return tr("“\(name)” is the built-in profile (plain Claude without flags); it cannot be \(action).",
                      "Профиль «\(name)» встроенный (обычный Claude без флагов), его нельзя \(action).")
        case .profileRunning(let name, let pid):
            return tr("Profile “\(name)” is running (PID \(pid)). Quit it first: clones kill \(name)",
                      "Профиль «\(name)» запущен (PID \(pid)). Сначала закройте его: clones kill \(name)")
        case .notRunning(let name):
            return tr("Profile “\(name)” is not running.", "Профиль «\(name)» не запущен.")
        case .invalidColor(let value):
            return tr("Invalid color “\(value)”. Expected hex: #RRGGBB or RRGGBB (e.g. #E5484D).",
                      "Неверный цвет «\(value)». Ожидается hex: #RRGGBB или RRGGBB (например, #E5484D).")
        case .fileNotFound(let path):
            return tr("File not found: \(path)", "Файл не найден: \(path)")
        case .launchFailed(let reason):
            return tr("Could not start Claude: \(reason)", "Не удалось запустить Claude: \(reason)")
        case .killTimedOut(let name, let pid):
            return tr("“\(name)” (PID \(pid)) did not quit in time. Force it: clones kill \(name) --force",
                      "Профиль «\(name)» (PID \(pid)) не закрылся вовремя. Принудительно: clones kill \(name) --force")
        case .confirmationRequired(let what):
            return tr("Confirmation required (\(what)), but stdin is not a terminal. Add --force.",
                      "Нужно подтверждение (\(what)), но stdin не терминал. Добавьте --force.")
        case .invalidConfig(let path, let reason):
            return tr("Could not read \(path): \(reason)", "Не удалось прочитать \(path): \(reason)")
        case .unsupportedPlatform(let what):
            return tr("\(what) is only supported on macOS.", "\(what) поддерживается только на macOS.")
        case .other(let message):
            return message
        }
    }

    public var errorDescription: String? { description }
}
