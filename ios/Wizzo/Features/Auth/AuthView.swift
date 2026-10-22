import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = AuthViewModel()
    @FocusState private var usernameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WIZZO")
                .font(.system(size: 52, weight: .heavy, design: .default))
                .foregroundColor(Theme.ivory)

            Rectangle()
                .fill(Theme.gold)
                .frame(width: 72, height: 5)
                .padding(.vertical, 12)

            Text("DAS KARTENSPIEL")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .tracking(1.5)

            Divider().background(Theme.gold.opacity(0.3)).padding(.vertical, 24)

            Picker("Modus", selection: $viewModel.mode) {
                Text("Anmelden").tag(AuthMode.login)
                Text("Registrieren").tag(AuthMode.register)
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 22)

            Text("NAME")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            TextField("Dein Name", text: $viewModel.username)
                .flatFieldStyle()
                .focused($usernameFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.bottom, 18)

            Text("PASSWORT")
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.ivoryDim)
                .padding(.bottom, 6)
            SecureField("Passwort", text: $viewModel.password)
                .flatFieldStyle()
                .padding(.bottom, 26)

            Button {
                Task { await viewModel.submit(appState: appState) }
            } label: {
                HStack {
                    Text(viewModel.isLoading ? "…" : (viewModel.mode == .login ? "ANMELDEN" : "KONTO ANLEGEN"))
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .foregroundColor(Theme.bgDark)
                .padding()
                .background(Theme.gold)
                .cornerRadius(Theme.Radius.md)
            }
            .disabled(viewModel.isLoading)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(Theme.error.opacity(0.13))
                    .cornerRadius(Theme.Radius.sm)
                    .padding(.top, 14)
            }

            Spacer()

            Text("Kein Passwort vergeben? Der Login funktioniert weiter mit dem Namen allein – genau wie in der Web-App.")
                .font(.caption2)
                .foregroundColor(Theme.ivoryDim)
                .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.top, 74)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bgDark.ignoresSafeArea())
        .onAppear { usernameFocused = true }
    }
}

private struct FlatFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Theme.bgPanel)
            .foregroundColor(Theme.ivory)
            .cornerRadius(Theme.Radius.sm)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(Theme.gold.opacity(0.2), lineWidth: 1)
            )
    }
}

private extension View {
    func flatFieldStyle() -> some View {
        modifier(FlatFieldStyle())
    }
}

#Preview {
    AuthView().environmentObject(AppState())
}
