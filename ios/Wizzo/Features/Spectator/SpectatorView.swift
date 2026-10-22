import SwiftUI

/// Read-only watcher UI - deliberately simpler than GameView (no seat-
/// layout table graphics, no card-playability concerns, no special-card
/// dialogs: nothing here ever acts), matching the web's own choice not to
/// reuse GameRoom for SpectatorRoom (see docs/ARCHITECTURE.md).
struct SpectatorView: View {
    @StateObject private var viewModel: SpectatorViewModel
    let onLeave: () -> Void
    @State private var showLog = false

    init(roomId: UUID, onLeave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: SpectatorViewModel(roomId: roomId))
        self.onLeave = onLeave
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView().tint(Theme.gold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bgDark.ignoresSafeArea())
            } else if let room = viewModel.room {
                content(room: room)
            } else {
                ComingSoonView(title: "Partie nicht gefunden", subtitle: viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private func leave() {
        Task {
            await viewModel.leave()
            onLeave()
        }
    }

    private func content(room: Room) -> some View {
        VStack(spacing: 0) {
            header(room: room)
            if room.phase == "lobby" {
                lobbyContent
                Spacer()
            } else {
                scoreboard
                Spacer(minLength: 8)
                trickArea(room: room)
                Spacer(minLength: 8)
                statusLine(room: room)
                Spacer()
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDark.ignoresSafeArea())
        .sheet(isPresented: $showLog) { logSheet }
    }

    private func header(room: Room) -> some View {
        HStack {
            Button(action: leave) {
                Text("← ZUSCHAUEN BEENDEN")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.ivoryDim)
            }
            Spacer()
            Text("👁 \(room.code) · RUNDE \(room.round ?? 0)/\(room.maxRounds ?? 0)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.gold)
            Spacer()
            Button {
                showLog = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 54)
        .padding(.bottom, 10)
    }

    private var lobbyContent: some View {
        VStack(spacing: 14) {
            Text("👁 Warteraum")
                .font(.headline)
                .foregroundColor(Theme.gold)
                .padding(.top, 30)
            VStack(spacing: 8) {
                ForEach(viewModel.players) { player in
                    HStack(spacing: 10) {
                        Text(player.isAi ? "🤖" : "👤")
                        Text(player.aiName ?? "?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.ivory)
                        if player.playerIndex == 0 {
                            Text("(Host)")
                                .font(.caption)
                                .foregroundColor(Theme.ivoryDim)
                        }
                        Spacer()
                        if !player.isAi {
                            Circle()
                                .fill(player.connected ? Theme.success : Theme.ivoryDim.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            Text("Wartet auf den Host…")
                .font(.caption)
                .foregroundColor(Theme.ivoryDim)
        }
    }

    private var scoreboard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.players) { player in
                    let isTurn = viewModel.room?.currentPlayer == player.playerIndex
                    VStack(spacing: 2) {
                        Text(player.aiName ?? "?")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(isTurn ? Theme.gold : Theme.ivory)
                            .lineLimit(1)
                        Text("\(player.tricksWon ?? 0)/\(player.bid.map { String($0) } ?? "–")")
                            .font(.caption2)
                            .foregroundColor(Theme.ivoryDim)
                        Text("\(player.score ?? 0)")
                            .font(.caption.weight(.bold))
                            .foregroundColor(Theme.ivory)
                        Text("🂠\(player.handCount ?? 0)")
                            .font(.caption2)
                            .foregroundColor(Theme.ivoryDim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isTurn ? Theme.accent : Color.clear)
                    .cornerRadius(Theme.Radius.sm)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func trickArea(room: Room) -> some View {
        let entries = room.phase == "trickEnd" ? (room.lastTrickCards ?? []) : (room.currentTrick ?? [])
        return VStack(spacing: 10) {
            if entries.isEmpty {
                Text(" ").frame(height: 70)
            } else {
                HStack(spacing: 10) {
                    ForEach(entries) { entry in
                        VStack(spacing: 4) {
                            CardChipView(card: entry.card)
                            Text(nameFor(playerIndex: entry.playerIndex))
                                .font(.caption2)
                                .foregroundColor(Theme.ivoryDim)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let trump = room.trumpCard {
                HStack(spacing: 4) {
                    Text("TRUMPF")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.ivoryDim)
                    CardChipView(card: trump)
                        .scaleEffect(0.55)
                        .frame(width: 26, height: 34)
                }
            }
        }
    }

    private func nameFor(playerIndex: Int) -> String {
        viewModel.players.first(where: { $0.playerIndex == playerIndex })?.aiName ?? "?"
    }

    @ViewBuilder
    private func statusLine(room: Room) -> some View {
        switch room.phase {
        case "bidding":
            Text("Gebote werden abgegeben…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
        case "trickEnd":
            Text(room.lastTrickWinner.map { "Stich gewinnt \(nameFor(playerIndex: $0))" } ?? "Stich beendet")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
        case "roundEnd":
            Text("Runde beendet")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
        case "gameEnd":
            Text("Spiel beendet 🏆")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
        case "choosingTrump":
            Text("Trumpf wird gewählt…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
        case "choosingWerewolf":
            Text("🐺 Stichfarbe wird gewählt…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
        default:
            EmptyView()
        }
    }

    private var logSheet: some View {
        NavigationStack {
            Group {
                let entries = viewModel.room?.log ?? []
                if entries.isEmpty {
                    Text("Noch keine Einträge")
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                } else {
                    List(Array(entries.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.caption)
                            .foregroundColor(Theme.ivoryDim)
                            .listRowBackground(Theme.bgDark)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bgDark.ignoresSafeArea())
            .navigationTitle("Spiel-Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { showLog = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    SpectatorView(roomId: UUID()) {}
}
