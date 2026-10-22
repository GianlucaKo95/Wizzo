import SwiftUI

/// Honest "not built yet" placeholder for tabs without a native screen yet
/// - never fake data, just says so. See docs/IOS.md for the phase roadmap
/// (Home/Friends/Stats are each their own, much larger follow-up).
struct ComingSoonView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundColor(Theme.ivory)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(Theme.ivoryDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDark.ignoresSafeArea())
    }
}

#Preview {
    ComingSoonView(title: "Home", subtitle: "Kommt in einer der nächsten Phasen.")
}
