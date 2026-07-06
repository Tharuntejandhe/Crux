import Foundation
import UserNotifications

/// Fires on-device local notifications when something that actually needs the
/// user lands — batched, throttled, and Focus-aware (`interruptionLevel = .active`
/// means macOS suppresses it during Do Not Disturb / a Focus). This is what makes
/// Novex useful *while you work* instead of only when you glance at it.
///
/// 100% local: nothing is sent anywhere. This only asks macOS to draw a banner
/// from data already on the machine.
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var authorized = false
    private var didRequest = false

    private let lastNotifiedKey = "notif.lastNotifiedMessageDate"
    private let lastFiredKey = "notif.lastFiredAt"
    private let lastDigestDayKey = "notif.lastDigestDay"
    /// Never tap the user more than once per this window — anti-spam.
    private let minInterval: TimeInterval = 600  // 10 minutes

    private init() {}

    /// Ask for notification permission once (after onboarding, when the service
    /// starts). The system shows its prompt a single time.
    func requestAuthorizationIfNeeded() async {
        guard !didRequest else { return }
        didRequest = true
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
    }

    /// Decide whether this refresh warrants a nudge, and fire one if so.
    /// - newestMessageDate: date of the newest message currently visible.
    /// - importantCount: how many briefing items genuinely need the user.
    /// - headline: the AI one-liner, used as the notification body when present.
    func consider(newestMessageDate: Date, importantCount: Int, headline: String?) async {
        guard authorized else { return }

        // Baseline on first run: remember where we are and NEVER notify about the
        // existing backlog — only about mail that arrives from now on.
        guard let lastNotified = UserDefaults.standard.object(forKey: lastNotifiedKey) as? Date else {
            UserDefaults.standard.set(newestMessageDate, forKey: lastNotifiedKey)
            return
        }
        guard newestMessageDate > lastNotified else { return }     // nothing newer arrived
        guard importantCount > 0 else {                            // arrived, but nothing that needs them
            UserDefaults.standard.set(newestMessageDate, forKey: lastNotifiedKey)
            return
        }
        // Throttle: at most one nudge per `minInterval`.
        let lastFired = UserDefaults.standard.object(forKey: lastFiredKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastFired) >= minInterval else { return }

        let content = UNMutableNotificationContent()
        content.title = "Novex"
        let cleaned = headline?.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = (cleaned?.isEmpty == false ? cleaned! :
            "\(importantCount) thing\(importantCount == 1 ? "" : "s") need you")
        content.interruptionLevel = .active   // Focus-aware: suppressed during DND
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "novex.brief.\(Int(newestMessageDate.timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await center.add(request)

        UserDefaults.standard.set(newestMessageDate, forKey: lastNotifiedKey)
        UserDefaults.standard.set(Date(), forKey: lastFiredKey)
    }

    /// A once-a-day "good morning, here's what needs you" digest. Fires at most
    /// once per calendar day, only after 7am local, and only when something
    /// actually needs the user. Distinct from `consider` (per-arrival nudges).
    func considerDailyDigest(actionCounts: [AIAction: Int], importantCount: Int, now: Date = Date()) async {
        guard authorized else { return }
        // User can switch the morning digest off in Settings (default on).
        guard UserDefaults.standard.object(forKey: "digestEnabled") as? Bool ?? true else { return }
        let day = Self.dayStamp(now)
        guard UserDefaults.standard.string(forKey: lastDigestDayKey) != day else { return }
        // Approximate "morning": don't fire in the small hours.
        guard Calendar.current.component(.hour, from: now) >= 7 else { return }
        let actionable = actionCounts.values.reduce(0, +)
        guard actionable > 0 || importantCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Novex · Good morning"
        content.body = Self.digestBody(actionCounts: actionCounts, importantCount: importantCount)
        content.interruptionLevel = .active
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: "novex.digest.\(day)", content: content, trigger: nil))
        UserDefaults.standard.set(day, forKey: lastDigestDayKey)
    }

    /// Nudge the user that snoozed items have come back.
    func notifyWoken(_ items: [SnoozedItem]) async {
        guard authorized, !items.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if items.count == 1 {
            content.title = "Novex · Back"
            content.body = "⏰ \(items[0].title)"
        } else {
            content.title = "Novex · \(items.count) snoozed items are back"
            content.body = items.prefix(3).map(\.title).joined(separator: " · ")
        }
        content.interruptionLevel = .active
        content.sound = .default
        try? await center.add(UNNotificationRequest(
            identifier: "novex.wake.\(Int(Date().timeIntervalSince1970))", content: content, trigger: nil))
    }

    // MARK: - Digest phrasing (pure, testable)

    nonisolated static func dayStamp(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Compose a natural digest line from the action breakdown, e.g.
    /// "3 things need you today — a reply, a payment, and a review."
    nonisolated static func digestBody(actionCounts: [AIAction: Int], importantCount: Int) -> String {
        func phrase(_ a: AIAction, _ n: Int) -> String? {
            guard n > 0 else { return nil }
            switch a {
            case .reply:   return n == 1 ? "a reply" : "\(n) replies"
            case .pay:     return n == 1 ? "a payment" : "\(n) payments"
            case .confirm: return n == 1 ? "a confirmation" : "\(n) to confirm"
            case .review:  return n == 1 ? "a review" : "\(n) to review"
            default:       return nil
            }
        }
        let parts = [AIAction.reply, .pay, .confirm, .review].compactMap { phrase($0, actionCounts[$0] ?? 0) }
        let replyN: Int = actionCounts[.reply] ?? 0
        let payN: Int = actionCounts[.pay] ?? 0
        let confirmN: Int = actionCounts[.confirm] ?? 0
        let reviewN: Int = actionCounts[.review] ?? 0
        let n = replyN + payN + confirmN + reviewN
        if parts.isEmpty {
            let c = max(importantCount, 1)
            return "\(c) thing\(c == 1 ? "" : "s") need\(c == 1 ? "s" : "") your attention today."
        }
        return "\(n) thing\(n == 1 ? "" : "s") need\(n == 1 ? "s" : "") you today: \(listPhrase(parts))."
    }

    private nonisolated static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0:  return ""
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
