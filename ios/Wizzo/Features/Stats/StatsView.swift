import SwiftUI

struct StatsView: View {
    @StateObject private var viewModel = StatsViewModel()
    @State private var openGameKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                statsGrid
                accuracySection
                pastGamesSection
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
        .task { await viewModel.load() }
    }

    private var header: some View {
        Text("STATISTIK")
            .font(.system(size: 22, weight: .heavy))
            .foregroundColor(Theme.ivory)
            .padding(.top, 60)
            .padding(.bottom, 20)
    }

    private var statsGrid: some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 16) {
            statTile(value: "\(viewModel.stats?.gamesPlayed ?? 0)", label: "Spiele")
            statTile(value: "\(viewModel.stats?.gamesWon ?? 0)", label: "Siege")
            statTile(value: viewModel.stats?.avgScore.map { "\(Int($0.rounded()))" } ?? "0", label: "Ø Punkte")
            statTile(value: viewModel.stats?.avgPlacement.map { String(format: "%.1f", $0) } ?? "–", label: "Ø Platz")
        }
        .padding(.bottom, 24)
    }

    private func statTile(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.system(size: 34, weight: .heavy))
                .foregroundColor(Theme.ivory)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.ivoryDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private var accuracySection: some View {
        let pct = viewModel.stats?.bidAccuracyPct
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline) {
                Text("TREFFERQUOTE DER ANSAGEN")
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.ivoryDim)
                Spacer()
                Text(pct.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.headline.weight(.heavy))
                    .foregroundColor(Theme.gold)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.ivoryDim.opacity(0.15))
                    Rectangle().fill(Theme.gold)
                        .frame(width: geo.size.width * CGFloat((pct ?? 0) / 100))
                }
            }
            .frame(height: 10)
        }
        .padding(.bottom, 24)
    }

    private var pastGamesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LETZTE PARTIEN")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
            if viewModel.pastGames == nil {
                ProgressView().tint(Theme.gold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else if viewModel.pastGames?.isEmpty == true {
                Text("Noch keine Partien gespielt.")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                    .padding(.vertical, 10)
            } else {
                ForEach(viewModel.pastGames ?? []) { game in
                    pastGameRow(game)
                }
            }
        }
    }

    private func pastGameRow(_ game: PastGame) -> some View {
        let isOpen = openGameKey == game.gameKey
        let dateText = game.playedAt.formatted(.dateTime.day().month(.abbreviated))
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                openGameKey = isOpen ? nil : game.gameKey
            } label: {
                HStack(spacing: 10) {
                    Text("\(game.place).")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(game.place == 1 ? Theme.gold : Theme.ivory)
                        .frame(minWidth: 18, alignment: .leading)
                    Text((game.roomDataAvailable ? "\(game.playerCount) Spieler · " : "") + "\(game.totalRounds) Runden · \(dateText)")
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                    Spacer()
                    Text("\(game.score)")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundColor(Theme.ivory)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            .padding(.vertical, 10)

            if isOpen {
                if game.roomDataAvailable {
                    ForEach(game.rows) { row in
                        HStack(spacing: 8) {
                            Text("\(row.placement)")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.ivoryDim)
                                .frame(width: 14, alignment: .leading)
                            Text(row.name)
                                .font(.subheadline)
                                .foregroundColor(Theme.ivory)
                            Spacer()
                            Text("\(row.score)")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(Theme.ivory)
                        }
                        .padding(.vertical, 6)
                        .overlay(Rectangle().fill(Theme.gold.opacity(0.1)).frame(height: 1), alignment: .top)
                    }
                } else {
                    Text("Mitspieler-Daten für diese Partie sind nicht mehr verfügbar.")
                        .font(.caption)
                        .foregroundColor(Theme.ivoryDim)
                        .padding(.vertical, 6)
                        .overlay(Rectangle().fill(Theme.gold.opacity(0.1)).frame(height: 1), alignment: .top)
                }
            }
        }
        .overlay(Rectangle().fill(Theme.gold.opacity(0.1)).frame(height: 1), alignment: .bottom)
    }
}

#Preview {
    StatsView()
}
