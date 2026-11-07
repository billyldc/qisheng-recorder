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
    precondition(CloudLaunchPolicy.confirmedPrincePrompt(prompt, prompt) != nil)
    precondition(CloudLaunchPolicy.confirmedPrincePrompt(prompt, prompt + [line("观看一下对局回放", 0.65, 0.60, 0.2)]) == nil)
    precondition(CloudLaunchPolicy.confirmedPrincePrompt(prompt, [uid, line("F", 0.65, 0.58), line("小王子", 0.71, 0.58)]) == nil)
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
    let partialWorld = [line("Q", 0.94, 0.95)]
    let complementary = [uid, line("Enter", 0.045, 0.95), line("E", 0.88, 0.95)]
    let supplemented = TavernNavigationEvidence.mergingWorldHUD(partialWorld, additions: complementary)
    precondition(TavernNavigationEvidence.worldVisible(supplemented))
    let duplicate = TavernNavigationEvidence.mergingWorldHUD(supplemented, additions: [line("E", 0.882, 0.951)])
    precondition(TavernNavigationEvidence.worldVisible(duplicate))
    let ambiguous = TavernNavigationEvidence.mergingWorldHUD(supplemented, additions: [line("E", 0.81, 0.95)])
    precondition(!TavernNavigationEvidence.worldVisible(ambiguous))
    let invalid = TavernNavigationEvidence.mergingWorldHUD(partialWorld, additions: [
        line("Enter", 0.6, 0.4), line("E", 0.1, 0.1), line("Q", 0.1, 0.1),
        line(uid.text, 0.2, 0.2), line("其他", 0.9, 0.9)
    ])
    precondition(invalid.count == partialWorld.count && !TavernNavigationEvidence.worldVisible(invalid))
    precondition(TavernNavigationEvidence.princeNearby(nearby))
    precondition(!TavernNavigationEvidence.princeNearby(world))
    let misread = world + [line("「冰王子」", 0.465, 0.198, 0.057, 0.026),
                           line("＜猫之牌圣>", 0.465, 0.227, 0.057, 0.024)]
    precondition(TavernNavigationEvidence.princeNearby(misread))
    precondition(!TavernNavigationEvidence.princeNearby(world + [line("雪王子", 0.465, 0.198), line("猫之牌圣", 0.465, 0.227)]))
    precondition(!TavernNavigationEvidence.princeNearby(world + [line("冰王子", 0.465, 0.198), line("牌圣之手", 0.465, 0.227)]))
    precondition(!TavernNavigationEvidence.princeNearby(world + [line("冰王子", 0.465, 0.198), line("猫之牌圣", 0.6, 0.227)]))
    precondition(!TavernNavigationEvidence.princeNearby(world + [line("冰王子", 0.465, 0.198), line("猫之牌圣", 0.465, 0.35)]))
    precondition(!TavernNavigationEvidence.princeNearby(misread + [line("小王子", 0.49, 0.19)]))
    precondition(!TavernNavigationEvidence.princeNearby(misread + [line("猫之牌圣", 0.49, 0.23)]))
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

    var dialogue = PrinceDialogueGuard()
    precondition(dialogue.observe(.unknown, at: 0) == .proceed)
    precondition(dialogue.observe(.princeDialogue, at: 1) == .proceed)
    for time in 2...4 { precondition(dialogue.observe(.unknown, at: Double(time)) == .waitForChoice) }
    precondition(dialogue.observe(.prince, at: 5) == .stop)
    dialogue = PrinceDialogueGuard()
    precondition(dialogue.observe(.princeDialogue, at: 10) == .proceed)
    dialogue.confirmationFailed()
    precondition(dialogue.unconfirmedChoices == 1)
    dialogue.replayClickSent(at: 11)
    for time in 12...36 { precondition(dialogue.observe(.unknown, at: Double(time)) == .waitForReplay) }
    precondition(dialogue.observe(.unknown, at: 37) == .stop)
    dialogue = PrinceDialogueGuard()
    precondition(dialogue.observe(.princeDialogue, at: 10) == .proceed)
    dialogue.replayClickSent(at: 11)
    precondition(dialogue.observe(.loading, at: 30) == .proceed)
    precondition(dialogue.observe(.unknown, at: 54) == .waitForReplay)
    precondition(dialogue.observe(.recentReplays, at: 55) == .proceed)
    precondition(dialogue.observe(.unknown, at: 56) == .proceed)
    precondition(dialogue.observe(.prince, at: 57) == .proceed)
    dialogue = PrinceDialogueGuard()
    precondition(dialogue.observe(.princeDialogue, at: 1) == .proceed)
    precondition(dialogue.observe(.favorites, at: 2) == .proceed)
    precondition(dialogue.observe(.unknown, at: 3) == .proceed)
    precondition(dialogue.observe(.login, at: 4) == .proceed)
    dialogue = PrinceDialogueGuard()
    precondition(dialogue.observe(.princeDialogue, at: 10) == .proceed)
    dialogue.replayClickSent(at: 11)
    for time in 12...14 { precondition(dialogue.observe(.princeGreeting, at: Double(time)) == .waitForChoice) }
    precondition(dialogue.observe(.prince, at: 15) == .stop)
    precondition(dialogue.observe(.unknown, at: .nan) == .stop)

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
    var nearbyFlow = TavernNavigationFlow(at: 0)
    func near(_ lines: [TextLine], _ time: Double) -> TavernNavigationFlow.Action {
        nearbyFlow.observe(lines, width: 1324, height: 752, zoom: nil, at: time)
    }
    precondition(near(world, 0) == .wait && near(nearby, 1) == .wait && near(nearby, 2) == .wait)
    precondition(near(nearby, 5) == .wait && near(nearby, 6) == .forward)
    precondition(near(prompt, 7) == .wait && near(prompt, 8) == .arrived)
    var retry = TavernNavigationFlow(at: 0)
    func retryObserve(_ lines: [TextLine], _ time: Double) -> TavernNavigationFlow.Action {
        retry.observe(lines, width: 1324, height: 752, zoom: nil, at: time)
    }
    precondition(retryObserve(world, 0) == .wait && retryObserve(world, 1) == .openMap)
    precondition(retryObserve(world, 4) == .wait && retryObserve(world, 5) == .wait)
    retry.resetEvidence()
    precondition(retryObserve(world, 6) == .wait && retryObserve(world, 7) == .retryMap)
    precondition(retryObserve(world, 12) == .wait && retryObserve(world, 13) == .wait)
    precondition(retryObserve(layer, 14) == .wait)
    guard case .click(_, .mapLayers) = retryObserve(layer, 15) else { preconditionFailure("map after retry") }
    var changedAfterKey = TavernNavigationFlow(at: 0)
    precondition(changedAfterKey.observe(world, width: 1324, height: 752, zoom: nil, at: 0) == .wait)
    let beforeMap = changedAfterKey
    precondition(changedAfterKey.observe(world, width: 1324, height: 752, zoom: nil, at: 1) == .openMap)
    changedAfterKey.pageChanged(from: beforeMap, inputSent: true)
    precondition(changedAfterKey.observe(layer, width: 1324, height: 752, zoom: nil, at: 2) == .wait)
    guard case .click(_, .mapLayers) = changedAfterKey.observe(layer, width: 1324, height: 752, zoom: nil, at: 3) else {
        preconditionFailure("sent map key must advance without repeating it")
    }
    var changedBeforeKey = TavernNavigationFlow(at: 0)
    precondition(changedBeforeKey.observe(world, width: 1324, height: 752, zoom: nil, at: 0) == .wait)
    let beforeUnsentMap = changedBeforeKey
    precondition(changedBeforeKey.observe(world, width: 1324, height: 752, zoom: nil, at: 1) == .openMap)
    changedBeforeKey.pageChanged(from: beforeUnsentMap, inputSent: false)
    precondition(changedBeforeKey.observe(layer, width: 1324, height: 752, zoom: nil, at: 2) == .wait)
    precondition(changedBeforeKey.observe(world, width: 1324, height: 752, zoom: nil, at: 3) == .wait)
    precondition(changedBeforeKey.observe(world, width: 1324, height: 752, zoom: nil, at: 4) == .openMap)
    let page = CGRect(x: 0, y: 90, width: 1324, height: 820)
    precondition(GameViewport.samePageBounds(page, page.offsetBy(dx: 0.5, dy: 0.5)))
    precondition(!GameViewport.samePageBounds(page, page.offsetBy(dx: 0, dy: 30)))
    precondition(!GameViewport.samePageBounds(page, CGRect(x: 0, y: 90, width: 1324, height: 790)))

    let empty = [UInt8](repeating: 0, count: 1324 * 752 * 4)
    precondition(TavernMapZoom.point(rgba: empty, width: 1324, height: 752) == nil)
    let white = [UInt8](repeating: 255, count: 960 * 544 * 4)
    precondition(TavernMapZoom.point(rgba: white, width: 960, height: 544) == nil)
    if let index = CommandLine.arguments.firstIndex(of: "--tavern-zoom-fixture"), index + 1 < CommandLine.arguments.count {
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let rgba = GameViewport.rgba(image), let point = TavernMapZoom.point(rgba: rgba, width: image.width, height: image.height) else {
            throw NSError(domain: "TavernFixture", code: 1)
        }
        precondition(abs(point.x - 0.025) < 0.008 && abs(point.y - 0.411) < 0.008)
        print("PASS: private map zoom-control image")
    }
    print("PASS: tavern navigation, dialogue transition guard, bounded movement and timeout")
}
