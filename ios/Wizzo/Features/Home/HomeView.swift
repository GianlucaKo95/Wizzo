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
            Picker("Edition", selection: $viewModel.edition) {
                Text("Classic").tag("classic")
                Text("30 Jahre").tag("anniversary")
            }
            .pickerStyle(.segmented)
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
