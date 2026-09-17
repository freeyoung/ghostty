import AppKit

/// The ring of light iTerm2 3.7 runs around the tab of a working session, drawn
/// around the tabs of a Ghostty window.
///
/// macOS draws the tabs themselves, in views Ghostty does not own, so this is a
/// transparent overlay laid over the tab bar: it is told where each tab is and
/// what it is doing, and it strokes a rounded rectangle around the ones that are
/// doing something. It never takes a click.
///
/// The light runs clockwise, 1 turn every 3 seconds, or whatever
/// `defaults write com.mitchellh.ghostty TabActivityLightSeconds 1.5` says. A tab
/// waiting for an answer pulses its whole outline instead.
///
/// The view draws every frame itself, from a display link, rather than handing
/// the movement to Core Animation. AppKit rebuilds the tab bar whenever a tab
/// opens, closes or moves to another window, and a layer that has been taken out
/// of the view hierarchy comes back without its animations. A ring that has
/// stopped moving looks broken, and nothing tells us when that has happened.
final class TabActivityRingView: NSView {
    struct Ring {
        let frame: NSRect
        let activity: TerminalActivity
        /// Whether this is the tab the window is showing.
        let selected: Bool
    }

    /// Whether the tabs are told apart the way iTerm2 tells them apart: a line
    /// between 2 tabs that are both closed, and an outline around the open one.
    /// macOS 26 draws every tab as a pill and the open one a shade lighter,
    /// which is not much to go on. `defaults write com.mitchellh.ghostty
    /// TabSeparators -bool true` asks for it.
    static var separators: Bool {
        UserDefaults.ghostty.bool(forKey: "TabSeparators")
    }
    private static let separatorColor = NSColor(white: 1, alpha: 0.11)
    private static let selectedOutlineColor = NSColor(white: 1, alpha: 0.16)

    /// Where the light runs, if anywhere. The ring is the one iTerm2 draws
    /// around a working tab. The underline is the one the kitty tab bar of the
    /// same setup draws, which is all a tab bar of 1 row of cells can do: a cell
    /// has an underline and no outline, so the light lies along the bottom of
    /// the tab and nowhere else.
    ///
    /// Nothing is the default, which is what Ghostty does without this patch.
    /// `defaults write com.mitchellh.ghostty TabActivityLight ring` or
    /// `... underline` asks for one, and `defaults delete` goes back to none. It
    /// is not a setting in the config file, so that stock Ghostty still reads
    /// that file without complaining about an option it does not know.
    enum Style: String {
        case none
        case ring
        case underline

        static var current: Style {
            .init(rawValue: UserDefaults.ghostty.string(forKey: "TabActivityLight") ?? "") ?? .none
        }
    }

    static let workingColor = NSColor.systemGreen
    static let waitingColor = NSColor(srgbRed: 0x57 / 255, green: 0x74 / 255, blue: 0xDB / 255, alpha: 1)
    static let errorColor = NSColor(srgbRed: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255, alpha: 1)

