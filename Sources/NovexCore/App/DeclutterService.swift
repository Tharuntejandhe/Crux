import Foundation
import Observation

/// Declutter — finds the newsletters/promos piling up in the inbox, grouped by
/// sender, with a one-tap unsubscribe (from the List-Unsubscribe header) and a
/// local "mute" (hide this sender across Novex). Fully on-device.
@MainActor
@Observable
final class DeclutterService {
    enum State: Equatable {
        case idle, scanning, ready, needsFullDiskAccess, error(String)
    }

    private(set) var state: State = .idle
    private(set) var report: DeclutterReport = .empty

    private let reader = MailReader()
    private var lastScan: Date = .distantPast

    func scanIfNeeded(maxAge: TimeInterval = 300) async {
        if state == .ready, Date().timeIntervalSince(lastScan) < maxAge { return }
        await scan()
    }

    func scan() async {
        guard reader.hasFullDiskAccess else { state = .needsFullDiskAccess; return }
        if state != .ready { state = .scanning }

        let reader = self.reader
        let now = Date()
        let since = now.addingTimeInterval(-Self.windowDays * 86_400)
        let messages: [MailMessage]
        do {
            messages = try await Task.detached(priority: .utility) {
                try reader.threadMessages(since: since)
            }.value
        } catch {
            state = .error(String(describing: error)); return
        }

        var senders = Self.groupNewsletters(from: messages, muted: MuteStore.all())
        let total = senders.reduce(0) { $0 + $1.count }
        let top = Array(senders.prefix(Self.maxSenders))

        // Read the List-Unsubscribe header from the .emlx that actually carries one
        // (file I/O — off the main actor).
        let rowids = top.compactMap(\.unsubscribeRowID)
        let urls: [Int64: URL] = await Task.detached(priority: .utility) {
            reader.resolveUnsubscribeURLs(rowids: rowids)
        }.value
        senders = top.map { s in
            var s = s
            if let rid = s.unsubscribeRowID { s.unsubscribeURL = urls[rid] }
            return s
        }

        report = DeclutterReport(senders: senders, totalCount: total, generatedAt: now)
        lastScan = now
        state = .ready
    }

    /// Mute a sender (hide across Novex) and drop it from the current report.
    func mute(_ sender: NewsletterSender) {
        MuteStore.mute(sender.address)
        report = DeclutterReport(
            senders: report.senders.filter { $0.id != sender.id },
            totalCount: max(0, report.totalCount - sender.count),
            generatedAt: report.generatedAt
        )
    }

    // MARK: - Pure classification (testable)

    static let windowDays: Double = 30
    static let maxSenders = 15

    /// Whether a message is newsletter/promo/bulk mail — i.e. clutter we can
    /// offer to unsubscribe from or mute. Uses Mail's own signals.
    nonisolated static func isNewsletter(_ m: MailMessage) -> Bool {
        // Muting hides a sender across the WHOLE app, so protect anything the user
        // would never want buried, BEFORE the unsubscribe gate.
        // 1) Bills / receipts / statements. Apple's category is primary; a keyword
        //    backstop covers reads where the category is absent or misclassifies a
        //    receipt (many carry a marketing List-Unsubscribe footer).
        if m.isTransactional || looksTransactional(m) { return false }
        // 2) Account / security alerts (new login, new device, password). Social
        //    login-alert senders (Facebook/LinkedIn) attach a List-Unsubscribe, so
        //    this MUST win over the unsubscribe gate or muting them buries real
        //    security warnings.
        if isSecurityAlert(m) { return false }
        // A real List-Unsubscribe header = clearable bulk mail (incl. benign social
        // pings, which the user may still want to clear here).
        if m.unsubscribeType > 0 { return true }
        // Other ephemeral FYI (codes, benign social) is not clutter to mute.
        if m.isEphemeralNotification { return false }
        // Bulk/automated marketing, UNLESS it's a real person Apple mis-flagged:
        // short PERSONAL mail often gets a false automated_conversation tag, and
        // muting a friend is the highest-cost mistake this list can make.
        if m.automatedType >= 2 && !m.isLikelyPersonalSender { return true }
        return false
    }

