import Foundation
import AVFoundation
import Supabase
import WebRTC

/// Mirrors useVoiceChat in App.tsx: an opt-in P2P WebRTC mesh between a
/// room's players (and spectators - getIceServers already allows both,
/// see index.ts), signaled over a Supabase Realtime Broadcast channel (no
/// separate signaling server) and connected via the existing getIceServers
/// edge action (STUN + the self-hosted TURN add-on's short-lived HMAC
/// credentials). Audio-only - the web app itself is audio-only too, so
/// there's no video track to ever add here.
///
/// Deliberately skips the web's per-peer speaking indicator (Web Audio
/// analyser driving a green/gray dot) - its own comment calls that
/// "cosmetic only, connection works without it", and reproducing it would
/// mean polling WebRTC stats or tapping the audio engine for no behavioral
/// difference. `participantIds` (who's connected) is kept, since the web
/// UI's mic icon on a seat depends on it structurally, not just cosmetically.
///
/// Created once per room visit, owned by whichever view wraps that room's
/// whole session (LobbyView for players - passed down into GameView the
/// same way App.tsx passes `voice` as a prop from LobbyScreen into
/// GameRoom so the connection survives the lobby→game phase switch;
/// SpectatorView owns its own instance since it's never behind LobbyView).
@MainActor
final class VoiceChatManager: NSObject, ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var connecting = false
    @Published private(set) var muted = false
    @Published var errorMessage: String?
    @Published private(set) var participantIds: Set<UUID> = []
    @Published private(set) var mutedPeerIds: Set<UUID> = []

    private let roomId: UUID
    private var currentUserId: UUID?
    private var localAudioTrack: RTCAudioTrack?
    private var peers: [UUID: RTCPeerConnection] = [:]
    private var observers: [UUID: PeerConnectionObserver] = [:]
    private var pendingCandidates: [UUID: [RTCIceCandidate]] = [:]
    private var iceServers: [RTCIceServer] = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
    private var channel: RealtimeChannel?
    private var signalTask: Task<Void, Never>?

    /// One factory for every RTCPeerConnection this manager ever creates,
    /// same "shared factory, per-call connection" split the stasel/WebRTC
    /// demo app uses. RTCInitializeSSL() only needs calling once per process.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    init(roomId: UUID) {
        self.roomId = roomId
    }

    // MARK: - Public controls

    func enableVoice() async {
        guard !enabled, !connecting else { return }
        errorMessage = nil
        connecting = true
        defer { connecting = false }

        guard await Self.requestMicrophonePermission() else {
            errorMessage = "Mikrofon nicht verfügbar"
            return
        }
        guard let userId = try? await SupabaseService.client.auth.session.user.id else {
            errorMessage = "Nicht angemeldet"
            return
        }
        currentUserId = userId
        configureAudioSession()

        let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        localAudioTrack = Self.factory.audioTrack(with: source, trackId: "audio0")

        let iceResult = await GameActionClient.call(roomId: roomId.uuidString, action: "getIceServers")
        iceServers = Self.parseIceServers(iceResult)

        let ch = await SupabaseService.client.channel("voice:\(roomId.uuidString)") { config in
            config.broadcast.receiveOwnBroadcasts = false
        }
        channel = ch
        signalTask = Task { [weak self] in
            for await json in ch.broadcastStream(event: "signal") {
                guard let signal = try? json.decode(as: VoiceSignal.self) else { continue }
                await self?.handleSignal(signal)
            }
        }
        do {
            try await ch.subscribeWithError()
        } catch {
            errorMessage = "Verbindung zum Sprachchat unterbrochen"
            await disableVoice()
            return
        }
        enabled = true
        await send(VoiceSignal(type: "join", from: userId))
    }

    func disableVoice() async {
        if let userId = currentUserId {
            await send(VoiceSignal(type: "leave", from: userId))
        }
        for id in Array(peers.keys) { removePeer(id) }
        pendingCandidates.removeAll()
        localAudioTrack = nil

        signalTask?.cancel()
        signalTask = nil
        if let ch = channel {
            channel = nil
            await ch.unsubscribe()
        }
        participantIds = []
        mutedPeerIds = []
        muted = false
        enabled = false
    }

    func toggleMute() {
        guard let track = localAudioTrack else { return }
        muted.toggle()
        track.isEnabled = !muted
    }

    /// Muting a peer only affects local playback - toggles `isEnabled` on
    /// that ONE peer connection's remote audio track, which only silences
    /// what this device renders for them, same as the web muting one
    /// `<audio>` element while the others keep playing.
    func togglePeerMute(_ otherId: UUID) {
        if mutedPeerIds.contains(otherId) {
            mutedPeerIds.remove(otherId)
        } else {
            mutedPeerIds.insert(otherId)
        }
        let isMuted = mutedPeerIds.contains(otherId)
        if let remoteTrack = peers[otherId]?.transceivers.first(where: { $0.mediaType == .audio })?.receiver.track {
            remoteTrack.isEnabled = !isMuted
        }
    }

    // MARK: - Peer connection lifecycle

    private func getOrCreatePeer(_ otherId: UUID) -> RTCPeerConnection? {
        if let existing = peers[otherId] { return existing }
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        // Unified Plan + addTrack already defaults new transceivers to
        // sendRecv, so (unlike the older constraints-based API) no
        // offerToReceiveAudio constraint is needed here - DtlsSrtpKeyAgreement
        // is the one still required for interop with browser peers.
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": kRTCMediaConstraintsValueTrue])
        let observer = PeerConnectionObserver(manager: self, otherId: otherId)
        guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: observer) else {
            return nil
        }
        if let localAudioTrack {
            pc.add(localAudioTrack, streamIds: ["stream"])
        }
        peers[otherId] = pc
        observers[otherId] = observer
        return pc
    }

    private func removePeer(_ otherId: UUID) {
        peers[otherId]?.close()
        peers.removeValue(forKey: otherId)
        observers.removeValue(forKey: otherId)
        pendingCandidates.removeValue(forKey: otherId)
        participantIds.remove(otherId)
    }

    private func flushPendingCandidates(_ otherId: UUID, _ pc: RTCPeerConnection) async {
        guard let queued = pendingCandidates.removeValue(forKey: otherId), !queued.isEmpty else { return }
        for candidate in queued {
            try? await addIceCandidate(candidate, to: pc)
        }
    }

    private func send(_ signal: VoiceSignal) async {
        guard let channel else { return }
        try? await channel.broadcast(event: "signal", message: signal)
    }

    /// Only the peer with the "smaller" user id initiates the offer for a
    /// given pair - otherwise both sides would create one at once (glare).
    /// Comparing the lowercase string form matches the web's plain `>=`
    /// comparison on its (always-lowercase) ids exactly: hex digit/letter
    /// ordering is preserved under a case change applied consistently to
    /// both sides, so this agrees with a web peer's own decision for the
    /// same pair regardless of Swift's UUID.uuidString being uppercase.
    private func maybeOffer(_ otherId: UUID) async {
        guard let userId = currentUserId else { return }
        guard userId.uuidString.lowercased() < otherId.uuidString.lowercased() else { return }
        guard let pc = getOrCreatePeer(otherId) else { return }
        do {
            let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
            let offer = try await createOffer(on: pc, constraints: constraints)
            try await setLocalDescription(offer, on: pc)
            await send(VoiceSignal(type: "offer", from: userId, to: otherId, sdp: VoiceSDP(type: "offer", sdp: offer.sdp)))
        } catch {
            removePeer(otherId)
        }
    }

    private func handleSignal(_ signal: VoiceSignal) async {
        guard let userId = currentUserId, signal.from != userId else { return }
        switch signal.type {
        case "join":
            // Always answer "here", whether or not we end up offering - a
            // just-joined peer with a smaller id would otherwise never
            // learn about an existing peer with a larger id (who correctly
            // doesn't offer), and neither side would ever initiate.
            await send(VoiceSignal(type: "here", from: userId, to: signal.from))
            await maybeOffer(signal.from)
            return
        case "here":
            guard signal.to == userId else { return }
            await maybeOffer(signal.from)
            return
        case "leave":
            removePeer(signal.from)
            return
        default:
            break
        }
        guard signal.to == userId else { return }
        do {
            switch signal.type {
            case "offer":
                guard let sdp = signal.sdp else { return }
                let pc = getOrCreatePeer(signal.from)
                guard let pc else { return }
                try await setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp.sdp), on: pc)
                await flushPendingCandidates(signal.from, pc)
                let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                let answer = try await createAnswer(on: pc, constraints: constraints)
                try await setLocalDescription(answer, on: pc)
                await send(VoiceSignal(type: "answer", from: userId, to: signal.from, sdp: VoiceSDP(type: "answer", sdp: answer.sdp)))
            case "answer":
                guard let sdp = signal.sdp, let pc = peers[signal.from] else { return }
                try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp.sdp), on: pc)
                await flushPendingCandidates(signal.from, pc)
            case "ice":
                guard let candidatePayload = signal.candidate else { return }
                let candidate = RTCIceCandidate(
                    sdp: candidatePayload.candidate,
                    sdpMLineIndex: candidatePayload.sdpMLineIndex ?? 0,
                    sdpMid: candidatePayload.sdpMid
                )
                if let pc = peers[signal.from], pc.remoteDescription != nil {
                    try? await addIceCandidate(candidate, to: pc)
                } else {
                    pendingCandidates[signal.from, default: []].append(candidate)
                }
            default:
                break
            }
        } catch {
            // Negotiation failed (e.g. a stale/duplicate offer hitting a
            // connection in the wrong signaling state) - drop the pair
            // cleanly instead of leaving a half-negotiated connection that
            // never recovers.
            removePeer(signal.from)
        }
    }

    // MARK: - Delegate callbacks (see PeerConnectionObserver)

    fileprivate func handleLocalCandidate(_ candidate: RTCIceCandidate, for otherId: UUID) {
        guard let userId = currentUserId else { return }
        Task {
            await send(VoiceSignal(
                type: "ice", from: userId, to: otherId,
                candidate: VoiceICECandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int32(candidate.sdpMLineIndex))
            ))
        }
    }

    /// "disconnected" can persist indefinitely without ever escalating to
    /// "failed" on some networks - since there's no ICE-restart/reconnect
    /// logic here to recover it either way, treat it the same as a hard
    /// failure rather than leaving a dead peer marked connected forever
    /// (same reasoning as the web's onconnectionstatechange handler).
    fileprivate func handleConnectionStateChange(_ state: RTCIceConnectionState, for otherId: UUID) {
        switch state {
        case .connected, .completed:
            participantIds.insert(otherId)
        case .failed, .closed, .disconnected:
            removePeer(otherId)
        default:
            break
        }
    }

    // MARK: - Async wrappers over WebRTC's completion-handler API

    private func createOffer(on pc: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            pc.offer(for: constraints) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) } else { continuation.resume(throwing: error ?? VoiceChatError.unknown) }
            }
        }
    }

    private func createAnswer(on pc: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            pc.answer(for: constraints) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) } else { continuation.resume(throwing: error ?? VoiceChatError.unknown) }
            }
        }
    }

    private func setLocalDescription(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func setRemoteDescription(_ sdp: RTCSessionDescription, on pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(sdp) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate, to pc: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pc.add(candidate) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    // MARK: - Setup helpers

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Mirrors configureAudioSession() in the stasel/WebRTC demo, verified
    /// against the exact RTCAudioSession.h shipped in the pinned 155.0.0
    /// xcframework - .playAndRecord + .voiceChat is what makes WebRTC route
    /// audio through the earpiece/speaker correctly and, combined with the
    /// `audio` UIBackgroundMode (project.yml), keeps working while
    /// backgrounded.
    private func configureAudioSession() {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .defaultToSpeaker])
    }

    /// Parses the raw JSON dict GameActionClient hands back for
    /// getIceServers (index.ts) - `urls` is a single string for the STUN
    /// entry but an array for the TURN entry, matching how the web client
    /// passes the same heterogeneous shape straight to RTCPeerConnection.
    private static func parseIceServers(_ result: [String: Any]) -> [RTCIceServer] {
        guard let raw = result["iceServers"] as? [[String: Any]], !raw.isEmpty else {
            return [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        }
        return raw.map { entry in
            let urls: [String]
            if let single = entry["urls"] as? String {
                urls = [single]
            } else if let multiple = entry["urls"] as? [String] {
                urls = multiple
            } else {
                urls = []
            }
            if let username = entry["username"] as? String, let credential = entry["credential"] as? String {
                return RTCIceServer(urlStrings: urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: urls)
        }
    }
}

private enum VoiceChatError: Error {
    case unknown
}

/// One RTCPeerConnectionDelegate per peer (not one shared delegate for the
/// whole mesh) - the delegate protocol's callbacks don't carry which
/// connection's underlying peer they're about, so each peer needs its own
/// observer tagging callbacks with `otherId`. Kept alive by
/// VoiceChatManager.observers, since RTCPeerConnection.delegate is weak.
/// Callbacks can arrive on an arbitrary WebRTC-internal thread, so each one
/// hops onto the main actor before touching the (MainActor-isolated)
/// manager - same pattern as AppDelegate's APNs callbacks in WizzoApp.swift.
private final class PeerConnectionObserver: NSObject, RTCPeerConnectionDelegate {
    weak var manager: VoiceChatManager?
    let otherId: UUID

    init(manager: VoiceChatManager, otherId: UUID) {
        self.manager = manager
        self.otherId = otherId
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak manager, otherId] in
            manager?.handleLocalCandidate(candidate, for: otherId)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak manager, otherId] in
            manager?.handleConnectionStateChange(newState, for: otherId)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
