import AppKit
import IOKit.pwr_mgt

@MainActor
final class RecordingSession {
    private var assertions: [IOPMAssertionID] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notifiedLocked = false
    private var inactive = false
    private var activity: NSObjectProtocol?
    private(set) var lastPowerEvent = "none"

    init() {
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.notifiedLocked = locked
                    if locked { CloudAccountKeychain.clearSession() }
                }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        for (name, inactive) in [(NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.inactive = inactive
                    if inactive { CloudAccountKeychain.clearSession() }
                }
            })
        }
        for (name, label) in [(NSWorkspace.willSleepNotification, "systemSleep"),
                              (NSWorkspace.didWakeNotification, "systemWake"),
                              (NSWorkspace.screensDidSleepNotification, "displaySleep"),
                              (NSWorkspace.screensDidWakeNotification, "displayWake")] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.lastPowerEvent = label
                    if label == "systemSleep" { CloudAccountKeychain.clearSession() }
                }
            })
        }
    }

    var unlocked: Bool {
        guard !notifiedLocked, !inactive, let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true else { return false }
        if session["CGSSessionScreenIsLocked"] as? Bool == true { return false }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
    }

    func begin() throws {
        end()
        guard unlocked else { throw RecorderError.message("录制电脑的桌面未解锁。请先解锁并显示游戏窗口，再开始录制。") }
        lastPowerEvent = "sessionStarted"
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                         reason: "正在录制游戏或保持云游戏在线")
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "七圣召唤录制进行中" as CFString, &id)
            guard result == kIOReturnSuccess else { end(); throw RecorderError.message("无法申请录制期间的防睡眠保护。") }
            assertions.append(id)
        }
    }

    func checkProtection() throws {
        guard activity != nil, assertions.count == 2, assertions.allSatisfy({ id in
            guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else { return false }
            return (properties[kIOPMAssertionLevelKey] as? NSNumber)?.intValue == Int(kIOPMAssertionLevelOn)
        }) else { throw RecorderError.message("录制电脑的临时防休眠保护已失效，已停止并保留片段。") }
    }

    func diagnostic(displayID: UInt32?) -> String {
        let values = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
        return "解锁=\(unlocked)，控制台=\(values[kCGSessionOnConsoleKey as String] as? Bool ?? false)，会话活跃=\(!inactive)，最近电源事件=\(lastPowerEvent)，显示器休眠=\(displayID.map { CGDisplayIsAsleep($0) != 0 } ?? false)，防休眠断言=\(assertions.count)"
    }
    func end() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}
