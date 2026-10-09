import Foundation
import Security

public enum OpenAI {
    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.zhdan.traytranslate.openai",
         kSecAttrAccount as String: "api-key"]
    }

    public static func apiKey() throws -> String? {
        var query = keyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw keyError(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func saveAPIKey(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else {
            throw Translator.Failure(description: "Введите API-ключ без пробелов")
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(keyQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = keyQuery.merging(attributes) { _, new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw keyError(status) }
    }

    private static func keyError(_ status: OSStatus) -> Translator.Failure {
        Translator.Failure(description: "Связка ключей: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
    }

    public static func request(text: String, direction: Direction, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Engine.openai.model,
            "messages": [["role": "system", "content": direction.instructions],
                         ["role": "user", "content": text]],
            "store": false,
        ])
        return request
    }

    public static func translation(data: Data, status: Int) throws -> String {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = object?["error"] as? [String: Any]
            throw Translator.Failure(description: "OpenAI HTTP \(status): \(error?["message"] as? String ?? "Ошибка API")")
        }
        let choices = object?["choices"] as? [[String: Any]]
        let choice = choices?.first
        let message = choice?["message"] as? [String: Any]
        if choice?["finish_reason"] as? String == "length" {
            throw Translator.Failure(description: "OpenAI: перевод обрезан лимитом ответа")
        }
        guard let text = message?["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Translator.Failure(description: "OpenAI: пустой или некорректный ответ")
        }
        return text
    }
}
