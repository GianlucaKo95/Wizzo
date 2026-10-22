import Foundation

/// Mirrors a `{card, playerIndex}` entry in `rooms.current_trick`/
/// `last_trick_cards` - written by the edge function as a plain JS object
/// literal, so the key is camelCase `playerIndex` even though every actual
/// Postgres *column* in this schema is snake_case (docs/DATABASE.md).
struct TrickEntry: Codable, Identifiable, Equatable {
    let card: Card
    let playerIndex: Int

    var id: String { "\(playerIndex)-\(card.id)" }
}
