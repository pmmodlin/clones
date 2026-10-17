import Foundation

/// UI language: English by default, Russian when the system language is Russian.
/// Override with `CLONES_LANG=en|ru`.
public enum L10n {
    public static let isRussian: Bool = detectRussian(environment: ProcessInfo.processInfo.environment,
                                                      preferredLanguages: Locale.preferredLanguages)

    static func detectRussian(environment env: [String: String], preferredLanguages: [String]) -> Bool {
        if let forced = env["CLONES_LANG"]?.lowercased(), !forced.isEmpty {
            return forced.hasPrefix("ru")
        }
        #if os(macOS)
        // The system language (System Settings → Language & Region), not the terminal's LANG.
        if let first = preferredLanguages.first {
            return first.lowercased().hasPrefix("ru")
        }
        #endif
        for key in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            if let value = env[key], !value.isEmpty {
                return value.lowercased().hasPrefix("ru")
            }
        }
        return false
    }
}

/// Returns the string for the current UI language.
public func tr(_ english: String, _ russian: String) -> String {
    L10n.isRussian ? russian : english
}
