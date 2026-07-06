import SwiftUI
import AppKit

/// Full-panel Smart Reply composer. Drafts a reply to a briefing item entirely
/// on-device, lets the user edit it and re-roll the tone, then hands the result
/// to Mail (a `mailto:` compose window) or the clipboard. Presented as an
/// overlay over the briefing — never a separate window — so it inherits the
/// panel's surface and dismissal.
struct ReplyComposer: View {
    let message: MailMessage
    let service: BriefingService
    let onClose: () -> Void

    @State private var draft: ReplyDraft?
    @State private var bodyText: String = ""
    @State private var isDrafting = true
    @State private var tone: ReplyTone = .balanced
    @State private var copied = false
    @State private var confirming = false
    @State private var sending = false
    @State private var sent = false
    @State private var sendError: String?

    /// `message://` deep link to open the original in Mail, if we have a real id.
    private var originalURL: URL? {
        guard let mid = message.messageID else { return nil }
        let core = mid.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            subjectLine
            if isDrafting {
                draftingState
                Spacer(minLength: 0)
            } else {
                editor
                // Once a send is armed or in flight, lock the draft: no tone re-roll
                // or re-draft can mutate the text under an in-flight send.
                if !confirming, !sending, !sent {
                    toneRow
                }
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .task { await generate(.balanced) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.green.opacity(0.85))
            Text("Reply to \(message.senderDisplay)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .lineLimit(1)
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .appKitTap(onClose)
                .help("Close")
        }
    }

    private var subjectLine: some View {
        HStack(spacing: 8) {
            Text(draft?.replySubject ?? "Re: \(message.subject)")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let url = originalURL {
                Text("View original")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.cyan.opacity(0.8))
                    .appKitTap { NSWorkspace.shared.open(url) }
                    .help("Open the original email in Mail")
            }
        }
    }

    // MARK: - Drafting / editor

    private var draftingState: some View {
        HStack(spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text("Writing your reply…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("On-device · nothing leaves your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.top, 16)
    }

    private var editor: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 12.5))
            .foregroundStyle(.white.opacity(0.95))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 210)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("Write your reply…")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.3))
                        .padding(.horizontal, 13)
                        .padding(.top, 14)
                        .allowsHitTesting(false)
                }
            }
    }

    private var toneRow: some View {
        HStack(spacing: 6) {
            ForEach(ReplyTone.allCases, id: \.self) { t in
                toneChip(t)
            }
            Spacer()
        }
    }

    private func toneChip(_ t: ReplyTone) -> some View {
        let selected = tone == t
        return Text(t.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.16 : 0.06))
            )
            .appKitTap { if tone != t { Task { await generate(t) } } }
            .help("Rewrite \(t.label.lowercased())")
    }

    // MARK: - Actions

    private var canSend: Bool {
        guard let e = draft?.recipientEmail else { return false }
        return ReplyComposer.isSendable(e) && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var recipientLabel: String {
        draft?.recipientEmail ?? message.senderDisplay
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = sendError {
                Text(err)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if sent {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(.green)
                    Text("Sent")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            } else if sending {
                HStack(spacing: 10) {
                    PulsingSparkle()
                    Text("Sending through Mail…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                }
            } else if confirming {
                confirmRow
            } else {
                defaultActions
            }
        }
    }

    /// The mandatory confirm step: sending is a real outward action, so it never
    /// happens on the first tap - "Send" arms this, and only "Send now" sends.
    private var confirmRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Send to \(recipientLabel)?")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                Text("Sends the reply from Mail now")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            Text("Cancel")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                .appKitTap { confirming = false }
            Text("Send now")
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.green.opacity(0.9)))
                .appKitTap { Task { await doSend() } }
                .help("Send this reply through Mail now")
        }
    }

    private var defaultActions: some View {
        HStack(spacing: 8) {
            Text("Send")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(canSend ? .black.opacity(0.85) : .white.opacity(0.4))
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(canSend ? Color.green.opacity(0.85) : Color.white.opacity(0.08))
                )
                .appKitTap { if canSend { sendError = nil; confirming = true } }
                .help(canSend ? "Send this reply through Mail" : "No address to send to - use Edit in Mail")
            Text("Edit in Mail")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.10)))
                .appKitTap(useInMail)
                .help("Open this reply in Mail to tweak before sending")
            Text(copied ? "Copied ✓" : "Copy")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.10)))
                .appKitTap(copyDraft)
            Spacer(minLength: 0)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(7)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .appKitTap { Task { await generate(tone) } }
                .help("Re-draft")
        }
    }

    /// Mirror of `MailSender.isValidEmail` for the button-enable check, so the UI
    /// doesn't offer Send on an address Mail would reject.
    static func isSendable(_ email: String) -> Bool { MailSender.isValidEmail(email) }

    // MARK: - Logic

    private func generate(_ newTone: ReplyTone) async {
        tone = newTone
        copied = false
        isDrafting = true
        let d = await service.draftReply(for: message, tone: newTone)
        draft = d
        bodyText = d.body
        isDrafting = false
    }

    /// Runs ONLY after the user taps "Send now". Sends through Mail off the main
    /// actor, marks the original handled on success, and closes. On failure it
    /// surfaces an actionable reason and leaves the draft intact so the user can
    /// retry or fall back to Edit in Mail.
    private func doSend() async {
        // Re-entrancy guard: a fast double-tap of "Send now" must not dispatch two
        // sends (a duplicate email). MainActor serializes these Tasks, so the first
        // flips `sending` before the second runs this check.
        guard let d = draft, !sending, !sent else { return }
        confirming = false
        sendError = nil
        sending = true
        let result = await service.sendReply(d, body: bodyText, original: message)
        sending = false
        switch result {
        case .sent:
            sent = true
            try? await Task.sleep(nanoseconds: 850_000_000)
            onClose()
        case .failed(let reason):
            sendError = reason
        }
    }

    private func useInMail() {
        guard let d = draft else { return }
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = d.recipientEmail ?? ""
        comps.queryItems = [
            URLQueryItem(name: "subject", value: d.replySubject),
            URLQueryItem(name: "body", value: bodyText),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
        onClose()
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bodyText, forType: .string)
        copied = true
    }
}
