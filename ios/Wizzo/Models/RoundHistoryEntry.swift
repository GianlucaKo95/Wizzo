import Foundation

/// Mirrors a row of the `round_history` table (docs/DATABASE.md) - one row
/// per round once it's scored, written by apply_round_scores() in
/// 000_full_reset.sql. Read-only here: the App Store/Spielblatt view just
/// displays it, same as wizard/frontend's Scoresheet modal.
struct RoundHistoryEntry: Codable, Identifiable {
    let id: UUID
    let round: Int
    let results: [RoundResult]
}

/// Mirrors a single entry in `round_history.results` (RoundResult in
/// wizard/frontend/src/types.ts) - a plain JS object literal, so (like
/// TrickEntry/WitchSwap) its key is camelCase `playerIndex` even though
/// every actual column in this schema is snake_case.
struct RoundResult: Codable, Equatable {
    let playerIndex: Int
    let name: String
    let bid: Int
    let got: Int
    let delta: Int
    let totalScore: Int
}
