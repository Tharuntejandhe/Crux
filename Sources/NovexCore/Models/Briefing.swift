import Foundation

struct MailMessage: Identifiable, Hashable, Sendable {
    let id: Int64
    let dateReceived: Date
    let isRead: Bool
    let isFlagged: Bool
    let subject: String
    let senderName: String?
    let senderAddress: String?
    let mailbox: String?
    /// RFC 2822 Message-ID (with or without angle brackets); nil if the
    /// Envelope Index didn't expose one. Used to deep-link into Mail.app.
    let messageID: String?

    // --- Real content + Apple's own signals (macOS 26+; defaults keep older
    //     callers and tests working) ---

    /// Short body preview from Mail's `summaries` table — REAL content, not just
    /// the subject. This is what lets the assistant actually understand an email.
    /// nil when unavailable (older macOS / not yet summarized).
    var snippet: String? = nil
    /// Apple's own "this needs attention" flag.
    var isUrgent: Bool = false
    /// Apple's automated-conversation classification (0 = human-written; higher =
    /// bulk/automated/no-reply). Used to deprioritize newsletter/robot noise.
    var automatedType: Int = 0
    /// >0 when Mail detected an unsubscribe header (i.e. a newsletter/promo).
    var unsubscribeType: Int = 0

    // --- Apple's own ML analysis (message_global_data, macOS 26+) ---

    /// Apple Intelligence flagged this as a high-impact message.
    var isHighImpact: Bool = false
    /// Apple detected this needs a follow-up / reply from you.
    var needsFollowUp: Bool = false
    /// Apple's email category (Primary/Transactions/Updates/Promotions — raw int).
    var category: Int = 0

    /// Mail's conversation/thread id — groups a back-and-forth into one thread.
    /// nil on schemas without it (then Follow-up Radar falls back to subject).
    var conversationID: Int64? = nil

    var senderDisplay: String {
        if let name = senderName, !name.isEmpty { return name }
        return senderAddress ?? "Unknown"
    }

    /// Deterministic importance score — the rules engine. This is the "what
    /// matters" logic that runs in CODE (never the model), built on Apple's own
    /// ML signals plus the obvious cues. Higher = more likely to need you.
    var importanceScore: Int {
        var s = 0
        if isUrgent       { s += 100 }
        if isHighImpact   { s += 80 }
        if needsFollowUp  { s += 60 }
        if !isRead        { s += 40 }
        if isFlagged      { s += 30 }

        // Noise penalties for bulk / newsletter / no-reply mail.
        var penalty = 0
        // Apple's `automated` flag often MIS-flags short PERSONAL mail (a friend's
        // "hey bro") as automated. Don't apply that penalty to a plain personal
        // sender with no unsubscribe header and no no-reply signature, or real
        // people get buried below newsletters.
        let personalException = isLikelyPersonalSender && unsubscribeType == 0 && !isNotificationSender
        if automatedType >= 2 && !personalException { penalty += 45 }
        if unsubscribeType > 0 { penalty += 35 }   // newsletter / promo (List-Unsubscribe)
        if isNotificationSender { penalty += 50 }  // no-reply / notification bot

        // Rescue GENUINE actions from the noise penalty (Apple-urgent, or you owe a
        // reply, or a high-impact mail from a REAL sender). But do NOT rescue a
        // notification bot just because Apple flagged it high-impact — a Facebook
        // 2FA code / "password changed" / "account verification" is high-impact yet
        // needs nothing from you. Those that DO carry a real deadline/bill get
        // rescued later by the action bonus in the ranker (which has the deadline).
        if isUrgent || needsFollowUp || (isHighImpact && !isNotificationSender) {
            s -= min(penalty, 40)
        } else {
            s -= penalty
        }
        return s
    }

