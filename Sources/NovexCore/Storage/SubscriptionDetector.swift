import Foundation

/// Turns raw mail metadata into a list of recurring subscriptions — entirely
/// on-device, no bank, no network. Pure functions so the whole pipeline is
/// unit-testable with synthetic `MailMessage`s.
///
/// Strategy (in order of confidence):
///  1. Identify candidate emails: known merchant OR subscription-shaped subject.
///  2. Extract a real amount + currency from the subject when present.
///  3. Group candidates by merchant identity; collapse repeats.
///  4. Fill missing amounts from the static catalog (marked as estimates).
///  5. Detect billing cycle (subject tokens → catalog default → inter-arrival).
///  6. Flag trials that are about to convert to paid.
/// Internal implementation detail — the public surface is `MoneyRadarService`,
/// which returns the public `MoneyRadarReport`/`Subscription` types. Kept
/// internal so it can take the internal `MailMessage`; `@testable import`
/// still reaches every method below for unit testing.
enum SubscriptionDetector {

    // MARK: - Entry point

    /// Detect subscriptions from a batch of messages (any time window the
    /// caller chose — a wide window, e.g. 13 months, gives better cycle
    /// inference). `now` is injectable for deterministic tests.
    static func detect(from messages: [MailMessage], now: Date) -> [Subscription] {
        // 1–2. Build candidates with any amount we can read from the subject.
        let raw: [Candidate] = messages.compactMap { candidate(from: $0) }

        // Dedup Gmail's INBOX + "All Mail" copies of the same message. Two same-day
        // copies otherwise give inferCycle a 0-day gap (a monthly sub called "weekly",
        // 52x the real cost) and double the message count. Prefer the Message-ID; else
        // a merchant+amount+day content key.
        var seen = Set<String>()
        let candidates = raw.filter { c in
            let key = c.messageID ?? "\(c.merchantKey)|\(c.amount ?? 0)|\(Int(c.date.timeIntervalSinceReferenceDate / 86_400))"
            return seen.insert(key).inserted
        }

        // 3. Group by merchant identity.
        let groups = Dictionary(grouping: candidates, by: \.merchantKey)

        var subs: [Subscription] = groups.map { _, items in
            build(from: items, now: now)
        }

        // Sort: trials-converting first (act now), then by yearly cost desc.
        subs.sort { a, b in
            if a.isTrialConverting != b.isTrialConverting { return a.isTrialConverting }
            return a.yearlyCost > b.yearlyCost
        }
        return subs
    }

    // MARK: - Candidate extraction

    struct Candidate {
        let merchantKey: String
        let displayName: String
        let category: SubscriptionCategory
        let date: Date
        let amount: Double?
        let currencyCode: String?
        let amountSource: AmountSource
        let cycleHint: BillingCycle?
        let isTrial: Bool
        let nextRenewal: Date?
        let messageID: String?
        let catalogMonthlyUSD: Double?
        let catalogCycle: BillingCycle?
    }

    /// Decide whether a single message represents a subscription/billing event,
    /// and pull what we can from it. Returns nil for non-subscription mail.
    /// Cheap subject-only pre-filter: is this PLAUSIBLY a billing/subscription
    /// email? Money Radar uses it to choose which of the 1500 scanned messages
    /// get their body fetched (we can't open all those files).
    static func isLikelyCandidate(_ m: MailMessage) -> Bool {
        // Skip obvious non-subscriptions up front (tax invoices, statements,
        // income) so we don't waste a body-fetch on them.
        if isNonSubscriptionEmail(subject: m.subject.lowercased(), snippet: nil) { return false }
        if MerchantCatalog.match(senderAddress: m.senderAddress, senderName: m.senderName, subject: m.subject) != nil {
            return true
        }
        return isBillingSubject(m.subject.lowercased())
    }

