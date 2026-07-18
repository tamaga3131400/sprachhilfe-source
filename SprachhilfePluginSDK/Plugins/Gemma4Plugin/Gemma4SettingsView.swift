import SwiftUI
import SprachhilfePluginSDK

struct Gemma4SettingsView: View {
    let plugin: Gemma4Plugin
    private let bundle = Bundle(for: Gemma4Plugin.self)
    @State private var modelState: Gemma4ModelState = .notLoaded
    @State private var selectedModelId: String = ""
    @State private var llmTemperatureMode: PluginLLMTemperatureMode = .custom
    @State private var generationTemperature: Double = Gemma4Plugin.defaultGenerationTemperature
    @State private var downloadProgress: Double = 0
    @State private var hfTokenInput = ""
    @State private var isValidatingToken = false
    @State private var tokenValidationResult: Bool?
    @State private var isPolling = false
    @State private var loadTask: Task<Void, Never>?

    // Model catalog (HuggingFace discovery) + user-added models
    @State private var catalogQuery = "gemma"
    @State private var catalogEntries: [Gemma4Plugin.Gemma4CatalogEntry] = []
    @State private var isCatalogLoading = false
    @State private var manualRepoInput = ""
    @State private var userModelsVersion = 0

    // Advanced settings
    @State private var maxTokensValue: Double = Double(Gemma4Plugin.promptMaxTokens)
    @State private var useCustomMaxTokens = false
    @State private var prefillStepSizeValue: Int = 128
    @State private var useCustomPrefill = false

