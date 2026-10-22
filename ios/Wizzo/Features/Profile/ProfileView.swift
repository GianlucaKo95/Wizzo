import SwiftUI
import PhotosUI

/// First real end-to-end slice: fetches the signed-in user's own `profiles`
/// row (same broad `gs_select`-style read access the web app relies on, see
/// docs/DATABASE.md), a working sign-out, and avatar upload (Phase 14).
struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = ProfileViewModel()
    @State private var pickedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 40)

            if viewModel.isLoading {
                ProgressView().tint(Theme.gold)
            } else if let profile = viewModel.profile {
                VStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        AvatarView(url: profile.avatarUrl, name: profile.username, size: 72)
                        if viewModel.isUploadingAvatar {
                            ProgressView().tint(Theme.gold)
                        } else {
                            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(Theme.gold)
                                    .background(Circle().fill(Theme.bgDark))
                            }
                        }
                    }
                    .onChange(of: pickedPhoto) { item in
                        guard let item else { return }
                        Task {
                            await viewModel.uploadAvatar(item)
                            pickedPhoto = nil
                        }
                    }
                    Text(profile.username)
                        .font(.title3.weight(.bold))
                        .foregroundColor(Theme.ivory)
                    if let createdAt = profile.createdAt {
                        Text("Dabei seit \(createdAt.formatted(.dateTime.month(.wide).year()))")
                            .font(.caption)
                            .foregroundColor(Theme.ivoryDim)
                    }
                    if profile.avatarUrl != nil {
                        Button("Profilbild entfernen") { Task { await viewModel.removeAvatar() } }
                            .font(.caption)
                            .foregroundColor(Theme.ivoryDim)
                            .disabled(viewModel.isUploadingAvatar)
                    }
                    if let avatarMessage = viewModel.avatarMessage {
                        Text(avatarMessage.text)
                            .font(.caption)
                            .foregroundColor(avatarMessage.isError ? Theme.error : Theme.success)
                    }
                }
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(Theme.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            Button(role: .destructive) {
                Task { await appState.signOut() }
            } label: {
                Text("ABMELDEN")
                    .font(.headline)
                    .foregroundColor(Theme.error)
            }
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bgDark.ignoresSafeArea())
        .task { await viewModel.load() }
    }
}

#Preview {
    ProfileView().environmentObject(AppState())
}
