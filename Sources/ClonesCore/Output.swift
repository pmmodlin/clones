import Foundation

/// ANSI colors only when stdout is a terminal and NO_COLOR is not set.
public struct Style: Sendable {
    public let enabled: Bool

    public init(enabled: Bool) { self.enabled = enabled }

    public static func detect(fd: Int32 = STDOUT_FILENO,
                              environment env: [String: String] = ProcessInfo.processInfo.environment) -> Style {
        if env["NO_COLOR"] != nil || env["TERM"] == "dumb" { return Style(enabled: false) }
        if env["CLICOLOR_FORCE"].map({ $0 != "0" }) == true { return Style(enabled: true) }
        return Style(enabled: isatty(fd) == 1)
    }

    private func wrap(_ code: String, _ text: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    public func bold(_ s: String) -> String { wrap("1", s) }
    public func dim(_ s: String) -> String { wrap("2", s) }
    public func red(_ s: String) -> String { wrap("31", s) }
    public func green(_ s: String) -> String { wrap("32", s) }
    public func yellow(_ s: String) -> String { wrap("33", s) }
    public func cyan(_ s: String) -> String { wrap("36", s) }

    /// A "●" dot in the profile color (truecolor).
    public func swatch(_ color: HexColor?) -> String {
        guard enabled, let color else { return "" }
        let r = Int(color.red * 255), g = Int(color.green * 255), b = Int(color.blue * 255)
        return "\u{1B}[38;2;\(r);\(g);\(b)m●\u{1B}[0m "
    }
}

/// A table aligned by visible width (ANSI codes are not counted).
public struct Table {
    public let headers: [String]
    public var rows: [[String]] = []
    /// Right-aligned columns (numbers).
    public var rightAligned: Set<Int> = []

    public init(headers: [String]) { self.headers = headers }

    public mutating func add(_ row: [String]) { rows.append(row) }

    public func render(style: Style) -> String {
        var widths = headers.map(Table.visibleWidth)
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], Table.visibleWidth(cell))
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, cell in
                let pad = String(repeating: " ", count: max(0, widths[i] - Table.visibleWidth(cell)))
                if i == cells.count - 1 && !rightAligned.contains(i) { return cell }
                return rightAligned.contains(i) ? pad + cell : cell + pad
            }.joined(separator: "  ")
        }
        var out = [style.dim(line(headers))]
        out += rows.map(line)
        return out.joined(separator: "\n")
    }

    static func visibleWidth(_ string: String) -> Int {
        var width = 0
        var inEscape = false
        for scalar in string.unicodeScalars {
            if inEscape {
                if scalar == "m" { inEscape = false }
                continue
            }
            if scalar == "\u{1B}" { inEscape = true; continue }
            width += 1
        }
        return width
    }
}

public enum DiskUsage {
    /// Size on disk, like `du`: allocated blocks of regular files (lstat st_blocks × 512),
    /// so sparse and APFS-cloned files are not over-counted the way logical sizes would be.
    public static func size(of url: URL) -> UInt64 {
        // The folder may be a symlink (home-made account switchers do this); the enumerator
        // does not descend into a symlinked root, so start from the real path.
        let root = url.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                              options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in enumerator {
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            total += UInt64(max(Int64(info.st_blocks), 0)) * 512
        }
        return total
    }

    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(bytes) B" }
        return String(format: value < 10 ? "%.1f" : "%.0f", value) + " " + units[unit]
    }
}
