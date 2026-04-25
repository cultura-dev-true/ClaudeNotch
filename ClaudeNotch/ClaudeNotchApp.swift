import SwiftUI
import AppKit

@main
struct ClaudeNotchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Properties

    private var notchPanel: NSPanel?
    private let state = NotchState()
    private lazy var socketServer = SocketServer { [weak self] request in
        Task { @MainActor in self?.state.handle(request) }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        notchPanel = makeNotchPanel(on: screen, size: state.panelSize)
        notchPanel?.orderFrontRegardless()

        state.onPanelSizeNeedsUpdate = { [weak self] size in
            self?.resizePanel(to: size)
        }

        socketServer.start()
    }

    // MARK: Panel

    private func makeNotchPanel(on screen: NSScreen, size: CGSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame(for: size, on: screen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isOpaque = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: NotchView(state: state))
        return panel
    }

    /// Rect at top-center of the screen for the given size. Snaps y such that
    /// the top of the panel touches the top of the screen (covers the notch
    /// on MacBooks that have one).
    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func resizePanel(to size: CGSize) {
        guard let panel = notchPanel, let screen = NSScreen.main else { return }
        panel.setFrame(frame(for: size, on: screen), display: true, animate: true)
    }
}