    static func candidate(from m: MailMessage) -> Candidate? {
        let subject = m.subject
        let lowerSubject = subject.lowercased()

        // HARD EXCLUDE first: emails that look billing-shaped but are NOT a
        // subscription you pay — tax invoices, "payments you have received"
        // (income!), account statements, money requests. A PayPal tax-invoice
        // notification was the worst offender: matched "invoice", grabbed
        // ₹1,94,653 from the body, and showed up as a monthly subscription.
        if isNonSubscriptionEmail(subject: lowerSubject, snippet: m.snippet) { return nil }

        let merchant = MerchantCatalog.match(
            senderAddress: m.senderAddress, senderName: m.senderName, subject: subject, body: m.snippet
        )

        // For a KNOWN catalog merchant (a trusted subscription sender), a bland
        // subject with the receipt language only in the BODY is still a real
        // subscription, so check subject+body - the Apple path already trusts the
        // body this way. An UNKNOWN sender stays subject-only: we must never trust a
        // stranger's body text to manufacture a subscription.
        let billingHay = merchant != nil
            ? (lowerSubject + " " + (m.snippet ?? "").lowercased())
            : lowerSubject
        let looksBilling = isBillingSubject(billingHay)
        guard let merchant, looksBilling else {
            // Unknown sender → require a GENUINE transaction token (receipt /
            // charged / payment), not just a billing-SHAPED subject. A stranger
            // saying "your plan" is too speculative to list as a subscription.
            if merchant == nil, hasStrongBillingSignal(lowerSubject),
               let generic = genericCandidate(from: m) {
                return generic
            }
            return nil
        }

        var (amount, currency) = parseAmount(from: subject)
        // v2: fall back to the receipt BODY for the real charged amount when the
        // subject doesn't carry one. Money Radar attaches bodies to candidates,
        // so `snippet` here is the real receipt text — not a catalog guess.
        if amount == nil, let snip = m.snippet, !snip.isEmpty {
            (amount, currency) = parseAmount(from: snip)
        }
        // Parse the billing cycle from subject AND body: an annual receipt often
        // says "annual"/"1 year" only in the body, so subject-only parsing let
        // annuals fall back to monthly → a 12× inflated yearly total.
        let cycleText = lowerSubject + " " + (m.snippet ?? "").lowercased()

        // PLAUSIBILITY: a parsed amount that's absurd for a *personal*
        // subscription (e.g. ₹1,94,653 lifted from an invoice total) is a parse
        // error. Discard it and let the catalog estimate stand in instead.
        if let a = amount,
           !isPlausibleAmount(a, currency: currency, cycleHint: parseCycle(from: cycleText)) {
            amount = nil
            currency = nil
        }

        // CREDIBILITY GUARD: a known merchant + a merely billing-SHAPED subject
        // isn't enough — weak tokens ("free trial","plan") appear in marketing
        // too ("Start your free trial!", "New plan features"). Listing a service
        // the user doesn't actually pay for would make the radar look broken
        // (worse than a miss, for a "money you're wasting" tool). Require real
        // corroboration: a strong transactional token, a parsed amount, or a
        // genuine trial-conversion signal.
        let qualifies = hasStrongBillingSignal(lowerSubject)
            || amount != nil
            || isTrialEnding(lowerSubject)
        guard qualifies else { return nil }

        // A payment PROCESSOR (PayPal/etc, no typical price of its own) is not a
        // subscription — a one-off "Receipt for your payment to John's Store" must
        // not be listed. Require an explicit recurrence signal for these.
        if merchant.typicalMonthlyUSD == nil {
            let recurs = ["subscription", "recurring", "renew", "auto-renew",
                          "automatic payment", "membership", "/mo", "/month", "/yr",
                          "per month", "per year", "billing cycle", "next billing"]
            guard recurs.contains(where: { cycleText.contains($0) }) else { return nil }
        }

        return Candidate(
            merchantKey: merchant.key,
            displayName: merchant.displayName,
            category: merchant.category,
            date: m.dateReceived,
            amount: amount,
            currencyCode: currency,
            amountSource: amount == nil ? .unknown : .parsedFromEmail,
            cycleHint: parseCycle(from: cycleText),
            isTrial: isTrialEnding(lowerSubject),
            nextRenewal: parseRenewalDate(from: subject, relativeTo: m.dateReceived),
            messageID: m.messageID,
            catalogMonthlyUSD: merchant.typicalMonthlyUSD,
            catalogCycle: merchant.defaultCycle
        )
    }

