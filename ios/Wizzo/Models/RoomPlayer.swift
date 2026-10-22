import Foundation

/// Mirrors `room_players_view`, never the raw `room_players` table - that
/// one can carry other players' real hands (docs/DATABASE.md).
///
/// `visibleHand`/`handCount`/`bid`/`tricksWon`/`score` are optional because
/// the lobby screen only selects the lobby-relevant columns
/// (LobbyViewModel.load()) - they're populated once GameViewModel selects
/// the fuller column list. `visibleHand` is never this player's own hand
/// even then (the view forces it null for your own row) - GameViewModel
/// fetches that separately from the raw `room_players` table, same split
/// as the web app's `loadPlayersSecure()`.
struct RoomPlayer: Codable, Identifiable {
    let id: UUID
    let roomId: UUID
    let userId: UUID?
    let playerIndex: Int
    let isAi: Bool
    let aiName: String?
    let connected: Bool
    var bid: Int?
    var tricksWon: Int?
    var score: Int?
    var handCount: Int?
    var visibleHand: [Card]?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case userId = "user_id"
        case playerIndex = "player_index"
        case isAi = "is_ai"
        case aiName = "ai_name"
        case connected
        case bid
        case tricksWon = "tricks_won"
        case score
        case handCount = "hand_count"
        case visibleHand = "visible_hand"
    }
}
