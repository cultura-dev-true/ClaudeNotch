import Foundation
import AppKit
import ApplicationServices
import Network
import Observation

// MARK: - HookEvent

/// Parsed PreToolUse payload from the Python bridge. Carries everything the
/// notch UI needs to render both the compact one-liner and the hover-expanded
/// detail view.
struct HookEvent: Equatable {
    let sessionID: String
    let transcriptPath: String?
    let toolName: String
    /// Short one-liner for the compact pill (e.g. file basename, first words
    /// of a Bash command).
    let summary: String?
    /// Full text shown in the hover-expanded detail view (full command,
    /// absolute file path, etc.). Falls back to `summary` when missing.
    let detail: String?

    static func parse(_ data: Data) -> HookEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let toolName = object["tool_name"] as? String,
            let sessionID = object["session_id"] as? String
        else {
            return nil
        }

        let transcriptPath = object["transcript_path"] as? String
        let input = object["tool_input"] as? [String: Any]

        let detail: String? = {
            if let command = input?["command"] as? String { return command }
            if let filePath = input?["file_path"] as? String { return filePath }
            return nil
        }()
        let summary: String? = {
            if let command = input?["command"] as? String {
                return Self.firstLine(command)
            }
            if let filePath = input?["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
            return nil
        }()

        return HookEvent(
            sessionID: sessionID,
            transcriptPath: transcriptPath,
            toolName: toolName,
            summary: summary,
            detail: detail
        )
    }

    private static func firstLine(_ raw: String) -> String {
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(59)) + "…"
    }
}

// MARK: - ResponseDecision

enum ResponseDecision {
    case allow
    case deny(reason: String)
    case ask

    var hookOutputJSON: Data {
        let dict: [String: Any]
        switch self {
        case .allow:
            dict = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow"
            ]]
        case .deny(let reason):
            dict = ["hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason
            ]]
        case .ask:
            dict = [:]
        }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }
}

// MARK: - IncomingRequest

struct IncomingRequest: Identifiable {
    let id = UUID()
    let event: HookEvent
    let respond: (ResponseDecision) -> Void
}

// MARK: - SessionInfo

/// One Claude Code session we discovered on disk.
struct SessionInfo: Identifiable, Equatable {
    let id: String            // session UUID (filename without .jsonl)
    let transcriptPath: URL
    let projectPath: String   // decoded human path, e.g. "/Users/cultura/Xcode_Projects/ClaudeNotch"
    let modified: Date
    let title: String         // first user message, truncated

    var projectBasename: String {
        (projectPath as NSString).lastPathComponent
    }

    var relativeTime: String {
        Self.relativeFormatter.localizedString(for: modified, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

// MARK: - SessionStore

/// Reads Claude Code transcript files from ~/.claude/projects/ and produces
/// a list of the most recently active sessions across all projects.
enum SessionStore {
    static let projectsRoot: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/projects", isDirectory: true)
    }()

    /// Top N most recently modified sessions across every project.
    static func recentSessions(limit: Int = 3) -> [SessionInfo] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var scanned: [(url: URL, modified: Date)] = []
        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                scanned.append((file, mtime))
            }
        }