    /// A billing email from a sender we don't have in the catalog. We still
    /// surface it, named after the sender, so nothing is missed.
    static func genericCandidate(from m: MailMessage) -> Candidate? {
        if isNonSubscriptionEmail(subject: m.subject.lowercased(), snippet: m.snippet) { return nil }
        // A storefront one-off (Amazon/Google/Microsoft order) already failed the
        // catalog's product guard; never let it re-enter as a generic subscription.
        if let d = MerchantCatalog.emailDomain(m.senderAddress), MerchantCatalog.isStorefrontDomain(d) { return nil }
        // An UNKNOWN-merchant subscription worth surfacing comes from a billing /
        // receipt address — never from a notification bot (notifications@github,
        // alerts@…). Excluding these kills the "Pixxel $12" GitHub/Vercel
        // false positive; known no-reply billers (Spotify/Netflix) are covered by
        // the catalog path, not here.
        if m.isNotificationSender { return nil }
        // A non-catalog sender must show a STRONG billing token (receipt / payment
        // / invoice / charged) — not merely contain a number. Otherwise any mail
        // with "$12" in it (a GitHub PR, a price quote) becomes a fake "$12 sub".
        let lower = (m.subject + " " + (m.snippet ?? "")).lowercased()
        guard hasStrongBillingSignal(lower) else { return nil }
        var (amount, currency) = parseAmount(from: m.subject)
        if amount == nil, let snip = m.snippet, !snip.isEmpty {
            (amount, currency) = parseAmount(from: snip)
        }
        // For an unknown sender, only keep it if we parsed a PLAUSIBLE amount —
        // no amount, or an absurd one, is too speculative to call a subscription.
        guard let a = amount,
              isPlausibleAmount(a, currency: currency, cycleHint: parseCycle(from: lower))
        else { return nil }
        let name = m.senderName?.isEmpty == false
            ? m.senderName!
            : (MerchantCatalog.emailDomain(m.senderAddress) ?? "Unknown service")
        let key = "generic:" + name.lowercased()
        return Candidate(
            merchantKey: key,
            displayName: name,
            category: .other,
            date: m.dateReceived,
            amount: amount,
            currencyCode: currency,
            amountSource: .parsedFromEmail,
            cycleHint: parseCycle(from: lower),
            isTrial: isTrialEnding(m.subject.lowercased()),
            nextRenewal: parseRenewalDate(from: m.subject, relativeTo: m.dateReceived),
            messageID: m.messageID,
            catalogMonthlyUSD: nil,
            catalogCycle: nil
        )
    }

    // MARK: - Group → Subscription

    static func build(from items: [Candidate], now: Date) -> Subscription {
        let sorted = items.sorted { $0.date > $1.date }
        let newest = sorted[0]

        // Amount: prefer a parsed amount (newest first), else catalog estimate.
        let parsed = sorted.first { $0.amount != nil && $0.amountSource == .parsedFromEmail }
        let amount: Double?
        let currency: String
        let amountSource: AmountSource
        if let parsed, let a = parsed.amount {
            amount = a
            currency = parsed.currencyCode ?? "USD"
            amountSource = .parsedFromEmail
        } else if let monthly = newest.catalogMonthlyUSD {
            // Convert catalog monthly price into the detected cycle's per-charge
            // figure so yearly math stays correct.
            let cycle = resolveCycle(items: sorted)
            amount = monthly * (12.0 / cycle.perYear)
            currency = "USD"
            amountSource = .estimatedFromCatalog
        } else {
            amount = nil
            currency = "USD"
            amountSource = .unknown
        }

        let cycle = resolveCycle(items: sorted)
        let isTrialConverting = sorted.contains(where: \.isTrial)
        let nextRenewal = sorted.compactMap(\.nextRenewal).filter { $0 >= now }.min()

        return Subscription(
            merchantKey: newest.merchantKey,
            displayName: newest.displayName,
            category: newest.category,
            amount: amount,
            currencyCode: currency,
            amountSource: amountSource,
            cycle: cycle,
            lastSeen: newest.date,
            messageCount: items.count,
            isTrialConverting: isTrialConverting,
            nextRenewal: nextRenewal,
            sourceMessageID: newest.messageID
        )
    }

    /// Cycle from (in order): an explicit subject token on any related email,
    /// the catalog default, inference from spacing between receipts, else unknown.
    static func resolveCycle(items: [Candidate]) -> BillingCycle {
        if let hinted = items.compactMap(\.cycleHint).first { return hinted }
        if let catalog = items.compactMap(\.catalogCycle).first(where: { $0 != .unknown }) {
            return catalog
        }
        return inferCycle(fromDates: items.map(\.date))
    }