    private let pollTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var trimmedHfTokenInput: String {
        hfTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var storedHfToken: String {
        plugin.huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var hasStoredHfToken: Bool { !storedHfToken.isEmpty }

    private var displayableModels: [Gemma4ModelDef] {
        _ = userModelsVersion  // re-evaluate after add/remove
        return plugin.allDisplayableModels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Gemma 4 (MLXVLM)")
                .font(.headline)

            Text("Local Gemma models for Apple Silicon, loaded with MLXVLM. No API key required.", bundle: bundle)
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            generationSection

            Divider()

            advancedSection

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
            if catalogEntries.isEmpty { refreshCatalog() }
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
            Text("Generation", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Picker("Temperature Mode", selection: $llmTemperatureMode) {
                Text("Provider Default", bundle: bundle).tag(PluginLLMTemperatureMode.providerDefault)
                Text("Custom", bundle: bundle).tag(PluginLLMTemperatureMode.custom)
            }
            .onChange(of: llmTemperatureMode) { _, newValue in
                plugin.setLLMTemperatureMode(newValue)
            }

            if llmTemperatureMode == .custom {
                HStack {
                    Text("Temperature", bundle: bundle)
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
                    Text("Precise", bundle: bundle)
                    Spacer()
                    Text("Creative", bundle: bundle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Uses Gemma 4's built-in default temperature.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Advanced", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            // Max Output Tokens
            Toggle(isOn: $useCustomMaxTokens) {
                Text("Custom Max Output Tokens", bundle: bundle)
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
                    Text("Max tokens", bundle: bundle)
                    Spacer()
                    Text("\(Int(maxTokensValue))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.caption)

                Slider(
                    value: $maxTokensValue,
                    in: Double(Gemma4Plugin.minMaxTokens)...Double(Gemma4Plugin.maxMaxTokens),
                    step: 256
                )
                .onChange(of: maxTokensValue) { _, newValue in
                    plugin.setMaxTokens(Int(newValue))
                }

                HStack {
                    Text("\(Gemma4Plugin.minMaxTokens)", bundle: bundle)
                    Spacer()
                    Text("Default: \(Gemma4Plugin.promptMaxTokens)", bundle: bundle)
                    Spacer()
                    Text("\(Gemma4Plugin.maxMaxTokens)", bundle: bundle)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text("Controls the maximum number of tokens generated per response. Higher values allow longer outputs but use more memory and take longer.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().opacity(0.5)

            // Prefill Step Size
            Toggle(isOn: $useCustomPrefill) {
                Text("Custom Prefill Step Size", bundle: bundle)
                    .font(.callout)
            }
            .onChange(of: useCustomPrefill) { _, enabled in
                if enabled {
                    plugin.setPrefillStepSize(prefillStepSizeValue)
                } else {
                    plugin.resetPrefillStepSize()
                }
            }

            if useCustomPrefill {
                Picker("Prefill Step Size", selection: $prefillStepSizeValue) {
                    Text("16 (slow, low VRAM)").tag(16)
                    Text("32").tag(32)
                    Text("64").tag(64)
                    Text("128 (balanced)").tag(128)
                    Text("256").tag(256)
                    Text("512 (fast, high VRAM)").tag(512)
                }
                .pickerStyle(.menu)
                .onChange(of: prefillStepSizeValue) { _, newValue in
                    plugin.setPrefillStepSize(newValue)
                }

                Text("Controls how many tokens are processed in parallel during prompt prefill. Smaller values reduce peak memory usage; larger values speed up long prompts.", bundle: bundle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - HuggingFace Token Section

    private var hfTokenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HuggingFace Token", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            Text("Optional. Increases download rate limits. Free at huggingface.co/settings/tokens", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                SecureField("hf_...", text: $hfTokenInput)
                    .textFieldStyle(.roundedBorder)

                Button(String(localized: "Save", bundle: bundle)) {
                    validateAndSaveHuggingFaceToken()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(trimmedHfTokenInput.isEmpty || isValidatingToken)

                if hasStoredHfToken {
                    Button(String(localized: "Remove", bundle: bundle)) {
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
                    Text("Validating token...", bundle: bundle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let result = tokenValidationResult {
                HStack(spacing: 4) {
                    Image(systemName: result ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result ? .green : .red)
                    Text(result
                        ? String(localized: "Valid HuggingFace Token", bundle: bundle)
                        : String(localized: "Invalid HuggingFace Token", bundle: bundle))
                        .font(.caption)
                        .foregroundStyle(result ? .green : .red)
                }
            }
        }
    }

    // MARK: - Model List Section

    private var modelListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Model", bundle: bundle)
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(displayableModels) { modelDef in
                modelRow(modelDef)
            }

            Text("Gemma 4 E2B/E4B 4-bit models are recommended. Larger variants are experimental and may fail depending on hardware.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

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
                Text("Gemma Model Catalog", bundle: bundle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("(Gemma/MLXVLM-compatible mlx-community models)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Browse Gemma and MLXVLM-compatible models live from Hugging Face. Gemma 4 E2B/E4B 4-bit models are recommended; other variants are experimental. Added models appear in the model list above.", bundle: bundle)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(String(localized: "Search Gemma models", bundle: bundle), text: $catalogQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit { refreshCatalog() }

                Button {
                    refreshCatalog()
                } label: {
                    if isCatalogLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(String(localized: "Refresh", bundle: bundle), systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isCatalogLoading)
            }

            if catalogEntries.isEmpty && !isCatalogLoading {
                Text("No catalog loaded yet. Press Refresh to fetch the current model list.", bundle: bundle)
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

            // Manual fallback for repos not in the list
            HStack(spacing: 8) {
                TextField("Repo ID (Gemma/MLXVLM-compatible)", text: $manualRepoInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button(String(localized: "Add", bundle: bundle)) {
                    addRepo(manualRepoInput)
                    manualRepoInput = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(manualRepoInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Only add Gemma/MLXVLM-compatible repositories here. Use Local Models for other MLX architectures. Use a HuggingFace token if the repo is gated.", bundle: bundle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func catalogRow(_ entry: Gemma4Plugin.Gemma4CatalogEntry) -> some View {
        let added = plugin.isUserModelRepoAdded(entry.id)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.id.replacingOccurrences(of: "mlx-community/", with: ""))
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if entry.isRecommended {
                        Text("Recommended", bundle: bundle)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green, in: Capsule())
                    } else {
                        Text("Experimental", bundle: bundle)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
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
                Label(String(localized: "Added", bundle: bundle), systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(String(localized: "Add", bundle: bundle)) {
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
    private func modelRow(_ modelDef: Gemma4ModelDef) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(modelDef.displayName)
                        .font(.body)
                    if modelDef.isCustom {
                        Text("Custom")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.blue, in: Capsule())
                    }
                }
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
                    Button(String(localized: "Cancel", bundle: bundle)) { cancelCurrentLoad() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if case .loading = modelState, selectedModelId == modelDef.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "Cancel", bundle: bundle)) { cancelCurrentLoad() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if case .ready(let loadedId) = modelState, loadedId == modelDef.id {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Button(String(localized: "Unload", bundle: bundle)) { resetCachedModel(modelDef) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            } else if isRecoverableCachedModelError(for: modelDef) {
                Button(String(localized: "Delete cached model", bundle: bundle)) { resetCachedModel(modelDef) }
                    .buttonStyle(.bordered).controlSize(.small)
            } else if let warning = modelDef.experimentalWarning {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Experimental", bundle: bundle)
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.orange)
                    Text(LocalizedStringKey(warning), bundle: bundle)
                        .font(.caption2).foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 220, alignment: .trailing)
                    Button(String(localized: "Try anyway", bundle: bundle)) { startLoading(modelDef) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(modelState == .downloading || modelState == .loading)
                }
            } else {
                HStack(spacing: 8) {
                    Button(String(localized: "Download & Load", bundle: bundle)) { startLoading(modelDef) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(modelState == .downloading || modelState == .loading)
                    if modelDef.isCustom {
                        Button(String(localized: "Remove", bundle: bundle)) { removeUserModel(modelDef) }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(modelState == .downloading || modelState == .loading)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func syncFromPlugin() {
        modelState = plugin.modelState
        selectedModelId = plugin.selectedLLMModelId ?? Gemma4Plugin.availableModels.first?.id ?? ""
        llmTemperatureMode = plugin.llmTemperatureMode
        generationTemperature = plugin.generationTemperature
        downloadProgress = plugin.currentDownloadProgress
        if let token = plugin.huggingFaceToken, !token.isEmpty { hfTokenInput = token }

        // Model catalog cache (offline display until refreshed)
        catalogEntries = plugin.cachedCatalog

        // Advanced settings
        let storedMaxTokens = plugin.resolvedMaxTokens
        if storedMaxTokens != Gemma4Plugin.promptMaxTokens {
            useCustomMaxTokens = true
            maxTokensValue = Double(storedMaxTokens)
        }
        if let storedPrefill = plugin.customPrefillStepSize {
            useCustomPrefill = true
            prefillStepSizeValue = storedPrefill
        }
    }

    private func refreshCatalog() {
        let query = catalogQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        isCatalogLoading = true
        Task {
            let entries = await plugin.discoverCatalog(query: query.isEmpty ? "gemma" : query)
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

    private func removeUserModel(_ modelDef: Gemma4ModelDef) {
        plugin.removeUserModel(repoId: modelDef.repoId)
        userModelsVersion += 1
        modelState = plugin.modelState
        selectedModelId = plugin.selectedLLMModelId ?? Gemma4Plugin.availableModels.first?.id ?? ""
    }

    private func isRecoverableCachedModelError(for modelDef: Gemma4ModelDef) -> Bool {
        if case .error = modelState,
           selectedModelId == modelDef.id,
           plugin.isModelDownloaded(modelDef) {
            return true
        }
        return false
    }

    private func resetCachedModel(_ modelDef: Gemma4ModelDef) {
        loadTask?.cancel()
        loadTask = nil
        isPolling = false
        plugin.resetCachedModel(modelDef)
        modelState = plugin.modelState
        downloadProgress = plugin.currentDownloadProgress
    }

    private func startLoading(_ modelDef: Gemma4ModelDef) {
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
