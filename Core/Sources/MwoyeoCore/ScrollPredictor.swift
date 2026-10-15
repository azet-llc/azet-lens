/// Predicts how far the content under the pointer scrolls from wheel and trackpad events, ahead of the captured frames
/// that confirm it, so translations can follow a scroll the way a scroll view follows the finger instead of a
/// frame behind. Momentum scrolling needs nothing special: the system keeps sending decaying events.
///
/// Page points per wheel unit depend on the app: precise (trackpad) deltas are points and browsers apply them 1:1,
/// a mouse wheel's lines are not. The ratio is learnt from shifts the frames confirm.
public struct ScrollPredictor: Sendable {
    struct Event: Sendable {
        let time: Double
        let delta: Double
        let precise: Bool
    }

    /// From an event to the app showing it on screen.
    public var latency = 0.016
    /// Apps animate a mouse-wheel step over about this long; precise deltas show at once.
    public var stepDuration = 0.15
    private var events: [Event] = []
    /// Content points per wheel unit, for precise and for line deltas.
    private(set) var ratios: [Bool: Double] = [true: 1]

    public init() {}

    /// A scroll event (`NSEvent.scrollingDeltaY`, `hasPreciseScrollingDeltas`, `timestamp`); positive moves content down.
    public mutating func wheel(delta: Double, time: Double, precise: Bool) {
        guard delta != 0 else { return }
        events.removeAll { time - $0.time > 2 }
        events.append(Event(time: time, delta: delta, precise: precise))
    }

    /// Content movement (points, positive = down) expected between `t0` (the frame the overlay was placed from) and `t1`.
    public func offset(from t0: Double, to t1: Double) -> Double {
        ratios.reduce(0) { $0 + $1.value * units($1.key, from: t0, to: t1) }
    }

    /// Frames at `t0` and `t1` showed the content moved by `shift` points: learn the ratio from it. A stop at the end
    /// of the page (events, no movement) or a scroll by other means (keys, scripts) says nothing and is ignored.
    public mutating func confirm(shift: Double, from t0: Double, to t1: Double) {
        let precise = units(true, from: t0, to: t1), lines = units(false, from: t0, to: t1)
        guard (abs(precise) >= 1) != (abs(lines) >= 1) else { return }
        let kind = abs(precise) >= 1, sample = shift / (kind ? precise : lines)
        if let r = ratios[kind] {
            guard sample / r > 0.33, sample / r < 3 else { return }
            ratios[kind] = r + 0.3 * (sample - r)
        } else if sample.isFinite, sample != 0 {
            ratios[kind] = sample
        }
    }

    /// Another app or page: forget what was learnt.
    public mutating func reset() {
        events = []
        ratios = [true: 1]
    }

    /// Wheel units of one kind that reached the screen between `t0` and `t1`.
    func units(_ precise: Bool, from t0: Double, to t1: Double) -> Double {
        events.reduce(0) { $1.precise == precise ? $0 + $1.delta * (shown($1, at: t1) - shown($1, at: t0)) : $0 }
    }

    /// How much of an event's movement is on screen at `t`.
    private func shown(_ e: Event, at t: Double) -> Double {
        let s = t - e.time - latency
        guard s > 0 else { return 0 }
        guard !e.precise else { return 1 }
        let u = min(1, s / stepDuration), rest = 1 - u
        return 1 - rest * rest * rest   // ease-out, like a smooth-scroll animation
    }
}
