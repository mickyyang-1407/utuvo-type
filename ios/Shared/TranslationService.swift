import Foundation

/// 雲端翻譯（選配）：走 DashScope 相容模式 chat completions。
/// 對齊 macOS 線邊界：key 只在使用者明確輸入後使用；無 key 時功能隱藏、絕不雲端。
/// 2026-09-11：key 從 UserDefaults 明文搬進 Keychain（`IOSSecretStore`），
/// 與 macOS `SecretStore` 同語意；舊的明文值第一次讀取時自動遷移並刪除。
struct TranslationService {
    static let shared = TranslationService()

    private var apiKey: String {
        IOSSecretStore.apiKey()
    }
    var isConfigured: Bool { !apiKey.isEmpty }

    /// 目標語言（對齊 macOS 修飾鍵 slot 的常用清單）。
    static let targets: [(code: String, zh: String, en: String)] = [
        ("zh-Hant", "繁體中文", "Traditional Chinese"),
        ("en", "英文", "English"),
        ("ja", "日文", "Japanese"),
        ("ko", "韓文", "Korean"),
        ("fr", "法文", "French"),
        ("de", "德文", "German"),
        ("es", "西班牙文", "Spanish"),
        ("pt", "葡萄牙文", "Portuguese"),
        ("ru", "俄文", "Russian")
    ]

    func translate(_ text: String, to targetName: String) async throws -> String {
        let systemPrompt = """
        You are a translation engine. Translate the user's text into \(targetName). \
        Output ONLY the translation, no explanations, no quotes, no reasoning.
        """
        return try await complete(system: systemPrompt, user: text)
    }

    /// 通用 chat completion（翻譯與「說出要怎麼改」共用）：只回 content。
    func complete(system systemPrompt: String, user text: String) async throws -> String {
        guard !apiKey.isEmpty else { throw TranslationError.notConfigured }
        guard let url = URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions") else {
            throw TranslationError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": "qwen3.7-flash",
            "temperature": 0,
            "stream": false,
            "enable_thinking": false,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw TranslationError.http(http.statusCode)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranslationError.malformed
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum TranslationError: LocalizedError {
        case notConfigured, badURL, http(Int), malformed

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未設定雲端 API key（設定 → 雲端翻譯）"
            case .badURL: return "端點網址錯誤"
            case .http(let code): return "雲端回傳 HTTP \(code)"
            case .malformed: return "雲端回應格式無法解析"
            }
        }
    }
}
