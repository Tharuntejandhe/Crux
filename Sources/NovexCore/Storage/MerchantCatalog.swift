import Foundation

/// A known recurring-billing merchant: how to recognize it and what it
/// typically costs. Entirely static + on-device — no network, no bank.
struct Merchant: Sendable {
    let key: String                 // stable identity, e.g. "netflix"
    let displayName: String         // "Netflix"
    let category: SubscriptionCategory
    let domains: [String]           // sender domains that identify it
    let nameTokens: [String]        // lowercased tokens to match in sender/subject
    let typicalMonthlyUSD: Double?  // typical price (for estimates); nil if too variable
    let defaultCycle: BillingCycle
}

/// Built-in catalog of the most common subscription services, covering the
/// long tail of what people actually forget they're paying for. Prices are
/// representative US list prices (2025–2026) used only as *estimates* when we
/// can't parse a real amount from the email — always shown as "est." in the UI.
///
/// This is intentionally a curated static table: it costs nothing, runs
/// offline, and is trivially unit-testable. Unknown senders still get detected
/// by the generic keyword heuristics in `SubscriptionDetector`.
enum MerchantCatalog {
    static let all: [Merchant] = [
        // Streaming
        .init(key: "netflix", displayName: "Netflix", category: .streaming,
              domains: ["netflix.com"], nameTokens: ["netflix"], typicalMonthlyUSD: 15.49, defaultCycle: .monthly),
        .init(key: "spotify", displayName: "Spotify", category: .streaming,
              domains: ["spotify.com"], nameTokens: ["spotify"], typicalMonthlyUSD: 11.99, defaultCycle: .monthly),
        .init(key: "youtube", displayName: "YouTube Premium", category: .streaming,
              domains: ["youtube.com"], nameTokens: ["youtube premium", "youtube music"], typicalMonthlyUSD: 13.99, defaultCycle: .monthly),
        .init(key: "disneyplus", displayName: "Disney+", category: .streaming,
              domains: ["disneyplus.com", "mail.disneyplus.com"], nameTokens: ["disney+", "disney plus"], typicalMonthlyUSD: 13.99, defaultCycle: .monthly),
        .init(key: "hulu", displayName: "Hulu", category: .streaming,
              domains: ["hulu.com"], nameTokens: ["hulu"], typicalMonthlyUSD: 17.99, defaultCycle: .monthly),
        .init(key: "max", displayName: "Max (HBO)", category: .streaming,
              domains: ["max.com", "hbomax.com"], nameTokens: ["hbo max", "hbomax"], typicalMonthlyUSD: 16.99, defaultCycle: .monthly),
        .init(key: "paramountplus", displayName: "Paramount+", category: .streaming,
              domains: ["paramountplus.com"], nameTokens: ["paramount+"], typicalMonthlyUSD: 12.99, defaultCycle: .monthly),
        .init(key: "peacock", displayName: "Peacock", category: .streaming,
              domains: ["peacocktv.com"], nameTokens: ["peacock"], typicalMonthlyUSD: 7.99, defaultCycle: .monthly),
        .init(key: "appletv", displayName: "Apple TV+", category: .streaming,
              domains: [], nameTokens: ["apple tv+"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),
        .init(key: "applemusic", displayName: "Apple Music", category: .streaming,
              domains: [], nameTokens: ["apple music"], typicalMonthlyUSD: 10.99, defaultCycle: .monthly),
        .init(key: "appleone", displayName: "Apple One", category: .streaming,
              domains: [], nameTokens: ["apple one"], typicalMonthlyUSD: 19.95, defaultCycle: .monthly),
        .init(key: "audible", displayName: "Audible", category: .streaming,
              domains: ["audible.com"], nameTokens: ["audible"], typicalMonthlyUSD: 14.95, defaultCycle: .monthly),
        .init(key: "twitch", displayName: "Twitch", category: .streaming,
              domains: ["twitch.tv"], nameTokens: ["twitch"], typicalMonthlyUSD: 5.99, defaultCycle: .monthly),

        // AI
        .init(key: "openai", displayName: "ChatGPT Plus", category: .ai,
              domains: ["openai.com"], nameTokens: ["chatgpt", "openai"], typicalMonthlyUSD: 20.0, defaultCycle: .monthly),
        .init(key: "anthropic", displayName: "Claude Pro", category: .ai,
              domains: ["anthropic.com"], nameTokens: ["claude"], typicalMonthlyUSD: 20.0, defaultCycle: .monthly),
        .init(key: "perplexity", displayName: "Perplexity Pro", category: .ai,
              domains: ["perplexity.ai"], nameTokens: ["perplexity"], typicalMonthlyUSD: 20.0, defaultCycle: .monthly),
        // NOTE: no bare "github.com" domain — it matched EVERY GitHub notification
        // (PR/issue mail) and mis-tagged it "GitHub Copilot". Identified by name only.
        .init(key: "copilot", displayName: "GitHub Copilot", category: .ai,
              domains: [], nameTokens: ["copilot", "github copilot"], typicalMonthlyUSD: 10.0, defaultCycle: .monthly),

        // Software / productivity
        .init(key: "adobe", displayName: "Adobe Creative Cloud", category: .software,
              domains: ["adobe.com"], nameTokens: ["adobe", "creative cloud"], typicalMonthlyUSD: 59.99, defaultCycle: .monthly),
        .init(key: "microsoft365", displayName: "Microsoft 365", category: .software,
              domains: ["microsoft.com"], nameTokens: ["microsoft 365", "office 365"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),
        .init(key: "notion", displayName: "Notion", category: .software,
              domains: ["notion.so", "mail.notion.so"], nameTokens: ["notion"], typicalMonthlyUSD: 10.0, defaultCycle: .monthly),
        .init(key: "grammarly", displayName: "Grammarly", category: .software,
              domains: ["grammarly.com"], nameTokens: ["grammarly"], typicalMonthlyUSD: 12.0, defaultCycle: .monthly),
        .init(key: "1password", displayName: "1Password", category: .software,
              domains: ["1password.com"], nameTokens: ["1password"], typicalMonthlyUSD: 2.99, defaultCycle: .monthly),
        .init(key: "canva", displayName: "Canva Pro", category: .software,
              domains: ["canva.com"], nameTokens: ["canva"], typicalMonthlyUSD: 12.99, defaultCycle: .monthly),
        .init(key: "zoom", displayName: "Zoom", category: .software,
              domains: ["zoom.us"], nameTokens: ["zoom"], typicalMonthlyUSD: 13.99, defaultCycle: .monthly),
        .init(key: "linkedin", displayName: "LinkedIn Premium", category: .software,
              domains: ["linkedin.com"], nameTokens: ["linkedin premium"], typicalMonthlyUSD: 39.99, defaultCycle: .monthly),
        .init(key: "squarespace", displayName: "Squarespace", category: .software,
              domains: ["squarespace.com"], nameTokens: ["squarespace"], typicalMonthlyUSD: 16.0, defaultCycle: .monthly),

        // Cloud / storage
        .init(key: "icloud", displayName: "iCloud+", category: .cloud,
              domains: [], nameTokens: ["icloud"], typicalMonthlyUSD: 2.99, defaultCycle: .monthly),
        .init(key: "googleone", displayName: "Google One", category: .cloud,
              domains: ["google.com"], nameTokens: ["google one"], typicalMonthlyUSD: 1.99, defaultCycle: .monthly),
        .init(key: "dropbox", displayName: "Dropbox", category: .cloud,
              domains: ["dropbox.com"], nameTokens: ["dropbox"], typicalMonthlyUSD: 11.99, defaultCycle: .monthly),
        .init(key: "backblaze", displayName: "Backblaze", category: .cloud,
              domains: ["backblaze.com"], nameTokens: ["backblaze"], typicalMonthlyUSD: 9.0, defaultCycle: .monthly),

        // News / reading
        .init(key: "nytimes", displayName: "The New York Times", category: .news,
              domains: ["nytimes.com"], nameTokens: ["new york times", "nytimes"], typicalMonthlyUSD: 17.0, defaultCycle: .monthly),
        .init(key: "medium", displayName: "Medium", category: .news,
              domains: ["medium.com"], nameTokens: ["medium"], typicalMonthlyUSD: 5.0, defaultCycle: .monthly),
        .init(key: "substack", displayName: "Substack", category: .news,
              domains: ["substack.com"], nameTokens: ["substack"], typicalMonthlyUSD: 8.0, defaultCycle: .monthly),
        .init(key: "wsj", displayName: "The Wall Street Journal", category: .news,
              domains: ["wsj.com", "dj.com"], nameTokens: ["wall street journal", "wsj"], typicalMonthlyUSD: 38.99, defaultCycle: .monthly),

        // Shopping / delivery
        .init(key: "amazonprime", displayName: "Amazon Prime", category: .shopping,
              domains: ["amazon.com"], nameTokens: ["amazon prime", "prime membership"], typicalMonthlyUSD: 14.99, defaultCycle: .monthly),
        .init(key: "walmartplus", displayName: "Walmart+", category: .shopping,
              domains: ["walmart.com"], nameTokens: ["walmart+"], typicalMonthlyUSD: 12.95, defaultCycle: .monthly),
        .init(key: "dashpass", displayName: "DoorDash DashPass", category: .shopping,
              domains: ["doordash.com"], nameTokens: ["dashpass"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),
        .init(key: "uberone", displayName: "Uber One", category: .shopping,
              domains: ["uber.com"], nameTokens: ["uber one"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),
        .init(key: "instacart", displayName: "Instacart+", category: .shopping,
              domains: ["instacart.com"], nameTokens: ["instacart+"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),
        .init(key: "costco", displayName: "Costco Membership", category: .shopping,
              domains: ["costco.com"], nameTokens: ["costco"], typicalMonthlyUSD: 5.0, defaultCycle: .yearly),

        // Gaming
        .init(key: "xboxgamepass", displayName: "Xbox Game Pass", category: .gaming,
              domains: ["xbox.com"], nameTokens: ["game pass"], typicalMonthlyUSD: 16.99, defaultCycle: .monthly),
        .init(key: "psplus", displayName: "PlayStation Plus", category: .gaming,
              domains: ["playstation.com", "sony.com"], nameTokens: ["playstation plus", "ps plus"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),
        .init(key: "nintendo", displayName: "Nintendo Switch Online", category: .gaming,
              domains: ["nintendo.com"], nameTokens: ["nintendo switch online"], typicalMonthlyUSD: 3.99, defaultCycle: .monthly),
        .init(key: "discord", displayName: "Discord Nitro", category: .gaming,
              domains: ["discord.com"], nameTokens: ["discord nitro", "nitro"], typicalMonthlyUSD: 9.99, defaultCycle: .monthly),

        // Fitness / wellness
        .init(key: "strava", displayName: "Strava", category: .fitness,
              domains: ["strava.com"], nameTokens: ["strava"], typicalMonthlyUSD: 11.99, defaultCycle: .monthly),
        .init(key: "calm", displayName: "Calm", category: .fitness,
              domains: ["calm.com"], nameTokens: ["calm"], typicalMonthlyUSD: 14.99, defaultCycle: .monthly),
        .init(key: "headspace", displayName: "Headspace", category: .fitness,
              domains: ["headspace.com"], nameTokens: ["headspace"], typicalMonthlyUSD: 12.99, defaultCycle: .monthly),
        .init(key: "peloton", displayName: "Peloton", category: .fitness,
              domains: ["onepeloton.com"], nameTokens: ["peloton"], typicalMonthlyUSD: 44.0, defaultCycle: .monthly),

        // Payment processors (generic — identify the receipt even if the
        // underlying merchant is unknown; the detector refines the name).
        .init(key: "paypal", displayName: "PayPal", category: .finance,
              domains: ["paypal.com"], nameTokens: [], typicalMonthlyUSD: nil, defaultCycle: .unknown),
    ]

    /// Index by domain for O(1) sender lookup. Computed once.
    static let byDomain: [String: Merchant] = {
        var map: [String: Merchant] = [:]
        for m in all {
            for d in m.domains { map[d] = m }
        }
        return map
    }()

    /// Domains that sell a flagship subscription AND countless one-off items from
    /// the SAME address (Amazon order, Google Play game, Microsoft Store purchase).
    /// A bare receipt from them is usually a one-off, so mail from these is only
    /// treated as the subscription when the product is actually NAMED (see match()).
    static let storefrontDomains: Set<String> = ["amazon.com", "google.com", "microsoft.com"]

    static func isStorefrontDomain(_ domain: String) -> Bool {
        storefrontDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    /// Match a sender address + subject to a known merchant, if any.
    /// Tries exact/suffix domain match first (most reliable), then name tokens.
    static func match(senderAddress: String?, senderName: String?, subject: String, body: String? = nil) -> Merchant? {
        if let domain = emailDomain(senderAddress) {
            // Storefront guard (Amazon/Google/Microsoft): only map to the flagship
            // subscription when its product is NAMED in the subject/body (like the
            // Apple path). A bare order/game/app receipt returns nil so it is never
            // listed as "Amazon Prime $27.49/mo".
            if let store = storefrontDomains.first(where: { domain == $0 || domain.hasSuffix("." + $0) }),
               let m = byDomain[store] {
                let hay = (subject + " " + (body ?? "")).lowercased()
                return m.nameTokens.contains { !$0.isEmpty && hay.contains($0) } ? m : nil
            }
            if let exact = byDomain[domain] { return exact }
            // Suffix match: "email.netflix.com" → "netflix.com".
            for (d, m) in byDomain where domain == d || domain.hasSuffix("." + d) {
                return m
            }
            // Apple bills iCloud+/Music/TV+/One from ONE address (no_reply@apple.com),
            // naming the product only in the receipt BODY. The sender is verified-Apple
            // (not arbitrary), so reading the product token from subject+body is safe
            // here — unlike the general path below, which must never trust subject text
            // from an unknown sender. Non-subscription Apple mail returns nil.
            if isAppleDomain(domain), let m = matchAppleProduct(subject: subject, body: body) {
                return m
            }
        }
        // Name tokens match the SENDER NAME / address only — NOT the subject.
        // Matching arbitrary subject text manufactured subscriptions from ordinary
        // mail (a PR titled "...max..." became a paid plan). The sender identifies
        // the merchant; the subject is just what they wrote about.
        let haystack = "\(senderName ?? "") \(senderAddress ?? "")".lowercased()
        for m in all {
            for token in m.nameTokens where !token.isEmpty && haystack.contains(token) {
                return m
            }
        }
        return nil
    }

    /// Apple's billing domains — receipts come from no_reply@apple.com,
    /// email.apple.com, itunes.com, etc.
    private static func isAppleDomain(_ domain: String) -> Bool {
        domain == "apple.com" || domain.hasSuffix(".apple.com")
            || domain == "itunes.com" || domain.hasSuffix(".itunes.com")
    }

    /// The specific Apple subscription named in a verified-Apple receipt's
    /// subject+body, or nil for non-subscription Apple mail (one-time App Store
    /// purchases, order confirmations) so those are never listed as subscriptions.
    private static func matchAppleProduct(subject: String, body: String?) -> Merchant? {
        let hay = (subject + " " + (body ?? "")).lowercased()
        // The bundle ("apple one") is checked before its components.
        let products: [(key: String, tokens: [String])] = [
            ("appleone",   ["apple one"]),
            ("applemusic", ["apple music"]),
            ("appletv",    ["apple tv+", "apple tv plus"]),
            ("icloud",     ["icloud+", "icloud plus", "icloud storage", "icloud"]),
        ]
        for p in products where p.tokens.contains(where: { hay.contains($0) }) {
            if let m = all.first(where: { $0.key == p.key }) { return m }
        }
        return nil
    }

    /// Lowercased domain portion of an email address, or nil.
    static func emailDomain(_ address: String?) -> String? {
        guard let address, let at = address.lastIndex(of: "@") else { return nil }
        let domain = address[address.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return domain.isEmpty ? nil : domain
    }

    /// Where to go to cancel each known service. Static + offline; opening one
    /// just sends the user's own browser to a public account page (the APP still
    /// makes no network calls). For unknown merchants we fall back to a search.
    static let cancelURLs: [String: String] = [
        "netflix": "https://www.netflix.com/cancelplan",
        "spotify": "https://www.spotify.com/account/subscription/",
        "youtube": "https://www.youtube.com/paid_memberships",
        "disneyplus": "https://www.disneyplus.com/account/subscription",
        "hulu": "https://secure.hulu.com/account",
        "max": "https://play.max.com/settings/subscription",
        "paramountplus": "https://www.paramountplus.com/account/",
        "peacock": "https://www.peacocktv.com/account/plans",
        "appletv": "https://tv.apple.com/settings",
        "applemusic": "https://music.apple.com/account/subscriptions",
        "audible": "https://www.audible.com/account/membership-details",
        "openai": "https://chatgpt.com/#settings",
        "anthropic": "https://claude.ai/settings/billing",
        "perplexity": "https://www.perplexity.ai/settings/account",
        "copilot": "https://github.com/settings/billing",
        "adobe": "https://account.adobe.com/plans",
        "microsoft365": "https://account.microsoft.com/services",
        "notion": "https://www.notion.so/my-account",
        "grammarly": "https://account.grammarly.com/subscription",
        "1password": "https://my.1password.com/billing",
        "canva": "https://www.canva.com/settings/billing-and-teams",
        "linkedin": "https://www.linkedin.com/premium/manage/",
        "squarespace": "https://account.squarespace.com/",
        "nytimes": "https://www.nytimes.com/subscription",
        "medium": "https://medium.com/me/settings/membership",
        "substack": "https://substack.com/settings",
        "amazonprime": "https://www.amazon.com/gp/primecentral",
        "walmartplus": "https://www.walmart.com/plus",
        "icloud": "https://support.apple.com/en-us/HT207594",
        "googleone": "https://one.google.com/settings",
        "dropbox": "https://www.dropbox.com/account/plan",
        "xboxgamepass": "https://account.microsoft.com/services",
        "psplus": "https://www.playstation.com/subscriptions",
        "discord": "https://discord.com/settings/premium",
        "strava": "https://www.strava.com/settings/profile",
        "calm": "https://www.calm.com/profile",
        "headspace": "https://www.headspace.com/subscription",
        "peloton": "https://members.onepeloton.com/preferences/subscriptions",
        "paypal": "https://www.paypal.com/myaccount/autopay/",
    ]

    /// A URL where the user can cancel this service — a known account page, or a
    /// web search as a fallback.
    static func cancelURL(forKey key: String, displayName: String) -> URL? {
        if let s = cancelURLs[key], let u = URL(string: s) { return u }
        let q = "how to cancel \(displayName) subscription"
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "cancel+subscription"
        return URL(string: "https://www.google.com/search?q=\(enc)")
    }
}
