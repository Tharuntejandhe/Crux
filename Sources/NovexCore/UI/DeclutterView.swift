import SwiftUI
import AppKit

/// Declutter tab — newsletters/promos piling up in the inbox, with one-tap
/// Unsubscribe (from the List-Unsubscribe header) and a local Mute. On-device.
struct DeclutterView: View {
    @State private var service = DeclutterService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch service.state {
            case .idle, .scanning:
                scanningCard
            case .needsFullDiskAccess:
                statusCard(icon: "lock.shield", title: "Grant Full Disk Access",
                           detail: "Declutter reads which senders are piling up, on-device, never your bank or the network.")
                    .appKitTap { openFDASettings() }
                    .help("Open Full Disk Access settings")
            case .error(let msg):
                statusCard(icon: "exclamationmark.triangle", title: "Couldn't scan", detail: msg)
            case .ready:
                if service.report.isEmpty { allClearCard } else { report }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .task { await service.scanIfNeeded() }
    }

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var report: some View {
        let r = service.report
        VStack(alignment: .leading, spacing: 3) {
            Text("\(r.totalCount) newsletter\(r.totalCount == 1 ? "" : "s") · 30 days")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
            Text("Unsubscribe, or mute to hide a sender across Novex")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.bottom, 2)

        ForEach(service.report.senders) { sender in
            senderRow(sender)
        }
    }

    private func senderRow(_ sender: NewsletterSender) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(sender.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                Text("\(sender.count) in 30 days")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 6)
            if let url = sender.unsubscribeURL {
                actionPill("Unsubscribe", tint: .orange) { NSWorkspace.shared.open(url) }
            }
            actionPill("Mute", tint: .white) { service.mute(sender) }
        }
        .padding(.vertical, 3)
    }

    private func actionPill(_ title: String, tint: Color, _ action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint == .white ? .white.opacity(0.85) : tint.opacity(0.95))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tint == .white ? Color.white.opacity(0.10) : tint.opacity(0.14))
            )
            .appKitTap(action)
    }

    // MARK: - Cards

    private var scanningCard: some View {
        HStack(spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text("Finding the clutter…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Grouping newsletters on-device")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    private var allClearCard: some View {
        HStack(spacing: 11) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundStyle(.green.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your inbox is clean")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("No newsletters piling up in the last 30 days.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func statusCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
