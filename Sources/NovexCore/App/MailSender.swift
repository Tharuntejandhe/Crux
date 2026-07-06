import Foundation

/// Closes the loop: actually SENDS a reply (or archives a message) through Apple
/// Mail, using AppleScript / Apple Events. This is the ONLY component in Novex
/// that acts OUTWARD on the user's behalf, so it is deliberately tiny, explicit,
/// and NEVER invoked without a direct tap on a Send / Archive button in the UI.
/// It does not auto-send, retry, batch, or run on a timer.
///
/// Still 100% local to the user's machine: Apple Mail sends from the user's own
/// account; nothing routes through us and we make no network calls of our own.
/// The script is generated purely (testable) and the runner is injectable, so
/// the whole path is unit-tested without ever driving Mail.
struct MailSender: Sendable {
    enum Result: Equatable, Sendable {
        case sent
        case failed(String)   // human-readable reason
    }

    /// Runs an AppleScript, returning stdout and a non-nil error string on failure.
    /// Injected so tests never spawn osascript / touch Mail.
    var run: @Sendable (String) -> (out: String, error: String?)

    /// The real executor (osascript). Use `MailSender.live` in the app.
    static let live = MailSender(run: { AppleScriptRunner.run($0) })

    // MARK: - Actions (each maps to exactly one explicit button)

    /// Send a reply. `from` selects the sending account (the address the original
    /// was addressed TO), so cross-account users reply from the right identity;
    /// if it doesn't resolve, Mail falls back to the default account (the sender
    /// line is best-effort inside a `try`). Threading is "Re: subject" + the same
    /// recipient - Mail's AppleScript can't set In-Reply-To, and subject+participant
    /// is what both Mail and Gmail thread on anyway.
    func sendReply(to recipient: String, from account: String?, subject: String, body: String) -> Result {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidEmail(to) else { return .failed("No valid recipient address to send to.") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed("The reply is empty.")
        }
        let (_, err) = run(Self.sendScript(to: to, from: account, subject: subject, body: body))
        return err == nil ? .sent : .failed(Self.friendly(err!))
    }

    /// Move a message (by Message-ID) out of the inbox into its account's Archive.
    /// Best-effort across accounts; a no-match is reported so the caller can fall
    /// back to a local clear.
    func archive(messageID: String) -> Result {
        let id = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \n\t"))
        guard !id.isEmpty else { return .failed("No message id to archive.") }
        let (out, err) = run(Self.archiveScript(messageID: id))
        if let err { return .failed(Self.friendly(err)) }
        return out.contains("NOVEX_OK") ? .sent : .failed("Couldn't find that message in Mail to archive.")
    }

    // MARK: - Script generation (pure + testable)

    static func sendScript(to recipient: String, from account: String?, subject: String, body: String) -> String {
        let senderLine: String
        if let a = account?.trimmingCharacters(in: .whitespacesAndNewlines), isValidEmail(a) {
            senderLine = "    try\n        set sender of newMsg to \(literal(a))\n    end try\n"
        } else {
            senderLine = ""
        }
        return """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:\(literal(subject)), content:\(literal(body)), visible:false}
            tell newMsg
                make new to recipient at end of to recipients with properties {address:\(literal(recipient))}
            end tell
        \(senderLine)    send newMsg
        end tell
        """
    }

    static func archiveScript(messageID: String) -> String {
        // Scan each account's inbox for the id; move the match to that account's
        // archive (fall back to a mailbox literally named "Archive"). Print a
        // sentinel so the caller can tell a hit from a silent miss.
        """
        tell application "Mail"
            repeat with acct in accounts
                try
                    set hits to (messages of mailbox "INBOX" of acct whose message id is \(literal(messageID)))
                    if (count of hits) > 0 then
                        set theMsg to item 1 of hits
                        try
                            set mailbox of theMsg to (mailbox "Archive" of acct)
                        on error
                            set mailbox of theMsg to (mailbox "Archive" of acct)
                        end try
                        return "NOVEX_OK"
                    end if
                end try
            end repeat
        end tell
        return "NOVEX_MISS"
        """
    }

    /// An AppleScript string EXPRESSION for `s`: each line becomes a quoted,
    /// escaped literal, joined with `& linefeed &`, so newlines survive without
    /// relying on `\n` escape support. `\` and `"` are escaped inside each line.
    static func literal(_ s: String) -> String {
        let normalized = s.replacingOccurrences(of: "\r\n", with: "\n")
                          .replacingOccurrences(of: "\r", with: "\n")
        if normalized.isEmpty { return "\"\"" }
        let lines = normalized.components(separatedBy: "\n").map { line -> String in
            let e = line.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(e)\""
        }
        return lines.joined(separator: " & linefeed & ")
    }

    /// Best-effort: the account address that RECEIVED a message, parsed from its
    /// mailbox URL (e.g. `imap://me%40gmail.com@imap.gmail.com/INBOX` -> `me@gmail.com`),
    /// so a reply goes out from the same identity it came in on. Returns nil for a
    /// non-email login; the caller then lets Mail use its default account.
    static func accountHint(fromMailbox mailbox: String?) -> String? {
        guard let mailbox, let scheme = mailbox.range(of: "://") else { return nil }
        let rest = mailbox[scheme.upperBound...]
        let authority = rest.prefix(while: { $0 != "/" })      // userinfo@host
        guard let at = authority.lastIndex(of: "@") else { return nil }
        let userinfo = String(authority[..<at])
        let decoded = userinfo.removingPercentEncoding ?? userinfo
        return isValidEmail(decoded) ? decoded : nil
    }

    static func isValidEmail(_ s: String) -> Bool {
        guard let at = s.firstIndex(of: "@"), at != s.startIndex else { return false }
        let domain = s[s.index(after: at)...]
        return domain.contains(".") && !s.contains(" ") && s.last != "." && !domain.isEmpty
            && s.firstIndex(of: "@") == s.lastIndex(of: "@")
    }

    /// Turn an osascript error into something a person can act on.
    static func friendly(_ raw: String) -> String {
        let l = raw.lowercased()
        if l.contains("-1743") || l.contains("not authori") || l.contains("not allowed") || l.contains("not permitted") {
            return "Novex needs permission to control Mail. Enable it in System Settings > Privacy & Security > Automation (Novex > Mail), then try again."
        }
        if l.contains("-600") || l.contains("isn't running") || l.contains("not running") {
            return "Mail isn't available right now. Open Mail and try again."
        }
        if l.contains("-1728") || l.contains("can't get") {
            return "Mail couldn't complete that. Try opening Mail first."
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Mail reported an unknown error." : trimmed
    }
}

/// Runs an AppleScript via `/usr/bin/osascript`, reading the script from stdin
/// (so multi-line scripts need no temp file). Blocking - call it off the main
/// actor. The Apple Events it sends are attributed to Novex, so macOS shows the
/// one-time "Novex wants to control Mail" Automation prompt on first use.
enum AppleScriptRunner {
    static func run(_ script: String) -> (out: String, error: String?) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return ("", "Could not launch osascript: \(error.localizedDescription)")
        }
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        try? inPipe.fileHandleForWriting.close()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 || !err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reason = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return (out, reason.isEmpty ? "osascript exited with code \(proc.terminationStatus)" : reason)
        }
        return (out, nil)
    }
}
