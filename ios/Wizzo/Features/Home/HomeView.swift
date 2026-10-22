import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        Group {
            if let roomId = viewModel.activeRoomId {
                LobbyView(roomId: roomId) {
                    viewModel.activeRoomId = nil
                    Task { await viewModel.checkReconnect() }
                }
            } else {
                content
            }
        }
        .task {
            await viewModel.loadUsername()
            await viewModel.checkReconnect()
        }
        .onChange(of: appState.pendingRoomCodeToJoin) { code in
            guard let code else { return }
            appState.pendingRoomCodeToJoin = nil
            viewModel.codeInput = code
            Task { await viewModel.joinRoom() }
        }
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

            if let info = viewModel.reconnectInfo {
                reconnectBanner(info)
                    .padding(.bottom, 24)
            }

            Text("EDITION")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            // Re-enabled in Phase 5: all 9 "30 Jahre" special cards (incl.
            // Jongleur/Gleis 9¾/Hexe) are now implemented, so a room created
            // here can no longer get stuck on one of them - see docs/IOS.md.
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

    /// Mirrors the gold "Laufende Partie" banner in App.tsx's LobbyScreen -
    /// shown whenever `checkReconnect()` finds an active room_players
    /// membership. "FORTSETZEN" just re-joins; "VERWERFEN" (only offered
    /// when `dismissible`) abandons a solo-vs-AI game instead of waiting on
    /// the server's inactivity reaper.
    private func reconnectBanner(_ info: ReconnectInfo) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAUFENDE PARTIE")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.bgDark.opacity(0.75))
                    Text(info.code)
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundColor(Theme.bgDark)
                }
                Spacer()
                Button {
                    Task { await viewModel.reconnect() }
                } label: {
                    Text(viewModel.isLoading ? "…" : "FORTSETZEN →")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.goldLight)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Theme.bgDark)
                }
                .disabled(viewModel.isLoading)
            }
            if info.dismissible {
                Button {
                    Task { await viewModel.dismissReconnect() }
                } label: {
                    Text(viewModel.isDismissingReconnect ? "Wird verworfen…" : "VERWERFEN")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.bgDark.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .stroke(Theme.bgDark.opacity(0.4), lineWidth: 1)
                        )
                }
                .disabled(viewModel.isDismissingReconnect)
            }
        }
        .padding(14)
        .background(Theme.gold)
        .cornerRadius(Theme.Radius.md)
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
    HomeView().environmentObject(AppState())
}
