import Foundation

/// A compact picture of HOW the user writes, learned from their Sent mail, so
/// drafts sound like them (their greeting, sign-off, length, formality, emoji) -
/// the "voice-matched drafting" that Superhuman/Shortwave charge for. Learned
/// DETERMINISTICALLY (code extracts the facts; the model just writes in that voice).
struct StyleProfile: Codable, Equatable, Sendable {
    enum Length: String, Codable, Sendable { case veryShort, short, medium }
    enum Formality: String, Codable, Sendable { case casual, neutral, formal }

    var greeting: String?     // "Hi", "Hey", "Hello", ... (their usual opener)
    var signOff: String?      // "Thanks", "Best", "Cheers", ... (their usual closer)
    var length: Length
    var usesEmoji: Bool
    var formality: Formality
    var sampleCount: Int      // how many sent emails it was learned from

    static let empty = StyleProfile(greeting: nil, signOff: nil, length: .short,
                                    usesEmoji: false, formality: .neutral, sampleCount: 0)

    /// Only trust the profile once it's seen enough of the user's own writing.
    var hasSignal: Bool { sampleCount >= 3 }

    /// Instruction fragment telling the drafting model to mirror this voice.
    var styleClause: String {
        guard hasSignal else { return "" }
        var bits: [String] = []
        if let g = greeting { bits.append("they usually open with \"\(g)\" then the first name") }
        switch length {
        case .veryShort: bits.append("they keep replies to about one sentence")
        case .short:     bits.append("they keep replies to 1-2 short sentences")
        case .medium:    bits.append("they write 2-3 sentences")
        }
        switch formality {
        case .casual: bits.append("casual, friendly wording with contractions")
        case .neutral: bits.append("warm but plain wording")
        case .formal:  bits.append("polished, professional wording")
        }
        if usesEmoji { bits.append("an occasional emoji fits their style") }
        if let s = signOff { bits.append("they close with \"\(s)\" (no name - the app adds that)") }
        return "MATCH THE USER'S OWN VOICE, learned from their sent mail: " +
               bits.joined(separator: "; ") +
               ". Make the reply sound like them, not like generic AI."
    }
}

/// Deterministic style extraction from sent messages (pure + testable).
enum StyleLearner {
    static func profile(fromSent sent: [MailMessage]) -> StyleProfile {
        var greetings: [String: Int] = [:]
        var signoffs: [String: Int] = [:]
        var sentenceCounts: [Int] = []
        var emojiN = 0, casualN = 0, formalN = 0, n = 0

        for m in sent {
            let body = ownText(m.snippet ?? "")
            guard body.count >= 10 else { continue }
            n += 1
            let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let first = lines.first, let g = greeting(in: first) { greetings[g, default: 0] += 1 }
            if let s = signOff(in: lines) { signoffs[s, default: 0] += 1 }
            sentenceCounts.append(sentenceCount(body))
            if hasEmoji(body) { emojiN += 1 }
            casualN += casualScore(body)
            formalN += formalScore(body)
        }
        guard n > 0 else { return .empty }

        let med = median(sentenceCounts)
        let length: StyleProfile.Length = med <= 1 ? .veryShort : (med <= 3 ? .short : .medium)
        let formality: StyleProfile.Formality =
            casualN > formalN + 1 ? .casual : (formalN > casualN + 1 ? .formal : .neutral)
        return StyleProfile(
            greeting: topKey(greetings, total: n, minShare: 0.34),
            signOff: topKey(signoffs, total: n, minShare: 0.34),
            length: length,
            usesEmoji: emojiN * 3 >= n,          // ~a third of emails carry an emoji
            formality: formality,
            sampleCount: n
        )
    }

    // MARK: - Extractors (pure)

