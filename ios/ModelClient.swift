import Foundation
import Security
import UIKit

struct ModelClient {
    let baseURL: String
    let model: String
    let apiKey: String
    private static let session = URLSession(configuration: .ephemeral, delegate: ModelRedirectGuard(), delegateQueue: nil)

    static func baseComponents(_ value: String) -> URLComponents? {
        guard var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.scheme = scheme
        components.host = host
        while components.path.hasSuffix("/") { components.path.removeLast() }
        for suffix in ["/chat/completions", "/messages", "/models"] where components.path.hasSuffix(suffix) {
            components.path.removeLast(suffix.count)
            break
        }
        return components
    }

    private var isClaude: Bool { Self.baseComponents(baseURL)?.host == "api.anthropic.com" }

    func request(path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard var components = Self.baseComponents(baseURL) else {
            throw LinkError.io("请填写有效的服务地址。")
        }
        components.path += "/\(path)"
        guard let url = components.url else { throw LinkError.io("服务地址无效。") }

        var request = URLRequest(url: url, timeoutInterval: body == nil ? 25 : 45)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if isClaude {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    func models() async throws -> [String] {
        let response = try await send(request(path: "models"))
        guard let entries = response["data"] as? [[String: Any]] else {
            throw LinkError.io("这个服务没有返回可读取的模型列表。")
        }
        return Set(entries.compactMap { $0["id"] as? String }).sorted()
    }

    func ping() async throws -> String {
        try await complete(question: "Reply with the single word: ok", image: nil, maxTokens: 64)
    }

    func ask(question: String, image: Data? = nil) async throws -> String {
        try await complete(question: question, image: image, maxTokens: 800)
    }

    func completionRequest(question: String, image: Data?, maxTokens: Int) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LinkError.io("请选择模型或填写模型名称。") }

        var content: Any = question
        if let image, !image.isEmpty {
            let jpeg: Data
            if image.starts(with: [0xFF, 0xD8]) {
                jpeg = image
            } else if let converted = UIImage(data: image)?.jpegData(compressionQuality: 0.84) {
                jpeg = converted
            } else {
                throw LinkError.io("这张照片无法转换为模型支持的格式。")
            }
            let encoded = jpeg.base64EncodedString()
            let photo: [String: Any] = isClaude
                ? ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": encoded]]
                : ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(encoded)"]]
            content = [["type": "text", "text": question], photo]
        }
        let tokenField = Self.baseComponents(baseURL)?.host == "api.openai.com"
            ? "max_completion_tokens" : "max_tokens"
        let body: [String: Any] = ["model": model, tokenField: maxTokens,
                                   "messages": [["role": "user", "content": content]]]
        return try request(path: isClaude ? "messages" : "chat/completions", body: body)
    }

    private func complete(question: String, image: Data?, maxTokens: Int) async throws -> String {
        let response = try await send(completionRequest(question: question, image: image, maxTokens: maxTokens))
        let text: String?
        if isClaude {
            let blocks = response["content"] as? [[String: Any]] ?? []
            text = blocks.filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            let choices = response["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LinkError.io("模型没有返回文本。")
        }
        return text
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await Self.session.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode else {
            throw LinkError.io("服务没有返回 HTTP 响应。")
        }
        switch code {
        case 200 ..< 300:
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LinkError.io("服务返回了无法读取的内容。")
            }
            return json
        case 300 ..< 400: throw LinkError.io("服务要求跳转，请填写它的最终 API 地址。")
        case 401: throw LinkError.io("HTTP 401 · 请检查此服务的 API Key。")
        case 403: throw LinkError.io("HTTP 403 · 当前账号没有访问权限。")
        case 404: throw LinkError.io("HTTP 404 · 请检查服务地址和模型 ID。")
        case 429: throw LinkError.io("HTTP 429 · 请检查服务额度或稍后重试。")
        default:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            var detail = error?["message"] as? String ?? "服务拒绝了请求。"
            if !apiKey.isEmpty { detail = detail.replacingOccurrences(of: apiKey, with: "[API Key]") }
            throw LinkError.io("HTTP \(code) · \(detail.prefix(200))")
        }
    }
}

private final class ModelRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum ModelCredentials {
    private static func query(for baseURL: String) -> [String: Any]? {
        guard let endpoint = ModelClient.baseComponents(baseURL)?.string else { return nil }
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.local.glasseslink.model",
                kSecAttrAccount as String: endpoint]
    }

    static func read(for baseURL: String) -> String {
        guard var query = query(for: baseURL) else { return "" }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ key: String, for baseURL: String) throws {
        guard let query = query(for: baseURL) else { throw LinkError.io("服务地址无效。") }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let status: OSStatus
        if key.isEmpty {
            status = SecItemDelete(query as CFDictionary)
        } else {
            let data = Data(key.utf8)
            let change = [kSecValueData as String: data]
            let updated = SecItemUpdate(query as CFDictionary, change as CFDictionary)
            if updated == errSecItemNotFound {
                var item = query
                item[kSecValueData as String] = data
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(item as CFDictionary, nil)
            } else {
                status = updated
            }
        }
        if status != errSecSuccess, !(key.isEmpty && status == errSecItemNotFound) {
            throw LinkError.io("无法更新钥匙串中的模型 API Key（\(status)）。")
        }
    }

    static func migrateLegacyKey(for baseURL: String) {
        let defaults = UserDefaults.standard
        guard let old = defaults.string(forKey: "modelKey"), !old.isEmpty else { return }
        let expectedHost: String?
        if old.hasPrefix("sk-ant-") {
            expectedHost = "api.anthropic.com"
        } else if old.hasPrefix("sk-or-") {
            expectedHost = "openrouter.ai"
        } else if old.hasPrefix("sk-proj-") {
            expectedHost = "api.openai.com"
        } else {
            expectedHost = nil
        }
        guard let expectedHost, let endpoint = ModelClient.baseComponents(baseURL),
              endpoint.scheme == "https", endpoint.host == expectedHost else { return }
        if !read(for: baseURL).isEmpty || (try? save(old, for: baseURL)) != nil {
            defaults.removeObject(forKey: "modelKey")
        }
    }
}
