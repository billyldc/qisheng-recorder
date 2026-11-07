import Foundation

public struct TavernNavigationFlow {
    public enum ClickKind: String {
        case mapLayers, mondstadt, zoom, iconCluster, tavernCandidate, teleport
    }
    public enum Action: Equatable {
        case wait, openMap, retryMap, click(UnitPoint, ClickKind), forward, arrived, stop(String)
    }
    private enum Stage {
        case world, map, regions, zoom, cluster, candidate, panel, arrival, done
    }

    private var stage: Stage = .world
    private var stageStarted: Double
    private var lastSample: (point: UnitPoint, time: Double)?
    private var lastAction = -Double.infinity
    private var zooms = 0
    private var steps = 0
    private var mapRetries = 0

    public init(at now: Double) { stageStarted = now }
    public var checkingArrival: Bool { stage == .arrival }
    public var needsZoomControl: Bool { stage == .zoom || stage == .cluster }
    public var needsWorldEvidence: Bool { stage == .world || stage == .map || stage == .arrival }
    public mutating func resetEvidence() { lastSample = nil }

    public mutating func pageChanged(from previous: Self, inputSent: Bool) {
        if !inputSent { self = previous }
        resetEvidence()
    }

    private mutating func stable(_ point: UnitPoint?, at now: Double) -> Bool {
        guard let point else { lastSample = nil; return false }
        defer { lastSample = (point, now) }
        guard let previous = lastSample, now - previous.time >= 0.2,
              abs(previous.point.x - point.x) < 0.015, abs(previous.point.y - point.y) < 0.015 else { return false }
        return true
    }

    private mutating func advance(_ next: Stage, at now: Double) {
        stage = next; stageStarted = now; lastAction = now; lastSample = nil
    }

    public mutating func observe(_ lines: [TextLine], width: Int, height: Int, zoom: UnitPoint?, at now: Double) -> Action {
        guard now.isFinite, now >= stageStarted else { return .stop("导航时钟异常，已停止。") }
        if CloudLaunchPolicy.state(lines) == .login { return .stop("检测到登录或验证页面，已停止地图操作。") }
        let limit = stage == .arrival ? 70.0 : stage == .zoom ? 70.0 : 25.0
        guard now - stageStarted <= limit else { return .stop("未能确认地图导航的下一步，已停止；请检查游戏画面。") }
        switch stage {
        case .world:
            let nearby = TavernNavigationEvidence.princeNearby(lines)
            let candidate = nearby ? UnitPoint(x: 0.3, y: 0.3)
                : (TavernNavigationEvidence.worldVisible(lines) ? UnitPoint(x: 0.5, y: 0.5) : nil)
            guard stable(candidate, at: now) else { return .wait }
            if nearby {
                advance(.arrival, at: now)
                return .wait
            }
            advance(.map, at: now)
            return .openMap
        case .map:
            if let point = TavernNavigationEvidence.layerPoint(lines) {
                guard stable(point, at: now) else { return .wait }
                advance(.regions, at: now)
                return .click(point, .mapLayers)
            }
            let stillInWorld = now - lastAction >= 4 && mapRetries == 0 && TavernNavigationEvidence.worldVisible(lines)
            guard stable(stillInWorld ? UnitPoint(x: 0.5, y: 0.5) : nil, at: now) else { return .wait }
            mapRetries += 1; lastAction = now; lastSample = nil
            return .retryMap
        case .regions:
            let candidate = TavernNavigationEvidence.regionPoint(lines)
            guard stable(candidate, at: now), let point = candidate else { return .wait }
            advance(.zoom, at: now)
            return .click(point, .mondstadt)
        case .zoom:
            let candidate = TavernNavigationEvidence.isMondstadtMap(lines) ? zoom : nil
            guard now - lastAction >= 0.8 else { lastSample = nil; return .wait }
            guard stable(candidate, at: now), let point = candidate else { return .wait }
            zooms += 1; lastAction = now; lastSample = nil
            if zooms >= 8 { advance(.cluster, at: now) }
            return .click(point, .zoom)
        case .cluster:
            let candidate = zoom != nil ? TavernNavigationEvidence.clusterPoint(lines, width: width, height: height) : nil
            guard stable(candidate, at: now), let point = candidate else { return .wait }
            advance(.candidate, at: now)
            return .click(point, .iconCluster)
        case .candidate:
            if let point = TavernNavigationEvidence.teleportPoint(lines) {
                guard stable(point, at: now) else { return .wait }
                advance(.arrival, at: now)
                return .click(point, .teleport)
            }
            let candidate = TavernNavigationEvidence.tavernCandidatePoint(lines)
            guard stable(candidate, at: now), let point = candidate else { return .wait }
            advance(.panel, at: now)
            return .click(point, .tavernCandidate)
        case .panel:
            let candidate = TavernNavigationEvidence.teleportPoint(lines)
            guard stable(candidate, at: now), let point = candidate else { return .wait }
            advance(.arrival, at: now)
            return .click(point, .teleport)
        case .arrival:
            if CloudLaunchPolicy.state(lines) == .prince {
                guard stable(UnitPoint(x: 0.5, y: 0.5), at: now) else { return .wait }
                advance(.done, at: now)
                return .arrived
            }
            guard now - lastAction >= 3 else { lastSample = nil; return .wait }
            let nearby = TavernNavigationEvidence.princeNearby(lines) ? UnitPoint(x: 0.3, y: 0.3) : nil
            guard stable(nearby, at: now) else { return .wait }
            guard steps < 3 else { return .stop("已到酒馆但未找到小王子的 F 提示，请手动靠近后继续。") }
            steps += 1; lastAction = now; lastSample = nil
            return .forward
        case .done:
            return .arrived
        }
    }
}
