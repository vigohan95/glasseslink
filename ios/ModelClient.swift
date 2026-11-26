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

    /// A JPEG no longer than `maxPixel` on its long edge, upright.
    static func modelImage(_ data: Data, maxPixel: Int = 1568) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }

    /// `withoutImage`: the question to ask instead when this model takes no pictures (DeepSeek's do not);
    /// nil asks the same question without the picture.
    func ask(question: String, image: Data? = nil, withoutImage: String? = nil) async throws -> String {
        guard let image else { return try await complete(question: question, image: nil, maxTokens: 800) }
        do {
            return try await complete(question: question, image: image, maxTokens: 800)
        } catch LinkError.io(let message) where Self.refusedPicture(message) {
            return try await complete(question: withoutImage ?? question, image: nil, maxTokens: 800)
        }
    }

    /// A refusal of the request as made (400, 415, 422): a model that takes no pictures says so this way.
    static func refusedPicture(_ message: String) -> Bool {
        ["HTTP 400", "HTTP 415", "HTTP 422"].contains { message.hasPrefix($0) }
    }

    /// Services whose models think before answering unless told not to. A spoken answer wants the answer
    /// at once, and the thinking would use up the tokens the answer has (DeepSeek's API docs: thinking
    /// is on by default, `thinking: {type: disabled}` turns it off).
    private var thinksByDefault: Bool { Self.baseComponents(baseURL)?.host == "api.deepseek.com" }

    /// Model names a service has retired, to the names it takes now.
    static func current(model: String, baseURL: String) -> String {
        guard baseComponents(baseURL)?.host == "api.deepseek.com" else { return model }
        switch model {
        case "deepseek-chat", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": return "deepseek-flash"
        case "deepseek-reasoner": return "deepseek-v4-pro"
        default: return model
        }
    }

    func completionRequest(question: String, image: Data?, maxTokens: Int) throws -> URLRequest {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LinkError.io("请选择模型或填写模型名称。") }

        var content: Any = question
        if let image, !image.isEmpty {
            // Originals are several megabytes; the model APIs cap an image near 5 MB and gain nothing past ~1568 px.
            guard let jpeg = Self.modelImage(image) ?? (image.starts(with: [0xFF, 0xD8]) ? image : nil) else {
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
        var body: [String: Any] = ["model": Self.current(model: model, baseURL: baseURL), tokenField: maxTokens,
                                   "messages": [["role": "user", "content": content]]]
        if thinksByDefault { body["thinking"] = ["type": "disabled"] }
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
            let choices = response["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            if let thought = message?["reasoning_content"] as? String, !thought.isEmpty {
                throw LinkError.io("模型只返回了思考过程，没有给出回答。换一个不带思考的模型试试。")
            }
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
        case 401: throw LinkError.io("HTTP 401 · API Key 不对，或不属于这个服务。")
        case 402: throw LinkError.io("HTTP 402 · 这个服务的账户余额不足，需要充值。")
        case 403: throw LinkError.io("HTTP 403 · 当前账号没有访问权限。")
        case 404: throw LinkError.io("HTTP 404 · 请检查服务地址和模型 ID。")
        case 429: throw LinkError.io("HTTP 429 · 请检查服务额度或稍后重试。")
        default:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            var detail = error?["message"] as? String ?? "服务拒绝了请求。"
            if !apiKey.isEmpty { detail = detail.replacingOccurrences(of: apiKey, with: "[API Key]") }
            var hint = ""
            let lower = detail.lowercased()
            if lower.contains("model") && (lower.contains("not exist") || lower.contains("not found")
                                           || lower.contains("invalid") || lower.contains("does not")) {
                hint = " · 模型 ID 不对，点「从服务读取模型列表」选一个"
            } else if lower.contains("balance") || lower.contains("credit") || lower.contains("quota")
                        || lower.contains("insufficient") {
                hint = " · 这个服务的账户余额不足，需要充值"
            }
            throw LinkError.io("HTTP \(code) · \(detail.prefix(200))\(hint)")
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
