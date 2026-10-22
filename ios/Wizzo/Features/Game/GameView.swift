import SwiftUI

struct GameView: View {
    @StateObject private var viewModel: GameViewModel
    let onLeave: () -> Void
    @State private var wizardfoolCardId: String?
    @State private var rainbowSuitCardId: String?
    @State private var rainbow7CardId: String?
    @State private var witchTakeCardId: String?
    @State private var showLog = false
    @State private var showScoresheet = false

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
        .overlay {
            if let cardId = rainbowSuitCardId {
                suitChoiceOverlay(cardId: cardId)
            }
        }
    }

    private func resolveWizardfool(choice: String) {
        guard let cardId = wizardfoolCardId else { return }
        wizardfoolCardId = nil
        Task { await viewModel.playWizardfool(cardId: cardId, choice: choice) }
    }

    /// Jongleur/George Weasley (rainbow7) and Gleis 9¾ (rainbow9) both need a
    /// suit choice at the moment they're played (index.ts's playCard,
    /// `isRainbowChoice`) - a dedicated colored-suit overlay rather than
    /// confirmationDialog's plain text buttons, to stay visually consistent
    /// with trumpPicker/werewolfPicker. Tapping the dimmed background cancels
    /// without playing the card (the server itself never requires a choice -
    /// this mirrors the web app always asking before playing either card).
    private func suitChoiceOverlay(cardId: String) -> some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { rainbowSuitCardId = nil }
            VStack(spacing: 14) {
                Text("Welche Farbe?")
                    .font(.headline)
                    .foregroundColor(Theme.gold)
                HStack(spacing: 10) {
                    ForEach(["red", "blue", "green", "yellow"], id: \.self) { suit in
                        Button {
                            rainbowSuitCardId = nil
                            Task { await viewModel.playCard(cardId, suit: suit) }
                        } label: {
                            Text(Theme.suitSymbol(suit))
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .foregroundColor(Theme.bgDark)
                                .background(Theme.suitColor(suit))
                                .clipShape(Circle())
                        }
                    }
                }
            }
            .padding(24)
            .background(Theme.bgPanel)
            .cornerRadius(Theme.Radius.lg)
        }
    }

    private func content(room: Room) -> some View {
        VStack(spacing: 0) {
            header(room: room)
            toolbarRow
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
                // Jongleur/Hexe/Wolke (Phase 5) all run their follow-up
                // during this same phase (see handleClearTrick in index.ts,
                // which refuses to leave trickEnd while one of these is
                // still pending) - whichever applies to ME takes over the
                // normal trick-end banner until I've resolved it.
                if let myIndex = viewModel.myIndex, room.pendingRainbow7?.contains(myIndex) == true {
                    rainbow7PassPicker(room: room)
                } else if let myIndex = viewModel.myIndex, room.pendingWitch == myIndex {
                    witchSwapPicker(room: room)
                } else if let myIndex = viewModel.myIndex, room.pendingRainbow9 == myIndex,
                          let me = viewModel.players.first(where: { $0.playerIndex == myIndex }) {
                    rainbow9AdjustPicker(player: me)
                } else {
                    trickEndBanner(room: room)
                }
            case "witchReveal":
                witchRevealBanner(room: room)
            case "roundEnd":
                roundEndSummary
            case "gameEnd":
                gameEndSummary
            default:
                EmptyView()
            }

            let myIndexForHand = viewModel.myIndex
            let handConsumedByPendingAction =
                (myIndexForHand != nil && room.pendingRainbow7?.contains(myIndexForHand!) == true) ||
                (myIndexForHand != nil && room.pendingWitch == myIndexForHand)
            if (room.phase == "bidding" || room.phase == "playing" || room.phase == "trickEnd") && !handConsumedByPendingAction {
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
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(isPresented: $showScoresheet) { scoresheet(room: room) }
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

    /// Phase 6: Spiel-Log + Spielblatt (Rundenhistorie) - same two icon
    /// buttons as App.tsx's IconHistory/IconClipboardList, as plain SF
    /// Symbols (see AuthView for the existing precedent in this app).
    private var toolbarRow: some View {
        HStack(spacing: 18) {
            Spacer()
            Button {
                showLog = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.ivoryDim)
            }
            Button {
                Task { await viewModel.loadRoundHistory() }
                showScoresheet = true
            } label: {
                Image(systemName: "tablecells")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
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
                    // Indices, not \.self, as the id - log entries can repeat
                    // verbatim (e.g. two players bidding the same number),
                    // and SwiftUI's List needs a stable unique id per row.
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

    /// Mirrors App.tsx's Scoresheet modal: one row per scored round (final
    /// running total + bid per player) plus, while the game isn't over, a
    /// live row for the round in progress (current bids/tricks). Data comes
    /// from `GameViewModel.roundHistory`, fetched on demand when the sheet
    /// opens (see toolbarRow).
    private func scoresheet(room: Room) -> some View {
        let runningByRound = computeRunningTotals()
        let lastRoundNum = viewModel.roundHistory.last?.round
        return NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    scoresheetHeaderRow

                    ForEach(viewModel.roundHistory) { entry in
                        scoresheetRow(
                            label: "R\(entry.round)",
                            labelColor: Theme.ivory,
                            cell: { player in
                                guard let result = entry.results.first(where: { $0.playerIndex == player.playerIndex }),
                                      let total = runningByRound[entry.round]?[player.playerIndex]
                                else { return scoresheetCell(primary: "–", secondary: nil, primaryColor: Theme.ivoryDim) }
                                let isLeaderHere = entry.round == lastRoundNum && isLeader(player)
                                return scoresheetCell(
                                    primary: "\(total)",
                                    secondary: "A:\(result.bid)",
                                    primaryColor: isLeaderHere ? Theme.gold : Theme.ivory
                                )
                            }
                        )
                    }

                    if room.phase != "gameEnd" {
                        scoresheetRow(
                            label: "R\(room.round ?? 0) ▶",
                            labelColor: Theme.goldLight,
                            cell: { player in
                                let bidText = player.bid.map { "A:\($0)" } ?? "–"
                                let tricksText = (room.phase == "playing" || room.phase == "trickEnd")
                                    ? "\(player.tricksWon ?? 0)/\(player.bid.map { String($0) } ?? "?")"
                                    : nil
                                return scoresheetCell(primary: bidText, secondary: tricksText, primaryColor: Theme.goldLight)
                            }
                        )
                    }
                }
                .padding(16)
            }
            .background(Theme.bgDark.ignoresSafeArea())
            .navigationTitle("Spielblatt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { showScoresheet = false }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var scoresheetHeaderRow: some View {
        HStack(spacing: 0) {
            Text("RUNDE")
                .frame(width: 60, alignment: .leading)
            ForEach(viewModel.players) { player in
                Text(player.aiName ?? "?")
                    .frame(width: 64, alignment: .trailing)
                    .lineLimit(1)
            }
        }
        .font(.caption2.weight(.bold))
        .foregroundColor(Theme.ivoryDim)
        .padding(.bottom, 8)
    }

    private func scoresheetRow<Cell: View>(label: String, labelColor: Color, cell: (RoomPlayer) -> Cell) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(labelColor)
                .frame(width: 60, alignment: .leading)
            ForEach(viewModel.players) { player in
                cell(player)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(Theme.gold.opacity(0.1)).frame(height: 1), alignment: .top)
    }

    private func scoresheetCell(primary: String, secondary: String?, primaryColor: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(primary)
                .font(.caption.weight(.bold))
                .foregroundColor(primaryColor)
            if let secondary {
                Text(secondary)
                    .font(.caption2)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
    }

    /// Cumulative `delta` per player per round - mirrors computeRunningTotals
    /// in App.tsx exactly.
    private func computeRunningTotals() -> [Int: [Int: Int]] {
        var acc: [Int: Int] = [:]
        for player in viewModel.players { acc[player.playerIndex] = 0 }
        var out: [Int: [Int: Int]] = [:]
        for entry in viewModel.roundHistory {
            for player in viewModel.players {
                if let result = entry.results.first(where: { $0.playerIndex == player.playerIndex }) {
                    acc[player.playerIndex, default: 0] += result.delta
                }
            }
            out[entry.round] = acc
        }
        return out
    }

    /// Crowns the current leader, but only once scores have actually
    /// diverged from the 0-0 starting tie - mirrors isLeader in App.tsx.
    private func isLeader(_ player: RoomPlayer) -> Bool {
        let maxScore = viewModel.players.map { $0.score ?? 0 }.max() ?? 0
        return maxScore > 0 && (player.score ?? 0) == maxScore
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

    /// Falls back to a one-line status while a pending Jongleur/Hexe/Wolke
    /// follow-up belongs to someone ELSE (mine take over the whole phase
    /// switch instead, see content(room:)) - without this, waiting players
    /// would just see the stale winner banner while nothing visibly happens.
    @ViewBuilder
    private func trickEndBanner(room: Room) -> some View {
        if let pending = room.pendingRainbow7, !pending.isEmpty {
            Text("🎁 Wartet auf Kartenweitergabe…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.vertical, 10)
        } else if room.pendingWitch != nil {
            Text("🧹 Wartet auf Kartentausch…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.vertical, 10)
        } else if room.pendingRainbow9 != nil {
            Text("🚂 Wartet auf Vorhersage-Anpassung…")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.vertical, 10)
        } else {
            Text(room.lastTrickWinner.map { "Stich gewinnt \(nameFor(playerIndex: $0))" } ?? "Stich beendet")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
                .padding(.vertical, 10)
        }
    }

    /// George Weasley/Jongleur (rainbow7): everyone still in
    /// `room.pendingRainbow7` picks one hand card to pass to their left
    /// neighbor (see passCard in GameViewModel). A dedicated picker, not
    /// handArea's tap-to-play - the hand is being used for a different
    /// purpose here, so handArea is hidden while this is showing (see
    /// content(room:)'s handConsumedByPendingAction).
    private func rainbow7PassPicker(room: Room) -> some View {
        VStack(spacing: 10) {
            Text("🎁 George Weasley – Karte weitergeben")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.gold)
            Text("Wähle eine Karte für deinen linken Nachbarn" + (room.pendingRainbow7.map { " · noch \($0.count) ausstehend" } ?? ""))
                .font(.caption)
                .foregroundColor(Theme.ivoryDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.myHand) { card in
                        CardChipView(card: card, isSelected: rainbow7CardId == card.id)
                            .onTapGesture { rainbow7CardId = card.id }
                    }
                }
                .padding(.horizontal, 16)
            }
            Button {
                guard let cardId = rainbow7CardId else { return }
                rainbow7CardId = nil
                Task { await viewModel.passCard(cardId) }
            } label: {
                primaryLabel(viewModel.isSubmitting ? "…" : "KARTE WEITERGEBEN")
            }
            .disabled(rainbow7CardId == nil || viewModel.isSubmitting)
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    /// Bellatrix/Hexe: two steps - pick a card from the just-completed trick
    /// to take (step 1, witchTakeCardId == nil), then pick a hand card to
    /// give away in exchange (step 2). Mirrors App.tsx's specialAction
    /// "witchGive" two-step flow exactly.
    private func witchSwapPicker(room: Room) -> some View {
        VStack(spacing: 10) {
            Text("🧹 Bellatrix – Karte tauschen")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.specialColor("witch"))
            if let takeCardId = witchTakeCardId {
                Text("Welche Karte gibst du dafür ab?")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.myHand) { card in
                            CardChipView(card: card)
                                .onTapGesture {
                                    guard !viewModel.isSubmitting else { return }
                                    witchTakeCardId = nil
                                    Task { await viewModel.playWitchSwap(takeCardId: takeCardId, giveCardId: card.id) }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                Text("Wähle eine Karte aus dem Stich, die du nimmst")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                let trickCards = (room.lastTrickCards ?? []).filter { $0.card.specialType != "witch" && $0.card.id != "witch" }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(trickCards) { entry in
                            VStack(spacing: 4) {
                                CardChipView(card: entry.card)
                                Text(nameFor(playerIndex: entry.playerIndex))
                                    .font(.caption2)
                                    .foregroundColor(Theme.ivoryDim)
                                    .lineLimit(1)
                            }
                            .onTapGesture { witchTakeCardId = entry.card.id }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 10)
    }

    /// Gleis 9¾/Wolke: the trick winner must adjust their own bid by ±1.
    /// Decreasing is blocked if they already have exactly as many tricks as
    /// their current bid (mirrors `canDecrease` in App.tsx) - going below
    /// that would contradict tricks already won this round.
    private func rainbow9AdjustPicker(player: RoomPlayer) -> some View {
        let currentBid = player.bid ?? 0
        let tricksWon = player.tricksWon ?? 0
        let canDecrease = currentBid > 0 && tricksWon != currentBid
        return VStack(spacing: 10) {
            Text("🚂 Gleis 9¾ – Vorhersage anpassen")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.specialColor("rainbow9"))
            Text("Aktuell: \(currentBid)" + (tricksWon == currentBid ? " · du bist im Ziel, nur +1 möglich" : ""))
                .font(.caption)
                .foregroundColor(Theme.ivoryDim)
            HStack(spacing: 10) {
                if canDecrease {
                    Button {
                        Task { await viewModel.rainbow9Adjust(-1) }
                    } label: {
                        Text("−1 → \(currentBid - 1)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .foregroundColor(Theme.bgDark)
                            .padding(.vertical, 10)
                            .background(Theme.gold)
                            .cornerRadius(Theme.Radius.sm)
                    }
                    .disabled(viewModel.isSubmitting)
                }
                Button {
                    Task { await viewModel.rainbow9Adjust(1) }
                } label: {
                    Text("+1 → \(currentBid + 1)")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(Theme.bgDark)
                        .padding(.vertical, 10)
                        .background(Theme.gold)
                        .cornerRadius(Theme.Radius.sm)
                }
                .disabled(viewModel.isSubmitting)
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
    }

    /// `phase == "witchReveal"`: the ~4s window after a Hexe swap where the
    /// swap result is shown before the room moves on (see
    /// maybeScheduleWitchRevealDone in GameViewModel).
    private func witchRevealBanner(room: Room) -> some View {
        VStack(spacing: 8) {
            if let swap = room.witchSwap {
                Text("🧹 \(swap.playerName) hat getauscht")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.specialColor("witch"))
                HStack(spacing: 16) {
                    VStack(spacing: 4) {
                        Text("ABGEGEBEN").font(.caption2).foregroundColor(Theme.ivoryDim)
                        CardChipView(card: swap.gave)
                    }
                    Text("⇄").foregroundColor(Theme.gold)
                    VStack(spacing: 4) {
                        Text("GENOMMEN").font(.caption2).foregroundColor(Theme.ivoryDim)
                        CardChipView(card: swap.took)
                    }
                }
            }
        }
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
                            } else if card.specialType == "rainbow7" || card.specialType == "rainbow9" {
                                rainbowSuitCardId = card.id
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