    /// Looks like a bill / receipt / statement by subject, so it's never clutter to
    /// mute even when Apple's category is missing or it carries a marketing footer.
    nonisolated static func looksTransactional(_ m: MailMessage) -> Bool {
        let s = m.subject.lowercased()
        let markers = ["invoice", "receipt", "order confirmation", "your order",
                       "payment received", "payment of", "payment successful",
                       "amount due", "payment due", "your statement", "account statement",
                       "e-statement", "bill is ready", "your bill", "refund"]
        return markers.contains { s.contains($0) }
    }

    /// A dedup key for two copies of the SAME message (Gmail keeps one under INBOX
    /// and one under All Mail) when no RFC Message-ID is available.
    nonisolated static func contentKey(_ m: MailMessage) -> String {
        let day = Int(m.dateReceived.timeIntervalSinceReferenceDate / 86_400)
        let sender = (m.senderAddress ?? "").lowercased()
        let subj = m.subject.lowercased().trimmingCharacters(in: .whitespaces)
        return "\(sender)|\(subj)|\(day)"
    }

    /// Account/security alerts to protect from muting even when they carry an
    /// unsubscribe header (login/device/password/verification warnings).
    nonisolated static func isSecurityAlert(_ m: MailMessage) -> Bool {
        let t = (m.subject + " " + (m.snippet ?? "")).lowercased()
        let markers = ["new login", "new sign-in", "new sign in", "sign-in attempt",
                       "new device", "was accessed", "unusual activity", "unusual sign",
                       "suspicious", "password was", "password change", "password reset",
                       "reset your password", "changed your password", "verify your account",
                       "verification code", "security alert", "security code",
                       "did you just", "recognize this"]
        return markers.contains { t.contains($0) }
    }

    /// Group inbox newsletter mail by sender, newest name wins, deduped by
    /// Message-ID (Gmail stores a copy under both INBOX and All Mail). Sorted by
    /// volume. Muted senders are excluded. Pure — no I/O.
    nonisolated static func groupNewsletters(from messages: [MailMessage], muted: Set<String>) -> [NewsletterSender] {
        var seen = Set<String>()
        var byAddr: [String: (name: String, count: Int, latest: MailMessage, unsub: MailMessage?)] = [:]
        for m in messages {
            guard MailReader.isInboxMailbox(m.mailbox), isNewsletter(m) else { continue }
            guard let addr = m.senderAddress?.lowercased(), !addr.isEmpty else { continue }
            if muted.contains(addr) { continue }
            // Dedup Gmail's INBOX + "All Mail" copies. Prefer the RFC Message-ID; when
            // it's absent (the thread reader doesn't always fill it), fall back to a
            // sender+subject+day content key so the two copies still collapse to one
            // (else the "N newsletters" count and per-sender totals inflate up to 2x).
            let dedupKey = m.messageID ?? Self.contentKey(m)
            if !seen.insert(dedupKey).inserted { continue }
            let hasUnsub = m.unsubscribeType > 0
            if let e = byAddr[addr] {
                let newer = m.dateReceived > e.latest.dateReceived
                // The unsubscribe link must come from the newest message that ACTUALLY
                // has a List-Unsubscribe header — the newest message overall often
                // doesn't (a promo run mixes header-less blasts in), which left the
                // sender with no unsubscribe button even though an older one had it.
                let unsub = (hasUnsub && (e.unsub == nil || m.dateReceived > e.unsub!.dateReceived)) ? m : e.unsub
                byAddr[addr] = (newer ? m.senderDisplay : e.name, e.count + 1, newer ? m : e.latest, unsub)
            } else {
                byAddr[addr] = (m.senderDisplay, 1, m, hasUnsub ? m : nil)
            }
        }
        return byAddr.map { addr, v in
            NewsletterSender(id: addr, name: v.name, address: addr, count: v.count,
                             unsubscribeURL: nil, latestMessageID: v.latest.messageID,
                             latestRowID: v.latest.id, unsubscribeRowID: v.unsub?.id)
        }
        .sorted { $0.count > $1.count }
    }
}
