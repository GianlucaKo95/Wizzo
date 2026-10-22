import Foundation
import Supabase

/// Mirrors ManualScoreboardScreen's load() in App.tsx: the host's one
/// in-progress game (if any), plus the history of actually-completed ones
/// ("Frühere Spiele" - a game ended early via "SPIEL BEENDEN" before
/// max_rounds still gets finished_at and still counts in stats, it just
/// doesn't clutter this particular list unless every round was played).
@MainActor
final class RechenblockViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var userId: UUID?
    @Published var activeGame: ManualGame?
    @Published var pastGames: [ManualGame] = []
    @Published var viewingGame: ManualGame?

    func load() async {
        // Written as two statements rather than `userId ?? (try? await ...)` -
        // the nil-coalescing operator's autoclosure doesn't consistently
        // support an `await` on its right-hand side.
        if userId == nil {
            userId = try? await SupabaseService.client.auth.session.user.id
        }
        guard let userId else {
            isLoading = false
            return
        }
        do {
            let games: [ManualGame] = try await SupabaseService.client
                .from("manual_games")
                .select()
                .eq("host_id", value: userId)
                .order("created_at", ascending: false)
                .execute()
                .value

            let active = games.first { $0.finishedAt == nil }
            let finished = games.filter { $0.finishedAt != nil }
            if finished.isEmpty {
                pastGames = []
            } else {
                let roundRows: [RoundCountRow] = try await SupabaseService.client
                    .from("manual_game_rounds")
                    .select("manual_game_id")
                    .in("manual_game_id", values: finished.map(\.id))
                    .execute()
                    .value
                var counts: [UUID: Int] = [:]
                for r in roundRows { counts[r.manualGameId, default: 0] += 1 }
                pastGames = finished.filter { (counts[$0.id] ?? 0) >= $0.maxRounds }
            }

            activeGame = active
        } catch {
            activeGame = nil
            pastGames = []
        }
        isLoading = false
    }
}

private struct RoundCountRow: Codable {
    let manualGameId: UUID

    enum CodingKeys: String, CodingKey {
        case manualGameId = "manual_game_id"
    }
}
