import Foundation
import Network
import Observation

// MARK: - HookEvent

/// Minimal projection of a Claude Code PreToolUse hook payload.
/// Only the fields the notch actually needs are extracted; the rest is ignored
/// so new/unknown fields from Claude Code won't break the pipeline.
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

// MARK: - NotchState

/// UI state for the notch. `current` is set when a hook event arrives and
/// automatically cleared after `autoClearDelay` seconds.
///
/// `@Observable` (Swift 5.9+) means any SwiftUI view that reads a property
/// off this class gets invalidated when the property changes — no need for
/// @Published / ObservableObject / @ObservedObject.
@MainActor
@Observable
final class NotchState {
    var current: HookEvent?

    private let autoClearDelay: Duration = .seconds(3)
    private var clearTask: Task<Void, Never>?

    func show(_ event: HookEvent) {
        current = event
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: autoClearDelay)
            if !Task.isCancelled {
                self.current = nil
            }
        }
    }
}

// MARK: - SocketServer

/// Listens on a Unix domain socket at `socketPath`. Each incoming connection
/// is treated as one-shot: read until EOF, parse JSON, hand off to `onEvent`.
///
/// Phase 2.1 is fire-and-forget — the server never writes back. Phase 2.2
/// will add request/response for approve/deny.
final class SocketServer {
    private let socketPath: String
    private let onEvent: (HookEvent) -> Void
    private var listener: NWListener?

    init(socketPath: String = "/tmp/claude-notch.sock", onEvent: @escaping (HookEvent) -> Void) {
        self.socketPath = socketPath
        self.onEvent = onEvent
    }

    func start() {
        // Remove any stale socket file from a previous run; otherwise bind fails
        // with "Address already in use".
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
                    break  // .setup / .waiting are transient, don't log
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("[ClaudeNotch] socket server failed to start: \(error)")
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
                self.process(buffer)
                connection.cancel()
                return
            }

            self.receive(on: connection, accumulated: buffer)
        }
    }

    private func process(_ data: Data) {
        guard !data.isEmpty else { return }
        guard let event = HookEvent.parse(data) else {
            let raw = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            NSLog("[ClaudeNotch] parse failed; raw=\(raw)")
            return
        }
        onEvent(event)
    }
}
