import Foundation
import UIKit
import SwiftUI
import PhotosUI
import Supabase

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var profile: Profile?
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var isUploadingAvatar = false
    @Published var avatarMessage: (text: String, isError: Bool)?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let userId = try await SupabaseService.client.auth.session.user.id
            let profile: Profile = try await SupabaseService.client
                .from("profiles")
                .select()
                .eq("id", value: userId)
                .single()
                .execute()
                .value
            self.profile = profile
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Mirrors uploadAvatar() in App.tsx: resize/compress to a small JPEG
    /// client-side, upload to the `avatars` Storage bucket at
    /// `<user_id>/avatar.jpg` (upsert, so a re-upload just overwrites the
    /// same file), then point `profiles.avatar_url` at its cache-busted
    /// public URL - the bucket is public and RLS already restricts writes
    /// to that path to its own owner (003_avatars.sql), no edge function
    /// needed.
    func uploadAvatar(_ item: PhotosPickerItem) async {
        guard let userId = profile?.id else { return }
        isUploadingAvatar = true
        avatarMessage = nil
        defer { isUploadingAvatar = false }
        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let uiImage = UIImage(data: data),
                let jpegData = Self.resizedJPEG(from: uiImage)
            else {
                avatarMessage = ("Bitte ein Bild auswählen", true)
                return
            }
            let path = "\(userId.uuidString)/avatar.jpg"
            try await SupabaseService.client.storage.from("avatars")
                .upload(path, data: jpegData, options: FileOptions(contentType: "image/jpeg", upsert: true))
            let publicURL = try SupabaseService.client.storage.from("avatars").getPublicURL(path: path)
            // Cache-bust so the new image shows immediately instead of the
            // previously cached one at the same URL.
            let bustedUrl = "\(publicURL.absoluteString)?t=\(Int(Date().timeIntervalSince1970 * 1000))"
            try await SupabaseService.client
                .from("profiles")
                .update(AvatarUrlUpdate(avatarUrl: bustedUrl))
                .eq("id", value: userId)
                .execute()
            profile?.avatarUrl = bustedUrl
            avatarMessage = ("Profilbild gespeichert ✓", false)
        } catch {
            avatarMessage = ("Upload fehlgeschlagen", true)
        }
    }

    func removeAvatar() async {
        guard let userId = profile?.id else { return }
        isUploadingAvatar = true
        avatarMessage = nil
        defer { isUploadingAvatar = false }
        try? await SupabaseService.client
            .from("profiles")
            .update(AvatarUrlUpdate(avatarUrl: nil))
            .eq("id", value: userId)
            .execute()
        profile?.avatarUrl = nil
    }

    /// Scales down to at most 512pt on the long side and re-encodes as a
    /// JPEG - mirrors processAvatarImage()'s canvas resize in App.tsx, just
    /// via UIGraphicsImageRenderer instead of a <canvas>. Keeps upload size
    /// small regardless of the original photo's resolution.
    private static func resizedJPEG(from image: UIImage, maxDimension: CGFloat = 512) -> Data? {
        let scale = min(1, maxDimension / max(image.size.width, image.size.height))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

/// Swift's auto-synthesized Encodable uses `encodeIfPresent` for Optional
/// properties, which would omit the key entirely instead of writing JSON
/// `null` when clearing the avatar - a manual `encode(to:)` sidesteps that
/// ambiguity (same fix as Phase 13's PendingBidsUpdate).
private struct AvatarUrlUpdate: Encodable {
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case avatarUrl = "avatar_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let avatarUrl {
            try container.encode(avatarUrl, forKey: .avatarUrl)
        } else {
            try container.encodeNil(forKey: .avatarUrl)
        }
    }
}
