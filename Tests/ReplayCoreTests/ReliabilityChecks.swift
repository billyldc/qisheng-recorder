import Foundation
import ReplayCore
import ImageIO

func checkRecordingReliability() {
    var idle = CaptureHealth(at: 0)
    idle.frame(.complete, at: 1)
    idle.written(duration: 1, bytes: 100, at: 1)
    precondition(idle.hasWrittenMedia)
    idle.frame(.idle, at: 2)
    precondition(idle.failure(at: 10) == nil)
    precondition(idle.failure(at: 33) != nil, "Idle must not disable callback timeout")

    var writer = CaptureHealth(at: 0)
    for second in 1...35 {
        writer.frame(.complete, at: Double(second))
        writer.written(duration: 1, bytes: 100 + second, at: Double(second))
    }
    precondition(writer.failure(at: 35) != nil, "Byte growth alone is not time advancement")
    var blank = CaptureHealth(at: 0)
    blank.frame(.complete, at: 1)
    blank.written(duration: 1, bytes: 100, at: 1)
    blank.frame(.unavailable, at: 2)
    blank.frame(.idle, at: 10)
    blank.written(duration: 10, bytes: 1000, at: 10)
    precondition(blank.failure(at: 14) != nil)
    blank.frame(.complete, at: 14)
    precondition(blank.failure(at: 14) == nil)
    var empty = CaptureHealth(at: 0)
    empty.written(duration: .nan, bytes: 0, at: 10)
    precondition(!empty.hasWrittenMedia && empty.failure(at: 15) != nil)
    var healthy = CaptureHealth(at: 0)
    for second in 1...180 {
        healthy.frame(second % 3 == 0 ? .idle : .complete, at: Double(second))
        healthy.written(duration: Double(second), bytes: second * 100, at: Double(second))
        precondition(healthy.failure(at: Double(second)) == nil)
    }

    var entry = ReplayEntryGate(at: 0, grace: 12)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 11) == .wait)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 12) == .retry)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 13) == .wait)
    precondition(entry.observe(listVisible: true, sameRow: true, playbackVisible: false, at: 24) == .failed)
    var loaded = ReplayEntryGate(at: 0, grace: 12)
    precondition(loaded.observe(listVisible: false, sameRow: false, playbackVisible: false, at: 3) == .wait)
    precondition(loaded.observe(listVisible: false, sameRow: false, playbackVisible: true, at: 5) == .wait)
    precondition(loaded.observe(listVisible: false, sameRow: false, playbackVisible: true, at: 6) == .entered)
    var changedList = ReplayEntryGate(at: 0, grace: 12)
    for time in [12.0, 13, 14, 30] {
        precondition(changedList.observe(listVisible: true, sameRow: false, playbackVisible: false, at: time) == .wait)
    }
    precondition(changedList.observe(listVisible: false, sameRow: false, playbackVisible: false, at: 45) == .failed)

    var replay = ReplayProgressHealth()
    let pixels: [UInt8] = [20, 40, 60, 80]
    precondition(replay.observe(pixels: pixels, playback: .running, ending: false, at: 0) == nil)
    precondition(replay.observe(pixels: pixels, playback: .running, ending: false, at: 89) == nil)
    precondition(replay.observe(pixels: pixels, playback: .running, ending: false, at: 90) != nil)
    precondition(replay.observe(pixels: pixels, playback: .running, ending: true, at: 100) == nil)
    var paused = ReplayProgressHealth()
    precondition(paused.observe(pixels: pixels, playback: .paused, ending: false, at: 0) == nil)
    precondition(paused.observe(pixels: pixels, playback: nil, ending: false, at: 44) == nil)
    precondition(paused.observe(pixels: pixels, playback: .paused, ending: false, at: 45) != nil)
    precondition(paused.observe(pixels: [100, 80, 60, 40], playback: .running, ending: false, at: 46) == nil)

    precondition(!RecordingSafety.unavailableWindow(onScreen: false, minimized: false, fullWindow: true, unattended: true))
    precondition(RecordingSafety.unavailableWindow(onScreen: false, minimized: true, fullWindow: true, unattended: true))
    precondition(RecordingSafety.unavailableWindow(onScreen: false, minimized: false, fullWindow: false, unattended: true))
    precondition(RecordingSafety.unavailableWindow(onScreen: false, minimized: false, fullWindow: true, unattended: false))
    print("PASS: capture callbacks, stalled writer, blank recovery, entry evidence/retry, paused/frozen replay, remote window visibility")
}

