import SwiftUI
import AppKit

@main
struct ClaudeNotchApp: App {
    // Bridges SwiftUI's App lifecycle to a classic AppKit AppDelegate.
    // Kotlin-аналог: как @HiltAndroidApp подключает кастомный Application.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // We don't want a main WindowGroup — the notch overlay is created
        // manually in AppDelegate. `Settings` is the macOS "no main window"
        // escape hatch: it only opens on ⌘, and we don't care if it does.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchWindow: NSWindow?
    private let state = NotchState()
    private lazy var socketServer = SocketServer { [weak self] event in
        Task { @MainActor in self?.state.show(event) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        notchWindow = makeNotchWindow(on: screen)
        notchWindow?.orderFrontRegardless()
        socketServer.start()
    }

    // MARK: - Window construction

    private func makeNotchWindow(on screen: NSScreen) -> NSPanel {
        let frame = Self.notchFrame(on: screen)

        // NSPanel + .nonactivatingPanel: click on the overlay does NOT activate
        // our app, so focus stays on whatever the user was using.
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating         // above normal app windows
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true   // key only when a field/button needs it
        panel.hidesOnDeactivate = false
        // Visible on every Space and even when another app is fullscreen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        panel.contentView = NSHostingView(rootView: NotchView(state: state))
        return panel
    }

    /// Rect positioned at the top-center of the screen, roughly sitting on
    /// the physical notch. `safeAreaInsets.top` returns the notch height on
    /// notched MacBooks and 0 on older machines — fall back to 32pt so the
    /// window is still visible for testing on non-notched screens.
    private static func notchFrame(on screen: NSScreen) -> NSRect {
        let notchHeight = max(screen.safeAreaInsets.top, 32)
        let pillWidth: CGFloat = 220
        // NSScreen uses bottom-left origin — maxY is the top of the screen.
        let x = screen.frame.midX - pillWidth / 2
        let y = screen.frame.maxY - notchHeight
        return NSRect(x: x, y: y, width: pillWidth, height: notchHeight)
    }
}
