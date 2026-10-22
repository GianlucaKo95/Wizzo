import Foundation

/// Mirrors the `profiles` table (see supabase/migrations/000_full_reset.sql
/// and docs/DATABASE.md). `createdAt` is optional only because Postgrest
/// returns null for it in practice never - Codable still requires either an
/// optional or a guaranteed-present column, and treating it as present but
/// possibly unparseable would crash decoding instead of just leaving a gap.
struct Profile: Codable, Identifiable {
    let id: UUID
    var username: String
    var createdAt: Date?
    var avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case createdAt = "created_at"
        case avatarUrl = "avatar_url"
    }
}
