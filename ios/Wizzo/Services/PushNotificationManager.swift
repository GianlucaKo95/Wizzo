import Foundation
import UIKit
import UserNotifications
import Supabase

/// Mirrors subscribeToPush()/unsubscribeFromPush() in App.tsx, with native
/// APNs in place of Web Push: "enabled" means a row for this device exists
/// in `apns_device_tokens` (023_apns_device_tokens.sql), checked against the
/// server rather than just local permission state - same reasoning as the
/// web reading `pushManager.getSubscription()` instead of `Notification.
/// permission` alone. Deliberately opt-in only, triggered from the Profile
/// tab's toggle - never requests authorization automatically on launch,
/// same as the web never calls `Notification.requestPermission()` until
/// the user taps the toggle.
///
/// `UIApplication.registerForRemoteNotifications()` has no async/await
/// form - its result arrives later via two UIApplicationDelegate callbacks
/// (AppDelegate in WizzoApp.swift), which this bridges into a single
/// awaitable using a checked continuation, the same pattern Apple's own
/// docs use for delegate-callback APIs with no native async equivalent.
@MainActor
final class PushNotificationManager: ObservableObject {
    static let shared = PushNotificationManager()

    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published var message: (text: String, isError: Bool)?

    private var tokenContinuation: CheckedContinuation<String, Error>?

    private init() {}

    func handleDeviceToken(_ token: String) {
        tokenContinuation?.resume(returning: token)
        tokenContinuation = nil
    }

    func handleRegistrationError(_ error: Error) {
        tokenContinuation?.resume(throwing: error)
        tokenContinuation = nil
    }

    func toggle() async {
        if isEnabled {
            await disable()
        } else {
            await enable()
        }
    }

    /// Mirrors reading `pushManager.getSubscription()` on Profile mount.
    func refreshStatus() async {
        guard let userId = try? await SupabaseService.client.auth.session.user.id else {
            isEnabled = false
            return
        }
        let rows: [IdRow] = (try? await SupabaseService.client
            .from("apns_device_tokens")
            .select("id")
            .eq("user_id", value: userId)
            .execute()
            .value) ?? []
        isEnabled = !rows.isEmpty
    }

    private func enable() async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                message = ("Berechtigung verweigert", true)
                return
            }
            let token = try await requestDeviceToken()
            guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
            try await SupabaseService.client
                .from("apns_device_tokens")
                .upsert(NewDeviceToken(userId: userId, deviceToken: token), onConflict: "device_token")
                .execute()
            isEnabled = true
        } catch {
            message = ("Fehlgeschlagen", true)
        }
    }

    /// Mirrors unsubscribeFromPush(): deletes every row for this user rather
    /// than tracking "this device's own token" locally - the web does the
    /// same per-browser-subscription thing, but this device is the only one
    /// a native toggle here could possibly mean anyway.
    private func disable() async {
        isBusy = true
        defer { isBusy = false }
        guard let userId = try? await SupabaseService.client.auth.session.user.id else { return }
        try? await SupabaseService.client
            .from("apns_device_tokens")
            .delete()
            .eq("user_id", value: userId)
            .execute()
        isEnabled = false
    }

    private func requestDeviceToken() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.tokenContinuation = continuation
            UIApplication.shared.registerForRemoteNotifications()
        }
    }
}

private struct NewDeviceToken: Encodable {
    let userId: UUID
    let deviceToken: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case deviceToken = "device_token"
    }
}

private struct IdRow: Codable {
    let id: UUID
}
