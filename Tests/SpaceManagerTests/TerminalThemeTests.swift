import XCTest
@testable import SpaceManager

final class TerminalThemeTests: XCTestCase {
    func testQuickLightPaletteDefinesAllANSIColors() throws {
        let colors = TerminalPalette.quickLight.colors
        let ansi16 = [
            "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
            "brightBlack", "brightRed", "brightGreen", "brightYellow",
            "brightBlue", "brightMagenta", "brightCyan", "brightWhite",
        ]

        XCTAssertEqual(colors["background"], "#ffffff")
        XCTAssertEqual(colors["foreground"], "#202124")
        XCTAssertEqual(Set(ansi16).subtracting(colors.keys), [])
        XCTAssertEqual(ansi16.compactMap { colors[$0] }.count, 16)
        XCTAssertNotNil(TerminalPalette.quickLight.json)
    }

    func testWorkspacePaletteKeepsExistingDarkColors() {
        XCTAssertEqual(TerminalPalette.workspaceDark.colors, [
            "background": "#1e1e1e",
            "foreground": "#d4d4d4",
            "cursor": "#d4d4d4",
            "selectionBackground": "#264f78",
        ])
    }
}
