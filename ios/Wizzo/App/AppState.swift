import Foundation
import Supabase

/// Mirrors the `room_invites` table (002_friends.sql) - a one-shot invite
/// from an accepted friend into their current room's lobby. Accepting or
/// declining both just delete the row (no status column).
struct RoomInvite: Codable, Identifiable, Equatable {
    let id: UUID
    let roomId: UUID
    let roomCode: String
    let fromUserId: UUID
    let fromUsername: String
    let toUserId: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case roomCode = "room_code"
        case fromUserId = "from_user_id"
        case fromUsername = "from_username"
        case toUserId = "to_user_id"
    }
}

/// Top-level session holder - decides whether the app shows AuthView or
/// RootView. Deliberately a simple "check once on launch, update explicitly
/// after sign-in/out" model rather than subscribing to auth state change
/// events, to keep this first native slice's surface area small; revisit if
/// that turns out to be too coarse (e.g. a session expiring mid-use).
///
/// Also owns two session-wide, tab-independent pieces of state (Phase 12),
/// mirroring where App.tsx's LobbyScreen keeps them ("stays mounted for the
/// whole session" - see its own comments): who's currently online
/// (Supabase Realtime Presence) and the most recent pending room invite
/// (shown as a global banner regardless of which tab is active).
///
/// Uses ObservableObject/@Published (not the @Observable macro) so the
/// deployment target can stay at iOS 16 instead of requiring 17.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var isLoadingInitialSession = true
    @Published private(set) var onlineUserIds: Set<UUID> = []
    @Published var incomingInvite: RoomInvite?
    @Published var isRespondingToInvite = false
    /// Set by RootView's accept handler, cleared by HomeView once it has
    /// actually joined - the bridge between "a global invite banner was
    /// accepted" and "HomeView, the only owner of an active room here,
    /// does something about it" (see RootView's doc comment).
    @Published var pendingRoomCodeToJoin: String?

    private var presenceTask: Task<Void, Never>?
    private var presenceChannel: RealtimeChannel?
    private var inviteTask: Task<Void, Never>?

    func loadInitialSession() async {
        session = try? await SupabaseService.client.auth.session
        isLoadingInitialSession = false
        if session != nil {
            startPresenceTracking()
            startWatchingInvites()
        }
    }

    func setSession(_ session: Session) {
        self.session = session
        startPresenceTracking()
        startWatchingInvites()
    }

    func signOut() async {
        stopPresenceTracking()
        stopWatchingInvites()
        try? await SupabaseService.client.auth.signOut()
        session = nil
    }

    /// Mirrors the "online-users" presence channel in App.tsx: every signed-
    /// in client tracks itself under its own user id as the presence key, so
    /// `joins`/`leaves` keys are directly usable as user ids. There's no
    /// single "full snapshot" call in this SDK's AsyncStream-based API (only
    /// the JS client's `.presenceState()` offers that) - the very first
    /// event on a fresh subscription carries everyone already present as
    /// `joins` (standard Phoenix Presence behavior), so starting from an
    /// empty set and just applying every joins/leaves diff from then on
    /// converges to the same result.
    private func startPresenceTracking() {
        guard presenceTask == nil, let userId = session?.user.id else { return }
        presenceTask = Task { [weak self] in
            let ch = await SupabaseService.client.channel("online-users") { config in
                config.presence.key = userId.uuidString
            }
            self?.presenceChannel = ch
            let changes = await ch.presenceChange()
            do {
                try await ch.subscribeWithError()
            } catch {
                return
            }
            try? await ch.track(["at": ISO8601DateFormatter().string(from: Date())])
            for await action in changes {
                guard let self else { return }
                for key in action.joins.keys {
                    if let id = UUID(uuidString: key) { onlineUserIds.insert(id) }
                }
                for key in action.leaves.keys {
                    if let id = UUID(uuidString: key) { onlineUserIds.remove(id) }
                }
            }
        }
    }

    private func stopPresenceTracking() {
        presenceTask?.cancel()
        presenceTask = nil
        if let presenceChannel {
            Task { await presenceChannel.unsubscribe() }
        }
        presenceChannel = nil
        onlineUserIds = []
    }

    /// Simplified from App.tsx's realtime INSERT/DELETE subscription on
    /// room_invites: a plain 10s poll for the most recent pending invite
    /// instead, same cadence/reasoning as FriendsViewModel's
    /// friends_active_rooms poll - a short delay before the banner appears
    /// is an acceptable trade for not needing to decode realtime payloads
    /// for a one-row, infrequently-written table.
    private func startWatchingInvites() {
        guard inviteTask == nil, let userId = session?.user.id else { return }
        inviteTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadLatestInvite(userId: userId)
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func stopWatchingInvites() {
        inviteTask?.cancel()
        inviteTask = nil
        incomingInvite = nil
    }

    private func loadLatestInvite(userId: UUID) async {
        do {
            let invites: [RoomInvite] = try await SupabaseService.client
                .from("room_invites")
                .select("id, room_id, room_code, from_user_id, from_username, to_user_id")
                .eq("to_user_id", value: userId)
                .order("created_at", ascending: false)
                .limit(1)
                .execute()
                .value
            incomingInvite = invites.first
        } catch {
            // best-effort - the banner just stays as it was
        }
    }

    /// Mirrors respondToInvite() in App.tsx: accepting/declining both just
    /// delete the invite row (no status column) - accepting additionally
    /// joins the room via the returned code, which the caller (HomeView)
    /// turns into an actual navigation.
    func respondToInvite(accept: Bool) async -> String? {
        guard let invite = incomingInvite else { return nil }
        isRespondingToInvite = true
        defer { isRespondingToInvite = false }
        try? await SupabaseService.client
            .from("room_invites")
            .delete()
            .eq("id", value: invite.id)
            .execute()
        incomingInvite = nil
        return accept ? invite.roomCode : nil
    }
}
