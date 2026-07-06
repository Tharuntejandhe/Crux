import Foundation
import Observation

/// Follow-up Radar — finds stalled threads in the local Mail store: emails you
/// haven't replied to, and emails where you replied but got no answer. All
/// on-device; reads across Inbox + Sent to tell thread direction.
@MainActor
@Observable
final class FollowUpService {
    enum State: Equatable {
        case idle, scanning, ready, needsFullDiskAccess, error(String)
    }

    private(set) var state: State = .idle
    private(set) var report: FollowUpReport = .empty
    /// The user's own addresses (from Sent mail) — used to label "You" when
    /// summarizing a thread.
    private(set) var myAddresses: Set<String> = []

    private let reader = MailReader()
    private var lastScan: Date = .distantPast
    /// The messages from the last scan, kept so "Catch me up" can pull a whole
    /// thread without re-querying.
    private var scanned: [MailMessage] = []

    /// Clear a follow-up the user has handled: hide the WHOLE thread from
    /// Follow-ups instantly (no re-read of Mail). The tapped message is also
    /// dismissed app-wide via the shared DismissStore. Dropping the whole thread
    /// (not just the one message) is essential: leaving the rest would let
    /// buildReport reclassify it by the new latest message and flip the cleared
    /// row into the other section. Not reversible from here.
    func dismiss(_ item: FollowUpItem) {
        guard let id = item.message.messageID else { return }
        DismissStore.dismiss(id)
        scanned = Self.hidingDismissedThreads(scanned, dismissed: DismissStore.dismissed())
        report = Self.buildReport(from: scanned, now: Date())
    }

