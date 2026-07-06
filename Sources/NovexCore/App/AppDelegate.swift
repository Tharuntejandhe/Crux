import AppKit
import SwiftUI

/// Builds the menu bar item and the brief popover with AppKit (NSStatusItem +
/// NSPopover) instead of SwiftUI's MenuBarExtra. See `NovexApp` for why: a fixed
/// NSPopover can't bounce/flicker the way MenuBarExtra(.window) does.
public extension Notification.Name {
    /// Posted when first-run onboarding completes, so the notch can install.
    static let novexDidCompleteOnboarding = Notification.Name("NovexDidCompleteOnboarding")
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    /// The notch panel (Dynamic-Island-style). nil until onboarding is done.
    private var notch: NotchController?
    /// The "notification flies to Novex" dot animation.
    private let flight = DotFlight()
    /// Watches Mail's store → new mail fires a card within seconds (popover or not).
    private var mailWatcher: MailWatcher?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar agent: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // The brief popover — FIXED size, closes when you click away.
        // animates = true gives the native scale-up-from-the-icon + fade open
        // (the Blip-style "flip" reveal) that pairs with the dot dissolving into
        // the icon. NSHostingController hosts the SwiftUI panel; all its controls
        // are AppKit taps so there's no SwiftUI Button gesture to crash.
        popover.contentSize = NSSize(width: 348, height: 470)
        // Normally transient (click-away closes it). For headless screenshots we
        // pin it open so it survives the app losing focus to the capture process.
        popover.behavior = UserDefaults.standard.bool(forKey: "NOVEX_DEBUG_SHOW_POPOVER")
            ? .applicationDefined : .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: NovexMenuBarPanel())

        // The menu bar icon.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Novex")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        // Live count badge next to the sparkle — "N things need you". Repainted
        // whenever the briefing recomputes.
        BriefingService.shared.onMenuBarCountChange = { [weak self] count in
            self?.updateBadge(count)
        }
        updateBadge(BriefingService.shared.menuBarCount)

        // Start the data services (idempotent; views may also call start()).
        Task { @MainActor in
            guard UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") else { return }
            BriefingService.shared.start()
            await CalendarService.shared.start()
            await RemindersService.shared.start()
            await UpdateChecker.shared.checkIfDue()   // anonymous, ≤1×/day, opt-out
        }

        // The notch panel — only once the user is past onboarding (FDA granted),
        // so it has data to show. Also install it the moment onboarding finishes
        // (first run) so a new user doesn't have to relaunch to get the notch.
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            installNotchIfNeeded()
        }
        NotificationCenter.default.addObserver(
            forName: .novexDidCompleteOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.installNotchIfNeeded() }
        }

        debugShowPopoverIfRequested()
        debugDemoNotchIfRequested()

        // Dev-only: run the headless agent bench against a FAKE inbox and write
        // results to ~/novex_bench.txt (fake data, never touches real mail or UI).
        if UserDefaults.standard.bool(forKey: "NOVEX_AGENT_BENCH"), #available(macOS 26.0, *) {
            Task { @MainActor in await AgentBench.run() }
        }
    }

    /// Demo (screenshots only): drop a notch card, or loop the fly-to-Novex dot so
    /// a GIF can be captured. Gated by NOVEX_DEMO_PEEK / NOVEX_DEMO_FLIGHT.
    private func debugDemoNotchIfRequested() {
        if UserDefaults.standard.bool(forKey: "NOVEX_DEMO_PEEK") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                NotchModel.shared.showPeek(icon: "envelope.fill", title: "Sarah Chen",
                    subtitle: "Re: Q3 partnership proposal, finalize by Friday?",
                    messageID: "demo-1", linger: 90)
            }
        }
        if UserDefaults.standard.bool(forKey: "NOVEX_DEMO_FLIGHT") {
            Task { @MainActor in
                while !Task.isCancelled {
                    NotchModel.shared.showPeek(icon: "envelope.fill", title: "Sarah Chen",
                        subtitle: "Re: Q3 partnership proposal", messageID: "demo-1", linger: 30)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    NotchModel.shared.trigger()                       // → flight
                    try? await Task.sleep(nanoseconds: 2_600_000_000)
                    self.popover.performClose(nil)
                    try? await Task.sleep(nanoseconds: 1_600_000_000) // pause before looping
                }
            }
        }
    }

    @MainActor
    private func installNotchIfNeeded() {
        guard notch == nil else { return }
        let controller = NotchController()
        controller.install()
        notch = controller
        // Tapping a notch notification flies a dot to the Novex icon, then opens
        // the panel focused on that mail.
        NotchModel.shared.onTap = { [weak self] peek in
            Task { @MainActor in self?.flyNotificationToNovex(peek) }
        }
        startMailWatcher()
        observeWakeForGreeting()
    }

    /// Watch Mail's store so a new message fires the notch card within ~2–3s,
    /// even when Novex's panel is closed (the refresh loop alone only runs while
    /// the panel is open). Event-driven → no battery cost while the inbox is idle.
    private func startMailWatcher() {
        guard mailWatcher == nil else { return }
        let watcher = MailWatcher {
            Task { @MainActor in await BriefingService.shared.refresh() }
        }
        watcher.start()
        mailWatcher = watcher
    }

    /// On wake-from-sleep / screen-unlock, greet the user with what they missed
    /// (or stay silent if nothing needs them).
    private func observeWakeForGreeting() {
        let greet: @Sendable (Notification) -> Void = { _ in
            Task { @MainActor in await BriefingService.shared.greetOnWake() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: greet)
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main, using: greet)
    }

    /// The notification → Novex handoff: collapse the peek, fly the dot from the
    /// notch to the menu-bar icon, then open the panel showing that mail.
    private func flyNotificationToNovex(_ peek: NotchModel.PeekItem) {
        let messageID = peek.messageID
        NotchModel.shared.peek = nil                 // collapse the peek (reverse)
        // Respect the user's preference — some people don't want the flight.
        let animate = UserDefaults.standard.object(forKey: "flightAnimationEnabled") as? Bool ?? true
        guard animate, let start = notch?.notchAnchor, let end = novexIconScreenPoint() else {
            BriefingService.shared.focus(messageID: messageID); showPopover(); return
        }
        flight.fly(from: start, to: end) { [weak self] in
            BriefingService.shared.focus(messageID: messageID)
            self?.showPopover()
        }
    }

    /// Center of the menu-bar Novex icon, in screen coordinates (works on any screen).
    private func novexIconScreenPoint() -> CGPoint? {
        guard let button = statusItem?.button, let win = button.window else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        let onScreen = win.convertToScreen(inWindow)
        return CGPoint(x: onScreen.midX, y: onScreen.midY)
    }

    private func showPopover() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Paint (or clear) the count badge on the menu-bar button.
    private func updateBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if count > 0 {
            button.title = "  \(count)"
            button.font = .systemFont(ofSize: 11, weight: .semibold)
        } else {
            button.title = ""
        }
    }

    /// Debug: auto-open the popover on launch for headless screenshots, and
    /// optionally fire a REAL question (against the real inbox) to validate Q&A.
    func debugShowPopoverIfRequested() {
        guard UserDefaults.standard.bool(forKey: "NOVEX_DEBUG_SHOW_POPOVER") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)   // bring the popover on top for capture
            self?.togglePopover(nil)
            self?.popover.contentViewController?.view.window?.orderFrontRegardless()
            if let q = UserDefaults.standard.string(forKey: "NOVEX_DEBUG_ASK"), !q.isEmpty {
                Task { @MainActor in await BriefingService.shared.answerQuestion(q) }
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            BriefingService.shared.clearFocus()   // a normal click shows the briefing
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Let the panel's TextField accept keyboard focus.
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