    /// A plain person-to-person address (consumer mail provider). Used to stop
    /// Apple's over-eager "automated" flag from burying a friend's short message.
    var isLikelyPersonalSender: Bool {
        guard let addr = senderAddress?.lowercased(), addr.contains("@") else { return false }
        if isNotificationSender || unsubscribeType > 0 { return false }
        let domain = addr.split(separator: "@").last.map(String.init) ?? ""
        let personalDomains: Set<String> = [
            "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com",
            "yahoo.com", "ymail.com", "icloud.com", "me.com", "mac.com",
            "proton.me", "protonmail.com", "aol.com", "msn.com",
        ]
        return personalDomains.contains(domain)
    }

    /// A concrete near-future date mentioned in the subject/snippet (a deadline
    /// like "verify by 14/07/2026"), via NSDataDetector — the real to-dos Apple's
    /// signals miss. nil if none. NOTE: regex-based, so callers compute it ONCE
    /// per message (never inside `importanceScore`, which is hot in sorts).
    var detectedDeadline: Date? {
        // A routine notification's date is never a to-do deadline (a policy's
        // "effective by <date>", a code's expiry) — don't stamp it "due"/"overdue".
        if isEphemeralNotification { return nil }
        let text = subject + ". " + (snippet ?? "")
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        // A DEADLINE needs a cue — "by/due/before/expires/pay by/verify by". A bare
        // date is just a mention (a meeting time, a session), NOT a to-do, so we
        // don't stamp "overdue" on a session invitation.
        let cues = ["by ", " due", "due ", "before ", "expire", "deadline", "no later",
                    "last day", "ends ", "closes ", "respond by", "reply by", "act by",
                    "pay by", "verify by", "complete by", "within "]
        let ns = text as NSString
        let now = Date()
        var best: Date?
        for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let d = m.date,
                  d > now.addingTimeInterval(-30 * 86_400),      // recently-overdue still counts
                  d < now.addingTimeInterval(400 * 86_400) else { continue }
            let start = max(0, m.range.location - 34)
            let pre = ns.substring(with: NSRange(location: start, length: m.range.location - start)).lowercased()
            if cues.contains(where: { pre.contains($0) }) {
                if best == nil || d < best! { best = d }
            }
        }
        return best
    }

    /// Routine notifications that are FYI or ephemeral — a one-time code you use
    /// instantly, a "password changed" notice, a social ping, an account-verify
    /// prompt. High-impact to Apple, but they need NOTHING from you, so they must
    /// never be featured as "needs you" or labeled confirm/review. (A genuine
    /// deadline overrides this — see the callers.)
    var isEphemeralNotification: Bool {
        let t = (subject + " " + (snippet ?? "")).lowercased()
        // One-time CODES — match by pattern, not exact phrase, so "239768 is your
        // Facebook code" and "your login code is 481920" are both caught.
        if t.contains("code"),
           t.contains("your") || t.contains("verification") || t.contains("login")
           || t.contains("security") || t.contains("one-time") || t.contains("otp")
           || t.contains("sign-in") || t.contains("sign in") || t.contains("2fa") {
            return true
        }
        let markers = [
            // security / account FYIs — informational, nothing to DO
            "password change", "password was changed", "password has been changed",
            "password reset", "changed your password", "new login", "new sign-in",
            "new sign in", "just log in", "did you just", "log in near", "sign-in attempt",
            "new device", "was accessed", "unusual activity", "suspicious", "we noticed",
            "recognize this", "account verification", "verify your account",
            "your account was", "successfully logged",
            // terms / policy / privacy UPDATES — a notice, not a task (grabbed a false
            // "effective by <date>" deadline before)
            "terms of service", "terms and conditions", "privacy policy", "policy update",
            "policy change", "updates to our", "changes to our", "update our terms",
            "updated our terms", "updated terms", "we're updating", "we are updating",
            "changes to the terms", "update to our", "changes to your terms",
            // social pings — activity notifications from Facebook/Instagram/LinkedIn/X
            // are FYI, never a to-do (a "Rahul on Facebook" / friend-suggestion was
            // wrongly landing on the "needs you" plate).
            "posted an update", "posted a ", "posted on", "shared a ", "commented on",
            "liked your", "mentioned you", "friend request", "friend suggestion",
            "people you may know", "wants to be friends", "tagged you", "started following",
            "reacted to", "sent you a message request", "wants to connect", "new follower",
            "on facebook", "on instagram", "on linkedin", "on threads",
            "viewed your profile", "endorsed you", "invitation to connect",
            "invited you to connect", "new connection", "is now on",
        ]
        return markers.contains { t.contains($0) }
    }

    /// True when this mail was sent BY the user (a note-to-self / your own send).
    /// You never "reply" to yourself and it's never a conversation that needs you.
    func isFromSelf(_ mine: Set<String>) -> Bool {
        guard let a = senderAddress?.lowercased() else { return false }
        return mine.contains(a)
    }

    /// A no-reply / notification / bot sender (Fiverr `noreply@`, Vercel 2FA,
    /// "X via Slack/LinkedIn", mailer-daemon…). You can't meaningfully reply to
    /// these, and they should NEVER be featured as "needs you". Single source of
    /// truth used by ranking, the reply gate, and follow-ups.
    var isNotificationSender: Bool {
        let addr = (senderAddress ?? "").lowercased()
        let name = (senderName ?? "").lowercased()
        if name.contains("via slack") || name.contains("via linkedin")
            || name.contains("via facebook") || name.contains("via teams")
            || name.contains("notification") { return true }
        // Anchor to the LOCAL PART (before @), not the whole address — so a real
        // person like `alberto@…`, a `security`-team human, or any domain that
        // merely contains "bounce"/"alert" isn't wrongly silenced (and we don't
        // refuse to draft them a reply).
        let local = addr.split(separator: "@").first.map(String.init) ?? addr
        let prefixes = [
            "noreply", "no-reply", "no_reply", "no.reply", "donotreply",
            "do-not-reply", "do_not_reply", "notifications", "notification",
            "notify", "mailer-daemon", "mailerdaemon", "postmaster",
            "automated", "auto-confirm", "auto_confirm",
        ]
        if prefixes.contains(where: { local.hasPrefix($0) }) { return true }
        // Exact-match mailbox names that are always machine senders.
        let exacts: Set<String> = ["security", "alerts", "alert", "bounce", "bounces", "mailer"]
        return exacts.contains(local)
    }

    /// Can the user actually write a human reply to this? (Real person, not a bot.)
    var isReplyable: Bool { !isNotificationSender }

    /// Whether this mail is worth FEATURING in the briefing (vs. de-emphasizing
    /// as "recent" noise). Human mail, flagged, urgent, or Apple-flagged
    /// high-impact clears the bar; automated newsletters/alerts/notifications don't.
    var isImportant: Bool { importanceScore >= 30 }

    /// Subject + body snippet, for feeding the model real content. Falls back to
    /// just the subject when no snippet is available.
    var contentForModel: String {
        guard let s = snippet?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return subject
        }
        return "\(subject): \(s.prefix(280))"
    }

    /// Apple's "Transactions" category (bills / receipts / payments). macOS 26
    /// `model_category`: 0 Primary, 1 Transactions, 2 Updates, 3 Promotions.
    var isTransactional: Bool { category == 1 }

    /// Deterministic action label — runs in CODE, so pay/confirm/reply still work
    /// with Apple Intelligence OFF (the model only refines phrasing). `mine` = the
    /// user's own addresses, so a note-to-self never becomes a "reply".
    /// `deadline` is precomputed by the caller (regex is too slow for the ranker's
    /// hot path) — pass `detectedDeadline` once per message.
    func deterministicAction(mine: Set<String>, deadline: Date?) -> AIAction {
        if isFromSelf(mine) { return .none }
        // Routine notification (code / security alert / terms update / social) → FYI,
        // never an action to confirm/review, period.
        if isEphemeralNotification { return isRead ? .none : .read }
        let text = (subject + " " + (snippet ?? "")).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        if has(["invoice", "amount due", "payment due", "pay now", "outstanding balance",
                "your bill", "bill is due", "make a payment", "complete your payment",
                "past due", "payment failed", "renew your subscription"]) {
            return .pay
        }
        // A REAL deadline, or explicit verify/confirm language you must act on.
        if deadline != nil || has(["verify your identity", "verify your", "confirm your",
                "action required", "complete your verification", "please confirm",
                "confirm your email", "rsvp"]) {
            return .confirm
        }
        // Apple "Transactions" (a receipt/statement) from a real sender, not a bot.
        if isTransactional && !isNotificationSender && !isRead { return .review }
        if isReplyable && (needsFollowUp
            || subject.trimmingCharacters(in: .whitespaces).hasSuffix("?")) {
            return .reply
        }
        return isRead ? .none : .read
    }

    /// One-word reason this surfaced. `deadline` precomputed. The date itself is
    /// shown as a separate chip, so this returns the OTHER reason (or nil).
    func attentionReason(mine: Set<String>, deadline: Date?) -> String? {
        if isFromSelf(mine) { return "your note" }
        if isUrgent { return "urgent" }
        if isFlagged { return "flagged" }
        if needsFollowUp && isReplyable { return "awaiting reply" }
        if isTransactional && !isNotificationSender { return "bill" }
        if isHighImpact && !isNotificationSender { return "important" }
        return nil
    }
}

