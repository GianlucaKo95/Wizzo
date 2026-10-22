import SwiftUI

/// Tab shell, mirrors TabBar/TabKey in wizard/frontend/src/App.tsx (home,
/// friends, stats, profile). Home (create/join a room + lobby), Freunde and
/// Profil are wired to real data - see docs/IOS.md for what each tab still
/// needs (Freunde: online status, Zuschauen, tap-to-profile).
struct RootView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }

            FriendsView()
                .tabItem { Label("Freunde", systemImage: "person.2.fill") }

            ComingSoonView(
                title: "Statistik",
                subtitle: "Spielverlauf und Trefferquote kommen noch."
            )
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
