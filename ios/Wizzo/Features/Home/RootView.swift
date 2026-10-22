import SwiftUI

/// Tab shell, mirrors TabBar/TabKey in wizard/frontend/src/App.tsx (home,
/// friends, stats, profile). Only Profil is wired to real data so far -
/// see docs/IOS.md for what each tab still needs.
struct RootView: View {
    var body: some View {
        TabView {
            ComingSoonView(
                title: "Home",
                subtitle: "Räume erstellen/beitreten und der Spieltisch selbst kommen in einer der nächsten Phasen."
            )
            .tabItem { Label("Home", systemImage: "house.fill") }

            ComingSoonView(
                title: "Freunde",
                subtitle: "Freundesliste, Einladungen und Zuschauen kommen noch."
            )
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
