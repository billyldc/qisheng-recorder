import Foundation

public enum CloudPageState: String, Sendable {
    case favorites, recentReplays, prince, princeGreeting, princeDialogue, replayEnd, gameEntry, loading, login, launcher, disconnected, dailyReward, unknown
}

public enum CloudLaunchPolicy {
    public static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "ys.mihoyo.com" &&
        (url.path == "/cloud" || url.path.hasPrefix("/cloud/"))
    }

    public static func loginFrameAllowed(_ url: URL) -> Bool {
        allowed(url) || (url.scheme == "https" && ["user.mihoyo.com", "account.mihoyo.com"].contains(url.host ?? ""))
    }

    public static func state(_ lines: [TextLine]) -> CloudPageState {
        let text = lines.map { $0.text.filter { !$0.isWhitespace } }.joined(separator: "\n")
        if ["验证码", "短信登录", "密码登录", "扫码登录", "手机号登录"].contains(where: text.contains) { return .login }
        if text.contains("连接中断"), uniquePoint(lines, labels: ["退出游戏"]) != nil { return .disconnected }
        if ["每日登录奖励", "每日登陆奖励"].contains(where: text.contains), text.contains("免费时长"),
           uniquePoint(lines, labels: ["我知道了"]) != nil { return .dailyReward }
        // The recent tab also displays a top-right “收藏对局 5/5” counter.
        // Only the left-hand page heading is evidence of the selected favorites tab.
        if text.contains("最近对局") { return .recentReplays }
        let favoriteHeading = lines.contains {
            $0.x < 0.5 && $0.y < 0.45 && compact($0.text).contains("收藏对局")
        }
        if favoriteHeading { return .favorites }
        if princeChoicesVisible(lines) { return .princeDialogue }
        if princeGreetingPoint(lines) != nil { return .princeGreeting }
        if princePoint(lines) != nil { return .prince }
        if ["对局胜利", "对局失败"].contains(where: text.contains), uniquePoint(lines, labels: ["退出观看"]) != nil { return .replayEnd }
        if uniquePoint(lines, labels: ["点击进入"]) != nil { return .gameEntry }
        if ["正在检测网络环境", "游戏启动中", "正在排队", "正在加载"].contains(where: text.contains) { return .loading }
        if ["开始游戏", "进入游戏"].contains(where: text.contains) { return .launcher }
        return .unknown
    }

    /// Enable move-only keepalive even when the already-running world needs another OCR pass.
    public static func hasGameSession(_ lines: [TextLine]) -> Bool {
        guard ![.login, .disconnected].contains(state(lines)) else { return false }
        return lines.contains {
            $0.x > 0.7 && $0.y > 0.65 && compact($0.text).range(of: #"^UID[:：]?[0-9]{5,15}$"#, options: .regularExpression) != nil
        }
    }

    /// Exact, unique on-screen launch labels only; never selects subscriptions or notices.
    public static func startPoint(_ lines: [TextLine]) -> UnitPoint? {
        guard state(lines) == .launcher else { return nil }
        return uniquePoint(lines, labels: ["开始游戏", "进入游戏"])
    }

    public static func navigationPoint(_ lines: [TextLine]) -> UnitPoint? {
        switch state(lines) {
        case .disconnected: return uniquePoint(lines, labels: ["退出游戏"])
        case .dailyReward: return uniquePoint(lines, labels: ["我知道了"])
        case .gameEntry: return uniquePoint(lines, labels: ["点击进入"])
        case .princeDialogue: return princeReplayPoint(lines)
        case .prince: return princePoint(lines)
        case .princeGreeting: return princeGreetingPoint(lines)
        case .replayEnd: return uniquePoint(lines, labels: ["退出观看"])
        default: return nil
        }
    }

    public static func confirmedDisconnectExit(_ first: [TextLine], _ second: [TextLine]) -> UnitPoint? {
        guard state(first) == .disconnected, state(second) == .disconnected,
              let a = navigationPoint(first), let b = navigationPoint(second),
              abs(a.x - b.x) < 0.025, abs(a.y - b.y) < 0.025 else { return nil }
        return b
    }

    public static func confirmedDailyReward(_ first: [TextLine], _ second: [TextLine]) -> UnitPoint? {
        guard state(first) == .dailyReward, state(second) == .dailyReward,
              let a = navigationPoint(first), let b = navigationPoint(second),
              abs(a.x - b.x) < 0.025, abs(a.y - b.y) < 0.025 else { return nil }
        return b
    }

    public static func confirmedPrincePrompt(_ first: [TextLine], _ second: [TextLine]) -> UnitPoint? {
        guard state(first) == .prince, state(second) == .prince,
              let a = navigationPoint(first), let b = navigationPoint(second),
              abs(a.x - b.x) < 0.025, abs(a.y - b.y) < 0.025 else { return nil }
        return b
    }

    public static func recentTabKeyPoint(_ lines: [TextLine]) -> UnitPoint? {
        guard state(lines) == .recentReplays else { return nil }
        let headings = lines.filter { $0.x < 0.5 && $0.y < 0.45 }
        if let heading = uniquePoint(headings, labels: ["对局回放/最近对局", "最近对局"]) { return heading }
        guard let q = uniquePoint(lines, labels: ["Q"]), let e = uniquePoint(lines, labels: ["E"]),
              q.x < e.x, (0.04...0.3).contains(e.x - q.x), abs(q.y - e.y) < 0.025,
              e.y < 0.45 else { return nil }
        return e
    }

    private static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !"「」『』。“”\"".contains($0) }
    }

    /// Require the same unique replay entry in two frames before clicking a dialogue choice.
    public static func confirmedPrinceReplayPoint(_ first: [TextLine], _ second: [TextLine]) -> UnitPoint? {
        guard state(first) == .princeDialogue, state(second) == .princeDialogue,
              let a = princeReplayPoint(first), let b = princeReplayPoint(second),
              abs(a.x - b.x) < 0.025, abs(a.y - b.y) < 0.025 else { return nil }
        return b
    }

    private static let princeChoiceLabels = [
        "查询牌手等级", "进行铸境研炼挑战", "进行酒馆牌局挑战",
        "看看卡牌商店的商品", "观看一下对局回放", "观看对局回放", "暂时有别的事"
    ]

    private static func princeChoiceLabel(_ text: String) -> String? {
        let value = String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
        })
        for label in princeChoiceLabels where value.hasSuffix(label) {
            let prefix = value.dropLast(label.count)
            // Real menu glyphs become 口 / 日 / t / 4 in Vision. Never accept
            // arbitrary Chinese prefixes or approximate another dialogue action.
            if prefix.count <= 2 && prefix.allSatisfy({ "口囗日Ddt0123456789".contains($0) }) { return label }
        }
        return nil
    }

    private static func princeChoices(_ lines: [TextLine]) -> [TextLine] {
        lines.compactMap { line in
            guard let label = princeChoiceLabel(line.text),
                  [line.x, line.y, line.width, line.height].allSatisfy({ $0.isFinite }),
                  line.x > 0.2, line.y > 0.2, line.y < 0.86,
                  line.width > 0, line.width < 0.6, line.height > 0, line.height < 0.08,
                  line.x + line.width <= 1, line.y + line.height <= 1 else { return nil }
            return TextLine(text: label, x: line.x, y: line.y, width: line.width, height: line.height)
        }
    }

    private static func princeChoicesVisible(_ lines: [TextLine]) -> Bool {
        let choices = princeChoices(lines)
        let speaker = lines.contains { compact($0.text) == "小王子" }
        if speaker && princeReplayPoint(lines) != nil { return true }
        // The greeting remains below the menu. Missing the replay label must not
        // turn a visible choice list back into a greeting and press F on item one.
        return choices.contains { anchor in
            let stack = choices.filter {
                abs($0.x - anchor.x) < 0.10 &&
                ($0.text == anchor.text || abs($0.y - anchor.y) > 0.025)
            }
            return Set(stack.map(\.text)).count >= (speaker ? 2 : 3)
        }
    }

    private static func princeReplayPoint(_ lines: [TextLine]) -> UnitPoint? {
        uniquePoint(princeChoices(lines), labels: ["观看一下对局回放", "观看对局回放"])
    }

    private static func princeGreetingPoint(_ lines: [TextLine]) -> UnitPoint? {
        // Before the choices appear, the game waits at the Prince's greeting.
        // Require the dialogue controls and the bottom-centred speaker name;
        // the floating NPC label in the world is never enough to click.
        let speakers = lines.filter {
            compact($0.text) == "小王子" && (0.35...0.65).contains($0.x) && (0.60...0.88).contains($0.y)
        }
        guard let speaker = uniquePoint(speakers, labels: ["小王子"]),
              lines.contains(where: { compact($0.text) == "自动" && $0.x < 0.2 && $0.y < 0.35 }) else { return nil }
        let speech = lines.filter {
            $0.width > 0.25 && $0.height < 0.08 && $0.x < 0.6 &&
            $0.y > speaker.y && $0.y < min(0.94, speaker.y + 0.16) && compact($0.text).count >= 8
        }.sorted { $0.y < $1.y }
        guard let first = speech.first else { return nil }
        return uniquePoint([first], labels: [compact(first.text)])
    }

    private static func princePoint(_ lines: [TextLine]) -> UnitPoint? {
        // Vision can merge the key, speech-bubble icon and quoted NPC name into one
        // line, or append the keycap arrow to F. Match that label, not the floating
        // NPC name above the cat, and pair split lines locally rather than requiring
        // F to be unique across the entire game window.
        func label(_ text: String) -> String {
            String(text.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
        }
        let prompts = lines.filter { $0.x > 0.35 && $0.y > 0.3 && $0.y < 0.85 && $0.width < 0.3 }
        var candidates: [TextLine] = prompts.filter { label($0.text) == "F小王子" }
        let keys = prompts.filter { label($0.text) == "F" && $0.width < 0.08 }
        for name in prompts where label(name.text) == "小王子" {
            let adjacent = keys.filter { key in
                let keyY = key.y + key.height / 2, nameY = name.y + name.height / 2
                return name.x > key.x && name.x - key.x < 0.16 &&
                    abs(nameY - keyY) < max(0.018, max(name.height, key.height) * 0.65)
            }
            if adjacent.count == 1 { candidates.append(name) }
        }
        let normalized = candidates.map { TextLine(text: "prince", x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return uniquePoint(normalized, labels: ["prince"])
    }

    private static func uniquePoint(_ lines: [TextLine], labels: [String]) -> UnitPoint? {
        var points: [UnitPoint] = []
        for line in lines {
            guard labels.contains(compact(line.text)),
                  [line.x, line.y, line.width, line.height].allSatisfy({ $0.isFinite }),
                  line.x >= 0, line.y >= 0, line.width > 0, line.height > 0,
                  line.x + line.width <= 1, line.y + line.height <= 1 else { continue }
            let point = UnitPoint(x: line.x + line.width / 2, y: line.y + line.height / 2)
            if !points.contains(where: { abs($0.x - point.x) < 0.005 && abs($0.y - point.y) < 0.005 }) { points.append(point) }
        }
        return points.count == 1 ? points[0] : nil
    }

    /// Preserve deliberate checkboxes and manually corrected characters only when identities match.
    public static func restoringChoices(_ previous: [Replay], in found: [Replay], freshPerspective: ReplayPerspective = .own) -> [Replay]? {
        guard !previous.isEmpty else {
            guard freshPerspective != .own else { return found }
            return found.map { item in
                var result = item
                result.recordingPerspective = freshPerspective
                return result
            }
        }
        let hasChoices = previous.contains { !$0.selected || $0.preferredPerspective != .own || $0.manualCharacters?.contains(true) == true }
        let old = Dictionary(grouping: previous, by: { $0.date + "|" + $0.mode })
        let new = Dictionary(grouping: found, by: { $0.date + "|" + $0.mode })
        guard Set(old.keys) == Set(new.keys), old.values.allSatisfy({ $0.count == 1 }), new.values.allSatisfy({ $0.count == 1 }) else {
            return hasChoices ? nil : found
        }
        return found.map { item in
            var result = item
            let prior = old[item.date + "|" + item.mode]![0]
            result.selected = prior.selected
            result.recordingPerspective = prior.recordingPerspective
            if let manual = prior.manualCharacters, manual.count == 6, prior.left.count == 3, prior.right.count == 3,
               result.left.count == 3, result.right.count == 3 {
                for index in 0..<3 {
                    if manual[index] { result.left[index] = prior.left[index] }
                    if manual[index + 3] { result.right[index] = prior.right[index] }
                }
                result.manualCharacters = manual
            }
            return result
        }
    }

    public static func verified(_ first: [TextLine], _ second: [TextLine], rows: [Replay]) -> Bool {
        guard state(first) == .favorites, state(second) == .favorites, !rows.isEmpty,
              rows.allSatisfy({ $0.playDetected && $0.date != "未知日期" }) else { return false }
        let a = Set(first.compactMap { ReplayText.date($0.text) })
        let b = Set(second.compactMap { ReplayText.date($0.text) })
        return !a.isEmpty && a == b && rows.allSatisfy { b.contains($0.date) }
    }
}
