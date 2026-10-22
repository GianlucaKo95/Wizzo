import Foundation
import Supabase

/// Mirrors the `user_stats` view (021_bid_accuracy_hit_rate.sql) - one
/// aggregate row per user, server-computed from `game_stats`.
struct UserStats: Codable {
    let gamesPlayed: Int
    let gamesWon: Int
    let avgScore: Double?
    let avgPlacement: Double?
    let bidAccuracyPct: Double?

    enum CodingKeys: String, CodingKey {
        case gamesPlayed = "games_played"
        case gamesWon = "games_won"
        case avgScore = "avg_score"
        case avgPlacement = "avg_placement"
        case bidAccuracyPct = "bid_accuracy_pct"
    }
}

struct PastGame: Identifiable {
    let gameKey: String
    let playedAt: Date
    let edition: String?
    let place: Int
    let score: Int
    let totalRounds: Int
    let playerCount: Int
    let rows: [PastGamePlayer]
    let roomDataAvailable: Bool

    var id: String { gameKey }
}

struct PastGamePlayer: Identifiable {
    let userId: String
    let name: String
    let placement: Int
    let score: Int

    var id: String { userId }
}

/// Mirrors usePastGames() in App.tsx, with one deliberate simplification:
/// the web's client-side heuristic that reconstructs pre-game_session_id
/// legacy games from played_at proximity (see the long comment above
/// reconstructOrphan() there) isn't replicated here. Every game created
/// since 022_game_session_id.sql always carries a game_session_id, so that
/// heuristic only ever matters for games from before that migration - a
/// shrinking, already-historical slice of data. Those few legacy rows just
/// show as "Mitspieler-Daten nicht mehr verfügbar" here instead, same as
/// any other roomDataAvailable:false case.
@MainActor
final class StatsViewModel: ObservableObject {
    @Published var stats: UserStats?
    @Published var pastGames: [PastGame]?

    func load() async {
        guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
        stats = try? await SupabaseService.client
            .from("user_stats")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        await loadPastGames(userId: userId)
    }

