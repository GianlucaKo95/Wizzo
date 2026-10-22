import Foundation

/// Mirrors the `manual_games` table (010_manual_games.sql) - one row per
/// "Rechenblock" game, the digital replacement for a paper scoring block
/// used for games played at a real table rather than through a `rooms` row.
/// Written directly by the client (RLS: only the host), unlike `rooms`
/// where the edge function is the sole writer - see the migration's own
/// comment for why that's safe here (the real game is already over by the
/// time this gets entered).
struct ManualGame: Codable, Identifiable, Equatable {
    let id: UUID
    let hostId: UUID
    let edition: String
    let maxRounds: Int
    /// Bids for the round currently being played, locked in once everyone
    /// (including the dealer) has bid, cleared again once that round's
    /// result is saved - mirrors the two-phase round in ManualGamePlay.
    var pendingBids: [String: Int]?
    var finishedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case hostId = "host_id"
        case edition
        case maxRounds = "max_rounds"
        case pendingBids = "pending_bids"
        case finishedAt = "finished_at"
        case createdAt = "created_at"
    }
}

/// Mirrors a row of `manual_game_players` - `userId` nil means a guest with
/// no account to attribute stats to (finishManualGame skips those).
struct ManualGamePlayer: Codable, Identifiable, Equatable {
    let id: UUID
    let manualGameId: UUID
    let playerIndex: Int
    let userId: UUID?
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case manualGameId = "manual_game_id"
        case playerIndex = "player_index"
        case userId = "user_id"
        case displayName = "display_name"
    }
}

/// Mirrors a row of `manual_game_rounds` - `results` reuses `RoundResult`
/// (RoundHistoryEntry.swift), the same shape `round_history.results` uses
/// minus `totalScore`, which manual games never write.
struct ManualGameRound: Codable, Identifiable, Equatable {
    let id: UUID
    let manualGameId: UUID
    let round: Int
    var results: [RoundResult]

    enum CodingKeys: String, CodingKey {
        case id
        case manualGameId = "manual_game_id"
        case round
        case results
    }
}

/// Mirrors computeRunningTotals() in App.tsx: a running score total per
/// player, keyed by round - shared by the live table (RechenblockPlayView)
/// and the finished-game read-only table (ManualFinishedGameView).
func computeManualRunningTotals(playerIndexes: [Int], rounds: [ManualGameRound]) -> [Int: [Int: Int]] {
    var out: [Int: [Int: Int]] = [:]
    var acc: [Int: Int] = [:]
    for pi in playerIndexes { acc[pi] = 0 }
    for r in rounds {
        for pi in playerIndexes {
            if let entry = r.results.first(where: { $0.playerIndex == pi }) {
                acc[pi, default: 0] += entry.delta
            }
        }
        out[r.round] = acc
    }
    return out
}
