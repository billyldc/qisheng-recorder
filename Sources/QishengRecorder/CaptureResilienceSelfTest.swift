import AppKit
import ApplicationServices
import AVFoundation
import CoreImage
import ReplayCore

@MainActor
private final class CapturePatternView: NSView {
    var tick = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.08, green: 0.24, blue: 0.55, alpha: 1).setFill()
        bounds.fill()
        NSColor(srgbRed: 0.12, green: 0.62, blue: 0.38, alpha: 1).setFill()
        CGRect(x: bounds.width * 0.6, y: 0, width: bounds.width * 0.2, height: bounds.height).fill()
        ("Qisheng capture test" as NSString).draw(at: CGPoint(x: 20, y: 70), withAttributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.white
        ])
        NSColor.white.setFill()
        CGRect(x: 20, y: 20, width: CGFloat(20 + tick % 300), height: 20).fill()
    }
}

private func rightPixels(_ image: CGImage) throws -> [UInt8] {
    guard let crop = image.cropping(to: CGRect(x: Double(image.width) * 0.55, y: 0,
                                              width: Double(image.width) * 0.4, height: Double(image.height))),
          let context = CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 48,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
        throw RecorderError.message("Synthetic capture pixels unavailable")
    }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 48, height: 48))
    guard let bytes = context.data else { throw RecorderError.message("Synthetic image has no bytes") }
    return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: 48 * 48))
}

private func validateSyntheticVideo(_ url: URL) async throws -> (frames: Int, duration: Double, maxGap: Double, maxPixelDifference: Double) {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw RecorderError.message("Synthetic recording has no video")
    }
    let duration = try await asset.load(.duration).seconds
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? RecorderError.message("Reader did not start") }
    var frames = 0, previous = -Double.infinity, firstTime: Double?, maxGap = 0.0, maxDifference = 0.0
    var expectedPixels: [UInt8]?
    let context = CIContext(options: [.cacheIntermediates: false])
    while let sample = output.copyNextSampleBuffer() {
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        guard time.isFinite, time >= previous, let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw RecorderError.message("Invalid decoded synthetic frame")
        }
        if firstTime == nil { firstTime = time }
        let source = CIImage(cvPixelBuffer: buffer)
        guard let image = context.createCGImage(source, from: source.extent) else {
            throw RecorderError.message("Decoded frame has no pixels")
        }
        let pixels = try rightPixels(image)
        // Compare in the decoded stream's color space, not screenshot RGB vs H.264 YUV.
        if expectedPixels == nil { expectedPixels = pixels }
        let difference = Double(zip(pixels, expectedPixels!).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(pixels.count)
        maxDifference = max(maxDifference, difference)
        guard difference < 5 else { throw RecorderError.message("Decoded video contains an unexpected occluding layer at \(time)s (difference \(difference))") }
        if previous.isFinite { maxGap = max(maxGap, time - previous) }
        previous = time; frames += 1
    }
    guard reader.status == .completed, frames >= 20, duration >= 5, maxGap < 1,
          let firstTime, firstTime < 1, duration - previous < 1 else {
        throw reader.error ?? RecorderError.message("Synthetic recording has a timeline gap")
    }
    return (frames, duration, maxGap, maxDifference)
}

