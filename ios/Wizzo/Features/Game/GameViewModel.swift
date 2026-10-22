import Foundation
import Supabase

@MainActor
final class GameViewModel: ObservableObject {
    @Published var room: Room?
    @Published var players: [RoomPlayer] = []
    @Published var myHand: [Card] = []
    @Published var currentUserId: UUID?
    @Published var errorMessage: String?
    @Published var isLoading = true
    @Published var isSubmitting = false

    private let roomId: UUID
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var channel: RealtimeChannel?
    private var aiTriggerPending = false
    private var aiTriggerLastKey: String?
    private var clearTrickPending = false
    private var witchRevealPending = false

    private static let roomColumns = "id, code, phase, edition, round, max_rounds, dealer, current_player, trump_card, trump_suit, current_trick, last_trick_winner, last_trick_cards, pending_rainbow7, pending_rainbow9, pending_witch, witch_swap"
    private static let playerColumns = "id, room_id, user_id, player_index, is_ai, ai_name, connected, bid, tricks_won, score, hand_count, visible_hand"

    var myIndex: Int? {
        players.first(where: { $0.userId == currentUserId })?.playerIndex
    }

    var isHost: Bool { myIndex == 0 }
    var isMyTurn: Bool { room?.currentPlayer != nil && room?.currentPlayer == myIndex }

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

