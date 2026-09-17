import SwiftUI

/// The progress bar to show a surface progress report. We implement this from scratch because the
/// standard ProgressView is broken on macOS 26 and this is simple anyways and gives us a ton of
/// control.
struct SurfaceProgressBar: View {
    let report: Ghostty.Action.ProgressReport

    /// Whether the bar is drawn as the light on the tab is, in the same colors
    /// and shapes. Ghostty draws a blue block that bounces over a track, and
    /// keeps doing that until `defaults write com.mitchellh.ghostty
    /// SurfaceProgressBarStyle match` says otherwise.
    private var matchesTab: Bool {
        UserDefaults.ghostty.string(forKey: "SurfaceProgressBarStyle") == "match"
    }

    private var color: Color {
        guard matchesTab else {
            switch report.state {
            case .error: return .red
            case .pause: return .orange
            default: return .accentColor
            }
        }
        // The tab of the window says the same thing in these colors, and 2
        // lights for 1 piece of news should at least look alike.
        switch report.state {
        case .error: return Color(nsColor: TabActivityRingView.errorColor)
        case .pause: return Color(nsColor: TabActivityRingView.waitingColor)
        default: return Color(nsColor: TabActivityRingView.workingColor)
        }
    }

    /// Waiting and failing are states, not amounts, so the bar shows them the
    /// way the tab does: the whole width of it, breathing.
    private var pulses: Bool {
        matchesTab && (report.state == .pause || report.state == .error)
    }

    private var progress: UInt8? {
        // If we have an explicit progress use that.
        if let v = report.progress { return v }

        // Otherwise, if we're in the pause state, we act as if we're at 100%.
        if !matchesTab, report.state == .pause { return 100 }

        return nil
    }

    private var accessibilityLabel: String {
        switch report.state {
        case .error: return "Terminal progress - Error"
        case .pause: return "Terminal progress - Paused"
        case .indeterminate: return "Terminal progress - In progress"
        default: return "Terminal progress"
        }
    }

    private var accessibilityValue: String {
        if let progress {
            return "\(progress) percent complete"
        } else {
            switch report.state {
            case .error: return "Operation failed"
            case .pause: return "Operation paused at completion"
            case .indeterminate: return "Operation in progress"
            default: return "Indeterminate progress"
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if pulses {
                    PulsingProgressBar(color: color)
                } else if let progress {
                    // Determinate progress bar with specific percentage
                    Rectangle()
                        .fill(color)
                        .frame(
                            width: geometry.size.width * CGFloat(progress) / 100,
                            height: geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.2), value: progress)
                } else if matchesTab {
                    // Nothing is known but that it is working, which is what the
                    // light on the tab says as well, in the same shape and at
                    // the same pace.
                    SweepingProgressBar(color: color)
                } else {
                    BouncingProgressBar(color: color)
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }
}

/// The whole bar, breathing, for a program that is waiting or has failed. It
/// keeps time with the outline of the tab, which breathes for the same states.
private struct PulsingProgressBar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Double(TabActivityRingView.framesPerSecond))) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let phase = now.truncatingRemainder(dividingBy: TabActivityRingView.pulseSeconds)
                    / TabActivityRingView.pulseSeconds
                let alpha = 0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * phase))
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(color.opacity(alpha)))
            }
        }
    }
}

/// A band of light that crosses the bar, for a program that says it is working
/// and nothing more. It is the light the tab of the window carries: the same
/// shape, the same pace, and drawn as often.
private struct SweepingProgressBar: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Double(TabActivityRingView.framesPerSecond))) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let seconds = TabActivityRingView.turnSeconds
                let travelled = CGFloat(now.truncatingRemainder(dividingBy: seconds) / seconds)
                let steps = TabActivityRingView.sweepSteps
                let stops = (0...steps).map { step -> Gradient.Stop in
                    let along = CGFloat(step) / CGFloat(steps)
                    let ahead = (along - travelled).truncatingRemainder(dividingBy: 1)
                    let alpha = TabActivityRingView.sweepProfile(ahead + (along < travelled ? 1 : 0))
                    return .init(color: color.opacity(alpha), location: along)
                }
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(stops: stops),
                        startPoint: .zero,
                        endPoint: CGPoint(x: size.width, y: 0)))
            }
        }
    }
}

/// Bouncing progress bar for indeterminate states
private struct BouncingProgressBar: View {
    let color: Color
    @State private var position: CGFloat = 0

    private let barWidthRatio: CGFloat = 0.25

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(color.opacity(0.3))

                Rectangle()
                    .fill(color)
                    .frame(
                        width: geometry.size.width * barWidthRatio,
                        height: geometry.size.height
                    )
                    .offset(x: position * (geometry.size.width * (1 - barWidthRatio)))
            }
        }
        .onAppear {
            withAnimation(
                .easeInOut(duration: 1.2)
                .repeatForever(autoreverses: true)
            ) {
                position = 1
            }
        }
        .onDisappear {
            position = 0
        }
    }
}
