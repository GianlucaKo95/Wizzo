import Foundation

/// Mirrors `Card` in wizard/frontend/src/types.ts. `value` is `Double` (not
/// `Int`) because the anniversary-edition special cards use fractional
/// values (7.5, 9.75) - classic-only cards (this phase's scope, see
/// docs/IOS.md) always have whole-number values, but sharing one model now
/// avoids a breaking change once specials are added.
struct Card: Codable, Identifiable, Equatable {
    let id: String
    let type: String
    let suit: String?
    let value: Double
    let specialType: String?
}
