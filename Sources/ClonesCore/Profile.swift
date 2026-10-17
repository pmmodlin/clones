import Foundation

public struct Profile: Equatable, Sendable {
    public static let defaultName = "default"

    public let name: String
    public let dataDir: URL
    public let meta: ProfileMeta?

    public var isDefault: Bool { name == Profile.defaultName }
    public var mcpConfigFile: URL { dataDir.appendingPathComponent("claude_desktop_config.json") }

    /// Launcher / Dock name: “Claude Work”.
    public var appTitle: String {
        if let title = meta?.title, !title.isEmpty { return title }
        if isDefault { return "Claude Default" }
        return "Claude " + Profile.capitalize(name)
    }

    /// Command-line arguments that make Claude run this profile.
    public var launchArguments: [String] {
        isDefault ? [] : ["--user-data-dir=\(dataDir.path)"]
    }

    public var environment: [String: String] { meta?.env ?? [:] }

    static func capitalize(_ name: String) -> String {
        name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

public enum ProfileName {
    public static let maxLength = 32

    /// The name ends up in a folder path, an .app name and a bundle id, so only safe characters.
    public static func validate(_ name: String) throws {
        if name.isEmpty { throw ClonesError.invalidName(name, reason: tr("empty name", "пустое имя")) }
        if name.count > maxLength {
            throw ClonesError.invalidName(name, reason: tr("longer than \(maxLength) characters", "длиннее \(maxLength) символов"))
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if let bad = name.first(where: { !allowed.contains($0) }) {
            throw ClonesError.invalidName(name, reason: tr("character “\(bad)” is not allowed; use Latin letters, digits, “-”, “_”, “.”", "символ «\(bad)» не разрешён; можно латиницу, цифры, «-», «_», «.»"))
        }
        if let first = name.first, !(first.isLetter || first.isNumber) {
            throw ClonesError.invalidName(name, reason: tr("must start with a letter or digit", "должно начинаться с буквы или цифры"))
        }
        if name.lowercased() == Profile.defaultName {
            throw ClonesError.invalidName(name, reason: tr("“default” is reserved for plain Claude", "«default» зарезервирован за обычным Claude"))
        }
    }
}

/// A #RRGGBB color.
public struct HexColor: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double

    public init?(_ string: String) {
        var hex = string.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    public var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    /// A stable color derived from the profile name when none was set.
    public static func automatic(for name: String) -> HexColor {
        let palette = ["#E5484D", "#F76B15", "#FFC53D", "#30A46C", "#12A594", "#0090FF", "#3E63DD", "#8E4EC6", "#D6409F", "#8D8D8D"]
        // FNV-1a: String.hashValue is randomized per process.
        var hash: UInt32 = 2_166_136_261
        for byte in name.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return HexColor(palette[Int(hash % UInt32(palette.count))])!
    }
}
