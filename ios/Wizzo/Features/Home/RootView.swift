import SwiftUI

/// Tab shell, mirrors TabBar/TabKey in wizard/frontend/src/App.tsx (home,
/// friends, stats, profile). All four tabs are wired to real data now -
/// see docs/IOS.md for what's still missing within each (Freunde: online
/// status, Raum-Einladungen, tap-to-profile).
struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            FriendsView()
                .tabItem { Label("Freunde", systemImage: "person.2.fill") }

            StatsView()
                .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }

            ProfileView()
                .tabItem { Label("Profil", systemImage: "person.crop.circle") }
        }
        .tint(Theme.gold)
    }
}

#Preview {
    RootView().environmentObject(AppState())
}
