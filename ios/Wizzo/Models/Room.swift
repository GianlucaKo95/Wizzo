import Foundation

/// Lobby-relevant subset of the `rooms` table (docs/DATABASE.md). Clients
/// only ever have column-granted read access to a specific list (see
/// `revoke select on public.rooms` / the `grant select (...)` right after
/// it in 000_full_reset.sql) - notably NOT `host_id`, so `isHost` has to be
/// derived from `room_players.player_index == 0` instead (same as the web
/// app's `effectiveMyIdx === 0`, see LobbyViewModel.isHost). A bare
/// `select()`/`select("*")` against `rooms` fails outright because it would
/// expand to an ungranted column - every query must list columns explicitly
/// (see LobbyViewModel.load()).
struct Room: Codable, Identifiable {
    let id: UUID
    let code: String
    var edition: String
    var phase: String

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case edition
        case phase
    }
}