    /// All messages belonging to the same thread as `item`, oldest first.
    func thread(for item: FollowUpItem) -> [MailMessage] {
        let key = Self.threadKey(item.message)
        return scanned
            .filter { Self.threadKey($0) == key }
            .sorted { $0.dateReceived < $1.dateReceived }
    }

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
            state = .error(String(describing: error))
            return
        }
        // Respect muted senders (Declutter), snoozed items, and anything the user
        // marked Done: a follow-up you've handled must stay gone, here as in Inbox.
        let asleep = SnoozeStore.asleepIDs()
        let dismissed = DismissStore.dismissed()
        let visible = Self.hidingDismissedThreads(messages, dismissed: dismissed).filter {
            !MuteStore.isMuted($0.senderAddress)
                && !($0.messageID.map(asleep.contains) ?? false)
        }
        scanned = visible
        myAddresses = Set(visible
            .filter { MailReader.isSentMailbox($0.mailbox) }
            .compactMap { $0.senderAddress?.lowercased() })
            .union(OwnerIdentity.addresses)   // Gmail Sent lives under All Mail → union so "You" is tagged right
        // Share "who am I" with the rest of the app — the briefing uses it to
        // recognize notes-to-self and never draft a reply back to you.
        OwnerIdentity.learn(myAddresses)
        report = Self.buildReport(from: visible, now: now)
        lastScan = now
        state = .ready
    }

    /// Remove EVERY message of any thread that contains a dismissed message. If we
    /// dropped only the one dismissed message, buildReport would re-group the
    /// thread's remaining messages and reclassify it by the new latest one, so a
    /// cleared "needs reply" would flip into "waiting on them" (or a cleared
    /// "waiting on them" would start nagging you to reply to mail you answered).
    /// Hiding the whole thread makes "Done" actually stick. Pure + testable.
    nonisolated static func hidingDismissedThreads(_ messages: [MailMessage], dismissed: Set<String>) -> [MailMessage] {
        guard !dismissed.isEmpty else { return messages }
        let deadKeys = Set(messages
            .filter { $0.messageID.map(dismissed.contains) ?? false }
            .map { threadKey($0) })
        guard !deadKeys.isEmpty else { return messages }
        return messages.filter { !deadKeys.contains(threadKey($0)) }
    }

    /// Stable thread key: conversation id when present, else normalized subject.
    nonisolated static func threadKey(_ m: MailMessage) -> String {
        if let c = m.conversationID, c != 0 { return "c\(c)" }
        let subj = m.subject.lowercased()
            .replacingOccurrences(of: #"^\s*(re|fwd|fw)\s*:\s*"#,
                                  with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return "s|\(subj)"
    }

    // MARK: - Pure classification (testable)

    nonisolated static let windowDays: Double = 30
    nonisolated static let replyMinAge: TimeInterval = 12 * 3600      // give fresh mail time
    nonisolated static let replyMaxAge: TimeInterval = 21 * 86_400    // stop nagging after 3 weeks
    nonisolated static let waitMinAge: TimeInterval = 2 * 86_400      // give them time to reply
    // Stop showing "waiting on them" after ~2 weeks: if they haven't replied by
    // then they aren't going to, so it's stale noise, not a live thread.
    nonisolated static let waitMaxAge: TimeInterval = 14 * 86_400
    nonisolated static let maxPerSection = 6

    /// Build the report from a flat list of thread messages (across all
    /// mailboxes). Derives "my addresses" from Sent mail, groups into threads,
    /// and classifies each by whose turn it is. Pure — no I/O.
    nonisolated static func buildReport(from messages: [MailMessage], now: Date) -> FollowUpReport {
        // Who am I? Senders of my own Sent mail in this window, UNION the persisted
        // identity set — on Gmail (Sent lives under All Mail) the local window can
        // be empty, which made answered threads wrongly resurface as "needs reply".
        let myAddresses = Set(messages
            .filter { MailReader.isSentMailbox($0.mailbox) }
            .compactMap { $0.senderAddress?.lowercased() })
            .union(OwnerIdentity.addresses)

        func isMine(_ m: MailMessage) -> Bool {
            guard let a = m.senderAddress?.lowercased() else { return false }
            return myAddresses.contains(a)
        }

        // Group into threads (conversation id, else normalized subject).
        var groups: [String: [MailMessage]] = [:]
        for m in messages {
            groups[threadKey(m), default: []].append(m)
        }

        var needsReply: [FollowUpItem] = []
        var waitingOn: [FollowUpItem] = []

        for (_, msgs) in groups {
            let sorted = msgs.sorted { $0.dateReceived > $1.dateReceived }
            guard let latest = sorted.first else { continue }
            let age = now.timeIntervalSince(latest.dateReceived)
            guard age >= 0 else { continue }   // ignore clock-skew/future dates
            // The human on the other side = most recent incoming sender.
            let counterpart = sorted.first(where: { !isMine($0) })
            let counterpartName = counterpart?.senderDisplay ?? "someone"

            if isMine(latest) {
                // You spoke last → waiting on them — but only for a REAL two-way
                // thread. Skip self-only notes (no other party → blank "—" rows) and
                // broadcasts / newsletters / bots you happened to reply to (you're
                // not awaiting a reply from an announcement).
                guard age >= waitMinAge, age <= waitMaxAge,
                      let cp = counterpart, wantsReply(cp) else { continue }
                waitingOn.append(FollowUpItem(message: latest,
                                              counterpartName: cp.senderDisplay,
                                              kind: .waitingOn))
            } else {
                // They spoke last → needs your reply (if it actually wants one).
                guard age >= replyMinAge, age <= replyMaxAge, wantsReply(latest) else { continue }
                needsReply.append(FollowUpItem(message: latest,
                                               counterpartName: counterpartName,
                                               kind: .needsReply))
            }
        }

        // Most overdue first; cap each section so it never becomes a wall.
        needsReply.sort { $0.lastDate < $1.lastDate }
        waitingOn.sort { $0.lastDate < $1.lastDate }
        return FollowUpReport(
            needsReply: Array(needsReply.prefix(maxPerSection)),
            waitingOn: Array(waitingOn.prefix(maxPerSection)),
            generatedAt: now
        )
    }

    /// Whether an incoming email plausibly wants a human reply (vs a newsletter,
    /// promo, or no-reply robot we'd never answer).
    nonisolated static func wantsReply(_ m: MailMessage) -> Bool {
        if m.automatedType >= 2 { return false }         // automated conversation
        if m.unsubscribeType > 0 { return false }         // newsletter / bulk
        if m.isNotificationSender { return false }         // no-reply / 2FA / "via Slack" bots
        if m.isEphemeralNotification { return false }      // code / password / terms / social FYI
        return true
    }
}
