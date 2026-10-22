import Foundation

/// Subset of the `rooms` table (docs/DATABASE.md). Clients only ever have
/// column-granted read access to a specific list (see
/// `revoke select on public.rooms` / the `grant select (...)` right after
/// it in 000_full_reset.sql) - notably NOT `host_id`, so `isHost` has to be
/// derived from `room_players.player_index == 0` instead (same as the web
/// app's `effectiveMyIdx === 0`, see LobbyViewModel.isHost). A bare
/// `select()`/`select("*")` against `rooms` fails outright because it would
/// expand to an ungranted column - every query must list columns explicitly.
///
/// The game-state fields are optional because the lobby screen only selects
/// `id, code, phase, edition` (LobbyViewModel.load()) - they're populated
/// once GameViewModel selects the fuller column list.
struct Room: Codable, Identifiable {
    let id: UUID
    let code: String
    var edition: String
    var phase: String
    var round: Int?
    var maxRounds: Int?
    var dealer: Int?
    var currentPlayer: Int?
    var trumpCard: Card?
    var trumpSuit: String?
    var currentTrick: [TrickEntry]?
    var lastTrickWinner: Int?
    var lastTrickCards: [TrickEntry]?
    /// 30-Jahre-Sonderkarten-Nachwirkungen (Phase 5) - alle drei existieren
    /// nur während `phase == "trickEnd"` (siehe handleClearTrick in
    /// index.ts, das genau deshalb blockiert, solange einer davon gesetzt
    /// ist). pendingRainbow7 listet ALLE Spieler, die noch eine Karte
    /// weitergeben müssen (Jongleur); pendingWitch/pendingRainbow9 je einen
    /// einzelnen Spielerindex (Hexe-Tausch bzw. Wolke-Vorhersage).
    var pendingRainbow7: [Int]?
    var pendingRainbow9: Int?
    var pendingWitch: Int?
    var witchSwap: WitchSwap?
    /// Always present once selected (`not null default '[]'`) - optional
    /// here only because, like the other game-state fields, the lobby
    /// screen's narrower column list doesn't select it.
    var log: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case code
        case edition
        case phase
        case round
        case maxRounds = "max_rounds"
        case dealer
        case currentPlayer = "current_player"
        case trumpCard = "trump_card"
        case trumpSuit = "trump_suit"
        case currentTrick = "current_trick"
        case lastTrickWinner = "last_trick_winner"
        case lastTrickCards = "last_trick_cards"
        case pendingRainbow7 = "pending_rainbow7"
        case pendingRainbow9 = "pending_rainbow9"
        case pendingWitch = "pending_witch"
        case witchSwap = "witch_swap"
        case log
    }
}
