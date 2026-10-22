import SwiftUI

struct LobbyView: View {
    @StateObject private var viewModel: LobbyViewModel
    let roomId: UUID
    let onLeave: () -> Void

    init(roomId: UUID, onLeave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: LobbyViewModel(roomId: roomId))
        self.roomId = roomId
        self.onLeave = onLeave
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView().tint(Theme.gold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bgDark.ignoresSafeArea())
            } else if let room = viewModel.room, room.phase == "lobby" {
                lobbyContent(room: room)
            } else if viewModel.room != nil {
                // Once the host starts the game, this view's own Realtime
                // watch is no longer needed - GameView runs its own.
                GameView(roomId: roomId, onLeave: onLeave)
            } else {
                ComingSoonView(title: "Raum nicht gefunden", subtitle: viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private func lobbyContent(room: Room) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    Task {
                        await viewModel.leave()
                        onLeave()
                    }
                } label: {
                    Text("← ZURÜCK")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.ivory)
                }
                Spacer()
            }
            .padding(.top, 56)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("RAUMCODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.bgDark.opacity(0.75))
                Text(room.code)
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundColor(Theme.bgDark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
            .padding(.horizontal, 18)
            .background(Theme.gold)

            Text("Am Tisch · \(viewModel.players.count) von \(viewModel.players.count + viewModel.effectiveAiCount)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ForEach(viewModel.players) { player in
                playerRow(player)
            }

            if viewModel.isHost && viewModel.effectiveAiCount > 0 {
                Text("+ \(viewModel.effectiveAiCount) KI wird beim Start ergänzt")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                    .padding(.top, 14)
            }

            Spacer()

            if viewModel.isHost {
                Button {
                    Task { await viewModel.startGame() }
                } label: {
                    Text(viewModel.isSubmitting ? "…" : "SPIEL STARTEN")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(Theme.bgDark)
                        .padding()
                        .background(Theme.gold)
                        .cornerRadius(Theme.Radius.md)
                }
                .disabled(viewModel.isSubmitting || viewModel.players.count + viewModel.effectiveAiCount < 2)
            } else {
                Text("Warte auf den Host…")
                    .font(.subheadline)
                    .foregroundColor(Theme.ivoryDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
    }

    private func playerRow(_ player: RoomPlayer) -> some View {
        let isMe = player.userId == viewModel.currentUserId
        return HStack(spacing: 10) {
            Text("\(player.playerIndex + 1)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .frame(width: 16)

            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text((player.aiName ?? "?").prefix(1).uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Theme.goldLight)
                    )
                if !player.isAi {
                    Circle()
                        .fill(player.connected ? Theme.success : Theme.ivoryDim.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            Text(player.aiName ?? "?")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.ivory)

            Spacer()

            if isMe {
                Text(player.playerIndex == 0 ? "HOST · DU" : "DU")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.bgDark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Theme.gold)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    LobbyView(roomId: UUID()) {}
}
