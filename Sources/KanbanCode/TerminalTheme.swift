import AppKit
import SwiftTerm
import KanbanCodeCore

/// Terminal color + font theme: background / foreground / cursor, the 16 ANSI
/// colors, and the font family/size.
///
/// Resolved once from the user's **kitty configuration** when it can be read,
/// otherwise falling back to the app's original built-in dark palette and the
/// system monospaced font. This lets the embedded terminal match the user's real
/// terminal (colors *and* font — including Nerd Font glyphs) instead of imposing
/// a fixed scheme.
struct TerminalTheme {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let ansi: [SwiftTerm.Color]  // exactly 16 entries (standard 0-7, bright 8-15)
    /// Font family from kitty (`font_family`), or nil to use the system monospaced font.
    let fontFamily: String?
    /// Font size from kitty (`font_size`), or nil to use the app default.
    let fontSize: CGFloat?

    /// The theme actually used by the app: the user's kitty config if readable,
    /// else the built-in palette. Read once (all call sites are @MainActor).
    @MainActor static let current: TerminalTheme = KittyThemeLoader.load() ?? builtIn

    /// Perceived darkness of the background (Rec. 601 luma < 0.5). Used to tell
    /// embedded apps whether the terminal is light or dark.
    var isDarkBackground: Bool {
        let c = background.usingColorSpace(.sRGB) ?? background
        let luma = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return luma < 0.5
    }

    /// `COLORFGBG` hint passed to child processes so background-aware TUIs
    /// (Claude Code, vim, …) render for the right theme. Format is "fg;bg" as ANSI
    /// color indices; bg 15 = light, bg 0 = dark.
    var colorFgBg: String { isDarkBackground ? "15;0" : "0;15" }

    /// Resolve the terminal font: the kitty `font_family` at `size` when it can be
    /// instantiated, else the system monospaced font. `size` wins over the theme's
    /// own `fontSize` so the app's zoom (Cmd +/-) keeps working.
    /// @MainActor because it touches `NSFontManager.shared`.
    @MainActor
    func resolvedFont(size: CGFloat) -> NSFont {
        if let family = fontFamily {
            if let font = NSFont(name: family, size: size)
                ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                return font
            }
            // Falling back silently would resurrect the tofu bug (Nerd Font glyphs as
            // boxes) with no clue why — log which family failed to resolve.
            KanbanCodeLog.info("terminal-font",
                "kitty font_family '\(family)' not resolvable — using the system monospaced font")
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Default ANSI palette: used by the built-in theme, and to fill any ANSI slots a
    /// kitty theme leaves unset — so a partial theme still applies its background and
    /// foreground instead of being dropped entirely to the dark fallback.
    /// Computed (not a stored `static let`) because `SwiftTerm.Color` isn't Sendable,
    /// which would make a mutable global under Swift 6 strict concurrency.
    static var defaultAnsi: [SwiftTerm.Color] {
        [
            // Standard colors (0-7)
            ansi8(0x33, 0x33, 0x33), ansi8(0xFF, 0x5F, 0x56), ansi8(0x5A, 0xF7, 0x8E), ansi8(0xFF, 0xD7, 0x5F),
            ansi8(0x57, 0xAC, 0xFF), ansi8(0xFF, 0x6A, 0xC1), ansi8(0x5A, 0xF7, 0xD4), ansi8(0xE0, 0xE0, 0xE0),
            // Bright colors (8-15)
            ansi8(0x66, 0x66, 0x66), ansi8(0xFF, 0x6E, 0x67), ansi8(0x5A, 0xF7, 0x8E), ansi8(0xFF, 0xFC, 0x67),
            ansi8(0x6B, 0xC1, 0xFF), ansi8(0xFF, 0x77, 0xD0), ansi8(0x5A, 0xF7, 0xD4), ansi8(0xFF, 0xFF, 0xFF),
        ]
    }

    /// Original hardcoded dark palette — the fallback when kitty is absent/unreadable.
    @MainActor static let builtIn = TerminalTheme(
        background: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.07, alpha: 1.0),
        foreground: NSColor(srgbRed: 0.93, green: 0.93, blue: 0.93, alpha: 1.0),
        cursor: .systemGreen,
        ansi: defaultAnsi,
        fontFamily: nil,
        fontSize: nil
    )
}

