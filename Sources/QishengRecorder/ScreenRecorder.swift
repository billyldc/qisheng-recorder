import AppKit
import AVFoundation
import ScreenCaptureKit
import ReplayCore

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@MainActor
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var finished = false
    private var started = false
    private var lifecycle = CaptureLifecycle()
    private var failure: Error?
    private var health = CaptureHealth(at: 0)
    private var pendingCrop: (url: URL, normalized: CGRect)?
    var isRecording: Bool { stream != nil }

    private func context(region: CaptureRegion, audio: Bool) async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.message("选中的显示器已经断开，请重新选框。")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        if let windowID = region.windowID {
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecorderError.message("目标窗口已关闭，请重新选择窗口。")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.ignoreShadowsSingleWindow = true
            config.includeChildWindows = false
        } else {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config.sourceRect = region.sourceRect
        }
        // Independent-window streams ignore sourceRect on supported macOS versions.
        // Keep the full capture and crop its screenshots/export explicitly.
        let captureRect = region.windowID != nil ? CGRect(origin: .zero, size: region.anchorFrame!.size) : region.sourceRect
        let size = RegionGeometry.outputSize(rect: captureRect, scale: region.scale)
        config.width = Int(size.width)
        config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.capturesAudio = audio
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = false
        config.queueDepth = 5
        return (filter, config)
    }

    func screenshot(region: CaptureRegion) async throws -> CGImage {
        let (filter, config) = try await context(region: region, audio: false)
        let size = region.windowID != nil ? region.anchorFrame!.size : region.sourceRect.size
        config.width = Int(size.width * region.scale)
        config.height = Int(size.height * region.scale)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let crop = region.windowCrop else { return image }
        let pixels = GameViewport.pointRect(pixelRect: crop, imageSize: size,
                                           source: CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard let cropped = image.cropping(to: pixels) else { throw RecorderError.message("无法截取已确认的游戏区域。") }
        return cropped
    }

    func start(region: CaptureRegion, url: URL, audio: Bool) async throws {
        guard stream == nil else { throw RecorderError.message("已有录制正在进行。") }
        let (filter, config) = try await context(region: region, audio: audio)
        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: self)
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        finished = false; started = false; failure = nil
        pendingCrop = nil
        if let crop = region.windowCrop, let frame = region.anchorFrame {
            pendingCrop = (url, CGRect(x: crop.minX / frame.width, y: crop.minY / frame.height,
                                      width: crop.width / frame.width, height: crop.height / frame.height))
        }
        health = CaptureHealth(at: ProcessInfo.processInfo.systemUptime)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try capture.addRecordingOutput(recording)
        stream = capture; output = recording
        lifecycle.beginCapture()
        do {
            try await capture.startCapture()
            for _ in 0..<150 {
                if let failure { throw failure }
                try checkFailure()
                if started && health.hasWrittenMedia { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RecorderError.message("录制未能开始。请检查屏幕录制权限后重新打开应用。")
        } catch {
            try? await capture.stopCapture()
            stream = nil; output = nil
            lifecycle.captureFailedToStart()
            throw error
        }
    }

    func stop() async throws {
        // A cancelled automation task must still allow real time for MP4 finalization.
        lifecycle.beginFinalization()
        try await Task { @MainActor in
            defer { self.lifecycle.finishFinalization() }
            try await self.finalize()
            if let pending = self.pendingCrop {
                self.pendingCrop = nil
                if FileManager.default.fileExists(atPath: pending.url.path) {
                    try await GameVideoExport.cropPreservingOriginal(pending.url, normalized: pending.normalized)
                }
            }
        }.value
    }

    private func finalize() async throws {
        guard let capture = stream else { return }
        defer { stream = nil; output = nil }
        var stopError: Error?
        if !finished {
            do { try await capture.stopCapture() } catch { stopError = error }
        }
        for _ in 0..<150 {
            if finished {
                if let failure { throw failure }
                if let stopError { throw stopError }
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RecorderError.message("视频保存超时，请在输出目录检查文件。")
    }

    func checkFailure() throws {
        if lifecycle.stoppingIntentionally { return }
        guard stream != nil else { throw RecorderError.message("录制流已丢失，已停止自动操作。") }
        if let failure { throw failure }
        if finished && stream != nil {
            throw RecorderError.message("视频输出意外结束，已停止后续操作；当前片段不计为完成。")
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let output { health.written(duration: output.recordedDuration.seconds, bytes: output.recordedFileSize, at: now) }
        if let reason = health.failure(at: now) { throw RecorderError.message(reason) }
    }

    var diagnostic: String {
        let duration = output?.recordedDuration.seconds ?? 0
        return "有效画面=\(health.hasFrame)，写入=\(duration.isFinite ? Int(duration) : 0)秒/\(output?.recordedFileSize ?? 0)字节"
    }

    static func boardPixels(_ image: CGImage) -> [UInt8] {
        let rect = CGRect(x: Double(image.width) * 0.15, y: Double(image.height) * 0.25,
                          width: Double(image.width) * 0.65, height: Double(image.height) * 0.50)
        guard let board = image.cropping(to: rect),
              let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 64,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        context.draw(board, in: CGRect(x: 0, y: 0, width: 64, height: 36))
        guard let data = context.data else { return [] }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: 64 * 36))
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        Task { @MainActor in
            guard stream === self.stream else { return }
            let frame: CaptureHealth.Frame = status == .complete ? .complete :
                (status == .idle || status == .started ? .idle : .unavailable)
            self.health.frame(frame, at: ProcessInfo.processInfo.systemUptime)
        }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in if recordingOutput === self.output { self.started = true } }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in if recordingOutput === self.output { self.finished = true } }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in if recordingOutput === self.output { self.failure = error; self.finished = true } }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in if stream === self.stream { self.failure = error } }
    }
}
