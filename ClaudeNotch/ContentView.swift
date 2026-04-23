import SwiftUI

struct NotchView: View {
    let state: NotchState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.display {
        case .idle:
            Text("idle")
                .foregroundStyle(.white.opacity(0.25))
                .font(.system(size: 9, weight: .regular, design: .rounded))

        case .observing(let event):
            eventLabel(for: event)

        case .pending(let request):
            VStack(spacing: 6) {
                eventLabel(for: request.event)
                HStack(spacing: 6) {
                    actionButton("Deny", color: .red.opacity(0.8)) {
                        state.resolve(.deny(reason: "Denied via ClaudeNotch."))
                    }
                    actionButton("Allow", color: .green.opacity(0.75)) {
                        state.resolve(.allow)
                    }
                }
            }
        }
    }

    private func eventLabel(for event: HookEvent) -> some View {
        Text(label(for: event))
            .foregroundStyle(.white)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func actionButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func label(for event: HookEvent) -> String {
        guard let summary = event.summary, !summary.isEmpty else { return event.toolName }
        return "\(event.toolName) · \(summary)"
    }
}

#Preview("idle") {
    NotchView(state: NotchState())
        .frame(width: 220, height: 32)
        .padding()
        .background(Color.gray)
}

#Preview("pending") {
    let state = NotchState()
    let request = IncomingRequest(
        event: HookEvent(toolName: "Bash", summary: "git commit -m 'test'"),
        respond: { _ in }
    )
    state.display = .pending(request)
    return NotchView(state: state)
        .frame(width: 280, height: 72)
        .padding()
        .background(Color.gray)
}
