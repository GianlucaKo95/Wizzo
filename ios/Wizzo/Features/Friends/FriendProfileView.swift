import SwiftUI

/// Mirrors FriendProfileScreen in App.tsx - reuses StatsSummaryView for the
/// identical stats-grid/accuracy/Letzte-Partien layout, just with its own
/// header (avatar initial, name, "Seit MONAT JAHR · N Partien").
struct FriendProfileView: View {
    let friendId: UUID
    let friendName: String
    let onBack: () -> Void

    @StateObject private var viewModel = StatsViewModel()
    @State private var openGameKey: String?
    @State private var memberSince: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backButton
                profileHeader
                StatsSummaryView(viewModel: viewModel, openGameKey: $openGameKey)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
        .task {
            await viewModel.load(userId: friendId)
            let row: CreatedAtRow? = try? await SupabaseService.client
                .from("profiles")
                .select("created_at")
                .eq("id", value: friendId)
                .single()
                .execute()
                .value
            memberSince = row?.createdAt
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            Text("← ZURÜCK")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivory)
        }
        .padding(.top, 60)
        .padding(.bottom, 16)
    }

    private var profileHeader: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 60, height: 60)
                .overlay(
                    Text(friendName.prefix(1).uppercased())
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Theme.goldLight)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(friendName)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(Theme.ivory)
                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
            }
        }
        .padding(.bottom, 20)
    }

    private var subtitleText: String {
        let games = "\(viewModel.stats?.gamesPlayed ?? 0) Partien"
        guard let memberSince else { return games }
        let since = memberSince.formatted(.dateTime.month(.wide).year())
        return "Seit \(since) · \(games)"
    }
}

private struct CreatedAtRow: Codable {
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
    }
}

#Preview {
    FriendProfileView(friendId: UUID(), friendName: "Spieler") {}
}
