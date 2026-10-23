import AppKit
import CryptoKit
import Security
import ReplayCore

private struct GitHubRelease: Decodable {
    struct Asset: Decodable { let name: String; let digest: String? }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let body: String?
    let assets: [Asset]
}

@MainActor
final class AppUpdater: ObservableObject {
    nonisolated static var repository: String {
        Bundle.main.object(forInfoDictionaryKey: "QishengUpdateRepository") as? String ?? ""
    }
    nonisolated static let identifier = "io.github.billyldc.QishengRecorder"
    @Published private(set) var working = false
    private(set) var installerLaunched = false
    private var job: Task<Void, Never>?

    func cancel() { if !installerLaunched { job?.cancel() } }

    func terminateForInstaller() {
        // terminate() can enter a nested AppKit loop. The delegate must not wait
        // for the update task containing this call to return and clear busy.
        installerLaunched = true
        NSApp.terminate(nil)
    }

    func checkAndOffer() async {
        guard !working else { return }
        working = true
        let task = Task { await self.performUpdate() }
        job = task
        await task.value
        job = nil; working = false
    }

    private func performUpdate() async {
        var stage: URL?
        var installing = false
        defer { if !installing, let stage { try? FileManager.default.removeItem(at: stage) } }
        do {
            guard Self.repositoryIsValid(Self.repository) else {
                throw RecorderError.message("安装包缺少有效的更新仓库配置，请从项目页面获取完整安装包。")
            }
            guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw RecorderError.message("私有仓库更新需要 GitHub CLI。请先安装并登录 GitHub CLI；也可从私有仓库 Releases 下载更新。")
            }
            let bytes = try await Self.run(gh, ["api", "--hostname", "github.com", "repos/\(Self.repository)/releases?per_page=30"], timeout: 40)
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: bytes)
            let currentBundle = Bundle.main.bundleURL
            guard let current = AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") else {
                throw RecorderError.message("当前版本号无效，请使用完整安装包。")
            }
            let available = releases.filter { !$0.draft && !$0.prerelease && AppVersion($0.tag_name).map { $0 > current } == true }
                .sorted { AppVersion($0.tag_name)! > AppVersion($1.tag_name)! }
            guard let release = available.first else { Self.notice("已是最新正式版", "当前版本没有可用的更新。"); return }
            #if arch(arm64)
            let arch = "arm64"
            #else
            let arch = "x86_64"
            #endif
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let archiveName = "Qisheng-Recorder-\(version)-macOS-\(arch).zip"
            guard let asset = release.assets.first(where: { $0.name == archiveName }),
                  let digest = asset.digest, UpdatePolicy.validDigest(digest) else {
                throw RecorderError.message("新版缺少适合本机的安装包或 GitHub SHA-256 校验值，未安装。")
            }
            try Self.validateInstallLocation(currentBundle)
            let alert = ReleaseNotesPresentation.alert(version: release.tag_name, body: release.body)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try Task.checkCancellation()
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QishengRecorder/Updates/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            stage = directory
            _ = try await Self.run(gh, ["release", "download", release.tag_name, "--repo", Self.repository,
                                       "--pattern", archiveName, "--dir", directory.path], timeout: 600)
            let archive = directory.appendingPathComponent(archiveName)
            let hash = try await Task.detached { try Self.sha256(archive) }.value
            try Task.checkCancellation()
            guard "sha256:" + hash == digest else { throw RecorderError.message("下载文件校验失败，未安装。") }
            let expanded = directory.appendingPathComponent("expanded")
            _ = try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path], timeout: 120)
            let candidate = expanded.appendingPathComponent("Qisheng Recorder.app")
            try Self.validateCandidate(candidate, against: currentBundle)
            guard Bundle(url: candidate)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version else {
                throw RecorderError.message("安装包版本与发布版本不一致，未安装。")
            }
            try Task.checkCancellation()
            let helper = Process()
            helper.executableURL = candidate.appendingPathComponent("Contents/MacOS/QishengRecorder")
            helper.arguments = ["--install-update", currentBundle.path, String(getpid())]
            try helper.run()
            installing = true
            terminateForInstaller()
        } catch is CancellationError {
        } catch {
            Self.notice("未能更新", error.localizedDescription + "\n\n私有仓库需要本机 GitHub CLI 已登录且有访问权限；旧版应用没有被删除。")
        }
    }

    nonisolated static func repositoryIsValid(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.allSatisfy {
                $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0))
            }
        }
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ executable: String, _ arguments: [String], timeout: Double) async throws -> Data {
        try Task.checkCancellation()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let output = temp.appendingPathComponent("stdout"), errors = temp.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GH_PROMPT_DISABLED"] = "1"; environment["GH_HOST"] = "github.com"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out; process.standardError = err
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(100))
                if ProcessInfo.processInfo.systemUptime > deadline { throw RecorderError.message("更新操作超时，可稍后重试。") }
            }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            // Reap the process before deleting its output files.
            for _ in 0..<20 where process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationStatus == 0 else { throw RecorderError.message("更新工具执行失败。请确认网络、GitHub 登录和安装目录写入权限。") }
        return try Data(contentsOf: output)
    }

    nonisolated static func validateInstallLocation(_ url: URL) throws {
        let allowed = [URL(fileURLWithPath: "/Applications/Qisheng Recorder.app"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Qisheng Recorder.app")]
        guard allowed.contains(url.standardizedFileURL), url.resolvingSymlinksInPath() == url.standardizedFileURL,
              FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw RecorderError.message("请将应用安装在可写的 /Applications 或 ~/Applications 后更新；不从下载目录或磁盘映像直接替换。")
        }
    }

    nonisolated static func validateCandidate(_ candidate: URL, against installed: URL) throws {
        guard candidate.resolvingSymlinksInPath() == candidate.standardizedFileURL,
              let newBundle = Bundle(url: candidate), let oldBundle = Bundle(url: installed),
              newBundle.bundleIdentifier == identifier, oldBundle.bundleIdentifier == identifier,
              let oldVersion = AppVersion(oldBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
              let newVersion = AppVersion(newBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""),
              newVersion > oldVersion else { throw RecorderError.message("更新包身份或版本检查失败，未安装。") }
        var oldCode: SecStaticCode?, newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(installed as CFURL, [], &oldCode) == errSecSuccess,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &newCode) == errSecSuccess,
              let oldCode, let newCode,
              SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), nil) == errSecSuccess else {
            throw RecorderError.message("更新包代码签名损坏，未安装。")
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(oldCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else {
            throw RecorderError.message("无法读取已安装应用的签名身份。")
        }
        // Ad hoc builds rely on authenticated GitHub download + digest; certificate
        // builds additionally require the new version to satisfy the existing DR.
        if flags & 2 == 0 {
            var requirement: SecRequirement?
            guard SecCodeCopyDesignatedRequirement(oldCode, [], &requirement) == errSecSuccess, let requirement,
                  SecStaticCodeCheckValidity(newCode, [], requirement) == errSecSuccess else {
                throw RecorderError.message("新版签名身份与已安装版本不一致，未安装。")
            }
        }
    }

    static func runInstaller() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--install-update"), args.count == index + 3,
              let pid = Int32(args[index + 2]), pid > 1 else { exit(2) }
        let destination = URL(fileURLWithPath: args[index + 1])
        let candidate = Bundle.main.bundleURL
        Task {
            do {
                try validateInstallLocation(destination)
                try validateCandidate(candidate, against: destination)
                try await waitForOldApplication(pid: pid, destination: destination)
                let fm = FileManager.default
                let backup = destination.deletingLastPathComponent().appendingPathComponent(".QishengRecorder-backup-\(UUID().uuidString)")
                let staged = destination.deletingLastPathComponent().appendingPathComponent(".QishengRecorder-update-\(UUID().uuidString).app")
                try fm.copyItem(at: candidate, to: staged)
                try validateCandidate(staged, against: destination)
                try fm.moveItem(at: destination, to: backup)
                do { try fm.moveItem(at: staged, to: destination) }
                catch { try fm.moveItem(at: backup, to: destination); throw error }
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    _ = try await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                } catch {
                    try fm.moveItem(at: destination, to: staged)
                    try fm.moveItem(at: backup, to: destination)
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    _ = try? await NSWorkspace.shared.openApplication(at: destination, configuration: configuration)
                    throw error
                }
                NSApp.terminate(nil)
            } catch is CancellationError { NSApp.terminate(nil) }
            catch { notice("更新未完成", error.localizedDescription); NSApp.terminate(nil) }
        }
    }

    static func waitForOldApplication(pid: Int32, destination: URL) async throws {
        guard let old = NSRunningApplication(processIdentifier: pid), !old.isTerminated else {
            guard kill(pid, 0) != 0 && errno == ESRCH else {
                throw RecorderError.message("无法确认旧版进程身份，未安装。")
            }
            return
        }
        guard old.bundleIdentifier == identifier,
              old.bundleURL?.standardizedFileURL == destination.standardizedFileURL else {
            throw RecorderError.message("旧版进程与安装位置不符，未安装。")
        }
        let version = Bundle(url: destination)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        // Recovery is offered only to the installer explicitly launched by a
        // known affected parent. Never force-quit an arbitrary PID or app copy.
        let legacy = UpdatePolicy.canOfferLegacyExitRecovery(version: version, launchedByOldApp: getppid() == pid)
        let deadline = ProcessInfo.processInfo.systemUptime + (legacy ? 10 : 60)
        while !old.isTerminated && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if !old.isTerminated && legacy {
            let alert = NSAlert()
            alert.messageText = "旧版卡在更新退出流程"
            alert.informativeText = "此版本存在已知的退出等待问题。确认当前没有正在录制或保存的视频后，可关闭旧版并继续安装。旧版应用保留为备份，录像与权限设置不变。"
            alert.addButton(withTitle: "取消安装")
            alert.addButton(withTitle: "关闭旧版并继续")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { throw CancellationError() }
            if !old.isTerminated {
                guard old.forceTerminate() else { throw RecorderError.message("未能关闭旧版，未安装。") }
                for _ in 0..<50 where !old.isTerminated { try await Task.sleep(for: .milliseconds(200)) }
            }
        }
        guard old.isTerminated else { throw RecorderError.message("旧版未退出，未替换任何文件。请退出旧版后重试。") }
    }

    static func notice(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: "确定"); alert.runModal()
    }
}
