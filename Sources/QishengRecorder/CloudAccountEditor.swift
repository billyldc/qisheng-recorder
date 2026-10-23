import SwiftUI

struct CloudAccountEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var savedAccount: String?
    @State private var failure: String?
    let saved: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("云原神账号").font(.title2.bold())
            Form {
                TextField("账号（手机号或邮箱）", text: $account)
                    .textContentType(.username).autocorrectionDisabled()
                SecureField(savedAccount == nil ? "密码" : "新密码（留空保留原密码）", text: $password)
                    .textContentType(.password)
            }.textFieldStyle(.roundedBorder)
            Text("账号和密码仅持久保存在这台 Mac 的钥匙串，成功读取后在本次解锁会话内复用，锁屏、锁定钥匙串、切换用户、休眠或退出时清除内存副本。保存后启用自动密码登录；自动勾选官方协议需另行开启，验证码仍需手动处理。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let failure { Text(failure).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("取消") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存到钥匙串", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (password.isEmpty && savedAccount == nil))
            }
        }.padding(24).frame(width: 520)
            .onAppear {
                do { savedAccount = try CloudAccountKeychain.load()?.account; account = savedAccount ?? "" }
                catch { failure = error.localizedDescription }
            }
            .onDisappear { password = "" }
    }

    private func save() {
        do {
            let account = account.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials: CloudCredentials
            if password.isEmpty {
                guard let old = try CloudAccountKeychain.load(), old.account == account else {
                    throw RecorderError.message("修改账号时也需要输入对应密码。")
                }
                credentials = old
            } else { credentials = CloudCredentials(account: account, password: password) }
            try CloudAccountKeychain.save(credentials)
            password = ""
            saved()
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
