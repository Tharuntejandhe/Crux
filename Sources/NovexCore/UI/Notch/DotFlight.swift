import AppKit
import SwiftUI
import Observation

/// The "notification travels to Novex" animation. A small black dot flies from
/// the notch to the menu-bar Novex icon along a gentle arc, then dissolves
/// (scale + fade) as the panel opens — a premium Dynamic-Island-style handoff.
/// All coordinates are passed in live (screen space), so it works on ANY screen.
@MainActor
public final class DotFlight {
    private var window: NSPanel?
    private var timer: Timer?
    private let dot = FlightDot()
    private let size: CGFloat = 110       // roomy for the halo + dissolve scale
    private var start = CGPoint.zero
    private var end = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private let duration: CFTimeInterval = 1.2    // brisk but still smooth
    private let arc: CGFloat = 30          // gentle downward dip mid-flight
    private var onArrive: (() -> Void)?
    /// Bumped on every fly(); the delayed post-arrival cleanup checks it so a stale
    /// flight can't tear down a newer one (rapid successive notch cards).
    private var generation = 0

    public init() {}

    /// `from` and `to` are the dot's CENTER in screen coordinates (bottom-left
    /// origin). `onArrive` fires the instant it reaches the icon (open the panel).
    public func fly(from: CGPoint, to: CGPoint, onArrive: @escaping () -> Void) {
        cancel()
        generation += 1
        start = from; end = to; self.onArrive = onArrive

        let panel = NSPanel(contentRect: NSRect(x: from.x - size/2, y: from.y - size/2,
                                                width: size, height: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: FlightDotView(model: dot))
        host.frame = NSRect(origin: .zero, size: NSSize(width: size, height: size))
        panel.contentView = host
        panel.orderFrontRegardless()
        window = panel

        startTime = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0/120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func cancel() {
        timer?.invalidate(); timer = nil
        window?.orderOut(nil); window = nil
        dot.arrived = false
    }

    private func tick() {
        guard let window else { return }
        let raw = min(1, (CACurrentMediaTime() - startTime) / duration)
        let e = Self.easeInOut(raw)
        let x = start.x + (end.x - start.x) * e
        let y = start.y + (end.y - start.y) * e - sin(raw * .pi) * arc   // dip (screen y is up)
        window.setFrameOrigin(CGPoint(x: x - size/2, y: y - size/2))
        // Size TRANSFORMS along the path — swells mid-flight, settles small.
        dot.scale = 0.85 + 0.85 * sin(raw * .pi)
        if raw >= 1 { arrive() }
    }

    private func arrive() {
        timer?.invalidate(); timer = nil
        onArrive?()                 // open the panel at the moment it lands
        dot.arrived = true          // dot dissolves (scale + fade)
        let gen = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            // Only clean up if no newer flight started in the meantime.
            guard gen == self.generation else { return }
            cancel()
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2*t*t : 1 - pow(-2*t + 2, 2)/2
    }
}

@MainActor @Observable final class FlightDot {
    var arrived = false
    var scale: CGFloat = 0.85   // driven each tick → the size "transform"
}

private struct FlightDotView: View {
    @State var model: FlightDot
    var body: some View {
        ZStack {
            // Soft halo — gives the bead a designed, premium presence and a
            // gentle glow as it dissolves into the panel.
            Circle()
                .fill(Color.black.opacity(0.28))
                .frame(width: 26, height: 26)
                .blur(radius: 6)
            Circle()
                .fill(Color.black)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
        }
        .scaleEffect(model.arrived ? 3.2 : model.scale)
        .opacity(model.arrived ? 0 : 1)
        .animation(.easeOut(duration: 0.4), value: model.arrived)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
