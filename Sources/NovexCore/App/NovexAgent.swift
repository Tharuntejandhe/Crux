import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// A clear action the user asked for in plain language. Detected DETERMINISTICALLY
/// (see ActionParser) - never by the small on-device model, which cannot be trusted
/// to only act when asked (in testing it dismissed real mail in response to plain
/// questions). The model reads and answers; code decides and acts.
enum ActionIntent: Equatable {
    case draft(targetHint: String, intent: String)   // "reply to X saying Y"
    case dismiss(targetHint: String)                 // "clear the X notifications"
    case snooze(targetHint: String, preset: SnoozePreset)   // "remind me about X tomorrow"
}

/// High-precision classifier for action requests. Returns nil for anything that
/// isn't UNAMBIGUOUSLY an action (questions, chit-chat) so those flow to Q&A. Pure.
enum ActionParser {
    // A request that STARTS with one of these is a question, never an action.
    private static let interrogatives: Set<String> = ["did","do","does","is","are","was","were",
        "have","has","had","can't","cant","any","anything","what","whats","what's","when","where",
        "who","whos","who's","why","how","which","whose","whom","should","will there"]
    // Strip these lead-ins so "can you reply to X" reads as a command, not a question.
    private static let politePrefixes = ["please ", "pls ", "hey novex ", "ok novex ", "novex ",
        "hey ", "can you please ", "can you ", "could you please ", "could you ", "would you please ",
        "would you ", "will you ", "i want you to ", "i'd like you to ", "i need you to ", "go ahead and "]
    static let clutterWords: Set<String> = ["promotion","promotions","promo","promos","newsletter",
        "newsletters","spam","junk","ad","ads","subscription","subscriptions","marketing"]

    static func classify(_ q: String) -> ActionIntent? {
        var lower = q.lowercased().trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for p in politePrefixes where lower.hasPrefix(p) {
                lower = String(lower.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true; break
            }
        }
        // A genuine question is never an action ("did I forget to reply to anyone?").
        let firstWord = lower.split(separator: " ").first.map(String.init) ?? ""
        if interrogatives.contains(firstWord) { return nil }

        if let d = draftMatch(lower) { return .draft(targetHint: d.0, intent: d.1) }
        if let hint = dismissMatch(lower) { return .dismiss(targetHint: hint) }
        if let s = snoozeMatch(lower) { return .snooze(targetHint: s.0, preset: s.1) }
        return nil
    }