    /// Infer a cycle from the median gap between recurring receipts.
    static func inferCycle(fromDates dates: [Date]) -> BillingCycle {
        let sorted = dates.sorted()
        guard sorted.count >= 2 else { return .unknown }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let g = sorted[i].timeIntervalSince(sorted[i - 1]) / 86_400 // days
            if g >= 1 { gaps.append(g) }   // ignore same-day duplicate copies
        }
        guard !gaps.isEmpty else { return .unknown }
        gaps.sort()
        let medianDays = gaps[gaps.count / 2]
        switch medianDays {
        case ..<11:        return .weekly
        case 11..<45:      return .monthly
        case 45..<135:     return .quarterly
        case 135...:       return .yearly
        default:           return .unknown
        }
    }

    // MARK: - Subject heuristics (pure, testable)

    /// STRONG tokens: a real transaction you almost certainly paid for. These
    /// alone qualify a known-merchant email as a subscription.
    static let strongBillingTokens = [
        "receipt", "invoice", "your subscription", "subscription has",
        "subscription will", "subscription renew", "payment", "renew", "renewal",
        "billed", "your bill", "membership", "auto-renew", "order confirmation",
        "thank you for your purchase", "you've been charged", "charged",
        "payment confirmation", "we've received your payment",
    ]

    /// WEAK tokens: promo-ish words that appear in BOTH receipts and marketing
    /// ("start your free trial", "new plan features"). They make an email
    /// billing-SHAPED but are NOT enough alone to call it a paid subscription —
    /// `candidate()` requires corroboration (strong token / amount / real trial
    /// conversion).
    static let weakBillingTokens = ["trial", "free trial", "plan"]

    static let billingTokens = strongBillingTokens + weakBillingTokens

    static func isBillingSubject(_ lowerSubject: String) -> Bool {
        billingTokens.contains { lowerSubject.contains($0) }
    }

    static func hasStrongBillingSignal(_ lowerSubject: String) -> Bool {
        strongBillingTokens.contains { lowerSubject.contains($0) }
    }

    // MARK: - Non-subscription exclusions

    /// Phrases that mark an email as billing-SHAPED but NOT a subscription you
    /// pay: tax invoices, income ("payments you have received"), account
    /// statements, money requests/transfers. These caused the worst false
    /// positives (a PayPal tax-invoice notification listed as ₹1.9L/mo).
    static let nonSubscriptionTokens = [
        // Fee / rate / pricing-change notices — informational, not a charge you pay
        // (e.g. Payoneer "lower card fees" became a "$0.49 subscription").
        "fee change", "fees change", "lower card fees", "card fees",
        "rate change", "fee update", "pricing update", "price update",
        "changes to our", "update to our terms", "updates to our terms",
        "terms of service", "terms and conditions",
        "tax invoice",
        "you have received",
        "you've received",
        "you received a payment",
        "sent you money",
        "sent you a payment",
        "has sent you",
        "payment request",
        "requested a payment",
        "requested money",
        "request money",
        "money request",
        "account statement",
        "statement is ready",
        "statement is available",
        "view your statement",
        "e-statement",
        // Income / money-in: a payout to YOU is not a subscription you pay for.
        "received from",
        "you've received a payment",
        "you have received a payment",
        "you've been paid",
        "you have been paid",
        "payout",
        "money received",
        "has paid you",
        "credited to your",
        // Refunds / reversals: a refund is not ongoing spend (often a cancellation).
        "refund",
        "refunded",
        "we refunded",
        "credit note",
    ]

    /// True if the email is billing-shaped but isn't something the user PAYS
    /// for (income, tax docs, statements, money requests). Checked against both
    /// subject and snippet so income receipts are caught wherever the tell sits.
    static func isNonSubscriptionEmail(subject: String, snippet: String?) -> Bool {
        let hay = (subject + " " + (snippet ?? "")).lowercased()
        return nonSubscriptionTokens.contains { hay.contains($0) }
    }

    /// Reject amounts absurd for a *personal* subscription — almost always a
    /// parse error (an invoice total, balance, or order number grabbed from a
    /// receipt body). Currency-aware via per-currency monthly ceilings, so we
    /// never need an FX rate. ₹1,94,653/mo → rejected; $12/wk → kept.
    static func isPlausibleAmount(_ amount: Double, currency: String?, cycleHint: BillingCycle?) -> Bool {
        guard amount > 0 else { return false }
        let monthlyEquivalent = amount * (cycleHint ?? .monthly).perYear / 12.0
        let ceiling: Double
        let floor: Double   // below this, it's a fee/rounding artifact, not a sub
        switch currency ?? "USD" {
        case "INR": ceiling = 80_000;  floor = 15
        case "JPY": ceiling = 200_000; floor = 100
        default:    ceiling = 1_500;   floor = 1   // USD / EUR / GBP / CAD / AUD
        }
        // A "$0.49/mo" reads as broken — it's a card-fee line or a parse artifact,
        // not a subscription. Require a sane minimum as well as a ceiling.
        return monthlyEquivalent >= floor && monthlyEquivalent <= ceiling
    }

    /// True only for a trial CONVERTING to paid (the "act now" signal), NOT for
    /// marketing inviting you to *start* a trial. Excludes start-invites and
    /// matches precise ending phrases, so "Start your free trial!" is not flagged.
    static func isTrialEnding(_ lowerSubject: String) -> Bool {
        let startInvites = ["start your free trial", "start a free trial",
                            "try it free", "try free", "begin your free trial",
                            "get started with a free trial", "claim your free trial"]
        if startInvites.contains(where: { lowerSubject.contains($0) }) { return false }

        // NOTE: no "will be charged" — that's a NORMAL renewal notice, not a trial
        // converting; it was flagging every renewal as an "act now" trial.
        let trialEnding = [
            "trial ends", "trial ending", "trial is ending", "trial will end",
            "trial expires", "trial expiring", "trial has ended", "trial ended",
            "end of your trial", "end of your free trial", "trial is about to",
            "last day of your", "your trial is", "before your trial",
            "convert to a paid", "convert to paid",
        ]
        return trialEnding.contains { lowerSubject.contains($0) }
    }

    static func parseCycle(from lowerSubject: String) -> BillingCycle? {
        // Annual phrasings MUST be checked before "month", or "12 months" / "for
        // the year" fall through to monthly and the yearly total inflates 12x.
        if lowerSubject.contains("annual") || lowerSubject.contains("yearly")
            || lowerSubject.contains("per year") || lowerSubject.contains("/year")
            || lowerSubject.contains("/yr") || lowerSubject.contains("per annum")
            || lowerSubject.contains("for the year") || lowerSubject.contains("1 year")
            || lowerSubject.contains("one year") || lowerSubject.contains("12 months")
            || lowerSubject.contains("12-month") || lowerSubject.contains("12 month") { return .yearly }
        if lowerSubject.contains("quarter") { return .quarterly }
        if lowerSubject.contains("week") { return .weekly }
        if lowerSubject.contains("month") || lowerSubject.contains("/mo")
            || lowerSubject.contains("monthly") { return .monthly }
        return nil
    }

    // MARK: - Amount parsing

    /// Recognized currency symbols/codes → ISO code.
    static let currencyMap: [(token: String, code: String)] = [
        ("$", "USD"), ("US$", "USD"), ("usd", "USD"),
        ("€", "EUR"), ("eur", "EUR"),
        ("£", "GBP"), ("gbp", "GBP"),
        ("₹", "INR"), ("inr", "INR"), ("rs.", "INR"), ("rs ", "INR"),
        ("¥", "JPY"), ("jpy", "JPY"),
        ("c$", "CAD"), ("cad", "CAD"),
        ("a$", "AUD"), ("aud", "AUD"),
    ]

    /// Parse the first plausible monetary amount from text. Returns the value
    /// and an ISO currency code (defaulting to USD when only a bare number
    /// follows a known currency word). Returns (nil, nil) if nothing found.
    ///
    /// Handles "$15.99", "USD 15.99", "15,99 €", "₹499", "Rs. 1,499.00".
    static func parseAmount(from text: String) -> (Double?, String?) {
        let lower = text.lowercased()
        let chars = Array(lower)

        // Collect EVERY currency-symbol occurrence with its position, not just the
        // first one in a fixed symbol order. "Total ₹499 (approx $6)" has both, and
        // the old code always took the $ (first in the map) even though ₹499 is the
        // real charge.
        var anchors: [(offset: Int, token: String, code: String)] = []
        for (token, code) in currencyMap {
            var from = lower.startIndex
            while let r = lower.range(of: token, range: from..<lower.endIndex) {
                anchors.append((lower.distance(from: lower.startIndex, to: r.lowerBound), token, code))
                from = r.upperBound
            }
        }
        guard !anchors.isEmpty else { return (nil, nil) }

        // A cue that this is the amount CHARGED (vs a discount/approx conversion).
        let positiveCues = ["total", "charged", "amount due", "you paid", "amount paid",
                            "billed", "payment of", "grand total"]

        var best: (amount: Double, code: String, score: Int, offset: Int)?
        for a in anchors {
            guard let idx = lower.index(lower.startIndex, offsetBy: a.offset, limitedBy: lower.endIndex) else { continue }
            let tokEnd = lower.index(idx, offsetBy: a.token.count, limitedBy: lower.endIndex) ?? lower.endIndex
            // Prefer the number right after the symbol; fall back to just before it.
            var value = firstNumber(in: String(lower[tokEnd...].prefix(16)))
            if value == nil {
                let beforeStart = lower.index(idx, offsetBy: -16, limitedBy: lower.startIndex) ?? lower.startIndex
                value = firstNumber(in: String(lower[beforeStart..<idx]), takeLast: true)
            }
            guard let v = value else { continue }
            // Score using ONLY the text immediately before the symbol ("total $49.99"),
            // so the cue attaches to the amount it labels, not to every nearby amount.
            let ctx = String(chars[max(0, a.offset - 16)..<a.offset])
            let score = positiveCues.contains(where: { ctx.contains($0) }) ? 2 : 0
            // Highest score wins; ties go to the earliest amount (usually the main one).
            if best == nil || score > best!.score || (score == best!.score && a.offset < best!.offset) {
                best = (v, a.code, score, a.offset)
            }
        }
        guard let b = best else { return (nil, nil) }
        return (b.amount, b.code)
    }

    /// Extract the first (or last) decimal number from a short string, handling
    /// both "1,234.56" (US) and "1.234,56" / "15,99" (EU) groupings.
    static func firstNumber(in text: String, takeLast: Bool = false) -> Double? {
        var matches: [Double] = []
        var current = ""
        func flush() {
            if !current.isEmpty {
                if let v = normalizeNumber(current) { matches.append(v) }
                current = ""
            }
        }
        for ch in text {
            if ch.isNumber || ch == "," || ch == "." {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        // Drop bare separators / empty captures.
        matches = matches.filter { $0 > 0 }
        guard !matches.isEmpty else { return nil }
        return takeLast ? matches.last : matches.first
    }

    /// Normalize a numeric token with either US or EU grouping into a Double.
    static func normalizeNumber(_ token: String) -> Double? {
        var s = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        guard !s.isEmpty else { return nil }
        let hasComma = s.contains(",")
        let hasDot = s.contains(".")
        if hasComma && hasDot {
            // The rightmost separator is the decimal point.
            if s.lastIndex(of: ",")! > s.lastIndex(of: ".")! {
                // EU: "1.234,56" → remove dots, comma→dot.
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                // US: "1,234.56" → remove commas.
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if hasComma {
            // Only commas: decimal comma ("15,99") if exactly 2 trailing digits,
            // else thousands grouping ("1,499").
            let parts = s.split(separator: ",")
            if let last = parts.last, last.count == 2, parts.count <= 2 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }
        return Double(s)
    }

    // MARK: - Renewal date parsing

    /// Best-effort parse of a renewal/charge date mentioned in the subject,
    /// e.g. "renews on May 3", "next billing date 2026-06-01". Year is inferred
    /// (next occurrence on/after the email date) when omitted.
    static func parseRenewalDate(from subject: String, relativeTo base: Date) -> Date? {
        let lower = subject.lowercased()
        // Only bother if the subject references renewal/billing timing.
        guard lower.contains("renew") || lower.contains("next") || lower.contains("bill")
            || lower.contains("charge") || lower.contains("on ") else { return nil }

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current

        // ISO yyyy-mm-dd
        if let r = subject.range(of: #"(\d{4})-(\d{2})-(\d{2})"#, options: .regularExpression) {
            let parts = subject[r].split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let d = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                return d
            }
        }

        // "Month Day" (e.g. "May 3", "June 12th")
        let months = ["january","february","march","april","may","june","july",
                      "august","september","october","november","december"]
        for (idx, name) in months.enumerated() {
            let short = String(name.prefix(3))
            guard lower.contains(name) || lower.contains(short) else { continue }
            let pattern = "(?:\(name)|\(short))\\.?\\s+(\\d{1,2})"
            if let r = lower.range(of: pattern, options: .regularExpression),
               let dayMatch = lower[r].range(of: #"\d{1,2}"#, options: .regularExpression),
               let day = Int(lower[dayMatch]) {
                let baseYear = cal.component(.year, from: base)
                for year in [baseYear, baseYear + 1] {
                    if let d = cal.date(from: DateComponents(year: year, month: idx + 1, day: day)),
                       d >= cal.startOfDay(for: base) {
                        return d
                    }
                }
            }
        }
        return nil
    }
}
