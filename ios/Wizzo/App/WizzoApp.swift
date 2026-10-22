import SwiftUI
import Supabase

/// Mirrors how little the web app's push opt-in needs beyond the browser's
/// own Notification/PushManager APIs: this just bridges the two
/// AppDelegate callbacks APNs registration requires (no SwiftUI/async
/// equivalent exists) into `PushNotificationManager`'s continuation - see
/// its own doc comment for why registration itself is never triggered here
/// (deliberately opt-in only, from the Profile tab, same as the web).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Hops onto the main actor explicitly rather than calling the
        // @MainActor-isolated manager directly - safe regardless of how
        // this delegate callback's own isolation is annotated in the SDK.
        Task { @MainActor in
            PushNotificationManager.shared.handleDeviceToken(tokenString)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationManager.shared.handleRegistrationError(error)
        }
    }
}

@main
struct WizzoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if appState.isLoadingInitialSession {
                    ProgressView()
                        .tint(Theme.gold)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.bgDark.ignoresSafeArea())
                } else if appState.session != nil {
                    RootView()
                } else {
                    AuthView()
                }
            }
            .environmentObject(appState)
            .preferredColorScheme(.dark)
            .task { await appState.loadInitialSession() }
        }
    }
}
