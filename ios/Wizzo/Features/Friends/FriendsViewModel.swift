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

/// Core friend-graph management (Phase 9): search/add by username, accept
/// or decline incoming requests, cancel outgoing ones, remove an existing
/// friend. Deliberately doesn't yet cover the web's online-status dot,
/// "spielt gerade"/ZUSCHAUEN button (needs presence tracking + spectator
/// mode, neither built yet) or tap-to-profile (needs the stats feature) -
/// see docs/IOS.md.
@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var rows: [FriendRow] = []
    @Published var usernames: [UUID: String] = [:]
    @Published var isLoaded = false
    @Published var usernameInput = ""
    @Published var isSending = false
    @Published var message: (text: String, isError: Bool)?
    @Published var busyId: UUID?

    private var currentUserId: UUID?

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
