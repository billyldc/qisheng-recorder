import Foundation

public struct TavernNavigationFlow {
    public enum Action: Equatable {
        case wait, forward, arrived, needsAssistance(String), stop(String)
    }
    private enum Stage { case observing, approaching, assistance, done }
    private var stage = Stage.observing
    private var stageStarted: Double
    private var lastTime: Double?
    private var lastSample: (point: UnitPoint, time: Double)?
    private var lastAction = -Double.infinity
    private var steps = 0

    public init(at now: Double) { stageStarted = now }
    public var checkingArrival: Bool { stage == .approaching || stage == .assistance }
    public var waitingForUser: Bool { stage == .assistance }
    public mutating func resetEvidence() { lastSample = nil }
    public mutating func pageChanged(from previous: Self, inputSent: Bool) {
        if !inputSent { self = previous }
        resetEvidence()
    }

    private mutating func stable(_ point: UnitPoint?, at now: Double) -> Bool {
        guard let point else { resetEvidence(); return false }
        defer { lastSample = (point, now) }
        guard let previous = lastSample, (0.2...10).contains(now - previous.time),
              abs(previous.point.x - point.x) < 0.015,
              abs(previous.point.y - point.y) < 0.015 else { return false }
        return true
    }
    private mutating func help(_ message: String, at now: Double) -> Action {
        resetEvidence()
        guard stage != .assistance else { return .wait }
        stage = .assistance; stageStarted = now; resetEvidence()
        return .needsAssistance(message)
    }
    public mutating func observe(_ lines: [TextLine], width: Int, height: Int, zoom: UnitPoint?, at now: Double) -> Action {
        guard now.isFinite, now >= stageStarted, lastTime.map({ now >= $0 }) ?? true else {
            return .stop("导航时钟异常，尚未发送输入。")
        }
        lastTime = now
        guard width > 0, height > 0 else { return help("画面尺寸未就绪，任务等待恢复。", at: now) }
        let page = CloudLaunchPolicy.state(lines)
        if page == .login { return help("请先完成登录或验证码，任务保持等待，不会代填验证。", at: now) }
        if stage == .done { return .arrived }
        let terminal: UnitPoint?
        switch page {
        case .prince: terminal = UnitPoint(x: 0.1, y: 0.1)
        case .favorites: terminal = UnitPoint(x: 0.2, y: 0.1)
        case .recentReplays: terminal = UnitPoint(x: 0.3, y: 0.1)
        default: terminal = nil
        }
        if let terminal {
            guard stable(terminal, at: now) else { return .wait }
            stage = .done
            return .arrived
        }
        let nearby = TavernNavigationEvidence.princeNearby(lines)
        if nearby {
            if stage != .approaching {
                guard stable(UnitPoint(x: 0.4, y: 0.1), at: now) else { return .wait }
                stage = .approaching; stageStarted = now; lastAction = now; resetEvidence()
                return .wait
            }
            guard now - lastAction >= 3 else { resetEvidence(); return .wait }
            guard stable(UnitPoint(x: 0.4, y: 0.1), at: now) else { return .wait }
            guard steps < 3 else {
                return help("已看到小王子但未确认 F 入口，请手动靠近；识别到入口后继续。", at: now)
            }
            steps += 1; lastAction = now; resetEvidence()
            return .forward
        }
        if stage == .assistance { resetEvidence(); return .wait }
        // Indoor map screenshots do not establish an outdoor teleport route.
        // No coordinates, map keys or inferred tavern entries are sent here.
        let world = TavernNavigationEvidence.worldVisible(lines)
        let map = TavernNavigationEvidence.layerPoint(lines) != nil
        if stable(world ? UnitPoint(x: 0.6, y: 0.1) : map ? UnitPoint(x: 0.7, y: 0.1) : nil, at: now) {
            return help("室外进入猫尾酒馆的路线尚未验证。请手动进入酒馆并靠近小王子；任务不会退出，确认入口后自动继续。", at: now)
        }
        if now - stageStarted > (stage == .approaching ? 70 : 25) {
            return help("暂时无法确认小王子入口，请检查画面；任务等待可识别的入口或收藏列表。", at: now)
        }
        return .wait
    }
}
