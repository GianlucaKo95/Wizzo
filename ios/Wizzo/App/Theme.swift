import SwiftUI

/// Mirrors the `C`/`RADIUS` constants in wizard/frontend/src/App.tsx (same
/// hex values) - keeps the native app visually consistent with the web app
/// it's replacing instead of inventing a second, drifting palette.
enum Theme {
    static let bgDark = Color(hex: 0x10161A)
    static let bgPanel = Color(hex: 0x17201B)
    static let accent = Color(hex: 0x263029)
    static let accentLight = Color(hex: 0x3A4B40)
    static let gold = Color(hex: 0xC9A84C)
    static let goldLight = Color(hex: 0xE4C97A)
    static let ivory = Color(hex: 0xF2E8D5)
    static let ivoryDim = Color(hex: 0xB8A98A)
    static let error = Color(hex: 0xCF4444)
    static let success = Color(hex: 0x2D9E5F)

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    /// Mirrors SUIT_COLORS/SUIT_SYMBOLS in wizard/frontend/src/types.ts -
    /// the symbols are Hogwarts-house initials (the app's cosmetic theme,
    /// see cards.ts' HOUSES), not generic suit icons.
    static func suitColor(_ suit: String?) -> Color {
        switch suit {
        case "red": return Color(hex: 0xE63946)
        case "blue": return Color(hex: 0x457B9D)
        case "green": return Color(hex: 0x2D6A4F)
        case "yellow": return Color(hex: 0xE9C46A)
        default: return ivoryDim
        }
    }

    static func suitSymbol(_ suit: String?) -> String {
        switch suit {
        case "red": return "G"
        case "blue": return "R"
        case "green": return "S"
        case "yellow": return "H"
        default: return ""
        }
    }

    /// Mirrors specialConfigs in wizard/frontend/src/CardView.tsx (same
    /// label/color per special card) - the native app shows text-only cards,
    /// no illustrated card art pipeline yet (see docs/IOS.md), so this is the
    /// entire visual treatment for a special card.
    static func specialLabel(_ specialType: String) -> String {
        switch specialType {
        case "dragon": return "D"
        case "fairy": return "✦"
        case "witch": return "H"
        case "werewolf": return "W"
        case "vampire": return "V"
        case "bomb": return "✕"
        case "rainbow7": return "7½"
        case "rainbow9": return "9¾"
        default: return "?"
        }
    }

    static func specialColor(_ specialType: String) -> Color {
        switch specialType {
        case "dragon": return Color(hex: 0xA8C0E8)
        case "fairy": return Color(hex: 0xD2B4DE)
        case "witch": return Color(hex: 0xC0392B)
        case "werewolf": return Color(hex: 0xF7DC6F)
        case "vampire": return Color(hex: 0x9B59B6)
        case "bomb": return Color(hex: 0xE8DAEF)
        case "rainbow7": return Color(hex: 0xF1C40F)
        case "rainbow9": return Color(hex: 0xAED6F1)
        default: return ivoryDim
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
