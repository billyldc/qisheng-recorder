import Foundation

/// Evidence is deliberately scoped to the cropped game viewport, not Safari's frame.
public enum TavernNavigationEvidence {
    private static func compact(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) &&
            !CharacterSet.punctuationCharacters.contains($0) && !CharacterSet.symbols.contains($0)
        })
    }

    private static func valid(_ line: TextLine) -> Bool {
        [line.x, line.y, line.width, line.height].allSatisfy(\.isFinite) &&
        line.x >= 0 && line.y >= 0 && line.width > 0 && line.height > 0 &&
        line.x + line.width <= 1 && line.y + line.height <= 1
    }

    private static func unique(_ lines: [TextLine], _ predicate: (TextLine) -> Bool) -> UnitPoint? {
        let matches = lines.filter { valid($0) && predicate($0) }
        guard matches.count == 1, let line = matches.first else { return nil }
        return UnitPoint(x: line.x + line.width / 2, y: line.y + line.height / 2)
    }

    private static func safe(_ lines: [TextLine]) -> Bool {
        CloudLaunchPolicy.state(lines) != .login && CloudLaunchPolicy.hasGameSession(lines)
    }

    public static func worldVisible(_ lines: [TextLine]) -> Bool {
        guard safe(lines), CloudLaunchPolicy.state(lines) == .unknown else { return false }
        let enter = unique(lines) { compact($0.text).lowercased() == "enter" && $0.x < 0.2 && $0.y > 0.8 }
        let e = unique(lines) { compact($0.text) == "E" && $0.x > 0.75 && $0.y > 0.8 }
        let q = unique(lines) { compact($0.text) == "Q" && $0.x > 0.8 && $0.y > 0.8 }
        guard let enter, let e, let q else { return false }
        return enter.x < e.x && e.x < q.x && abs(e.y - q.y) < 0.04
    }

    /// The lower-right map layer selector is only accepted at its known location.
    public static func layerPoint(_ lines: [TextLine]) -> UnitPoint? {
        guard safe(lines), regionPoint(lines) == nil, teleportPoint(lines) == nil else { return nil }
        let layers = ["提瓦特", "猫尾酒馆", "渊下宫", "尘歌壶", "旧日之海", "空之神殿", "远古圣山", "千星奇域大厅"]
        return unique(lines) { layers.contains(compact($0.text)) && $0.x > 0.78 && $0.y > 0.82 && $0.width < 0.2 }
    }

    public static func regionPoint(_ lines: [TextLine]) -> UnitPoint? {
        guard safe(lines), lines.contains(where: { valid($0) && compact($0.text) == "地图" && $0.x > 0.6 && $0.y < 0.12 }),
              lines.contains(where: { valid($0) && compact($0.text) == "璃月" && $0.x > 0.75 && $0.y < 0.35 }) else { return nil }
        return unique(lines) { compact($0.text) == "蒙德" && $0.x > 0.6 && $0.x < 0.8 && $0.y < 0.35 }
    }

    public static func isMondstadtMap(_ lines: [TextLine]) -> Bool {
        layerPoint(lines) != nil && unique(lines, {
            compact($0.text) == "蒙德城" && (0.20...0.65).contains($0.x) && (0.08...0.55).contains($0.y)
        }) != nil
    }

    /// After selecting Mondstadt and fully zooming in, its stable map label anchors the nearby icon cluster.
    /// The next step must still recognize the exact tavern entry and teleport panel.
    public static func clusterPoint(_ lines: [TextLine], width: Int, height: Int) -> UnitPoint? {
        guard layerPoint(lines) != nil, width > 0, height > 0,
              (1.65...1.86).contains(Double(width) / Double(height)),
              let city = unique(lines, { compact($0.text) == "蒙德城" && (0.25...0.55).contains($0.x) && (0.08...0.35).contains($0.y) }) else { return nil }
        let point = UnitPoint(x: city.x + 0.159 * Double(height) / Double(width), y: city.y + 0.418)
        guard (0.25...0.75).contains(point.x), (0.35...0.8).contains(point.y) else { return nil }
        return point
    }

    public static func tavernCandidatePoint(_ lines: [TextLine]) -> UnitPoint? {
        guard layerPoint(lines) != nil, lines.contains(where: { valid($0) && compact($0.text) == "蒙德城" && $0.x < 0.6 }) else { return nil }
        return unique(lines) { line in
            let label = compact(line.text)
            guard label.hasSuffix("猫尾酒馆") else { return false }
            let prefix = label.dropLast("猫尾酒馆".count)
            return prefix.count <= 2 && prefix.allSatisfy { "Cc口囗D0".contains($0) } &&
                line.x > 0.5 && line.x < 0.85 && line.y > 0.25 && line.y < 0.87 && line.width < 0.25
        }
    }

    public static func teleportPoint(_ lines: [TextLine]) -> UnitPoint? {
        guard safe(lines), lines.contains(where: { valid($0) && compact($0.text) == "猫尾酒馆" && $0.x > 0.7 && $0.y < 0.12 }),
              lines.contains(where: { valid($0) && compact($0.text).contains("蒙德蒙德城") && $0.x > 0.7 && $0.y < 0.22 }) else { return nil }
        return unique(lines) { compact($0.text) == "传送至猫尾酒馆" && $0.x > 0.72 && $0.y > 0.8 && $0.width < 0.25 }
    }

    public static func princeNearby(_ lines: [TextLine]) -> Bool {
        guard worldVisible(lines) else { return false }
        // Vision may read 小王子 as 冰王子; the aligned unique title is mandatory.
        let names = lines.filter {
            valid($0) && ["小王子", "冰王子"].contains(compact($0.text)) &&
            (0.3...0.7).contains($0.x) && (0.05...0.5).contains($0.y)
        }
        let titles = lines.filter {
            valid($0) && compact($0.text) == "猫之牌圣" &&
            (0.3...0.7).contains($0.x) && $0.y < 0.55
        }
        guard names.count == 1, titles.count == 1, let name = names.first, let title = titles.first else { return false }
        let horizontalDifference = abs((name.x + name.width/2) - (title.x + title.width/2))
        let verticalGap = title.y - (name.y + name.height)
        return horizontalDifference <= 0.05 && (-0.01...0.055).contains(verticalGap)
    }
}