/// Build a `SwiftTerm.Color` from 8-bit components (SwiftTerm uses 16-bit 0-65535).
private func ansi8(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color {
    SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257)
}

/// Reads terminal colors and font from the user's **kitty** configuration.
///
/// kitty config is a flat `key value` text file. `include <path>` pulls in another
/// file (relative to the including file's directory), and **later assignments win**,
/// so themes work by `include`-ing a file that overrides `background`/`color0`/… .
/// We flatten `kitty.conf` + its whole include chain, then read the final values.
enum KittyThemeLoader {
    /// Load the theme from the default kitty config path, or nil if unreadable.
    static func load() -> TerminalTheme? {
        guard let path = defaultConfigPath() else { return nil }
        let settings = flatten(path: path) { try? String(contentsOfFile: $0, encoding: .utf8) }
        return theme(from: settings)
    }

    /// `$XDG_CONFIG_HOME/kitty/kitty.conf` or `~/.config/kitty/kitty.conf`, if it exists.
    static func defaultConfigPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        let path = (base as NSString).appendingPathComponent("kitty/kitty.conf")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Flatten `path` + its `include` chain into a settings dict (last value wins).
    /// `read` returns a file's contents; injected so this is testable without disk.
    /// Include cycles and runaway depth are bounded.
    static func flatten(path: String, read: (String) -> String?) -> [String: String] {
        var settings: [String: String] = [:]
        var visited: Set<String> = []

        func walk(_ path: String, depth: Int) {
            let resolved = (path as NSString).standardizingPath
            guard depth < 32, !visited.contains(resolved), let text = read(resolved) else { return }
            visited.insert(resolved)
            let dir = (resolved as NSString).deletingLastPathComponent

            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }
                guard let sep = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
                let key = String(line[..<sep])
                let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                if key == "include" {
                    let target = value.hasPrefix("/")
                        ? value
                        : (dir as NSString).appendingPathComponent(value)
                    walk(target, depth: depth + 1)
                } else {
                    settings[key] = value  // later wins
                }
            }
        }

        walk(path, depth: 0)
        return settings
    }

    /// Map flattened kitty settings to a `TerminalTheme`.
    /// Only background + foreground are mandatory (a theme missing those isn't usable
    /// — fall back to the built-in palette). Any ANSI slot the theme omits keeps the
    /// default palette entry, so a partial kitty theme still applies its bg/fg instead
    /// of forcing the whole dark fallback. Font is optional.
    static func theme(from settings: [String: String]) -> TerminalTheme? {
        guard let background = color(settings["background"]),
              let foreground = color(settings["foreground"]) else { return nil }
        let cursor = color(settings["cursor"]) ?? foreground

        var ansi = TerminalTheme.defaultAnsi
        for i in 0..<16 {
            if let c = color(settings["color\(i)"]) { ansi[i] = swiftTerm(c) }
        }

        let fontFamily = settings["font_family"].flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 }
        let fontSize = settings["font_size"].flatMap(Double.init).map { CGFloat($0) }

        return TerminalTheme(background: background, foreground: foreground, cursor: cursor,
                             ansi: ansi, fontFamily: fontFamily, fontSize: fontSize)
    }

    /// Parse a kitty color literal (`#rgb` or `#rrggbb`) into an sRGB `NSColor`.
    static func color(_ str: String?) -> NSColor? {
        guard var hex = str, hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        func channel(_ s: Substring) -> CGFloat? {
            UInt8(s, radix: 16).map { CGFloat($0) / 255 }
        }
        let expanded: String
        switch hex.count {
        case 3: expanded = hex.map { "\($0)\($0)" }.joined()  // #rgb → #rrggbb
        case 6: expanded = hex
        default: return nil
        }
        let chars = Array(expanded)
        guard let r = channel(Substring(String(chars[0...1]))),
              let g = channel(Substring(String(chars[2...3]))),
              let b = channel(Substring(String(chars[4...5]))) else { return nil }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    /// Convert an `NSColor` to a `SwiftTerm.Color` (16-bit sRGB, clamped 0-1).
    static func swiftTerm(_ ns: NSColor) -> SwiftTerm.Color {
        let c = ns.usingColorSpace(.sRGB) ?? ns
        func channel(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        return SwiftTerm.Color(red: channel(c.redComponent),
                               green: channel(c.greenComponent),
                               blue: channel(c.blueComponent))
    }
}