        scanned.sort { $0.modified > $1.modified }
        return scanned.prefix(limit).compactMap { makeInfo(from: $0.url, modified: $0.modified) }
    }

    // MARK: Private helpers

    private static func makeInfo(from url: URL, modified: Date) -> SessionInfo? {
        let id = url.deletingPathExtension().lastPathComponent
        let projectPath = decodeProjectDir(url.deletingLastPathComponent().lastPathComponent)
        let title = firstUserPrompt(in: url) ?? "(session \(id.prefix(8)))"
        return SessionInfo(
            id: id,
            transcriptPath: url,
            projectPath: projectPath,
            modified: modified,
            title: title
        )
    }

    /// Claude encodes the absolute project path by replacing "/" with "-".
    /// "/Users/cultura/Xcode_Projects/ClaudeNotch" -> "-Users-cultura-Xcode_Projects-ClaudeNotch"
    private static func decodeProjectDir(_ encoded: String) -> String {
        encoded.replacingOccurrences(of: "-", with: "/")
    }

    /// Read at most the first 8KB of the transcript and extract the first
    /// user-authored prompt as a title. Returns nil if nothing matches.
    private static func firstUserPrompt(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = (try? handle.read(upToCount: 8 * 1024)) ?? Data()
        let text = String(data: chunk, encoding: .utf8) ?? ""

        for line in text.split(separator: "\n").prefix(40) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if obj["type"] as? String != "user" { continue }

            guard let message = obj["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String {
                return truncate(text, to: 50)
            }
            if let parts = message["content"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String {
                        return truncate(text, to: 50)
                    }
                }
            }
        }
        return nil
    }

    private static func truncate(_ raw: String, to n: Int) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= n { return s }
        return String(s.prefix(n - 1)) + "…"
    }
}

// MARK: - DockAccessibility

/// Drives macOS Accessibility APIs to simulate a real Dock icon press.
/// This is the only way to get programmatic activation that matches a real
/// Dock click — including switching Spaces to the one where the target app
/// has windows (per the user's Mission Control preference).
///
/// Requires Accessibility trust. Calling `isTrusted(prompting: true)` triggers
/// the standard macOS permission prompt the first time.
enum DockAccessibility {
    static let dockBundleID = "com.apple.dock"

    /// Returns whether ClaudeNotch has Accessibility trust right now. With
    /// `prompting = true`, macOS shows its "wants to control your computer"
    /// dialog if trust is missing (no-op if already granted).
    @discardableResult
    static func isTrusted(prompting: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompting] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Find the Dock item with the given title and dispatch a press action.
    /// Returns true iff `AXPress` succeeded. Needs AX trust.
    @discardableResult
    static func pressDockItem(title: String) -> Bool {
        guard let pid = NSRunningApplication.runningApplications(
            withBundleIdentifier: dockBundleID
        ).first?.processIdentifier else {
            NSLog("[ClaudeNotch] Dock process not found")
            return false
        }
        let dock = AXUIElementCreateApplication(pid)

        guard let item = findDockItem(in: dock, matching: title) else {
            NSLog("[ClaudeNotch] no Dock item matched '\(title)' — check Claude is in Dock")
            return false
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if result != .success {
            NSLog("[ClaudeNotch] AXPress failed with error \(result.rawValue)")
        }
        return result == .success
    }

    // MARK: Private

    /// Depth-first search for an element whose title matches and whose role
    /// looks like a Dock item. We accept any role containing "DockItem" so
    /// we stay robust across macOS versions (`AXDockItem`,
    /// `AXApplicationDockItem`, etc.).
    private static func findDockItem(in element: AXUIElement, matching title: String) -> AXUIElement? {
        let role = attribute(of: element, key: kAXRoleAttribute) as? String ?? ""
        let itemTitle = attribute(of: element, key: kAXTitleAttribute) as? String ?? ""
        if role.lowercased().contains("dockitem"), itemTitle == title {
            return element
        }
        guard let children = attribute(of: element, key: kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let found = findDockItem(in: child, matching: title) { return found }
        }
        return nil
    }

    private static func attribute(of element: AXUIElement, key: String) -> Any? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success else { return nil }
        return ref
    }
}

// MARK: - ClaudeDesktopLauncher

/// High-level activation. Tries the AX Dock-click path first (gives a real
/// Space switch), falls back to LaunchServices if AX trust is missing or
/// the Dock item can't be found.
enum ClaudeDesktopLauncher {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let dockIconTitle = "Claude"

