import Foundation
import ReplayCore

enum CaptureMode: String, Codable, CaseIterable {
    case region, window
}

struct Settings: Codable {
    var outputDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/七圣召唤").path
    var targetBundleID = "com.google.Chrome"
    var captureDisplayID: UInt32?
    var systemAudio = true
    var speed2x = false
    var bothPerspectives = false
    var loadingSeconds = 12.0
    var maxSeconds = 1200.0
    var profiles: [String: Calibration] = [:]
    var captureMode = CaptureMode.region
    var unattended = false
    var showHUD = true
    var cloudKeepAlive = true
    var keepAliveSeconds = 60.0
    var legacyCalibrationBundleID: String?
    var autoReview = true
    var autoAssetUpdates = false
    var cloudAutoLogin = false
    var cloudAutoAcceptAgreements = false

    init() {}
    enum CodingKeys: String, CodingKey {
        case outputDirectory, targetBundleID, captureDisplayID, systemAudio, speed2x, bothPerspectives
        case loadingSeconds, maxSeconds, profiles, captureMode, unattended, showHUD, legacyCalibrationBundleID
        case cloudKeepAlive, keepAliveSeconds
        case autoReview, autoAssetUpdates
        case cloudAutoLogin, cloudAutoAcceptAgreements
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        outputDirectory = try values.decodeIfPresent(String.self, forKey: .outputDirectory) ?? outputDirectory
        targetBundleID = try values.decodeIfPresent(String.self, forKey: .targetBundleID) ?? targetBundleID
        captureDisplayID = try values.decodeIfPresent(UInt32.self, forKey: .captureDisplayID)
        systemAudio = try values.decodeIfPresent(Bool.self, forKey: .systemAudio) ?? systemAudio
        speed2x = try values.decodeIfPresent(Bool.self, forKey: .speed2x) ?? speed2x
        bothPerspectives = try values.decodeIfPresent(Bool.self, forKey: .bothPerspectives) ?? bothPerspectives
        loadingSeconds = try values.decodeIfPresent(Double.self, forKey: .loadingSeconds) ?? loadingSeconds
        maxSeconds = try values.decodeIfPresent(Double.self, forKey: .maxSeconds) ?? maxSeconds
        profiles = try values.decodeIfPresent([String: Calibration].self, forKey: .profiles) ?? profiles
        captureMode = try values.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? captureMode
        unattended = try values.decodeIfPresent(Bool.self, forKey: .unattended) ?? unattended
        showHUD = try values.decodeIfPresent(Bool.self, forKey: .showHUD) ?? showHUD
        cloudKeepAlive = try values.decodeIfPresent(Bool.self, forKey: .cloudKeepAlive) ?? cloudKeepAlive
        let interval = try values.decodeIfPresent(Double.self, forKey: .keepAliveSeconds) ?? keepAliveSeconds
        keepAliveSeconds = KeepAliveSchedule.allowedInterval.contains(interval) ? interval : 60
        legacyCalibrationBundleID = try values.decodeIfPresent(String.self, forKey: .legacyCalibrationBundleID) ?? targetBundleID
        autoReview = try values.decodeIfPresent(Bool.self, forKey: .autoReview) ?? autoReview
        autoAssetUpdates = try values.decodeIfPresent(Bool.self, forKey: .autoAssetUpdates) ?? autoAssetUpdates
        cloudAutoLogin = try values.decodeIfPresent(Bool.self, forKey: .cloudAutoLogin) ?? cloudAutoLogin
        cloudAutoAcceptAgreements = try values.decodeIfPresent(Bool.self, forKey: .cloudAutoAcceptAgreements) ?? cloudAutoAcceptAgreements
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QishengRecorder")
    }
    static func load() -> Settings {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("settings.json")),
              let result = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return result
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.directory.appendingPathComponent("settings.json"), options: .atomic) }
    }
}

struct Calibration: Codable {
    var speed: UnitPoint?
    var exit: UnitPoint?
    var label: String
}

struct RecordingEntry: Identifiable {
    var id = UUID()
    var url: URL
    var detail: String
}
