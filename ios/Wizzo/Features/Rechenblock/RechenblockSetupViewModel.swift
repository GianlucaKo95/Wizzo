import Foundation
import Supabase

/// One seating slot being filled in on the roster screen - either a linked
/// registered user (found via search) or a plain guest name. Not a DB row;
/// turns into a `manual_game_players` row only once `start()` succeeds.
struct RosterSlot: Identifiable, Equatable {
    let id: Int
    var userId: UUID?
    var name: String
}

/// A registered user found via the roster screen's username search.
struct RechenblockPlayerCandidate: Identifiable, Codable {
    let id: UUID
    let username: String
}

/// Mirrors ManualGameSetup in App.tsx: pick who's playing (registered users
/// via search, or guests by name), then fix the seating order, then create
/// the game. Reordering uses a plain SwiftUI `List` in permanent edit mode
/// instead of the web's custom Pointer-Events drag implementation - a
/// deliberate simplification, since `.onMove` already gives touch
/// reordering for free here.
@MainActor
final class RechenblockSetupViewModel: ObservableObject {
    enum Stage { case roster, order }

    @Published var stage: Stage = .roster
    @Published var edition = "classic"
    @Published var count = 4
    @Published var slots: [RosterSlot]
    @Published var isLoading = false
    @Published var errorMessage: String?

    let userId: UUID
    private var nextSlotId = 4

    init(userId: UUID) {
        self.userId = userId
        self.slots = (0..<4).map { RosterSlot(id: $0, userId: nil, name: "") }
    }

    var excludeIds: [UUID] { slots.compactMap(\.userId) }
    var openSlotCount: Int { slots.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count }
    var roundsPreview: Int { 60 / count }

    func changeCount(_ n: Int) {
        count = n
        if slots.count < n {
            while slots.count < n {
                slots.append(RosterSlot(id: nextSlotId, userId: nil, name: ""))
                nextSlotId += 1
            }
        } else if slots.count > n {
            slots = Array(slots.prefix(n))
        }
    }

    func goToOrder() {
        errorMessage = nil
        guard openSlotCount == 0 else {
            errorMessage = "Bitte für jede Position einen Namen eintragen oder Spieler wählen"
            return
        }
        stage = .order
    }

    func move(from source: IndexSet, to destination: Int) {
        slots.move(fromOffsets: source, toOffset: destination)
    }

    /// Mirrors start() in App.tsx: create the game row, then its players -
    /// if the second insert fails, the game row is rolled back so a half-
    /// created game never lingers as a phantom "active game".
    func start() async -> Bool {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let newGame = NewManualGame(hostId: userId, edition: edition, maxRounds: roundsPreview)
        guard let game: ManualGame = try? await SupabaseService.client
            .from("manual_games")
            .insert(newGame)
            .select()
            .single()
            .execute()
            .value
        else {
            errorMessage = "Spiel konnte nicht erstellt werden"
            return false
        }

        let rows = slots.enumerated().map { index, slot in
            NewManualGamePlayer(
                manualGameId: game.id, playerIndex: index,
                userId: slot.userId, displayName: slot.name.trimmingCharacters(in: .whitespaces)
            )
        }
        do {
            try await SupabaseService.client.from("manual_game_players").insert(rows).execute()
            return true
        } catch {
            errorMessage = "Spieler konnten nicht gespeichert werden"
            try? await SupabaseService.client.from("manual_games").delete().eq("id", value: game.id).execute()
            return false
        }
    }
}

private struct NewManualGame: Encodable {
    let hostId: UUID
    let edition: String
    let maxRounds: Int

    enum CodingKeys: String, CodingKey {
        case hostId = "host_id"
        case edition
        case maxRounds = "max_rounds"
    }
}

private struct NewManualGamePlayer: Encodable {
    let manualGameId: UUID
    let playerIndex: Int
    let userId: UUID?
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case manualGameId = "manual_game_id"
        case playerIndex = "player_index"
        case userId = "user_id"
        case displayName = "display_name"
    }
}
