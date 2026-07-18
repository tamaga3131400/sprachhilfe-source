import SwiftUI
import AppKit
import SprachhilfePluginSDK

enum SettingsTab: Hashable {
    case home, general, recording, hotkeys, recorder
    case dictationRecovery, fileTranscription, watchFolder, history, dictionary, snippets, workflows, profiles, prompts, integrations, chat, library, advanced, about
}

private struct SettingsDestination: Identifiable, Hashable {
    let tab: SettingsTab
    let title: String
    let systemImage: String
    let badge: Int?

    var id: SettingsTab { tab }
}

private struct SettingsDestinationSection: Identifiable {
    let id: String
    let destinations: [SettingsDestination]
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home
    @ObservedObject private var fileTranscription = FileTranscriptionViewModel.shared
    @ObservedObject private var dictationRecovery = DictationRecoveryViewModel.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var homeViewModel = HomeViewModel.shared
    @ObservedObject private var promptActionsViewModel = PromptActionsViewModel.shared
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared

    private var destinations: [SettingsDestination] {
        [
            SettingsDestination(tab: .home, title: String(localized: "Home"), systemImage: "house", badge: nil),
            SettingsDestination(tab: .general, title: String(localized: "General"), systemImage: "gear", badge: nil),
            SettingsDestination(tab: .recording, title: String(localized: "Recording"), systemImage: "mic.fill", badge: nil),
            SettingsDestination(tab: .hotkeys, title: String(localized: "Hotkeys"), systemImage: "keyboard", badge: nil),
            SettingsDestination(
                tab: .recorder,
                title: String(localized: "settings.tab.recorder"),
                systemImage: "waveform.circle",
                badge: nil
            ),
            dictationRecovery.hasRecoveryContent
                ? SettingsDestination(
                    tab: .dictationRecovery,
                    title: localizedAppText("Recovery", de: "Wiederherstellung"),
                    systemImage: "waveform",
                    badge: nil
                )
                : nil,
            SettingsDestination(tab: .fileTranscription, title: String(localized: "File Transcription"), systemImage: "doc.text", badge: nil),
            SettingsDestination(tab: .watchFolder, title: localizedAppText("Watch Folder", de: "Überwachter Ordner"), systemImage: "folder.badge.gearshape", badge: nil),
            SettingsDestination(tab: .history, title: String(localized: "History"), systemImage: "clock.arrow.circlepath", badge: nil),
            SettingsDestination(tab: .dictionary, title: String(localized: "Dictionary"), systemImage: "book.closed", badge: nil),
            SettingsDestination(tab: .snippets, title: String(localized: "Snippets"), systemImage: "text.badge.plus", badge: nil),
            SettingsDestination(
                tab: .workflows,
                title: localizedAppText("Workflows", de: "Workflows"),
                systemImage: "point.3.connected.trianglepath.dotted",
                badge: nil
            ),
            SettingsDestination(
                tab: .integrations,
                title: String(localized: "Integrations"),
                systemImage: "puzzlepiece.extension",
                badge: registryService.availableUpdatesCount > 0 ? registryService.availableUpdatesCount : nil
            ),
            SettingsDestination(
                tab: .chat,
                title: localizedAppText("Chat", de: "Chat"),
                systemImage: "bubble.left.and.bubble.right",
                badge: nil
            ),
            SettingsDestination(
                tab: .library,
                title: localizedAppText("Knowledge", de: "Wissen"),
                systemImage: "books.vertical",
                badge: nil
            ),
            SettingsDestination(tab: .advanced, title: String(localized: "Advanced"), systemImage: "gearshape.2", badge: nil),
            SettingsDestination(tab: .about, title: String(localized: "About"), systemImage: "info.circle", badge: nil)
        ].compactMap { $0 }
    }