    /// The user's OWN text from a sent body: everything before quoted history /
    /// forwarded original / their client signature.
    static func ownText(_ body: String) -> String {
        var kept: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let l = line.trimmingCharacters(in: .whitespaces).lowercased()
            if l.hasPrefix(">") { break }
            if l.hasPrefix("on ") && l.contains(" wrote:") { break }
            if l.hasPrefix("-----original") || l.hasPrefix("________") { break }
            if l.hasPrefix("from:") && kept.count > 0 { break }
            if l.hasPrefix("sent from my ") || l.hasPrefix("get outlook for") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func greeting(in line: String) -> String? {
        let l = line.lowercased()
        let map: [(String, String)] = [
            ("good morning", "Good morning"), ("good afternoon", "Good afternoon"),
            ("good evening", "Good evening"), ("hello", "Hello"), ("heya", "Heya"),
            ("hiya", "Hiya"), ("hey", "Hey"), ("hii", "Hi"), ("hi", "Hi"),
            ("dear", "Dear"), ("yo", "Yo"),
        ]
        for (k, v) in map where l == k || l.hasPrefix(k + " ") || l.hasPrefix(k + ",") {
            return v
        }
        return nil
    }

    static func signOff(in lines: [String]) -> String? {
        let map: [(String, String)] = [
            ("thanks so much", "Thanks so much"), ("thank you", "Thank you"),
            ("thanks", "Thanks"), ("thx", "Thanks"), ("best regards", "Best regards"),
            ("best", "Best"), ("regards", "Regards"), ("cheers", "Cheers"),
            ("talk soon", "Talk soon"), ("sincerely", "Sincerely"),
            ("warmly", "Warmly"), ("appreciate it", "Appreciate it"), ("ttyl", "Talk soon"),
        ]
        for line in lines.suffix(4).reversed() where line.count <= 24 {
            let l = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ,.!-–"))
            for (k, v) in map where l == k || l.hasPrefix(k) { return v }
        }
        return nil
    }

    static func sentenceCount(_ s: String) -> Int {
        let parts = s.split(whereSeparator: { ".!?".contains($0) })
            .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 }
        return max(1, parts.count)
    }

    static func hasEmoji(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isEmojiPresentation }
    }

    static func casualScore(_ s: String) -> Int {
        let l = s.lowercased()
        let markers = ["haha", "lol", " yeah", " yep", " nope", "gonna", "wanna", "cool",
                       "awesome", "no worries", " np ", " btw", "thanks!", "!!", " ya ", "sounds good"]
        var score = markers.reduce(0) { $0 + (l.contains($1) ? 1 : 0) }
        if s.contains("!") { score += 1 }
        return score
    }

    static func formalScore(_ s: String) -> Int {
        let l = s.lowercased()
        let markers = ["dear ", "sincerely", "regards", "please find", "kindly", "as per",
                       "i would like to", "furthermore", "please be advised", "at your earliest",
                       "do not hesitate", "i am writing to", "with reference to"]
        return markers.reduce(0) { $0 + (l.contains($1) ? 1 : 0) }
    }

    static func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }

    /// The most common value - but only if it's a genuine HABIT (a real share of
    /// emails and seen at least twice), else nil (don't force a style we didn't see).
    static func topKey(_ counts: [String: Int], total: Int, minShare: Double) -> String? {
        guard let best = counts.max(by: { $0.value < $1.value }),
              best.value >= 2, Double(best.value) >= Double(total) * minShare else { return nil }
        return best.key
    }
}

/// Persists the learned style so drafting is instant and stable across launches,
/// refreshed weekly.
enum StyleStore {
    private static let key = "novex.styleProfile"
    private static let dateKey = "novex.styleProfileLearnedAt"

    static func load() -> StyleProfile? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(StyleProfile.self, from: data) else { return nil }
        return p
    }

    static func save(_ p: StyleProfile) {
        UserDefaults.standard.set(try? JSONEncoder().encode(p), forKey: key)
        UserDefaults.standard.set(Date(), forKey: dateKey)
    }

    static var isStale: Bool {
        guard let d = UserDefaults.standard.object(forKey: dateKey) as? Date else { return true }
        return Date().timeIntervalSince(d) > 7 * 86_400
    }
}
