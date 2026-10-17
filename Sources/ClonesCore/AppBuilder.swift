import Foundation
#if os(macOS)
import AppKit
#endif

/// `clones app <name>`: a tiny .app in /Applications that starts the profile via `clones run`.
/// This is what goes into the Dock. The Claude.app copy named after the profile is BundleCopy's job.
public struct AppBuilder {
    public let paths: Paths
    public let app: ClaudeApp
    /// Absolute path of the clones binary the launcher calls.
    public let clonesExecutable: String

    public init(paths: Paths, app: ClaudeApp, clonesExecutable: String) {
        self.paths = paths
        self.app = app
        self.clonesExecutable = clonesExecutable
    }

    public func launcherURL(for profile: Profile) -> URL {
        paths.applicationsDir.appendingPathComponent(profile.appTitle + ".app", isDirectory: true)
    }

    /// clones launchers in every place they may be (including the old ~/Applications).
    public static func existingLaunchers(paths: Paths) -> [(url: URL, profile: String)] {
        paths.launcherDirs.flatMap { existingLaunchers(in: $0) }
    }

    /// Launchers made by clones (recognized by bundle id), for rm/rename/doctor.
    public static func existingLaunchers(in dir: URL) -> [(url: URL, profile: String)] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            guard url.pathExtension == "app",
                  let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = plist["CFBundleIdentifier"] as? String, id.hasPrefix(bundleIDPrefix),
                  let profile = plist["ClonesProfile"] as? String
            else { return nil }
            return (url, profile)
        }
    }

    static let bundleIDPrefix = "dev.clones.launcher."

    @discardableResult
    public func build(for profile: Profile, overwrite: Bool) throws -> URL {
        let fm = FileManager.default
        let bundle = launcherURL(for: profile)
        try fm.createDirectory(at: paths.applicationsDir, withIntermediateDirectories: true)
        guard fm.isWritableFile(atPath: paths.applicationsDir.path) else {
            throw ClonesError.other(tr("No write access to \(paths.applicationsDir.path). Usually a Mac administrator can write there; "
                + "otherwise choose another folder: export CLONES_APPS_DIR=~/Applications",
                "Нет прав на запись в \(paths.applicationsDir.path). Обычно туда может писать администратор Mac; "
                + "иначе укажите другую папку: export CLONES_APPS_DIR=~/Applications"))
        }
        if fm.fileExists(atPath: bundle.path) {
            guard overwrite || isOurLauncher(bundle) else {
                throw ClonesError.other(tr("\(paths.abbreviate(bundle)) already exists and was not made by clones. Remove it manually.", "\(paths.abbreviate(bundle)) уже существует и создан не clones. Удалите его вручную."))
            }
            try fm.removeItem(at: bundle)
        }

        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        do {
            let script = macOS.appendingPathComponent("launcher")
            try launcherScript(for: profile).write(to: script, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            var iconFile: String?
            if try makeIcon(for: profile, into: resources.appendingPathComponent("AppIcon.icns")) {
                iconFile = "AppIcon"
            }
            try infoPlist(for: profile, iconFile: iconFile).write(to: contents.appendingPathComponent("Info.plist"))
            try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
        } catch {
            try? fm.removeItem(at: bundle)
            throw error
        }
        register(bundle)
        // An older launcher of this profile elsewhere (~/Applications or under a previous name) is obsolete.
        for old in AppBuilder.existingLaunchers(paths: paths)
        where old.profile == profile.name && old.url.canonicalPath != bundle.canonicalPath {
            try? remove(launcher: old.url)
        }
        return bundle
    }

    /// The badge icon from the built launcher, reused for the Claude.app copy.
    public func iconFile(for profile: Profile) -> URL? {
        let icon = launcherURL(for: profile).appendingPathComponent("Contents/Resources/AppIcon.icns")
        return FileManager.default.fileExists(atPath: icon.path) ? icon : nil
    }

    public func remove(launcher url: URL) throws {
        unregister(url)
        try FileManager.default.removeItem(at: url)
    }

    func isOurLauncher(_ url: URL) -> Bool {
        AppBuilder.existingLaunchers(in: url.deletingLastPathComponent()).contains { $0.url.canonicalPath == url.canonicalPath }
    }

    // MARK: - Bundle contents

    func bundleID(for profile: Profile) -> String {
        let safe = profile.name.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "-" }
        return AppBuilder.bundleIDPrefix + String(safe)
    }

    func infoPlist(for profile: Profile, iconFile: String?) throws -> Data {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": bundleID(for: profile),
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": profile.appTitle,
            "CFBundleDisplayName": profile.appTitle,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            // The launcher lives for a fraction of a second and must not flash in the Dock.
            "LSUIElement": true,
            "NSHighResolutionCapable": true,
            "ClonesProfile": profile.name,
        ]
        if let iconFile { plist["CFBundleIconFile"] = iconFile }
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    public func launcherScript(for profile: Profile) -> String {
        let candidates = [clonesExecutable, "$HOME/.local/bin/clones", "/opt/homebrew/bin/clones", "/usr/local/bin/clones"]
        var seen = Set<String>()
        let list = candidates.filter { seen.insert($0).inserted }
            .map { $0.hasPrefix("$HOME") ? "\"\($0)\"" : shellQuote($0) }
            .joined(separator: " ")

        var fallback = ["/usr/bin/open", "-n", "-a", "\"$APP\""]
        for (key, value) in profile.environment.sorted(by: { $0.key < $1.key }) {
            fallback += ["--env", shellQuote("\(key)=\(value)")]
        }
        if !profile.launchArguments.isEmpty {
            fallback += ["--args"] + profile.launchArguments.map(shellQuote)
        }

        return """
        #!/bin/sh
        # Generated by clones: launcher for profile "\(profile.name)".
        # Rebuild: clones app \(profile.name) --force
        PROFILE=\(shellQuote(profile.name))
        for c in \(list); do
          if [ -x "$c" ]; then exec "$c" run "$PROFILE" --from-launcher; fi
        done
        # clones not found: start Claude directly (without the "already running" check).
        APP=\(shellQuote(BundleCopy.url(for: profile, paths: paths).path))
        [ -d "$APP" ] || APP=\(shellQuote(app.bundleURL.path))
        exec \(fallback.joined(separator: " "))

        """
    }

    // MARK: - Icon

    /// true if an icon was created.
    func makeIcon(for profile: Profile, into target: URL) throws -> Bool {
        #if os(macOS)
        let customIcon = profile.meta?.icon.flatMap { NSImage(contentsOfFile: $0) }
        let base = customIcon ?? NSWorkspace.shared.icon(forFile: app.bundleURL.path)
        // A custom icon gets a badge only with an explicit color; the Claude icon always gets one.
        let explicitColor = profile.meta?.color.flatMap(HexColor.init)
        let badgeColor: HexColor? = customIcon == nil ? (explicitColor ?? HexColor.automatic(for: profile.name)) : explicitColor
        let letter = String(profile.appTitle.replacingOccurrences(of: "Claude ", with: "").prefix(1)).uppercased()
        try IconRenderer.writeICNS(base: base, badge: badgeColor.map { ($0, letter) }, to: target)
        return true
        #else
        return false
        #endif
    }

    // MARK: - LaunchServices

    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// So that Spotlight and Raycast find the launcher right away.
    private func register(_ url: URL) {
        #if os(macOS)
        _ = try? Shell.run(AppBuilder.lsregister, ["-f", url.path])
        #endif
    }

    private func unregister(_ url: URL) {
        #if os(macOS)
        _ = try? Shell.run(AppBuilder.lsregister, ["-u", url.path])
        #endif
    }
}

