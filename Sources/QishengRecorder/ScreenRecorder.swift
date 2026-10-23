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
    private var failure: Error?
    private var lastFrameAt: Date?
    private var unavailableSince: Date?
    private var idleFrame = false
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
        let size = RegionGeometry.outputSize(rect: region.sourceRect, scale: region.scale)
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
        // Keep the original selected rectangle. The final recording uses the same rectangle.
        config.width = Int(region.sourceRect.width * region.scale)
        config.height = Int(region.sourceRect.height * region.scale)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
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
        lastFrameAt = Date(); unavailableSince = nil; idleFrame = false
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        try capture.addRecordingOutput(recording)
        stream = capture; output = recording
        do {
            try await capture.startCapture()
            for _ in 0..<100 {
                if let failure { throw failure }
                if started { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw RecorderError.message("录制未能开始。请检查屏幕录制权限后重新打开应用。")
        } catch {
            try? await capture.stopCapture()
            stream = nil; output = nil
            throw error
        }
    }

    func stop() async throws {
        // A cancelled automation task must still allow real time for MP4 finalization.
        try await Task { @MainActor in try await self.finalize() }.value
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
        if let failure { throw failure }
        if let unavailableSince, Date().timeIntervalSince(unavailableSince) >= 8 {
            throw RecorderError.message("捕获画面已暂停或变为空白。请还原目标窗口并检查桌面是否解锁；当前片段已保存。")
        }
        if !idleFrame, let lastFrameAt, Date().timeIntervalSince(lastFrameAt) > 30 {
            throw RecorderError.message("超过 30 秒没有收到捕获帧，已保存当前片段。请检查窗口及远程会话。")
        }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return }
        Task { @MainActor in
            guard stream === self.stream else { return }
            self.lastFrameAt = Date()
            self.idleFrame = status == .idle
            if status == .blank || status == .suspended || status == .stopped {
                if self.unavailableSince == nil { self.unavailableSince = Date() }
            } else { self.unavailableSince = nil }
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
