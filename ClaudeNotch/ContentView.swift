import SwiftUI

struct NotchView: View {
    let state: NotchState

    /// Bottom-only corner radius — the pill's top edge meets the screen edge
    /// so only the bottom corners need rounding. Tuned to look concentric
    /// with the hardware notch (~9pt outer / ~5pt inner radius).
    private let pillCornerRadius: CGFloat = 12

    var body: some View {
        // Hover events arrive from the AppKit-level HoverTrackingView wrapping
        // this hosting view (see ClaudeNotchApp.swift) — SwiftUI .onHover only
        // fires for the front-most app, which we never are.
        base
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var base: some View {
        if state.shouldExpand {
            expandedPill { ExpandedView(
                sessions: state.recentSessions,
                onPick: { _ in ClaudeDesktopLauncher.activate() }
            )}
        } else {
            switch state.display {
            case .pending(let request):
                expandedPill { pendingContent(for: request) }

            case .observing(let event):
                activityPill { eventLabel(for: event) }

            case .idle:
                idlePill
            }
        }
    }

    // MARK: Pill shells

    /// The expanded pill grows downward from the notch. Top corners stay sharp
    /// (they meet the screen edge), bottom corners are rounded.
    private func expandedPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            BottomRoundedRectangle(cornerRadius: pillCornerRadius * 2)
                .fill(Color.black)
            content()
                .padding(.top, state.notchHeight + 6)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Resting pill — exactly the size of the hardware notch so it fuses with
    /// the cutout. The surrounding panel area is transparent and stays
    /// hover-active so the cursor doesn't have to land pixel-perfectly on the
    /// black pill to expand the notch.
    private var idlePill: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
            BottomRoundedRectangle(cornerRadius: pillCornerRadius)
                .fill(Color.black)
                .frame(width: state.notchWidth, height: state.notchHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Activity pill — the black shape grows past the bottom of the hardware
    /// notch by ~`notchHeight` overshoot, with the activity text sitting in
    /// that overshoot. This is the visible signal "Claude is doing something".
    private func activityPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
            BottomRoundedRectangle(cornerRadius: pillCornerRadius)
                .fill(Color.black)
                .overlay(alignment: .top) {
                    content()
                        .padding(.top, state.notchHeight + 1)
                        .padding(.horizontal, 14)
                }
                .frame(
                    minWidth: state.notchWidth,
                    maxWidth: .infinity,
                    minHeight: state.notchHeight + 16,
                    maxHeight: state.notchHeight + 16
                )
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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

// MARK: - BottomRoundedRectangle

/// Rectangle with only its bottom-left and bottom-right corners rounded.
/// The pill's top edge sits flush with the screen bezel, so rounding the
/// top would create a visible gap above the notch.
struct BottomRoundedRectangle: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
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