func shellQuote(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

#if os(macOS)
enum IconRenderer {
    /// Draws the base icon plus a colored badge with a letter in the bottom-right corner and builds an .icns with iconutil.
    static func writeICNS(base: NSImage, badge: (HexColor, String)?, to target: URL) throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("clones-icon-\(UUID().uuidString)", isDirectory: true)
        let iconset = workDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        let variants: [(String, Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]
        for (file, size) in variants {
            guard let png = render(base: base, badge: badge, size: size) else {
                throw ClonesError.other(tr("Could not render the \(size)px icon", "Не удалось отрисовать иконку \(size)px"))
            }
            try png.write(to: iconset.appendingPathComponent(file))
        }
        let result = try Shell.run("/usr/bin/iconutil", ["-c", "icns", "-o", target.path, iconset.path])
        if result.status != 0 {
            throw ClonesError.other("iconutil: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func render(base: NSImage, badge: (HexColor, String)?, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: size, height: size)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        let s = CGFloat(size)
        base.draw(in: NSRect(x: 0, y: 0, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 1)

        if let (color, letter) = badge {
            // macOS icons sit in an ~82% square with ~9% margins: put the badge on the bottom-right of the squircle.
            let diameter = s * 0.42
            let rect = NSRect(x: s * 0.93 - diameter, y: s * 0.07, width: diameter, height: diameter)
            let fill = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)

            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = s * 0.02
            shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.restoreGraphicsState()

            let border = NSBezierPath(ovalIn: rect.insetBy(dx: s * 0.012, dy: s * 0.012))
            border.lineWidth = s * 0.024
            NSColor.white.setStroke()
            border.stroke()

            if size >= 32, !letter.isEmpty {
                let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
                let text = NSAttributedString(string: letter, attributes: [
                    .font: NSFont.systemFont(ofSize: diameter * 0.58, weight: .bold),
                    .foregroundColor: luminance > 0.65 ? NSColor.black : NSColor.white,
                ])
                let textSize = text.size()
                text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
