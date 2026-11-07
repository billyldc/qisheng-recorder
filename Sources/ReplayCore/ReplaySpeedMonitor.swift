import Foundation

/// Retries only when fresh, stable toolbar evidence still shows normal speed.
public struct ReplaySpeedMonitor {
    public enum Action: Equatable {
        case wait, click(UnitPoint, attempt: Int), confirmed, stillNormal
    }

    private let enabled: Bool
    private let calibrated: UnitPoint?
    private var previous: ReplaySpeedControl?
    private var previousAt: Double?
    private var lastAttempt = -Double.infinity
    private var attempts = 0
    private var confirmed = false
    private var warned = false

    public init(enabled: Bool, calibrated: UnitPoint? = nil) {
        self.enabled = enabled
        self.calibrated = calibrated.flatMap { Self.valid($0) ? $0 : nil }
    }

    public mutating func observe(_ controls: ReplayPlaybackControls, menuOpen: Bool, at now: Double) -> Action {
        guard enabled, now.isFinite, !menuOpen, controls.playback?.state == .running else {
            previous = nil; previousAt = nil
            return .wait
        }
        let detected = controls.speed.flatMap { speed -> ReplaySpeedControl? in
            guard Self.valid(speed.point), [1, 2].contains(speed.multiplier ?? 0),
                  calibrated.map({ Self.near($0, speed.point) }) ?? true else { return nil }
            return speed
        }
        guard let sample = detected ?? calibrated.map({ ReplaySpeedControl(point: $0, multiplier: nil) }) else {
            previous = nil; previousAt = nil
            return .wait
        }
        let stable = previous.map {
            $0.multiplier == sample.multiplier && Self.near($0.point, sample.point)
        } == true && previousAt.map { now > $0 } == true
        previous = sample; previousAt = now
        guard stable else { return .wait }
        if sample.multiplier == 2 {
            guard !confirmed else { return .wait }
            confirmed = true
            return .confirmed
        }
        confirmed = false
        if sample.multiplier == 1 && attempts >= 2 && now - lastAttempt >= 6 && !warned {
            warned = true
            return .stillNormal
        }
        // An unknown calibrated control may be clicked once, but never blindly retried.
        guard attempts < 2, now - lastAttempt >= 6,
              sample.multiplier == 1 || attempts == 0 else { return .wait }
        attempts += 1
        lastAttempt = now
        previous = nil; previousAt = nil
        return .click(calibrated ?? sample.point, attempt: attempts)
    }

    private static func valid(_ point: UnitPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func near(_ first: UnitPoint, _ second: UnitPoint) -> Bool {
        abs(first.x - second.x) < 0.04 && abs(first.y - second.y) < 0.04
    }
}
