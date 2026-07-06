import Foundation
import Observation

/// The ONLY network touch in Novex. An anonymous, at-most-once-a-day GET to
/// GitHub's public Releases API to see whether a newer Novex exists. It sends
/// nothing about you or your mail, runs only when enabled (Settings → "Check for
/// updates"), and fails silently. When a newer version is found it surfaces a
/// card in the daily briefing.
@MainActor
@Observable
public final class UpdateChecker {
    public static let shared = UpdateChecker()
    private init() {}

    /// ⚠️ Set this to your public repo ("owner/Novex") before release. While it's
    /// still `unconfiguredRepo`, the checker no-ops (no network) so dev builds
    /// never call out.
    nonisolated static let repo = "Tharuntejandhe/Novex"

    /// The "not configured yet" sentinel. The checker no-ops while `repo` still
    /// equals this. It must DIFFER from `repo` once a real repo is set — otherwise
    /// the guard in `fetch()` permanently disables update checks. (Regression
    /// guarded by a test.)
    nonisolated static let unconfiguredRepo = "OWNER/Novex"

    public struct Update: Equatable, Sendable {
        public let version: String   // e.g. "v1.2.0"
        public let url: String       // release page
        public let notes: String     // release title
    }

    /// nil when up to date / not checked / disabled.
    public private(set) var available: Update?

    private let lastCheckKey = "novex.update.lastCheck"
    private let enabledKey = "updateCheckEnabled"

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Check at most once per ~day. Call on launch / briefing refresh.
    public func checkIfDue() async {
        guard isEnabled else { available = nil; return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 23 * 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        await fetch()
    }

    /// Re-evaluate after the user toggles the setting.
    public func refreshForSettingChange() async {
        if isEnabled { await fetch() } else { available = nil }
    }

    private func fetch() async {
        guard Self.repo != Self.unconfiguredRepo,
              let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")
        else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return }
        // Only ever open a github.com URL from the update card. GitHub generates
        // html_url itself (release authors can't set it), but constraining the host
        // is cheap defense-in-depth so a tap can never navigate off-github.
        let fallbackPage = "https://github.com/\(Self.repo)/releases/latest"
        let apiPage = json["html_url"] as? String
        let page = (apiPage.flatMap { URL(string: $0)?.host == "github.com" ? $0 : nil }) ?? fallbackPage
        let notes = (json["name"] as? String) ?? ""
        available = Self.isNewer(tag, than: Self.currentVersion)
            ? Update(version: tag, url: page, notes: notes)
            : nil
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Numeric, component-wise version compare (tolerant of a leading "v").
    /// Pure — no actor state — so it stays `nonisolated` for easy testing.
    nonisolated static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { !$0.isNumber }).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
