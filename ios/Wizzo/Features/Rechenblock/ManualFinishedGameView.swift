import SwiftUI

/// Mirrors ManualFinishedGameView in App.tsx: read-only round-by-round
/// history for a finished Rechenblock game. No editing offered here -
/// finishManualGame already recorded the final scores into game_stats, so
/// changing rounds after the fact would desync the two. Deliberately a
/// plain @State fetch (no dedicated view model) - same simplicity as the
/// web's version, since there's nothing here to mutate.
struct ManualFinishedGameView: View {
    let game: ManualGame
    let onBack: () -> Void

    @State private var isLoading = true
    @State private var players: [ManualGamePlayer] = []
    @State private var rounds: [ManualGameRound] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Text("← ZURÜCK")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.ivory)
                }
                Spacer()
                Text("\(game.edition == "anniversary" ? "30 Jahre" : "Classic") · \(game.createdAt.formatted(date: .numeric, time: .omitted))")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.ivoryDim)
            }
            .padding(.bottom, 12)

            if isLoading {
                ProgressView().tint(Theme.gold).frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    table
                }
            }
        }
        .task {
            async let playersFetch: [ManualGamePlayer] = SupabaseService.client
                .from("manual_game_players").select().eq("manual_game_id", value: game.id).order("player_index").execute().value
            async let roundsFetch: [ManualGameRound] = SupabaseService.client
                .from("manual_game_rounds").select().eq("manual_game_id", value: game.id).order("round").execute().value
            players = (try? await playersFetch) ?? []
            rounds = (try? await roundsFetch) ?? []
            isLoading = false
        }
    }

    private var table: some View {
        let runningByRound = computeManualRunningTotals(playerIndexes: players.map(\.playerIndex), rounds: rounds)
        let lastRoundNum = rounds.last?.round

        func isLeader(round: Int, playerIndex: Int) -> Bool {
            guard round == lastRoundNum, let totals = runningByRound[round] else { return false }
            let maxTotal = totals.values.max() ?? 0
            return maxTotal > 0 && totals[playerIndex] == maxTotal
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("RUNDE").frame(width: 56, alignment: .leading)
                ForEach(players) { p in
                    Text(p.displayName).frame(width: 64, alignment: .trailing).lineLimit(1)
                }
            }
            .font(.caption2.weight(.bold))
            .foregroundColor(Theme.ivoryDim)
            .padding(.bottom, 6)

            ForEach(rounds) { round in
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("R\(round.round)").font(.subheadline.weight(.semibold)).foregroundColor(Theme.ivory)
                        let dealerIndex = players.isEmpty ? 0 : (round.round - 1) % players.count
                        Text("\(players.first { $0.playerIndex == dealerIndex }?.displayName ?? "") gibt")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.ivoryDim)
                    }
                    .frame(width: 56, alignment: .leading)

                    ForEach(players) { p in
                        let entry = round.results.first { $0.playerIndex == p.playerIndex }
                        let total = runningByRound[round.round]?[p.playerIndex]
                        let leader = isLeader(round: round.round, playerIndex: p.playerIndex)
                        VStack(alignment: .trailing, spacing: 1) {
                            if let entry, let total {
                                Text("\(total)").font(.subheadline.weight(.bold)).foregroundColor(leader ? Theme.gold : Theme.goldLight)
                                Text("A:\(entry.bid)").font(.caption2).foregroundColor(Theme.ivoryDim)
                            }
                        }
                        .frame(width: 64, alignment: .trailing)
                    }
                }
                .padding(.vertical, 8)
                .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.accent), alignment: .top)
            }
        }
        .padding(12)
        .background(Theme.bgPanel)
        .cornerRadius(Theme.Radius.sm)
    }
}