    private var destinationSections: [SettingsDestinationSection] {
        settingsDestinationSections(destinations)
    }

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                SettingsModernShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: { tab in AnyView(settingsDetail(for: tab)) }
                )
            } else {
                SettingsSidebarShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: settingsDetail(for:)
                )
            }
        }
        .frame(minWidth: 950, idealWidth: 1050, minHeight: 550, idealHeight: 600)
        .onAppear {
            navigateToFileTranscriptionIfNeeded()
            navigateAwayFromMissingRecoveryIfNeeded()
        }
        .onChange(of: fileTranscription.showFilePickerFromMenu) { _, _ in
            navigateToFileTranscriptionIfNeeded()
        }
        .onChange(of: dictationRecovery.hasRecovery) { _, _ in
            navigateAwayFromMissingRecoveryIfNeeded()
        }
        .onChange(of: dictationRecovery.lastSavedHistoryRecordID) { _, _ in
            navigateAwayFromMissingRecoveryIfNeeded()
        }
        .onChange(of: homeViewModel.navigateToHistory) { _, navigate in
            if navigate {
                selectedTab = .history
                homeViewModel.navigateToHistory = false
            }
        }
        .onChange(of: promptActionsViewModel.navigateToIntegrations) { _, navigate in
            if navigate {
                selectedTab = .integrations
                promptActionsViewModel.navigateToIntegrations = false
            }
        }
        .onReceive(settingsNavigation.$request.compactMap { $0 }) { request in
            switch request.tab {
            case .profiles, .prompts, .workflows:
                selectedTab = .workflows
                WorkflowsNavigationCoordinator.shared.showMine()
            default:
                selectedTab = Self.availableTab(request.tab, hasRecoveryContent: dictationRecovery.hasRecoveryContent)
            }
        }
    }

    static func availableTab(_ tab: SettingsTab, hasRecoveryContent: Bool) -> SettingsTab {
        tab == .dictationRecovery && !hasRecoveryContent ? .recording : tab
    }

    private func navigateToFileTranscriptionIfNeeded() {
        if fileTranscription.showFilePickerFromMenu {
            selectedTab = .fileTranscription
        }
    }

    private func navigateAwayFromMissingRecoveryIfNeeded() {
        selectedTab = Self.availableTab(selectedTab, hasRecoveryContent: dictationRecovery.hasRecoveryContent)
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .home:
            HomeSettingsView()
        case .general:
            GeneralSettingsView()
        case .recording:
            RecordingSettingsView()
        case .hotkeys:
            HotkeySettingsView()
        case .recorder:
            AudioRecorderView(viewModel: AudioRecorderViewModel.shared)
        case .dictationRecovery:
            DictationRecoveryView()
        case .fileTranscription:
            FileTranscriptionView()
        case .watchFolder:
            WatchFolderSettingsView()
        case .history:
            HistoryView()
        case .dictionary:
            DictionarySettingsView()
        case .snippets:
            SnippetsSettingsView()
        case .workflows:
            WorkflowsSettingsView()
        case .profiles:
            WorkflowsSettingsView()
        case .prompts:
            WorkflowsSettingsView()
        case .integrations:
            PluginSettingsView()
        case .chat:
            ChatView(viewModel: ServiceContainer.shared.chatViewModel)
        case .library:
            LibraryView(viewModel: ServiceContainer.shared.libraryViewModel)
        case .advanced:
            AdvancedSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

@available(macOS 15, *)
private struct SettingsModernShell: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> AnyView

    @State private var sidebarSearchText = ""

    private var filteredSections: [SettingsDestinationSection] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }

        return sections
            .map { section in
                SettingsDestinationSection(
                    id: section.id,
                    destinations: section.destinations.filter { destination in
                        destination.title.localizedCaseInsensitiveContains(query)
                    }
                )
            }
            .filter { !$0.destinations.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.destinations) { destination in
                            SettingsSidebarRow(destination: destination)
                                .tag(destination.tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(
                text: $sidebarSearchText,
                placement: .sidebar,
                prompt: Text(localizedAppText("Search Settings", de: "Einstellungen durchsuchen"))
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func settingsDestination(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> SettingsDestination {
    destinations.first(where: { $0.tab == tab })!
}

private func settingsDestinationIfAvailable(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> SettingsDestination? {
    destinations.first(where: { $0.tab == tab })
}

private func settingsTitle(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> String {
    settingsDestination(destinations, tab).title
}

private func settingsSystemImage(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> String {
    settingsDestination(destinations, tab).systemImage
}

private func settingsBadge(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> Int? {
    settingsDestination(destinations, tab).badge
}

private func settingsDestinationSections(_ destinations: [SettingsDestination]) -> [SettingsDestinationSection] {
    var coreDestinations = [
        settingsDestination(destinations, .general),
        settingsDestination(destinations, .recording)
    ]
    if let recoveryDestination = settingsDestinationIfAvailable(destinations, .dictationRecovery) {
        coreDestinations.append(recoveryDestination)
    }
    coreDestinations.append(contentsOf: [
        settingsDestination(destinations, .hotkeys),
        settingsDestination(destinations, .fileTranscription),
        settingsDestination(destinations, .watchFolder),
        settingsDestination(destinations, .recorder)
    ])

    let workspaceDestinations = [
        settingsDestination(destinations, .history),
        settingsDestination(destinations, .dictionary),
        settingsDestination(destinations, .snippets),
        settingsDestination(destinations, .workflows),
        settingsDestination(destinations, .integrations),
        settingsDestination(destinations, .chat),
        settingsDestination(destinations, .library)
    ]

    return [
        SettingsDestinationSection(
            id: "home",
            destinations: [settingsDestination(destinations, .home)]
        ),
        SettingsDestinationSection(
            id: "core",
            destinations: coreDestinations
        ),
        SettingsDestinationSection(
            id: "workspace",
            destinations: workspaceDestinations
        ),
        SettingsDestinationSection(
            id: "system",
            destinations: [
                settingsDestination(destinations, .advanced),
                settingsDestination(destinations, .about)
            ]
        )
    ]
}

private struct SettingsSidebarShell<DetailContent: View>: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> DetailContent

    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                List(selection: $selectedTab) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.destinations) { destination in
                                SettingsSidebarRow(destination: destination)
                                    .tag(destination.tab)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)

                Divider()
            }

            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // macOS 14 glitches when the default NavigationSplitView sidebar reveal animates.
        // Use a custom zero-duration toggle instead.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .help(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
                .accessibilityLabel(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
            }
        }
    }

    private func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            withAnimation(nil) {
                isSidebarVisible.toggle()
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let destination: SettingsDestination

    var body: some View {
        HStack(spacing: 10) {
            Label(destination.title, systemImage: destination.systemImage)

            Spacer(minLength: 8)

            if let badge = destination.badge {
                SettingsSidebarBadge(title: destination.title, count: badge)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsSidebarBadge: View {
    let title: String
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tertiary, in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(title), \(count) updates")
    }
}

struct RecordingSettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var settings = SettingsViewModel.shared
    @State private var selectedProvider: String?
    @State private var customSounds: [String] = SoundChoice.installedCustomSounds()
    private let soundService = ServiceContainer.shared.soundService

    private var needsPermissions: Bool {
        dictation.needsMicPermission || dictation.needsAccessibilityPermission
    }

    private func transcriptionAuthNotice(for engines: [TranscriptionEnginePlugin]) -> String? {
        engines
            .map { modelManager.transcriptionAuthStatus(for: $0) }
            .first { !$0.isAvailable }?
            .unavailableReason
    }

    @ViewBuilder
    private func enginePickerLabel(for engine: TranscriptionEnginePlugin) -> some View {
        let authStatus = modelManager.transcriptionAuthStatus(for: engine)
        HStack {
            Text(engine.providerDisplayName)
            if !authStatus.isAvailable {
                Text("(\(String(localized: "unavailable")))")
                    .foregroundStyle(.secondary)
            } else if !engine.isConfigured {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        Form {
            if needsPermissions {
                PermissionsBanner(dictation: dictation)
            }

            Section(String(localized: "Engine")) {
                let engines = pluginManager.transcriptionEngines
                if engines.isEmpty {
                    Text(String(localized: "No transcription engines installed. Install engines via Integrations."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: "Default Engine"), selection: $selectedProvider) {
                        Text(String(localized: "None")).tag(nil as String?)
                        Divider()
                        ForEach(engines, id: \.providerId) { engine in
                            enginePickerLabel(for: engine)
                                .tag(engine.providerId as String?)
                                .disabled(!modelManager.canUseForTranscription(engine))
                        }
                    }
                    .onChange(of: selectedProvider) { _, newValue in
                        if let newValue {
                            modelManager.selectProvider(newValue)
                        }
                    }

                    if let notice = transcriptionAuthNotice(for: engines) {
                        Label(notice, systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let providerId = selectedProvider,
                       let engine = pluginManager.transcriptionEngine(for: providerId),
                       modelManager.canUseForTranscription(engine) {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: Binding(
                                get: { engine.selectedModelId },
                                set: { if let id = $0 { modelManager.selectModel(providerId, modelId: id) } }
                            )) {
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                        }
                    }

                }
            }

            Section(String(localized: "Task")) {
                Picker(String(localized: "Transcription Mode"), selection: $settings.selectedTask) {
                    ForEach(TranscriptionTask.allCases) { task in
                        Text(task.displayName).tag(task)
                    }
                }

                Text(String(localized: "Transcribe keeps the spoken language. Translate to English outputs English regardless of the source language."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Microphone")) {
                Picker(String(localized: "Input Device"), selection: $audioDevice.selectedDeviceUID) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(audioDevice.displayName(for: device)).tag(device.uid as String?)
                    }
                }

                if let message = audioDevice.selectedDeviceStatusMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                if audioDevice.isPreviewActive {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.quaternary)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.green.gradient)
                                    .frame(width: max(0, geo.size.width * CGFloat(audioDevice.previewAudioLevel)))
                                    .animation(.easeOut(duration: 0.08), value: audioDevice.previewAudioLevel)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)
                }

                Button(audioDevice.isPreviewActive
                    ? String(localized: "Stop Preview")
                    : String(localized: "Test Microphone")
                ) {
                    if audioDevice.isPreviewActive {
                        audioDevice.stopPreview()
                    } else {
                        audioDevice.startPreview()
                    }
                }
                .disabled(!audioDevice.isPreviewActive && dictation.needsMicPermission)

                if let error = audioDevice.previewError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                if let name = audioDevice.disconnectedDeviceName {
                    Label(
                        String(localized: "Microphone disconnected. Falling back to system default."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if audioDevice.disconnectedDeviceName == name {
                                audioDevice.disconnectedDeviceName = nil
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Sound")) {
                Toggle(String(localized: "Play sound feedback"), isOn: $dictation.soundFeedbackEnabled)

                if dictation.soundFeedbackEnabled {
                    SoundEventPicker(event: .recordingStarted, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .transcriptionSuccess, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .error, soundService: soundService, customSounds: $customSounds)
                }

                Text(String(localized: "Plays a sound when recording starts and when transcription completes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section(String(localized: "Clipboard")) {
                Toggle(String(localized: "Preserve clipboard content"), isOn: $dictation.preserveClipboard)

                Text(String(localized: "Restores your clipboard after text insertion. Without this, your clipboard contains the transcribed text after dictation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Output Formatting")) {
                Toggle(String(localized: "App-aware formatting"), isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled) },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.appFormattingEnabled) }
                ))

                Text(String(localized: "Automatically format transcribed text based on the target app. Configure the output format per workflow."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(String(localized: "Normalize spoken numbers to digits"), isOn: Binding(
                    get: { TranscriptionNormalizationService.numberNormalizationEnabled() },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) }
                ))

                Text(String(localized: "Converts spoken numbers in supported languages into digits before insertion and export."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Audio Ducking")) {
                Toggle(String(localized: "Reduce system volume during recording"), isOn: $dictation.audioDuckingEnabled)

                if dictation.audioDuckingEnabled {
                    HStack {
                        Image(systemName: "speaker.slash")
                            .foregroundStyle(.secondary)
                        Slider(value: $dictation.audioDuckingLevel, in: 0...0.5, step: 0.05)
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Percentage of your current volume to use during recording. 0% mutes completely."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(String(localized: "Media Pause")) {
                Toggle(String(localized: "Pause media playback during recording"), isOn: $dictation.mediaPauseEnabled)

                Text(String(localized: "Automatically pauses music and videos while recording and resumes when done. Uses macOS system media controls - may not work with all apps."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if needsPermissions {
                Section(String(localized: "Permissions")) {
                    if dictation.needsMicPermission {
                        HStack {
                            Label(
                                String(localized: "Microphone"),
                                systemImage: "mic.slash"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestMicPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if dictation.needsAccessibilityPermission {
                        HStack {
                            Label(
                                String(localized: "Accessibility"),
                                systemImage: "lock.shield"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            modelManager.restoreProviderSelection()
            selectedProvider = modelManager.selectedProviderId
            customSounds = SoundChoice.installedCustomSounds()
        }
    }

}

// MARK: - Sound Event Picker

private struct SoundEventPicker: View {
    let event: SoundEvent
    let soundService: SoundService
    @Binding var customSounds: [String]
    @State private var selection: String

    init(event: SoundEvent, soundService: SoundService, customSounds: Binding<[String]>) {
        self.event = event
        self.soundService = soundService
        self._customSounds = customSounds
        self._selection = State(initialValue: soundService.choice(for: event).storageKey)
    }

    var body: some View {
        HStack {
            Picker(event.displayName, selection: $selection) {
                Text(String(localized: "Default")).tag(event.defaultChoice.storageKey)

                Divider()

                ForEach(SoundChoice.bundledSounds, id: \.name) { sound in
                    Text(sound.displayName).tag(SoundChoice.bundled(sound.name).storageKey)
                }

                if !customSounds.isEmpty {
                    Divider()
                    ForEach(customSounds, id: \.self) { name in
                        Text(name).tag(SoundChoice.custom(name).storageKey)
                    }
                }

                Divider()

                ForEach(SoundChoice.systemSounds, id: \.self) { name in
                    Text(name).tag(SoundChoice.system(name).storageKey)
                }

                Divider()

                Text(String(localized: "None")).tag(SoundChoice.none.storageKey)
            }
            .onChange(of: selection) { _, newValue in
                let choice = SoundChoice(storageKey: newValue)
                soundService.updateChoice(for: event, choice: choice)
                soundService.preview(choice)
            }

            Button {
                soundService.preview(SoundChoice(storageKey: selection))
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Preview sound"))

            Button {
                importCustomSound()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Add custom sound"))
        }
    }

    private func importCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SoundChoice.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a sound file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let filename = try soundService.importCustomSound(from: url)
            customSounds = SoundChoice.installedCustomSounds()
            selection = SoundChoice.custom(filename).storageKey
        } catch {
            // File copy failed - silently ignore
        }
    }
}

// MARK: - Permissions Banner

struct PermissionsBanner: View {
    @ObservedObject var dictation: DictationViewModel

    var body: some View {
        Section {
            if dictation.needsMicPermission {
                HStack {
                    Label(
                        String(localized: "Microphone access required"),
                        systemImage: "mic.slash"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestMicPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        String(localized: "Accessibility access required"),
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

struct WatchFolderSettingsView: View {
    @ObservedObject private var watchFolder = WatchFolderViewModel.shared

    var body: some View {
        Form {
            Section(String(localized: "watchFolder.folders")) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "watchFolder.watchFolder"))
                            .font(.body)
                        if let path = watchFolder.watchFolderPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(String(localized: "watchFolder.noFolder"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(String(localized: "watchFolder.selectFolder")) {
                        watchFolder.selectWatchFolder()
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "watchFolder.outputFolder"))
                            .font(.body)
                        if let path = watchFolder.outputFolderPath {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text(String(localized: "watchFolder.outputFolder.sameAsWatch"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if watchFolder.outputFolderPath != nil {
                        Button {
                            watchFolder.clearOutputFolder()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(String(localized: "watchFolder.selectFolder")) {
                        watchFolder.selectOutputFolder()
                    }
                }
            }

            Section(localizedAppText("Watch Folder Transcription", de: "Ordner-Transkription")) {
                Picker(String(localized: "watchFolder.engine"), selection: $watchFolder.selectedEngine) {
                    Text(String(localized: "watchFolder.engine.default")).tag(nil as String?)
                    Divider()
                    ForEach(watchFolder.availableEngines, id: \.providerId) { engine in
                        HStack {
                            Text(engine.providerDisplayName)
                            if !watchFolder.canPrepareForTranscription(engine) {
                                Text("(\(String(localized: "not ready")))")
                                    .foregroundStyle(.secondary)
                            }
                        }.tag(engine.providerId as String?)
                    }
                }

                if let engine = watchFolder.resolvedEngine {
                    let models = engine.transcriptionModels
                    if models.count > 1 {
                        Picker(String(localized: "Model"), selection: $watchFolder.selectedModel) {
                            Text(String(localized: "watchFolder.model.default")).tag(nil as String?)
                            Divider()
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                    }
                }

                LanguageSelectionEditor(
                    selection: $watchFolder.languageSelection,
                    availableLanguages: localizedAppLanguageOptions(for: watchFolder.selectedEngineSupportedLanguages)
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        .map { (code: $0.code, name: $0.name) },
                    hintBehavior: LanguageSelectionHintBehavior(engine: watchFolder.resolvedEngine)
                )
            }

            Section(String(localized: "watchFolder.settings")) {
                Picker(String(localized: "watchFolder.outputFormat"), selection: $watchFolder.outputFormat) {
                    Text(WatchFolderOutputFormat.markdown.displayName).tag(WatchFolderOutputFormat.markdown)
                    Text(WatchFolderOutputFormat.plainText.displayName).tag(WatchFolderOutputFormat.plainText)
                    Text(WatchFolderOutputFormat.srt.displayName).tag(WatchFolderOutputFormat.srt)
                    Text(WatchFolderOutputFormat.vtt.displayName).tag(WatchFolderOutputFormat.vtt)
                }

                Toggle(String(localized: "watchFolder.deleteSource"), isOn: $watchFolder.deleteSourceFiles)

                Toggle(String(localized: "watchFolder.autoStart"), isOn: $watchFolder.autoStartOnLaunch)
            }

            Section {
                HStack {
                    Button {
                        watchFolder.toggleWatching()
                    } label: {
                        Label(
                            watchFolder.watchFolderService.isWatching
                                ? String(localized: "watchFolder.stopWatching")
                                : String(localized: "watchFolder.startWatching"),
                            systemImage: watchFolder.watchFolderService.isWatching ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(watchFolder.watchFolderPath == nil)

                    if let processing = watchFolder.watchFolderService.currentlyProcessing {
                        Spacer()
                        Label(processing, systemImage: "arrow.trianglehead.2.counterclockwise")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Text(String(localized: "watchFolder.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "watchFolder.history")) {
                if watchFolder.watchFolderService.processedFiles.isEmpty {
                    Text(String(localized: "watchFolder.history.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(watchFolder.watchFolderService.processedFiles.prefix(20)) { item in
                        HStack {
                            Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(item.success ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.fileName)
                                    .lineLimit(1)
                                if let error = item.errorMessage {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                } else {
                                    Text(item.date, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !watchFolder.watchFolderService.processedFiles.isEmpty {
                        Button(String(localized: "watchFolder.history.clear"), role: .destructive) {
                            watchFolder.watchFolderService.clearHistory()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }
}
