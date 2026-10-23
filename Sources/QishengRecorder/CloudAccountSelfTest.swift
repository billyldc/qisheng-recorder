import AppKit

@MainActor
func runCloudAccountSelfTest() {
    let service = CloudAccountKeychain.service + ".test." + UUID().uuidString
    defer { try? CloudAccountKeychain.remove(service: service) }
    do {
        try checkCredentialSessionReuse()
        precondition(!CloudAccountKeychain.configured(service: service))
        let empty = try CloudAccountKeychain.load(service: service)
        precondition(empty == nil)
        let first = CloudCredentials(account: "fixture@example.invalid", password: "fixture-only ' \" \\ 中文\n")
        try CloudAccountKeychain.save(first, service: service)
        precondition(CloudAccountKeychain.configured(service: service))
        CloudAccountKeychain.clearSession()
        let loaded = try CloudAccountKeychain.load(service: service)
        precondition(loaded == first)
        let second = CloudCredentials(account: "second@example.invalid", password: "second-fixture-only")
        try CloudAccountKeychain.save(second, service: service)
        CloudAccountKeychain.clearSession()
        let updated = try CloudAccountKeychain.load(service: service)
        precondition(updated == second)
        try CloudAccountKeychain.remove(service: service)
        precondition(!CloudAccountKeychain.configured(service: service))
        let settings = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as! [String: Any]
        precondition(!settings.keys.contains("password") && !settings.keys.contains("account"))
        print("PASS: credential-session reuse/invalidation; isolated keychain save/load/update/delete; no credentials in Settings")
        NSApp.terminate(nil)
    } catch { fputs("Cloud account self-test failed: \(error.localizedDescription)\n", stderr); exit(1) }
}

@MainActor
func checkCredentialSessionReuse() throws {
    let session = CloudCredentialSession()
    let fixture = CloudCredentials(account: "fixture@example.invalid", password: "fixture-only")
    var reads = 0
    func read() -> CloudCredentials? { reads += 1; return fixture }
    for _ in 0..<5 {
        let loaded = session.load(service: "one", read: read)
        precondition(loaded == fixture)
    }
    precondition(reads == 1)
    session.invalidate(service: "one")
    _ = session.load(service: "one", read: read)
    precondition(reads == 2)
    session.saved(fixture, service: "two")
    _ = session.load(service: "two", read: read)
    precondition(reads == 2)
    session.clear()
    _ = session.load(service: "one", read: read)
    _ = session.load(service: "two", read: read)
    precondition(reads == 4)
    for _ in 0..<2 { _ = session.load(service: "missing") { reads += 1; return nil } }
    precondition(reads == 6)
    for _ in 0..<2 {
        do {
            _ = try session.load(service: "cancelled") { reads += 1; throw RecorderError.message("fixture cancellation") }
            preconditionFailure("Cancelled reads must throw")
        } catch {}
    }
    precondition(reads == 8)
}
