import Foundation

/// A drafted reply the user can edit before sending. Built entirely on-device
/// from the original email. `body` is what the model wrote — editable in the
/// composer; everything else addresses the message.
struct ReplyDraft: Equatable, Sendable {
    let recipientEmail: String?
    let recipientName: String
    let originalSubject: String
    var body: String

    /// "Re: …" subject, collapsing any existing reply/forward prefixes so we
    /// never produce "Re: Re: Fwd: …".
    var replySubject: String {
        var s = originalSubject
        while let r = s.range(of: #"^\s*(re|fwd|fw)\s*:\s*"#,
                              options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Re:" : "Re: \(trimmed)"
    }

    /// Pull a bare `user@host` address out of a sender field that might be
    /// "Name <user@host>", a bare address, or nil.
    static func extractEmail(from raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let lt = raw.firstIndex(of: "<"), let gt = raw.firstIndex(of: ">"), lt < gt {
            let inner = String(raw[raw.index(after: lt)..<gt])
                .trimmingCharacters(in: .whitespaces)
            if inner.contains("@") { return inner }
        }
        if let token = raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .first(where: { $0.contains("@") }) {
            return String(token).trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        }
        return raw.contains("@") ? raw : nil
    }
}

/// Tone presets the user can re-roll a draft with — the "make it shorter /
/// warmer / more formal" affordance.
enum ReplyTone: String, CaseIterable, Sendable {
    case balanced, shorter, warmer, formal

    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .shorter:  return "Shorter"
        case .warmer:   return "Warmer"
        case .formal:   return "Formal"
        }
    }

    /// Length/voice guidance appended to the drafting instructions.
    var guidance: String {
        switch self {
        case .balanced: return "Keep it to 2 to 4 short sentences, natural and direct."
        case .shorter:  return "Keep it to 1-2 short sentences. Get straight to the point."
        case .warmer:   return "Warm and friendly, 2-4 sentences. A personal touch is welcome."
        case .formal:   return "Professional and polished, 2-4 sentences. No slang or emoji."
        }
    }
}
