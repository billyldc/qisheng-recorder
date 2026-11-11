import Foundation
import ReplayCore

func checkAdversarialNavigation() {
    func line(_ text: String, _ x: Double, _ y: Double, _ width: Double = 0.05, _ height: Double = 0.02) -> TextLine {
        .init(text: text, x: x, y: y, width: width, height: height)
    }
    let uid = line("UID:" + String(repeating: "0", count: 9), 0.85, 0.97, 0.14)
    let world = [uid, line("Enter", 0.04, 0.95), line("E", 0.86, 0.95), line("Q", 0.94, 0.95)]
    let nearby = world + [line("小王子", 0.47, 0.19), line("猫之牌圣", 0.47, 0.22)]
    let prompt = [uid, line("F", 0.55, 0.58), line("小王子", 0.61, 0.58)]
    let favorites = [line("收藏对局", 0.08, 0.1, 0.15), line("2000年1月1日 01:01", 0.3, 0.3, 0.2)]
    let fixtures: [[TextLine]] = [
        [], world, nearby, prompt, favorites,
        [uid, line("提瓦特", 0.85, 0.92)],
        [uid, line("猫尾酒馆", 0.8, 0.92)],
        Array(world.dropLast()),
        nearby + [line("小王子", 0.50, 0.19)],
        nearby + [line("验证码", 0.3, 0.3)],
        world + [line("小王子", .nan, 0.19), line("猫之牌圣", 0.47, 0.22)],
        [line("收藏对局", -1, -1)],
        [line("收藏对局", .infinity, 0.1)],
        [line("收藏对局", 0.1, 0.1, -0.1)],
        [line("收藏对局", 0.1, 0.1, 0.95)],
        world + [line("切换至对手视角", 0.5, 0.3)]
    ]
    for invalid in fixtures[11...14] { precondition(CloudLaunchPolicy.state(invalid) == .unknown) }
    precondition(ReplayControls.speed(in: [line("1x", 0.85, 0.85, -0.1)]) == nil)
    precondition(ReplayControls.speed(in: [line("2x", 0.85, 0.85, 0.1, .infinity)]) == nil)
    var seed: UInt64 = 0x51535243
    func random(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(bound))
    }
    var observations = 0
    for _ in 0..<1000 {
        var flow = TavernNavigationFlow(at: 0)
        var now = 0.0, previousTime: Double?
        var previous: [TextLine] = []
        var arrived = false
        for _ in 0..<80 {
            let lines = fixtures[random(fixtures.count)]
            now += [0.0, 0.3, 0.7, 1, 3, 50][random(6)]
            let malformedClock = random(80) == 0
            let at = malformedClock ? Double.nan : now
            let validSize = random(20) != 0
            let action = flow.observe(lines, width: validSize ? 1324 : 0, height: 752,
                                      zoom: .init(x: .nan, y: .infinity), at: at)
            observations += 1
            switch action {
            case .forward:
                precondition(validSize && !malformedClock)
                precondition(TavernNavigationEvidence.princeNearby(lines))
                precondition(TavernNavigationEvidence.princeNearby(previous))
                precondition(previousTime.map { (0.2...10).contains(now - $0) } == true)
                precondition(CloudLaunchPolicy.state(lines) != .login)
            case .arrived:
                if !arrived {
                    let page = CloudLaunchPolicy.state(lines)
                    precondition([.prince, .favorites, .recentReplays].contains(page))
                    precondition(CloudLaunchPolicy.state(previous) == page)
                }
                arrived = true
            case .stop:
                precondition(malformedClock)
                flow = TavernNavigationFlow(at: now)
                arrived = false; previous = []; previousTime = nil
                continue
            case .wait, .needsAssistance: break
            }
            previous = lines
            previousTime = now
        }
    }
    print("PASS: \(observations) seeded malformed/partial/duplicate/delayed navigation observations; no inferred outdoor map route")
}