    /// The color a state is drawn in, wherever it is drawn.
    static func color(of activity: TerminalActivity) -> NSColor {
        switch activity {
        case .error: return errorColor
        case .paused: return waitingColor
        default: return workingColor
        }
    }
    private static let lineWidth: CGFloat = 2
    static let pulseSeconds: CFTimeInterval = 1.2
    /// How long the light takes to go once around a tab, or once across it.
    static var turnSeconds: CFTimeInterval {
        let seconds = UserDefaults.ghostty.double(forKey: "TabActivityLightSeconds")
        return seconds > 0 ? seconds : 3
    }
    /// How long the light and the tail behind it are, in points. It is a length
    /// and not a share of the outline, because a tab in Ghostty is wide: a tail
    /// that grew with the tab would cover a third of a long outline and crawl,
    /// whatever its pace. A short tail on a long outline reads as something
    /// running, and a long one that fades at both ends reads as something
    /// running smoothly. It is never more than `tailShare` of the outline, so
    /// that a narrow tab is not lit end to end.
    static var tailPoints: CGFloat {
        let points = UserDefaults.ghostty.double(forKey: "TabActivityLightLength")
        return points > 0 ? points : 220
    }
    private static let tailShare: CGFloat = 0.36
    /// A stroke cannot carry a gradient, as the light in iTerm2 does, so the
    /// tail is built from this many strokes.
    private static let tailSteps = 32
    /// How many times a second the light is drawn. This is what it costs: the
    /// pace it runs at costs nothing at all, and its length very little.
    ///
    /// The band along the bottom of a tab is drawn 15 times a second, where it
    /// moves 9 points a frame and costs 3% of a core; nothing that soft and that
    /// slow shows a step that small. The ring goes all the way around a tab,
    /// which is 3 times as far, so it is drawn twice as often for the same
    /// movement a frame. `defaults write com.mitchellh.ghostty
    /// TabActivityLightFPS 60` asks for any other rate.
    static var framesPerSecond: Float {
        let rate = UserDefaults.ghostty.double(forKey: "TabActivityLightFPS")
        guard rate <= 0 else { return Float(min(max(rate, 10), 120)) }
        return Style.current == .underline ? 15 : 30
    }
    /// How many steps the gradient of the underline light is built from, and the
    /// shape of it, which is the one in omarchy/quickshell/claude-rings: up to
    /// half in a fifth of the width, up to full in the next, full for a fifth,
    /// and back down over the last two.
    static let sweepSteps = 32
    /// How far the underline light stops short of each end of the tab, which is
    /// about the corner of the pill macOS draws, and how far from each end it
    /// starts to fade. It ends in nothing rather than in a cut, so that the
    /// corner it cannot reach looks like the end of the light and not like a
    /// piece missing from it.
    private static let underlineInset: CGFloat = 4
    private static let underlineFade: CGFloat = 26
    static func sweepProfile(_ along: CGFloat) -> CGFloat {
        let x = min(max(along, 0), 1) * 5
        switch x {
        case ..<1: return 0.5 * x
        case ..<2: return 0.5 + 0.5 * (x - 1)
        case ..<3: return 1
        case ..<4: return 1 - 0.5 * (x - 3)
        default: return 0.5 - 0.5 * (x - 4)
        }
    }
    /// Where the light is brightest, as a share of its length back from the
    /// front. What is in front of that point fades in, what is behind it fades
    /// out, and neither end has an edge: an edge is what makes a slow light look
    /// like something being moved a step at a time.
    private static let riseShare: CGFloat = 0.3
    private static let riseSteps = 16
    /// How bright the light is at each step behind its brightest point, and in
    /// front of it, as a share of the working color.
    private static func tailProfile(_ step: Int) -> CGFloat {
        pow(1 - CGFloat(step) / CGFloat(tailSteps), 1.6)
    }
    private static func riseProfile(_ step: Int) -> CGFloat {
        let along = 1 - CGFloat(step) / CGFloat(riseSteps)
        return along * along * (3 - 2 * along)
    }
    /// The tail is drawn as strokes that all start at the light and each reach 1
    /// step further back, so that the strokes lie over one another instead of
    /// meeting end to end. Two strokes that meet end to end leave a thin line
    /// between them where neither one covers the pixel fully, and a row of such
    /// lines makes the tail look like a chain. These are the opacities that stack up to
    /// `tailProfile` once all the strokes are drawn.
    private static let tailAlphas: [CGFloat] = stackedAlphas(steps: tailSteps, profile: tailProfile)
    private static let riseAlphas: [CGFloat] = stackedAlphas(steps: riseSteps, profile: riseProfile)

    /// The opacities that stack up to `profile` once all the strokes are drawn,
    /// for strokes that share the end they start from.
    private static func stackedAlphas(steps: Int, profile: (Int) -> CGFloat) -> [CGFloat] {
        (1...steps).map { k in
            let here = profile(k - 1)
            let further = k < steps ? profile(k) : 0
            return here >= 1 ? 1 : 1 - (1 - here) / (1 - further)
        }
    }

    /// The rings to draw, as the window last reported them.
    private var drawn: [Ring] = []

    /// Where the tabs are now, asked again on every frame. AppKit slides the
    /// tabs into their new places when one closes, and it says nothing while it
    /// does, so a light that was placed once ends up beside its tab or on top of
    /// another one. It returns nil while the tab bar and the windows disagree,
    /// which is the middle of a rebuild, and then what is drawn is left alone.
    var ringsProvider: (() -> [Ring]?)?

