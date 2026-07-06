import SwiftUI
import AppKit

/// Follow-up Radar tab — stalled threads that need attention: emails you haven't
/// replied to, and ones where you're waiting on someone else. Reads the local
/// Mail store (Inbox + Sent) entirely on-device.
struct FollowUpView: View {
    @State private var service = FollowUpService()
    /// Open the Smart Reply composer for a "needs reply" thread.
    let onReply: (MailMessage) -> Void

    /// When set, the "Catch me up" thread digest takes over the tab.
    @State private var caughtUp: FollowUpItem?

    var body: some View {
        if let item = caughtUp {
            ThreadDigestView(item: item,
                             thread: service.thread(for: item),
                             userAddresses: service.myAddresses,
                             onReply: onReply,
                             onClose: { caughtUp = nil })
                .padding(.horizontal, 16)
                .padding(.top, 14)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch service.state {
            case .idle, .scanning:
                scanningCard
            case .needsFullDiskAccess:
                statusCard(icon: "lock.shield", title: "Grant Full Disk Access",
                           detail: "Follow-up Radar reads your threads on-device — never your bank or the network.")
            case .error(let msg):
                statusCard(icon: "exclamationmark.triangle", title: "Couldn't scan", detail: msg)
            case .ready:
                if service.report.isEmpty {
                    allClearCard
                } else {
                    sections
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        // Short cache so opening the tab after you act on mail shows fresh state,
        // not a 5-minute-old snapshot (the "why is this still here" complaint).
        .task { await service.scanIfNeeded(maxAge: 15) }
    }

    // MARK: - Sections

    @ViewBuilder
    private var sections: some View {
        let r = service.report
        if !r.needsReply.isEmpty {
            sectionHeader(icon: "hourglass", tint: .orange, title: "NEEDS YOUR REPLY")
            ForEach(r.needsReply) { item in
                followRow(item, trailingReply: true, help: "Catch me up, then reply")
            }
        }
        if !r.waitingOn.isEmpty {
            sectionHeader(icon: "clock.arrow.circlepath", tint: .cyan, title: "WAITING ON THEM")
            ForEach(r.waitingOn) { item in
                followRow(item, trailingReply: false, help: "Catch me up on this thread")
            }
        }
    }

    /// A follow-up row plus a sibling "Done" control. Done sits OUTSIDE the row's
    /// catch-up tap (AppKitTap overlays its whole view), so clearing a follow-up
    /// never also opens the digest.
    private func followRow(_ item: FollowUpItem, trailingReply: Bool, help: String) -> some View {
        HStack(spacing: 8) {
            row(item, trailingReply: trailingReply)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .appKitTap { caughtUp = item }
                .help(help)
            if item.message.messageID != nil {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
                    .padding(.top, 2)
                    .appKitTap { service.dismiss(item) }
                    .help("Done: clear this follow-up")
            }
        }
    }

    private func sectionHeader(icon: String, tint: Color, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 4)
    }

    private func row(_ item: FollowUpItem, trailingReply: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.counterpartName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(ageLine(item))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .layoutPriority(1)
                }
                Text(item.subject)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if trailingReply {
                replyPill
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var replyPill: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8, weight: .bold))
            Text("Catch up").font(.system(size: 9.5, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.green.opacity(0.5)))
        .padding(.top, 1)
    }

    // MARK: - Cards

    private var scanningCard: some View {
        HStack(spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text("Finding loose ends…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Scanning your threads on-device")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    private var allClearCard: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.green.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text("No loose ends")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Nobody's waiting on you, and you're not waiting on anyone.")
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

    // MARK: - Helpers

    private func ageLine(_ item: FollowUpItem) -> String {
        let rel = relativeShort(item.lastDate)
        return item.kind == .waitingOn ? "you replied \(rel)" : rel
    }

    private func relativeShort(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func mailURL(_ m: MailMessage) -> URL? {
        guard let mid = m.messageID else { return nil }
        let core = mid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }
}
