import Foundation

/// Mirrors the signaling payload shapes useVoiceChat sends/receives over
/// the `voice:<roomId>` Realtime Broadcast channel in App.tsx - a native
/// and a web client can end up signaling to each other in the same room, so
/// every field name here has to match the JS object literals byte-for-byte
/// (camelCase, not snake_case, since this is never a Postgres row).
struct VoiceSignal: Codable {
    let type: String // "join" | "here" | "offer" | "answer" | "ice" | "leave"
    let from: UUID
    var to: UUID?
    var sdp: VoiceSDP?
    var candidate: VoiceICECandidate?
}

/// Mirrors a JS `RTCSessionDescriptionInit` ({type, sdp}).
struct VoiceSDP: Codable {
    let type: String // "offer" | "answer"
    let sdp: String
}

/// Mirrors a JS `RTCIceCandidateInit` ({candidate, sdpMid, sdpMLineIndex}).
struct VoiceICECandidate: Codable {
    let candidate: String
    let sdpMid: String?
    let sdpMLineIndex: Int32?
}