    // Mirrors loadPlayersSecure() in wizard/frontend/src/App.tsx exactly:
    // room_players_view never carries this player's own hand (the view
    // forces visible_hand null for your own row), so the own hand comes
    // from a second, separately-scoped query against the raw table (RLS
    // only allows reading your own row there anyway).
    func load() async {
        guard let myUserId = currentUserId else { return }
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
            async let ownHandFetch: [OwnHandRow] = SupabaseService.client
                .from("room_players")
                .select("player_index, hand")
                .eq("room_id", value: roomId)
                .eq("user_id", value: myUserId)
                .execute()
                .value

            let (room, players, ownHandRows) = try await (roomFetch, playersFetch, ownHandFetch)
            self.room = room
            self.players = players
            self.myHand = ownHandRows.first?.hand ?? []
            maybeScheduleAITurn()
            maybeScheduleClearTrick()
            maybeScheduleWitchRevealDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func bid(_ value: Int) async {
        await submit("bid", extra: ["bid": value])
    }

    /// `suit` is only sent for Jongleur/George Weasley (rainbow7) and Gleis
    /// 9¾ (rainbow9) - the only two cards where playing them means choosing
    /// a suit to fight with (index.ts's playCard: `isRainbowChoice`). Every
    /// other card ignores it server-side, so passing nil for them is safe.
    func playCard(_ cardId: String, suit: String? = nil) async {
        var extra: [String: Any] = ["cardId": cardId]
        if let suit { extra["suit"] = suit }
        await submit("playCard", extra: extra)
    }

    /// Jongleur/George Weasley (rainbow7): once it's played, every player
    /// still in `room.pendingRainbow7` must pick a card from their own hand
    /// to pass to their left neighbor (see passCard in index.ts).
    func passCard(_ cardId: String) async {
        await submit("passCard", extra: ["cardId": cardId])
    }

    /// Gleis 9¾ (rainbow9): the trick winner must adjust their own bid by
    /// exactly ±1 (clamped to >= 0 server-side).
    func rainbow9Adjust(_ adjust: Int) async {
        await submit("rainbow9Adjust", extra: ["adjust": adjust])
    }

    /// Hexe/Bellatrix: the player who played it (room.pendingWitch) takes
    /// one card from the just-completed trick and gives one of their own
    /// hand cards back in exchange - a dedicated playSpecial action, not
    /// playCard, same shape as playWizardfool below.
    func playWitchSwap(takeCardId: String, giveCardId: String) async {
        await submit("playSpecial", extra: ["specialAction": "witch", "takeCardId": takeCardId, "giveCardId": giveCardId])
    }

    /// Ron Weasley/Zauberer-oder-Narr: the only special card played through
    /// `playSpecial` instead of plain `playCard` - the server resolves it as
    /// a real Wizard or Fool depending on `choice` (index.ts, case
    /// "playSpecial", sa === "wizardfool").
    func playWizardfool(cardId: String, choice: String) async {
        await submit("playSpecial", extra: ["specialAction": "wizardfool", "cardId": cardId, "choice": choice])
    }

    func chooseTrump(_ suit: String) async {
        await submit("chooseTrump", extra: ["suit": suit])
    }

    /// Lupin/Werwolf: whoever is dealt it picks the suit that leads the
    /// *entire round* (room.phase "choosingWerewolf", set once at deal time
    /// - see dealRound() in index.ts), not just one trick.
    func chooseWerewolf(_ suit: String) async {
        await submit("chooseWerewolf", extra: ["suit": suit])
    }

    func nextRound() async {
        await submit("nextRound")
    }

    func newGame() async {
        await submit("newGame")
    }

    func leave() async {
        _ = await GameActionClient.call(roomId: roomId.uuidString, action: "leaveRoom")
    }

    private func submit(_ action: String, extra: [String: Any] = [:]) async {
        isSubmitting = true
        defer { isSubmitting = false }
        let result = await GameActionClient.call(roomId: roomId.uuidString, action: action, extra: extra)
        if let error = result["error"] as? String {
            errorMessage = error
        } else {
            errorMessage = nil
            await load()
        }
    }

    // The web app drives both of these from the client rather than having
    // the server schedule them, so a human gets to actually see the AI's
    // move / the completed trick before the game moves on (App.tsx: a 2s
    // delay before triggerAI, a 5s delay before clearTrick). The dedup keys
    // mirror aiTriggerLastKey/clearTrickPending there - without them, every
    // Realtime event in the window would schedule a duplicate call.
    private func maybeScheduleAITurn() {
        guard let room, room.phase == "playing",
              let currentPlayer = room.currentPlayer,
              let player = players.first(where: { $0.playerIndex == currentPlayer }),
              player.isAi
        else { return }
        let key = "\(currentPlayer)-\(room.currentTrick?.count ?? 0)-\(room.round ?? 0)"
        guard !aiTriggerPending, aiTriggerLastKey != key else { return }
        aiTriggerPending = true
        aiTriggerLastKey = key
        Task {
            try? await Task.sleep(for: .seconds(2))
            aiTriggerPending = false
            _ = await GameActionClient.call(roomId: roomId.uuidString, action: "triggerAI")
        }
    }

    private func maybeScheduleClearTrick() {
        guard room?.phase == "trickEnd", !clearTrickPending else { return }
        clearTrickPending = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            clearTrickPending = false
            _ = await GameActionClient.call(roomId: roomId.uuidString, action: "clearTrick")
        }
    }

    /// Hexe/Bellatrix: same client-driven-delay pattern as clearTrick above
    /// (App.tsx uses the same 4s), so the swap result is actually visible
    /// before the room moves on - the server has its own 6s fallback
    /// (scheduleWitchRevealDone in index.ts) in case no client is open.
    private func maybeScheduleWitchRevealDone() {
        guard room?.phase == "witchReveal", !witchRevealPending else { return }
        witchRevealPending = true
        Task {
            try? await Task.sleep(for: .seconds(4))
            witchRevealPending = false
            _ = await GameActionClient.call(roomId: roomId.uuidString, action: "witchRevealDone")
        }
    }

    private func watchRealtime() async {
        let ch = await SupabaseService.client.channel("room-game:\(roomId.uuidString)")
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

private struct OwnHandRow: Codable {
    let playerIndex: Int
    let hand: [Card]

    enum CodingKeys: String, CodingKey {
        case playerIndex = "player_index"
        case hand
    }
}
