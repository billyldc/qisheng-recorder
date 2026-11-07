import Foundation
import CoreGraphics

public struct UnitPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Replay: Codable, Identifiable, Equatable, Sendable {
    public var id: Int
    public var selected = true
    public var date: String
    public var mode: String
    public var left: [String]
    public var right: [String]
    public var play: UnitPoint
    public var playDetected = false
    public var manualCharacters: [Bool]?
    public var recordingPerspective: ReplayPerspective?
    public var confirmedPerspective: ReplayPerspective?
    public var perspectiveStatus: String?
    public var recordingOutcome: String?
    public var preferredPerspective: ReplayPerspective { recordingPerspective ?? .own }
    public init(id: Int, date: String, mode: String, left: [String], right: [String], play: UnitPoint) {
        self.id = id; self.date = date; self.mode = mode
        self.left = left; self.right = right; self.play = play
    }
    public var filename: String {
        let view = recordingPerspective.map { "_\($0.label)" } ?? ""
        return Filename.safe("第\(id)局\(view)_\(date)_\(mode)_己方-\(left.joined(separator: "-"))_对方-\(right.joined(separator: "-"))")
    }
}

public enum Filename {
    public static func safe(_ value: String, maxBytes: Int = 220) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        for character in cleaned {
            if (result + String(character)).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result.isEmpty || result == "." || result == ".." ? "回放" : result
    }
    public static func uniqueURL(directory: URL, stem: String, extension ext: String = "mp4") -> URL {
        let base = safe(stem)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }
}

public enum RegionGeometry {
    public static func displayIndex(window: CGRect, displays: [CGRect]) -> Int? {
        displays.indices.filter { !window.intersection(displays[$0]).isEmpty }.max {
            let a = window.intersection(displays[$0]), b = window.intersection(displays[$1])
            return a.width * a.height < b.width * b.height
        }
    }
    // AppKit local coordinates are bottom-left; ScreenCaptureKit uses top-left points.
    public static func sourceRect(selection: CGRect, displaySize: CGSize) -> CGRect {
        CGRect(x: selection.minX, y: displaySize.height - selection.maxY,
               width: selection.width, height: selection.height)
    }
    public static func drag(from a: CGPoint, to b: CGPoint, bounds: CGRect) -> CGRect {
        let a = CGPoint(x: min(bounds.maxX, max(bounds.minX, a.x)), y: min(bounds.maxY, max(bounds.minY, a.y)))
        let b = CGPoint(x: min(bounds.maxX, max(bounds.minX, b.x)), y: min(bounds.maxY, max(bounds.minY, b.y)))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    public static func outputSize(rect: CGRect, scale: Double, maxHeight: Double = 1080) -> CGSize {
        let factor = min(scale, maxHeight / rect.height)
        return CGSize(width: max(2, Int(ceil(rect.width * factor / 2)) * 2),
                      height: max(2, Int(ceil(rect.height * factor / 2)) * 2))
    }
    public static func screenPoint(_ unit: UnitPoint, source: CGRect, displayOrigin: CGPoint) -> CGPoint {
        CGPoint(x: displayOrigin.x + source.minX + source.width * unit.x,
                y: displayOrigin.y + source.minY + source.height * unit.y)
    }
}

public struct TextLine: Codable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum ReplayText {
    public static func date(_ text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "：", with: ":")
        let pattern = #"(\d{4})年(\d{1,2})月(\d{1,2})日(\d{1,2}):(\d{2})"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = compact as NSString
        guard let match = regex.firstMatch(in: compact, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let values = (1...5).map { Int(ns.substring(with: match.range(at: $0))) ?? -1 }
        guard (2000...2100).contains(values[0]), (1...12).contains(values[1]), (1...31).contains(values[2]),
              (0...23).contains(values[3]), (0...59).contains(values[4]) else { return nil }
        return String(format: "%04d-%02d-%02d_%02d%02d", values[0], values[1], values[2], values[3], values[4])
    }
}
