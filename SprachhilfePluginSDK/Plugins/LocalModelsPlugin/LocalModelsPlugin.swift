import Foundation
import SwiftUI
import MLXLLM
import MLXVLM
import MLXLMCommon
import HuggingFace
import Hub
import Tokenizers
import SprachhilfePluginSDK

// This plugin is intentionally independent of Gemma4Plugin: own download directory, own
// tokenizer bridge, own model list. It exists to load ANY MLX-compatible model the user finds
// on Hugging Face (mlx-community), not just Gemma.

private struct LocalModelsHubDownloader: Downloader {
    let client: HubClient
    let modelsDirectory: URL

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest _: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw LocalModelsPlugin.DownloadError.invalidRepositoryID(id)
        }

        let destination = modelsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        return try await client.downloadSnapshot(
            of: repoID,
            to: destination,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

private struct LocalModelsTokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private struct LocalModelsTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return LocalModelsTokenizerBridge(upstream: tokenizer)
    }
}

// MARK: - Plugin Entry Point

@objc(LocalModelsPlugin)
final class LocalModelsPlugin: NSObject, LLMProviderPlugin, LLMTemperatureControllableProvider, LLMProviderSetupStatusProviding, LLMModelSelectable, PluginSettingsActivityReporting, PluginDownloadedModelManaging, PluginModelCatalogProviding, @unchecked Sendable {
    static let pluginId = "com.sprachhilfe.localmodels"
    static let pluginName = "Local Models"
    static let defaultGenerationTemperature = 0.1
    static let promptMaxTokens = 2048
    static let minMaxTokens = 256
    static let maxMaxTokens = 8192
    static let defaultPrefillStepSize = 128

