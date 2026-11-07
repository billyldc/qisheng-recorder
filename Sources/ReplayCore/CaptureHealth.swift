import Foundation

public struct CaptureLifecycle {
    private enum Phase { case idle, capturing, finalizing, finished }
    private var phase: Phase = .idle
    public init() {}
    public var stoppingIntentionally: Bool { phase == .finalizing || phase == .finished }
    public mutating func beginCapture() { phase = .capturing }
    public mutating func captureFailedToStart() { phase = .idle }
    public mutating func beginFinalization() { phase = .finalizing }
    public mutating func finishFinalization() { phase = .finished }
}

/// A start callback is not proof that frames and encoded output keep arriving.
public struct CaptureHealth {
    public enum Frame { case complete, idle, unavailable }
    private let start: Double
    private var lastCallback: Double
    private var unavailableSince: Double?
    private var lastWrite: Double
    private var duration = 0.0
    private var bytes = 0
    public private(set) var hasFrame = false
    public var hasWrittenMedia: Bool { hasFrame && duration > 0 && bytes > 0 }

    public init(at now: Double) { start = now; lastCallback = now; lastWrite = now }

    public mutating func frame(_ frame: Frame, at now: Double) {
        lastCallback = now
        switch frame {
        case .complete: hasFrame = true; unavailableSince = nil
        case .unavailable: if unavailableSince == nil { unavailableSince = now }
        case .idle: break // An idle notification does not recover a blank/suspended stream.
        }
    }

    public mutating func written(duration: Double, bytes: Int, at now: Double) {
        if duration.isFinite && duration > self.duration {
            self.duration = duration
            lastWrite = now
        }
        self.bytes = max(self.bytes, bytes)
    }

    public func failure(at now: Double) -> String? {
        if let unavailableSince, now - unavailableSince >= 12 {
            return "捕获画面持续空白或暂停，已停止并保留片段。请检查录制电脑的屏幕、窗口和登录会话。"
        }
        if now - lastCallback >= 30 {
            return "超过 30 秒没有收到捕获回调，已停止并保留片段；最后一帧为空闲状态也不会继续假录制。"
        }
        if !hasWrittenMedia && now - start >= 15 {
            return "未收到有效画面和视频写入进度，录制没有成功开始。请检查录制电脑的屏幕与权限。"
        }
        if now - lastWrite >= 30 {
            return "视频写入进度超过 30 秒未推进，已停止并保留片段，不计为完成。"
        }
        return nil
    }
}

public struct ReplayProgressHealth {
    private var previous: [UInt8]?
    private var changedAt: Double?
    private var pausedAt: Double?
    public init() {}

    public mutating func observe(pixels: [UInt8], playback: ReplayPlaybackControl.State?,
                                 ending: Bool, at now: Double) -> String? {
        if ending { changedAt = now; pausedAt = nil; previous = pixels; return nil }
        if playback == .paused {
            if pausedAt == nil { pausedAt = now }
        } else if playback == .running { pausedAt = nil }
        if let pausedAt, now - pausedAt >= 45 {
            return "回放持续暂停，自动继续未能生效；片段已保留，不计为完整对局。"
        }
        guard !pixels.isEmpty else { return nil }
        if let previous, previous.count == pixels.count {
            let difference = zip(previous, pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
            if Double(difference) / Double(pixels.count) >= 3 { changedAt = now; self.previous = pixels }
        } else { changedAt = now; previous = pixels }
        if let changedAt, now - changedAt >= 90 {
            return "牌桌画面超过 90 秒没有明显变化，可能已断流或卡住；片段已保留，请检查后重试。"
        }
        return nil
    }
}
