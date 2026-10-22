import Foundation
import Supabase

enum AuthMode: Hashable {
    case login
    case register
}

/// Mirrors the exact logic of AuthScreen in wizard/frontend/src/App.tsx:
/// there's no real email, just a username - the account underneath is a
/// synthetic `${slug}@wizard.local` email with a derived default password
/// when the user doesn't set one ("Login funktioniert weiter mit dem Namen
/// allein"). This has to match byte-for-byte or existing accounts created
/// via the web app won't be able to log in from this app, and vice versa.
@MainActor
final class AuthViewModel: ObservableObject {
    @Published var mode: AuthMode = .login
    @Published var username = ""
    @Published var password = ""
    @Published var errorMessage: String?
    @Published var isLoading = false

    /// Matches the web app's `name.toLowerCase().replace(/[^a-z0-9]/g, "")`
    /// exactly, including stripping accented letters entirely (not just
    /// ASCII punctuation) - `isLetter`/`isNumber` would keep "é"/"ü" and
    /// produce a different synthetic email than the web client for the same
    /// name, locking that account out of whichever client computed it
    /// differently.
    private func slug(for name: String) -> String {
        name.lowercased().unicodeScalars
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            .map(String.init)
            .joined()
    }

    func submit(appState: AppState) async {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Bitte gib deinen Namen ein"
            return
        }

        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        let slugValue = slug(for: name)
        let email = "\(slugValue)@wizard.local"
        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePassword = trimmedPassword.isEmpty ? "wiz\(slugValue)2024!" : trimmedPassword

        do {
            switch mode {
            case .login:
                let session = try await SupabaseService.client.auth.signIn(
                    email: email,
                    password: effectivePassword
                )
                appState.setSession(session)

            case .register:
                guard !trimmedPassword.isEmpty else {
                    errorMessage = "Bitte ein Passwort wählen"
                    return
                }
                try await SupabaseService.client.auth.signUp(
                    email: email,
                    password: effectivePassword,
                    data: ["username": .string(name)]
                )
                let session = try await SupabaseService.client.auth.signIn(
                    email: email,
                    password: effectivePassword
                )
                appState.setSession(session)
            }
        } catch {
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let raw = error.localizedDescription
        if mode == .login {
            return "Falscher Name oder Passwort"
        }
        if raw.contains("already registered") || raw.contains("already exists") {
            return "Name bereits vergeben – bitte anmelden"
        }
        return raw
    }
}
