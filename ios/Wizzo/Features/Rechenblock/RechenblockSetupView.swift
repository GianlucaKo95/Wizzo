import SwiftUI

/// Mirrors ManualGameSetup in App.tsx: pick edition/player count, fill in
/// each seat (search a registered username or type a guest name), fix the
/// seating order, then create the game.
struct RechenblockSetupView: View {
    let pastGames: [ManualGame]
    let onCreated: () -> Void
    let onViewGame: (ManualGame) -> Void

    @StateObject private var viewModel: RechenblockSetupViewModel

    init(userId: UUID, pastGames: [ManualGame], onCreated: @escaping () -> Void, onViewGame: @escaping (ManualGame) -> Void) {
        self.pastGames = pastGames
        self.onCreated = onCreated
        self.onViewGame = onViewGame
        _viewModel = StateObject(wrappedValue: RechenblockSetupViewModel(userId: userId))
    }

    var body: some View {
        ScrollView {
            if viewModel.stage == .order {
                orderStage
            } else {
                rosterStage
            }
        }
    }

    // MARK: - Roster stage

    private var rosterStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Neues Spiel erfassen")
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.ivory)
            Text("Registrierte Nutzer suchen - dann landet die Partie auch in deren Statistik. Gäste einfach als Namen eintragen.")
                .font(.caption)
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 4)
                .padding(.bottom, 18)

            Text("EDITION")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            Picker("Edition", selection: $viewModel.edition) {
                Text("Classic").tag("classic")
                Text("30 Jahre").tag("anniversary")
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 16)

            Text("SPIELERANZAHL")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            HStack(spacing: 0) {
                ForEach([3, 4, 5, 6], id: \.self) { n in
                    Button("\(n)") { viewModel.changeCount(n) }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundColor(viewModel.count == n ? Theme.bgDark : Theme.ivory)
                        .background(viewModel.count == n ? Theme.gold : Theme.bgPanel)
                }
            }
            .cornerRadius(Theme.Radius.sm)
            Text("\(viewModel.roundsPreview) Runden · Geber wechselt jede Runde")
                .font(.caption2)
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 6)
                .padding(.bottom, 16)

            Text("MITSPIELER · REIHENFOLGE AM TISCH")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 8)
            ForEach($viewModel.slots) { $slot in
                RechenblockPlayerSlotRow(slot: $slot, excludeIds: viewModel.excludeIds)
            }

            if viewModel.openSlotCount > 0 {
                Text("Noch \(viewModel.openSlotCount) Mitspieler offen.")
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.error.opacity(0.12))
                    .padding(.top, 10)
            }

            Button("WEITER → REIHENFOLGE") { viewModel.goToOrder() }
                .disabled(viewModel.openSlotCount > 0)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .foregroundColor(Theme.bgDark)
                .padding()
                .background(Theme.gold)
                .cornerRadius(Theme.Radius.md)
                .opacity(viewModel.openSlotCount > 0 ? 0.4 : 1)
                .padding(.top, 18)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }

            if !pastGames.isEmpty {
                pastGamesSection
            }
        }
    }

    private var pastGamesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FRÜHERE SPIELE")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 26)
                .padding(.bottom, 4)
            ForEach(pastGames.prefix(8)) { game in
                Button { onViewGame(game) } label: {
                    HStack {
                        Text("\(game.edition == "anniversary" ? "30 Jahre" : "Classic") · \(game.maxRounds) Runden")
                        Spacer()
                        Text(game.createdAt.formatted(date: .numeric, time: .omitted))
                    }
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                }
                .padding(.vertical, 10)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.accent), alignment: .top)
            }
        }
    }

    // MARK: - Order stage

    private var orderStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { viewModel.stage = .roster } label: {
                Text("← ZURÜCK")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.ivory)
            }
            .padding(.bottom, 4)
            Text("Reihenfolge festlegen")
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.ivory)
            Text("So wie ihr am Tisch sitzt - bestimmt Geber- und Bietreihenfolge. Zum Sortieren halten und ziehen.")
                .font(.caption)
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 4)
                .padding(.bottom, 16)

            // SwiftUI's own List drag-to-reorder (.onMove, forced into
            // permanent edit mode) replaces the web's custom Pointer-Events
            // drag implementation - a deliberate simplification, see
            // docs/IOS.md.
            List {
                ForEach(Array(viewModel.slots.enumerated()), id: \.element.id) { index, slot in
                    HStack(spacing: 10) {
                        Text("\(index + 1).")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Theme.gold)
                            .frame(width: 20)
                        Text(slot.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Theme.ivory)
                        Spacer()
                        if slot.userId == viewModel.userId, index == 0 {
                            Text("DU · GIBT R1")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(Theme.gold)
                        }
                    }
                    .listRowBackground(Theme.bgPanel)
                }
                .onMove { viewModel.move(from: $0, to: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .frame(height: CGFloat(viewModel.slots.count) * 52 + 8)

            Button(viewModel.isLoading ? "…" : "SPIEL STARTEN") {
                Task { if await viewModel.start() { onCreated() } }
            }
            .disabled(viewModel.isLoading)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .foregroundColor(Theme.bgDark)
            .padding()
            .background(Theme.gold)
            .cornerRadius(Theme.Radius.md)
            .padding(.top, 18)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }
        }
    }
}

/// One roster slot: a linked registered user (search result picked) shows
/// as a plain chip with an unlink button; otherwise a text field doubles as
/// both the guest name and the live username search query - typing either
/// picks a result from the dropdown or just stays a guest name as typed.
private struct RechenblockPlayerSlotRow: View {
    @Binding var slot: RosterSlot
    let excludeIds: [UUID]

    @State private var results: [RechenblockPlayerCandidate] = []

    var body: some View {
        if slot.userId != nil {
            HStack {
                Text(slot.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ivory)
                Spacer()
                Text("VERKNÜPFT")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.success)
                Button {
                    slot.userId = nil
                    slot.name = ""
                    results = []
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            .padding(10)
            .background(Theme.bgPanel)
            .cornerRadius(Theme.Radius.sm)
            .padding(.bottom, 6)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                TextField("Name oder Spieler suchen", text: $slot.name)
                    .flatFieldStyle()
                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { candidate in
                            Button {
                                slot.userId = candidate.id
                                slot.name = candidate.username
                                results = []
                            } label: {
                                Text(candidate.username)
                                    .font(.subheadline)
                                    .foregroundColor(Theme.ivory)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                            }
                        }
                    }
                    .background(Theme.bgPanel)
                    .cornerRadius(Theme.Radius.sm)
                }
            }
            .padding(.bottom, 6)
            .task(id: slot.name) {
                let q = slot.name.trimmingCharacters(in: .whitespaces)
                guard q.count >= 2 else { results = []; return }
                try? await Task.sleep(for: .seconds(0.25))
                guard !Task.isCancelled else { return }
                let rows: [RechenblockPlayerCandidate] = (try? await SupabaseService.client
                    .from("profiles")
                    .select("id, username")
                    .ilike("username", pattern: "%\(q)%")
                    .limit(6)
                    .execute()
                    .value) ?? []
                results = rows.filter { !excludeIds.contains($0.id) }
            }
        }
    }
}

#Preview {
    RechenblockSetupView(userId: UUID(), pastGames: [], onCreated: {}, onViewGame: { _ in })
        .background(Theme.bgDark)
}
