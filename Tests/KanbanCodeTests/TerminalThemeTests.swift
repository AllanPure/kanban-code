import Testing
import AppKit
@testable import KanbanCode

@Suite("Kitty terminal theme loader")
struct TerminalThemeTests {
    /// Flatten resolves `include`, later assignments win, comments/blanks are ignored.
    @Test("include chain flattens with last-value-wins")
    func flattenIncludeChain() {
        let files: [String: String] = [
            "/cfg/kitty.conf": """
            # Font settings
            font_family      DankMono Nerd Font
            font_size 16.0
            background #000000

            include theme.conf
            """,
            "/cfg/theme.conf": """
            background #ffffff
            foreground #5c6166
            """,
        ]
        let settings = KittyThemeLoader.flatten(path: "/cfg/kitty.conf") { files[$0] }

        // theme.conf is included after the initial background, so it wins.
        #expect(settings["background"] == "#ffffff")
        #expect(settings["foreground"] == "#5c6166")
        #expect(settings["font_family"] == "DankMono Nerd Font")
        #expect(settings["font_size"] == "16.0")
    }

    /// A missing include file is skipped, not fatal.
    @Test("missing include is ignored")
    func missingIncludeIgnored() {
        let files = ["/cfg/kitty.conf": "background #ffffff\ninclude nope.conf"]
        let settings = KittyThemeLoader.flatten(path: "/cfg/kitty.conf") { files[$0] }
        #expect(settings["background"] == "#ffffff")
    }

    /// Cyclic includes terminate instead of looping forever.
    @Test("include cycle terminates")
    func includeCycleTerminates() {
        let files = [
            "/cfg/a.conf": "background #ffffff\ninclude b.conf",
            "/cfg/b.conf": "foreground #5c6166\ninclude a.conf",
        ]
        let settings = KittyThemeLoader.flatten(path: "/cfg/a.conf") { files[$0] }
        #expect(settings["background"] == "#ffffff")
        #expect(settings["foreground"] == "#5c6166")
    }

    /// A complete ayu-light config maps to a usable light theme with font.
    @Test("ayu light maps to a light theme")
    func ayuLightMapsToTheme() {
        var settings: [String: String] = [
            "background": "#ffffff",
            "foreground": "#5c6166",
            "cursor": "#ff9940",
            "font_family": "DankMono Nerd Font",
            "font_size": "16.0",
        ]
        for i in 0..<16 { settings["color\(i)"] = "#5c6166" }

        let theme = KittyThemeLoader.theme(from: settings)
        #expect(theme != nil)
        #expect(theme?.isDarkBackground == false)          // #ffffff → light
        #expect(theme?.colorFgBg == "0;15")                // light hint for TUIs
        #expect(theme?.fontFamily == "DankMono Nerd Font")
        #expect(theme?.fontSize == 16.0)
        let bg = theme?.background.usingColorSpace(.sRGB)
        #expect((bg?.redComponent ?? 0) > 0.99)            // pure white
    }

    /// Missing mandatory colors → nil, so the app falls back to the built-in palette.
    @Test("missing background yields no theme")
    func missingBackgroundYieldsNil() {
        let settings = ["foreground": "#5c6166"]
        #expect(KittyThemeLoader.theme(from: settings) == nil)
    }

    /// A partial ansi palette still yields a usable theme: bg/fg apply and the
    /// missing slots keep the default palette (no whole-theme dark fallback).
    @Test("incomplete ansi palette still applies bg/fg, fills the rest")
    func incompleteAnsiFillsDefaults() {
        var settings = ["background": "#ffffff", "foreground": "#5c6166"]
        for i in 0..<15 { settings["color\(i)"] = "#5c6166" }  // color15 missing
        let theme = KittyThemeLoader.theme(from: settings)
        #expect(theme != nil)
        #expect(theme?.isDarkBackground == false)       // still the light bg
        #expect(theme?.ansi.count == 16)                // slot 15 filled from defaults
    }

    /// Both #rgb and #rrggbb literals parse; junk is rejected.
    @Test("color literal parsing")
    func colorParsing() {
        let white = KittyThemeLoader.color("#ffffff")?.usingColorSpace(.sRGB)
        #expect((white?.redComponent ?? 0) > 0.99)
        let short = KittyThemeLoader.color("#fff")?.usingColorSpace(.sRGB)
        #expect((short?.greenComponent ?? 0) > 0.99)       // #fff expands to #ffffff
        #expect(KittyThemeLoader.color("ffffff") == nil)   // no leading #
        #expect(KittyThemeLoader.color("#xyz") == nil)     // non-hex
        #expect(KittyThemeLoader.color(nil) == nil)
    }
}
