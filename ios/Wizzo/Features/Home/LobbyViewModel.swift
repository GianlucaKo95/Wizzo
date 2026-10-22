import Foundation
import Supabase

/// One accepted friend who could be invited into this room's lobby.
struct InviteCandidate: Identifiable {
    let id: UUID
    let username: String
    let avatarUrl: String?
}

@MainActor
final class LobbyViewModel: ObservableObject {
    @Published var room: Room?
    @Published var players: [RoomPlayer] = []
    @Published var currentUserId: UUID?
    @Published var errorMessage: String?
    @Published var isLoading = true
    @Published var isSubmitting = false
    @Published var inviteCandidates: [InviteCandidate]?
    @Published var invitedIds: Set<UUID> = []
    @Published var inviteSendingId: UUID?
    @Published var avatarUrls: [UUID: String] = [:]

    private var myUsername: String?

    private let roomId: UUID
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var channel: RealtimeChannelV2?

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
            await loadAvatars(for: players.compactMap(\.userId))
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

    /// `room_players_view` doesn't carry `avatar_url` - mirrors the web's
    /// own separate `profiles`-by-id batch fetch for seat avatars.
    private func loadAvatars(for userIds: [UUID]) async {
        guard !userIds.isEmpty else { return }
        let profiles: [Profile] = (try? await SupabaseService.client
            .from("profiles")
            .select("id, username, avatar_url")
            .in("id", values: Array(Set(userIds)))
            .execute()
            .value) ?? []
        for profile in profiles { avatarUrls[profile.id] = profile.avatarUrl }
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

    /// Mirrors openInvitePicker() in App.tsx: the accepted-friends list plus
    /// which of them already have a pending invite out to this specific
    /// room, loaded once (not on every poll tick - this is a lobby-only,
    /// manually-triggered picker, not something that needs to stay live).
    func loadInviteCandidates() async {
        guard inviteCandidates == nil, let userId = currentUserId else { return }
        do {
            async let friendRowsFetch: [FriendRow] = SupabaseService.client
                .from("friends")
                .select("id, requester_id, addressee_id, status")
                .eq("status", value: "accepted")
                .or("requester_id.eq.\(userId),addressee_id.eq.\(userId)")
                .execute()
                .value
            async let myProfileFetch: Profile = SupabaseService.client
                .from("profiles")
                .select("id, username")
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            async let pendingFetch: [PendingInviteRow] = SupabaseService.client
                .from("room_invites")
                .select("to_user_id")
                .eq("room_id", value: roomId)
                .eq("from_user_id", value: userId)
                .execute()
                .value

            let (friendRows, myProfile, pending) = try await (friendRowsFetch, myProfileFetch, pendingFetch)
            myUsername = myProfile.username
            invitedIds = Set(pending.map { $0.toUserId })

            let otherIds = Array(Set(friendRows.map { $0.requesterId == userId ? $0.addresseeId : $0.requesterId }))
            guard !otherIds.isEmpty else { inviteCandidates = []; return }
            let profiles: [Profile] = try await SupabaseService.client
                .from("profiles")
                .select("id, username, avatar_url")
                .in("id", values: otherIds)
                .execute()
                .value
            inviteCandidates = profiles.map { InviteCandidate(id: $0.id, username: $0.username, avatarUrl: $0.avatarUrl) }
        } catch {
            inviteCandidates = []
        }
    }

    /// Mirrors inviteFriend() in App.tsx, with one simplification: the web
    /// only swallows a unique-constraint violation (code 23505 - already
    /// invited) as a non-error; this just marks `candidate` invited on any
    /// outcome, since `inviteCandidates` is already filtered to confirmed
    /// friends (the only other way this insert could fail server-side), so
    /// there's no realistic failure mode left to distinguish from success.
    func inviteFriend(_ candidate: InviteCandidate) async {
        guard let userId = currentUserId, let room,
              !invitedIds.contains(candidate.id), inviteSendingId == nil
        else { return }
        inviteSendingId = candidate.id
        defer { inviteSendingId = nil }
        let newInvite = NewRoomInvite(
            roomId: roomId, roomCode: room.code, fromUserId: userId,
            fromUsername: myUsername ?? "Spieler", toUserId: candidate.id
        )
        try? await SupabaseService.client.from("room_invites").insert(newInvite).execute()
        invitedIds.insert(candidate.id)
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

        let playerChanges = await ch.postgresChange(AnyAction.self, table: "room_players", filter: .eq("room_id", value: roomId.uuidString))
        let roomChanges = await ch.postgresChange(UpdateAction.self, table: "rooms", filter: .eq("id", value: roomId.uuidString))

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

private struct PendingInviteRow: Codable {
    let toUserId: UUID

    enum CodingKeys: String, CodingKey {
        case toUserId = "to_user_id"
    }
}

private struct NewRoomInvite: Encodable {
    let roomId: UUID
    let roomCode: String
    let fromUserId: UUID
    let fromUsername: String
    let toUserId: UUID

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case roomCode = "room_code"
        case fromUserId = "from_user_id"
        case fromUsername = "from_username"
        case toUserId = "to_user_id"
    }
}
