import Foundation

/// xterm.js에 전달하는 창 종류별 팔레트.
struct TerminalPalette: Equatable {
    let colors: [String: String]

    /// 기존 워크스페이스 터미널 픽셀은 변경하지 않는다.
    static let workspaceDark = TerminalPalette(colors: [
        "background": "#1e1e1e",
        "foreground": "#d4d4d4",
        "cursor": "#d4d4d4",
        "selectionBackground": "#264f78",
    ])

    /// 흰 배경에서 bright 색까지 읽히도록 명도를 눌러 잡은 라이트 ANSI 16색.
    /// Solarized처럼 배경을 착색하지 않고, 표준 ANSI 의미색을 유지한다.
    static let quickLight = TerminalPalette(colors: [
        "background": "#ffffff",
        "foreground": "#202124",
        "cursor": "#202124",
        "cursorAccent": "#ffffff",
        "selectionBackground": "#c2dbff",
        "black": "#202124",
        "red": "#b3261e",
        "green": "#137333",
        "yellow": "#7a5d00",
        "blue": "#185abc",
        "magenta": "#7b1fa2",
        "cyan": "#007c83",
        "white": "#e8eaed",
        "brightBlack": "#5f6368",
        "brightRed": "#d93025",
        "brightGreen": "#188038",
        "brightYellow": "#8a6500",
        "brightBlue": "#1a73e8",
        "brightMagenta": "#9334e6",
        "brightCyan": "#00838f",
        "brightWhite": "#ffffff",
    ])

    var json: String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: colors,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
