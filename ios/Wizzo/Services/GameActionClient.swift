import Foundation
import Supabase

/// Swift equivalent of wizard/frontend/src/supabase.ts's callGameAction():
/// every game-affecting action (create/join/leave a room, bid, play a card,
/// ...) goes through the same single edge function, never a direct table
/// write - the edge function runs with the service-role key and does its
/// own permission checks explicitly in code (see docs/ARCHITECTURE.md).
///
/// Deliberately a generic JSON-in/JSON-out call, same as the web client,
/// instead of a typed method per action - that keeps this in lockstep with
/// the edge function's own action list without a parallel Swift enum to
/// keep hand-in-sync as actions are added.
enum GameActionClient {
    static func call(roomId: String, action: String, extra: [String: Any] = [:]) async -> [String: Any] {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: "\(urlString)/functions/v1/game-action")
        else {
            return ["error": "Konfigurationsfehler"]
        }

        var body: [String: Any] = ["roomId": roomId, "action": action]
        for (key, value) in extra { body[key] = value }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            let session = try? await SupabaseService.client.auth.session
            if let token = session?.accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            // Network hiccup, expired session, non-JSON error page, etc. -
            // never throw here, mirrors the web client's same fallback
            // message so callers always get *something* to show.
            return ["error": "Verbindung unterbrochen – bitte erneut versuchen"]
        }
    }
}
