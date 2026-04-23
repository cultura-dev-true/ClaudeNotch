import Foundation
import Network
import Observation

// MARK: - HookEvent

/// Minimal projection of a Claude Code PreToolUse hook payload.
struct HookEvent: Equatable {
    let toolName: String
    let summary: String?

    static func parse(_ data: Data) -> HookEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let toolName = object["tool_name"] as? String
        else {
            return nil
        }

        let input = object["tool_input"] as? [String: Any]
        let summary: String? = {
            if let command = input?["command"] as? String { return command }
            if let filePath = input?["file_path"] as? String {
                return (filePath as NSString).lastPathComponent
            }
            return nil
        }()

        return HookEvent(toolName: toolName, summary: summary)
    }
}

// MARK: - ResponseDecision

/// The JSON this hook should write to stdout for Claude Code to read.
/// `.ask` means "empty {} — no override, use default permission flow".
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

/// One hook invocation that's waiting on our side for a decision.
/// `respond` sends the decision back over the socket and closes it.
struct IncomingRequest: Identifiable {
    let id = UUID()
    let event: HookEvent
    let respond: (ResponseDecision) -> Void
}

// MARK: - NotchState

@MainActor
@Observable
final class NotchState {

    enum Display: Equatable {
        case idle
        case observing(HookEvent)       // auto-clears after autoClearDelay
        case pending(IncomingRequest)   // blocks until user click or timeout

        static func == (lhs: Display, rhs: Display) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.observing(a), .observing(b)): return a == b
            case let (.pending(a), .pending(b)): return a.id == b.id
            default: return false
            }
        }
    }

    var display: Display = .idle

    /// Called whenever `display` changes — AppDelegate uses this to resize the NSPanel.
    var onDisplayChanged: ((Display) -> Void)?

    private var queue: [IncomingRequest] = []
    private var autoClearTask: Task<Void, Never>?
    private var pendingTimeoutTask: Task<Void, Never>?

    private let autoClearDelay: Duration = .seconds(3)
    private let pendingTimeoutDelay: Duration = .seconds(30)

    // MARK: Input from SocketServer

    func handle(_ request: IncomingRequest) {
        if shouldPrompt(request.event) {
            if case .pending = display {
                queue.append(request)
            } else {
                showPending(request)
            }
        } else {
            // Observer-only tool — don't block Claude, just flash.
            request.respond(.ask)
            showObserving(request.event)
        }
    }

    // MARK: User clicks Allow / Deny

    func resolve(_ decision: ResponseDecision) {
        guard case .pending(let current) = display else { return }
        pendingTimeoutTask?.cancel()
        current.respond(decision)
        advanceQueue()
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
                // Silence = deny (Variant A, safer default).
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
        onDisplayChanged?(new)
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
                // Don't cancel here — process() or the respond() closure will.
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

        // Build a respond closure that writes the decision JSON and closes
        // the connection. Called once — either by NotchState.resolve() or
        // by the auto-respond path for non-prompting tools.
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
