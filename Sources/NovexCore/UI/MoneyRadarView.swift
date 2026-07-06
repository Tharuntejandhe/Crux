import SwiftUI
import AppKit

/// Money Radar tab — on-device subscription/spend detection from the local
/// Mail store. Free and open: the headline total, the full itemized list,
/// billing cycles, and trial alerts — all of it, no account, no paywall.
struct MoneyRadarView: View {
    @State private var service = MoneyRadarService()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch service.state {
            case .idle, .scanning:
                scanningCard
            case .needsFullDiskAccess:
                statusCard(icon: "lock.shield", title: "Grant Full Disk Access",
                           detail: "Money Radar reads renewal emails from Mail's local store, never your bank.")
                    .appKitTap { openFDASettings() }
                    .help("Open Full Disk Access settings")
            case .error(let msg):
                statusCard(icon: "exclamationmark.triangle", title: "Couldn't scan", detail: msg)
            case .empty:
                statusCard(icon: "checkmark.seal", title: "No subscriptions found",
                           detail: "Nothing recurring in your recent mail. We'll keep watching.")
            case .ready:
                report
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .task { await service.scanIfNeeded() }
    }

    // MARK: - Report

    private func openFDASettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var report: some View {
        let r = service.report
        // The hook — always visible, even on the free tier.
        VStack(alignment: .leading, spacing: 3) {
            Text(headlineAmount(r.totalYearly, currency: r.primaryCurrency))
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
            Text(subtitle(r))
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.bottom, 2)

        // Trial-converting alert (highest value) — shown to everyone.
        if !r.convertingTrials.isEmpty {
            trialBanner(count: r.convertingTrials.count)
        }

        // The full itemized list — free and open.
        ForEach(r.subscriptions) { sub in
            subscriptionRow(sub)
        }
    }

    private func subscriptionRow(_ sub: Subscription) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: sub.category.sfSymbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 18)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sub.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    if sub.isTrialConverting { trialPill }
                }
                Text(priceLine(sub))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            // Cancel — the action that actually saves money.
            if let cancel = MerchantCatalog.cancelURL(forKey: sub.merchantKey, displayName: sub.displayName) {
                Text("Cancel")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.14)))
                    .appKitTap { NSWorkspace.shared.open(cancel) }
                    .help("Open the cancellation page")
            }
            if let url = mailURL(sub) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
                    .appKitTap { NSWorkspace.shared.open(url) }
                    .help("Open the email in Mail")
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Small pieces

    private var scanningCard: some View {
        HStack(spacing: 12) {
            PulsingSparkle()
            VStack(alignment: .leading, spacing: 3) {
                Text("Scanning for subscriptions…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Reading renewal emails on-device")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
    }

    private func trialBanner(count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange.opacity(0.9))
            Text("\(count) free trial\(count == 1 ? "" : "s") about to start charging")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.16)))
    }

    private var trialPill: some View {
        Text("TRIAL ENDING")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.7)))
    }

    private func statusCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Helpers

    private func headlineAmount(_ yearly: Double, currency: String) -> String {
        let formatted = currencyString(yearly, code: currency)
        return yearly > 0 ? "\(formatted)/yr" : "Subscriptions found"
    }

    private func subtitle(_ r: MoneyRadarReport) -> String {
        let n = r.subscriptions.count
        let base = "across \(n) subscription\(n == 1 ? "" : "s")"
        // Be honest when the total only covers one of several currencies.
        if r.hasMixedCurrencies {
            return "\(base) · total in \(r.primaryCurrency) · we never touched your bank"
        }
        return "\(base) · we never touched your bank"
    }

    private func priceLine(_ sub: Subscription) -> String {
        var parts: [String] = []
        if let amount = sub.amount {
            let price = currencyString(amount, code: sub.currencyCode)
            let est = sub.amountSource == .estimatedFromCatalog ? " est." : ""
            parts.append("\(price)/\(sub.cycle.label)\(est)")
        } else {
            parts.append(sub.cycle.label)
        }
        if let next = sub.nextRenewal {
            parts.append("renews \(next.formatted(.dateTime.month(.abbreviated).day()))")
        }
        if sub.messageCount > 1 { parts.append("\(sub.messageCount) emails") }
        return parts.joined(separator: " · ")
    }

    private func currencyString(_ value: Double, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.maximumFractionDigits = value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? "\(value) \(code)"
    }

    private func mailURL(_ sub: Subscription) -> URL? {
        guard let id = sub.sourceMessageID else { return nil }
        let core = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard !core.isEmpty,
              let enc = core.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "message://%3C\(enc)%3E")
    }
}
