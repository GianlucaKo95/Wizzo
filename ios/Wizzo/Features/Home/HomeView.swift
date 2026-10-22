import SwiftUI

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        Group {
            if let roomId = viewModel.activeRoomId {
                LobbyView(roomId: roomId) {
                    viewModel.activeRoomId = nil
                }
            } else {
                content
            }
        }
        .task { await viewModel.loadUsername() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WIZZO")
                .font(.system(size: 40, weight: .heavy))
                .foregroundColor(Theme.ivory)
                .padding(.top, 60)

            Text("Raum erstellen oder beitreten")
                .font(.subheadline)
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 6)
                .padding(.bottom, 30)

            Text("EDITION")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            // The "30 Jahre"-Edition's 9 special cards always deal together;
            // 3 of them (Jongleur/Gleis 9¾/Hexe - rainbow7/rainbow9/witch) need
            // multi-step pending-state UI the app doesn't have yet (see
            // docs/IOS.md), so creating that room from here is disabled for
            // now rather than risking a game that gets permanently stuck once
            // one of those three is dealt and played. Joining an existing
            // anniversary room (created from the web app) via code is still
            // possible and carries that same risk - a known, documented gap.
            Text("Classic")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .foregroundColor(Theme.bgDark)
                .padding(.vertical, 8)
                .background(Theme.gold)
                .cornerRadius(Theme.Radius.sm)
            Text("„30 Jahre“-Edition folgt in einer späteren Phase (3 der 9 Sonderkarten sind hier noch nicht umgesetzt)")
                .font(.caption2)
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 6)
                .padding(.bottom, 24)

            Button {
                Task { await viewModel.createRoom() }
            } label: {
                primaryLabel(viewModel.isLoading ? "…" : "RAUM ERSTELLEN")
            }
            .disabled(viewModel.isLoading)
            .padding(.bottom, 30)

            Divider()
                .background(Theme.gold.opacity(0.3))
                .padding(.bottom, 24)

            Text("ODER MIT CODE BEITRETEN")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            TextField("Raumcode", text: $viewModel.codeInput)
                .flatFieldStyle()
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.bottom, 14)

            Button {
                Task { await viewModel.joinRoom() }
            } label: {
                primaryLabel(viewModel.isLoading ? "…" : "BEITRETEN")
            }
            .disabled(viewModel.isLoading)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .padding(.top, 14)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
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
    HomeView()
}