@MainActor
func runCaptureResilienceSelfTest() {
    Task {
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
            print("SKIP: live capture needs existing screen/accessibility access; no permission was requested")
            exit(2)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("qisheng-capture-resilience-\(UUID().uuidString)")
        let recorder = ScreenRecorder()
        let backend = SystemRecordingFocus()
        let quiet = NotificationQuietSession(backend: backend, journal: directory.appendingPathComponent("focus.json"))
        let session = RecordingSession()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 160, width: 800, height: 450),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.hasShadow = false
        let pattern = CapturePatternView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        window.contentView = pattern
        let overlay = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false; overlay.hidesOnDeactivate = false
        overlay.level = .floating; overlay.hasShadow = false
        overlay.isOpaque = true; overlay.backgroundColor = .white
        let previousApp = NSWorkspace.shared.frontmostApplication
        let explicitPID = CommandLine.arguments.first(where: { $0.hasPrefix("--external-pid=") })
            .flatMap { Int32($0.dropFirst("--external-pid=".count)) }
        let externalApp = explicitPID.flatMap(NSRunningApplication.init(processIdentifier:)) ??
            (previousApp?.processIdentifier != getpid() ? previousApp : NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        var timer: Timer?
        var failure: Error?
        var report: [String: Any] = [:]
        var original: SystemFocusState?
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let path = ProcessInfo.processInfo.environment["QISHENG_FOCUS_RECOVERY_JOURNAL"] {
                let recovery = NotificationQuietSession(backend: backend, journal: URL(fileURLWithPath: path))
                guard recovery.canRecover else { throw RecorderError.message("Requested test recovery journal is unavailable") }
                print(await recovery.end(recoverPreviousSession: true) ?? "No recovery needed")
                guard !recovery.canRecover else { throw RecorderError.message("Previous test Focus restoration failed") }
            }
            original = try await backend.read()
            let message = await quiet.begin()
            let during = try await backend.read()
            let expected = SystemFocusState(activeID: SystemFocusState.doNotDisturb)
            print("Live quiet: \(message); state_matches_expected=\(during == expected)")
            guard during == expected, !message.hasPrefix("未能") else {
                throw RecorderError.message("Live quiet activation was not confirmed")
            }
            try session.begin()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak pattern] _ in
                Task { @MainActor in pattern?.tick += 8; pattern?.needsDisplay = true }
            }
            try await Task.sleep(for: .milliseconds(400))
            guard window.windowNumber > 0,
                  let target = CaptureWindow.list(pid: getpid()).first(where: { $0.id == UInt32(window.windowNumber) }) else {
                throw RecorderError.message("Synthetic window unavailable")
            }
            print("Synthetic capture window: \(target.frame)")
            let region = try target.region()
            let movie = directory.appendingPathComponent("occlusion-and-focus.mp4")
            try await recorder.start(region: region, url: movie, audio: false)
            try await Task.sleep(for: .seconds(2))
            let before = try rightPixels(await recorder.screenshot(region: region))
            let frame = window.frame
            overlay.setFrame(NSRect(x: frame.minX + frame.width * 0.55, y: frame.minY + frame.height * 0.55,
                                    width: frame.width * 0.45, height: frame.height * 0.45), display: false)
            overlay.orderFrontRegardless()
            try await Task.sleep(for: .seconds(1))
            externalApp?.activate(options: [])
            try await Task.sleep(for: .seconds(3))
            guard !NSRunningApplication.current.isActive, overlay.isVisible else {
                throw RecorderError.message("Synthetic focus-loss/occlusion precondition was not achieved")
            }
            try recorder.checkFailure()
            try session.checkProtection()
            let after = try rightPixels(await recorder.screenshot(region: region))
            let difference = Double(zip(before, after).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(before.count)
            guard difference < 3 else { throw RecorderError.message("Occluding window entered the independent capture") }
            try await recorder.stop()
            let decoded = try await validateSyntheticVideo(movie)
            report = ["frames": decoded.frames, "duration": decoded.duration, "maximum_frame_gap": decoded.maxGap,
                      "maximum_decoded_overlay_difference": decoded.maxPixelDifference,
                      "overlay_pixel_difference": difference, "captured_only_synthetic_window": true,
                      "focus_lost_without_stopping": true, "movie": movie.path]
        } catch { failure = error }
        timer?.invalidate()
        await Task { @MainActor in
            do { try await recorder.stop() } catch { if failure == nil { failure = error } }
            _ = await quiet.end()
            if quiet.canRecover { _ = await quiet.end(recoverPreviousSession: true) }
        }.value
        session.end()
        overlay.close(); window.close()
        if NSRunningApplication.current.isActive { externalApp?.activate(options: []) }
        if let original {
            do {
                guard try await backend.read() == original, !quiet.canRecover else {
                    throw RecorderError.message("Live focus restoration could not be confirmed; recovery journal retained")
                }
            } catch { if failure == nil { failure = error } }
        }
        if let failure {
            fputs("FAIL: \(failure.localizedDescription); diagnostics: \(directory.path)\n", stderr)
            exit(1)
        }
        report["focus_restored"] = true
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("result.json"))
            print(String(decoding: data, as: UTF8.self))
        }
        print("PASS: live synthetic recording survives focus loss and occlusion, all frames decoded, system focus restored; no game input")
        NSApp.terminate(nil)
    }
}
