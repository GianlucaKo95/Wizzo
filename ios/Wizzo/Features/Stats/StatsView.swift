import SwiftUI

struct StatsView: View {
    @StateObject private var viewModel = StatsViewModel()
    @State private var openGameKey: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                StatsSummaryView(viewModel: viewModel, openGameKey: $openGameKey)
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
}

#Preview {
    StatsView()
}
