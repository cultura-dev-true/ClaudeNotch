import SwiftUI

struct NotchView: View {
    let state: NotchState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)

            if let event = state.current {
                Text(label(for: event))
                    .foregroundStyle(.white)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
            } else {
                Text("idle")
                    .foregroundStyle(.white.opacity(0.25))
                    .font(.system(size: 9, weight: .regular, design: .rounded))
            }
        }
    }

    private func label(for event: HookEvent) -> String {
        guard let summary = event.summary, !summary.isEmpty else {
            return event.toolName
        }
        return "\(event.toolName) · \(summary)"
    }
}

#Preview {
    let state = NotchState()
    return VStack(spacing: 8) {
        NotchView(state: state)
            .frame(width: 220, height: 32)
        Button("simulate event") {
            state.show(HookEvent(toolName: "Bash", summary: "git status"))
        }
    }
    .padding()
    .background(Color.gray)
}
