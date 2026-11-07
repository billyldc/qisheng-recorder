import Foundation

/// Detect the bright plus and diamond outline before clicking the map zoom control.
public enum TavernMapZoom {
    public static func point(rgba: [UInt8], width: Int, height: Int) -> UnitPoint? {
        guard width >= 500, height >= 300, rgba.count == width * height * 4,
              (1.65...1.86).contains(Double(width) / Double(height)) else { return nil }
        let radius = max(4, Int((Double(height) * 0.0093).rounded()))
        let cross = max(1, Int((Double(radius) * 0.30).rounded()))
        let diagonal = max(2, Int((Double(radius) * 0.55).rounded()))
        let inside = max(2, Int((Double(radius) * 0.40).rounded()))
        func light(_ x: Int, _ y: Int) -> Int {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            let i = (y * width + x) * 4
            return (Int(rgba[i]) + Int(rgba[i + 1]) + Int(rgba[i + 2])) / 3
        }
        let expectedX = Int((Double(width) * 0.025).rounded())
        let expectedY = Int((Double(height) * 0.411).rounded())
        let search = max(3, Int((Double(height) * 0.008).rounded()))
        var best: (score: Int, x: Int, y: Int)?
        for y in (expectedY - search)...(expectedY + search) {
            for x in (expectedX - search)...(expectedX + search) {
                let middle = [(0, 0), (-cross, 0), (cross, 0), (0, -cross), (0, cross)]
                let ring = [(-radius, 0), (radius, 0), (0, -radius), (0, radius),
                            (-diagonal, -diagonal), (diagonal, -diagonal),
                            (-diagonal, diagonal), (diagonal, diagonal)]
                let gaps = [(-inside, -inside), (inside, -inside), (-inside, inside), (inside, inside)]
                let mid = middle.map { light(x + $0.0, y + $0.1) }
                let rim = ring.map { light(x + $0.0, y + $0.1) }
                let dark = gaps.map { light(x + $0.0, y + $0.1) }
                guard mid.filter({ $0 >= 155 }).count >= 4,
                      rim.filter({ $0 >= 150 }).count >= 6,
                      dark.filter({ $0 < 155 }).count >= 3 else { continue }
                let score = mid.reduce(0, +) + rim.reduce(0, +) - dark.reduce(0, +)
                if best == nil || score > best!.score { best = (score, x, y) }
            }
        }
        guard let best else { return nil }
        return UnitPoint(x: Double(best.x) / Double(width), y: Double(best.y) / Double(height))
    }
}
