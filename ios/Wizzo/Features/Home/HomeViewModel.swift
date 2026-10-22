import Foundation
import Supabase

/// Mirrors App.tsx's `reconnectRoom` state - a room this user is still a
/// member of (room_players row) that hasn't ended yet. `dismissible` only
/// once every other seat is AI, same reasoning as `dismissible` there: with
/// a real human still seated, leaveRoom refuses mid-game (see index.ts) -
/// there's nothing to protect once everyone else is AI, so the whole room
/// can just be abandoned instead of waiting on the inactivity reaper.
struct ReconnectInfo {
    let roomId: UUID
    let code: String
    let phase: String
    let dismissible: Bool
}

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var username: String?
    @Published var edition: String = "classic"
    @Published var codeInput = ""
    @Published var activeRoomId: UUID?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var reconnectInfo: ReconnectInfo?
    @Published var isDismissingReconnect = false

    func loadUsername() async {
        guard username == nil else { return }
        guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
        let profile: Profile? = try? await SupabaseService.client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        username = profile?.username
    }

    /// Mirrors checkReconnect() in App.tsx exactly: reconnect state lives on
    /// the backend (room_players membership), not in local storage, so it's
    /// authoritative for any tab/device - the server's inactivity reaper
    /// (004_room_cleanup.sql) is what bounds how long a stale membership can
    /// hang around in the meantime.
    func checkReconnect() async {
        guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
        do {
            let joined: [RoomPlayerRoomJoin] = try await SupabaseService.client
                .from("room_players")
                .select("room_id, rooms:room_id(id, code, phase)")
                .eq("user_id", value: userId)
                .order("created_at", ascending: false, referencedTable: "rooms")
                .execute()
                .value
            guard let active = joined.compactMap({ $0.rooms }).first(where: { $0.phase != "gameEnd" }) else {
                reconnectInfo = nil
                return
            }
            // room_players_view, not the raw table: room_players' own RLS
            // ("rp_select_own") restricts every row select to auth.uid() =
            // user_id, so a query against the raw table here would only
            // ever see the caller's own row - silently making `others`
            // always empty and `dismissible` always true, regardless of who
            // else is actually seated. room_players_view (security_invoker
            // off) is the sanctioned way every other screen in this app
            // reads co-player data for exactly this reason.
            let others: [OtherPlayerRow] = try await SupabaseService.client
                .from("room_players_view")
                .select("is_ai, user_id")
                .eq("room_id", value: active.id)
                .execute()
                .value
            let dismissible = !others.contains { $0.userId != userId && !$0.isAi }
            reconnectInfo = ReconnectInfo(roomId: active.id, code: active.code, phase: active.phase, dismissible: dismissible)
        } catch {
            reconnectInfo = nil
        }
    }

    /// Mirrors reconnect() in App.tsx: rejoining is just joinRoom with the
    /// already-known code - the edge function already lets an existing
    /// member back in at any phase (see joinRoom in index.ts).
    func reconnect() async {
        guard let info = reconnectInfo else { return }
        codeInput = info.code
        await joinRoom()
    }

    /// Mirrors dismissReconnect() in App.tsx: only offered when dismissible
    /// (see ReconnectInfo), so leaveRoom is expected to actually delete the
    /// solo-vs-AI room instead of refusing - clears the banner immediately
    /// rather than waiting on a second checkReconnect() round trip.
    func dismissReconnect() async {
        guard let info = reconnectInfo else { return }
        isDismissingReconnect = true
        defer { isDismissingReconnect = false }
        let result = await GameActionClient.call(roomId: info.roomId.uuidString, action: "leaveRoom")
        if result["error"] == nil {
            reconnectInfo = nil
        }
    }

    func createRoom() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let result = await GameActionClient.call(
            roomId: "",
            action: "createRoom",
            extra: ["username": username ?? "Spieler", "edition": edition]
        )
        await handleRoomResult(result, fallbackError: "Raum konnte nicht erstellt werden")
    }

    func joinRoom() async {
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            errorMessage = "Bitte einen Raumcode eingeben"
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let result = await GameActionClient.call(
            roomId: "",
            action: "joinRoom",
            extra: ["username": username ?? "Spieler", "code": code]
        )
        await handleRoomResult(result, fallbackError: "Raum nicht gefunden")
    }

    private func handleRoomResult(_ result: [String: Any], fallbackError: String) async {
        if let roomIdString = result["roomId"] as? String, let roomId = UUID(uuidString: roomIdString) {
            activeRoomId = roomId
        } else {
            errorMessage = (result["error"] as? String) ?? fallbackError
        }
    }
}

/// Mirrors the `room_players:room_id(...)` embedded-select shape in
/// checkReconnect()'s query - PostgREST returns the embedded many-to-one
/// relation (room_players.room_id -> rooms.id) as a single nested object,
/// not an array.
private struct RoomPlayerRoomJoin: Codable {
    let roomId: UUID
    let rooms: JoinedRoom?

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case rooms
    }
}

private struct JoinedRoom: Codable {
    let id: UUID
    let code: String
    let phase: String
}

private struct OtherPlayerRow: Codable {
    let isAi: Bool
    let userId: UUID?

    enum CodingKeys: String, CodingKey {
        case isAi = "is_ai"
        case userId = "user_id"
    }
}
