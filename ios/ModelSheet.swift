import SwiftUI

struct ModelSheet: View {
    private enum Provider: String, CaseIterable, Identifiable {
        case openAI = "OpenAI"
        case claude = "Claude（Anthropic）"
        case openRouter = "OpenRouter"
        case deepSeek = "DeepSeek"
        case ollama = "本地 Ollama"
        case custom = "自建服务"

        var id: Self { self }

        var endpoint: String {
            switch self {
            case .openAI: return "https://api.openai.com/v1"
            case .claude: return "https://api.anthropic.com/v1"
            case .openRouter: return "https://openrouter.ai/api/v1"
            case .deepSeek: return "https://api.deepseek.com/v1"
            case .ollama: return "http://192.168.3.90:11434/v1"
            case .custom: return ""
            }
        }

        var suggestions: [String] {
            switch self {
            case .openAI: return ["gpt-4o-mini"]
            case .claude: return ["claude-sonnet-4-6"]
            case .openRouter: return ["anthropic/claude-sonnet-4.6", "google/gemini-2.5-flash"]
            case .deepSeek: return ["deepseek-chat"]
            case .ollama: return ["gemma3:4b"]
            case .custom: return []
            }
        }

        static func detect(_ address: String) -> Self {
            guard let components = ModelClient.baseComponents(address) else { return .custom }
            if components.port == 11434 { return .ollama }
            return allCases.first {
                ModelClient.baseComponents($0.endpoint)?.host == components.host
            } ?? .custom
        }
    }

    @ObservedObject var g: Glasses
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider
    @State private var baseURL: String
    @State private var model: String
    @State private var key: String
    @State private var requestInFlight = false
    @State private var response: String?
    @State private var responseOK = false
    @State private var modelIDs: [String] = []
    @State private var showModels = false
    @State private var search = ""

    init(g: Glasses) {
        self.g = g
        _provider = State(initialValue: Provider.detect(g.modelBaseURL))
        _baseURL = State(initialValue: g.modelBaseURL)
        _model = State(initialValue: g.modelName)
        _key = State(initialValue: ModelCredentials.read(for: g.modelBaseURL))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("服务") {
                    Picker("提供商", selection: $provider) {
                        ForEach(Provider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("服务地址", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("服务地址")
                    SecureField("API Key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("模型") {
                    TextField("模型 ID，可手动输入", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("模型 ID")
                    if !provider.suggestions.isEmpty {
                        Menu("选择常用模型") {
                            ForEach(provider.suggestions, id: \.self) { id in
                                Button(id) { model = id }
                            }
                        }
                    }
                    Button("从服务读取模型列表") { loadModels() }
                        .disabled(ModelClient.baseComponents(baseURL) == nil)
                }

                Section {
                    Button("测试连接") { testConnection() }.disabled(!ready)
                    if requestInFlight { ProgressView("正在请求服务…") }
                    if let response {
                        Label(response, systemImage: responseOK ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(responseOK ? Color.green : Color.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .disabled(requestInFlight)
            .navigationTitle("模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!ready || requestInFlight)
                }
            }
            .onChange(of: provider) { _, value in
                guard value != .custom else { return }
                baseURL = value == .ollama && Provider.detect(g.modelBaseURL) == .ollama
                    ? g.modelBaseURL : value.endpoint
                model = value.suggestions.first ?? ""
            }
            .onChange(of: baseURL) { old, new in
                if ModelClient.baseComponents(old) != ModelClient.baseComponents(new) {
                    key = ModelCredentials.read(for: new)
                }
                response = nil
            }
            .onChange(of: key) { _, _ in response = nil }
            .onChange(of: model) { _, _ in response = nil }
            .sheet(isPresented: $showModels) { modelPicker }
        }
    }

    private var ready: Bool {
        ModelClient.baseComponents(baseURL) != nil
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var client: ModelClient { ModelClient(baseURL: baseURL, model: model, apiKey: key) }

    private var modelPicker: some View {
        NavigationStack {
            List(modelIDs.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { id in
                Button(id) {
                    model = id
                    showModels = false
                }
            }
            .searchable(text: $search, prompt: "搜索模型")
            .navigationTitle("服务提供的模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showModels = false } }
            }
        }
    }

    private func loadModels() {
        let draft = client
        requestInFlight = true
        response = nil
        Task {
            defer { requestInFlight = false }
            do {
                modelIDs = try await draft.models()
                if modelIDs.isEmpty {
                    responseOK = false
                    response = "服务返回的列表为空。可以手动填写模型 ID。"
                } else {
                    search = ""
                    showModels = true
                }
            } catch {
                responseOK = false
                response = Glasses.explain(error)
            }
        }
    }

    private func testConnection() {
        let draft = client
        requestInFlight = true
        response = nil
        Task {
            defer { requestInFlight = false }
            let start = Date()
            do {
                _ = try await draft.ping()
                responseOK = true
                response = "模型已返回回复 · \(Int(Date().timeIntervalSince(start) * 1000)) ms"
            } catch {
                responseOK = false
                response = Glasses.explain(error)
            }
        }
    }

    private func save() {
        do {
            try g.saveModelSettings(baseURL: baseURL, model: model, key: key)
            dismiss()
        } catch {
            responseOK = false
            response = Glasses.explain(error)
        }
    }
}
