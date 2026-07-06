import SwiftUI
import AppKit

struct WidgetView: View {
    @State private var service = BriefingService.shared
    @State private var voice = VoiceService()
    @State private var speech = SpeechService.shared
    @State private var reminders = RemindersService.shared
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool
    /// First-run flag. While false, the widget shows the one-time onboarding
    /// (privacy explainer + permission walk-through) instead of the briefing.
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// The owner's name, captured at setup — Novex is a personal agent, so it
    /// should know who it works for.
    @AppStorage("ownerName") private var ownerName = ""

    /// Which tab is showing. Inbox = the daily briefing + Q&A; Money = the
    /// subscription/spend radar.
    private enum Mode: String { case inbox, followups, cleanup, money }
    @State private var mode: Mode = .inbox
    @State private var updater = UpdateChecker.shared

    /// When non-nil, the Smart Reply composer is open for this message (covers
    /// the whole panel). Set from a briefing "Reply" row or a Follow-up thread.
    @State private var replyTarget: MailMessage?

    /// When non-nil, the snooze picker is open for this briefing item.
    @State private var snoozingItem: BriefingItem?
    /// Whether the Settings overlay is open.
    @State private var showSettings = false
    /// Whether the "Catch me up" digest overlay is open.
    @State private var showDigest = false
    /// Bumped to force a re-render after snooze/unsnooze (the store is plain
    /// UserDefaults, not observable).
    @State private var dataRevision = 0

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                widgetBody
            } else {
                onboardingBody
            }
        }
    }

    // MARK: - Onboarding gate

    /// One consistent, premium dark surface. A near-opaque gradient sits over the
    /// blur so the panel looks the SAME no matter what's behind it — the old
    /// `black.opacity(0.18)` let the desktop's colors bleed through (the red/green
    /// wash). Subtle top→bottom gradient keeps a hint of depth.
    private var novexBackground: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.95),
                    Color(red: 0.06, green: 0.06, blue: 0.08).opacity(0.975),
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    private var onboardingBody: some View {
        ZStack {
            novexBackground
            OnboardingView {
                hasCompletedOnboarding = true
                service.start()
                // Bring up the notch panel immediately (no relaunch needed).
                NotificationCenter.default.post(name: .novexDidCompleteOnboarding, object: nil)
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    service.markSeen()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var widgetBody: some View {
        ZStack {
            novexBackground

            VStack(alignment: .leading, spacing: 0) {
                header
                modePicker
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 14)
                // FILL the remaining space (not size-to-content). With the panel
                // pinned to a fixed height, the scroll area is a constant size, so
                // the loading→ready content swap happens INSIDE the scroll and
                // never changes the window's height — which is what was bouncing
                // the menu-bar panel on a fresh launch.
                ScrollView(.vertical, showsIndicators: false) {
                    switch mode {
                    case .inbox: content
                    case .followups: FollowUpView { replyTarget = $0 }
                    case .cleanup: DeclutterView()
                    case .money: MoneyRadarView()
                    }
                }
                .frame(maxHeight: .infinity)
                if mode == .inbox {
                    if showSuggestions { suggestionBar.padding(.top, 8) }
                    inputBar
                        .padding(.top, 8)
                }
            }
            .padding(.vertical, 12)

            // Smart Reply composer — full-panel takeover with the same surface,
            // so drafting a reply never disturbs whatever's beneath it.
            if let m = replyTarget {
                ZStack {
                    novexBackground
                    ReplyComposer(message: m, service: service) { replyTarget = nil }
                }
            }
            // Snooze picker overlay.
            if let item = snoozingItem {
                ZStack {
                    novexBackground
                    SnoozePicker(item: item) { snoozingItem = nil; dataRevision += 1 }
                }
            }
            // Settings overlay.
            if showSettings {
                ZStack {
                    novexBackground
                    SettingsView(service: service) { showSettings = false; dataRevision += 1 }
                }
            }
            // "Catch me up" digest overlay.
            if showDigest {
                ZStack {
                    novexBackground
                    DigestView(digest: service.currentDigest()) { showDigest = false }
                }
            }
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.16), value: replyTarget != nil)
        .onDisappear {
            // Closing the panel must kill a live mic + any speech - otherwise the
            // engine keeps recording (and transcribing) with the panel shut, and
            // TTS keeps reading aloud. Privacy + battery.
            voice.stopRecording(resetTranscript: true)
            speech.stop()
        }
        .onAppear {
            // Only start the briefing service once the user is past onboarding,
            // so we don't poll mail before they've granted access.
            guard hasCompletedOnboarding else { return }
            service.start()
            // Request Calendar access + do the first pairing on THIS launch. The
            // AppDelegate path is gated on hasCompletedOnboarding, so on a fresh
            // install Calendar was never requested and "Up Next" stayed dead until a
            // relaunch. Mirrors how Reminders is started just below.
            Task { await CalendarService.shared.start() }
            // Lightweight: pick up a freshly-added calendar event on open WITHOUT
            // the full mail refresh that churned state and bounced the window.
            Task { await service.refreshUpNext() }
            Task { await reminders.start() }
            if UserDefaults.standard.bool(forKey: "NOVEX_DEBUG_SHOW_SETTINGS") { showSettings = true }
            // Demo (screenshots): open on a chosen tab.
            if let raw = UserDefaults.standard.string(forKey: "NOVEX_DEMO_TAB"),
               let m = Mode(rawValue: raw) { mode = m }
            // Demo (screenshots): force the reply composer open on the demo message
            // so its Send / confirm UI can be captured. Off by default; demo data only.
            if UserDefaults.standard.bool(forKey: "NOVEX_DEMO_COMPOSE") {
                Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    if let pr = service.preparedReply, let m = service.message(forID: pr.messageID) {
                        replyTarget = m
                    }
                }
            }
            Task {
                // Give the first briefing a moment to render, then mark seen
                // so subsequent refreshes can flag new arrivals.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                service.markSeen()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Daily Briefing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
            Text(briefingTimestamp)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 4)
                .appKitTap { showSettings = true }
                .help("Settings")
            Image(systemName: "power")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 2)
                .appKitTap { NSApplication.shared.terminate(nil) }
                .help("Quit Novex")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Mode picker (Inbox / Money)

    private var modePicker: some View {
        // All four tabs must FIT (no scroll-clip — a hidden "Money" tab is a bug),
        // so this is a tight, evenly-spread row, not a scroll view.
        HStack(spacing: 3) {
            modeChip(.inbox, label: "Inbox", icon: "tray.full")
            modeChip(.followups, label: "Follow-ups", icon: "arrow.triangle.2.circlepath")
            modeChip(.cleanup, label: "Cleanup", icon: "sparkles")
            modeChip(.money, label: "Money", icon: "dollarsign.circle")
            Spacer(minLength: 0)
        }
    }

    private func modeChip(_ m: Mode, label: String, icon: String) -> some View {
        let selected = mode == m
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            Text(label).font(.system(size: 10.5, weight: .semibold)).fixedSize()
        }
        .foregroundStyle(.white.opacity(selected ? 0.95 : 0.5))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.14 : 0.0))
        )
        // AppKit-backed tap — SwiftUI Button crashes on tap here (AppKitTap.swift).
        .appKitTap { mode = m }
    }

    private var briefingTimestamp: String {
        let date = service.briefing.generatedAt == .distantPast ? Date() : service.briefing.generatedAt
        return date.formatted(.dateTime.hour().minute())
    }

    // MARK: - State-driven content

    @ViewBuilder
    private var content: some View {
        if !service.chat.isEmpty {
            chatView
        } else if let mid = service.focusedMessageID, let m = service.message(forID: mid) {
            focusedMailView(m)
        } else {
            stateContent
        }
    }

    /// The mail you tapped from the notch notification — opened focused.
    private func focusedMailView(_ m: MailMessage) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "bell.badge.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.8))
                    Text("From your notification").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Text("Back").font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.85))
                    .appKitTap { service.clearFocus() }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(m.subject).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.96)).fixedSize(horizontal: false, vertical: true)
                Text(m.senderDisplay).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                if let snip = m.snippet, !snip.isEmpty {
                    Text(snip).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78))
                        .lineLimit(8).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.06)))
            HStack(spacing: 8) {
                if m.isReplyable && !m.isFromSelf(OwnerIdentity.addresses) && !m.isEphemeralNotification {
                    focusPill("Reply", filled: true) { LearnStore.recordOpen(m.senderAddress); replyTarget = m }
                }
                if let url = mailURLFor(m.messageID ?? "") {
                    focusPill("Open in Mail", filled: false) { openInMail(url) }
                }
                Spacer()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.top, 12)
    }

    private func focusPill(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(filled ? .black.opacity(0.85) : .white.opacity(0.9))
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Capsule().fill(filled ? Color.green.opacity(0.85) : Color.white.opacity(0.12)))
            .appKitTap(action)
    }

    @ViewBuilder
    private var stateContent: some View {
        switch service.state {
        case .loading where !service.hasEverLoaded:
            analyzingCard(title: "Reading your mail…", subtitle: "Loading recent messages")
        case .analyzing where !service.hasEverLoaded:
            analyzingCard(title: "Analyzing your mail…", subtitle: "Apple Intelligence is summarizing")
        case .needsFullDiskAccess:
            actionCard(
                icon: "lock.shield",
                title: "Grant Full Disk Access",
                detail: "Novex needs to read Mail.app's local store",
                actionTitle: "Open Settings",
                action: openFullDiskAccessSettings
            )
        case .mailNotConfigured:
            actionCard(
                icon: "envelope.badge",
                title: "Add a mail account",
                detail: "Sign in via System Settings > Internet Accounts",
                actionTitle: "Open Settings",
                action: openInternetAccountsSettings
            )
        case .error(let msg):
            statusCard(icon: "exclamationmark.triangle", title: "Couldn't load", detail: msg)
        case .llmUnavailable(let msg):
            statusCard(icon: "cpu", title: "Apple Intelligence unavailable", detail: msg)
        case .loading, .analyzing, .ready:
            briefingList
        }
    }

    /// The Q&A conversation — your question echoed as a bubble, Novex's reply
    /// below it, with history. A "Back" returns to the briefing.
    private var chatView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Ask Novex").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Text("Back to briefing")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.85))
                    .appKitTap { service.dismissAnswer() }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(service.chat) { turn in
                        chatTurn(turn)
                    }
                    // A reply the agent drafted in this chat - Send/Edit inline.
                    if let pr = service.chatDraft {
                        preparedDraftCard(pr).padding(.leading, 20)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private func chatTurn(_ turn: BriefingService.ChatTurn) -> some View {
        // Your question — a right-aligned bubble (skipped for system confirmations).
        if !turn.question.isEmpty {
            HStack {
                Spacer(minLength: 36)
                Text(turn.question)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.cyan.opacity(0.22)))
            }
        }
        // Novex's answer — left-aligned, with a sparkle.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.8)).padding(.top, 3)
            if let answer = turn.answer {
                VStack(alignment: .leading, spacing: 6) {
                    TypingText(text: answer)
                    if !turn.sources.isEmpty { sourceChips(turn.sources) }
                }
            } else {
                TypingDots().padding(.top, 4)
            }
        }
        .padding(.trailing, 24)
    }

    /// Source-email citations under an answer, each with inline quick-actions: tap
    /// the name to open it in Mail, or act on it (Reply / Done) without typing.
    @ViewBuilder
    private func sourceChips(_ sources: [BriefingService.ChatSource]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sources) { s in
                HStack(spacing: 5) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.forward.app").font(.system(size: 9))
                        Text(s.sender).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .foregroundStyle(.cyan.opacity(0.85))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.cyan.opacity(0.12)))
                    .appKitTap { if let url = mailURLFor(s.messageID) { openInMail(url) } }

                    if s.canReply {
                        citationAction("Reply") {
                            if let m = service.message(forID: s.messageID) {
                                LearnStore.recordOpen(m.senderAddress); replyTarget = m
                            }
                        }
                    }
                    citationAction("Done") {
                        Task { await service.markDoneFromCitation(s.messageID, sender: s.sender) }
                    }
                    citationAction("Archive") {
                        Task { await service.archiveInMail(s.messageID) }
                    }
                }
            }
        }
        .padding(.top, 1)
    }

    private func citationAction(_ label: String, _ act: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .appKitTap(act)
    }

    private func analyzingCard(title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    /// Briefing items that are currently visible — snoozed ones are hidden until
    /// they wake. (`dataRevision` makes this recompute right after a snooze.)
    private var visibleItems: [BriefingItem] {
        _ = dataRevision
        return service.briefing.items.filter {
            !SnoozeStore.isAsleep($0.messageID) && !DismissStore.isDismissed($0.messageID)
        }
    }

    /// The rest of the recent inbox (newsletters, job alerts, FYI), shown under
    /// "RECENT" so you still see everything — not just the things that need you.
    private var recentVisible: [BriefingItem] {
        _ = dataRevision
        return service.briefing.recent.filter {
            !SnoozeStore.isAsleep($0.messageID) && !DismissStore.isDismissed($0.messageID)
        }
    }

    /// Plain rows for the rest of the inbox — tap to open, no Done/snooze (they're
    /// context, not tasks).
    private var recentRows: some View {
        ForEach(recentVisible) { item in
            rowContent(item)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .appKitTap { primaryAction(item) }
                .help(primaryHelp(item))
        }
    }

    /// An item you can actually COMPLETE (reply / pay / confirm / review) — the
    /// only kind that gets a "Done" affordance.
    private func isActionItem(_ item: BriefingItem) -> Bool {
        switch item.action {
        case .reply, .pay, .confirm, .review: return true
        default: return false
        }
    }

    /// Caught up = nothing genuinely IMPORTANT (human / flagged / high-impact /
    /// VIP). A pile of unread newsletters and job alerts is NOT "needs you" — it
    /// shows calmly under RECENT instead of as a fake briefing.
    private var isCaughtUp: Bool {
        service.briefing.importantCount == 0
    }

    private var briefingList: some View {
        VStack(alignment: .leading, spacing: 12) {
            updateCard
            if !service.upNext.isEmpty { upNextSection }
            snoozedSection

            // The assistant SPEAKS — a greeting + a synthesized line — instead of
            // a clinical status + raw list.
            assistantMessage

            todoSection

            if isCaughtUp {
                if !visibleItems.isEmpty {
                    sectionLabel("RECENT")
                    itemRows
                }
            } else {
                if !visibleItems.isEmpty {
                    sectionLabel("NEEDS YOU")
                    itemRows
                }
                if !recentVisible.isEmpty {
                    sectionLabel("RECENT")
                    recentRows
                }
            }

            discoverSection
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    /// A gentle "a new Novex is out" card at the top of the briefing (only when the
    /// once-daily update check found a newer release). Tap → opens the release page.
    @ViewBuilder
    private var updateCard: some View {
        if let up = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.95))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Novex \(up.version) is available")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    Text(up.notes.isEmpty ? "Tap to see what's new" : up.notes)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Update").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(0.9)))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.cyan.opacity(0.10)))
            .contentShape(Rectangle())
            .appKitTap { if let u = URL(string: up.url) { NSWorkspace.shared.open(u) } }
        }
    }

    /// "Worth a look" — interesting reads pulled from the newsletters you already
    /// subscribe to, matched to what you follow. Tap to open in Mail.
    @ViewBuilder
    private var discoverSection: some View {
        if !service.discover.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("WORTH A LOOK")
                ForEach(service.discover) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.9)).frame(width: 16)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9)).lineLimit(2)
                            Text(item.sub).font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .appKitTap {
                        if let url = mailURLFor(item.messageID ?? "") { openInMail(url) }
                    }
                }
            }
        }
    }

    /// "On your plate" — open Apple Reminders due/overdue, so Novex is aware of
    /// your todos, not just your mail.
    /// Only reminders that are actually DUE — overdue, today, or tomorrow. We
    /// never mirror the user's whole Reminders-app list (that's pointless: they
    /// already have it). Undated/next-week items are planning, not a "remind me".
    private var dueSoonTodos: [Todo] {
        let cal = Calendar.current
        return reminders.todos.filter { t in
            guard let due = t.due else { return false }
            return t.isOverdue() || cal.isDateInToday(due) || cal.isDateInTomorrow(due)
        }
    }

    @ViewBuilder
    private var todoSection: some View {
        if !dueSoonTodos.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("DUE SOON")
                ForEach(dueSoonTodos) { todo in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(todo.isOverdue() ? .orange.opacity(0.85) : .white.opacity(0.5))
                            .frame(width: 16)
                        Text(todo.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let due = todo.due {
                            Text(dueLabel(due, overdue: todo.isOverdue()))
                                .font(.system(size: 10, weight: todo.isOverdue() ? .semibold : .regular))
                                .foregroundStyle(todo.isOverdue() ? .orange.opacity(0.9) : .white.opacity(0.45))
                                .layoutPriority(1)
                        }
                    }
                    .contentShape(Rectangle())
                    .appKitTap { NSWorkspace.shared.open(URL(string: "x-apple-reminderkit://")!) }
                }
                Divider().background(Color.white.opacity(0.08)).padding(.top, 2)
            }
        }
    }

    private func dueLabel(_ date: Date, overdue: Bool) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return overdue ? "overdue" : "today" }
        if cal.isDateInTomorrow(date) { return "tomorrow" }
        if date < Date() { return "overdue" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// A time-of-day greeting + the assistant's synthesized one-liner — the
    /// "person giving you the update" moment.
    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(greeting)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Spacer()
                Image(systemName: speech.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(speech.isSpeaking ? .cyan.opacity(0.9) : .white.opacity(0.4))
                    .appKitTap { speech.toggle("\(greeting). \(assistantLine)") }
                    .help("Read the briefing aloud")
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.7))
                    .padding(.top, 2.5)
                Text(assistantLine)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 2)
    }

    private var assistantLine: String {
        if let s = service.briefing.summary, !s.isEmpty { return s }
        return isCaughtUp ? "It's quiet. Nothing needs you right now." : "Here's your inbox."
    }

    private var greeting: String {
        let base: String
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  base = "Good morning"
        case 12..<17: base = "Good afternoon"
        case 17..<22: base = "Good evening"
        default:      base = "Working late?"
        }
        let name = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? base : "\(base), \(name)"
    }

    @ViewBuilder
    private var itemRows: some View {
        ForEach(visibleItems) { item in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    rowContent(item)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .appKitTap { primaryAction(item) }
                        .help(primaryHelp(item))
                    // "Done" is only meaningful for an actual ACTION you can
                    // complete (reply / pay / confirm / review) — not an FYI row.
                    if item.messageID != nil, isActionItem(item) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.32))
                            .padding(.top, 2)
                            .appKitTap {
                                // "I've handled this" — clear it for good, even if the
                                // email is still unread (you acted outside of mail).
                                DismissStore.dismiss(item.messageID)
                                dataRevision += 1
                                Task { await service.refresh() }
                            }
                            .help("Mark done, stop showing this")
                    }
                    if let mid = item.messageID {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 2)
                            .appKitTap { Task { await service.archiveInMail(mid) } }
                            .help("Archive in Mail: move it out of your inbox")
                    }
                    if item.messageID != nil {
                        Image(systemName: "clock.badge")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(.top, 2)
                            .appKitTap { snoozingItem = item }
                            .help("Snooze")
                    }
                }
                if let pr = service.preparedReply, pr.messageID == item.messageID {
                    preparedDraftCard(pr)
                }
            }
        }
    }

    /// The "assistant already wrote it" card — a drafted reply ready to Send/Edit.
    private func preparedDraftCard(_ pr: BriefingService.PreparedReply) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.85))
                Text("Reply drafted").font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.green.opacity(0.85))
            }
            Text(pr.draft.body)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Send").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .appKitTap { sendPreparedDraft(pr) }
                Text("Edit").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .appKitTap { if let m = service.message(forID: pr.messageID) { replyTarget = m } }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.green.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.green.opacity(0.13), lineWidth: 0.5))
        .padding(.leading, 26)
    }

    private func sendPreparedDraft(_ pr: BriefingService.PreparedReply) {
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = pr.draft.recipientEmail ?? ""
        var items = [URLQueryItem(name: "subject", value: pr.draft.replySubject),
                     URLQueryItem(name: "body", value: pr.draft.body)]
        // Best-effort threading: RFC 6068 lets a mailto carry In-Reply-To/References
        // so a compliant client files the reply in the original thread. (Apple Mail
        // may ignore these; the "Re:" subject still gives visual threading.)
        if !pr.messageID.isEmpty {
            let angled = pr.messageID.hasPrefix("<") ? pr.messageID : "<\(pr.messageID)>"
            items.append(URLQueryItem(name: "In-Reply-To", value: angled))
            items.append(URLQueryItem(name: "References", value: angled))
        }
        comps.queryItems = items
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    private func primaryAction(_ item: BriefingItem) {
        if item.action == .reply, let m = service.message(forID: item.messageID) {
            LearnStore.recordOpen(m.senderAddress)
            OwnerModel.learnOpened(m)
            replyTarget = m
        } else if let url = item.mailURL {
            if let m = service.message(forID: item.messageID) {
                LearnStore.recordOpen(m.senderAddress)
                OwnerModel.learnOpened(m)
            }
            openInMail(url)
        }
    }

    private func primaryHelp(_ item: BriefingItem) -> String {
        if item.action == .reply, service.message(forID: item.messageID) != nil {
            return "Draft a reply with Novex"
        }
        return item.mailURL != nil ? "Open in Mail" : ""
    }

    /// Snoozed items waiting to wake — a calm, collapsible reminder list.
    @ViewBuilder
    private var snoozedSection: some View {
        let _ = dataRevision
        let snoozed = SnoozeStore.upcoming()
        if !snoozed.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("SNOOZED")
                ForEach(snoozed, id: \.messageID) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.purple.opacity(0.7))
                            .frame(width: 16)
                        Text(s.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("back \(snoozeBackLabel(s.wake))")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .layoutPriority(1)
                        Text("Wake")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.8))
                            .appKitTap { SnoozeStore.unsnooze(s.messageID); dataRevision += 1 }
                            .help("Bring it back now")
                    }
                }
            }
        }
    }

    private func snoozeBackLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let t = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return t }
        if cal.isDateInTomorrow(date) { return "tmrw \(t)" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    /// Calm "all caught up" state — quality over quantity.
    private var caughtUpHeader: some View {
        HStack(spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.green.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text("You're all caught up")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text("Nothing needs you right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.white.opacity(0.32))
            .padding(.top, 4)
    }

    // MARK: - Up next (cross-app: Calendar × Mail)

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.white.opacity(0.4))
            ForEach(service.upNext) { item in
                upNextRow(item)
            }
            Divider().background(Color.white.opacity(0.08))
        }
    }

    private func upNextRow(_ item: UpNext) -> some View {
        let url = item.relatedMessageID.flatMap { mailURLFor($0) }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16)
                Text(eventTimeString(item.event.start))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .layoutPriority(1)
                Text(item.event.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if url != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            // The cross-app magic: a recent email from someone in this meeting.
            if let sender = item.relatedSenderName, let when = item.relatedWhen {
                Text("\(sender) emailed \(relativeShort(when))")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.cyan.opacity(0.85))
                    .lineLimit(1)
                    .padding(.leading, 24)
            }
        }
        .contentShape(Rectangle())
        .appKitTap { if let url { openInMail(url) } }
    }

    private func eventTimeString(_ date: Date) -> String {
        let cal = Calendar.current
        let t = date.formatted(.dateTime.hour().minute())
        if cal.isDateInToday(date) { return t }
        if cal.isDateInTomorrow(date) { return "Tmrw \(t)" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func relativeShort(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func mailURLFor(_ messageID: String) -> URL? {
        let core = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }

    // MARK: - Assistant suggestions

    /// Show the tappable suggestions except while the chat is open.
    private var showSuggestions: Bool { service.chat.isEmpty }

    /// Tappable prompts that make Novex feel like an assistant you talk to, not a
    /// passive list. Each one runs the on-device Q&A.
    private var suggestionBar: some View {
        let suggestions: [(icon: String, label: String, prompt: String)] = [
            ("sparkles", "Needs me?", "What needs me today?"),
            ("text.line.first.and.arrowtriangle.forward", "Catch me up", "Catch me up on my inbox in 3 short lines."),
            ("creditcard", "Bills due?", "Do I have any bills, payments, or renewals coming up?"),
        ]
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.label) { s in
                    HStack(spacing: 4) {
                        Image(systemName: s.icon).font(.system(size: 9, weight: .semibold))
                        Text(s.label).font(.system(size: 10.5, weight: .medium)).fixedSize()
                    }
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .appKitTap {
                        if s.label == "Catch me up" { showDigest = true }
                        else { Task { await service.answerQuestion(s.prompt) } }
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    /// A briefing row's content (icon + title + detail), without a trailing
    /// control — the caller adds the tap + the snooze button as siblings, so the
    /// snooze ⏰ never nests inside the row's tap (AppKitTap overlays its view).
    private func rowContent(_ item: BriefingItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1).truncationMode(.tail)
                    if item.isNew { newBadge }
                    Spacer(minLength: 0)
                    if let reason = item.reason { reasonTag(reason) }
                }
                HStack(spacing: 6) {
                    Text(item.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1).truncationMode(.tail)
                    if let due = item.dueDate { dueChip(due) }
                    if item.action.showsPill { actionPill(item.action, replyable: item.replyable) }
                }
            }
        }
    }

    /// A colored deadline chip ("due Jul 14" / "due today", overdue in red) so a
    /// real deadline is glanceable instead of buried in free text.
    private func dueChip(_ date: Date) -> some View {
        let cal = Calendar.current
        let overdue = date < Date()
        let today = cal.isDateInToday(date)
        let f = DateFormatter(); f.dateFormat = "MMM d"
        let label = overdue ? "overdue" : (today ? "due today" : "due \(f.string(from: date))")
        let color: Color = overdue ? .red : (today ? .orange : .orange.opacity(0.8))
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.6)))
    }

    /// A subtle one-word "why this surfaced" tag (urgent / flagged / deadline …)
    /// so the ranking isn't a black box.
    private func reasonTag(_ reason: String) -> some View {
        Text(reason)
            .font(.system(size: 8.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white.opacity(0.08)))
    }

    private func openInMail(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func statusCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(3)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func actionCard(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            statusCard(icon: icon, title: title, detail: detail)
            Text(actionTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
                .appKitTap(action)
                .padding(.leading, 44)
        }
    }

    // MARK: - Input

    private var inputBar: some View {
        HStack(spacing: 8) {
            Image(systemName: voice.state == .recording ? "waveform" : "text.bubble")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(voice.state == .recording ? 0.9 : 0.5))
            TextField(inputPlaceholder, text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.95))
                .focused($inputFocused)
                .onSubmit { submitTextQuestion() }
            micButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(voice.state == .recording ? 0.5 : 0.05), lineWidth: 0.5)
                )
        )
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .onChange(of: voice.transcript) { _, new in
            if voice.state == .recording { inputText = new }
        }
    }

    private var inputPlaceholder: String {
        switch voice.state {
        case .recording:           return "Listening…"
        case .requestingPermission: return "Asking permission…"
        case .denied:              return "Mic denied, click to fix"
        case .error:               return "Mic error, click to retry"
        default:                   return "Ask or say something"
        }
    }

    private var micButton: some View {
        Image(systemName: voice.state == .recording ? "stop.fill" : "mic.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(voice.state == .recording ? .red : .white.opacity(0.85))
            .padding(6)
            .background(
                Circle()
                    .fill(voice.state == .recording ? Color.red.opacity(0.22) : Color.white.opacity(0.10))
            )
            .scaleEffect(voice.state == .recording ? 1.08 : 1.0)
            .animation(.easeInOut(duration: 0.18), value: voice.state)
            .appKitTap(toggleVoiceCapture)
            .help(voice.state == .recording ? "Click to stop" : "Click to talk")
    }

    private func toggleVoiceCapture() {
        switch voice.state {
        case .recording:
            let spoken = voice.stopRecording(resetTranscript: true)
            let final = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !final.isEmpty {
                inputText = ""
                Task { await service.answerQuestion(final) }
            }
        case .denied(_):
            openMicrophoneSettings()
        default:
            inputText = ""
            speech.stop()   // don't record the assistant's own spoken voice back in
            // Silence auto-stop submits the question without a manual stop tap.
            voice.onFinish = { [service, bind = $inputText] spoken in
                let final = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !final.isEmpty else { return }
                bind.wrappedValue = ""
                Task { await service.answerQuestion(final) }
            }
            Task { try? await voice.startRecording() }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func submitTextQuestion() {
        let q = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        guard !q.isEmpty else { return }
        Task { await service.answerQuestion(q) }
    }

    // MARK: - Badges & pills

    private var newBadge: some View {
        Text("NEW")
            .font(.system(size: 8.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.blue.opacity(0.85))
            )
    }

    private func actionPill(_ action: AIAction, replyable: Bool = true) -> some View {
        // Never promise "Reply" on something you can't reply to (a bot, a
        // notification, your own note) — tapping would just open Mail. Downgrade
        // the affordance to "Open" so the pill never lies.
        let downgraded = (action == .reply && !replyable)
        let label = downgraded ? "Open" : action.displayLabel
        let effective: AIAction = downgraded ? .read : action
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(actionForeground(effective))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(actionBackground(effective))
            )
    }

    private func actionForeground(_ action: AIAction) -> Color {
        switch action {
        case .reply:   return .white
        case .pay:     return .white
        case .confirm: return .white
        case .review:  return .white.opacity(0.95)
        case .read:    return .white.opacity(0.85)
        default:       return .white.opacity(0.6)
        }
    }

    private func actionBackground(_ action: AIAction) -> Color {
        switch action {
        case .reply:   return Color.green.opacity(0.55)
        case .pay:     return Color.orange.opacity(0.6)
        case .confirm: return Color.purple.opacity(0.55)
        case .review:  return Color.cyan.opacity(0.45)
        case .read:    return Color.white.opacity(0.12)
        default:       return Color.white.opacity(0.08)
        }
    }

    // MARK: - Settings deep-links

    private func openInternetAccountsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

}
