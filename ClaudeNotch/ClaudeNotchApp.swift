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

    // MARK: Sizes

    private let idlePillWidth: CGFloat = 220
    private let pendingPillWidth: CGFloat = 280
    private let extraHeightForButtons: CGFloat = 44

    // MARK: Properties

    private var notchPanel: NSPanel?
    private let state = NotchState()
    private lazy var socketServer = SocketServer { [weak self] request in
        Task { @MainActor in self?.state.handle(request) }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        notchPanel = makeNotchPanel(on: screen)
        notchPanel?.orderFrontRegardless()

        state.onDisplayChanged = { [weak self] display in
            self?.resize(for: display)
        }

        socketServer.start()
    }

    // MARK: Panel

    private func makeNotchPanel(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame(for: .idle, on: screen),
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

    /// Rect at top-center, sized according to the current display state.
    /// Notch height comes from `safeAreaInsets.top` (32pt fallback for
    /// non-notched screens). Pending adds 44pt below for the button row.
    private func frame(for display: NotchState.Display, on screen: NSScreen) -> NSRect {
        let notchHeight = max(screen.safeAreaInsets.top, 32)
        let width: CGFloat
        let height: CGFloat
        switch display {
        case .pending:
            width = pendingPillWidth
            height = notchHeight + extraHeightForButtons
        default:
            width = idlePillWidth
            height = notchHeight
        }
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height  // NSScreen uses bottom-left origin; maxY is top
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func resize(for display: NotchState.Display) {
        guard let panel = notchPanel, let screen = NSScreen.main else { return }
        panel.setFrame(frame(for: display, on: screen), display: true, animate: true)
    }
}
