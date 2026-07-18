import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @ObservedObject private var viewModel = APIServerViewModel.shared
    @ObservedObject private var memoryService = ServiceContainer.shared.memoryService
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var speechFeedbackService = ServiceContainer.shared.speechFeedbackService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var errorLogService = ServiceContainer.shared.errorLogService
    @State private var cliInstalled = false
    @State private var cliSymlinkTarget = ""
    @State private var raycastInstalled = false
    @State private var showClearMemoryConfirmation = false
    @State private var showDiagnosticsExportError = false
    @State private var diagnosticsExportErrorMessage = ""
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var showImportAlert = false
    @State private var importAlertMessage = ""
    @State private var importAlertIsError = false
    @State private var showImportPicker = false

    @AppStorage(UserDefaultsKeys.historyEnabled) private var historyEnabled: Bool = true
    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays: Int = 0
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var saveAudioWithHistory: Bool = false
    @AppStorage(UserDefaultsKeys.graphExtractionProvider) private var graphExtractionProvider: String = ""
    @AppStorage(UserDefaultsKeys.graphExtractionModel) private var graphExtractionModel: String = ""
    @AppStorage(UserDefaultsKeys.graphAutoExtract) private var graphAutoExtract: Bool = false

    var body: some View {
        Form {
            // MARK: - Support Diagnostics
            Section(localizedAppText("Support Diagnostics", de: "Support-Diagnose")) {
                Button {
                    exportDiagnostics()
                } label: {
                    Label(
                        localizedAppText("Export Diagnostics", de: "Diagnose exportieren"),
                        systemImage: "square.and.arrow.up"
                    )
                }

                Text(localizedAppText(
                    "Creates a JSON support report with app, system, permission, plugin, settings and audio device diagnostics.",
                    de: "Erstellt einen JSON-Supportbericht mit App-, System-, Berechtigungs-, Plugin-, Einstellungs- und Audiogeräte-Diagnose."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // MARK: - Settings Backup
            Section(localizedAppText("Settings Backup", de: "Einstellungen sichern")) {
                Button {
                    exportSettings()
                } label: {
                    Label(
                        localizedAppText("Export Settings…", de: "Einstellungen exportieren …"),
                        systemImage: "square.and.arrow.up"
                    )
                }

                Text(localizedAppText(
                    "Saves dictionary, snippets, workflows and profiles as a JSON file.",
                    de: "Sichert Wörterbuch, Snippets, Workflows und Profile als JSON-Datei."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    showImportPicker = true
                } label: {
                    Label(
                        localizedAppText("Import Settings…", de: "Einstellungen importieren …"),
                        systemImage: "square.and.arrow.down"
                    )
                }

                Text(localizedAppText(
                    "Restores previously exported settings. Existing entries are preserved, duplicates are skipped.",
                    de: "Stellt zuvor exportierte Einstellungen wieder her. Vorhandene Einträge bleiben erhalten, Duplikate werden übersprungen."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            // MARK: - Memory
            Section(String(localized: "Memory")) {
                Toggle(String(localized: "Enable Memory"), isOn: $memoryService.isEnabled)
                Text(String(localized: "Automatically extracts facts, preferences and patterns from your transcriptions using an LLM. Memories are injected into prompt context."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if memoryService.isEnabled {
                    Picker(String(localized: "Capture From"), selection: $memoryService.captureScope) {
                        ForEach(MemoryCaptureScope.allCases) { scope in
                            Text(scope.localizedTitle).tag(scope)
                        }
                    }
                    Text(memoryService.captureScope.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(String(localized: "Extraction Provider"), selection: $memoryService.extractionProviderId) {
                        Text(String(localized: "None")).tag("")
                        ForEach(promptProcessingService.availableProviders, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }

                    if !memoryService.extractionProviderId.isEmpty {
                        let models = promptProcessingService.modelsForProvider(memoryService.extractionProviderId)
                        if !models.isEmpty {
                            Picker(String(localized: "Extraction Model"), selection: $memoryService.extractionModel) {
                                Text(String(localized: "Default")).tag("")
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                        }
                    }

                    Stepper(value: $memoryService.minimumTextLength, in: 10...200, step: 10) {
                        HStack {
                            Text(String(localized: "Min. text length"))
                            Spacer()
                            Text("\(memoryService.minimumTextLength)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(String(localized: "Transcriptions shorter than this are skipped for memory extraction."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    DisclosureGroup(String(localized: "Extraction Prompt")) {
                        TextEditor(text: $memoryService.extractionPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                            .border(.separator)

                        Button(String(localized: "Reset to Default")) {
                            memoryService.extractionPrompt = MemoryService.defaultExtractionPrompt
                        }
                        .font(.caption)
                    }

                    let pluginCount = PluginManager.shared.memoryStoragePlugins.count
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(pluginCount > 0 && !memoryService.extractionProviderId.isEmpty ? .green : .orange)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        if pluginCount == 0 {
                            Text(String(localized: "No memory storage plugins active. Enable one in Integrations."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if memoryService.extractionProviderId.isEmpty {
                            Text(String(localized: "Select an extraction provider to start collecting memories."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "\(pluginCount) storage plugin(s) active"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showClearMemoryConfirmation = true
                    } label: {
                        Label(String(localized: "Clear All Memories"), systemImage: "trash")
                    }
                    .confirmationDialog(
                        String(localized: "Clear All Memories?"),
                        isPresented: $showClearMemoryConfirmation
                    ) {
                        Button(String(localized: "Clear All"), role: .destructive) {
                            Task { await memoryService.clearAllMemories() }
                        }
                    } message: {
                        Text(String(localized: "This will permanently delete all stored memories from all plugins. This cannot be undone."))
                    }
                }
            }

            // MARK: - Knowledge Graph (GraphRAG)
            if !pluginManager.graphStoragePlugins.isEmpty {
                Section(localizedAppText("Knowledge Graph (GraphRAG)", de: "Wissensgraph (GraphRAG)")) {
                    Text(localizedAppText(
                        "Choose which LLM turns imported documents into knowledge-graph entities and relations. Configure the graph connection itself under Integrations.",
                        de: "Wähle, welches LLM importierte Dokumente in Wissensgraph-Entitäten und -Beziehungen umwandelt. Die Graph-Verbindung selbst wird unter Integrationen konfiguriert."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Picker(localizedAppText("Extraction Provider", de: "Extraktions-Anbieter"), selection: $graphExtractionProvider) {
                        Text(localizedAppText("None", de: "Keiner")).tag("")
                        ForEach(promptProcessingService.availableProviders, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }

                    if !graphExtractionProvider.isEmpty {
                        let models = promptProcessingService.modelsForProvider(graphExtractionProvider)
                        if !models.isEmpty {
                            Picker(localizedAppText("Extraction Model", de: "Extraktions-Modell"), selection: $graphExtractionModel) {
                                Text(localizedAppText("Default", de: "Standard")).tag("")
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                        }
                    }

                    Toggle(localizedAppText("Auto-extract on import", de: "Automatisch beim Import extrahieren"), isOn: $graphAutoExtract)
                    Text(localizedAppText(
                        "Runs extraction automatically after every document import. Costs several LLM calls per document and can be slow with local models — manual extraction from the Library is recommended instead.",
                        de: "Führt die Extraktion automatisch nach jedem Dokument-Import aus. Kostet mehrere LLM-Aufrufe pro Dokument und kann mit lokalen Modellen langsam sein — die manuelle Extraktion in der Bibliothek wird stattdessen empfohlen."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            // MARK: - Recording
            Section(String(localized: "Recording")) {
                Picker(String(localized: "Auto-unload model"), selection: Binding(
                    get: { modelManager.autoUnloadSeconds },
                    set: { modelManager.autoUnloadSeconds = $0 }
                )) {
                    Text(String(localized: "Never")).tag(0)
                    Divider()
                    Text(String(localized: "Immediate")).tag(-1)
                    Text(String(localized: "After 2 minutes")).tag(120)
                    Text(String(localized: "After 5 minutes")).tag(300)
                    Text(String(localized: "After 10 minutes")).tag(600)
                    Text(String(localized: "After 30 minutes")).tag(1800)
                    Text(String(localized: "After 1 hour")).tag(3600)
                }

                Text(String(localized: "Automatically unloads local models from memory after inactivity. It reloads when needed. Does not affect cloud engines."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    String(localized: "Transcribe short / quiet clips more aggressively"),
                    isOn: $dictation.transcribeShortQuietClipsAggressively
                )

                Text(String(localized: "Still discards accidental ultra-short taps, but keeps more very short or quiet recordings instead of classifying them as no speech."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    localizedAppText("Whisper Mode (AGC)", de: "Whisper-Modus (AGC)"),
                    isOn: $dictation.microphoneBoostEnabled
                )

                Text(localizedAppText(
                    "Automatically raises quiet microphone input before transcription. Useful for low-gain microphones, but very noisy rooms may sound louder too.",
                    de: "Hebt leise Mikrofoneingaben vor der Transkription automatisch an. Hilft bei Mikrofonen mit niedrigem Pegel, kann in lauten Räumen aber auch Störgeräusche verstärken."
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if speechFeedbackService.hasAvailableProviders {
                    Toggle(String(localized: "Spoken feedback"), isOn: $dictation.spokenFeedbackEnabled)

                    Text(String(localized: "Reads back the final transcribed text after each dictation using the selected speech provider. Recording, error, and prompt announcements are only spoken through VoiceOver accessibility announcements."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if dictation.spokenFeedbackEnabled {
                        let providerSelection = Binding(
                            get: { speechFeedbackService.effectiveProviderId ?? speechFeedbackService.selectedProviderId },
                            set: { speechFeedbackService.selectedProviderId = $0 }
                        )

                        Picker(String(localized: "Speech Provider"), selection: providerSelection) {
                            ForEach(speechFeedbackService.availableProviders, id: \.id) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }

                        if let summary = speechFeedbackService.currentSettingsSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let activeProviderId = speechFeedbackService.effectiveProviderId,
                           let plugin = pluginManager.loadedTTSPlugin(for: activeProviderId),
                           plugin.instance.settingsView != nil {
                            Button(String(localized: "Configure Voice & Speed…")) {
                                PluginSettingsWindowManager.shared.present(plugin)
                            }
                        }
                    }
                }
            }

            SpokenPunctuationSettingsSection()

            // MARK: - History
            Section(String(localized: "History")) {
                Toggle(String(localized: "Save history"), isOn: $historyEnabled)
                Text(String(localized: "Saves transcriptions to the history tab."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if historyEnabled {
                    Toggle(String(localized: "Save audio with transcriptions"), isOn: $saveAudioWithHistory)
                    Text(String(localized: "Stores a WAV recording alongside each transcription. Uses approximately 1 MB per 30 seconds."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker(String(localized: "Auto-delete after"), selection: $historyRetentionDays) {
                        Text(String(localized: "Unlimited")).tag(0)
                        Text(String(localized: "30 days")).tag(30)
                        Text(String(localized: "60 days")).tag(60)
                        Text(String(localized: "90 days")).tag(90)
                        Text(String(localized: "180 days")).tag(180)
                    }
                    Text(String(localized: "Older entries are automatically removed at app launch."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - API Server
            Section(String(localized: "API Server")) {
                Toggle(String(localized: "Enable API Server"), isOn: $viewModel.isEnabled)
                    .onChange(of: viewModel.isEnabled) { _, enabled in
                        if enabled {
                            viewModel.startServer()
                        } else {
                            viewModel.stopServer()
                        }
                    }

                Text(String(localized: "Advanced automation interface for local tools. Disabled by default and bound to 127.0.0.1 only."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(String(localized: "Require API Token"), isOn: $viewModel.requiresAuthentication)

                Text(String(localized: "Off by default for compatibility with existing local integrations. New clients can use api-discovery.json or send the bearer token."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.isEnabled {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(viewModel.isRunning ? .green : .orange)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(viewModel.isRunning
                             ? String(localized: "Running on port \(String(viewModel.port))")
                             : String(localized: "Not running"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }

            // MARK: - Command Line Tool
            Section(String(localized: "Command Line Tool")) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(cliInstalled ? .green : .orange)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    if cliInstalled {
                        Text(String(localized: "Installed at /usr/local/bin/sprachhilfe"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Not installed"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if cliInstalled {
                    Button(String(localized: "Uninstall")) {
                        uninstallCLI()
                    }
                } else {
                    Button(String(localized: "Install Command Line Tool")) {
                        installCLI()
                    }
                }

                Text(String(localized: "Requires the API server to be running. The CLI tool connects to Sprachhilfe's API for fast transcription without model cold starts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Usage Examples
            if viewModel.isEnabled {
                Section(String(localized: "Usage Examples")) {
                    if cliInstalled {
                        cliExamples
                    } else {
                        curlExamples
                    }
                }
            }

            // MARK: - Integrations
            Section(String(localized: "Integrations")) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "command.square")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Raycast Extension"))
                            .font(.headline)

                        if raycastInstalled {
                            Text(String(localized: "Raycast is installed. You can connect a custom Raycast extension to Sprachhilfe's local API."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "Sprachhilfe's local API can be connected to a custom Raycast extension."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if raycastInstalled {
                            Button(String(localized: "Open API Documentation")) {
                                NSWorkspace.shared.open(URL(string: "https://github.com/tamaga3131400/sprachhilfe-source#http-api")!)
                            }
                        } else {
                            Button(String(localized: "Learn More")) {
                                NSWorkspace.shared.open(URL(string: "https://github.com/tamaga3131400/sprachhilfe-source#http-api")!)
                            }
                        }

                        Text(String(localized: "Requires the API server to be running."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            raycastInstalled = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.raycast.macos"
            ) != nil
            checkCLIInstallation()
            syncSpeechFeedbackAvailability()
        }
        .onReceive(pluginManager.$loadedPlugins) { _ in
            syncSpeechFeedbackAvailability()
        }
        .alert(localizedAppText("Export Failed", de: "Export fehlgeschlagen"), isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .alert(localizedAppText("Export Failed", de: "Export fehlgeschlagen"), isPresented: $showDiagnosticsExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsExportErrorMessage)
        }
        .alert(importAlertIsError
            ? localizedAppText("Import Failed", de: "Import fehlgeschlagen")
            : localizedAppText("Import Complete", de: "Import abgeschlossen"),
               isPresented: $showImportAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importAlertMessage)
        }
        .fileImporter(isPresented: $showImportPicker, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                importSettings(from: url)
            }
        }
    }

    // MARK: - Examples

    private var cliExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Show help:"), "sprachhilfe --help")
            Divider()
            exampleRow(String(localized: "Check status:"), "sprachhilfe status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "sprachhilfe transcribe audio.wav")
            Divider()
            exampleRow(String(localized: "Transcribe with language:"), "sprachhilfe transcribe audio.wav --language de")
            Divider()
            exampleRow(String(localized: "JSON output:"), "sprachhilfe transcribe audio.wav --json")
            Divider()
            exampleRow(String(localized: "Pipe to clipboard:"), "sprachhilfe transcribe audio.wav | pbcopy")
            Divider()
            exampleRow(String(localized: "List models:"), "sprachhilfe models")
        }
    }

    private var curlExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Check status:"), "curl http://127.0.0.1:\(viewModel.port)/v1/status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "curl -X POST http://127.0.0.1:\(viewModel.port)/v1/transcribe \\\n  -F \"file=@audio.wav\"")
            Divider()
            exampleRow(String(localized: "List models:"), "curl http://127.0.0.1:\(viewModel.port)/v1/models")
        }
    }

    private func exampleRow(_ label: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy"))
            }
        }
    }

    // MARK: - Support Diagnostics

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = localizedAppText("Export Diagnostics", de: "Diagnose exportieren")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = diagnosticsFilename()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await errorLogService.exportDiagnostics(to: url)
                } catch {
                    diagnosticsExportErrorMessage = error.localizedDescription
                    showDiagnosticsExportError = true
                }
            }
        }
    }

    private func diagnosticsFilename() -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "sprachhilfe-diagnostics-\(timestamp).json"
    }

    // MARK: - CLI Installation

    private static let symlinkPath = "/usr/local/bin/sprachhilfe"

    private var cliBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sprachhilfe-cli").path
    }

    private func checkCLIInstallation() {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: Self.symlinkPath) else {
            cliInstalled = false
            return
        }
        cliSymlinkTarget = dest
        cliInstalled = dest == cliBinaryPath
    }

    private func installCLI() {
        let target = cliBinaryPath
        let link = Self.symlinkPath
        let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf '\(target)' '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func uninstallCLI() {
        let link = Self.symlinkPath
        let script = """
            do shell script "rm -f '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func runOsascript(_ source: String, completion: @escaping @MainActor @Sendable () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.terminationHandler = { _ in
            Task { @MainActor in completion() }
        }
        try? process.run()
    }

    private func syncSpeechFeedbackAvailability() {
        guard !speechFeedbackService.hasAvailableProviders else { return }
        if dictation.spokenFeedbackEnabled {
            dictation.spokenFeedbackEnabled = false
        } else {
            _ = speechFeedbackService.disableIfNoProvidersAvailable()
        }
    }

    // MARK: - Settings Export/Import

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.title = localizedAppText("Export Settings", de: "Einstellungen exportieren")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "sprachhilfe-settings-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try buildExportData()
                try data.write(to: url, options: .atomic)
            } catch {
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
        }
    }

    private func buildExportData() throws -> Data {
        let container = ServiceContainer.shared
        let dictEntries = container.dictionaryService.entries.map { entry in
            ExportDictionaryEntry(
                type: entry.type.rawValue,
                original: entry.original,
                replacement: entry.replacement,
                caseSensitive: entry.caseSensitive,
                isEnabled: entry.isEnabled
            )
        }
        let snips = container.snippetService.snippets.map { snippet in
            ExportSnippet(
                trigger: snippet.trigger,
                replacement: snippet.replacement,
                caseSensitive: snippet.caseSensitive,
                isEnabled: snippet.isEnabled
            )
        }
        let wfs = container.workflowService.workflows.map { workflow in
            ExportWorkflow(
                name: workflow.name,
                template: workflow.templateRaw,
                triggerKindRaw: workflow.triggerKindRaw,
                triggerAppBundleIdentifier: workflow.triggerAppBundleIdentifier,
                triggerWebsitePattern: workflow.triggerWebsitePattern,
                isEnabled: workflow.isEnabled
            )
        }
        let profs = container.profileService.profiles.map { profile in
            ExportProfile(
                name: profile.name,
                isEnabled: profile.isEnabled,
                bundleIdentifiers: profile.bundleIdentifiers,
                urlPatterns: profile.urlPatterns,
                inputLanguage: profile.inputLanguage,
                translationEnabled: profile.translationEnabled,
                translationTargetLanguage: profile.translationTargetLanguage,
                selectedTask: profile.selectedTask,
                engineOverride: profile.engineOverride,
                cloudModelOverride: profile.cloudModelOverride,
                promptActionId: profile.promptActionId,
                memoryEnabled: profile.memoryEnabled,
                outputFormat: profile.outputFormat,
                autoEnterEnabled: profile.autoEnterEnabled
            )
        }

        let export = ExportData(
            appVersion: AppConstants.appVersion,
            exportDate: Date(),
            dictionary: dictEntries,
            snippets: snips,
            workflows: wfs,
            profiles: profs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }

    private func importSettings(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            importAlertMessage = String(localized: "Cannot access the selected file.")
            importAlertIsError = true
            showImportAlert = true
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let export = try decoder.decode(ExportData.self, from: data)

            var dictCount = 0, snipCount = 0, wfCount = 0, profCount = 0
            let container = ServiceContainer.shared

            if !export.dictionary.isEmpty {
                let items = export.dictionary.map { entry in
                    (type: DictionaryEntryType(rawValue: entry.type) ?? .term,
                     original: entry.original,
                     replacement: entry.replacement,
                     caseSensitive: entry.caseSensitive,
                     isEnabled: entry.isEnabled)
                }
                container.dictionaryService.importEntries(items)
                dictCount = items.count
            }

            if !export.snippets.isEmpty {
                for snip in export.snippets {
                    container.snippetService.addSnippet(
                        trigger: snip.trigger,
                        replacement: snip.replacement,
                        caseSensitive: snip.caseSensitive
                    )
                }
                snipCount = export.snippets.count
            }

            if !export.workflows.isEmpty {
                for wf in export.workflows {
                    let trigger = WorkflowTrigger(kind: WorkflowTriggerKind(rawValue: wf.triggerKindRaw) ?? .manual)
                    container.workflowService.addWorkflow(
                        name: wf.name,
                        template: WorkflowTemplate(rawValue: wf.template) ?? .dictation,
                        trigger: trigger,
                        isEnabled: wf.isEnabled
                    )
                }
                wfCount = export.workflows.count
            }

            if !export.profiles.isEmpty {
                for prof in export.profiles {
                    container.profileService.addProfile(
                        name: prof.name,
                        isEnabled: prof.isEnabled,
                        bundleIdentifiers: prof.bundleIdentifiers,
                        urlPatterns: prof.urlPatterns,
                        inputLanguage: prof.inputLanguage,
                        translationEnabled: prof.translationEnabled,
                        translationTargetLanguage: prof.translationTargetLanguage,
                        selectedTask: prof.selectedTask,
                        engineOverride: prof.engineOverride,
                        cloudModelOverride: prof.cloudModelOverride,
                        promptActionId: prof.promptActionId,
                        memoryEnabled: prof.memoryEnabled,
                        outputFormat: prof.outputFormat,
                        autoEnterEnabled: prof.autoEnterEnabled
                    )
                }
                profCount = export.profiles.count
            }

            let total = dictCount + snipCount + wfCount + profCount
            importAlertMessage = String(localized: "Imported \(total) items (\(dictCount) dictionary, \(snipCount) snippets, \(wfCount) workflows, \(profCount) profiles).")
            importAlertIsError = false
        } catch {
            importAlertMessage = error.localizedDescription
            importAlertIsError = true
        }
        showImportAlert = true
    }
}

// MARK: - Export Data Types

private struct ExportData: Codable {
    let appVersion: String
    let exportDate: Date
    let dictionary: [ExportDictionaryEntry]
    let snippets: [ExportSnippet]
    let workflows: [ExportWorkflow]
    let profiles: [ExportProfile]
}

private struct ExportDictionaryEntry: Codable {
    let type: String
    let original: String
    let replacement: String?
    let caseSensitive: Bool
    let isEnabled: Bool
}

private struct ExportSnippet: Codable {
    let trigger: String
    let replacement: String
    let caseSensitive: Bool
    let isEnabled: Bool
}

private struct ExportWorkflow: Codable {
    let name: String
    let template: String
    let triggerKindRaw: String
    let triggerAppBundleIdentifier: String?
    let triggerWebsitePattern: String?
    let isEnabled: Bool
}

private struct ExportProfile: Codable {
    let name: String
    let isEnabled: Bool
    let bundleIdentifiers: [String]
    let urlPatterns: [String]
    let inputLanguage: String?
    let translationEnabled: Bool?
    let translationTargetLanguage: String?
    let selectedTask: String?
    let engineOverride: String?
    let cloudModelOverride: String?
    let promptActionId: String?
    let memoryEnabled: Bool
    let outputFormat: String?
    let autoEnterEnabled: Bool
}
