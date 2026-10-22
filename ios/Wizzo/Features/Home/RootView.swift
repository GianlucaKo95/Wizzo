import SwiftUI

/// Tab shell, mirrors TabBar/TabKey in wizard/frontend/src/App.tsx (home,
/// friends, stats, profile). All four tabs are wired to real data now -
/// see docs/IOS.md for what's still missing within each.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(0)

                FriendsView()
                    .tabItem { Label("Freunde", systemImage: "person.2.fill") }
                    .tag(1)

                StatsView()
                    .tabItem { Label("Statistik", systemImage: "chart.bar.fill") }
                    .tag(2)

                ProfileView()
                    .tabItem { Label("Profil", systemImage: "person.crop.circle") }
                    .tag(3)
            }
            .tint(Theme.gold)

            if let invite = appState.incomingInvite {
                inviteBanner(invite)
            }
        }
    }

    /// Mirrors the fixed-position "lädt dich zu einer Partie ein" banner in
    /// App.tsx - shown over whichever tab is active. Accepting switches to
    /// the Home tab, which picks up `pendingRoomCodeToJoin` and actually
    /// joins (see HomeView) - a small simplification of the web's "roomId
    /// just replaces the whole screen regardless of the active tab"
    /// behavior, since only HomeView owns the concept of an active room
    /// here.
    private func inviteBanner(_ invite: RoomInvite) -> some View {
        VStack(spacing: 10) {
            Text("\(invite.fromUsername) lädt dich zu einer Partie ein")
                .font(.subheadline)
                .foregroundColor(Theme.ivory)
            HStack(spacing: 8) {
                Button {
                    Task {
                        if let code = await appState.respondToInvite(accept: true) {
                            appState.pendingRoomCodeToJoin = code
                            selectedTab = 0
                        }
                    }
                } label: {
                    Text("Beitreten")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .foregroundColor(Theme.bgDark)
                        .padding(.vertical, 9)
                        .background(Theme.gold)
                        .cornerRadius(Theme.Radius.sm)
                }
                Button {
                    Task { _ = await appState.respondToInvite(accept: false) }
                } label: {
                    Text("Ablehnen")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .foregroundColor(Theme.ivory)
                        .padding(.vertical, 9)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .stroke(Theme.ivoryDim.opacity(0.4), lineWidth: 1)
                        )
                }
            }
            .opacity(appState.isRespondingToInvite ? 0.5 : 1)
            .disabled(appState.isRespondingToInvite)
        }
        .padding(16)
        .background(Theme.bgPanel)
        .cornerRadius(Theme.Radius.md)
        .shadow(color: .black.opacity(0.4), radius: 12)
        .padding(.horizontal, 24)
        .padding(.top, 54)
    }
}

#Preview {
    RootView().environmentObject(AppState())
}
