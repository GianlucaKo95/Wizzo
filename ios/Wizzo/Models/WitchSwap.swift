import Foundation

/// Mirrors `rooms.witch_swap` - a plain JS object literal written by
/// `index.ts`'s witch-swap handling, so (like TrickEntry) its key is
/// camelCase `playerName` even though every actual column in this schema
/// is snake_case (docs/DATABASE.md). Shown during `phase == "witchReveal"`.
struct WitchSwap: Codable, Equatable {
    let playerName: String
    let gave: Card
    let took: Card
}
