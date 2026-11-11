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
    func observe(_ lines: [TextLine], _ time: Double) -> TavernNavigationFlow.Action {
        flow.observe(lines, width: 1324, height: 752, zoom: nil, at: time)
    }
    precondition(observe(world, 0) == .wait)
    guard case .needsAssistance = observe(world, 1) else { preconditionFailure("An outdoor HUD does not prove a tavern teleport") }
    precondition(flow.waitingForUser)
    for time in 2...200 {
        precondition(observe(time % 2 == 0 ? world : city, Double(time)) == .wait)
    }
    precondition(observe(nearby, 201) == .wait && observe(nearby, 202) == .wait)
    precondition(observe(nearby, 205) == .wait && observe(nearby, 206) == .forward)
    precondition(observe(prompt, 207) == .wait && observe(prompt, 208) == .arrived)

    var missing = TavernNavigationFlow(at: 0)
    guard case .needsAssistance = missing.observe([], width: 1324, height: 752, zoom: nil, at: 26) else {
        preconditionFailure("Unknown input must wait for help, not exit")
    }
    precondition(missing.observe([], width: 1324, height: 752, zoom: nil, at: 6000) == .wait)
    precondition(missing.observe(prompt, width: 1324, height: 752, zoom: nil, at: 6001) == .wait)
    precondition(missing.observe(prompt, width: 1324, height: 752, zoom: nil, at: 6002) == .arrived)
    var blocked = TavernNavigationFlow(at: 0)
    guard case .needsAssistance = blocked.observe(world + [line("验证码", 0.4, 0.4)],
        width: 1324, height: 752, zoom: nil, at: 1) else { preconditionFailure("Login requires user assistance") }
    precondition(blocked.observe(prompt, width: 1324, height: 752, zoom: nil, at: 2) == .wait)
    precondition(blocked.observe(prompt, width: 1324, height: 752, zoom: nil, at: 3) == .arrived)
    for invalidTime in [Double.nan, .infinity, -1] {
        var invalidClock = TavernNavigationFlow(at: 0)
        guard case .stop = invalidClock.observe(nearby, width: 1324, height: 752, zoom: nil, at: invalidTime) else {
            preconditionFailure("Invalid clock must never authorize movement")
        }
    }
    for damaged in [layer, regions, city, candidates, panel] {
        var map = TavernNavigationFlow(at: 0)
        _ = map.observe(damaged, width: 1324, height: 752, zoom: zoom, at: 0)
        let action = map.observe(damaged, width: 1324, height: 752, zoom: zoom, at: 26)
        guard case .needsAssistance = action else { preconditionFailure("Historical indoor map evidence must not become an outdoor route") }
    }
    var moved = TavernNavigationFlow(at: 0)
    func move(_ time: Double) -> TavernNavigationFlow.Action {
        moved.observe(nearby, width: 1324, height: 752, zoom: nil, at: time)
    }
    precondition(move(0) == .wait && move(1) == .wait && move(4) == .wait)
    let beforeUnsent = moved
    precondition(move(5) == .forward)
    moved.pageChanged(from: beforeUnsent, inputSent: false)
    precondition(move(5.5) == .wait && move(6) == .forward)
    let afterSent = moved
    moved.pageChanged(from: beforeUnsent, inputSent: true)
    precondition(move(7) == .wait && move(9) == .wait && move(10) == .forward)
    precondition(move(13) == .wait && move(14) == .forward)
    precondition(move(17) == .wait)
    guard case .needsAssistance = move(18) else { preconditionFailure("Bounded approach must not walk forever") }
    _ = afterSent
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
