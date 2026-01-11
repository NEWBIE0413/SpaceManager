import Foundation
import SwiftUI

/// A model configuration with new and resume commands
struct ModelConfig: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var newCommand: String       // Command for new session (e.g., "claude")
    var resumeCommand: String    // Command for resume (e.g., "claude --resume")
    var shortcut: String         // "1", "2", etc.
    var colorHex: String

    init(id: UUID = UUID(), name: String, newCommand: String, resumeCommand: String, shortcut: String = "", colorHex: String = "808080") {
        self.id = id
        self.name = name
        self.newCommand = newCommand
        self.resumeCommand = resumeCommand
        self.shortcut = shortcut
        self.colorHex = colorHex
    }

    var color: Color {
        Color(hex: colorHex) ?? .gray
    }

    /// Default model configurations
    static var defaults: [ModelConfig] {
        [
            ModelConfig(name: "Claude", newCommand: "claude", resumeCommand: "claude --resume", shortcut: "1", colorHex: "FF9500"),
            ModelConfig(name: "Codex", newCommand: "codex", resumeCommand: "codex --continue", shortcut: "2", colorHex: "34C759"),
            ModelConfig(name: "Gemini", newCommand: "gemini", resumeCommand: "gemini --resume", shortcut: "3", colorHex: "007AFF"),
            ModelConfig(name: "Shell", newCommand: "", resumeCommand: "", shortcut: "4", colorHex: "8E8E93"),
        ]
    }
}

/// Legacy CommandPreset for workspace-specific presets (kept for compatibility)
struct CommandPreset: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var command: String
    var shortcut: String
    var colorHex: String

    init(id: UUID = UUID(), name: String, command: String, shortcut: String = "", colorHex: String = "808080") {
        self.id = id
        self.name = name
        self.command = command
        self.shortcut = shortcut
        self.colorHex = colorHex
    }

    var color: Color {
        Color(hex: colorHex) ?? .gray
    }
}

// Color extension for hex support
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }

    func toHex() -> String {
        guard let components = NSColor(self).cgColor.components, components.count >= 3 else {
            return "808080"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