    /// Architecture strings (`model_type` in config.json) registered in mlx-swift-lm's
    /// VLMTypeRegistry (verified against mlx-swift-lm 3.31.4,
    /// Libraries/MLXVLM/VLMModelFactory.swift). Everything else is treated as a plain text LLM
    /// (LLMTypeRegistry, MLXLLM). Refresh this list if the mlx-swift-lm package is upgraded.
    static let knownVLMArchitectureTypes: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_5", "qwen3_5_moe",
        "idefics3", "gemma3", "gemma4", "gemma4_unified", "smolvlm", "fastvlm", "llava_qwen2",
        "pixtral", "mistral3", "lfm2_vl", "lfm2-vl", "glm_ocr",
    ]

    enum DownloadError: LocalizedError {
        case invalidRepositoryID(String)

        var errorDescription: String? {
            switch self {
            case .invalidRepositoryID(let id):
                return "Invalid Hugging Face repository ID: '\(id)'. Expected format 'namespace/name'."
            }
        }
    }

    fileprivate var host: HostServices?
    fileprivate var _selectedLLMModelId: String?
    fileprivate var modelContainer: ModelContainer?
    fileprivate var loadedModelId: String?
    fileprivate var _generationTemperature: Double = defaultGenerationTemperature
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.custom.rawValue
    fileprivate var _hfToken: String?
    fileprivate var _customMaxTokens: Int?
    fileprivate var _userModels: [LocalModelsUserModel] = []
    fileprivate var _catalogCache: [LocalModelsCatalogEntry] = []
    fileprivate var downloadProgress: Double = 0
    var modelState: LocalModelsState = .notLoaded

    private func modelsDirectory() -> URL {
        host?.pluginDataDirectory.appendingPathComponent("models")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("localmodels-models")
    }

    private func localModelDirectory(for repoId: String) -> URL {
        modelsDirectory().appendingPathComponent(repoId, isDirectory: true)
    }

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        _userModels = Self.decodeUserModels(host.userDefault(forKey: "userModels") as? String)
        _catalogCache = Self.decodeCatalog(host.userDefault(forKey: "catalogCache") as? String)
        _customMaxTokens = host.userDefault(forKey: "customMaxTokens") as? Int

        let persistedSelection = host.userDefault(forKey: "selectedLLMModel") as? String
        _selectedLLMModelId = persistedSelection.flatMap { resolveModelDef(for: $0) != nil ? $0 : nil }
            ?? userModelDefs.first?.id

        let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String
        if let persistedLoadedModel, resolveModelDef(for: persistedLoadedModel) == nil {
            host.setUserDefault(nil, forKey: "loadedModel")
        }

        _generationTemperature = host.userDefault(forKey: "generationTemperature") as? Double
            ?? Self.defaultGenerationTemperature
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.custom.rawValue
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

        // A unit-test host can share persisted app state with a developer
        // installation, but does not include MLX's bundled Metal runtime.
        // Avoid automatically restoring a user's model in that isolated host;
        // explicit model-loading tests continue to exercise the load path.
        Task { [weak self] in
            guard let self, !Self.isRunningUnitTests else { return }
            await self.restoreLoadedModel(allowDownloads: false)
        }
    }

    func deactivate() {
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        host = nil
    }

    private static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["SPRACHHILFE_RUNNING_TESTS"] == "1" ||
            environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        return NSClassFromString("XCTestCase") != nil ||
            Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") } ||
            Bundle.allFrameworks.contains { $0.bundleIdentifier == "com.apple.dt.XCTest" }
    }

    // MARK: - LLMProviderPlugin

    var providerName: String { "Local Models (MLX)" }
    var isLocalModel: Bool { true }
    var isAvailable: Bool { modelContainer != nil && loadedModelId != nil }

    var supportedModels: [PluginModelInfo] {
        guard let loadedModelId else { return [] }
        return userModelDefs
            .filter { $0.id == loadedModelId }
            .map { PluginModelInfo(id: $0.id, displayName: $0.displayName) }
    }

    var downloadedModels: [PluginModelInfo] {
        userModelDefs
            .filter { hasDownloadedModel($0) }
            .map { def in
                PluginModelInfo(
                    id: def.id,
                    displayName: def.displayName,
                    sizeDescription: def.sizeDescription,
                    downloaded: true,
                    loaded: def.id == loadedModelId
                )
            }
    }

    func deleteDownloadedModel(_ modelId: String) async throws {
        guard let modelDef = resolveModelDef(for: modelId) else { return }
        if loadedModelId == modelId {
            modelContainer = nil
            loadedModelId = nil
            downloadProgress = 0
            modelState = .notLoaded
        }
        if _selectedLLMModelId == modelId {
            _selectedLLMModelId = nil
            host?.setUserDefault(nil, forKey: "selectedLLMModel")
        }
        if host?.userDefault(forKey: "loadedModel") as? String == modelId {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        try deleteModelFiles(modelDef)
        host?.notifyCapabilitiesChanged()
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        try await process(
            systemPrompt: systemPrompt,
            userText: userText,
            model: model,
            temperatureDirective: .inheritProviderSetting
        )
    }

    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective
    ) async throws -> String {
        guard let modelContainer else {
            throw PluginChatError.notConfigured
        }

        let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserText.isEmpty else {
            throw LocalModelsPluginError.noInputText
        }

        let combinedPrompt = """
        Follow these instructions exactly:
        \(systemPrompt)

        Input text:
        \(trimmedUserText)
        """

        let chat: [Chat.Message] = [.user(combinedPrompt)]
        let userInput = UserInput(chat: chat)
        let input = try await modelContainer.prepare(input: userInput)
        let resolvedTemperature = providerTemperatureDirective
            .resolvedTemperature(applying: temperatureDirective) ?? Self.defaultGenerationTemperature

        let parameters = GenerateParameters(
            maxTokens: resolvedMaxTokens,
            temperature: Float(resolvedTemperature),
            prefillStepSize: Self.defaultPrefillStepSize
        )

        let stream = try await modelContainer.generate(input: input, parameters: parameters)
        var result = ""
        for await generation in stream {
            switch generation {
            case .chunk(let text):
                result += text
            case .info, .toolCall:
                break
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLMModelSelectable

    func selectLLMModel(_ modelId: String) {
        _selectedLLMModelId = modelId
        host?.setUserDefault(modelId, forKey: "selectedLLMModel")
    }

    var selectedLLMModelId: String? { _selectedLLMModelId }
    var preferredModelId: String? { _selectedLLMModelId }
    var huggingFaceToken: String? { _hfToken }
    var currentDownloadProgress: Double { downloadProgress }

    var generationTemperature: Double { _generationTemperature }
    var llmTemperatureMode: PluginLLMTemperatureMode {
        PluginLLMTemperatureMode(rawValue: _llmTemperatureModeRaw) ?? .custom
    }
    fileprivate var providerTemperatureDirective: PluginLLMTemperatureDirective {
        switch llmTemperatureMode {
        case .providerDefault:
            return .custom(Self.defaultGenerationTemperature)
        case .custom, .inheritProviderSetting:
            return .custom(_generationTemperature)
        }
    }

    var requiresExternalCredentials: Bool { false }

    var unavailableReason: String? {
        if isAvailable { return nil }
        if case .error(let message) = modelState, !message.isEmpty {
            return message
        }
        return "Add and load a model in Integrations before using Local Models for prompts."
    }

    func setGenerationTemperature(_ temperature: Double) {
        let clamped = min(max(temperature, 0.0), 1.0)
        _generationTemperature = clamped
        host?.setUserDefault(clamped, forKey: "generationTemperature")
    }

    func setLLMTemperatureMode(_ mode: PluginLLMTemperatureMode) {
        let storedMode: PluginLLMTemperatureMode
        switch mode {
        case .providerDefault:
            storedMode = .providerDefault
        case .custom, .inheritProviderSetting:
            storedMode = .custom
        }
        _llmTemperatureModeRaw = storedMode.rawValue
        host?.setUserDefault(storedMode.rawValue, forKey: "llmTemperatureMode")
    }

    func saveHuggingFaceToken(_ token: String) {
        _hfToken = PluginHuggingFaceTokenHelper.saveToken(token, to: host)
    }

    func clearHuggingFaceToken() {
        _hfToken = nil
        PluginHuggingFaceTokenHelper.clearToken(from: host)
    }

    func validateHuggingFaceToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> Bool {
        await PluginHuggingFaceTokenHelper.validateToken(token, dataFetcher: dataFetcher)
    }

    func isModelDownloaded(_ modelDef: LocalModelDef) -> Bool {
        hasDownloadedModel(modelDef)
    }

    func beginModelLoad(for modelDef: LocalModelDef, isAlreadyDownloaded: Bool) {
        _selectedLLMModelId = modelDef.id
        modelState = isAlreadyDownloaded ? .loading : .downloading
        downloadProgress = isAlreadyDownloaded ? 0.8 : 0.02
        host?.notifyCapabilitiesChanged()
    }

    func cancelModelLoad() {
        downloadProgress = 0
        modelState = .notLoaded
        host?.notifyCapabilitiesChanged()
    }

    // MARK: - Model Management

    func loadModel(_ modelDef: LocalModelDef) async throws {
        try Task.checkCancellation()
        let isAlreadyDownloaded = hasDownloadedModel(modelDef)
        beginModelLoad(for: modelDef, isAlreadyDownloaded: isAlreadyDownloaded)
        do {
            let token = _hfToken?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelsDir = modelsDirectory()
            try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

            let hubClient = HubClient(
                host: HubClient.defaultHost,
                bearerToken: token?.isEmpty == false ? token : nil,
                cache: HubCache(cacheDirectory: modelsDir)
            )
            let downloader = LocalModelsHubDownloader(client: hubClient, modelsDirectory: modelsDir)
            let configuration = ModelConfiguration(id: modelDef.repoId)

            let progressHandler: @Sendable (Progress) -> Void = { progress in
                guard !Task.isCancelled else { return }
                let fraction = max(0.0, min(progress.fractionCompleted, 1.0))
                let mapped = 0.02 + fraction * 0.78
                Task { @MainActor in
                    self.downloadProgress = mapped
                    if case .downloading = self.modelState {
                        self.host?.notifyCapabilitiesChanged()
                    }
                }
            }

            // Peek the architecture before committing to a factory: both VLMModelFactory and
            // LLMModelFactory download the full model weights BEFORE checking whether the
            // architecture is registered, so guessing wrong and catching the error would
            // silently double-download several GB. A narrow config.json-only fetch first avoids
            // that — the destination directory is the same one the full download uses, so this
            // file is already in place (cache hit) when the real load runs.
            let architecture = await Self.peekArchitecture(downloader: downloader, repoId: modelDef.repoId)
            let preferVLM = architecture.map { Self.knownVLMArchitectureTypes.contains($0) } ?? false

            let container = try await Self.loadContainer(
                preferVLM: preferVLM,
                downloader: downloader,
                configuration: configuration,
                progressHandler: progressHandler
            )

            try Task.checkCancellation()
            modelState = .loading
            downloadProgress = 0.9
            modelContainer = container
            loadedModelId = modelDef.id
            _selectedLLMModelId = modelDef.id
            host?.setUserDefault(modelDef.id, forKey: "selectedLLMModel")
            host?.setUserDefault(modelDef.id, forKey: "loadedModel")
            downloadProgress = 1.0
            modelState = .ready(modelDef.id)
            host?.notifyCapabilitiesChanged()
        } catch {
            if error is CancellationError {
                cancelModelLoad()
                throw error
            }
            downloadProgress = 0
            modelState = .error(Self.userFacingLoadErrorMessage(for: error, modelDef: modelDef))
            throw error
        }
    }

    /// Reads just `config.json` for `repoId` and returns its `model_type`, or nil if that
    /// can't be determined (network error, gated repo, missing field) — callers should treat
    /// nil as "unknown" and fall back to a sensible default rather than failing outright.
    private static func peekArchitecture(downloader: LocalModelsHubDownloader, repoId: String) async -> String? {
        guard let dir = try? await downloader.download(
            id: repoId, revision: nil, matching: ["config.json"], useLatest: false, progressHandler: { _ in }
        ) else { return nil }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
              let base = try? JSONDecoder().decode(BaseConfiguration.self, from: data) else { return nil }
        return base.modelType
    }

    /// Tries the preferred factory first; if it fails specifically because the architecture
    /// isn't registered there, retries once with the other factory. Any other error (network,
    /// weight mismatch, ...) propagates immediately without a pointless second attempt.
    private static func loadContainer(
        preferVLM: Bool,
        downloader: LocalModelsHubDownloader,
        configuration: ModelConfiguration,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        do {
            return try await loadContainer(
                useVLM: preferVLM, downloader: downloader, configuration: configuration, progressHandler: progressHandler
            )
        } catch let error as MLXLMCommon.ModelFactoryError {
            guard case .unsupportedModelType = error else { throw error }
            return try await loadContainer(
                useVLM: !preferVLM, downloader: downloader, configuration: configuration, progressHandler: progressHandler
            )
        }
    }

    private static func loadContainer(
        useVLM: Bool,
        downloader: LocalModelsHubDownloader,
        configuration: ModelConfiguration,
        progressHandler: @escaping @Sendable (Progress) -> Void
    ) async throws -> ModelContainer {
        if useVLM {
            return try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: LocalModelsTokenizerLoader(),
                configuration: configuration,
                progressHandler: progressHandler
            )
        } else {
            return try await LLMModelFactory.shared.loadContainer(
                from: downloader,
                using: LocalModelsTokenizerLoader(),
                configuration: configuration,
                progressHandler: progressHandler
            )
        }
    }

    @objc func triggerAutoUnload() { unloadModel(clearPersistence: false) }
    @objc func triggerRestoreModel() { Task { await restoreLoadedModel(allowDownloads: true) } }

    func unloadModel(clearPersistence: Bool = true) {
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        if clearPersistence {
            host?.setUserDefault(nil, forKey: "loadedModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    func deleteModelFiles(_ modelDef: LocalModelDef) throws {
        let repoDir = localModelDirectory(for: modelDef.repoId)
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
    }

    /// Clears a possibly-corrupted local cache for `modelDef` so the next load re-downloads
    /// from scratch — the recovery action offered when loading fails with a cache-shaped error.
    func resetCachedModel(_ modelDef: LocalModelDef) {
        modelContainer = nil
        loadedModelId = nil
        downloadProgress = 0
        modelState = .notLoaded
        host?.setUserDefault(nil, forKey: "loadedModel")
        try? deleteModelFiles(modelDef)
        host?.notifyCapabilitiesChanged()
    }

    func restoreLoadedModel(allowDownloads: Bool = true) async {
        guard let savedId = host?.userDefault(forKey: "loadedModel") as? String,
              let modelDef = resolveModelDef(for: savedId) else {
            host?.setUserDefault(nil, forKey: "loadedModel")
            return
        }
        guard allowDownloads || hasDownloadedModel(modelDef) else { return }
        try? await loadModel(modelDef)
    }

    private func hasDownloadedModel(_ modelDef: LocalModelDef) -> Bool {
        let repoDir = localModelDirectory(for: modelDef.repoId)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: repoDir.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Settings Activity

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(message: "Downloading model", progress: downloadProgress)
        case .loading:
            return PluginSettingsActivity(message: "Preparing model")
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(LocalModelsSettingsView(plugin: self))
    }

    // MARK: - User-Configurable Settings

    var resolvedMaxTokens: Int { _customMaxTokens ?? Self.promptMaxTokens }

    func setMaxTokens(_ tokens: Int) {
        let clamped = min(max(tokens, Self.minMaxTokens), Self.maxMaxTokens)
        _customMaxTokens = clamped
        host?.setUserDefault(clamped, forKey: "customMaxTokens")
    }

    func resetMaxTokens() {
        _customMaxTokens = nil
        host?.setUserDefault(nil, forKey: "customMaxTokens")
    }

    // MARK: - User Models

    struct LocalModelsUserModel: Codable, Equatable {
        var repoId: String
        var displayName: String
    }

    static func userModelId(for repoId: String) -> String { "user-\(repoId)" }

    var userModelDefs: [LocalModelDef] {
        _userModels.map { model in
            LocalModelDef(
                id: Self.userModelId(for: model.repoId),
                displayName: model.displayName.isEmpty
                    ? (model.repoId.components(separatedBy: "/").last ?? model.repoId)
                    : model.displayName,
                repoId: model.repoId,
                sizeDescription: "?",
                ramRequirement: Self.estimatedRAM(forRepoId: model.repoId) ?? "—"
            )
        }
    }

    func resolveModelDef(for id: String?) -> LocalModelDef? {
        guard let id else { return nil }
        return userModelDefs.first(where: { $0.id == id })
    }

    func isUserModelRepoAdded(_ repoId: String) -> Bool {
        _userModels.contains(where: { $0.repoId == repoId })
    }

    @discardableResult
    func addUserModel(repoId: String, displayName: String = "") -> Bool {
        let trimmedRepo = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty, !isUserModelRepoAdded(trimmedRepo) else { return false }
        _userModels.append(LocalModelsUserModel(
            repoId: trimmedRepo,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        persistUserModels()
        host?.notifyCapabilitiesChanged()
        return true
    }

    func removeUserModel(repoId: String) {
        let id = Self.userModelId(for: repoId)
        if let def = resolveModelDef(for: id) {
            if loadedModelId == id { unloadModel(clearPersistence: true) }
            try? deleteModelFiles(def)
        }
        _userModels.removeAll { $0.repoId == repoId }
        persistUserModels()
        if _selectedLLMModelId == id {
            _selectedLLMModelId = userModelDefs.first?.id
            host?.setUserDefault(_selectedLLMModelId, forKey: "selectedLLMModel")
        }
        host?.notifyCapabilitiesChanged()
    }

    private func persistUserModels() {
        if let data = try? JSONEncoder().encode(_userModels),
           let json = String(data: data, encoding: .utf8) {
            host?.setUserDefault(json, forKey: "userModels")
        } else {
            host?.setUserDefault(nil, forKey: "userModels")
        }
    }

    static func decodeUserModels(_ json: String?) -> [LocalModelsUserModel] {
        guard let json, let data = json.data(using: .utf8),
              let models = try? JSONDecoder().decode([LocalModelsUserModel].self, from: data) else { return [] }
        return models
    }

    // MARK: - HuggingFace Catalog (Discovery)

    struct LocalModelsCatalogEntry: Codable, Identifiable, Equatable {
        var id: String
        var downloads: Int
        var isRecommended: Bool
        var ramEstimate: String?
    }

    var cachedCatalog: [LocalModelsCatalogEntry] { _catalogCache }

    func discoverCatalog(
        query: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> [LocalModelsCatalogEntry] {
        var components = URLComponents(string: "https://huggingface.co/api/models")!
        components.queryItems = [
            URLQueryItem(name: "author", value: "mlx-community"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: "50"),
        ]
        guard let url = components.url else { return _catalogCache }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let token = _hfToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        struct HFModel: Decodable {
            let id: String
            let downloads: Int?
        }

        do {
            let (data, response) = try await dataFetcher(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return _catalogCache
            }
            let models = try JSONDecoder().decode([HFModel].self, from: data)
            let entries = models.map { model in
                LocalModelsCatalogEntry(
                    id: model.id,
                    downloads: model.downloads ?? 0,
                    isRecommended: Self.isRecommendedRepo(model.id),
                    ramEstimate: Self.estimatedRAM(forRepoId: model.id)
                )
            }
            _catalogCache = entries
            if let encoded = try? JSONEncoder().encode(entries),
               let json = String(data: encoded, encoding: .utf8) {
                host?.setUserDefault(json, forKey: "catalogCache")
            }
            return entries
        } catch {
            return _catalogCache
        }
    }

    static func decodeCatalog(_ json: String?) -> [LocalModelsCatalogEntry] {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([LocalModelsCatalogEntry].self, from: data) else { return [] }
        return entries
    }

    /// Instruction-tuned 4-bit quantized repos are the most stable, fastest choice on Apple Silicon.
    static func isRecommendedRepo(_ repoId: String) -> Bool {
        let name = repoId.lowercased()
        return (name.contains("-it-") || name.hasSuffix("-it") || name.contains("instruct")) && name.contains("4bit")
    }

    /// Rough RAM estimate derived from the parameter count in the repo name (e.g. "7b", "12b").
    static func estimatedRAM(forRepoId repoId: String) -> String? {
        let name = repoId.lowercased()
        let bytesPerParam: Double
        if name.contains("4bit") { bytesPerParam = 0.6 }
        else if name.contains("6bit") { bytesPerParam = 0.85 }
        else if name.contains("8bit") { bytesPerParam = 1.1 }
        else { bytesPerParam = 2.1 } // bf16/fp16

        guard let range = name.range(of: #"(\d+(?:\.\d+)?)b\b"#, options: .regularExpression) else { return nil }
        let token = String(name[range].dropLast())
        guard let billions = Double(token) else { return nil }

        let neededGB = billions * bytesPerParam * 1.4 + 2.0
        switch neededGB {
        case ..<7: return "8 GB+"
        case ..<14: return "16 GB+"
        case ..<28: return "32 GB+"
        default: return "64 GB+"
        }
    }

    static func userFacingLoadErrorMessage(for error: Error, modelDef: LocalModelDef) -> String {
        if let pluginError = error as? LocalModelsPluginError, let description = pluginError.errorDescription {
            return description
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return "Download timed out while fetching \(modelDef.displayName) from Hugging Face. Please retry. Adding an optional HuggingFace token in this plugin can also increase download rate limits."
        }
        let rawMessage = String(describing: error).lowercased()
        if isRecoverableCacheError(rawMessage) {
            return "The downloaded model cache for \(modelDef.displayName) appears incomplete or incompatible. Delete the cached model and download it again."
        }
        if case let factoryError as MLXLMCommon.ModelFactoryError = error,
           case .unsupportedModelType(let type) = factoryError {
            return "\(modelDef.displayName)'s architecture ('\(type)') isn't supported by the bundled MLX runtime yet."
        }
        return error.localizedDescription
    }

    private static func isRecoverableCacheError(_ rawMessage: String) -> Bool {
        (rawMessage.contains("key ") && rawMessage.contains(" not found"))
            || rawMessage.contains("missing key")
            || rawMessage.contains("missing weight")
            || rawMessage.contains("shape mismatch")
            || rawMessage.contains("size mismatch")
            || (rawMessage.contains("checkpoint")
                && (rawMessage.contains("not found")
                    || rawMessage.contains("missing")
                    || rawMessage.contains("shape")
                    || rawMessage.contains("mismatch")))
    }

    // MARK: - PluginModelCatalogProviding

    var modelCatalogSourceDescription: String { "mlx-community on Hugging Face" }

    var cachedModelCatalog: [PluginCatalogModel] {
        _catalogCache.map(Self.catalogModel(from:))
    }

    func searchModelCatalog(query: String) async -> [PluginCatalogModel] {
        await discoverCatalog(query: query).map(Self.catalogModel(from:))
    }

    func isCatalogModelAdded(_ id: String) -> Bool {
        isUserModelRepoAdded(id)
    }

    @discardableResult
    func addCatalogModel(id: String, displayName: String) -> Bool {
        addUserModel(repoId: id, displayName: displayName)
    }

    private static func catalogModel(from entry: LocalModelsCatalogEntry) -> PluginCatalogModel {
        PluginCatalogModel(
            id: entry.id,
            title: entry.id,
            subtitle: "\(entry.downloads) downloads",
            isRecommended: entry.isRecommended,
            detailText: entry.ramEstimate.map { "RAM \($0)" }
        )
    }
}

// MARK: - Model Types

struct LocalModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
}

enum LocalModelsPluginError: LocalizedError {
    case noInputText

    var errorDescription: String? {
        switch self {
        case .noInputText:
            return "Please select or copy some text first."
        }
    }
}

enum LocalModelsState: Equatable {
    case notLoaded
    case downloading
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: LocalModelsState, rhs: LocalModelsState) -> Bool {
        switch (lhs, rhs) {
        case (.notLoaded, .notLoaded): true
        case (.downloading, .downloading): true
        case (.loading, .loading): true
        case let (.ready(a), .ready(b)): a == b
        case let (.error(a), .error(b)): a == b
        default: false
        }
    }
}
