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
    private let mouseMonitor = MouseLocationMonitor()
    /// Last hit-test result reported to NotchState. Compared against incoming
    /// events so we forward only real transitions, not "still outside" noise.
    /// Without this, every mouse-move while the cursor is outside the panel
    /// would re-trigger setHovering(false) and reset the collapse timer.
    private var lastReportedInside = false

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        state.notchHeight = NotchGeometry.notchHeight(of: screen)
        state.notchWidth = NotchGeometry.notchWidth(of: screen)

        NSLog("[ClaudeNotch] screen.frame=\(screen.frame)")
        NSLog("[ClaudeNotch] screen.visibleFrame=\(screen.visibleFrame)")
        NSLog("[ClaudeNotch] safeAreaInsets.top=\(screen.safeAreaInsets.top)")
        NSLog("[ClaudeNotch] notchHeight resolved=\(state.notchHeight)")
        NSLog("[ClaudeNotch] notchWidth resolved=\(state.notchWidth)")

        notchPanel = makeNotchPanel(on: screen, size: state.panelSize)
        notchPanel?.orderFrontRegardless()

        if let panel = notchPanel {
            NSLog("[ClaudeNotch] panel.frame after order=\(panel.frame)")
            // Re-apply the frame after orderFront — on the initial show macOS
            // may clamp the panel under the menu bar; setting it again with
            // .screenSaver level seems to stick.
            panel.setFrame(frame(for: state.panelSize, on: screen), display: true)
            NSLog("[ClaudeNotch] panel.frame after re-set=\(panel.frame)")
        }

        state.onPanelSizeNeedsUpdate = { [weak self] size in
            self?.resizePanel(to: size)
        }

        socketServer.start()
        startMouseTracking()
        installSpaceSwitchHider()
    }

    /// `.canJoinAllSpaces` makes the panel visible on every Space at once —
    /// great for cross-app rendering, terrible for Space-swipe transitions
    /// because the pill becomes a "ghost" sitting on the destination Space
    /// during the animation. We hide the panel for a brief moment around
    /// the activeSpaceDidChange notification so the user only sees the pill
    /// settle in *after* the swipe finishes.
    private func installSpaceSwitchHider() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let panel = self?.notchPanel else { return }
            panel.animator().alphaValue = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                panel.animator().alphaValue = 1
            }
        }
    }

    // MARK: Panel

    private func makeNotchPanel(on screen: NSScreen, size: CGSize) -> NSPanel {
        let panel = NotchPanel(contentRect: frame(for: size, on: screen))
        panel.contentView = NSHostingView(rootView: NotchView(state: state))
        return panel
    }

    // MARK: Mouse hit-testing

    /// Drive `state.setHovering` from the system-wide mouse location.
    /// `addGlobalMonitorForEvents` fires when *another* app is front-most
    /// (NSTrackingArea / SwiftUI .onHover would not). The local monitor
    /// covers the case where ClaudeNotch itself is front-most.
    private func startMouseTracking() {
        mouseMonitor.onLocationChange = { [weak self] location in
            Task { @MainActor [weak self] in
                self?.handleMouseLocation(location)
            }
        }
        mouseMonitor.start()
    }

    private func handleMouseLocation(_ location: NSPoint) {
        guard let panel = notchPanel else { return }
        // CGRect.contains is half-open on the top/right edges. Cursor pinned to
        // the screen's top row (y == screen.frame.maxY == panel.frame.maxY)
        // would otherwise read as "outside" and trigger an endless flicker.
        let inside = inclusiveContains(panel.frame, location)
        // Compare against our own last-reported value rather than state.isHovering.
        // state.isHovering stays true during the 150ms collapse delay, so using
        // it would treat every mouse move outside the panel as a "new" transition
        // and reset the collapse timer, leaving the notch stuck open.
        if inside == lastReportedInside { return }
        lastReportedInside = inside
        NSLog("[ClaudeNotch] hover transition → \(inside) loc=\(location) panel=\(panel.frame)")
        state.setHovering(inside)
    }

    /// Closed-interval hit-test on all four sides — needed because the cursor
    /// can sit exactly on the screen's top edge while still being visually
    /// inside our panel.
    private func inclusiveContains(_ rect: NSRect, _ p: NSPoint) -> Bool {
        p.x >= rect.minX && p.x <= rect.maxX
            && p.y >= rect.minY && p.y <= rect.maxY
    }

    /// Rect at top-center of the screen for the given size. Top edge of the
    /// panel touches the absolute top of the screen so the pill aligns with
    /// the physical notch cutout (not the menu bar bottom).
    private func frame(for size: CGSize, on screen: NSScreen) -> NSRect {
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func resizePanel(to size: CGSize) {
        guard let panel = notchPanel, let screen = NSScreen.main else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        NSLog("[ClaudeNotch] resizePanel to \(size) front=\(frontApp) visible=\(panel.isVisible)")
        panel.setFrame(frame(for: size, on: screen), display: true, animate: true)
    }
}