struct BriefingItem: Identifiable, Hashable {
    let id: UUID
    let icon: String
    let title: String
    let detail: String
    let action: AIAction
    let isNew: Bool
    let messageID: String?
    /// A concrete deadline to show as a chip (e.g. "due Jul 14"), if detected.
    let dueDate: Date?
    /// One-word reason this surfaced ("urgent", "flagged", "deadline"…), shown so
    /// the ranking isn't a black box. nil = no badge.
    let reason: String?
    /// Can the user actually reply to this? Drives whether the row offers a
    /// "Reply" affordance vs a plain "Open". False for bots / your own notes.
    let replyable: Bool

    init(
        id: UUID = UUID(),
        icon: String,
        title: String,
        detail: String,
        action: AIAction = .none,
        isNew: Bool = false,
        messageID: String? = nil,
        dueDate: Date? = nil,
        reason: String? = nil,
        replyable: Bool = true
    ) {
        self.id = id
        self.icon = icon
        self.title = title
        self.detail = detail
        self.action = action
        self.isNew = isNew
        self.messageID = messageID
        self.dueDate = dueDate
        self.reason = reason
        self.replyable = replyable
    }

    /// A `message://` URL that opens this exact message in Mail.app, or nil if
    /// we don't have a usable Message-ID. Mail marks the message read when it
    /// opens, so tapping doubles as "mark read".
    var mailURL: URL? {
        guard let messageID else { return nil }
        let core = messageID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty,
              let encoded = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        // Angle brackets are encoded as %3C / %3E per the message: scheme.
        return URL(string: "message://%3C\(encoded)%3E")
    }
}

struct Briefing: Equatable {
    let generatedAt: Date
    let items: [BriefingItem]
    let totalUnread: Int
    let summary: String?
    /// How many messages were genuinely important (worth featuring). 0 means the
    /// inbox is just noise → show the calm "caught up" state, not fake analysis.
    var importantCount: Int = 0
    /// The REST of the recent inbox (newsletters, job alerts, FYI mail) — shown
    /// under "RECENT" below the action items so you still see everything, not just
    /// the few things that need you. Excludes the featured items and your own notes.
    var recent: [BriefingItem] = []

    static let empty = Briefing(generatedAt: .distantPast, items: [], totalUnread: 0, summary: nil)
}
