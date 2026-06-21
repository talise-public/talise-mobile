import SwiftUI
import AVFoundation
import UserNotifications

/// Step 4/4 — the final onboarding screen. Asks for the two permissions
/// Talise actually needs day one: camera (QR scanning in Send) and
/// notifications (transaction updates).
///
/// UX rule: never block. Denial still calls `onContinue` — the user can
/// always re-grant later from iOS Settings, and we surface that path
/// from Profile.
///
/// Visual: progress bar (step 4/4), title + subtitle on the top-left,
/// a primary CTA ("Enable Permissions") with a camera glyph, and a
/// secondary "Continue" skip below. Background is the shared
/// `OnboardingBackground`.
struct PermissionsScreen: View {
    let onContinue: () -> Void

    @State private var requesting = false

    private func kern(_ size: CGFloat) -> CGFloat { -size * 0.03 }

    var body: some View {
        ZStack(alignment: .top) {
            OnboardingBackground()

            VStack(spacing: 0) {
                OnboardingProgressBar(totalSteps: 4, currentStep: 4)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Enable Permissions")
                        .font(TaliseFont.heading(23.5, weight: .semibold))
                        .kerning(kern(23.5))
                        .foregroundStyle(TaliseColor.fg)

                    Text("Talise needs camera access to scan QR codes and notifications to keep you updated on transactions.")
                        .font(TaliseFont.body(13, weight: .light))
                        .kerning(kern(13))
                        .foregroundStyle(TaliseColor.fgMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer(minLength: 0)

                permissionBullets
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)

                primaryCTA
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)

                secondaryCTA
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var permissionBullets: some View {
        VStack(alignment: .leading, spacing: 18) {
            bullet(icon: "camera.fill", title: "Camera", body: "Scan recipient QR codes when sending money.")
            bullet(icon: "bell.fill",   title: "Notifications", body: "Get notified when a payment lands or fails.")
        }
    }

    private func bullet(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(TaliseColor.fg)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(TaliseFont.body(14, weight: .medium))
                    .kerning(kern(14))
                    .foregroundStyle(TaliseColor.fg)
                Text(body)
                    .font(TaliseFont.body(12, weight: .light))
                    .kerning(kern(12))
                    .foregroundStyle(TaliseColor.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    private var primaryCTA: some View {
        Button(action: requestPermissions) {
            HStack(spacing: 8) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 15, weight: .medium))
                Text("Enable Permissions")
                    .font(TaliseFont.body(15, weight: .medium))
                    .kerning(kern(15))
            }
            .foregroundStyle(TaliseColor.bg)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(TaliseColor.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(requesting)
        .opacity(requesting ? 0.6 : 1)
    }

    private var secondaryCTA: some View {
        Button(action: onContinue) {
            Text("Continue")
                .font(TaliseFont.body(15, weight: .medium))
                .kerning(kern(15))
                .foregroundStyle(TaliseColor.fg)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.white.opacity(0.08))
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Permission requests

    /// Request camera then notifications. Either result advances —
    /// denial is not a blocker.
    private func requestPermissions() {
        guard !requesting else { return }
        requesting = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            let center = UNUserNotificationCenter.current()
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run {
                requesting = false
                UserDefaults.standard.set(true, forKey: "talise.onboarding.permissionsRequested")
                onContinue()
            }
        }
    }
}
