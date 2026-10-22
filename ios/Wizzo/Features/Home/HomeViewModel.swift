import Foundation
import Supabase

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var username: String?
    @Published var edition: String = "classic"
    @Published var codeInput = ""
    @Published var activeRoomId: UUID?
    @Published var errorMessage: String?
    @Published var isLoading = false

    func loadUsername() async {
        guard username == nil else { return }
        guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
        let profile: Profile? = try? await SupabaseService.client
            .from("profiles")
            .select()
            .eq("id", value: userId)
            .single()
            .execute()
            .value
        username = profile?.username
    }

    func createRoom() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let result = await GameActionClient.call(
            roomId: "",
            action: "createRoom",
            extra: ["username": username ?? "Spieler", "edition": edition]
        )
        await handleRoomResult(result, fallbackError: "Raum konnte nicht erstellt werden")
    }

    func joinRoom() async {
        let code = codeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            errorMessage = "Bitte einen Raumcode eingeben"
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let result = await GameActionClient.call(
            roomId: "",
            action: "joinRoom",
            extra: ["username": username ?? "Spieler", "code": code]
        )
        await handleRoomResult(result, fallbackError: "Raum nicht gefunden")
    }

    private func handleRoomResult(_ result: [String: Any], fallbackError: String) async {
        if let roomIdString = result["roomId"] as? String, let roomId = UUID(uuidString: roomIdString) {
            activeRoomId = roomId
        } else {
            errorMessage = (result["error"] as? String) ?? fallbackError
        }
    }
}