    /// Drives the animation. It only runs while there is a ring to move.
    private var ticker: Any?
    private var fallbackTicker: Timer?
    private var mode: Mode = .off
    private var lastStyle: Style = .current
    private var lastFrame: CFTimeInterval = 0
    private var lastRate: Float = framesPerSecond

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        // A style is picked from outside the application, and with no style
        // there is no frame being drawn in which to notice it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil)
    }

    @objc private func defaultsDidChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, Style.current != self.lastStyle else { return }
            self.lastStyle = .current
            self.needsDisplay = true
            self.retick()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        fallbackTicker?.invalidate()
    }

    /// A click belongs to the tab under the overlay, never to the overlay.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The overlay is taken out of the tab bar when the bar goes, which is what
    /// happens when a window is down to its last tab. Nothing it draws can be
    /// seen from there, so it stops asking for frames.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopTicking() }
    }

    override var isFlipped: Bool { false }

    func update(rings: [Ring]) {
        guard rings != drawn else { return }
        drawn = rings
        retick()
        needsDisplay = true
    }

    /// Whether any tab is doing something a style would light. A tab that is
    /// only marked idle carries its dot and nothing else.
    private var lit: Bool {
        drawn.contains { $0.activity >= .working }
    }

    /// Whether there is a light to move.
    private var animates: Bool {
        Style.current != .none && lit
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = CACurrentMediaTime()

        ctx.setLineWidth(Self.lineWidth)
        // A cap would reach past the end of the light, and past the end of every
        // stroke that builds the tail.
        ctx.setLineCap(.butt)

        if Self.separators { drawSeparators(in: ctx) }

        let style = Style.current
        guard style != .none else { return }
        for ring in drawn where ring.activity != .none {
            let rect = ring.frame.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)
            guard rect.width > 0, rect.height > 0, ring.frame.intersects(dirtyRect) else { continue }
            let radius = min(rect.height / 2, 10)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if style == .underline {
                drawUnderline(ring, in: ctx, now: now)
                continue
            }
            // The perimeter of a rounded rectangle: the straight parts plus 1 circle.
            let perimeter = 2 * (rect.width + rect.height) - 8 * radius + 2 * .pi * radius

            switch ring.activity {
            // done draws no ring, the same as idle. Nothing is running, and
            // the dot on the tab is what says the 2 apart. It also ranks below
            // working, so a pulse here would ask for more attention than the
            // state deserves.
            case .none, .idle, .done:
                continue

            case .paused, .error:
                let phase = now.truncatingRemainder(dividingBy: Self.pulseSeconds) / Self.pulseSeconds
                let alpha = 0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * phase))
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.setStrokeColor(Self.color(of: ring.activity).withAlphaComponent(alpha).cgColor)
                ctx.addPath(path)
                ctx.strokePath()

            case .working:
                // How far the light has run since it passed the start of the
                // outline. A larger dash phase moves the lit piece against the
                // direction of the path, which is clockwise on the screen, and
                // a piece further down the tail then falls behind the light.
                let seconds = Self.turnSeconds
                let travelled = perimeter * CGFloat(now.truncatingRemainder(dividingBy: seconds) / seconds)
                let length = min(Self.tailPoints, perimeter * Self.tailShare)
                let rise = length * Self.riseShare
                // Both halves of the light are strokes that start at its
                // brightest point, one reaching back and one reaching forward,
                // so that they lie over one another and over that point.
                let back = (length - rise) / CGFloat(Self.tailSteps)
                for (index, alpha) in Self.tailAlphas.enumerated() {
                    let reach = back * CGFloat(index + 1)
                    ctx.setStrokeColor(Self.workingColor.withAlphaComponent(alpha).cgColor)
                    ctx.setLineDash(phase: travelled - rise, lengths: [reach, perimeter - reach])
                    ctx.addPath(path)
                    ctx.strokePath()
                }
                let front = rise / CGFloat(Self.riseSteps)
                for (index, alpha) in Self.riseAlphas.enumerated() {
                    let reach = front * CGFloat(index + 1)
                    ctx.setStrokeColor(Self.workingColor.withAlphaComponent(alpha).cgColor)
                    ctx.setLineDash(phase: travelled - rise + reach, lengths: [reach, perimeter - reach])
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
        }
    }

    /// The light of the kitty tab bar: 1 band the width of the tab, along its
    /// bottom edge, whose peak crosses the tab from left to right.
    private func drawUnderline(_ ring: Ring, in ctx: CGContext, now: CFTimeInterval) {
        // The tab is drawn a little below the bounds of its button, so the band
        // has to go under those bounds to lie on the bottom edge of the tab.
        let line = NSRect(
            x: ring.frame.minX + Self.underlineInset,
            y: ring.frame.minY - Self.lineWidth,
            width: ring.frame.width - 2 * Self.underlineInset,
            height: Self.lineWidth)
        guard line.width > 0 else { return }

        let alphas: [CGFloat]
        switch ring.activity {
        case .paused, .error:
            let phase = now.truncatingRemainder(dividingBy: Self.pulseSeconds) / Self.pulseSeconds
            let alpha = 0.3 + 0.7 * (0.5 + 0.5 * cos(2 * .pi * phase))
            alphas = .init(repeating: alpha, count: Self.sweepSteps + 1)

        default:
            let seconds = Self.turnSeconds
            let travelled = CGFloat(now.truncatingRemainder(dividingBy: seconds) / seconds)
            alphas = (0...Self.sweepSteps).map { step in
                let along = CGFloat(step) / CGFloat(Self.sweepSteps)
                return Self.sweepProfile((along - travelled).truncatingRemainder(dividingBy: 1) + (along < travelled ? 1 : 0))
            }
        }

        // Both ends fade out, so that the band does not stop dead where the
        // corner of the pill begins.
        let fade = min(Self.underlineFade / line.width, 0.5)
        let color = Self.color(of: ring.activity)
        let stops = alphas.enumerated().map { step, alpha -> CGColor in
            let along = CGFloat(step) / CGFloat(Self.sweepSteps)
            let edge = min(along, 1 - along) / fade
            return color.withAlphaComponent(alpha * min(edge, 1)).cgColor
        }
        let locations = (0...Self.sweepSteps).map { CGFloat($0) / CGFloat(Self.sweepSteps) }
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops as CFArray,
            locations: locations) else { return }

        ctx.saveGState()
        ctx.clip(to: line)
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: line.minX, y: line.midY),
            end: CGPoint(x: line.maxX, y: line.midY),
            options: [])
        ctx.restoreGState()
    }

    /// A line between 2 closed tabs, and an outline around the open one.
    private func drawSeparators(in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(1)
        for (index, tab) in drawn.enumerated() {
            if tab.selected {
                let rect = tab.frame.insetBy(dx: 0.5, dy: 0.5)
                let radius = min(rect.height / 2, 10)
                ctx.setStrokeColor(Self.selectedOutlineColor.cgColor)
                ctx.addPath(CGPath(
                    roundedRect: rect,
                    cornerWidth: radius,
                    cornerHeight: radius,
                    transform: nil))
                ctx.strokePath()
                continue
            }
            // The line goes in the gap on the right of this tab, and only when
            // the tab on the other side of it is closed as well.
            guard index + 1 < drawn.count, !drawn[index + 1].selected else { continue }
            let next = drawn[index + 1]
            let x = (tab.frame.maxX + next.frame.minX) / 2
            // The gap between 2 tabs is narrow, so a line down the whole
            // height of them sits wedged in it.
            let inset = tab.frame.height * 0.34
            ctx.setStrokeColor(Self.separatorColor.cgColor)
            ctx.move(to: CGPoint(x: x, y: tab.frame.minY + inset))
            ctx.addLine(to: CGPoint(x: x, y: tab.frame.maxY - inset))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    // MARK: Animation

    /// What the view is doing between the frames it draws.
    private enum Mode {
        /// Nothing: no tab is doing anything, or none that a style would light.
        case off
        /// Drawing the light, frame by frame.
        case frames
        /// Watching for a style to be picked, once a second. There is a tab to
        /// light and no style says how, and the style is written from outside
        /// the application, which tells the application nothing.
        case watch
    }

    private func retick() {
        let wanted: Mode = animates ? .frames : (lit ? .watch : .off)
        guard wanted != mode else { return }
        stopTicking()
        mode = wanted
        switch wanted {
        case .off: break
        case .frames: startFrames()
        case .watch: startWatching()
        }
    }

    private func startFrames() {
        if #available(macOS 14.0, *) {
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: Self.framesPerSecond / 2,
                maximum: Self.framesPerSecond,
                preferred: Self.framesPerSecond)
            link.add(to: .main, forMode: .common)
            ticker = link
        } else {
            startTimer(every: 1.0 / Double(Self.framesPerSecond))
        }
    }

    private func startWatching() {
        startTimer(every: 1)
    }

    private func startTimer(every interval: TimeInterval) {
        let timer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTicker = timer
    }

    private func stopTicking() {
        if #available(macOS 14.0, *), let link = ticker as? CADisplayLink {
            link.invalidate()
        }
        ticker = nil
        fallbackTicker?.invalidate()
        fallbackTicker = nil
        mode = .off
    }

    @objc private func tick() {
        if let rings = ringsProvider?() { update(rings: rings) }

        // Both are read from the defaults, which can change while Ghostty runs.
        // What was drawn under the old style has to go, and a display link only
        // takes a rate when it is made, so a new rate needs a new one.
        if Style.current != lastStyle || Self.framesPerSecond != lastRate {
            lastStyle = .current
            lastRate = Self.framesPerSecond
            needsDisplay = true
            stopTicking()
            retick()
            return
        }

        guard animates else {
            retick()
            return
        }

        // The rate is asked of the display link, which is free to call more
        // often than that and does when the rate changes while it runs, so a
        // frame that comes too soon is dropped here. This is what holds the rate
        // to what the defaults say.
        let now = CACurrentMediaTime()
        guard now - lastFrame >= 0.98 / CFTimeInterval(Self.framesPerSecond) else { return }
        lastFrame = now

        // Only the tabs that carry a light are drawn again. The overlay lies
        // over the whole tab bar, and drawing all of it costs several times what
        // the lights themselves cost.
        for ring in drawn where ring.activity >= .working {
            setNeedsDisplay(ring.frame.insetBy(dx: -Self.lineWidth, dy: -Self.lineWidth))
        }
    }
}

extension TabActivityRingView.Ring: Equatable {}
