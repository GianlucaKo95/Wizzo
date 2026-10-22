import SwiftUI
import Supabase

@main
struct WizzoApp: App {
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
