import Foundation
import SwiftUI
import MLXVLM
import MLXLMCommon
import HuggingFace
import Hub
import Tokenizers
import SprachhilfePluginSDK

private struct Gemma4HubDownloader: Downloader {
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
            throw Gemma4Plugin.DownloadError.invalidRepositoryID(id)
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

private struct Gemma4TokenizerBridge: MLXLMCommon.Tokenizer {
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

private struct Gemma4TokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await AutoTokenizer.from(modelFolder: directory)
        return Gemma4TokenizerBridge(upstream: tokenizer)
    }
}

// MARK: - Plugin Entry Point

@objc(Gemma4Plugin)
final class Gemma4Plugin: NSObject, LLMProviderPlugin, LLMTemperatureControllableProvider, LLMProviderSetupStatusProviding, LLMModelSelectable, PluginSettingsActivityReporting, PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.sprachhilfe.gemma4"
    static let pluginName = "Gemma 4"
    static let defaultGenerationTemperature = 0.1
    static let experimentalModelWarning = "Experimental. You can try it at your own risk."
    static let promptMaxTokens = 2048
    static let minMaxTokens = 256
    static let maxMaxTokens = 8192
    static let customModelId = "custom-user-model"

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
    var loadedModelId: String?
    fileprivate var _generationTemperature: Double = 0.1
    fileprivate var _llmTemperatureModeRaw: String = PluginLLMTemperatureMode.custom.rawValue
    fileprivate var _hfToken: String?
    // User-configurable generation settings
    fileprivate var _customMaxTokens: Int?
    fileprivate var _customPrefillStepSize: Int?
    // User-added models (multiple slots, persisted as JSON)
    fileprivate var _userModels: [Gemma4UserModel] = []
    // HuggingFace catalog cache (offline fallback)
    fileprivate var _catalogCache: [Gemma4CatalogEntry] = []

    private func modelsDirectory() -> URL {
        host?.pluginDataDirectory.appendingPathComponent("models")
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("gemma4-models")
    }

    private func localModelDirectory(for repoId: String) -> URL {
        modelsDirectory().appendingPathComponent(repoId, isDirectory: true)
    }
    fileprivate var downloadProgress: Double = 0

    var modelState: Gemma4ModelState = .notLoaded

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host

        // Load user-added models (and migrate the legacy single custom slot)
        _userModels = Self.decodeUserModels(host.userDefault(forKey: "userModels") as? String)
        migrateLegacyCustomModel(host: host)
        _catalogCache = Self.decodeCatalog(host.userDefault(forKey: "catalogCache") as? String)

        // Load user-configurable generation settings
        _customMaxTokens = host.userDefault(forKey: "customMaxTokens") as? Int
        _customPrefillStepSize = host.userDefault(forKey: "customPrefillStepSize") as? Int

        let persistedSelection = host.userDefault(forKey: "selectedLLMModel") as? String
        let sanitizedSelection: String?
        if let persistedSelection, resolveModelDef(for: persistedSelection) != nil {
            sanitizedSelection = persistedSelection
        } else {
            sanitizedSelection = Self.sanitizedSelectedModelId(persistedSelection)
        }
        _selectedLLMModelId = sanitizedSelection
        if sanitizedSelection != persistedSelection {
            host.setUserDefault(sanitizedSelection, forKey: "selectedLLMModel")
        }

        let persistedLoadedModel = host.userDefault(forKey: "loadedModel") as? String
        let canRestore = persistedLoadedModel.map { resolveModelDef(for: $0) != nil } ?? true
        if !canRestore {
            host.setUserDefault(nil, forKey: "loadedModel")
        }

        _generationTemperature = host.userDefault(forKey: "generationTemperature") as? Double
            ?? Self.defaultGenerationTemperature
        _llmTemperatureModeRaw = host.userDefault(forKey: "llmTemperatureMode") as? String
            ?? PluginLLMTemperatureMode.custom.rawValue
        _hfToken = PluginHuggingFaceTokenHelper.loadToken(from: host)

        // A unit-test host can share the developer app's persisted model state,
        // but does not provide MLX's bundled Metal runtime. The XCTest bundle is
        // loaded just after the host app starts, so check from the asynchronous
        // task rather than synchronously during activation.
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

    // MARK: - LLMProviderPlugin

    var providerName: String { "Gemma 4 (MLX)" }

    var isLocalModel: Bool { true }

    var isAvailable: Bool {
        modelContainer != nil && loadedModelId != nil
    }

    var supportedModels: [PluginModelInfo] {
        guard let loadedModelId,
              let modelDef = resolveModelDef(for: loadedModelId) else { return [] }
        return [PluginModelInfo(id: modelDef.id, displayName: modelDef.displayName)]
    }

    var downloadedModels: [PluginModelInfo] {
        allDisplayableModels
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
            throw Gemma4PluginError.noInputText
        }

        let combinedPrompt = """
        Follow these instructions exactly:
        \(systemPrompt)

        Input text:
        \(trimmedUserText)
        """

        let chat: [Chat.Message] = [
            .user(combinedPrompt),
        ]
        let userInput = UserInput(chat: chat)
        let input = try await modelContainer.prepare(input: userInput)
        let resolvedTemperature = providerTemperatureDirective
            .resolvedTemperature(applying: temperatureDirective) ?? Self.defaultGenerationTemperature

        let effectiveModelId = model ?? loadedModelId
        let prefillSize = _customPrefillStepSize ?? Self.promptPrefillStepSize(for: effectiveModelId)
        let parameters = GenerateParameters(
            maxTokens: resolvedMaxTokens,
            temperature: Float(resolvedTemperature),
            prefillStepSize: prefillSize
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
        let sanitizedModelId = resolveModelDef(for: modelId)?.id
            ?? Self.sanitizedSelectedModelId(nil)
        _selectedLLMModelId = sanitizedModelId
        host?.setUserDefault(sanitizedModelId, forKey: "selectedLLMModel")
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

        if case .error(let message) = modelState,
           !message.isEmpty {
            return message
        }

        let bundle = Bundle(for: Gemma4Plugin.self)
        return String(
            localized: "Load a Gemma 4 model in Integrations before using it for prompts.",
            bundle: bundle
        )
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

    func isModelDownloaded(_ modelDef: Gemma4ModelDef) -> Bool {
        hasDownloadedModel(modelDef)
    }

    func beginModelLoad(for modelDef: Gemma4ModelDef, isAlreadyDownloaded: Bool) {
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

    func loadModel(_ modelDef: Gemma4ModelDef) async throws {
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
            let downloader = Gemma4HubDownloader(client: hubClient, modelsDirectory: modelsDir)
            let configuration = ModelConfiguration(
                id: modelDef.repoId,
                extraEOSTokens: ["<turn|>"]
            )
            let container = try await VLMModelFactory.shared.loadContainer(
                from: downloader,
                using: Gemma4TokenizerLoader(),
                configuration: configuration
            ) { progress in
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

    func deleteModelFiles(_ modelDef: Gemma4ModelDef) throws {
        let repoDir = localModelDirectory(for: modelDef.repoId)
        if FileManager.default.fileExists(atPath: repoDir.path) {
            try FileManager.default.removeItem(at: repoDir)
        }
    }

    func resetCachedModel(_ modelDef: Gemma4ModelDef) {
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

    private func hasDownloadedModel(_ modelDef: Gemma4ModelDef) -> Bool {
        let repoDir = localModelDirectory(for: modelDef.repoId)

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: repoDir.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Settings Activity

    var currentSettingsActivity: PluginSettingsActivity? {
        switch modelState {
        case .notLoaded, .ready:
            return nil
        case .downloading:
            return PluginSettingsActivity(
                message: "Downloading model",
                progress: downloadProgress
            )
        case .loading:
            return PluginSettingsActivity(message: "Preparing model")
        case .error(let message):
            return PluginSettingsActivity(message: message, isError: true)
        }
    }

    // MARK: - Settings View

    var settingsView: AnyView? {
        AnyView(Gemma4SettingsView(plugin: self))
    }

    // MARK: - User-Configurable Settings

    var resolvedMaxTokens: Int {
        _customMaxTokens ?? Self.promptMaxTokens
    }

    func setMaxTokens(_ tokens: Int) {
        let clamped = min(max(tokens, Self.minMaxTokens), Self.maxMaxTokens)
        _customMaxTokens = clamped
        host?.setUserDefault(clamped, forKey: "customMaxTokens")
    }

    func resetMaxTokens() {
        _customMaxTokens = nil
        host?.setUserDefault(nil, forKey: "customMaxTokens")
    }

    func setPrefillStepSize(_ size: Int) {
        let clamped = min(max(size, 16), 512)
        _customPrefillStepSize = clamped
        host?.setUserDefault(clamped, forKey: "customPrefillStepSize")
    }

    func resetPrefillStepSize() {
        _customPrefillStepSize = nil
        host?.setUserDefault(nil, forKey: "customPrefillStepSize")
    }

    var customPrefillStepSize: Int? { _customPrefillStepSize }

    // MARK: - User Models (multiple slots)

    struct Gemma4UserModel: Codable, Equatable {
        var repoId: String
        var displayName: String
    }

    static func userModelId(for repoId: String) -> String { "user-\(repoId)" }

    var userModelDefs: [Gemma4ModelDef] {
        _userModels.map { model in
            Gemma4ModelDef(
                id: Self.userModelId(for: model.repoId),
                displayName: model.displayName.isEmpty
                    ? (model.repoId.components(separatedBy: "/").last ?? model.repoId)
                    : model.displayName,
                repoId: model.repoId,
                sizeDescription: "?",
                ramRequirement: Self.estimatedRAM(forRepoId: model.repoId) ?? "—",
                availability: .custom
            )
        }
    }

    var allDisplayableModels: [Gemma4ModelDef] {
        Self.availableModels + userModelDefs
    }

    func resolveModelDef(for id: String?) -> Gemma4ModelDef? {
        guard let id else { return nil }
        if let builtIn = Self.availableModels.first(where: { $0.id == id }) { return builtIn }
        return userModelDefs.first(where: { $0.id == id })
    }

    func isUserModelRepoAdded(_ repoId: String) -> Bool {
        _userModels.contains(where: { $0.repoId == repoId })
            || Self.availableModels.contains(where: { $0.repoId == repoId })
    }

    @discardableResult
    func addUserModel(repoId: String, displayName: String = "") -> Bool {
        let trimmedRepo = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty, !isUserModelRepoAdded(trimmedRepo) else { return false }
        _userModels.append(Gemma4UserModel(
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
            _selectedLLMModelId = Self.sanitizedSelectedModelId(nil)
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

    static func decodeUserModels(_ json: String?) -> [Gemma4UserModel] {
        guard let json, let data = json.data(using: .utf8),
              let models = try? JSONDecoder().decode([Gemma4UserModel].self, from: data) else { return [] }
        return models
    }

    /// One-time migration from the legacy single custom-model slot.
    private func migrateLegacyCustomModel(host: HostServices) {
        guard let legacyRepo = host.userDefault(forKey: "customModelRepoId") as? String,
              !legacyRepo.isEmpty else { return }
        let legacyName = host.userDefault(forKey: "customModelDisplayName") as? String ?? ""
        addUserModel(repoId: legacyRepo, displayName: legacyName)
        let newId = Self.userModelId(for: legacyRepo)
        if host.userDefault(forKey: "selectedLLMModel") as? String == Self.customModelId {
            host.setUserDefault(newId, forKey: "selectedLLMModel")
        }
        if host.userDefault(forKey: "loadedModel") as? String == Self.customModelId {
            host.setUserDefault(newId, forKey: "loadedModel")
        }
        host.setUserDefault(nil, forKey: "customModelRepoId")
        host.setUserDefault(nil, forKey: "customModelDisplayName")
    }

    // MARK: - HuggingFace Catalog (Discovery)

    struct Gemma4CatalogEntry: Codable, Identifiable, Equatable {
        var id: String          // full repo id, e.g. "mlx-community/gemma-4-e2b-it-4bit"
        var downloads: Int
        var isRecommended: Bool
        var ramEstimate: String?
    }

    var cachedCatalog: [Gemma4CatalogEntry] { _catalogCache }

    func discoverCatalog(
        query: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> [Gemma4CatalogEntry] {
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
                Gemma4CatalogEntry(
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

    static func decodeCatalog(_ json: String?) -> [Gemma4CatalogEntry] {
        guard let json, let data = json.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Gemma4CatalogEntry].self, from: data) else { return [] }
        return entries
    }

    /// Instruction-tuned 4-bit quantized repos are the most stable choice on Apple Silicon.
    static func isRecommendedRepo(_ repoId: String) -> Bool {
        let name = repoId.lowercased()
        return (name.contains("-it-") || name.hasSuffix("-it")) && name.contains("4bit")
    }

    /// Rough RAM estimate derived from the parameter count in the repo name (e.g. "12b", "e4b").
    static func estimatedRAM(forRepoId repoId: String) -> String? {
        let name = repoId.lowercased()
        let bytesPerParam: Double
        if name.contains("4bit") { bytesPerParam = 0.6 }
        else if name.contains("6bit") { bytesPerParam = 0.85 }
        else if name.contains("8bit") { bytesPerParam = 1.1 }
        else { bytesPerParam = 2.1 } // bf16/fp16

        // "\b" keeps "4bit" from matching as a parameter count.
        guard let range = name.range(of: #"(\d+(?:\.\d+)?)b\b"#, options: .regularExpression) else { return nil }
        let token = String(name[range].dropLast())
        guard let billions = Double(token) else { return nil }

        let neededGB = billions * bytesPerParam * 1.4 + 2.0 // headroom for context/runtime
        switch neededGB {
        case ..<7: return "8 GB+"
        case ..<14: return "16 GB+"
        case ..<28: return "32 GB+"
        default: return "64 GB+"
        }
    }

    // MARK: - Model Definitions

    static let availableModels: [Gemma4ModelDef] = [
        Gemma4ModelDef(
            id: "gemma-4-e2b-it-4bit",
            displayName: "Gemma 4 E2B (4-bit)",
            repoId: "mlx-community/gemma-4-e2b-it-4bit",
            sizeDescription: "~3.6 GB",
            ramRequirement: "8 GB+",
            availability: .supported
        ),
        Gemma4ModelDef(
            id: "gemma-4-e4b-it-4bit",
            displayName: "Gemma 4 E4B (4-bit)",
            repoId: "mlx-community/gemma-4-e4b-it-4bit",
            sizeDescription: "~5.2 GB",
            ramRequirement: "16 GB+",
            availability: .supported
        ),
        Gemma4ModelDef(
            id: "gemma-4-e4b-it-8bit",
            displayName: "Gemma 4 E4B (8-bit)",
            repoId: "mlx-community/gemma-4-e4b-it-8bit",
            sizeDescription: "~8 GB",
            ramRequirement: "16 GB+",
            availability: .experimental(warning: experimentalModelWarning)
        ),
        Gemma4ModelDef(
            id: "gemma-4-26b-a4b-it-4bit",
            displayName: "Gemma 4 26B-A4B (4-bit, MoE)",
            repoId: "mlx-community/gemma-4-26b-a4b-it-4bit",
            sizeDescription: "~15.6 GB",
            ramRequirement: "32 GB+",
            availability: .experimental(warning: experimentalModelWarning)
        ),
    ]

    static var supportedModelDefinitions: [Gemma4ModelDef] {
        availableModels.filter(\.isSupported)
    }

    static func modelDefinition(for id: String?) -> Gemma4ModelDef? {
        guard let id else { return nil }
        return availableModels.first(where: { $0.id == id })
    }

    static func sanitizedSelectedModelId(_ id: String?) -> String? {
        guard let modelDef = modelDefinition(for: id) else {
            return supportedModelDefinitions.first?.id
        }
        return modelDef.id
    }

    static func userFacingLoadErrorMessage(for error: Error, modelDef: Gemma4ModelDef) -> String {
        if let pluginError = error as? Gemma4PluginError,
           let description = pluginError.errorDescription {
            return description
        }

        if let urlError = error as? URLError,
           urlError.code == .timedOut {
            let bundle = Bundle(for: Gemma4Plugin.self)
            return String(
                localized: "Download timed out while fetching Gemma 4 from Hugging Face. Please retry. Adding an optional HuggingFace token in this plugin can also increase download rate limits.",
                bundle: bundle
            )
        }

        let rawMessage = String(describing: error).lowercased()
        if isRecoverableCacheError(rawMessage) {
            let bundle = Bundle(for: Gemma4Plugin.self)
            return String(
                localized: "The downloaded Gemma model cache appears incomplete or incompatible. Delete the cached model and download it again.",
                bundle: bundle
            )
        }

        if rawMessage.contains("unsupported model type")
            || rawMessage.contains("model type gemma4 not supported") {
            return unsupportedModelMessage(for: modelDef)
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

    static func promptPrefillStepSize(for modelId: String?) -> Int {
        switch modelId {
        case "gemma-4-e2b-it-4bit":
            return 256
        case "gemma-4-e4b-it-4bit", "gemma-4-e4b-it-8bit":
            return 128
        case "gemma-4-26b-a4b-it-4bit":
            return 64
        default:
            return 128
        }
    }

    static func promptGenerationParameters(temperature: Double, modelId: String?) -> GenerateParameters {
        GenerateParameters(
            maxTokens: promptMaxTokens,
            temperature: Float(temperature),
            prefillStepSize: promptPrefillStepSize(for: modelId)
        )
    }

    private static func unsupportedModelMessage(for modelDef: Gemma4ModelDef) -> String {
        let supportedModels = supportedModelDefinitions.map(\.displayName).joined(separator: ", ")
        if modelDef.isSupported {
            return "Gemma 4 loading in this Sprachhilfe release is limited to \(supportedModels). If loading still fails, update to the latest app build and try again."
        }
        return "\(modelDef.displayName) is experimental in this Sprachhilfe release and may still fail to load. Recommended models: \(supportedModels)."
    }
}

// MARK: - Model Types

struct Gemma4ModelDef: Identifiable {
    let id: String
    let displayName: String
    let repoId: String
    let sizeDescription: String
    let ramRequirement: String
    let availability: Gemma4ModelAvailability

    var isSupported: Bool {
        switch availability {
        case .supported, .custom: return true
        case .experimental: return false
        }
    }

    var isCustom: Bool {
        if case .custom = availability { return true }
        return false
    }

    var experimentalWarning: String? {
        if case .experimental(let warning) = availability {
            return warning
        }
        return nil
    }
}

enum Gemma4ModelAvailability: Equatable {
    case supported
    case experimental(warning: String)
    case custom
}

enum Gemma4PluginError: LocalizedError {
    case noInputText

    var errorDescription: String? {
        switch self {
        case .noInputText:
            return "Please select or copy some text first."
        }
    }
}

enum Gemma4ModelState: Equatable {
    case notLoaded
    case downloading
    case loading
    case ready(String)
    case error(String)

    static func == (lhs: Gemma4ModelState, rhs: Gemma4ModelState) -> Bool {
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
