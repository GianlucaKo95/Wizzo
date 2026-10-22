import Foundation
import Supabase

/// Top-level session holder - decides whether the app shows AuthView or
/// RootView. Deliberately a simple "check once on launch, update explicitly
/// after sign-in/out" model rather than subscribing to auth state change
/// events, to keep this first native slice's surface area small; revisit if
/// that turns out to be too coarse (e.g. a session expiring mid-use).
///
/// Uses ObservableObject/@Published (not the @Observable macro) so the
/// deployment target can stay at iOS 16 instead of requiring 17.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var session: Session?
    @Published private(set) var isLoadingInitialSession = true

    func loadInitialSession() async {
        session = try? await SupabaseService.client.auth.session
        isLoadingInitialSession = false
    }

    func setSession(_ session: Session) {
        self.session = session
    }

    func signOut() async {
        try? await SupabaseService.client.auth.signOut()
        session = nil
    }
}
