import Foundation

/// Mirrors `room_players_view`, never the raw `room_players` table - that
/// one can carry other players' real hands (docs/DATABASE.md). Only the
/// lobby-relevant columns are selected for now; hand/bid/score etc. join
/// this once the actual game screen exists.
struct RoomPlayer: Codable, Identifiable {
    let id: UUID
    let roomId: UUID
    let userId: UUID?
    let playerIndex: Int
    let isAi: Bool
    let aiName: String?
    let connected: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case userId = "user_id"
        case playerIndex = "player_index"
        case isAi = "is_ai"
        case aiName = "ai_name"
        case connected
    }
}
