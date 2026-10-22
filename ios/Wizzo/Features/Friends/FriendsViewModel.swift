import Foundation
import Supabase

/// Mirrors a row of the `friends` table (002_friends.sql): one row per
/// person-pair, `status` "pending" until the addressee accepts
/// ("accepted") - declining/removing is a delete, never a status change.
struct FriendRow: Codable, Identifiable, Equatable {
    let id: UUID
    let requesterId: UUID
    let addresseeId: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case addresseeId = "addressee_id"
        case status
    }
}

/// Mirrors a row of the `friends_active_rooms` view (014/016/018_*.sql) -
/// server-computed "which of my accepted friends are currently in a room
/// that hasn't ended", keyed off auth.uid() on both sides of the friendship
/// subquery so a caller only ever sees rows for their OWN friends.
struct FriendActiveRoom: Codable, Identifiable {
    let roomId: UUID
    let code: String
    let phase: String
    let edition: String
    let friendUserId: UUID
    let friendName: String?
    let round: Int?
    let playerCount: Int?

    var id: UUID { roomId }

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case code, phase, edition
        case friendUserId = "friend_user_id"
        case friendName = "friend_name"
        case round
        case playerCount = "player_count"
    }
}

/// Core friend-graph management (Phase 9) plus spectator discovery
/// (Phase 10): search/add by username, accept or decline incoming
/// requests, cancel outgoing ones, remove an existing friend, see which
/// friends are currently in a room and watch one. Deliberately doesn't yet
/// cover the web's general online-status dot (needs presence tracking,
/// unrelated to friends_active_rooms) or tap-to-profile (needs the stats
/// feature) - see docs/IOS.md.
@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var rows: [FriendRow] = []
    @Published var usernames: [UUID: String] = [:]
    @Published var isLoaded = false
    @Published var usernameInput = ""
    @Published var isSending = false
    @Published var message: (text: String, isError: Bool)?
    @Published var busyId: UUID?
    @Published var activeRooms: [FriendActiveRoom] = []
    @Published var spectatingRoomId: UUID?
    @Published var isSpectating = false

    private var currentUserId: UUID?
    private var activeRoomsPollTask: Task<Void, Never>?

    var accepted: [FriendRow] { rows.filter { $0.status == "accepted" } }
    var incoming: [FriendRow] {
        rows.filter { $0.status == "pending" && $0.addresseeId == currentUserId }
    }
    var outgoing: [FriendRow] {
        rows.filter { $0.status == "pending" && $0.requesterId == currentUserId }
    }

    func otherUserId(_ row: FriendRow) -> UUID {
        row.requesterId == currentUserId ? row.addresseeId : row.requesterId
    }

    func name(for userId: UUID) -> String {
        usernames[userId] ?? "…"
    }

    func activeRoom(for userId: UUID) -> FriendActiveRoom? {
        activeRooms.first { $0.friendUserId == userId }
    }

    /// Mirrors loadActiveRooms() + its 10s setInterval poll in App.tsx: this
    /// panel is only open briefly and friends_active_rooms already re-
    /// derives everything server-side from auth.uid() on every read, so a
    /// cheap periodic refresh is plenty to catch a friend starting a new
    /// game while the screen is open - no realtime subscription needed.
    func startWatchingActiveRooms() {
        guard activeRoomsPollTask == nil else { return }
        activeRoomsPollTask = Task {
            while !Task.isCancelled {
                await loadActiveRooms()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopWatchingActiveRooms() {
        activeRoomsPollTask?.cancel()
        activeRoomsPollTask = nil
    }

    func loadActiveRooms() async {
        do {
            activeRooms = try await SupabaseService.client
                .from("friends_active_rooms")
                .select("room_id, code, phase, edition, friend_user_id, friend_name, round, player_count")
                .execute()
                .value
        } catch {
            activeRooms = []
        }
    }

    /// Mirrors spectate() in App.tsx: spectateRoom (index.ts) checks
    /// server-side that the caller is actually friends with someone seated
    /// in the room before inserting into room_spectators - this is purely
    /// the request, SpectatorView does the actual watching once this
    /// succeeds.
    func spectate(_ room: FriendActiveRoom) async {
        guard !isSpectating else { return }
        isSpectating = true
        defer { isSpectating = false }
        let result = await GameActionClient.call(roomId: room.roomId.uuidString, action: "spectateRoom")
        if let error = result["error"] as? String {
            message = (error, true)
        } else {
            spectatingRoomId = room.roomId
        }
    }

    func load() async {
        guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
        currentUserId = userId
        do {
            let fetched: [FriendRow] = try await SupabaseService.client
                .from("friends")
                .select("id, requester_id, addressee_id, status")
                .or("requester_id.eq.\(userId),addressee_id.eq.\(userId)")
                .execute()
                .value
            rows = fetched
            isLoaded = true

            let otherIds = Set(fetched.map { $0.requesterId == userId ? $0.addresseeId : $0.requesterId })
            guard !otherIds.isEmpty else { return }
            let profiles: [Profile] = try await SupabaseService.client
                .from("profiles")
                .select("id, username")
                .in("id", values: Array(otherIds))
                .execute()
                .value
            for profile in profiles { usernames[profile.id] = profile.username }
        } catch {
            isLoaded = true
        }
    }

    /// Mirrors sendRequest() in App.tsx: routed through the edge function
    /// (sendFriendRequest in index.ts), not a direct client insert, because
    /// every outcome - username doesn't exist, already a friend, or the
    /// caller's own name - has to return the exact same generic response.
    /// A direct insert's success/failure would otherwise let anyone
    /// enumerate real usernames.
    func sendRequest() async {
        let username = usernameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        usernameInput = ""
        let result = await GameActionClient.call(roomId: "", action: "sendFriendRequest", extra: ["username": username])
        if let error = result["error"] as? String {
            message = (error, true)
        } else {
            message = ("Anfrage gesendet ✓", false)
            await load()
        }
    }

    func accept(_ row: FriendRow) async {
        busyId = row.id
        defer { busyId = nil }
        do {
            try await SupabaseService.client
                .from("friends")
                .update(["status": "accepted"])
                .eq("id", value: row.id)
                .execute()
            await load()
        } catch {
            message = ("Annehmen fehlgeschlagen", true)
        }
    }

    /// Covers decline (incoming), cancel (outgoing) and unfriend (accepted)
    /// alike - all three are the same delete server-side (002_friends.sql).
    func remove(_ row: FriendRow) async {
        busyId = row.id
        defer { busyId = nil }
        do {
            try await SupabaseService.client
                .from("friends")
                .delete()
                .eq("id", value: row.id)
                .execute()
            await load()
        } catch {
            message = ("Entfernen fehlgeschlagen", true)
        }
    }
}
