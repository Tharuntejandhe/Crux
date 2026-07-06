import SwiftUI
import AppKit

/// Full-panel Settings overlay: the morning-digest toggle, VIP senders, muted
/// senders, and about/quit. Everything it controls is local + on-device.
struct SettingsView: View {
    let service: BriefingService
    let onClose: () -> Void

    @AppStorage("digestEnabled") private var digestEnabled = true
    @AppStorage("flightAnimationEnabled") private var flightAnimationEnabled = true
    @AppStorage("updateCheckEnabled") private var updateCheckEnabled = true
    @AppStorage("ownerName") private var ownerName = ""
    @AppStorage("ownerEmail") private var ownerEmail = ""
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var perfMode = PerfMode.current
    /// Bumped to re-read the (non-observable) VIP/Mute stores after an edit.
    @State private var rev = 0
    @State private var interestInput = ""

    var body: some View {
        let _ = rev
        return VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    nameRow
                    interestsSection
                    launchRow
                    perfRow
                    digestRow
                    animationRow
                    updateRow
                    voiceRow
                    learnedSection
                    vipSection
                    mutedSection
                    aboutSection
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Spacer()
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .appKitTap(onClose)
        }
        .padding(.bottom, 6)
    }

    // MARK: - Owner

    private var nameRow: some View {
        VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Your name").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                TextField("What should I call you?", text: $ownerName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
        }
        HStack(spacing: 10) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Your email").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("So Novex knows mail from you is a note, not a reply")
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45))
                TextField("you@example.com", text: $ownerEmail)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .onSubmit { OwnerIdentity.learn([ownerEmail]) }
            }
            Spacer()
        }
        }
    }

    // MARK: - Digest

    private var digestRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.horizon.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Morning digest")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("One daily “what needs you” notification")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            togglePill(on: digestEnabled) { digestEnabled.toggle() }
        }
    }

    // MARK: - Notification animation

    private var launchRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "power")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Launch at login").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(LoginItem.needsApproval
                     ? "Approve Novex under Login Items in System Settings"
                     : "Start Novex automatically when you log in")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            togglePill(on: launchAtLogin) {
                LoginItem.setEnabled(!launchAtLogin)
                launchAtLogin = LoginItem.isEnabled
            }
        }
    }

    private var perfRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Performance").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(perfMode.detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            HStack(spacing: 4) {
                ForEach(PerfMode.allCases, id: \.self) { m in
                    Text(m.label)
                        .font(.system(size: 10, weight: .semibold))
                        .fixedSize()   // never wrap "Auto"→"Aut/o" or "Saver"→"Save/r"
                        .foregroundStyle(perfMode == m ? .black.opacity(0.85) : .white.opacity(0.7))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(perfMode == m ? Color.cyan.opacity(0.8) : Color.white.opacity(0.10)))
                        .appKitTap { PerfMode.set(m); perfMode = m; rev += 1 }
                }
            }
        }
    }

    private var animationRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Notification animation")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("The dot that flies from the card to the menu bar")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            togglePill(on: flightAnimationEnabled) { flightAnimationEnabled.toggle() }
        }
    }

    // MARK: - Update check (the only network touch)

    private var updateRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Check for updates")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text("Once a day, anonymously, via GitHub. The only time Novex uses the network")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            togglePill(on: updateCheckEnabled) {
                updateCheckEnabled.toggle()
                Task { await UpdateChecker.shared.refreshForSettingChange() }
            }
        }
    }

    // MARK: - Voice quality (shown only when the Mac has no natural voice)

    @ViewBuilder
    private var voiceRow: some View {
        if !SpeechService.hasNaturalVoice {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Make Novex's voice human")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Your Mac only has the robotic voice. Download a free Premium one (one-time)")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("Get voice")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.cyan)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.cyan.opacity(0.16)))
                    .appKitTap { SpeechService.openVoiceSettings() }
            }
        }
    }

    private func togglePill(on: Bool, _ action: @escaping () -> Void) -> some View {
        Text(on ? "On" : "Off")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(on ? .black.opacity(0.85) : .white.opacity(0.7))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(on ? Color.green.opacity(0.8) : Color.white.opacity(0.10)))
            .appKitTap(action)
    }

    // MARK: - VIPs

    private var vipSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("VIP SENDERS", hint: "Always top of the briefing + always notify")
            let vips = VIPStore.all().sorted()
            if vips.isEmpty {
                Text("None yet. Star someone below.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
            ForEach(vips, id: \.self) { addr in
                personRow(name: addr, address: addr, trailing: "Remove", tint: .orange) {
                    VIPStore.remove(addr); rev += 1
                }
            }
            let candidates = service.recentSenders().filter { !VIPStore.isVIP($0.address) }
            if !candidates.isEmpty {
                Text("Add from recent")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 2)
                ForEach(candidates, id: \.address) { s in
                    personRow(name: s.name, address: s.address, trailing: "★ VIP", tint: .yellow) {
                        VIPStore.add(s.address); rev += 1
                    }
                }
            }
        }
    }

    // MARK: - What Novex learned about you

    private var interestsSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("YOUR INTERESTS", hint: "Your field or topics, so “Worth a look” surfaces the right reads")
            HStack(spacing: 8) {
                Image(systemName: "tag.fill")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).frame(width: 16)
                TextField("e.g. robotics, computer vision, startups", text: $interestInput)
                    .textFieldStyle(.plain).font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.85))
                    .onSubmit(addInterests)
                if !interestInput.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Add")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.cyan)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.cyan.opacity(0.16)))
                        .appKitTap(addInterests)
                }
            }
            let interests = OwnerModel.interests()
            if !interests.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(interests, id: \.self) { word in
                            Text(word)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.cyan.opacity(0.9))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(Color.cyan.opacity(0.12)))
                        }
                    }
                }
            }
        }
    }

    private func addInterests() {
        let t = interestInput.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        OwnerModel.seedInterests(t)
        interestInput = ""
        rev += 1
        Task { await service.refresh() }   // recompute Discover with the new interests
    }

    // MARK: - Learned

    @ViewBuilder
    private var learnedSection: some View {
        let ignored = LearnStore.ignoredSuggestions()
        if !ignored.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                label("LEARNED", hint: "You keep skipping these. Mute them?")
                ForEach(ignored, id: \.self) { addr in
                    personRow(name: addr, address: addr, trailing: "Mute", tint: .orange) {
                        MuteStore.mute(addr); rev += 1
                    }
                }
            }
        }
    }

    // MARK: - Muted

    private var mutedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            label("MUTED SENDERS", hint: "Hidden across Novex")
            let muted = MuteStore.all().sorted()
            if muted.isEmpty {
                Text("No muted senders.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
            ForEach(muted, id: \.self) { addr in
                personRow(name: addr, address: addr, trailing: "Unmute", tint: .cyan) {
                    MuteStore.unmute(addr); rev += 1
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().background(Color.white.opacity(0.08))
            HStack(spacing: 8) {
                Text("Novex · on-device, private · v0.1")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                Spacer()
                Text("Send feedback")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .appKitTap(sendFeedback)
                Text("Quit")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                    .appKitTap { NSApplication.shared.terminate(nil) }
            }
        }
    }

    /// Opens the user's mail client with a prefilled report. 100% local — nothing
    /// is sent anywhere until the user hits send. (Swap to a GitHub Issues URL
    /// once the repo is public.)
    private func sendFeedback() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let body = "\n\n\n---\nApp: Novex v0.1\nmacOS: \(os)\nWhat happened or what would make it better:"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let subject = "Novex feedback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let url = URL(string: "mailto:ishanai4567@gmail.com?subject=\(subject)&body=\(body)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Pieces

    private func label(_ text: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).font(.system(size: 9, weight: .bold)).tracking(0.7)
                .foregroundStyle(.white.opacity(0.4))
            Text(hint).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.32))
        }
    }

    private func personRow(name: String, address: String, trailing: String,
                           tint: Color, _ action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(width: 18)
            Text(name)
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            Spacer(minLength: 6)
            Text(trailing)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint.opacity(0.95))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.14)))
                .appKitTap(action)
        }
    }
}
