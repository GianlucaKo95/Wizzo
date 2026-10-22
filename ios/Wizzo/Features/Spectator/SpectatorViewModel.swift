import Foundation
import Supabase

/// Read-only watcher, mirrors SpectatorRoom in App.tsx - deliberately its
/// own small view model rather than reusing GameViewModel, same reasoning
/// ARCHITECTURE.md gives for the web's separate SpectatorRoom component:
/// the real-player view assumes a seat throughout (own hand, bidding,
/// playing a card, ...), none of which applies here. Reuses the Room/
/// RoomPlayer models directly - a spectator's query is just a narrower
/// column subset of the same tables.
@MainActor
final class SpectatorViewModel: ObservableObject {
    @Published var room: Room?
    @Published var players: [RoomPlayer] = []
    @Published var isLoading = true
    @Published var errorMessage: String?

    private let roomId: UUID
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var channel: RealtimeChannel?

    private static let roomColumns = "id, code, phase, edition, round, max_rounds, dealer, current_player, trump_card, trump_suit, current_trick, last_trick_winner, last_trick_cards, log"
    private static let playerColumns = "id, room_id, user_id, player_index, is_ai, ai_name, connected, bid, tricks_won, score, hand_count"

    init(roomId: UUID) {
        self.roomId = roomId
    }

    func start() async {
        await load()
        isLoading = false
        watchTask = Task { await watchRealtime() }
        pollTask = Task { await pollFallback() }
    }

    func stop() {
        watchTask?.cancel()
        pollTask?.cancel()
        if let channel {
            Task { await channel.unsubscribe() }
        }
    }

    func load() async {
        do {
            async let roomFetch: Room = SupabaseService.client
                .from("rooms")
                .select(Self.roomColumns)
                .eq("id", value: roomId)
                .single()
                .execute()
                .value
            async let playersFetch: [RoomPlayer] = SupabaseService.client
                .from("room_players_view")
                .select(Self.playerColumns)
                .eq("room_id", value: roomId)
                .order("player_index")
                .execute()
                .value
            let (room, players) = try await (roomFetch, playersFetch)
            self.room = room
            self.players = players
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func leave() async {
        _ = await GameActionClient.call(roomId: roomId.uuidString, action: "leaveSpectating")
    }

    /// Spectators have no own room_players row, so GameViewModel's
    /// postgres_changes stream (RLS-scoped to the caller's own row) would
    /// never fire here - a plain "rooms" UPDATE watch plus the poll
    /// fallback below is the whole story, same as SpectatorRoom in App.tsx.
    private func watchRealtime() async {
        let ch = await SupabaseService.client.channel("spectate:\(roomId.uuidString)")
        channel = ch
        let roomChanges = await ch.postgresChanges(UpdateAction.self, table: "rooms", filter: .eq("id", value: roomId.uuidString))
        do {
            try await ch.subscribe()
        } catch {
            return
        }
        for await _ in roomChanges {
            await load()
        }
    }

    private func pollFallback() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            await load()
        }
    }
}
