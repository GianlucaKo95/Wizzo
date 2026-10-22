import Foundation
import Supabase

/// Single shared SupabaseClient for the app - mirrors wizard/frontend/src/
/// supabase.ts (one client instance, imported everywhere). URL/key come
/// from Info.plist (populated from Config/Secrets.xcconfig at build time,
/// see ios/Config/Secrets.example.xcconfig), never hardcoded in source.
enum SupabaseService {
    static let client: SupabaseClient = {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !anonKey.isEmpty
        else {
            fatalError(
                "SUPABASE_URL/SUPABASE_ANON_KEY fehlen oder sind leer - Config/Secrets.xcconfig "
                + "aus Secrets.example.xcconfig anlegen und mit echten Werten füllen, siehe docs/IOS.md."
            )
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
    }()
}
