import SwiftUI

struct FriendsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = FriendsViewModel()
    @State private var pendingRemoval: FriendRow?
    @State private var viewingFriend: (id: UUID, name: String)?

    var body: some View {
        Group {
            if let roomId = viewModel.spectatingRoomId {
                SpectatorView(roomId: roomId) {
                    viewModel.spectatingRoomId = nil
                }
            } else if let friend = viewingFriend {
                FriendProfileView(friendId: friend.id, friendName: friend.name) {
                    viewingFriend = nil
                }
            } else {
                friendsContent
            }
        }
        .task {
            await viewModel.load()
            viewModel.startWatchingActiveRooms()
        }
        .onDisappear { viewModel.stopWatchingActiveRooms() }
    }

    private var friendsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                addFriendSection
                if !viewModel.incoming.isEmpty {
                    incomingSection
                }
                friendsSection
                if !viewModel.outgoing.isEmpty {
                    outgoingSection
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
        .confirmationDialog(
            pendingRemoval.map { "\(viewModel.name(for: viewModel.otherUserId($0))) wirklich entfernen?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Entfernen", role: .destructive) {
                if let row = pendingRemoval {
                    Task { await viewModel.remove(row) }
                }
                pendingRemoval = nil
            }
            Button("Abbrechen", role: .cancel) { pendingRemoval = nil }
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("FREUNDE")
                .font(.system(size: 22, weight: .heavy))
                .foregroundColor(Theme.ivory)
            Spacer()
            Text("\(viewModel.accepted.count) Freunde")
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.ivoryDim)
        }
        .padding(.top, 60)
        .padding(.bottom, 20)
    }

    private var addFriendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Username eingeben", text: $viewModel.usernameInput)
                    .flatFieldStyle()
                    .autocorrectionDisabled()
                    .onSubmit { Task { await viewModel.sendRequest() } }
                Button {
                    Task { await viewModel.sendRequest() }
                } label: {
                    Text(viewModel.isSending ? "…" : "SENDEN")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.bgDark)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Theme.gold)
                        .cornerRadius(Theme.Radius.sm)
                }
                .disabled(viewModel.isSending || viewModel.usernameInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let message = viewModel.message {
                Text(message.text)
                    .font(.caption)
                    .foregroundColor(message.isError ? Theme.error : Theme.success)
            }
        }
        .padding(.bottom, 24)
    }

    private var incomingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OFFENE ANFRAGEN · \(viewModel.incoming.count)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
            ForEach(viewModel.incoming) { row in
                friendRow(row) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await viewModel.accept(row) }
                        } label: {
                            Text("ANNEHMEN")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(Theme.bgDark)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Theme.gold)
                                .cornerRadius(Theme.Radius.sm)
                        }
                        .disabled(viewModel.busyId == row.id)
                        Button {
                            pendingRemoval = row
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundColor(Theme.ivoryDim)
                        }
                        .disabled(viewModel.busyId == row.id)
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MEINE FREUNDE")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
            if !viewModel.isLoaded {
                ProgressView().tint(Theme.gold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            } else if viewModel.accepted.isEmpty {
                Text("Noch keine Freunde – oben nach Usernamen suchen")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                    .padding(.vertical, 10)
            } else {
                ForEach(viewModel.accepted) { row in
                    let otherId = viewModel.otherUserId(row)
                    let activeRoom = viewModel.activeRoom(for: otherId)
                    let subtitle = activeRoom.map { "Spielt gerade · Runde \($0.round ?? 0)" }
                        ?? (appState.onlineUserIds.contains(otherId) ? "Online" : "Offline")
                    friendRow(row, subtitle: subtitle, onTapProfile: {
                        viewingFriend = (otherId, viewModel.name(for: otherId))
                    }) {
                        HStack(spacing: 8) {
                            if let activeRoom {
                                Button {
                                    Task { await viewModel.spectate(activeRoom) }
                                } label: {
                                    Text("ZUSCHAUEN")
                                        .font(.caption2.weight(.bold))
                                        .foregroundColor(Theme.gold)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                                .stroke(Theme.gold.opacity(0.4), lineWidth: 1)
                                        )
                                }
                                .disabled(viewModel.isSpectating)
                            }
                            Button {
                                pendingRemoval = row
                            } label: {
                                Image(systemName: "xmark")
                                    .foregroundColor(Theme.ivoryDim)
                            }
                            .disabled(viewModel.busyId == row.id)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 24)
    }

    private var outgoingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AUSSTEHEND")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
            ForEach(viewModel.outgoing) { row in
                friendRow(row) {
                    Button {
                        Task { await viewModel.remove(row) }
                    } label: {
                        Text("Zurückziehen")
                            .font(.caption2.weight(.semibold))
                            .foregroundColor(Theme.ivoryDim)
                    }
                    .disabled(viewModel.busyId == row.id)
                }
            }
        }
        .padding(.bottom, 10)
    }

    private func friendRow<Trailing: View>(
        _ row: FriendRow,
        subtitle: String? = nil,
        onTapProfile: (() -> Void)? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let otherId = viewModel.otherUserId(row)
        return HStack(spacing: 10) {
            Circle()
                .fill(Theme.accent)
                .frame(width: 28, height: 28)
                .overlay(
                    Text(viewModel.name(for: otherId).prefix(1).uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundColor(Theme.goldLight)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.name(for: otherId))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Theme.ivory)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(Theme.ivoryDim)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onTapProfile?() }
            Spacer()
            trailing()
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    FriendsView().environmentObject(AppState())
}
