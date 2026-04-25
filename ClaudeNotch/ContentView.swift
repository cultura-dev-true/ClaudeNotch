import SwiftUI

struct NotchView: View {
    let state: NotchState

    // Size of the visible black pill in idle/observing state. The panel frame
    // is intentionally larger (see NotchState.panelSize) so the extra area
    // catches hover events over the physical notch.
    private let compactPillWidth: CGFloat = 220
    private let compactPillHeight: CGFloat = 32

    var body: some View {
        base
            .onHover { hovering in state.setHovering(hovering) }
    }

    @ViewBuilder
    private var base: some View {
        if state.shouldExpand {
            fullPill { ExpandedView(
                sessions: state.recentSessions,
                onPick: { _ in ClaudeDesktopLauncher.activate() }
            )}
        } else {
            switch state.display {
            case .pending(let request):
                fullPill { pendingContent(for: request) }

            case .observing(let event):
                compactPill { eventLabel(for: event) }

            case .idle:
                compactPill {
                    Text("idle")
                        .foregroundStyle(.white.opacity(0.25))
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                }
            }
        }
    }

    // MARK: Pill shells

    /// Fills the entire panel — used for pending approval and expanded session
    /// list, where we want the visible pill to match panel bounds.
    private func fullPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black)
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    /// Renders the small pill (compactPillWidth × compactPillHeight) centered
    /// at the top of a transparent hover-catcher frame. The transparent margin
    /// ensures hover fires for the full notch area, not just on the pill.
    private func compactPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)
                content()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
            }
            .frame(width: compactPillWidth, height: compactPillHeight)
        }
    }

    // MARK: Content builders

    @ViewBuilder
    private func pendingContent(for request: IncomingRequest) -> some View {
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

// MARK: - Expanded view

struct ExpandedView: View {
    let sessions: [SessionInfo]
    let onPick: (SessionInfo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent sessions")
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .padding(.top, 2)

            if sessions.isEmpty {
                Text("no sessions found in ~/.claude/projects")
                    .foregroundStyle(.white.opacity(0.35))
                    .font(.system(size: 10, design: .rounded))
                    .padding(.top, 8)
            } else {
                ForEach(sessions) { session in
                    SessionRow(session: session)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(session) }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .foregroundStyle(.white)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(session.projectBasename) · \(session.relativeTime)")
                    .foregroundStyle(.white.opacity(0.45))
                    .font(.system(size: 9, design: .rounded))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Previews

#Preview("idle") {
    NotchView(state: NotchState())
        .frame(width: 320, height: 44)
        .padding()
        .background(Color.gray)
}

#Preview("expanded (empty)") {
    let state = NotchState()
    state.setHovering(true)
    return NotchView(state: state)
        .frame(width: 320, height: 200)
        .padding()
        .background(Color.gray)
}
