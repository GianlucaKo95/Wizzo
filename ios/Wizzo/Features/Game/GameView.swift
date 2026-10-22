import SwiftUI

struct GameView: View {
    @StateObject private var viewModel: GameViewModel
    let onLeave: () -> Void
    @State private var wizardfoolCardId: String?

    init(roomId: UUID, onLeave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: GameViewModel(roomId: roomId))
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
                ComingSoonView(title: "Spiel nicht gefunden", subtitle: viewModel.errorMessage ?? "")
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        .confirmationDialog(
            "Ron Weasley spielen als…",
            isPresented: Binding(
                get: { wizardfoolCardId != nil },
                set: { if !$0 { wizardfoolCardId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Zauberer") { resolveWizardfool(choice: "wizard") }
            Button("Narr") { resolveWizardfool(choice: "fool") }
            Button("Abbrechen", role: .cancel) { wizardfoolCardId = nil }
        }
    }

    private func resolveWizardfool(choice: String) {
        guard let cardId = wizardfoolCardId else { return }
        wizardfoolCardId = nil
        Task { await viewModel.playWizardfool(cardId: cardId, choice: choice) }
    }

    private func content(room: Room) -> some View {
        VStack(spacing: 0) {
            header(room: room)
            scoreboard
            Spacer(minLength: 8)
            trickArea(room: room)
            Spacer(minLength: 8)

            switch room.phase {
            case "choosingTrump":
                trumpPicker
            case "choosingWerewolf":
                werewolfPicker
            case "bidding":
                biddingArea(room: room)
            case "trickEnd":
                trickEndBanner(room: room)
            case "roundEnd":
                roundEndSummary
            case "gameEnd":
                gameEndSummary
            default:
                EmptyView()
            }

            if room.phase == "bidding" || room.phase == "playing" || room.phase == "trickEnd" {
                handArea
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDark.ignoresSafeArea())
    }

    // MARK: - Header & scoreboard

    private func header(room: Room) -> some View {
        HStack {
            Button {
                Task {
                    await viewModel.leave()
                    onLeave()
                }
            } label: {
                Text("← VERLASSEN")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.ivoryDim)
            }

            Spacer()

            Text("RUNDE \(room.round ?? 0)/\(room.maxRounds ?? 0)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)

            Spacer()

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
        .padding(.horizontal, 16)
        .padding(.top, 54)
        .padding(.bottom, 10)
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(isTurn ? Theme.accent : Color.clear)
                    .cornerRadius(Theme.Radius.sm)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Trick area

    private func trickArea(room: Room) -> some View {
        let entries = room.phase == "trickEnd" ? (room.lastTrickCards ?? []) : (room.currentTrick ?? [])
        return VStack(spacing: 6) {
            if entries.isEmpty {
                Text(room.phase == "bidding" ? "Gebote werden abgegeben…" : " ")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                    .frame(height: 70)
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
        }
    }

    private func nameFor(playerIndex: Int) -> String {
        viewModel.players.first(where: { $0.playerIndex == playerIndex })?.aiName ?? "?"
    }

    // MARK: - Phase-specific areas

    private var trumpPicker: some View {
        VStack(spacing: 10) {
            if viewModel.isMyTurn {
                Text("Trumpf wählen")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ivory)
                HStack(spacing: 10) {
                    ForEach(["red", "blue", "green", "yellow"], id: \.self) { suit in
                        Button {
                            Task { await viewModel.chooseTrump(suit) }
                        } label: {
                            Text(Theme.suitSymbol(suit))
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .foregroundColor(Theme.bgDark)
                                .background(Theme.suitColor(suit))
                                .clipShape(Circle())
                        }
                        .disabled(viewModel.isSubmitting)
                    }
                }
            } else {
                Text("Der Dealer wählt den Trumpf…")
                    .font(.subheadline)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.vertical, 10)
    }

    /// Lupin/Werwolf: whoever was dealt it picks the suit that leads the
    /// entire round (see chooseWerewolf in GameViewModel). Same picker shape
    /// as trumpPicker, different target action and whoever it is isn't
    /// necessarily the dealer.
    private var werewolfPicker: some View {
        VStack(spacing: 10) {
            if viewModel.isMyTurn {
                Text("🐺 Stichfarbe für die ganze Runde wählen")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ivory)
                HStack(spacing: 10) {
                    ForEach(["red", "blue", "green", "yellow"], id: \.self) { suit in
                        Button {
                            Task { await viewModel.chooseWerewolf(suit) }
                        } label: {
                            Text(Theme.suitSymbol(suit))
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .foregroundColor(Theme.bgDark)
                                .background(Theme.suitColor(suit))
                                .clipShape(Circle())
                        }
                        .disabled(viewModel.isSubmitting)
                    }
                }
            } else {
                Text("🐺 Wartet auf die Stichfarben-Wahl…")
                    .font(.subheadline)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.vertical, 10)
    }

    private func biddingArea(room: Room) -> some View {
        VStack(spacing: 10) {
            if viewModel.isMyTurn {
                Text("Wie viele Stiche bietest du?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ivory)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0...(room.round ?? 0), id: \.self) { n in
                            Button {
                                Task { await viewModel.bid(n) }
                            } label: {
                                Text("\(n)")
                                    .font(.headline)
                                    .frame(width: 40, height: 40)
                                    .foregroundColor(Theme.bgDark)
                                    .background(Theme.gold)
                                    .clipShape(Circle())
                            }
                            .disabled(viewModel.isSubmitting)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                Text("Warte auf Gebote…")
                    .font(.subheadline)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.vertical, 10)
    }

    private func trickEndBanner(room: Room) -> some View {
        Text(room.lastTrickWinner.map { "Stich gewinnt \(nameFor(playerIndex: $0))" } ?? "Stich beendet")
            .font(.subheadline.weight(.semibold))
            .foregroundColor(Theme.gold)
            .padding(.vertical, 10)
    }

    private var roundEndSummary: some View {
        VStack(spacing: 10) {
            Text("Runde beendet")
                .font(.headline)
                .foregroundColor(Theme.ivory)
            standingsList
            if viewModel.isHost {
                Button {
                    Task { await viewModel.nextRound() }
                } label: {
                    primaryLabel(viewModel.isSubmitting ? "…" : "NÄCHSTE RUNDE")
                }
                .disabled(viewModel.isSubmitting)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            } else {
                Text("Warte auf den Host…")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.vertical, 10)
    }

    private var gameEndSummary: some View {
        VStack(spacing: 10) {
            Text("Spiel beendet 🏆")
                .font(.headline)
                .foregroundColor(Theme.gold)
            standingsList
            if viewModel.isHost {
                Button {
                    Task { await viewModel.newGame() }
                } label: {
                    primaryLabel(viewModel.isSubmitting ? "…" : "NOCHMAL SPIELEN")
                }
                .disabled(viewModel.isSubmitting)
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 10)
    }

    private var standingsList: some View {
        let sorted = viewModel.players.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        return VStack(spacing: 4) {
            ForEach(Array(sorted.enumerated()), id: \.element.id) { index, player in
                HStack {
                    Text("\(index + 1).")
                        .font(.caption.weight(.bold))
                        .foregroundColor(index == 0 ? Theme.gold : Theme.ivoryDim)
                        .frame(width: 20)
                    Text(player.aiName ?? "?")
                        .font(.subheadline)
                        .foregroundColor(Theme.ivory)
                    Spacer()
                    Text("\(player.score ?? 0)")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Theme.ivory)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Hand

    private var handArea: some View {
        let canPlay = viewModel.room?.phase == "playing" && viewModel.isMyTurn
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.myHand) { card in
                    CardChipView(card: card)
                        .onTapGesture {
                            guard canPlay, !viewModel.isSubmitting else { return }
                            // Ron Weasley/Zauberer-oder-Narr needs a Wizard-or-
                            // Fool choice before it can be sent to the server
                            // (see playSpecial in GameViewModel) - every other
                            // card, special or not, just plays directly.
                            if card.specialType == "wizardfool" {
                                wizardfoolCardId = card.id
                            } else {
                                Task { await viewModel.playCard(card.id) }
                            }
                        }
                        .opacity(canPlay ? 1 : 0.6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func primaryLabel(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .foregroundColor(Theme.bgDark)
            .padding()
            .background(Theme.gold)
            .cornerRadius(Theme.Radius.md)
    }
}

#Preview {
    GameView(roomId: UUID()) {}
}
