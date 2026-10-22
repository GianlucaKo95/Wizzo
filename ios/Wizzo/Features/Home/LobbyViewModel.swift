import Foundation
import Supabase

@MainActor
final class LobbyViewModel: ObservableObject {
    @Published var room: Room?
    @Published var players: [RoomPlayer] = []
    @Published var currentUserId: UUID?
    @Published var errorMessage: String?
    @Published var isLoading = true
    @Published var isSubmitting = false

    private let roomId: UUID
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var channel: RealtimeChannel?

    var isHost: Bool {
        players.first(where: { $0.userId == currentUserId })?.playerIndex == 0
    }

    /// Mirrors GameRoom's `effectiveAiCount` in wizard/frontend/src/App.tsx:
    /// AI only tops the table up to 3 total seats if fewer real players have
    /// joined - above that, only the humans who actually joined play.
    var effectiveAiCount: Int {
        max(0, 3 - players.count)
    }

    init(roomId: UUID) {
        self.roomId = roomId
    }

    func start() async {
        currentUserId = try? await SupabaseService.client.auth.session.user.id
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
            let room: Room = try await SupabaseService.client
                .from("rooms")
                .select("id, code, phase, edition")
                .eq("id", value: roomId)
                .single()
                .execute()
                .value
            let players: [RoomPlayer] = try await SupabaseService.client
                .from("room_players_view")
                .select("id, room_id, user_id, player_index, is_ai, ai_name, connected")
                .eq("room_id", value: roomId)
                .order("player_index")
                .execute()
                .value
            self.room = room
            self.players = players
            // Once the game actually starts, GameView takes over with its
            // own Realtime watch/poll - no point running two for the same
            // room (wasteful, not incorrect, but easy to avoid).
            if room.phase != "lobby" {
                stop()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startGame() async {
        isSubmitting = true
        defer { isSubmitting = false }
        let result = await GameActionClient.call(
            roomId: roomId.uuidString,
            action: "startGame",
            extra: ["aiCount": effectiveAiCount, "edition": room?.edition ?? "classic"]
        )
        if let error = result["error"] as? String {
            errorMessage = error
        } else {
            await load()
        }
    }

    func leave() async {
        _ = await GameActionClient.call(roomId: roomId.uuidString, action: "leaveRoom")
    }

    // Realtime is an optimization, not a consistency guarantee (see
    // docs/ARCHITECTURE.md) - every event here just triggers a full reload
    // rather than trying to apply the change locally, same simplification
    // AppState makes for the session. A short poll fallback covers a
    // dropped Realtime message, same pattern the web app uses in a few
    // places for the same reason.
    private func watchRealtime() async {
        let ch = await SupabaseService.client.channel("room-lobby:\(roomId.uuidString)")
        channel = ch

        let playerChanges = await ch.postgresChanges(AnyAction.self, table: "room_players", filter: .eq("room_id", value: roomId.uuidString))
        let roomChanges = await ch.postgresChanges(UpdateAction.self, table: "rooms", filter: .eq("id", value: roomId.uuidString))

        do {
            try await ch.subscribe()
        } catch {
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await _ in playerChanges {
                    await self?.load()
                }
            }
            group.addTask { [weak self] in
                for await _ in roomChanges {
                    await self?.load()
                }
            }
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
