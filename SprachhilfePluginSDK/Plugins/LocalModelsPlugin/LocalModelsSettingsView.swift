import SwiftUI
import SprachhilfePluginSDK

struct LocalModelsSettingsView: View {
    let plugin: LocalModelsPlugin
    @State private var modelState: LocalModelsState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .custom
    @State private var generationTemperature: Double = LocalModelsPlugin.defaultGenerationTemperature
    @State private var downloadProgress: Double = 0
    @State private var hfTokenInput = ""
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?
    @State private var isPolling = false
    @State private var loadTask: Task<Void, Never>?

    @State private var catalogQuery = ""
    @State private var catalogEntries: [LocalModelsPlugin.LocalModelsCatalogEntry] = []
    @State private var isCatalogLoading = false
    @State private var manualRepoInput = ""
    @State private var userModelsVersion = 0

    @State private var maxTokensValue: Double = Double(LocalModelsPlugin.promptMaxTokens)
    @State private var useCustomMaxTokens = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin.huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool { !storedHfToken.isEmpty }

    private var displayableModels: [LocalModelDef] {
        _ = userModelsVersion
        return plugin.userModelDefs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Local Models (MLX)")
                .font(.headline)

            Text("Run any MLX-compatible model from Hugging Face locally on Apple Silicon — text LLMs (Llama, Qwen, Mistral, Phi, DeepSeek, ...) and vision-language models. No API key required.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            generationSection

            Divider()

            maxTokensSection

            Divider()

            hfTokenSection

            Divider()

            modelListSection

            Divider()

            catalogSection
        }
        .padding()
        .onAppear {
            syncFromPlugin()
        }
        .task {
            if case .notLoaded = plugin.modelState {
                isPolling = true
                await plugin.restoreLoadedModel(allowDownloads: false)
                isPolling = false
                modelState = plugin.modelState
            }
        }
        .onReceive(pollTimer) { _ in
            guard isPolling else { return }
            downloadProgress = plugin.currentDownloadProgress
            let pluginState = plugin.modelState
            if pluginState != .notLoaded { modelState = pluginState }
            if case .ready = pluginState { isPolling = false }
            else if case .error = pluginState { isPolling = false }
        }
        .onChange(of: hfTokenInput) { _, newValue in
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines) != storedHfToken {
                tokenValidationResult = nil
            }
        }
    }

    // MARK: - Generation Section

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generation")
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Temperature Mode", selection: $llmTemperatureMode) {
                Text("Provider Default").tag(PluginLLMTemperatureMode.providerDefault)
                Text("Custom").tag(PluginLLMTemperatureMode.custom)
            }
            .onChange(of: llmTemperatureMode) { _, newValue in
                plugin.setLLMTemperatureMode(newValue)
            }

            if llmTemperatureMode == .custom {
                HStack {
                    Text("Temperature")
                    Spacer()
                    Text(generationTemperature, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)

                Slider(value: $generationTemperature, in: 0...1, step: 0.05)
                    .onChange(of: generationTemperature) { _, newValue in
                        plugin.setGenerationTemperature(newValue)
                    }

                HStack {
                    Text("Precise")
                    Spacer()
                    Text("Creative")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Max Tokens Section

    private var maxTokensSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced")
                .font(.subheadline)
                .fontWeight(.medium)

            Toggle(isOn: $useCustomMaxTokens) {
                Text("Custom Max Output Tokens")
                    .font(.callout)
            }
            .onChange(of: useCustomMaxTokens) { _, enabled in
                if enabled {
                    plugin.setMaxTokens(Int(maxTokensValue))
                } else {
                    plugin.resetMaxTokens()
                }
            }

            if useCustomMaxTokens {
                HStack {
                    Text("Max tokens")
                    Spacer()
                    Text("\(Int(maxTokensValue))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)

                Slider(
                    value: $maxTokensValue,
                    in: Double(LocalModelsPlugin.minMaxTokens)...Double(LocalModelsPlugin.maxMaxTokens),
                    step: 256
                )
                .onChange(of: maxTokensValue) { _, newValue in
                    plugin.setMaxTokens(Int(newValue))
                }

                Text("Controls the maximum number of tokens generated per response. Higher values allow longer outputs but use more memory and take longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - HuggingFace Token Section

    private var hfTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HuggingFace Token")
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Optional. Increases download rate limits and allows gated repos. Free at huggingface.co/settings/tokens")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("hf_...", text: $hfTokenInput)
                    .textFieldStyle(.roundedBorder)

                Button("Save") {
                    validateAndSaveHuggingFaceToken()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)

                if hasStoredHfToken {
                    Button("Remove") {
                        hfTokenInput = ""
                        tokenValidationResult = nil
                        isValidatingToken = false
                        plugin.clearHuggingFaceToken()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if isValidatingToken {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Validating token...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let result = tokenValidationResult {
                HStack(spacing: 4) {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result ? "Valid HuggingFace Token" : "Invalid HuggingFace Token")
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }
        }
    }

    // MARK: - Model List Section

    private var modelListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.subheadline)
                .fontWeight(.medium)

            if displayableModels.isEmpty {
                Text("No models added yet. Search the catalog below or paste a Hugging Face repo ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(displayableModels) { modelDef in
                    modelRow(modelDef)
                }
            }

            if case .error(let message) = modelState {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Model Catalog Section

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Model Catalog")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("(mlx-community on Hugging Face)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Search any MLX model — text LLMs and vision-language models alike. Instruction-tuned 4-bit models are marked as recommended. Added models appear in the list above.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Search (e.g. llama, qwen, mistral)", text: $catalogQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit { refreshCatalog() }

                Button {
                    refreshCatalog()
                } label: {
                    if isCatalogLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCatalogLoading)
            }

            if catalogEntries.isEmpty && !isCatalogLoading {
                Text("No results yet. Enter a search term above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(catalogEntries) { entry in
                            catalogRow(entry)
                            Divider().opacity(0.4)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            HStack(spacing: 8) {
                TextField("Repo ID (e.g. mlx-community/model-name)", text: $manualRepoInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Add") {
                    addRepo(manualRepoInput)
                    manualRepoInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manualRepoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Note: models must use a supported MLX architecture (most current text and vision-language models do). Use a HuggingFace token if the repo is gated.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: LocalModelsPlugin.LocalModelsCatalogEntry) -> some View {
        let added = plugin.isUserModelRepoAdded(entry.id)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.id.replacingOccurrences(of: "mlx-community/", with: ""))
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if entry.isRecommended {
                        Text("Recommended")
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green, in: Capsule())
                    }
                    if let ram = entry.ramEstimate {
                        Text("RAM \(ram)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\(entry.downloads) downloads")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Spacer()

            if added {
                Label("Added", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    addRepo(entry.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Model Row

    @ViewBuilder
    private func modelRow(_ modelDef: LocalModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(modelDef.displayName)
                    .font(.body)
                Text(modelDef.sizeDescription == "?" ? "RAM: \(modelDef.ramRequirement)" :
                     "\(modelDef.sizeDescription) · RAM: \(modelDef.ramRequirement)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if case .downloading = modelState, selectedModelId == modelDef.id {
                HStack(spacing: 8) {
                    ProgressView(value: downloadProgress).frame(width: 80)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption).monospacedDigit()
                    Button("Cancel") { cancelCurrentLoad() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if case .loading = modelState, selectedModelId == modelDef.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { cancelCurrentLoad() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Unload") { resetCachedModel(modelDef) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if isRecoverableCachedModelError(for: modelDef) {
                Button("Delete cached model") { resetCachedModel(modelDef) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else {
                HStack(spacing: 8) {
                    Button("Download & Load") { startLoading(modelDef) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(modelState == .downloading || modelState == .loading)
                    Button("Remove") { removeUserModel(modelDef) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(modelState == .downloading || modelState == .loading)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func syncFromPlugin() {
        modelState = plugin.modelState
        selectedModelId = plugin.selectedLLMModelId ?? plugin.userModelDefs.first?.id ?? ""
        llmTemperatureMode = plugin.llmTemperatureMode
        generationTemperature = plugin.generationTemperature
        downloadProgress = plugin.currentDownloadProgress
        if let token = plugin.huggingFaceToken, !token.isEmpty { hfTokenInput = token }

        catalogEntries = plugin.cachedCatalog

        let storedMaxTokens = plugin.resolvedMaxTokens
        if storedMaxTokens != LocalModelsPlugin.promptMaxTokens {
            useCustomMaxTokens = true
            maxTokensValue = Double(storedMaxTokens)
        }
    }

    private func refreshCatalog() {
        let query = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isCatalogLoading = true
        Task {
            let entries = await plugin.discoverCatalog(query: query)
            await MainActor.run {
                catalogEntries = entries
                isCatalogLoading = false
            }
        }
    }

    private func addRepo(_ repoId: String) {
        let trimmed = repoId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        plugin.addUserModel(repoId: trimmed)
        userModelsVersion += 1
    }

    private func removeUserModel(_ modelDef: LocalModelDef) {
        plugin.removeUserModel(repoId: modelDef.repoId)
        userModelsVersion += 1
        modelState = plugin.modelState
        selectedModelId = plugin.selectedLLMModelId ?? plugin.userModelDefs.first?.id ?? ""
    }

    private func isRecoverableCachedModelError(for modelDef: LocalModelDef) -> Bool {
        if case .error = modelState,
           selectedModelId == modelDef.id,
           plugin.isModelDownloaded(modelDef) {
            return true
        }
        return false
    }

    private func resetCachedModel(_ modelDef: LocalModelDef) {
        loadTask?.cancel()
        loadTask = nil
        isPolling = false
        plugin.resetCachedModel(modelDef)
        modelState = plugin.modelState
        downloadProgress = plugin.currentDownloadProgress
    }

    private func startLoading(_ modelDef: LocalModelDef) {
        selectedModelId = modelDef.id
        let alreadyDownloaded = plugin.isModelDownloaded(modelDef)
        plugin.beginModelLoad(for: modelDef, isAlreadyDownloaded: alreadyDownloaded)
        modelState = plugin.modelState
        downloadProgress = plugin.currentDownloadProgress
        isPolling = true
        loadTask?.cancel()
        loadTask = Task {
            do { try await plugin.loadModel(modelDef) }
            catch is CancellationError { }
            catch { }
            await MainActor.run {
                isPolling = false
                modelState = plugin.modelState
                downloadProgress = plugin.currentDownloadProgress
                loadTask = nil
            }
        }
    }

    private func cancelCurrentLoad() {
        loadTask?.cancel()
        loadTask = nil
        isPolling = false
        plugin.cancelModelLoad()
        modelState = plugin.modelState
        downloadProgress = plugin.currentDownloadProgress
    }

    private func validateAndSaveHuggingFaceToken() {
        let token = trimmedHfTokenInput
        guard !token.isEmpty else { return }
        isValidatingToken = true
        tokenValidationResult = nil
        Task {
            let isValid = await plugin.validateHuggingFaceToken(token)
            await MainActor.run {
                isValidatingToken = false
                tokenValidationResult = isValid
                if isValid {
                    hfTokenInput = token
                    plugin.saveHuggingFaceToken(token)
                }
            }
        }
    }
}
