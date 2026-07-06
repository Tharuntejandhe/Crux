import Foundation

/// Reads the actual body text of a message from Apple Mail's `.emlx` files on
/// disk — the only reliable source (the body is NOT in the Envelope Index). This
/// is what lets the assistant understand real content instead of guessing from
/// the subject line.
///
/// Two parts: (1) LOCATE the file — Mail stores it at
/// `<mailbox>/Data/<reversed digits of rowid/1000>/Messages/<rowid>.emlx`, so we
/// compute that path and check each mailbox's Data dir (no expensive full walk),
/// and (2) PARSE it — strip the `.emlx` framing, then pull a clean text snippet
/// out of the RFC822/MIME body (text/plain preferred, else stripped text/html;
/// quoted-printable / base64 decoded).
enum BodyReader {
    private static let fm = FileManager.default

    /// The `…/Data` directories of every local mailbox. Found by walking the
    /// Mail tree but PRUNING at each Data dir, so we never enumerate the tens of
    /// thousands of message files inside them — bounded and quick.
    static func dataDirs(mailRoot: URL) -> [URL] {
        guard let en = fm.enumerator(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var dirs: [URL] = []
        for case let url as URL in en {
            if url.lastPathComponent == "Data" {
                dirs.append(url)
                en.skipDescendants()   // do NOT walk the message files inside
            }
        }
        return dirs
    }

    /// Mail nests messages by the digits of `rowid / 1000`, in REVERSE order:
    /// e.g. rowid 46136 → 46136/1000 = 46 → "6/4" → `Data/6/4/Messages/46136.emlx`.
    private static func subpath(for rowid: Int64) -> String {
        let q = rowid / 1000
        let digits = String(q).reversed().map(String.init)
        return digits.joined(separator: "/")
    }

    /// Locate the `.emlx` (or `.partial.emlx`) for a message id within the given
    /// Data dirs.
    static func emlxURL(for rowid: Int64, in dataDirs: [URL]) -> URL? {
        let sub = subpath(for: rowid)
        for dir in dataDirs {
            for ext in ["emlx", "partial.emlx"] {
                let url = dir.appendingPathComponent("\(sub)/Messages/\(rowid).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Find + read + parse a clean body snippet for a message, or nil.
    static func bodySnippet(for rowid: Int64, in dataDirs: [URL], maxChars: Int = 600) -> String? {
        guard let url = emlxURL(for: rowid, in: dataDirs),
              let data = try? Data(contentsOf: url) else { return nil }
        return extractBody(from: data, maxChars: maxChars)
    }

    /// Pull the best unsubscribe target out of a message's `List-Unsubscribe`
    /// header (which lives in the .emlx, not the index). Prefers an https link
    /// (one-click in the browser); falls back to a `mailto:`. nil if absent.
    static func unsubscribeURL(for rowid: Int64, in dataDirs: [URL]) -> URL? {
        guard let url = emlxURL(for: rowid, in: dataDirs),
              let data = try? Data(contentsOf: url),
              var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else { return nil }
        if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        let (headers, _) = splitHeadersBody(text)
        guard let raw = headerValue("list-unsubscribe", in: headers) else { return nil }
        return parseUnsubscribe(raw)
    }

    /// Parse a `List-Unsubscribe` header value (e.g.
    /// `<https://x.com/u?id=1>, <mailto:u@x.com>`) into the best actionable URL.
    /// Pure + testable.
    static func parseUnsubscribe(_ raw: String) -> URL? {
        // Pull out every `<...>` token; some senders omit the brackets.
        var tokens: [String] = []
        var current = ""
        var inside = false
        for ch in raw {
            if ch == "<" { inside = true; current = "" }
            else if ch == ">" { inside = false; if !current.isEmpty { tokens.append(current) } }
            else if inside { current.append(ch) }
        }
        if tokens.isEmpty {
            tokens = raw.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        }
        let trimmed = tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Prefer https, then http, then mailto - never open a plaintext http link
        // when a secure one is offered in the same header.
        if let s = trimmed.first(where: { $0.lowercased().hasPrefix("https://") }) {
            return URL(string: s)
        }
        if let h = trimmed.first(where: { $0.lowercased().hasPrefix("http://") }) {
            return URL(string: h)
        }
        if let m = trimmed.first(where: { $0.lowercased().hasPrefix("mailto:") }) {
            return URL(string: m)
        }
        return nil
    }

    // MARK: - Parsing

    /// Strip the `.emlx` framing (a leading byte-count line + a trailing Apple
    /// plist), then extract readable body text from the RFC822 message.
    static func extractBody(from emlx: Data, maxChars: Int) -> String? {
        guard var text = String(data: emlx, encoding: .utf8)
            ?? String(data: emlx, encoding: .isoLatin1) else { return nil }
        // Drop the leading byte-count line.
        if let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        // Drop the trailing Apple plist metadata.
        if let r = text.range(of: "<?xml", options: .backwards) {
            text = String(text[..<r.lowerBound])
        }
        return extractFromRFC822(text, maxChars: maxChars)
    }

    private static func extractFromRFC822(_ message: String, maxChars: Int) -> String? {
        let (headers, body) = splitHeadersBody(message)
        let contentType = headerValue("content-type", in: headers)?.lowercased() ?? "text/plain"

        if contentType.contains("multipart"), let boundary = boundary(from: contentType) {
            // Prefer the plain-text part, else the HTML part (stripped).
            let parts = body.components(separatedBy: "--\(boundary)")
            for preferred in ["text/plain", "text/html"] {
                for part in parts {
                    let (ph, pb) = splitHeadersBody(part)
                    let pct = headerValue("content-type", in: ph)?.lowercased() ?? ""
                    guard pct.contains(preferred) else { continue }
                    let enc = headerValue("content-transfer-encoding", in: ph)?.lowercased() ?? ""
                    var txt = decode(pb, encoding: enc)
                    if preferred == "text/html" { txt = stripHTML(txt) }
                    let clean = cleanWhitespace(txt)
                    if clean.count >= 8 { return String(clean.prefix(maxChars)) }
                }
            }
            return nil
        } else {
            let enc = headerValue("content-transfer-encoding", in: headers)?.lowercased() ?? ""
            var txt = decode(body, encoding: enc)
            if contentType.contains("text/html") { txt = stripHTML(txt) }
            let clean = cleanWhitespace(txt)
            return clean.count >= 8 ? String(clean.prefix(maxChars)) : nil
        }
    }

    // MARK: - Helpers

    private static func splitHeadersBody(_ s: String) -> (headers: String, body: String) {
        if let r = s.range(of: "\r\n\r\n") {
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }
        if let r = s.range(of: "\n\n") {
            return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
        }
        return (s, "")
    }

    /// Value of a header (handles simple folded headers on the next indented line).
    private static func headerValue(_ name: String, in headers: String) -> String? {
        let lower = name.lowercased() + ":"
        var value: String?
        for raw in headers.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if value != nil {
                // Continuation (folded) line starts with whitespace.
                if line.first == " " || line.first == "\t" {
                    value! += " " + line.trimmingCharacters(in: .whitespaces)
                    continue
                } else { break }
            }
            if line.lowercased().hasPrefix(lower) {
                value = String(line.dropFirst(lower.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }

    private static func boundary(from contentType: String) -> String? {
        guard let r = contentType.range(of: "boundary=") else { return nil }
        var b = String(contentType[r.upperBound...])
        if let semi = b.firstIndex(of: ";") { b = String(b[..<semi]) }
        b = b.trimmingCharacters(in: .whitespaces)
        b = b.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return b.isEmpty ? nil : b
    }

    private static func decode(_ s: String, encoding: String) -> String {
        if encoding.contains("quoted-printable") { return decodeQuotedPrintable(s) }
        if encoding.contains("base64") {
            let joined = s.components(separatedBy: .whitespacesAndNewlines).joined()
            if let d = Data(base64Encoded: joined),
               let t = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .isoLatin1) {
                return t
            }
            return s
        }
        return s
    }

    private static func decodeQuotedPrintable(_ s: String) -> String {
        // Build the raw BYTES first, then decode as UTF-8. Decoding each "=XX"
        // byte straight to a Character treats it as Latin-1, which mangles every
        // multi-byte UTF-8 sequence (the "Â â" mojibake).
        var bytes = [UInt8]()
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "=" {
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 2; continue }
                if i + 2 < chars.count, chars[i + 1] == "\r", chars[i + 2] == "\n" { i += 3; continue }
                if i + 2 < chars.count, let byte = UInt8(String([chars[i + 1], chars[i + 2]]), radix: 16) {
                    bytes.append(byte); i += 3; continue
                }
            }
            for b in String(c).utf8 { bytes.append(b) }
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</(script|style)>",
                                   with: " ", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
                        "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&zwnj;": ""]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: "&#[0-9]+;", with: " ", options: .regularExpression)
        return s
    }

    private static func cleanWhitespace(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")                                   // nbsp
         .replacingOccurrences(of: "[\u{200B}\u{200C}\u{200D}\u{FEFF}]", with: "", options: .regularExpression)  // zero-width spacers
         .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
         .replacingOccurrences(of: "(\\s*\\n\\s*)+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