    /// Activate Claude Desktop as if the user clicked its Dock icon.
    /// - If Accessibility is trusted → AX press on the Dock item (switches
    ///   Spaces properly).
    /// - Otherwise → LaunchServices-based focus (no Space switch). On the
    ///   first failure this session, we also trigger the system permission
    ///   prompt so the user can grant access.
    static func activate() {
        let trusted = DockAccessibility.isTrusted(prompting: false)
        if trusted, DockAccessibility.pressDockItem(title: dockIconTitle) {
            return
        }

        // Not trusted, or press failed. Prompt the user once per launch,
        // then fall through. Without this gate, every click would spawn
        // another "wants to control your computer" dialog.
        if !trusted, !hasPromptedThisSession {
            hasPromptedThisSession = true
            _ = DockAccessibility.isTrusted(prompting: true)
        }

        launchServicesFallback()
    }

    private static var hasPromptedThisSession = false

    /// Open a NEW Code session in Claude Desktop at the given folder.
    /// Uses the documented `claude://code/new?folder=<path>` deeplink.
    static func openNewCodeSession(inFolder folder: String?) {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/new"
        if let folder, !folder.isEmpty {
            components.queryItems = [URLQueryItem(name: "folder", value: folder)]
        }
        guard let url = components.url else { return }
        openURL(url)
    }

    // MARK: Private

    private static func launchServicesFallback() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
            return
        }
        openURL(URL(string: "claude://")!)
    }

    private static func openURL(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
    }
}

// MARK: - NotchState

@MainActor
@Observable
final class NotchState {

    enum Display: Equatable {
        case idle
        case observing(HookEvent)
        case pending(IncomingRequest)

        static func == (lhs: Display, rhs: Display) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.observing(a), .observing(b)): return a == b
            case let (.pending(a), .pending(b)): return a.id == b.id
            default: return false
            }
        }
    }

    // MARK: Observable properties

    private(set) var display: Display = .idle
    private(set) var isHovering: Bool = false
    private(set) var recentSessions: [SessionInfo] = []

    /// Physical notch height of the active screen, in points. Set once at
    /// launch from `NSScreen.safeAreaInsets.top`. Drives the resting pill
    /// height so the visible black shape matches the hardware cutout.
    var notchHeight: CGFloat = 32

    /// Physical notch width — the gap between the left/right menu-bar
    /// auxiliary areas. Resting pill uses this width exactly so it fuses with
    /// the hardware cutout instead of overhanging it.
    var notchWidth: CGFloat = 190

    // MARK: Callbacks

    /// Fired whenever the computed panel size changes. AppDelegate subscribes
    /// to resize the NSPanel accordingly.
    var onPanelSizeNeedsUpdate: ((CGSize) -> Void)?

    // MARK: Private

    private var queue: [IncomingRequest] = []
    private var autoClearTask: Task<Void, Never>?
    private var pendingTimeoutTask: Task<Void, Never>?
    private var hoverCollapseTask: Task<Void, Never>?

    private let autoClearDelay: Duration = .seconds(6)
    private let pendingTimeoutDelay: Duration = .seconds(30)
    private let hoverCollapseDelay: Duration = .milliseconds(150)

    // MARK: Derived size

    /// Current size the panel should have based on display + hover state.
    /// Heights are layered on top of `notchHeight` so the pill always starts
    /// at the physical notch and grows downward.
    ///
    /// Idle and observing reserve transparent slack around the visible pill so
    /// hover events fire reliably even when the cursor isn't pixel-perfect on
    /// the notch.
    var panelSize: CGSize {
        let notch = notchHeight
        if shouldExpand { return CGSize(width: 380, height: notch + 220) }
        switch display {
        case .pending:
            return CGSize(width: 340, height: notch + 64)
        case .observing:
            // Wider + a bit taller than the notch — the pill grows past the
            // hardware cutout so the activity text is actually visible.
            return CGSize(width: max(notchWidth + 140, 320), height: notch + 18)
        case .idle:
            // Same shape as the notch + a transparent hover-catch buffer.
            return CGSize(width: notchWidth + 60, height: notch + 10)
        }
    }

    /// True only when idle AND user is hovering — we don't interrupt pending
    /// approval UI with a session list overlay.
    var shouldExpand: Bool {
        if case .idle = display, isHovering { return true }
        return false
    }

    // MARK: Hook input

    func handle(_ request: IncomingRequest) {
        if shouldPrompt(request.event) {
            if case .pending = display {
                queue.append(request)
            } else {
                showPending(request)
            }
        } else {
            request.respond(.ask)
            showObserving(request.event)
        }
    }

    // MARK: User actions

    func resolve(_ decision: ResponseDecision) {
        guard case .pending(let current) = display else { return }
        pendingTimeoutTask?.cancel()
        current.respond(decision)
        advanceQueue()
    }

    /// Called only on real hover transitions (the AppDelegate dedupes
    /// non-changes via its own `lastReportedInside`). Enter applies
    /// immediately; exit is debounced by `hoverCollapseDelay` so a quick
    /// flick of the cursor through the pill edge doesn't strand the panel
    /// in the wrong state.
    func setHovering(_ new: Bool) {
        if new {
            hoverCollapseTask?.cancel()
            hoverCollapseTask = nil
            guard !isHovering else { return }
            isHovering = true
            recentSessions = SessionStore.recentSessions(limit: 3)
            emitSizeUpdate()
            return
        }

        // Exiting — schedule a delayed collapse. If a collapse task is already
        // pending, leave it alone; restarting would let the timer reset
        // forever as the mouse keeps moving outside the panel.
        if hoverCollapseTask != nil { return }
        hoverCollapseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            self.hoverCollapseTask = nil
            if self.isHovering {
                self.isHovering = false
                self.emitSizeUpdate()
            }
        }
    }

    // MARK: Private

    private func shouldPrompt(_ event: HookEvent) -> Bool {
        event.toolName == "Bash"
    }

    private func showPending(_ request: IncomingRequest) {
        autoClearTask?.cancel()
        update(display: .pending(request))

        pendingTimeoutTask?.cancel()
        pendingTimeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.pendingTimeoutDelay)
            if !Task.isCancelled {
                self.resolve(.deny(reason: "Timed out waiting for ClaudeNotch user decision."))
            }
        }
    }

    private func showObserving(_ event: HookEvent) {
        pendingTimeoutTask?.cancel()
        update(display: .observing(event))

        autoClearTask?.cancel()
        autoClearTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.autoClearDelay)
            if !Task.isCancelled, case .observing = self.display {
                self.update(display: .idle)
            }
        }
    }

    private func advanceQueue() {
        if let next = queue.first {
            queue.removeFirst()
            showPending(next)
        } else {
            update(display: .idle)
        }
    }

    private func update(display new: Display) {
        display = new
        emitSizeUpdate()
    }

    private func emitSizeUpdate() {
        onPanelSizeNeedsUpdate?(panelSize)
    }
}

