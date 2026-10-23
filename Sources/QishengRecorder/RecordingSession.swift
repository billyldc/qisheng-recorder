import AppKit
import IOKit.pwr_mgt

@MainActor
final class RecordingSession {
    private var assertions: [IOPMAssertionID] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var notifiedLocked = false
    private var inactive = false

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
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in CloudAccountKeychain.clearSession() }
        })
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
        guard unlocked else { throw RecorderError.message("Mini 的桌面未解锁。请先解锁并显示游戏窗口，再开始录制。") }
        for type in [kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionTypeNoIdleSleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "七圣召唤录制进行中" as CFString, &id)
            guard result == kIOReturnSuccess else { end(); throw RecorderError.message("无法申请录制期间的防睡眠保护。") }
            assertions.append(id)
        }
    }
    func end() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }
}