    private func loadPastGames(userId: UUID) async {
        pastGames = nil
        do {
            let mine: [GameStatsRow] = try await SupabaseService.client
                .from("game_stats")
                .select("room_id, manual_game_id, game_session_id, placement, final_score, total_rounds, played_at")
                .eq("user_id", value: userId)
                .order("played_at", ascending: false)
                .limit(20)
                .execute()
                .value
            guard !mine.isEmpty else { pastGames = []; return }

            let roomIds = Array(Set(mine.compactMap { $0.roomId }))
            let sessionIds = Array(Set(mine.compactMap { $0.gameSessionId }))
            let manualGameIds = Array(Set(mine.compactMap { $0.manualGameId }))

            var rowsByGroup: [UUID: [GroupRow]] = [:]
            if !roomIds.isEmpty {
                let roomRows: [RoomGroupRow] = try await SupabaseService.client
                    .from("game_stats")
                    .select("room_id, user_id, placement, final_score")
                    .in("room_id", values: roomIds)
                    .execute()
                    .value
                for r in roomRows {
                    rowsByGroup[r.roomId, default: []].append(GroupRow(userId: r.userId, placement: r.placement, finalScore: r.finalScore))
                }
            }
            if !sessionIds.isEmpty {
                let sessionRows: [SessionGroupRow] = try await SupabaseService.client
                    .from("game_stats")
                    .select("game_session_id, user_id, placement, final_score")
                    .in("game_session_id", values: sessionIds)
                    .execute()
                    .value
                for r in sessionRows {
                    rowsByGroup[r.gameSessionId, default: []].append(GroupRow(userId: r.userId, placement: r.placement, finalScore: r.finalScore))
                }
            }

            var editionByRoom: [UUID: String] = [:]
            if !roomIds.isEmpty {
                let roomsData: [RoomEditionRow] = try await SupabaseService.client
                    .from("rooms")
                    .select("id, edition")
                    .in("id", values: roomIds)
                    .execute()
                    .value
                for r in roomsData { editionByRoom[r.id] = r.edition }
            }

            // Manual (Rechenblock) games: no roster table RLS lets a
            // non-host participant read (manual_game_players), so - same as
            // the web - the standings are reconstructed straight from
            // manual_game_rounds.results, which carries each entry's own
            // display name already (see saveRound in App.tsx).
            var manualRowsByGame: [UUID: [PastGamePlayer]] = [:]
            if !manualGameIds.isEmpty {
                let manualRounds: [ManualGameRoundRow] = try await SupabaseService.client
                    .from("manual_game_rounds")
                    .select("manual_game_id, results")
                    .in("manual_game_id", values: manualGameIds)
                    .execute()
                    .value
                for gameId in manualGameIds {
                    let roundsForGame = manualRounds.filter { $0.manualGameId == gameId }
                    guard !roundsForGame.isEmpty else { continue }
                    var totalsByIndex: [Int: (name: String, score: Int)] = [:]
                    for round in roundsForGame {
                        for entry in round.results {
                            var totals = totalsByIndex[entry.playerIndex] ?? (name: entry.name, score: 0)
                            totals.score += entry.delta
                            totalsByIndex[entry.playerIndex] = totals
                        }
                    }
                    let sorted = totalsByIndex.sorted { $0.value.score > $1.value.score }
                    manualRowsByGame[gameId] = sorted.enumerated().map { index, item in
                        PastGamePlayer(userId: "\(gameId)-\(item.key)", name: item.value.name, placement: index + 1, score: item.value.score)
                    }
                }
            }

            let allUserIds = Set(rowsByGroup.values.flatMap { $0.map(\.userId) })
            var nameById: [UUID: String] = [:]
            if !allUserIds.isEmpty {
                let profiles: [Profile] = try await SupabaseService.client
                    .from("profiles")
                    .select("id, username")
                    .in("id", values: Array(allUserIds))
                    .execute()
                    .value
                for p in profiles { nameById[p.id] = p.username }
            }

            pastGames = mine.map { g in
                let isManual = g.manualGameId != nil
                let groupKey = g.gameSessionId ?? g.roomId
                let manualRows = g.manualGameId.flatMap { manualRowsByGame[$0] }
                let groupRows = groupKey.flatMap { rowsByGroup[$0] }
                let roomDataAvailable = isManual ? (manualRows != nil) : (groupRows != nil)
                let rows: [PastGamePlayer] = isManual
                    ? (manualRows ?? [])
                    : (groupRows ?? [])
                        .sorted { $0.placement < $1.placement }
                        .map { PastGamePlayer(userId: $0.userId.uuidString, name: nameById[$0.userId] ?? "Spieler", placement: $0.placement, score: $0.finalScore) }
                return PastGame(
                    gameKey: groupKey?.uuidString ?? "\(g.playedAt.timeIntervalSince1970)",
                    playedAt: g.playedAt,
                    edition: g.roomId.flatMap { editionByRoom[$0] },
                    place: g.placement,
                    score: g.finalScore,
                    totalRounds: g.totalRounds,
                    playerCount: isManual ? (manualRows?.count ?? 0) : (groupRows?.count ?? 0),
                    rows: rows,
                    roomDataAvailable: roomDataAvailable
                )
            }
        } catch {
            pastGames = []
        }
    }
}

private struct GroupRow {
    let userId: UUID
    let placement: Int
    let finalScore: Int
}

private struct GameStatsRow: Codable {
    let roomId: UUID?
    let manualGameId: UUID?
    let gameSessionId: UUID?
    let placement: Int
    let finalScore: Int
    let totalRounds: Int
    let playedAt: Date

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case manualGameId = "manual_game_id"
        case gameSessionId = "game_session_id"
        case placement
        case finalScore = "final_score"
        case totalRounds = "total_rounds"
        case playedAt = "played_at"
    }
}

private struct RoomGroupRow: Codable {
    let roomId: UUID
    let userId: UUID
    let placement: Int
    let finalScore: Int

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case userId = "user_id"
        case placement
        case finalScore = "final_score"
    }
}

private struct SessionGroupRow: Codable {
    let gameSessionId: UUID
    let userId: UUID
    let placement: Int
    let finalScore: Int

    enum CodingKeys: String, CodingKey {
        case gameSessionId = "game_session_id"
        case userId = "user_id"
        case placement
        case finalScore = "final_score"
    }
}

private struct RoomEditionRow: Codable {
    let id: UUID
    let edition: String
}

/// manual_game_rounds.results carries the same {playerIndex, name, bid,
/// got, delta, totalScore} shape as round_history.results (both written
/// from the same RoundResult type in types.ts) - reuses RoundResult as-is.
private struct ManualGameRoundRow: Codable {
    let manualGameId: UUID
    let results: [RoundResult]

    enum CodingKeys: String, CodingKey {
        case manualGameId = "manual_game_id"
        case results
    }
}
