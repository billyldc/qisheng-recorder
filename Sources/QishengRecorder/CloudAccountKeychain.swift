import Foundation
import Security

struct CloudCredentials: Codable, Equatable {
    let account: String
    let password: String
}

@MainActor
final class CloudCredentialSession {
    private var values: [String: CloudCredentials] = [:]

    func load(service: String, read: () throws -> CloudCredentials?) rethrows -> CloudCredentials? {
        if let saved = values[service] { return saved }
        let credentials = try read()
        if let credentials { values[service] = credentials }
        return credentials
    }

    func saved(_ credentials: CloudCredentials, service: String) { values[service] = credentials }
    func invalidate(service: String) { values.removeValue(forKey: service) }
    func clear() { values.removeAll() }
}

@MainActor
enum CloudAccountKeychain {
    nonisolated static let service = "io.github.billyldc.QishengRecorder.cloud-login"
    private static let session = CloudCredentialSession()
    private static let lockObserver = SecKeychainAddCallback({ _, _, _ in
        Task { @MainActor in CloudAccountKeychain.clearSession() }
        return errSecSuccess
    }, .lockEventMask, nil)

    static func clearSession() { session.clear() }
    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "primary",
         kSecAttrSynchronizable as String: false]
    }

    static func configured(service: String = service) -> Bool {
        var request = query(service)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static func load(service: String = service) throws -> CloudCredentials? {
        guard lockObserver == errSecSuccess else { return try read(service: service) }
        return try session.load(service: service) { try read(service: service) }
    }

    private static func read(service: String) throws -> CloudCredentials? {
        var request = query(service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        guard let credentials = try? JSONDecoder().decode(CloudCredentials.self, from: data) else {
            throw RecorderError.message("钥匙串中的账号记录无法读取，请重新配置。")
        }
        return credentials
    }

    static func save(_ credentials: CloudCredentials, service: String = service) throws {
        guard !credentials.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !credentials.password.isEmpty else {
            throw RecorderError.message("请输入账号和密码。")
        }
        let data = try JSONEncoder().encode(credentials)
        session.invalidate(service: service)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query(service) as CFDictionary, update)
        if status == errSecItemNotFound {
            // Only this app is trusted; macOS can add a per-build partition check.
            var app: SecTrustedApplication?
            status = SecTrustedApplicationCreateFromPath(nil, &app)
            guard status == errSecSuccess, let app else { throw failure(status) }
            var access: SecAccess?
            status = SecAccessCreate("七圣召唤录制器 · 云原神登录" as CFString, [app] as CFArray, &access)
            guard status == errSecSuccess, let access else { throw failure(status) }
            var item = query(service)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "七圣召唤录制器 · 云原神登录"
            item[kSecAttrAccess as String] = access
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
        if lockObserver == errSecSuccess { session.saved(credentials, service: service) }
    }

    static func remove(service: String = service) throws {
        session.invalidate(service: service)
        let status = SecItemDelete(query(service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> RecorderError {
        if status == errSecUserCanceled {
            return .message("已取消钥匙串访问，未继续登录，也不会自动重试。下次需要时请再次点击；系统询问时可输入钥匙串密码并选择「始终允许」。")
        }
        return RecorderError.message("无法访问登录钥匙串（\(status)）。请解锁钥匙串并允许录制器访问后重试。")
    }
}
