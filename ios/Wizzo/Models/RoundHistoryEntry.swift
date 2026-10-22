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
///
/// `totalScore` is optional (and, in this app, never actually read) because
/// the identically-shaped `manual_game_rounds.results` reuses this same
/// struct (see StatsViewModel/Rechenblock) but never writes that field -
/// saveRound() in App.tsx's ManualGamePlay only ever sets playerIndex/name/
/// bid/got/delta. Before this fix it was non-optional, which made decoding
/// throw for every manual game round and silently emptied Stats' entire
/// past-games list for any user with a finished Rechenblock game.
struct RoundResult: Codable, Equatable {
    let playerIndex: Int
    let name: String
    let bid: Int
    let got: Int
    let delta: Int
    let totalScore: Int?
}
