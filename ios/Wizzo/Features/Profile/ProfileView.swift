import SwiftUI

/// First real end-to-end slice: fetches the signed-in user's own `profiles`
/// row (same broad `gs_select`-style read access the web app relies on, see
/// docs/DATABASE.md) and offers a working sign-out. Avatar upload, friend
/// profiles, etc. are later phases - see docs/IOS.md.
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProfileViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            if viewModel.isLoading {
                ProgressView().tint(Theme.gold)
            } else if let profile = viewModel.profile {
                VStack(spacing: 10) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 72, height: 72)
                        .overlay(
                            Text(profile.username.prefix(1).uppercased())
                                .font(.title.weight(.bold))
                                .foregroundColor(Theme.ivory)
                        )
                    Text(profile.username)
                        .font(.title3.weight(.bold))
                        .foregroundColor(Theme.ivory)
                    if let createdAt = profile.createdAt {
                        Text("Dabei seit \(createdAt.formatted(.dateTime.month(.wide).year()))")
                            .font(.caption)
                            .foregroundColor(Theme.ivoryDim)
                    }
                }
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button(role: .destructive) {
                Task { await appState.signOut() }
            } label: {
                Text("ABMELDEN")
                    .font(.headline)
                    .foregroundColor(Theme.error)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDark.ignoresSafeArea())
        .task { await viewModel.load() }
    }
}

#Preview {
    ProfileView().environmentObject(AppState())
}
