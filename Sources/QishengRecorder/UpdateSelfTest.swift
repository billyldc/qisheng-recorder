import AppKit

@MainActor
func runUpdateSelfTest() {
    Task {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qisheng-update-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            guard AppUpdater.repositoryIsValid(AppUpdater.repository),
                  AppUpdater.repositoryIsValid("example/recorder"),
                  !AppUpdater.repositoryIsValid(""),
                  !AppUpdater.repositoryIsValid("../recorder"),
                  !AppUpdater.repositoryIsValid("example/recorder?token=value") else {
                throw RecorderError.message("Invalid distribution repository configuration")
            }
            try checkReleaseNotesRendering()
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            func fixture(_ name: String, _ version: String, identifier: String = AppUpdater.identifier) async throws -> URL {
                let url = root.appendingPathComponent(name + ".app")
                try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: url.appendingPathComponent("Contents/MacOS/Test"))
                let info = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                            "CFBundleExecutable": "Test", "CFBundlePackageType": "APPL"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: url.appendingPathComponent("Contents/Info.plist"))
                _ = try await AppUpdater.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path], timeout: 20)
                return url
            }
            let old = try await fixture("old", "1.1.3")
            let new = try await fixture("new", "1.2.0")
            try AppUpdater.validateCandidate(new, against: old)
            func rejected(_ candidate: URL, against installed: URL) throws {
                do { try AppUpdater.validateCandidate(candidate, against: installed) }
                catch { return }
                throw RecorderError.message("Invalid update accepted")
            }
            try rejected(old, against: new)
            try rejected(new, against: new)
            let foreign = try await fixture("foreign", "1.3.0", identifier: "test.foreign.app")
            try rejected(foreign, against: old)
            try Data("tampered".utf8).write(to: new.appendingPathComponent("Contents/MacOS/Test"))
            try rejected(new, against: old)
            let sample = root.appendingPathComponent("sample")
            try Data("abc".utf8).write(to: sample)
            guard try AppUpdater.sha256(sample) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else {
                throw RecorderError.message("SHA-256 failed")
            }
            do { try AppUpdater.validateInstallLocation(root); throw RecorderError.message("Invalid location accepted") }
            catch let error as RecorderError {
                if error.localizedDescription == "Invalid location accepted" { throw error }
            }
            let task = Task { try await AppUpdater.run("/bin/sleep", ["30"], timeout: 60) }
            try await Task.sleep(for: .milliseconds(100))
            task.cancel()
            do { _ = try await task.value; throw RecorderError.message("Cancelled process continued") }
            catch is CancellationError { }
            // Exercise the real NSApplication delegate while busy, not only
            // signature/hash helpers. A blocked terminate() must time out here.
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            _ = try await AppUpdater.run(executable.path, ["--update-exit-self-test"], timeout: 8)
            print("PASS: signed update validation, downgrade/same-version/foreign/tamper rejection, SHA-256, install location, subprocess cancellation, busy installer handoff exits")
            NSApp.terminate(nil)
        } catch { fputs("Update self-test failed: \(error)\n", stderr); exit(1) }
    }
}
