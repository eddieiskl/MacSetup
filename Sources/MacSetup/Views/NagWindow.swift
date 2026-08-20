import SwiftUI
import AppKit

/// The full-screen update screen, shown on every display.
///
/// A note on what this is *not*: it cannot be System Settings itself. macOS
/// gives no app control over another app's windows — level, size and ordering
/// all belong to the owning process — so nothing can force Software Update
/// full-screen and keep it above everything. What is possible is MacSetup's
/// own window doing exactly that, with a button that opens Software Update.
/// That is how every managed-update tool on macOS works, for the same reason.
@MainActor
final class NagWindowController {

    static let shared = NagWindowController()

    private var windows: [NSWindow] = []
    private var screenToken: NSObjectProtocol?
    private(set) var isShowing = false

    /// Called when the user asks for a few more minutes.
    var onSnooze: ((Int) -> Void)?
    /// Called when the user chooses to update.
    var onUpdate: (() -> Void)?

    func show(update: SystemUpdate, days: Int, policy: NagPolicy) {
        guard !isShowing else { return }
        isShowing = true

        // If the installer was already fetched overnight, the user is a click
        // away from starting, not an 18 GB download away.
        let ready = OSInstallerCache.cached(matching: update)

        let content = NagView(
            update: update,
            days: days,
            cached: ready,
            snoozeMinutes: policy.snooze(days: days),
            pastDeadline: policy.isPastDeadline(days: days),
            onUpdate: { [weak self] in
                self?.onUpdate?()
                if let ready { OSInstallerCache.open(ready) }
                else { UnlockThrottle.openSoftwareUpdate() }
                self?.dismiss()
            },
            onSnooze: { [weak self] minutes in
                self?.onSnooze?(minutes)
                self?.dismiss()
            })

        // One window per display, so a second monitor is not a way around it.
        for screen in NSScreen.screens {
            let hosting = NSHostingController(rootView: content)
            let w = NSWindow(contentViewController: hosting)
            w.styleMask = [.borderless]
            w.setFrame(screen.frame, display: true)
            w.isOpaque = true
            w.backgroundColor = .windowBackgroundColor
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            // Above ordinary windows and above the menu bar. Not above the
            // login window or a screen saver, which is correct — this must
            // never be able to cover a lock screen.
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
            w.hidesOnDeactivate = false
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }

        // A display plugged in or unplugged afterwards would otherwise leave an
        // uncovered screen to work on.
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refit() }
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func refit() {
        for (w, screen) in zip(windows, NSScreen.screens) {
            w.setFrame(screen.frame, display: true)
        }
    }

    func dismiss() {
        for w in windows { w.orderOut(nil); w.close() }
        windows.removeAll()
        if let t = screenToken { NotificationCenter.default.removeObserver(t) }
        screenToken = nil
        isShowing = false
    }
}

/// The contents of the update screen.
struct NagView: View {
    let update: SystemUpdate
    let days: Int
    var cached: OSInstallerCache.Cached? = nil
    let snoozeMinutes: Int
    let pastDeadline: Bool
    var onUpdate: () -> Void
    var onSnooze: (Int) -> Void

    private var headline: String {
        if days >= 30 { return "macOS is a month out of date" }
        if pastDeadline { return "This update is overdue" }
        return "Time to update macOS"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                Image(systemName: pastDeadline ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(pastDeadline ? .orange : .accentColor)

                Text(headline)
                    .font(.system(size: 34, weight: .semibold))

                Text("\(update.title) has been waiting \(days) day\(days == 1 ? "" : "s").")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)

                // Saying why it has to be them, so it does not read as an app
                // being difficult for no reason.
                Text("MacSetup installs your apps for you, but it cannot install macOS itself — "
                     + "Apple requires your password for that, typed into macOS's own prompt. "
                     + (cached == nil
                        ? "It takes a few minutes and a restart."
                        : "The download is already done, so all that is left is your password and a restart."))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)

                if let cached {
                    Label("Already downloaded (\(cached.sizeText)) — nothing to wait for",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                } else {
                    Text("\(update.version) · \(update.sizeText)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 14) {
                    Button(action: onUpdate) {
                        Text(cached == nil ? "Open Software Update" : "Start the installer")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 22).padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    Button {
                        onSnooze(snoozeMinutes)
                    } label: {
                        Text(snoozeMinutes >= 60
                             ? "Not now — remind me in an hour"
                             : "I'm in the middle of something — \(snoozeMinutes) minutes")
                            .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .padding(.top, 6)

                if pastDeadline {
                    Text("Deferring now only buys \(snoozeMinutes) minutes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Text("MacSetup")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
