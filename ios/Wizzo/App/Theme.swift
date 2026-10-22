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
