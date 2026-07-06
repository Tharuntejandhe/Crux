import SwiftUI
import AppKit

/// One-time first-run experience. Explains what Novex does, that everything
/// stays on-device (the core trust message), and walks through the two
/// permissions it may need — Full Disk Access (to read Mail's local store,
/// read-only) and, optionally, the microphone (for voice questions).
///
/// Kept inside the same 320pt widget window so setup feels trivial: no
/// separate installer, no config files. Completion is persisted so this is
/// shown exactly once.
struct OnboardingView: View {
    /// Called when the user taps "Get started" — the host flips to the live
    /// widget and starts the briefing service.
    var onComplete: () -> Void

    @AppStorage("ownerName") private var ownerName = ""
    @AppStorage("ownerEmail") private var ownerEmail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Brand
            HStack(spacing: 9) {
                Image(systemName: "sparkle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text("Welcome to Novex")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
            }

            Text("Your private, on-device inbox assistant. First, who am I working for?")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            // The agent should know its owner.
            HStack(spacing: 8) {
                Image(systemName: "person.fill")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(width: 18)
                TextField("What should I call you?", text: $ownerName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))

            // Your email — so Novex knows when mail is FROM you (a note to self) and
            // never tries to draft a reply back to you.
            HStack(spacing: 8) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(width: 18)
                TextField("Your email address (optional)", text: $ownerEmail)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.95))
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))

            // The trust message — the whole point of Novex.
            point(
                icon: "lock.shield.fill",
                title: "Everything stays on your Mac",
                detail: "No cloud, no account, no API keys. Your mail is summarized on-device and never leaves your computer."
            )
            point(
                icon: "internaldrive.fill",
                title: "Reads Mail, read-only",
                detail: "Novex needs Full Disk Access to read Mail's local store. It never modifies or sends anything."
            )
            point(
                icon: "mic.fill",
                title: "Optional voice",
                detail: "Grant the microphone later if you'd like to ask about your inbox out loud. You can skip it."
            )

            VStack(alignment: .leading, spacing: 8) {
                // AppKit-backed taps — SwiftUI Button crashes on tap in this
                // accessory app (see AppKitTap.swift).
                label("Grant Full Disk Access", filled: false)
                    .appKitTap(openFullDiskAccessSettings)

                label("Get started", filled: true)
                    .appKitTap {
                        OwnerIdentity.learn([ownerEmail])   // teach it "who am I"
                        onComplete()
                    }
            }
            .padding(.top, 2)

            Text("Tip: after enabling Full Disk Access, reopen Novex if it doesn't refresh on its own.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 320)
    }

    private func point(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func label(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(filled ? Color.black.opacity(0.85) : .white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(filled ? Color.white.opacity(0.92) : Color.white.opacity(0.12))
            )
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
