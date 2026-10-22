import SwiftUI

/// Mirrors ManualGamePlay in App.tsx: enter Ansage/Stiche round by round
/// for the host's one in-progress Rechenblock game.
struct RechenblockPlayView: View {
    let manualGameId: UUID
    let onFinishedOrDiscarded: () -> Void

    @StateObject private var viewModel: RechenblockPlayViewModel
    @State private var showDiscardConfirm = false
    @State private var showFinishConfirm = false

    init(manualGameId: UUID, onFinishedOrDiscarded: @escaping () -> Void) {
        self.manualGameId = manualGameId
        self.onFinishedOrDiscarded = onFinishedOrDiscarded
        _viewModel = StateObject(wrappedValue: RechenblockPlayViewModel(manualGameId: manualGameId))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView().tint(Theme.gold)
            } else if let game = viewModel.game {
                content(game: game)
            } else {
                Text("Spiel nicht gefunden")
                    .font(.subheadline)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .task {
            viewModel.onFinishedOrDiscarded = onFinishedOrDiscarded
            await viewModel.load()
        }
        .alert("Spiel verwerfen?", isPresented: $showDiscardConfirm) {
            Button("Verwerfen", role: .destructive) { Task { await viewModel.discard() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle bisher erfassten Runden gehen verloren.")
        }
        .alert("Spiel abschließen?", isPresented: $showFinishConfirm) {
            Button("Abschließen", role: .destructive) { Task { await viewModel.finish() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Erst \(viewModel.rounds.count) Runde\(viewModel.rounds.count == 1 ? "" : "n") gespielt - das wird dauerhaft in der Statistik gespeichert.")
        }
    }

    private func content(game: ManualGame) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                gameHeader(game: game)
                ScrollView(.horizontal, showsIndicators: false) {
                    scoreTable(game: game)
                }
                if let editingRound = viewModel.editingRound, let round = viewModel.rounds.first(where: { $0.round == editingRound }) {
                    editPanel(round: round)
                }
                if !viewModel.isDone, viewModel.pendingBids != nil, let goter = viewModel.nextGoter {
                    tricksEntry(goter: goter)
                }
                if !viewModel.isDone, viewModel.pendingBids == nil, let bidder = viewModel.nextBidder {
                    bidEntry(bidder: bidder)
                }
                if !viewModel.isDone, viewModel.pendingBids != nil, viewModel.currentRoundNum > 1, viewModel.gotSum > 0, viewModel.gotSum != viewModel.currentRoundNum {
                    Text("Summe Stiche (\(viewModel.gotSum)) ≠ Runde (\(viewModel.currentRoundNum)) - bei einer Bombe normal.")
                        .font(.caption2)
                        .foregroundColor(Theme.ivoryDim)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 6)
                }
                if !viewModel.isDone, viewModel.pendingBids != nil {
                    wolkeSection
                }
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(Theme.error)
                        .padding(.top, 10)
                }
                actionButtons
            }
        }
    }

    private func gameHeader(game: ManualGame) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(game.edition == "anniversary" ? "30 Jahre" : "Classic") · \(viewModel.players.count) Spieler")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Theme.ivory)
                Spacer()
                Button("Verwerfen") { showDiscardConfirm = true }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.ivoryDim)
            }
            Text("Runde \(min(viewModel.currentRoundNum, game.maxRounds))/\(game.maxRounds)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
        }
        .padding(.bottom, 14)
    }

    private func scoreTable(game: ManualGame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("RUNDE").frame(width: 56, alignment: .leading)
                ForEach(viewModel.players) { p in
                    Text(p.displayName).frame(width: 64, alignment: .trailing).lineLimit(1)
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundColor(Theme.ivoryDim)
            .padding(.bottom, 6)

            ForEach(viewModel.rounds) { round in
                roundRow(round: round)
            }

            if !viewModel.isDone, viewModel.pendingBids == nil {
                biddingRow
            }
            if !viewModel.isDone, viewModel.pendingBids != nil {
                gotsRow
            }
        }
        .padding(12)
        .background(Theme.bgPanel)
        .cornerRadius(Theme.Radius.sm)
    }

    private func roundRow(round: ManualGameRound) -> some View {
        HStack(spacing: 0) {
            Button {
                if viewModel.editingRound == round.round { viewModel.cancelEditRound() } else { viewModel.startEditRound(round) }
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text("R\(round.round)").font(.subheadline.weight(.semibold))
                        Image(systemName: "pencil").font(.system(size: 9))
                    }
                    .foregroundColor(Theme.ivory)
                    Text("\(dealerName(for: round.round)) gibt")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            .frame(width: 56, alignment: .leading)

            ForEach(viewModel.players) { p in
                let entry = round.results.first { $0.playerIndex == p.playerIndex }
                let total = viewModel.runningByRound[round.round]?[p.playerIndex]
                let leader = viewModel.isLeader(atRound: round.round, playerIndex: p.playerIndex)
                VStack(alignment: .trailing, spacing: 1) {
                    if let entry, let total {
                        Text("\(total)")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(leader ? Theme.gold : Theme.goldLight)
                        Text("A:\(entry.bid)").font(.caption2).foregroundColor(Theme.ivoryDim)
                    }
                }
                .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.accent), alignment: .top)
        .background(viewModel.editingRound == round.round ? Theme.accent.opacity(0.3) : Color.clear)
    }

    private var biddingRow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("R\(viewModel.currentRoundNum) ▶").font(.subheadline.weight(.semibold)).foregroundColor(Theme.goldLight)
                Text("\(viewModel.dealer?.displayName ?? "") gibt").font(.system(size: 9)).foregroundColor(Theme.ivoryDim)
            }
            .frame(width: 56, alignment: .leading)
            ForEach(viewModel.players) { p in
                let has = viewModel.bids[p.playerIndex] != nil
                let isNext = viewModel.nextBidder?.playerIndex == p.playerIndex
                Group {
                    if has {
                        Text(viewModel.bids[p.playerIndex] ?? "").foregroundColor(Theme.ivory)
                    } else if isNext {
                        Text("●").foregroundColor(Theme.gold).fontWeight(.bold)
                    } else {
                        Text("…").foregroundColor(Theme.ivoryDim)
                    }
                }
                .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.25))
    }

    private var gotsRow: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("R\(viewModel.currentRoundNum) ▶").font(.subheadline.weight(.semibold)).foregroundColor(Theme.goldLight)
                Text("\(viewModel.dealer?.displayName ?? "") gibt").font(.system(size: 9)).foregroundColor(Theme.ivoryDim)
            }
            .frame(width: 56, alignment: .leading)
            ForEach(viewModel.players) { p in
                let gotEntered = viewModel.gots[p.playerIndex] != nil
                let isNextGoter = viewModel.nextGoter?.playerIndex == p.playerIndex
                Text("\(viewModel.effectiveBid(p.playerIndex)) / \(gotEntered ? viewModel.gots[p.playerIndex] ?? "" : isNextGoter ? "●" : "…")")
                    .font(.caption)
                    .foregroundColor(gotEntered ? Theme.ivory : (isNextGoter ? Theme.gold : Theme.ivoryDim))
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.25))
    }

    private func dealerName(for round: Int) -> String {
        guard !viewModel.players.isEmpty else { return "" }
        let dealerIndex = (round - 1) % viewModel.players.count
        return viewModel.players.first { $0.playerIndex == dealerIndex }?.displayName ?? ""
    }

    private func editPanel(round: ManualGameRound) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Runde \(round.round) korrigieren")
                .font(.subheadline.weight(.bold))
                .foregroundColor(Theme.goldLight)
            ForEach(viewModel.players) { p in
                HStack(spacing: 8) {
                    Text(p.displayName).font(.subheadline).foregroundColor(Theme.ivory).frame(maxWidth: .infinity, alignment: .leading)
                    TextField("Ansage", text: binding(for: p.playerIndex, in: \.editBid))
                        .keyboardType(.numberPad)
                        .flatFieldStyle()
                        .frame(width: 52)
                        .multilineTextAlignment(.center)
                    Text("/").foregroundColor(Theme.ivoryDim)
                    TextField("Stiche", text: binding(for: p.playerIndex, in: \.editGot))
                        .keyboardType(.numberPad)
                        .flatFieldStyle()
                        .frame(width: 52)
                        .multilineTextAlignment(.center)
                }
            }
            if let editErrorMessage = viewModel.editErrorMessage {
                Text(editErrorMessage).font(.caption).foregroundColor(Theme.error)
            }
            HStack(spacing: 8) {
                Button("Abbrechen") { viewModel.cancelEditRound() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundColor(Theme.ivory)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.ivoryDim.opacity(0.4)))
                Button(viewModel.editSaving ? "…" : "Speichern") { Task { await viewModel.saveEditedRound(round) } }
                    .disabled(viewModel.editSaving)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundColor(Theme.bgDark)
                    .background(Theme.gold)
                    .cornerRadius(Theme.Radius.sm)
            }
        }
        .padding(12)
        .background(Theme.bgPanel)
        .cornerRadius(Theme.Radius.sm)
        .padding(.top, 10)
    }

    /// Generic binding into one of the edit-round dictionaries, keyed by
    /// player index - avoids writing the same get/set boilerplate twice for
    /// editBid/editGot.
    private func binding(for playerIndex: Int, in keyPath: ReferenceWritableKeyPath<RechenblockPlayViewModel, [Int: String]>) -> Binding<String> {
        Binding(
            get: { viewModel[keyPath: keyPath][playerIndex] ?? "" },
            set: { viewModel[keyPath: keyPath][playerIndex] = $0 }
        )
    }

    private func tricksEntry(goter: ManualGamePlayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                Text("Wie viele Stiche hat \(goter.displayName) geholt?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.goldLight)
                Spacer()
                Text("Ergebnis · 0–\(viewModel.currentRoundNum)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.ivoryDim)
            }
            if viewModel.players.contains(where: { viewModel.gots[$0.playerIndex] != nil }) {
                Button { viewModel.undoLastGot() } label: {
                    HStack(spacing: 3) { Image(systemName: "arrow.left"); Text("zurück") }
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            numberPicker(count: viewModel.currentRoundNum + 1, disabledValue: nil, disabled: viewModel.saving) { value in
                Task { await viewModel.recordGot(goter.playerIndex, value: value) }
            }
        }
        .padding(.top, 18)
    }

    private func bidEntry(bidder: ManualGamePlayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                Text("Wie viele Stiche sagt \(bidder.displayName) an?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.goldLight)
                Spacer()
                Text("Ansage · 0–\(viewModel.currentRoundNum)")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.ivoryDim)
            }
            if viewModel.biddingOrder.contains(where: { viewModel.bids[$0.playerIndex] != nil }) {
                Button { viewModel.undoLastBid() } label: {
                    HStack(spacing: 3) { Image(systemName: "arrow.left"); Text("zurück") }
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            if let forbidden = viewModel.dealerForbiddenBid {
                Text("⚠ Stichzwang: \(forbidden) ist verboten")
                    .font(.caption2)
                    .foregroundColor(Theme.error)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.error.opacity(0.12))
            }
            numberPicker(count: viewModel.currentRoundNum + 1, disabledValue: viewModel.dealerForbiddenBid, disabled: viewModel.locking) { value in
                Task { await viewModel.recordBid(bidder.playerIndex, value: value) }
            }
        }
        .padding(.top, 18)
    }

    private func numberPicker(count: Int, disabledValue: Int?, disabled: Bool, onTap: @escaping (Int) -> Void) -> some View {
        let columns = [GridItem(.adaptive(minimum: 44), spacing: 6)]
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<count, id: \.self) { value in
                Button { onTap(value) } label: {
                    Text("\(value)")
                        .font(.title3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundColor(Theme.ivory)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.accentLight))
                }
                .disabled(value == disabledValue || disabled)
                .opacity(value == disabledValue ? 0.25 : (disabled ? 0.5 : 1))
            }
        }
    }

    private var wolkeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.wolkePicking {
                Button {
                    viewModel.wolkePicking = true
                } label: {
                    Text("🚂 9¾ – Vorhersage anpassen")
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.accent))
                }
            } else if viewModel.wolkePlayer == nil {
                Text("Wer hat den Stich mit der Wolke gewonnen?")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                HStack(spacing: 6) {
                    ForEach(viewModel.players) { p in
                        Button(p.displayName) { viewModel.wolkePlayer = p.playerIndex }
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundColor(Theme.ivory)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.accentLight))
                    }
                    Button("Abbrechen") { viewModel.wolkePicking = false }
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                }
            } else if let wolkePlayer = viewModel.wolkePlayer {
                let p = viewModel.players.first { $0.playerIndex == wolkePlayer }
                let current = Int(viewModel.effectiveBid(wolkePlayer)) ?? 0
                Text("\(p?.displayName ?? "") — aktuelle Ansage: \(current)")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                HStack(spacing: 8) {
                    Button("−1 → \(max(0, current - 1))") {
                        viewModel.adjustBid(wolkePlayer, delta: -1)
                        viewModel.wolkePicking = false
                        viewModel.wolkePlayer = nil
                    }
                    .disabled(current == 0)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(Theme.ivory)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).stroke(Theme.accentLight))
                    .opacity(current == 0 ? 0.4 : 1)

                    Button("+1 → \(current + 1)") {
                        viewModel.adjustBid(wolkePlayer, delta: 1)
                        viewModel.wolkePicking = false
                        viewModel.wolkePlayer = nil
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(Theme.bgDark)
                    .background(Theme.gold)
                    .cornerRadius(Theme.Radius.sm)
                }
                Button("Anderer Spieler") { viewModel.wolkePlayer = nil }
                    .font(.caption2)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.top, 14)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if !viewModel.isDone, viewModel.pendingBids != nil {
                Button(viewModel.saving ? "…" : "RUNDE ABSCHLIESSEN") { Task { await viewModel.saveRound() } }
                    .disabled(viewModel.saving)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .foregroundColor(Theme.bgDark)
                    .padding()
                    .background(Theme.gold)
                    .cornerRadius(Theme.Radius.md)
            }
            Button(viewModel.finishing ? "…" : "SPIEL BEENDEN") {
                if viewModel.needsFinishConfirmation { showFinishConfirm = true } else { Task { await viewModel.finish() } }
            }
            .disabled(viewModel.finishing || viewModel.rounds.isEmpty)
            .font(viewModel.isDone ? .headline : .subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .foregroundColor(viewModel.isDone ? Theme.bgDark : Theme.ivory)
            .padding(viewModel.isDone ? 16 : 12)
            .background(viewModel.isDone ? Theme.gold : Color.clear)
            .overlay {
                if !viewModel.isDone {
                    RoundedRectangle(cornerRadius: Theme.Radius.md).stroke(Theme.ivoryDim.opacity(0.4))
                }
            }
            .cornerRadius(Theme.Radius.md)
            .opacity((viewModel.finishing || viewModel.rounds.isEmpty) ? 0.4 : 1)
        }
        .padding(.top, 18)
    }
}