func checkGameViewport() {
    let width = 320, height = 240
    func frame(_ rect: CGRect, value: UInt8 = 100) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * width + x) * 4
                data[i] = value; data[i + 1] = value; data[i + 2] = value; data[i + 3] = 255
            }
        }
        return data
    }
    let content = CGRect(x: 10, y: 20, width: 300, height: 200)
    let crop = GameViewport.blackBorderBounds(rgba: frame(content), width: width, height: height)
    precondition(crop == CGRect(x: 8, y: 18, width: 304, height: 204))
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    precondition(GameViewport.blackBorderBounds(rgba: frame(full), width: width, height: height) == full)
    precondition(GameViewport.blackBorderBounds(rgba: frame(full, value: 0), width: width, height: height) == nil)
    precondition(GameViewport.blackBorderBounds(rgba: frame(content, value: 15), width: width, height: height) == nil)
    precondition(GameViewport.blackBorderBounds(rgba: frame(CGRect(x: 0, y: 0, width: 150, height: 240)), width: width, height: height) == nil)
    precondition(GameViewport.stableBounds([crop, crop, crop], size: full.size) == crop)
    precondition(GameViewport.stableBounds([crop, nil, crop], size: full.size) == nil)
    precondition(GameViewport.stableBounds([crop, crop, full], size: full.size) == nil)
    precondition(GameViewport.stableBounds([crop, crop], size: full.size) == nil)
    let mapped = GameViewport.pointRect(pixelRect: crop!, imageSize: full.size,
        source: CGRect(x: 0, y: 90, width: 640, height: 480))
    precondition(mapped == CGRect(x: 16, y: 126, width: 608, height: 408))
    precondition(GameViewport.evenPixelBounds(normalized: CGRect(x: 0.1, y: 0.101, width: 0.8, height: 0.798),
                                             size: CGSize(width: 640, height: 480)) == CGRect(x: 64, y: 48, width: 512, height: 384))
    let point = RegionGeometry.screenPoint(UnitPoint(x: 0.5, y: 0.5), source: mapped,
                                         displayOrigin: CGPoint(x: -1920, y: -100))
    precondition(point == CGPoint(x: -1600, y: 230))
    let bytes = frame(content)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    precondition(GameViewport.blackBorderBounds(rgba: GameViewport.rgba(image)!, width: width, height: height) == crop)
    print("PASS: multi-frame black edges, no fixed aspect, dark/blank/half-frame rejection, Retina crop and negative display coordinates")
}

func checkPrivateViewportFixtures() throws {
    guard let index = CommandLine.arguments.firstIndex(of: "--viewport-fixture"), index + 1 < CommandLine.arguments.count else { return }
    struct Fixture: Decodable {
        let images: [String]
        let page: [Double]
        let expected: [Double]
        let preview: String?
    }
    let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[index + 1])))
    precondition(fixture.page.count == 4 && fixture.expected.count == 4)
    func rect(_ values: [Double]) -> CGRect { CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) }
    var candidates: [CGRect?] = []
    var size = CGSize.zero
    var first: CGImage?
    for path in fixture.images {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let full = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let image = full.cropping(to: rect(fixture.page))!
        if first == nil { first = image }
        size = CGSize(width: image.width, height: image.height)
        let crop = GameViewport.blackBorderBounds(rgba: GameViewport.rgba(image)!, width: image.width, height: image.height)
        print("Fixture edge candidate: \(String(describing: crop))")
        candidates.append(crop)
    }
    guard let crop = GameViewport.stableBounds(candidates, size: size) else {
        throw NSError(domain: "ViewportChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: "No stable crop; kept page boundary"])
    }
    precondition(crop == rect(fixture.expected), "Unexpected crop \(crop)")
    if let preview = fixture.preview, let image = first?.cropping(to: crop) {
        let target = CGImageDestinationCreateWithURL(URL(fileURLWithPath: preview) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(target, image, nil)
        precondition(CGImageDestinationFinalize(target))
    }
    print("PASS: private multi-frame viewport fixture (page boundary supplied, not a live browser test)")
}