// MARK: - MouseLocationMonitor

/// System-wide mouse-move observer. Combines a global monitor (fires when any
/// other app is front-most) and a local monitor (fires when ClaudeNotch
/// itself is front-most) so we get continuous mouse-location updates
/// regardless of focus. This is how NotchDrop and vibe-notch detect notch
/// hover; NSTrackingArea / SwiftUI .onHover are unreliable for accessory apps.
final class MouseLocationMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// Called on every mouse-moved event with the current screen-space cursor
    /// position. Caller is responsible for hit-testing and threading.
    var onLocationChange: ((NSPoint) -> Void)?

    func start() {
        let mask: NSEvent.EventTypeMask = .mouseMoved
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.onLocationChange?(NSEvent.mouseLocation)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.onLocationChange?(NSEvent.mouseLocation)
            return event
        }
        NSLog("[ClaudeNotch] mouse monitors: global=\(globalMonitor != nil) local=\(localMonitor != nil)")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    deinit { stop() }
}

// MARK: - NotchPanel

/// NSPanel subclass that renders over the menu bar and physical notch.
///
/// The combination of `.borderless + .nonactivatingPanel` style mask, a level
/// above `.mainMenu`, and a minimal collection behavior is what bypasses the
/// auto-clamp macOS otherwise applies to top-edge windows. This recipe is
/// shared by DynamicNotchKit, vibe-notch, NotchDrop, and boring.notch — all
/// of them subclass NSPanel rather than configure a vanilla one.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        // .mainMenu + 3 (= 27) — consensus across NotchDrop, vibe-notch, and
        // boring.notch. .screenSaver (1000) was too high: macOS treats it
        // like a system overlay and may skip rendering it when a foreground
        // app is fully composited.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        // Same flags NotchDrop and vibe-notch ship with. .canJoinAllSpaces is
        // required to keep the pill rendered above any foreground app on the
        // active Space — without it macOS only paints the panel when our app
        // is front-most. The "ghost during a Space swipe" side-effect is
        // mitigated by the alpha hide/restore in
        // ClaudeNotchApp.installSpaceSwitchHider().
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    // Note: we deliberately don't override `canBecomeKey` to true. As a
    // non-key panel, hover never steals focus from the user's foreground app.
}

// MARK: - NotchGeometry

/// Reads physical notch metrics from the screen so the SwiftUI view can size
/// the pill to match real hardware (e.g. ~32pt × ~190pt on 14"/16" MacBooks).
enum NotchGeometry {
    /// Top safe-area inset = notch height on notched MacBooks, 0 elsewhere.
    /// Falls back to 32pt for sanity if the system reports 0 unexpectedly.
    static func notchHeight(of screen: NSScreen) -> CGFloat {
        let inset = screen.safeAreaInsets.top
        return inset > 0 ? inset : 32
    }

    /// Hardware notch width derived from the gap between the menu-bar areas
    /// flanking the cutout. macOS exposes those as `auxiliaryTopLeftArea` /
    /// `auxiliaryTopRightArea` (NSRect?). Falls back to 190pt on screens
    /// without a notch or where the API returns nil.
    static func notchWidth(of screen: NSScreen) -> CGFloat {
        guard
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        else {
            return 190
        }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : 190
    }
}
