import Foundation

public enum SpeedAction: Equatable {
    case alreadyDouble, click(UnitPoint), skip
}

public enum SpeedPolicy {
    public static func action(detected: ReplaySpeedControl?, calibrated: UnitPoint?) -> SpeedAction {
        // An unrelated detected control must not override a calibrated button.
        let sameControl = calibrated.map { point in
            guard let detected else { return false }
            return abs(point.x - detected.point.x) < 0.04 && abs(point.y - detected.point.y) < 0.04
        } ?? true
        if detected?.multiplier == 2 && sameControl { return .alreadyDouble }
        if let point = calibrated ?? detected?.point { return .click(point) }
        return .skip
    }
}