    /// Classify a request that may contain MORE THAN ONE action ("reply to Sarah and
    /// clear the newsletters"). Splits only where the second clause starts with an
    /// action verb, so intents that merely contain "and" ("saying I'll be there and
    /// ready") stay whole. Falls back to a single classify.
    static func classifyAll(_ q: String) -> [ActionIntent] {
        let lower = q.lowercased()
        let connectors = [" and then ", " then ", " and also ", " also ", " and ", "; ", ", then ", ", "]
        let actionStarts = ["reply ", "reply to ", "respond ", "write ", "tell ", "let ", "draft ",
                            "clear ", "mark ", "dismiss ", "archive ", "delete ", "remove ",
                            "snooze ", "remind ", "hide ", "get back ", "get rid "]
        for c in connectors {
            guard let r = lower.range(of: c) else { continue }
            let secondLower = String(lower[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard actionStarts.contains(where: { secondLower.hasPrefix($0) }) else { continue }
            let first = String(q[..<q.index(q.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
            let second = String(q[q.index(q.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.upperBound))...])
            if let a = classify(first), let b = classify(second) { return [a, b] }
            break
        }
        return classify(q).map { [$0] } ?? []
    }

    /// "undo" / "restore" / "bring them back" - reverse the last dismiss or snooze.
    static func isUndo(_ q: String) -> Bool {
        let l = q.lowercased().trimmingCharacters(in: .whitespaces)
        let phrases = ["undo", "restore", "bring it back", "bring them back", "bring that back",
                       "put it back", "put them back", "never mind", "nevermind", "oops",
                       "un-dismiss", "undismiss", "unclear", "wait no"]
        return phrases.contains { l == $0 || l.hasPrefix($0 + " ") || l.hasSuffix(" " + $0) }
    }

    // MARK: draft

    private static func draftMatch(_ lower: String) -> (String, String)? {
        let verbs = ["draft a reply to ", "draft a response to ", "write back to ",
                     "reply to ", "respond to ", "get back to "]
        for v in verbs where lower.hasPrefix(v) {
            let (t, i) = splitTargetIntent(String(lower.dropFirst(v.count)))
            let hint = cleanTarget(t)
            if !hint.isEmpty { return (hint, i) }
        }
        // "tell <person> ..." but NOT "tell me/us/what..." (those are info requests).
        if lower.hasPrefix("tell ") {
            let rest = String(lower.dropFirst(5))
            let fw = rest.split(separator: " ").first.map(String.init) ?? ""
            let queryish: Set<String> = ["me","us","myself","what","who","when","whether","if","how","why","where","them"]
            if !queryish.contains(fw) {
                let (t, i) = splitTargetIntent(rest)
                let hint = cleanTarget(t)
                if !hint.isEmpty { return (hint, i) }
            }
        }
        // "let <person> know ..."
        if lower.hasPrefix("let "), let kr = lower.range(of: " know") {
            let target = cleanTarget(String(lower[lower.index(lower.startIndex, offsetBy: 4)..<kr.lowerBound]))
            var intent = String(lower[kr.upperBound...]).trimmingCharacters(in: .whitespaces)
            if intent.hasPrefix("that ") { intent = String(intent.dropFirst(5)) }
            if !target.isEmpty { return (target, intent) }
        }
        return nil
    }

    /// Split "X saying/that Y" into target X and intent Y.
    static func splitTargetIntent(_ s: String) -> (target: String, intent: String) {
        // Delimiters that are CONSUMED (the word "saying"/"that" isn't part of the intent).
        let cut = [" saying ", " to say ", " and say ", " that i'll ", " that i'm ", " that i ",
                   " that we'll ", " that we ", " that ", " telling them ", " telling ", ": "]
        for d in cut {
            if let r = s.range(of: d) {
                return (String(s[..<r.lowerBound]),
                        String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        // Pronoun starts ("tell mom I'll be home"): the pronoun BEGINS the intent, so
        // keep it ("i'll be home"), and everything before it is the target ("mom").
        let keep = [" i'll ", " i'm ", " we'll ", " we're ", " i ", " we "]
        for d in keep {
            if let r = s.range(of: d) {
                return (String(s[..<r.lowerBound]),
                        String(s[r.lowerBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (s, "")
    }

    // MARK: dismiss

    private static func dismissMatch(_ lower: String) -> String? {
        let verbs = ["mark ", "clear ", "dismiss ", "archive ", "get rid of ", "delete ", "remove "]
        for v in verbs where lower.hasPrefix(v) {
            let mailish = ["email","mail","notification","message","done","read","inbox","from ","alert"]
                .contains { lower.contains($0) } || clutterWords.contains { lower.contains($0) }
            guard mailish else { continue }
            let hint = cleanTarget(dismissClean(String(lower.dropFirst(v.count))))
            if !hint.isEmpty { return hint }
        }
        return nil
    }

    static func dismissClean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for suffix in [" as done", " as read", " done", " read"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    // MARK: snooze

    private static func snoozeMatch(_ lower: String) -> (String, SnoozePreset)? {
        let verbs = ["snooze ", "remind me about ", "remind me to look at ", "remind me of ", "hide "]
        guard let v = verbs.first(where: { lower.hasPrefix($0) }) else { return nil }
        var rest = String(lower.dropFirst(v.count))
        let preset = presetFrom(rest)
        for cut in [" until ", " till ", " til ", " again in ", " again ", " for "] {
            if let r = rest.range(of: cut) { rest = String(rest[..<r.lowerBound]); break }
        }
        // Strip a trailing preset phrase left without a connector ("snooze sarah tomorrow").
        for p in ["later today", "later", "tonight", "tomorrow", "this weekend", "the weekend",
                  "weekend", "next week", "monday", "in an hour", "in a bit"] where rest.hasSuffix(" " + p) {
            rest = String(rest.dropLast(p.count + 1)); break
        }
        let hint = cleanTarget(rest)
        return hint.isEmpty ? nil : (hint, preset)
    }

    /// Map a time phrase to the nearest built-in snooze preset (defaults to tomorrow).
    static func presetFrom(_ s: String) -> SnoozePreset {
        if s.contains("weekend") { return .thisWeekend }
        if s.contains("next week") || s.contains("monday") { return .nextWeek }
        if s.contains("later") || s.contains("tonight") || s.contains("hour") || s.contains("in a bit") { return .laterToday }
        return .tomorrow
    }

    // MARK: shared

    /// Strip articles / trailing mail-nouns and cut at " and " (multi-intent -> first
    /// target) so the remainder is clean search keywords.
    static func cleanTarget(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: " and ") { t = String(t[..<r.lowerBound]) }
        for a in ["the ", "my ", "that ", "this ", "an ", "a "] where t.hasPrefix(a) { t = String(t.dropFirst(a.count)) }
        for n in [" emails", " email", " messages", " message", " mail", " threads", " thread",
                  " notifications", " notification", " alerts", " alert", " one", " ones"] where t.hasSuffix(n) {
            t = String(t.dropLast(n.count))
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Whether a dismiss target means "the clutter" (promos/newsletters) rather than
    /// a specific sender/topic.
    static func isClutterTarget(_ hint: String) -> Bool {
        hint.isEmpty || clutterWords.contains { hint.contains($0) }
    }

    /// A "catch me up" / "what did I miss" request - answer with a deterministic
    /// inbox summary (counts + who needs a reply) rather than a fuzzy model search.
    static func isCatchUp(_ q: String) -> Bool {
        let l = q.lowercased()
        let phrases = ["catch me up", "catch up", "what did i miss", "what have i missed",
                       "whats new", "what's new", "anything new", "summarize my inbox",
                       "summarise my inbox", "summarize my email", "brief me", "give me a rundown",
                       "give me the rundown", "rundown", "recap", "what's happening", "whats happening",
                       "fill me in", "bring me up to speed", "the gist"]
        return phrases.contains { l == $0 || l.contains($0) }
    }

    /// A "what needs me / what's on my plate" planning question - the answer is
    /// grounded in the plate, so its citations should be the plate's emails.
    static func isPlanningQuestion(_ q: String) -> Bool {
        let l = q.lowercased()
        let phrases = ["what needs me", "needs me", "need to do", "what do i do", "what should i do",
                       "on my plate", "to-do", "to do today", "to do list", "anything for me",
                       "what's on my", "whats on my", "priorities", "what matters", "anything urgent",
                       "anything important", "what do i need", "what's important", "whats important",
                       "anything i should", "what's next", "whats next"]
        return phrases.contains { l.contains($0) }
    }

    /// Human psychology: people rarely ask plainly. "ugh so much spam" / "my inbox is
    /// a mess" isn't a question to search - it's a nudge for help. Detect it so we can
    /// offer the cleanup instead of literally searching for the word "spam".
    static func isClutterComplaint(_ q: String) -> Bool {
        let l = q.lowercased()
        if let fw = l.split(separator: " ").first.map(String.init), interrogatives.contains(fw) { return false }
        let phrases = ["so much spam", "so much junk", "so much mail", "so much clutter",
                       "too much spam", "too much junk", "so many email", "too many email",
                       "so many mail", "inbox is a mess", "messy inbox", "get so much",
                       "getting so much", "overwhelmed", "hate all these", "sick of these",
                       "clean up my inbox", "my inbox is full", "inbox is full", "drowning in"]
        return phrases.contains { l.contains($0) }
    }
}

/// Agentic on-device Q&A.
///
/// A small tool-use (ReAct) loop over the plain on-device model. The model can only
/// SEARCH the inbox and ANSWER - it CANNOT take actions (a small model can't be
/// trusted to act only when asked; in testing it dismissed real mail in reply to a
/// plain question). All actions go through the deterministic ActionParser instead.
/// It always sees a deterministic "what needs you" plate + inbox stats, so it never
/// sells an FYI as a to-do or miscounts. The model call is injected, so the whole
/// loop is deterministically testable with a scripted mock.
@available(macOS 26.0, *)
struct NovexAgent {
    let messages: [MailMessage]
    let mine: Set<String>
    let plate: String

    enum AgentError: Error { case unavailable }

    /// An answer plus the emails it was grounded in (the last search's hits), so the
    /// UI can offer "open the source" citations - the trust primitive the best
    /// assistants (Superhuman, Shortwave) all have.
    struct AgentReply: Equatable { let text: String; let sources: [MailMessage] }

    func answer(_ question: String) async throws -> AgentReply {
        #if canImport(FoundationModels)
        guard SystemLanguageModel.default.availability == .available else { throw AgentError.unavailable }
        let session = LanguageModelSession(instructions: Self.instructions(plate: plate, stats: statsLine))
        return try await run(question: question) { prompt in
            try await session.respond(to: prompt).content
        }
        #else
        throw AgentError.unavailable
        #endif
    }

    /// The Q&A loop, model-agnostic (live: a LanguageModelSession; tests: a mock).
    /// Answer-only: never returns or performs an action.
    func run(question: String, maxSteps: Int = 3,
             respond: (String) async throws -> String) async rethrows -> AgentReply {
        var prompt = Self.firstPrompt(question: question)
        var lastHits: [MailMessage] = []
        for _ in 0..<maxSteps {
            let out = try await respond(prompt)
            if let query = Self.extractSearch(out) {
                let found = InboxSearch.search(query: query, messages: messages, mine: mine)
                if !found.hits.isEmpty { lastHits = found.hits }   // remember for citations
                prompt = Self.resultsPrompt(query: query, results: found.text)
                continue
            }
            if let answer = Self.extractAnswer(out) { return AgentReply(text: answer, sources: lastHits) }
            return AgentReply(text: out, sources: lastHits)
        }
        let final = try await respond("Answer the user now in 1-2 short sentences from what you found. Start with ANSWER:")
        return AgentReply(text: Self.extractAnswer(final) ?? final, sources: lastHits)
    }

    var statsLine: String {
        let unread = messages.filter { !$0.isRead && !$0.isFromSelf(mine) }.count
        return "Inbox snapshot: \(unread) unread of \(messages.count) recent emails."
    }

    // MARK: - Prompts

    static func instructions(plate: String, stats: String) -> String {
        """
        You are Novex, the user's warm, concise on-device email assistant. You help ONLY with their email.

        To answer a question about their email, FIRST reply "SEARCH: <keywords>" (the key nouns from their question). I reply with the matching emails. Then reply "ANSWER: <your reply>". You may SEARCH again with different words if the first misses. If a search returns "No matching emails", ANSWER that you don't see anything about that in their recent mail. NEVER answer from unrelated mail and NEVER invent senders, subjects, amounts, or dates.

        Reply in 1-2 SHORT sentences, in your own words, like a friend who skimmed their inbox. No pasting email text, no bullet points, headers, greetings, or asterisks. Use the REAL sender names and subjects only.

        You can ONLY read and describe email. You CANNOT take actions here: NEVER claim you sent, drafted, replied to, cleared, dismissed, archived, deleted, scheduled, confirmed, handled, or took care of anything - only describe what is in the inbox. (When the user asks you to reply to or clear something, the app does that separately - you won't see it.)

        If the user asks about anything that is not their email (weather, news, sports, facts, math, code, trivia), reply with exactly this and nothing else: ANSWER: I can only help with your email.

        Here is a reliable, already-computed summary of what needs the user - each item tagged [bill to pay] / [needs a reply] / [action needed] / [to review]. Use it to answer questions about bills, replies owed, deadlines, or what to do:
        \(PromptSafety.fence(plate))
        \(stats)
        If they ask what needs them and the summary says nothing needs them, say so plainly.

        If they complain about spam, clutter, or too many emails, tell them they can say "clear the newsletters" or open the Cleanup tab.

        \(PromptSafety.noDashClause)

        \(PromptSafety.securityClause)
        """
    }

    static func firstPrompt(question: String) -> String {
        """
        The user (trusted) asks: \(question)

        Reply with SEARCH: <keywords> or ANSWER: <reply>.
        """
    }

    static func resultsPrompt(query: String, results: String) -> String {
        """
        Search results for "\(query)":
        \(PromptSafety.fence(results))

        Now reply with SEARCH: <new keywords> or ANSWER: <reply>.
        """
    }

    // MARK: - Parsing (pure, testable)

    static func extractSearch(_ s: String) -> String? {
        guard let r = s.range(of: "SEARCH:", options: .caseInsensitive) else { return nil }
        let after = s[r.upperBound...]
        let line = after.split(whereSeparator: \.isNewline).first.map(String.init) ?? String(after)
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? nil : q
    }

    static func extractAnswer(_ s: String) -> String? {
        guard let r = s.range(of: "ANSWER:", options: .caseInsensitive) else { return nil }
        let a = s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? nil : a
    }
}

/// Read-only inbox search shared by the agent + the deterministic action path.
/// Pure, no model, no FoundationModels dependency.
enum InboxSearch {
    /// Rank the inbox for `query` (with light synonym expansion) and return both a
    /// rendering for the model and the ordered messages. Honest: if the query has
    /// real terms but nothing matches, returns "No matching emails." + [].
    static func search(query: String, messages: [MailMessage], mine: Set<String>, limit: Int = 10)
        -> (text: String, hits: [MailMessage]) {
        let expanded = expand(query)
        let ranked = MailRetrieval.rank(question: expanded, messages: messages, limit: limit)
        let terms = queryTerms(expanded)
        let realMatch = terms.isEmpty || ranked.contains { m in
            let hay = (m.subject + " " + (m.snippet ?? "") + " " + m.senderDisplay).lowercased()
            return terms.contains { hay.contains($0) }
        }
        guard !ranked.isEmpty, realMatch else { return ("No matching emails.", []) }

        let hits = ranked.sorted { $0.dateReceived > $1.dateReceived }
        let now = Date()
        let rel = RelativeDateTimeFormatter()
        let text = hits.map { m -> String in
            let when = rel.localizedString(for: m.dateReceived, relativeTo: now)
            let read = m.isRead ? "" : " UNREAD"
            let sender = PromptSafety.sanitize(m.senderDisplay, maxChars: 48)
            let subject = PromptSafety.sanitize(String(m.subject.prefix(90)), maxChars: 90)
            let snip = PromptSafety.sanitize(String((m.snippet ?? "").prefix(120)), maxChars: 120)
            return "- (\(when))\(read)\(kind(of: m, mine: mine)) \(sender): \(subject)" + (snip.isEmpty ? "" : " - \(snip)")
        }.joined(separator: "\n")
        return (text, hits)
    }

    static func results(query: String, messages: [MailMessage], mine: Set<String>, limit: Int = 10) -> String {
        search(query: query, messages: messages, mine: mine, limit: limit).text
    }

    /// Expand a few common intents so keyword ranking finds the real mail:
    /// "bills/pay" also matches "invoice/payment/due"; clutter words match promos.
    static func expand(_ q: String) -> String {
        let l = q.lowercased()
        var extra: [String] = []
        if ["bill","bills","pay","paid","owe","owed","charge","charged","cost","subscription"].contains(where: l.contains) {
            extra += ["invoice", "payment", "due", "receipt", "$"]
        }
        if ActionParser.clutterWords.contains(where: l.contains) {
            extra += ["sale", "off", "deal", "unsubscribe"]
        }
        if ["meeting","meet","call","invite","schedule"].contains(where: l.contains) {
            extra += ["calendar", "invitation", "zoom"]
        }
        return extra.isEmpty ? q : q + " " + extra.joined(separator: " ")
    }

    static func kind(of m: MailMessage, mine: Set<String>) -> String {
        if m.isFromSelf(mine) { return " [your own note]" }
        if m.isEphemeralNotification { return " [FYI]" }
        switch m.deterministicAction(mine: mine, deadline: m.detectedDeadline) {
        case .reply:   return " [needs a reply]"
        case .pay:     return " [bill to pay]"
        case .confirm: return " [action needed]"
        case .review:  return " [to review]"
        default:       return m.unsubscribeType > 0 ? " [newsletter]" : ""
        }
    }

    private static let stop: Set<String> = ["the","and","for","you","your","did","does","what","when",
        "where","who","how","why","any","email","emails","mail","inbox","about","from",
        "have","has","was","were","there","that","this","with","are","get","got"]

    static func queryTerms(_ q: String) -> Set<String> {
        Set(q.lowercased()
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) })
    }
}
