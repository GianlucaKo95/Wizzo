import SwiftUI

/// Mirrors ManualScoreboardScreen in App.tsx: the Rechenblock entry point,
/// switching between the host's one active game (RechenblockPlayView), the
/// setup flow for starting a new one (RechenblockSetupView), and a finished
/// game's read-only history (ManualFinishedGameView). Reachable from a
/// button on HomeView, same placement as the web's "RECHENBLOCK" button on
/// LobbyScreen.
struct RechenblockView: View {
    let onBack: () -> Void
    @StateObject private var viewModel = RechenblockViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if viewModel.isLoading {
                    ProgressView().tint(Theme.gold)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let viewingGame = viewModel.viewingGame {
                    ManualFinishedGameView(game: viewingGame) { viewModel.viewingGame = nil }
                } else if let activeGame = viewModel.activeGame {
                    RechenblockPlayView(manualGameId: activeGame.id) {
                        Task { await viewModel.load() }
                    }
                } else if let userId = viewModel.userId {
                    RechenblockSetupView(
                        userId: userId,
                        pastGames: viewModel.pastGames,
                        onCreated: { Task { await viewModel.load() } },
                        onViewGame: { viewModel.viewingGame = $0 }
                    )
                } else {
                    Text("Nicht angemeldet")
                        .font(.subheadline)
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                Text("← ZURÜCK")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.ivory)
            }
            Spacer()
            Text("RECHENBLOCK")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
        }
        .padding(.top, 56)
        .padding(.bottom, 12)
    }
}

#Preview {
    RechenblockView {}
}
