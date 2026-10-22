import SwiftUI

struct LobbyView: View {
    @StateObject private var viewModel: LobbyViewModel
    // Owned here, not in GameView - mirrors App.tsx's useVoiceChat living in
    // LobbyScreen rather than GameRoom, specifically so the connection
    // survives the lobby→game phase switch below instead of unmounting
    // with it (see VoiceChatManager's own doc comment).
    @StateObject private var voice: VoiceChatManager
    let roomId: UUID
    let onLeave: () -> Void

    init(roomId: UUID, onLeave: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: LobbyViewModel(roomId: roomId))
        _voice = StateObject(wrappedValue: VoiceChatManager(roomId: roomId))
        self.roomId = roomId
        self.onLeave = onLeave
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView().tint(Theme.gold)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bgDark.ignoresSafeArea())
            } else if let room = viewModel.room, room.phase == "lobby" {
                lobbyContent(room: room)
            } else if viewModel.room != nil {
                // Once the host starts the game, this view's own Realtime
                // watch is no longer needed - GameView runs its own.
                GameView(roomId: roomId, onLeave: onLeave, voice: voice)
            } else {
                ComingSoonView(title: "Raum nicht gefunden", subtitle: viewModel.errorMessage ?? "")
            }
        }
        .task {
            await viewModel.start()
            await viewModel.loadInviteCandidates()
        }
        .onDisappear {
            viewModel.stop()
            Task { await voice.disableVoice() }
        }
    }

    private func lobbyContent(room: Room) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    Task {
                        await viewModel.leave()
                        onLeave()
                    }
                } label: {
                    Text("← ZURÜCK")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.ivory)
                }
                Spacer()
            }
            .padding(.top, 56)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("RAUMCODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(Theme.bgDark.opacity(0.75))
                Text(room.code)
                    .font(.system(size: 48, weight: .heavy))
                    .foregroundColor(Theme.bgDark)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 20)
            .padding(.horizontal, 18)
            .background(Theme.gold)

            Text("Am Tisch · \(viewModel.players.count) von \(viewModel.players.count + viewModel.effectiveAiCount)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 18)
                .padding(.bottom, 6)

            ForEach(viewModel.players) { player in
                playerRow(player)
            }

            if viewModel.isHost && viewModel.effectiveAiCount > 0 {
                Text("+ \(viewModel.effectiveAiCount) KI wird beim Start ergänzt")
                    .font(.caption)
                    .foregroundColor(Theme.ivoryDim)
                    .padding(.top, 14)
            }

            invitePicker

            voiceSection

            Spacer()

            if viewModel.isHost {
                Button {
                    Task { await viewModel.startGame() }
                } label: {
                    Text(viewModel.isSubmitting ? "…" : "SPIEL STARTEN")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .foregroundColor(Theme.bgDark)
                        .padding()
                        .background(Theme.gold)
                        .cornerRadius(Theme.Radius.md)
                }
                .disabled(viewModel.isSubmitting || viewModel.players.count + viewModel.effectiveAiCount < 2)
            } else {
                Text("Warte auf den Host…")
                    .font(.subheadline)
                    .foregroundColor(Theme.ivoryDim)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
    }

    /// Mirrors the "Freunde einladen" list in GameRoom's Warteraum (App.tsx)
    /// - shown permanently once seated rather than behind a toggle. Only
    /// accepted friends not already a seated player show up; inviting just
    /// writes a `room_invites` row directly (RLS-protected, no edge
    /// function needed, same as the web).
    @ViewBuilder
    private var invitePicker: some View {
        if let candidates = viewModel.inviteCandidates {
            let seatedIds = Set(viewModel.players.compactMap(\.userId))
            let invitable = candidates.filter { !seatedIds.contains($0.id) }
            if !invitable.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FREUNDE EINLADEN")
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.ivoryDim)
                        .padding(.top, 18)
                    ForEach(invitable) { candidate in
                        HStack(spacing: 10) {
                            AvatarView(url: candidate.avatarUrl, name: candidate.username, size: 24)
                            Text(candidate.username)
                                .font(.subheadline)
                                .foregroundColor(Theme.ivory)
                            Spacer()
                            let isInvited = viewModel.invitedIds.contains(candidate.id)
                            Button {
                                Task { await viewModel.inviteFriend(candidate) }
                            } label: {
                                Text(isInvited ? "Eingeladen ✓" : "EINLADEN")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(isInvited ? Theme.ivoryDim : Theme.gold)
                            }
                            .disabled(isInvited || viewModel.inviteSendingId == candidate.id)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    /// Mirrors the big "Sprachchat aktivieren" card in LobbyScreen's
    /// Warteraum (App.tsx) - once enabled, a participant row per connected
    /// peer (name + per-peer mute, no speaking-color indicator, see
    /// VoiceChatManager) plus Live/Stumm and leave controls.
    @ViewBuilder
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if voice.enabled, !voice.participantIds.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(voice.participantIds), id: \.self) { id in
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.caption2)
                                .foregroundColor(Theme.ivoryDim)
                            Text(nameFor(userId: id))
                                .font(.caption)
                                .foregroundColor(Theme.ivoryDim)
                            Spacer()
                            Button {
                                voice.togglePeerMute(id)
                            } label: {
                                Image(systemName: voice.mutedPeerIds.contains(id) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                    .font(.caption2)
                                    .foregroundColor(voice.mutedPeerIds.contains(id) ? Theme.error : Theme.ivoryDim.opacity(0.5))
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                if !voice.enabled {
                    Button {
                        Task { await voice.enableVoice() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                            Text(voice.connecting ? "Verbinde…" : "Sprachchat aktivieren")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundColor(Theme.bgDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Theme.gold)
                        .cornerRadius(Theme.Radius.sm)
                    }
                    .disabled(voice.connecting)
                } else {
                    Button {
                        voice.toggleMute()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: voice.muted ? "mic.slash.fill" : "mic.fill")
                            Text(voice.muted ? "Stumm" : "Live")
                        }
                        .font(.caption.weight(.bold))
                        .foregroundColor(voice.muted ? Theme.ivoryDim : Theme.bgDark)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(voice.muted ? Theme.bgPanel : Theme.gold)
                        .cornerRadius(Theme.Radius.sm)
                    }
                    Button {
                        Task { await voice.disableVoice() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(Theme.ivoryDim)
                            .padding(10)
                            .background(Theme.bgPanel)
                            .cornerRadius(Theme.Radius.sm)
                    }
                }
            }
            if let errorMessage = voice.errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundColor(Theme.error)
            }
        }
        .padding(.top, 18)
    }

    private func nameFor(userId: UUID) -> String {
        viewModel.players.first { $0.userId == userId }?.aiName ?? "?"
    }

    private func playerRow(_ player: RoomPlayer) -> some View {
        let isMe = player.userId == viewModel.currentUserId
        return HStack(spacing: 10) {
            Text("\(player.playerIndex + 1)")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .frame(width: 16)

            ZStack(alignment: .bottomTrailing) {
                AvatarView(
                    url: player.userId.flatMap { viewModel.avatarUrls[$0] },
                    name: player.aiName ?? "?",
                    size: 26
                )
                if !player.isAi {
                    Circle()
                        .fill(player.connected ? Theme.success : Theme.ivoryDim.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }

            Text(player.aiName ?? "?")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.ivory)

            Spacer()

            if isMe {
                Text(player.playerIndex == 0 ? "HOST · DU" : "DU")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(Theme.bgDark)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(Theme.gold)
            }
        }
        .padding(.vertical, 8)
    }
}

#Preview {
    LobbyView(roomId: UUID()) {}
}
