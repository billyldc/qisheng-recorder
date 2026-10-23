import Foundation

public enum CloudAgreementPolicy {
    public static func requiresConfirmation(_ labels: [String]) -> Bool {
        let text = labels.joined()
        return text.contains("同意") && (text.contains("协议") || text.contains("隐私"))
    }

    public static func checkboxIndex(labels: [String], pageLabels: [String]) -> Int? {
        let text = pageLabels.joined()
        guard text.contains("米哈游用户协议"), text.contains("米哈游隐私政策") else { return nil }
        func additionalConsent(_ label: String) -> Bool {
            ["营销", "广告", "推广", "个性化", "预约", "通知", "自动续费", "支付"].contains(where: label.contains)
        }
        let matches = labels.indices.filter { index in
            let label = labels[index]
            return label.contains("同意") && label.contains("米哈游用户协议") &&
                label.contains("米哈游隐私政策") && !additionalConsent(label)
        }
        if matches.count == 1 { return matches[0] }
        // Some Safari versions expose the checkbox without its adjacent legal text.
        guard labels.count == 1, matches.isEmpty, !additionalConsent(text) else { return nil }
        let label = labels[0].filter { !$0.isWhitespace && !"。，,.".contains($0) }
        return ["", "已阅读并同意", "我已阅读并同意"].contains(label) ? 0 : nil
    }
}
