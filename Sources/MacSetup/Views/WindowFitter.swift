import SwiftUI
import AppKit

/// The window's current content size, measured from AppKit.
///
/// SwiftUI was proposing the content's own (enormous) ideal height rather than
/// the window's height, so every ScrollView laid out at full content size,
/// decided nothing needed scrolling, and got clipped by the window — leaving the
/// top and bottom of every pane unreachable. Pinning the root view to the size
/// AppKit reports gives the scroll views a real bound to work with.
@MainActor
final class WindowMetrics: ObservableObject {
    @Published var contentSize: CGSize = .zero
}

/// Keeps the window inside the screen's usable area, on any Mac.
///
/// SwiftUI sizes a window from its content's ideal size, and this content is
/// deliberately flexible, so the window wanted the full height of the display —
/// including the strip the Dock occupies, which hid the bottom bar. Trying to
/// resize it afterwards turns into a fight with SwiftUI's own layout pass.
///
/// Setting `maxSize` instead lets AppKit enforce the limit: SwiftUI simply
/// cannot ask for more. `visibleFrame` already excludes the menu bar and Dock,
/// so this is correct on a 13" Air, a 16" Pro, or an external display, and it
/// updates when the window moves between screens.
struct WindowFitter: NSViewRepresentable {
    @ObservedObject var metrics: WindowMetrics
    var minSize = NSSize(width: 720, height: 480)
    var preferred = NSSize(width: 1180, height: 800)
    /// Open filling the screen's usable area rather than at `preferred`.
    var maximized = true

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window, min: minSize,
                                       preferred: preferred, maximized: maximized,
                                       metrics: metrics)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window, min: minSize,
                                       preferred: preferred, maximized: maximized,
                                       metrics: metrics)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator {
        private weak var window: NSWindow?
        private var tokens: [NSObjectProtocol] = []
        private var minSize = NSSize(width: 720, height: 480)
        private var preferred = NSSize(width: 1180, height: 800)
        private var maximized = true
        private var metrics: WindowMetrics?

        func attach(to window: NSWindow?, min: NSSize, preferred: NSSize,
                    maximized: Bool, metrics: WindowMetrics) {
            guard let window else { return }
            self.minSize = min
            self.preferred = preferred
            self.maximized = maximized
            self.metrics = metrics
            if self.window !== window {
                self.window = window
                observe(window)
                applyLimits(initial: true)
            } else {
                applyLimits(initial: false)
            }
        }

        private func observe(_ window: NSWindow) {
            for t in tokens { NotificationCenter.default.removeObserver(t) }
            tokens = [NSWindow.didChangeScreenNotification, NSWindow.didMoveNotification,
                      NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification]
                .map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        // The observer is registered on .main, so this is
                        // already the main actor — the compiler just cannot
                        // see that through the queue argument.
                        MainActor.assumeIsolated { self?.applyLimits(initial: false) }
                    }
                }
        }

        private func applyLimits(initial: Bool) {
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let usable = screen.visibleFrame
            // Maximised means filling the usable area exactly. `visibleFrame`
            // already excludes the menu bar and the Dock, so this fills the
            // screen without hiding the action bar behind the Dock — which is
            // the failure mode a naive "full screen height" would reintroduce.
            let margin: CGFloat = maximized ? 0 : 12
            let cap = NSSize(width: usable.width - margin * 2, height: usable.height - margin * 2)

            window.minSize = NSSize(width: Swift.min(minSize.width, cap.width),
                                    height: Swift.min(minSize.height, cap.height))
            // AppKit enforces this, so SwiftUI cannot grow past the usable area.
            window.maxSize = cap

            var frame = window.frame
            frame.size.width = Swift.min(frame.width, cap.width)
            frame.size.height = Swift.min(frame.height, cap.height)
            if initial {
                let want = maximized ? cap : preferred
                frame.size.width = Swift.min(want.width, cap.width)
                frame.size.height = Swift.min(want.height, cap.height)
                frame.origin.x = usable.midX - frame.width / 2
                frame.origin.y = usable.midY - frame.height / 2
            }
            frame.origin.x = Swift.min(Swift.max(frame.origin.x, usable.minX + margin),
                                       usable.maxX - frame.width - margin)
            frame.origin.y = Swift.min(Swift.max(frame.origin.y, usable.minY + margin),
                                       usable.maxY - frame.height - margin)

            if frame != window.frame {
                window.setFrame(frame, display: true, animate: false)
            }
            publish(window)
        }

        /// Report the usable content area so the root view can match it exactly.
        private func publish(_ window: NSWindow) {
            let size = window.contentLayoutRect.size
            guard size.width > 0, size.height > 0 else { return }
            if metrics?.contentSize != size { metrics?.contentSize = size }
        }

        deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }
    }
}
