import Foundation
import Vision
import AppKit
import ImageIO
import ReplayCore

enum Metadata {
    private static let workers = WorkerProcesses()
    private static let reviewWorkers = WorkerProcesses()
    static func beginOperation() { workers.reset() }
    static func cancelOperation() { workers.cancel() }
    static func cancelReview() { reviewWorkers.cancel() }
    static func beginReview() { reviewWorkers.reset() }
    static func text(in image: CGImage, keycap: Bool = false) throws -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = keycap ? ["en-US"] : ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = !keycap
        if keycap { request.minimumTextHeight = 0.003 }
        request.customWords = keycap ? ["F"] : ["小王子", "观看一下对局回放", "牌手等级", "铸境研炼", "酒馆牌局挑战", "卡牌商店", "收藏对局", "最近对局", "查看规则书", "切换至对手视角", "切换至我方视角", "退出观看"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first else { return nil }
            let box = result.boundingBox
            return TextLine(text: candidate.string, x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    static func cloudNavigationText(in image: CGImage) throws -> [TextLine] {
        let whole = try text(in: image)
        let state = CloudLaunchPolicy.state(whole)
        guard [.unknown, .prince, .princeGreeting, .princeDialogue].contains(state) else { return whole }
        let choices = try princeDialogue(in: image)
        if CloudLaunchPolicy.state(choices) == .princeDialogue { return choices }
        if state == .unknown {
            let prompt = try princePrompt(in: image)
            if CloudLaunchPolicy.state(prompt) == .prince { return prompt }
            return whole + prompt
        }
        return whole
    }

    /// Re-read the choice column separately so icons and background do not hide the replay label.
    static func princeDialogue(in image: CGImage) throws -> [TextLine] {
        let width = Double(image.width), height = Double(image.height)
        let crop = CGRect(x: width * 0.42, y: height * 0.20, width: width * 0.57, height: height * 0.66).integral
        guard let focused = image.cropping(to: crop),
              let context = CGContext(data: nil, width: focused.width * 2, height: focused.height * 2,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        context.interpolationQuality = .high
        context.draw(focused, in: CGRect(x: 0, y: 0, width: focused.width * 2, height: focused.height * 2))
        guard let enlarged = context.makeImage() else { return [] }
        return try text(in: enlarged).map {
            TextLine(text: $0.text, x: (crop.minX + $0.x * crop.width) / width,
                     y: (crop.minY + $0.y * crop.height) / height,
                     width: $0.width * crop.width / width, height: $0.height * crop.height / height)
        }
    }

    /// A second, smaller OCR pass keeps the small keycap legible on full Safari captures.
    static func princePrompt(in image: CGImage) throws -> [TextLine] {
        let width = Double(image.width), height = Double(image.height)
        let crop = CGRect(x: width * 0.35, y: height * 0.3, width: width * 0.6, height: height * 0.55).integral
        guard let focused = image.cropping(to: crop) else { return [] }
        var result = try text(in: focused).map {
            TextLine(text: $0.text, x: (crop.minX + $0.x * crop.width) / width,
                     y: (crop.minY + $0.y * crop.height) / height,
                     width: $0.width * crop.width / width, height: $0.height * crop.height / height)
        }
        if CloudLaunchPolicy.state(result) == .prince { return result }
        let names = result.filter {
            String($0.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }) == "小王子" &&
            $0.x > 0.45 && $0.y > 0.3 && $0.y < 0.85
        }
        for name in names.prefix(3) {
            // A full-window OCR pass ignores the isolated small F. The real Mini
            // fixture recognizes it after magnifying this name-anchored strip.
            let font = name.height * height
            guard font >= 5, font <= 100 else { continue }
            let strip = CGRect(x: name.x * width - font * 6, y: name.y * height - font * 0.8,
                               width: font * 6, height: font * 2.6).integral
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !strip.isEmpty, let small = image.cropping(to: strip),
                  let context = CGContext(data: nil, width: small.width * 4, height: small.height * 4,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.interpolationQuality = .high
            context.draw(small, in: CGRect(x: 0, y: 0, width: small.width * 4, height: small.height * 4))
            guard let enlarged = context.makeImage() else { continue }
            for key in try text(in: enlarged, keycap: true) where key.text.trimmingCharacters(in: .whitespacesAndNewlines) == "F" {
                result.append(TextLine(text: "F", x: (strip.minX + key.x * strip.width) / width,
                                       y: (strip.minY + key.y * strip.height) / height,
                                       width: key.width * strip.width / width, height: key.height * strip.height / height))
            }
        }
        return result
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw RecorderError.message("无法创建截图文件。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RecorderError.message("无法保存截图。") }
    }

    static func scan(image: CGImage, resources: URL) throws -> [Replay] {
        let lines = try text(in: image)
        let data = try imageWorker(image: image, lines: lines, resources: resources, controls: false)
        return try JSONDecoder().decode([Replay].self, from: data)
    }

    static func speed(image: CGImage, resources: URL) throws -> ReplaySpeedControl? {
        let data = try imageWorker(image: image, lines: [], resources: resources, controls: true)
        return try JSONDecoder().decode(ReplaySpeedControl?.self, from: data) ?? ReplayControls.speed(in: text(in: image))
    }

    static func playback(image: CGImage, resources: URL) throws -> ReplayPlaybackControls {
        let data = try imageWorker(image: image, lines: [], resources: resources, controls: true, playback: true)
        return try JSONDecoder().decode(ReplayPlaybackControls.self, from: data)
    }

    static func updateAssets(resources: URL) throws -> AssetUpdate {
        try JSONDecoder().decode(AssetUpdate.self, from: runWorker(arguments: ["--update-assets"], resources: resources, timeout: 180))
    }

    static func review(video: URL, resources: URL) throws -> VideoReview {
        return try JSONDecoder().decode(VideoReview.self, from: runWorker(arguments: [
            "--review-video", video.path,
            "--review-metadata", video.deletingPathExtension().appendingPathExtension("json").path,
            "--review-output", VideoReview.directory(video).path
        ], resources: resources, timeout: 900, reviewing: true))
    }

    private static func imageWorker(image: CGImage, lines: [TextLine], resources: URL, controls: Bool, playback: Bool = false) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Qisheng-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let screenshot = directory.appendingPathComponent("frame.png")
        let ocr = directory.appendingPathComponent("ocr.json")
        try savePNG(image, to: screenshot)
        try JSONEncoder().encode(lines).write(to: ocr)
        return try runWorker(arguments: ["--image", screenshot.path] + (playback ? ["--playback-controls"] : controls ? ["--controls"] : ["--ocr", ocr.path]),
                             resources: resources, timeout: controls ? 15 : 90)
    }

    private static func runWorker(arguments: [String], resources: URL, timeout: Double, reviewing: Bool = false) throws -> Data {
        let workers = reviewing ? reviewWorkers : workers
        let worker = resources.appendingPathComponent("portrait-worker/portrait-worker")
        guard FileManager.default.isExecutableFile(atPath: worker.path) else {
            throw RecorderError.message("角色识别组件缺失，请使用完整的应用安装包。")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Qisheng-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = worker
        if reviewing { process.qualityOfService = .utility }
        process.arguments = arguments + ["--assets", resources.appendingPathComponent("Assets").path,
                                          "--extra-assets", Settings.directory.appendingPathComponent("Portraits").path]
        let output = Pipe()
        let errorFile = directory.appendingPathComponent("error.txt")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer { try? errorHandle.close() }
        process.standardOutput = output
        process.standardError = errorHandle
        try workers.run(process)
        defer { workers.remove(process) }
        // Kill a stalled worker so a failed scan never freezes the application.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            throw RecorderError.message("识别组件执行失败：\((try? String(contentsOf: errorFile, encoding: .utf8)) ?? "未知错误")")
        }
        return data
    }
}

struct AssetUpdate: Decodable {
    let total: Int
    let added: [String]
    let failed: [String]
    let checkedAt: String
    let catalogVersion: String?
    let libraryVersion: String?
    let lastSuccessAt: String?
    let missing: [String]?
    let error: String?
}

private final class WorkerProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var cancelled = false
    func reset() { lock.lock(); defer { lock.unlock() }; cancelled = false }
    func run(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        current = process
    }
    func remove(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if current === process { current = nil }
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let current, current.isRunning { current.terminate() }
    }
}