// MARK: - SocketServer

final class SocketServer {
    private let socketPath: String
    private let onRequest: (IncomingRequest) -> Void
    private var listener: NWListener?

    init(socketPath: String = "/tmp/claude-notch.sock",
         onRequest: @escaping (IncomingRequest) -> Void) {
        self.socketPath = socketPath
        self.onRequest = onRequest
    }

    func start() {
        try? FileManager.default.removeItem(atPath: socketPath)

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

            let listener = try NWListener(using: params)

            let path = socketPath
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    NSLog("[ClaudeNotch] listener ready at \(path)")
                case .failed(let error):
                    NSLog("[ClaudeNotch] listener failed: \(error)")
                case .cancelled:
                    NSLog("[ClaudeNotch] listener cancelled")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("[ClaudeNotch] listener start failed: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }

            if isComplete || error != nil {
                self.process(buffer, on: connection)
                return
            }

            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func process(_ data: Data, on connection: NWConnection) {
        guard !data.isEmpty else {
            connection.cancel()
            return
        }
        guard let event = HookEvent.parse(data) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            NSLog("[ClaudeNotch] parse failed; raw=\(raw)")
            connection.cancel()
            return
        }

        let request = IncomingRequest(event: event) { [weak self] decision in
            self?.send(decision, on: connection)
        }
        onRequest(request)
    }

    private func send(_ decision: ResponseDecision, on connection: NWConnection) {
        connection.send(content: decision.hookOutputJSON,
                        completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
