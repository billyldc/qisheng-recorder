import Foundation
import ImageIO
import ReplayCore

func checkTavernNavigation() throws {
    func line(_ text: String, _ x: Double, _ y: Double, _ w: Double = 0.04, _ h: Double = 0.025) -> TextLine {
        TextLine(text: text, x: x, y: y, width: w, height: h)
    }
    let uid = line("UID:" + String(repeating: "0", count: 9), 0.87, 0.97, 0.12, 0.02)
    let world = [uid, line("Enter", 0.045, 0.95), line("E", 0.88, 0.95), line("Q", 0.94, 0.95)]
    let layer = [uid, line("提瓦特", 0.89, 0.92)]
    let regions = [uid, line("地图", 0.68, 0.02), line("蒙德", 0.69, 0.15), line("璃月", 0.85, 0.15)]
    let city = layer + [line("蒙德城", 0.402, 0.162, 0.073, 0.045)]
    let candidates = city + [line("C猫尾酒馆", 0.666, 0.556, 0.088, 0.035), line("猎鹿人", 0.69, 0.63)]
    let panel = [uid, line("猫尾酒馆", 0.78, 0.02, 0.06), line("蒙德 蒙德城", 0.76, 0.10, 0.1), line("传送至猫尾酒馆", 0.83, 0.92, 0.11)]
    let nearby = world + [line("小王子", 0.47, 0.19), line("猫之牌圣", 0.47, 0.22)]
    let prompt = [uid, line("F", 0.55, 0.58), line("小王子", 0.61, 0.58)]
    let zoom = UnitPoint(x: 0.025, y: 0.411)
    let disconnected = [line("连接中断", 0.4, 0.4), line("退出游戏", 0.4, 0.6, 0.2)]
    precondition(CloudLaunchPolicy.confirmedDisconnectExit(disconnected, disconnected) != nil)
    precondition(CloudLaunchPolicy.confirmedDisconnectExit(disconnected, [line("退出游戏", 0.4, 0.6)]) == nil)
    precondition(CloudLaunchPolicy.confirmedDisconnectExit(disconnected, disconnected + [line("验证码", 0.5, 0.5)]) == nil)
    let reward = [line("每日登陆奖励", 0.4, 0.4), line("免费时长15分钟", 0.4, 0.5, 0.2), line("我知道了", 0.4, 0.6, 0.2)]
    precondition(CloudLaunchPolicy.confirmedDailyReward(reward, reward) != nil)
    precondition(CloudLaunchPolicy.confirmedDailyReward(reward, [line("我知道了", 0.4, 0.6)]) == nil)
    precondition(CloudLaunchPolicy.confirmedDailyReward(reward, reward + [line("验证码", 0.5, 0.5)]) == nil)
    precondition(TavernNavigationEvidence.worldVisible(world))
    precondition(!TavernNavigationEvidence.worldVisible(world + [line("验证码", 0.5, 0.5)]))
    precondition(!TavernNavigationEvidence.worldVisible(Array(world.dropLast())))
    precondition(TavernNavigationEvidence.princeNearby(nearby))
    precondition(!TavernNavigationEvidence.princeNearby(world))
    precondition(TavernNavigationEvidence.layerPoint(layer) != nil)
    precondition(TavernNavigationEvidence.layerPoint(regions) == nil)
    precondition(TavernNavigationEvidence.regionPoint(regions) != nil)
    precondition(TavernNavigationEvidence.regionPoint(regions + [line("蒙德", 0.70, 0.24)]) == nil)
    precondition(TavernNavigationEvidence.isMondstadtMap(city))
    precondition(TavernNavigationEvidence.isMondstadtMap(layer + [line("蒙德城", 0.46, 0.37)]))
    let cluster = TavernNavigationEvidence.clusterPoint(city, width: 1324, height: 752)!
    precondition(abs(cluster.x - 0.529) < 0.003 && abs(cluster.y - 0.602) < 0.003)
    precondition(TavernNavigationEvidence.clusterPoint(city, width: 1324, height: 940) == nil)
    precondition(TavernNavigationEvidence.tavernCandidatePoint(candidates) != nil)
    precondition(TavernNavigationEvidence.tavernCandidatePoint(city + [line("其他猫尾酒馆", 0.66, 0.56)]) == nil)
    precondition(TavernNavigationEvidence.teleportPoint(panel) != nil)
    precondition(TavernNavigationEvidence.teleportPoint(panel.filter { !$0.text.contains("蒙德城") }) == nil)
    precondition(TavernNavigationEvidence.teleportPoint(panel + [line("验证码", 0.5, 0.5)]) == nil)

    var flow = TavernNavigationFlow(at: 0)
    func observe(_ lines: [TextLine], _ time: Double, _ icon: UnitPoint? = nil) -> TavernNavigationFlow.Action {
        flow.observe(lines, width: 1324, height: 752, zoom: icon, at: time)
    }
    precondition(observe(world, 0) == .wait && observe(world, 1) == .openMap)
    precondition(observe(layer, 2) == .wait && observe([], 2.5) == .wait && observe(layer, 3) == .wait)
    guard case .click(_, .mapLayers) = observe(layer, 4) else { preconditionFailure("map layers") }
    precondition(observe(regions, 5) == .wait)
    guard case .click(_, .mondstadt) = observe(regions, 6) else { preconditionFailure("region") }
    for index in 0..<8 {
        let time = 7.0 + Double(index) * 2
        precondition(observe(city, time, zoom) == .wait)
        guard case .click(_, .zoom) = observe(city, time + 1, zoom) else { preconditionFailure("zoom") }
    }
    precondition(observe(city, 23, zoom) == .wait)
    guard case .click(_, .iconCluster) = observe(city, 24, zoom) else { preconditionFailure("cluster") }
    precondition(observe(candidates, 25) == .wait)
    guard case .click(_, .tavernCandidate) = observe(candidates, 26) else { preconditionFailure("tavern") }
    precondition(observe(panel, 27) == .wait)
    guard case .click(_, .teleport) = observe(panel, 28) else { preconditionFailure("teleport") }
    precondition(observe(nearby, 31) == .wait && observe(nearby, 32) == .forward)
    precondition(observe(prompt, 33) == .wait && observe(prompt, 34) == .arrived)
    var blocked = TavernNavigationFlow(at: 0)
    precondition(blocked.observe(world + [line("验证码", 0.4, 0.4)], width: 1324, height: 752, zoom: nil, at: 1) != .openMap)
    var missing = TavernNavigationFlow(at: 0)
    precondition(missing.observe([], width: 1324, height: 752, zoom: nil, at: 26) != .openMap)

    let empty = [UInt8](repeating: 0, count: 1324 * 752 * 4)
    precondition(TavernMapZoom.point(rgba: empty, width: 1324, height: 752) == nil)
    if let index = CommandLine.arguments.firstIndex(of: "--tavern-zoom-fixture"), index + 1 < CommandLine.arguments.count {
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rgba = GameViewport.rgba(image), let point = TavernMapZoom.point(rgba: rgba, width: image.width, height: image.height) else {
            throw NSError(domain: "TavernFixture", code: 1)
        }
        precondition(abs(point.x - 0.025) < 0.008 && abs(point.y - 0.411) < 0.008)
        print("PASS: private map zoom-control image")
    }
    print("PASS: tavern navigation evidence, sequential confirmation, bounded movement and timeout")
}
