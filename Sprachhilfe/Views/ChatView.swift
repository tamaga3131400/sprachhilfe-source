import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SprachhilfePluginSDK

struct ChatView: View {
    @ObservedObject private var viewModel: ChatViewModel
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var graphExtractionService = GraphExtractionService.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var showURLPrompt = false
    @State private var urlInput = ""
    @State private var showCategoryFilter = false
    @State private var isContextPanelVisible = true
    @State private var showPasteStudio = false
    @State private var pasteDraft = ChatPasteDraft(text: "", fileURLs: [], containsUnsupportedImage: false)
    @State private var showCommandPalette = false
    @State private var showArchivedSessions = false
    @State private var sessionSearchText = ""
    @State private var sessionToRename: ChatSession?
    @State private var sessionTitleDraft = ""
    @FocusState private var isSidebarSearchFocused: Bool

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    static let importableContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .log, .sourceCode, .pdf, .rtf]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let doc = UTType(filenameExtension: "doc") { types.append(doc) }
        return types
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                sidebar
                Divider()
                chatMain
                if isContextPanelVisible {
                    Divider()
                    contextPanel
                }
            }

            if let notice = viewModel.noticeMessage {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 920, minHeight: 580)
        .onAppear {
            if viewModel.currentSession == nil, let first = viewModel.activeSessions.first {
                viewModel.selectSession(first)
            }
        }
        .alert(localizedAppText("Rename Chat", de: "Chat umbenennen"), isPresented: Binding(
            get: { sessionToRename != nil },
            set: { if !$0 { sessionToRename = nil } }
        )) {
            TextField(localizedAppText("Chat title", de: "Chat-Titel"), text: $sessionTitleDraft)
            Button(localizedAppText("Cancel", de: "Abbrechen"), role: .cancel) {
                sessionToRename = nil
            }
            Button(localizedAppText("Save", de: "Speichern")) {
                if let sessionToRename {
                    viewModel.renameSession(sessionToRename, title: sessionTitleDraft)
                }
                sessionToRename = nil
            }
            .disabled(sessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: ChatView.importableContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                for url in urls { viewModel.importDocument(url: url) }
            }
        }
        .sheet(isPresented: $showURLPrompt) {
            URLPromptSheet(urlInput: $urlInput) { url in
                viewModel.importURL(url)
            }
        }
        .sheet(isPresented: $showPasteStudio) {
            ChatPasteStudio(draft: pasteDraft) { text, contextURLs, contextFiles in
                viewModel.sendPasteDraft(text, contextURLs: contextURLs, contextFiles: contextFiles)
            }
        }
        .sheet(isPresented: $showCommandPalette) {
            ChatCommandPalette { command in
                switch command {
                case .newChat:
                    viewModel.createNewSession()
                case .searchChats:
                    isSidebarSearchFocused = true
                case .paste:
                    presentPasteStudio()
                case .toggleContext:
                    isContextPanelVisible.toggle()
                case .settings:
                    ManagedAppWindowOpener.shared.open(id: "settings")
                }
            }
        }
        .background {
            Button(action: presentPasteStudio) { EmptyView() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .hidden()
            Button { showCommandPalette = true } label: { EmptyView() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    private func presentPasteStudio() {
        pasteDraft = ChatClipboardService.captureDraft()
        showPasteStudio = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    viewModel.createNewSession()
                } label: {
                    Label(
                        localizedAppText("New Chat", de: "Neuer Chat"),
                        systemImage: "plus.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    Toggle(isOn: $showArchivedSessions) {
                        Label(
                            localizedAppText("Show archive", de: "Archiv anzeigen"),
                            systemImage: "archivebox"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help(localizedAppText("Chat list options", de: "Chatlisten-Optionen"))
            }
            .padding(8)

            TextField(localizedAppText("Search chats", de: "Chats durchsuchen"), text: $sessionSearchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSidebarSearchFocused)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)

            List(selection: Binding(
                get: { viewModel.currentSession },
                set: { session in
                    if let session { viewModel.selectSession(session) }
                }
            )) {
                if showArchivedSessions {
                    Section(localizedAppText("Archived", de: "Archiv")) {
                        ForEach(visibleSessions, id: \.id, content: sessionRow)
                    }
                } else {
                    if !pinnedSessions.isEmpty {
                        Section(localizedAppText("Pinned", de: "Angeheftet")) {
                            ForEach(pinnedSessions, id: \.id, content: sessionRow)
                        }
                    }
                    if !todaySessions.isEmpty {
                        Section(localizedAppText("Today", de: "Heute")) {
                            ForEach(todaySessions, id: \.id, content: sessionRow)
                        }
                    }
                    if !yesterdaySessions.isEmpty {
                        Section(localizedAppText("Yesterday", de: "Gestern")) {
                            ForEach(yesterdaySessions, id: \.id, content: sessionRow)
                        }
                    }
                    if !previousWeekSessions.isEmpty {
                        Section(localizedAppText("Previous 7 days", de: "Letzte 7 Tage")) {
                            ForEach(previousWeekSessions, id: \.id, content: sessionRow)
                        }
                    }
                    if !olderSessions.isEmpty {
                        Section(localizedAppText("Older", de: "Älter")) {
                            ForEach(olderSessions, id: \.id, content: sessionRow)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(width: 250)
    }

    private var visibleSessions: [ChatSession] {
        let source = showArchivedSessions ? viewModel.archivedSessions : viewModel.activeSessions
        let search = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return source
            .filter { viewModel.sessionMatchesSearch($0, query: search) }
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private var pinnedSessions: [ChatSession] {
        visibleSessions.filter(\.isPinned)
    }

    private var unpinnedSessions: [ChatSession] {
        visibleSessions.filter { !$0.isPinned }
    }

    private var todaySessions: [ChatSession] {
        unpinnedSessions.filter { Calendar.current.isDateInToday($0.updatedAt) }
    }

    private var yesterdaySessions: [ChatSession] {
        unpinnedSessions.filter { Calendar.current.isDateInYesterday($0.updatedAt) }
    }

    private var previousWeekSessions: [ChatSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return [] }
        return unpinnedSessions.filter {
            $0.updatedAt >= weekAgo
                && !Calendar.current.isDateInToday($0.updatedAt)
                && !Calendar.current.isDateInYesterday($0.updatedAt)
        }
    }

    private var olderSessions: [ChatSession] {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return unpinnedSessions }
        return unpinnedSessions.filter { $0.updatedAt < weekAgo }
    }

    @ViewBuilder
    private func sessionRow(_ session: ChatSession) -> some View {
        ChatSessionRow(
            session: session,
            searchPreview: viewModel.sessionSearchSnippet(for: session, query: sessionSearchText)
        )
            .tag(session)
            .contextMenu {
                if showArchivedSessions {
                    Button {
                        viewModel.restoreSession(session)
                    } label: {
                        Label(localizedAppText("Restore", de: "Wiederherstellen"), systemImage: "arrow.uturn.backward")
                    }
                } else {
                    Button {
                        sessionToRename = session
                        sessionTitleDraft = session.title
                    } label: {
                        Label(localizedAppText("Rename", de: "Umbenennen"), systemImage: "pencil")
                    }
                    Button {
                        viewModel.togglePinned(session)
                    } label: {
                        Label(
                            session.isPinned
                                ? localizedAppText("Unpin", de: "Lösen")
                                : localizedAppText("Pin", de: "Anheften"),
                            systemImage: session.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Button {
                        viewModel.archiveSession(session)
                    } label: {
                        Label(localizedAppText("Archive", de: "Archivieren"), systemImage: "archivebox")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    viewModel.deleteSession(session)
                } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            }
    }

    private var chatConfigurationSummary: String {
        guard let session = viewModel.currentSession else { return "" }
        let provider = viewModel.availableLLMProviders.first(where: { $0.id == session.providerId })?.displayName
            ?? localizedAppText("No provider", de: "Kein Anbieter")
        let model = session.modelId.flatMap { modelId in
            viewModel.modelsForProvider(session.providerId).first(where: { $0.id == modelId })?.displayName
        } ?? String(localized: "Default")
        let memory = session.memoryPluginId.isEmpty
            ? localizedAppText("Document retrieval off", de: "Dokumentenabruf aus")
            : viewModel.displayName(forMemoryPlugin: session.memoryPluginId)
        return "\(provider) · \(model) · \(responseModeTitle(viewModel.currentResponseMode)) · \(memory)"
    }

    private func responseModeTitle(_ mode: ChatResponseMode) -> String {
        switch mode {
        case .balanced:
            localizedAppText("Balanced", de: "Ausgewogen")
        case .documentGrounded:
            localizedAppText("Document grounded", de: "Nur Dokumente")
        case .general:
            localizedAppText("General Chat", de: "Allgemeiner Chat")
        case .logAnalysis:
            localizedAppText("Log Analysis", de: "Log-Analyse")
        }
    }

    private var hiddenMessageIds: Set<UUID> {
        let all = viewModel.messages
        var replaced = Set<UUID>()
        for msg in all {
            if let replacesId = msg.replacesMessageId {
                replaced.insert(replacesId)
                var cursor: UUID? = replacesId
                while let id = cursor {
                    if all.contains(where: { $0.replacesMessageId == id }) {
                        replaced.insert(id)
                        cursor = all.first(where: { $0.replacesMessageId == id })?.id
                    } else {
                        cursor = nil
                    }
                }
            }
        }
        return replaced
    }

    private var visibleMessages: [ChatMessage] {
        viewModel.messages.filter { !hiddenMessageIds.contains($0.id) }
    }

    private func branchCount(for message: ChatMessage) -> Int {
        max(0, viewModel.branchVariants(of: message).count - 1)
    }

    // MARK: - Chat Main

    /// Shared background for the header/system-prompt/documents "toolbar band", visually
    /// distinct from the message canvas below so the sections read as separate areas in dark
    /// mode instead of blending into one flat block.
    private static let toolbarBandBackground = Color(nsColor: .controlBackgroundColor)

    private var chatMain: some View {
        VStack(spacing: 0) {
            if let _ = viewModel.currentSession {
                chatHeader
                Divider()
                if let errorMessage = viewModel.errorMessage {
                    ChatFeedbackBanner(message: errorMessage) {
                        viewModel.dismissError()
                    }
                    Divider()
                }
                messageList
                Divider()
                inputBar
            } else {
                emptyState
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.currentSession?.title ?? "")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(chatConfigurationSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                isContextPanelVisible.toggle()
            } label: {
                Label(
                    isContextPanelVisible
                        ? localizedAppText("Hide context", de: "Kontext ausblenden")
                        : localizedAppText("Show context", de: "Kontext einblenden"),
                    systemImage: "sidebar.right"
                )
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial)
    }

    private var contextPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label(localizedAppText("Conversation context", de: "Gesprächskontext"), systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button {
                    isContextPanelVisible = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(localizedAppText("Hide context", de: "Kontext ausblenden"))
            }
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    chatSettingsControls
                    Divider()
                    systemPromptArea
                    Divider()
                    documentArea
                    Divider()
                    Label(
                        localizedAppText(
                            "Online research will be available as an opt-in integration.",
                            de: "Online-Recherche wird später als optionale Integration verfügbar sein."
                        ),
                        systemImage: "globe"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .frame(width: 330)
        .background(.regularMaterial)
    }

    private var chatSettingsControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizedAppText("Model & mode", de: "Modell & Modus"))
                .font(.subheadline.weight(.semibold))

            Picker(String(localized: "Provider"), selection: Binding(
                get: { viewModel.currentSession?.providerId ?? "" },
                set: { viewModel.updateSessionProvider($0) }
            )) {
                ForEach(viewModel.availableLLMProviders, id: \.id) { provider in
                    Text(provider.displayName).tag(provider.id)
                }
            }

            if let session = viewModel.currentSession {
                let models = viewModel.modelsForProvider(session.providerId)
                if !models.isEmpty {
                    Picker(String(localized: "Model"), selection: Binding(
                        get: { viewModel.currentSession?.modelId ?? "" },
                        set: { viewModel.updateSessionModel($0.isEmpty ? nil : $0) }
                    )) {
                        Text(String(localized: "Default")).tag("")
                        ForEach(models, id: \.id) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
            }

            Picker(String(localized: "Vector Store"), selection: Binding(
                get: { viewModel.currentSession?.memoryPluginId ?? "" },
                set: { viewModel.updateSessionMemoryPlugin($0) }
            )) {
                Text(String(localized: "None")).tag("")
                ForEach(viewModel.availableMemoryPlugins, id: \.storageName) { plugin in
                    Text(plugin.isReady
                         ? plugin.storageName
                         : "\(plugin.storageName) (\(String(localized: "not ready")))")
                        .tag(type(of: plugin).pluginId)
                        .disabled(!plugin.isReady)
                }
            }

            Picker(localizedAppText("Response mode", de: "Antwortmodus"), selection: Binding(
                get: { viewModel.currentResponseMode },
                set: { viewModel.updateSessionResponseMode($0) }
            )) {
                ForEach(ChatResponseMode.allCases) { mode in
                    Text(responseModeTitle(mode)).tag(mode)
                }
            }

            Text(responseModeDescription(viewModel.currentResponseMode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.isCurrentProviderLocal {
                Divider()
                Text(localizedAppText("Chunk size for local models", de: "Block-Größe für lokale Modelle"))
                    .font(.subheadline.weight(.medium))
                Stepper(
                    "\(viewModel.chunkMaxChars) " + localizedAppText("characters", de: "Zeichen"),
                    value: $viewModel.chunkMaxChars,
                    in: ChatViewModel.chunkMaxCharsRange,
                    step: 4000
                )
            }

            Divider()
            Text(localizedAppText("Presets", de: "Vorlagen"))
                .font(.subheadline.weight(.medium))
            ForEach(viewModel.chatPresets, id: \.id) { preset in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.title).font(.caption)
                        Text(responseModeTitle(ChatResponseMode(rawValue: preset.responseMode) ?? .balanced))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(localizedAppText("Load", de: "Laden")) {
                        viewModel.applyPresetToCurrent(preset)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    Button(role: .destructive) {
                        viewModel.deletePreset(preset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            HStack {
                Button {
                    viewModel.saveCurrentAsPreset()
                } label: {
                    Label(localizedAppText("Save current as preset", de: "Aktuelle als Vorlage speichern"), systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func responseModeDescription(_ mode: ChatResponseMode) -> String {
        switch mode {
        case .balanced:
            localizedAppText("Uses selected documents when relevant and can use general knowledge.", de: "Nutzt ausgewählte Dokumente bei Bedarf und darf allgemeines Wissen verwenden.")
        case .documentGrounded:
            localizedAppText("Answers only from selected documents.", de: "Antwortet ausschließlich aus ausgewählten Dokumenten.")
        case .general:
            localizedAppText("Does not search documents.", de: "Durchsucht keine Dokumente.")
        case .logAnalysis:
            localizedAppText("Structures findings, likely causes, and next steps for logs.", de: "Strukturiert Befunde, wahrscheinliche Ursachen und nächste Schritte für Logs.")
        }
    }

    private var categoryFilterPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localizedAppText("Filter by category", de: "Nach Kategorie filtern"))
                .font(.headline)
            Text(localizedAppText(
                "Empty = all global documents are used as context.",
                de: "Leer = alle globalen Dokumente werden als Kontext verwendet."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            ForEach(viewModel.globalLibraryCategories, id: \.self) { category in
                Toggle(isOn: Binding(
                    get: { viewModel.currentSession?.activeDocumentCategories.contains(category) ?? false },
                    set: { isOn in
                        var current = viewModel.currentSession?.activeDocumentCategories ?? []
                        if isOn {
                            if !current.contains(category) { current.append(category) }
                        } else {
                            current.removeAll { $0 == category }
                        }
                        viewModel.updateSessionActiveDocumentCategories(current)
                    }
                )) {
                    Text(category)
                }
                .toggleStyle(.checkbox)
            }

            if !(viewModel.currentSession?.activeDocumentCategories.isEmpty ?? true) {
                Divider()
                Button(localizedAppText("Clear filter", de: "Filter löschen")) {
                    viewModel.updateSessionActiveDocumentCategories([])
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .frame(width: 240)
    }

    // MARK: - System Prompt

    @ViewBuilder
    private var systemPromptArea: some View {
        if let session = viewModel.currentSession {
            SystemPromptSection(
                session: session,
                presets: viewModel.systemPromptPresets,
                onChange: { viewModel.updateSessionSystemPrompt($0) }
            )
            .id(session.id)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Documents

    private var documentArea: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
                Text(localizedAppText("Documents", de: "Dokumente"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !viewModel.documents.isEmpty {
                    Text("\(viewModel.documents.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if viewModel.isImportingDocuments {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Toggle(isOn: Binding(
                    get: { viewModel.currentSession?.includeGlobalLibrary ?? false },
                    set: { viewModel.updateSessionIncludeGlobalLibrary($0) }
                )) {
                    Text(localizedAppText("Global library", de: "Globale Bibliothek"))
                        .font(.caption)
                }
                .toggleStyle(.checkbox)
                .help(localizedAppText(
                    "Also use documents from the global Knowledge library when answering.",
                    de: "Beim Antworten auch Dokumente aus der globalen Wissens-Bibliothek nutzen."
                ))

                if pluginManager.graphStoragePlugins.contains(where: { $0.isReady }) {
                    Toggle(isOn: Binding(
                        get: { viewModel.currentSession?.useKnowledgeGraph ?? false },
                        set: { viewModel.updateSessionUseKnowledgeGraph($0) }
                    )) {
                        Text(localizedAppText("Knowledge graph", de: "Wissensgraph"))
                            .font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help(localizedAppText(
                        "Also query the connected knowledge graph when answering.",
                        de: "Beim Antworten auch den verbundenen Wissensgraphen abfragen."
                    ))
                }

                if viewModel.currentSession?.includeGlobalLibrary == true,
                   !viewModel.globalLibraryCategories.isEmpty {
                    Button {
                        showCategoryFilter = true
                    } label: {
                        let activeCount = viewModel.currentSession?.activeDocumentCategories.count ?? 0
                        Label(
                            activeCount == 0
                                ? localizedAppText("All categories", de: "Alle Kategorien")
                                : "\(activeCount) " + localizedAppText("categories", de: "Kategorien"),
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showCategoryFilter, arrowEdge: .bottom) {
                        categoryFilterPopover
                    }
                }

                Button {
                    urlInput = ""
                    showURLPrompt = true
                } label: {
                    Label(
                        localizedAppText("URL…", de: "URL …"),
                        systemImage: "globe"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isImportingDocuments)
                .help(localizedAppText("Load a web page as context", de: "Webseite als Kontext laden"))

                Button {
                    showFilePicker = true
                } label: {
                    Label(
                        localizedAppText("Add…", de: "Hinzufügen …"),
                        systemImage: "plus"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isImportingDocuments)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)

            if !viewModel.importActivities.isEmpty {
                importActivityList
            }

            if viewModel.documents.isEmpty {
                dropZone
            } else {
                documentList
            }
        }
        .background(Self.toolbarBandBackground)
        .background(isDragTargeted ? Color.blue.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var dropZone: some View {
        HStack {
            Spacer()
            Text(localizedAppText(
                "Drop .txt, .md, .pdf or .docx files here",
                de: ".txt-, .md-, .pdf- oder .docx-Dateien hier ablegen"
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(height: 28)
    }

    private var documentList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.documents, id: \.id) { doc in
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                        Text(doc.fileName)
                            .font(.caption)
                            .lineLimit(1)
                        Text("(\(doc.chunkCount))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Button {
                            viewModel.toggleDocumentInclusion(doc)
                        } label: {
                            Image(systemName: viewModel.isDocumentIncluded(doc) ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundStyle(viewModel.isDocumentIncluded(doc) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.isDocumentIncluded(doc)
                              ? localizedAppText("Use this document for answers", de: "Dieses Dokument für Antworten verwenden")
                              : localizedAppText("Exclude this document from answers", de: "Dieses Dokument von Antworten ausschließen"))
                        if let graphError = graphExtractionService.activeExtractions[doc.id]?.errorMessage {
                            Label(graphError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .help(graphError)
                        }
                        Button {
                            viewModel.deleteDocument(doc)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(viewModel.isDocumentIncluded(doc) ? Color.secondary.opacity(0.1) : Color.secondary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .frame(height: 32)
    }

    private var importActivityList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.importActivities) { activity in
                HStack(spacing: 6) {
                    switch activity.state {
                    case .importing:
                        ProgressView()
                            .controlSize(.small)
                        Text(localizedAppText("Indexing", de: "Wird indexiert") + ": \(activity.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .failed(let message):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("\(activity.name): \(message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.dismissImportActivity(activity)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Messages

    private var messageList: some View {
        GeometryReader { geometry in
            // Content column scales with the window instead of hugging a fixed width, so wide
            // windows don't leave a large empty gap on one side.
            let contentWidth = geometry.size.width * 0.96

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if viewModel.messages.isEmpty {
                            chatPlaceholder
                        }
                        ForEach(visibleMessages, id: \.id) { message in
                            ChatMessageRow(
                                message: message,
                                sourceDocuments: viewModel.sourceDocuments(for: message),
                                branchCount: branchCount(for: message),
                                maxContentWidth: contentWidth,
                                isEditing: viewModel.editingMessageId == message.id,
                                onCopy: { format in viewModel.copyToClipboard(message.content, format: format) },
                                onInsert: { viewModel.insertIntoLastActiveApp(message.content) },
                                onEdit: { viewModel.beginEditing(message) },
                                onRegenerate: { viewModel.regenerate(message) },
                                onSaveEdit: { viewModel.saveEdit(message, newContent: $0) },
                                onCancelEdit: { viewModel.cancelEditing() }
                            )
                            .id(message.id)
                        }
                        if viewModel.isSending {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(viewModel.processingStatus ?? String(localized: "Thinking…"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .frame(width: contentWidth)
                            .padding(.horizontal, 16)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                // Deliberately darker than the toolbar band above (controlBackgroundColor) so
                // the two areas read as clearly separate zones instead of blending together.
                // In light mode, underPageBackgroundColor reads as a dull gray rather than a
                // clean zone, so we use a bright, near-white canvas there instead.
                .background(colorScheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color(nsColor: .textBackgroundColor))
                .onChange(of: viewModel.messages.count) { _, _ in
                    if let lastId = viewModel.messages.last?.id {
                        withAnimation { proxy.scrollTo(lastId, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var chatPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(localizedAppText(
                "Ask a question or drop a document to get started.",
                de: "Stell eine Frage oder leg ein Dokument ab, um loszulegen."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Input

    private var inputBar: some View {
        ChatInputBar(
            isSending: viewModel.isSending,
            isRecording: viewModel.isRecording,
            isTranscribingVoice: viewModel.isTranscribingVoice,
            dictatedText: viewModel.dictatedText,
            onAttach: { showFilePicker = true },
            onPaste: presentPasteStudio,
            onToggleRecording: { viewModel.toggleRecording() },
            onConsumeDictation: { viewModel.clearDictatedText() },
            onSend: { viewModel.send($0) },
            onStop: { viewModel.stopGenerating() }
        )
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(localizedAppText(
                "No active chat.",
                de: "Kein aktiver Chat."
            ))
            .font(.headline)
            .foregroundStyle(.secondary)
            Button {
                viewModel.createNewSession()
            } label: {
                Label(
                    localizedAppText("New Chat", de: "Neuer Chat"),
                    systemImage: "plus.circle"
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.importDocument(url: url)
                }
            }
            found = true
        }
        return found
    }
}

// MARK: - URL Prompt Sheet

struct URLPromptSheet: View {
    @Binding var urlInput: String
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { urlInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localizedAppText("Load web page", de: "Webseite laden"))
                .font(.headline)
            Text(localizedAppText(
                "The page text is fetched and added as context for this chat.",
                de: "Der Seitentext wird geladen und als Kontext für diesen Chat hinzugefügt."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("https://…", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            HStack {
                Spacer()
                Button(localizedAppText("Cancel", de: "Abbrechen")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(localizedAppText("Load", de: "Laden"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private func submit() {
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

// MARK: - Input Bar (isolated for performance)

private struct ChatInputBar: View {
    let isSending: Bool
    let isRecording: Bool
    let isTranscribingVoice: Bool
    let dictatedText: String?
    let onAttach: () -> Void
    let onPaste: () -> Void
    let onToggleRecording: () -> Void
    let onConsumeDictation: () -> Void
    let onSend: (String) -> Void
    let onStop: () -> Void

    @State private var text: String = ""

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onAttach) {
                Image(systemName: "paperclip.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help(localizedAppText("Attach documents", de: "Dokumente anhängen"))

            Button(action: onPaste) {
                Image(systemName: "clipboard")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(isSending)
            .help(localizedAppText("Paste from clipboard", de: "Aus Zwischenablage einfügen"))

            Button(action: onToggleRecording) {
                if isTranscribingVoice {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle")
                        .font(.title2)
                        .foregroundStyle(isRecording ? .red : .secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isTranscribingVoice)
            .help(isRecording
                ? localizedAppText("Stop recording", de: "Aufnahme stoppen")
                : localizedAppText("Dictate", de: "Diktieren"))

            // TextEditor (scrollable, fixed max height) handles very long pasted text without
            // the content-fit hang of a vertical-growing TextField.
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 140)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(localizedAppText("Type a message…", de: "Nachricht eingeben …"))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                        .allowsHitTesting(false)
                    }
                }

            Button(action: submit) {
                EmptyView()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()

            Button {
                if isSending { onStop() } else { submit() }
            } label: {
                Image(systemName: isSending ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(isSending ? false : !canSend)
            .help(isSending
                ? localizedAppText("Stop generating", de: "Generieren stoppen")
                : localizedAppText("Send", de: "Senden"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .help(localizedAppText("Press Command-Return to send", de: "Mit Befehl-Eingabe senden"))
        .onChange(of: dictatedText) { _, newValue in
            guard let dictation = newValue, !dictation.isEmpty else { return }
            let separator = text.isEmpty || text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " "
            text += separator + dictation
            onConsumeDictation()
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        onSend(text)
        text = ""
    }
}

// MARK: - System Prompt Section (isolated for performance)

private struct SystemPromptSection: View {
    let session: ChatSession
    let presets: [SystemPromptPreset]
    let onChange: (String) -> Void

    @State private var draft: String
    @State private var expanded: Bool = false

    init(session: ChatSession, presets: [SystemPromptPreset], onChange: @escaping (String) -> Void) {
        self.session = session
        self.presets = presets
        self.onChange = onChange
        _draft = State(initialValue: session.systemPrompt)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !presets.isEmpty {
                    HStack {
                        Menu {
                            ForEach(presets, id: \.id) { preset in
                                Button(preset.title.isEmpty
                                       ? localizedAppText("Untitled", de: "Ohne Titel")
                                       : preset.title) {
                                    draft = preset.content
                                    onChange(preset.content)
                                }
                            }
                        } label: {
                            Label(localizedAppText("Use preset", de: "Vorlage verwenden"), systemImage: "text.badge.star")
                                .font(.caption)
                        }
                        .fixedSize()
                        Spacer()
                    }
                }

                TextEditor(text: $draft)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .padding(6)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(localizedAppText(
                                "e.g. \u{201E}Answer only in German and refer to the documents\u{201C}",
                                de: "z. B. \u{201E}Antworte nur auf Deutsch und beziehe dich auf die Dokumente\u{201C}"
                            ))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: draft) { _, newValue in onChange(newValue) }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.star")
                    .foregroundStyle(.secondary)
                Text(localizedAppText("System Prompt (optional)", de: "System-Prompt (optional)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !draft.isEmpty, !expanded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
        }
    }
}

// MARK: - Session Row

private struct ChatSessionRow: View {
    let session: ChatSession
    let searchPreview: String?

    var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let searchPreview {
                    Text(searchPreview)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            if session.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Message Row (OpenWebUI-style: full-width, avatar-led, hover actions)

private struct ChatMessageRow: View {
    let message: ChatMessage
    let sourceDocuments: [ChatDocument]
    let branchCount: Int
    let maxContentWidth: CGFloat
    let isEditing: Bool
    let onCopy: (ChatCopyFormat) -> Void
    let onInsert: () -> Void
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onSaveEdit: (String) -> Void
    let onCancelEdit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var editDraft: String = ""

    private static let longThreshold = 4000
    // Solid, hand-picked pastels for light mode — opacity-blended tints look muddy on the
    // near-white canvas there, unlike dark mode where they blend cleanly against near-black.
    private static let lightUserBackground = Color(red: 0.90, green: 0.95, blue: 1.0)
    private static let lightAssistantBackground = Color(red: 1.0, green: 0.94, blue: 0.87)

    private var isUser: Bool { message.role == "user" }
    private var isLong: Bool { message.content.count > Self.longThreshold }
    // Complementary pair (blue ↔ orange) so the two roles stay visually distinct even when the
    // app's accent color happens to be blue — and with enough opacity to actually read in dark
    // mode (low-opacity tints on a near-black background are invisible).
    private var avatarTint: Color { isUser ? .blue : .orange }
    private var contentBackground: Color {
        if colorScheme == .dark {
            isUser ? Color.blue.opacity(0.14) : Color.orange.opacity(0.12)
        } else {
            isUser ? Self.lightUserBackground : Self.lightAssistantBackground
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(isUser ? localizedAppText("You", de: "Du") : localizedAppText("Assistant", de: "Assistent"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if branchCount > 0 {
                        Label("\(branchCount + 1)", systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if message.replacesMessageId != nil {
                        Text("(\(localizedAppText("variant", de: "Variante")))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isEditing {
                    editingContent
                } else {
                    content
                    if !isUser, let retrievalSummary = message.retrievalSummary {
                        Label(retrievalSummary, systemImage: "books.vertical")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !sourceDocuments.isEmpty {
                        ChatSourceChips(documents: sourceDocuments)
                    }
                    actionRow
                }
            }
            .frame(maxWidth: maxContentWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .onAppear { editDraft = message.content }
        .onChange(of: isEditing) { _, editing in
            if editing { editDraft = message.content }
        }
    }

    private var avatar: some View {
        Image(systemName: isUser ? "person.fill" : "sparkles")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(avatarTint))
    }

    @ViewBuilder
    private var content: some View {
        if isLong {
            MessageTextView(text: message.content)
                .frame(height: 320)
                .padding(8)
                .background(contentBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if isUser {
            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(contentBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            MarkdownContentView(
                text: message.content,
                contentBackground: contentBackground,
                onCopyCode: { code in ChatClipboardService.copy(code, as: .plainText) }
            )
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(ChatCopyFormat.allCases) { format in
                    Button(format.title) {
                        onCopy(format)
                    }
                }
                Divider()
                Button(localizedAppText("Insert into last active app", de: "In zuletzt aktive App einfügen")) {
                    onInsert()
                }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help(localizedAppText("Copy or insert", de: "Kopieren oder einfügen"))

            if isUser {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .help(localizedAppText("Edit", de: "Bearbeiten"))
            } else {
                Button(action: onRegenerate) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(localizedAppText("Regenerate", de: "Neu generieren"))
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var editingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editDraft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 36, maxHeight: 200)
                .padding(6)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button(localizedAppText("Cancel", de: "Abbrechen"), action: onCancelEdit)
                Button(localizedAppText("Save & Resend", de: "Speichern & senden")) {
                    onSaveEdit(editDraft)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }
}

private struct ChatSourceChips: View {
    let documents: [ChatDocument]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(documents, id: \.id) { document in
                    Group {
                        if let sourceURL = document.sourceURL, let url = URL(string: sourceURL) {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                sourceLabel(for: document)
                            }
                            .buttonStyle(.borderless)
                            .help(sourceURL)
                        } else {
                            sourceLabel(for: document)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
            }
        }
        .frame(height: 26)
    }

    private func sourceLabel(for document: ChatDocument) -> some View {
        Label(document.fileName, systemImage: document.sourceURL == nil ? "doc.text" : "link")
            .font(.caption2)
            .lineLimit(1)
    }
}

private struct ChatPasteStudio: View {
    let draft: ChatPasteDraft
    let onSubmit: (String, [String], [URL]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var includeURLAsContext = false
    @State private var contextFileURLs: Set<URL> = []

    init(draft: ChatPasteDraft, onSubmit: @escaping (String, [String], [URL]) -> Void) {
        self.draft = draft
        self.onSubmit = onSubmit
        _text = State(initialValue: draft.text)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(localizedAppText("Paste Studio", de: "Einfüge-Studio"), systemImage: "clipboard")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(kindTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(localizedAppText(
                "Review content before it is sent. Nothing from your clipboard is kept after this window closes.",
                de: "Prüfe den Inhalt vor dem Senden. Nach dem Schließen wird nichts aus deiner Zwischenablage gespeichert."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)

            if draft.containsUnsupportedImage {
                Label(
                    localizedAppText(
                        "Images are recognized but image analysis is not supported yet.",
                        de: "Bilder wurden erkannt, Bildanalyse wird aber noch nicht unterstützt."
                    ),
                    systemImage: "photo.badge.exclamationmark"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if !draft.fileURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(localizedAppText("Files", de: "Dateien"))
                        .font(.subheadline.weight(.medium))
                    ForEach(draft.fileURLs, id: \.self) { url in
                        Toggle(isOn: Binding(
                            get: { contextFileURLs.contains(url) },
                            set: { include in
                                if include { contextFileURLs.insert(url) }
                                else { contextFileURLs.remove(url) }
                            }
                        )) {
                            Label(url.lastPathComponent, systemImage: "doc")
                                .lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(localizedAppText(
                        "Selected files are indexed as chat context before your message is sent.",
                        de: "Ausgewählte Dateien werden vor dem Senden als Chat-Kontext indexiert."
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            if ChatPasteDraft.isWebURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Toggle(isOn: $includeURLAsContext) {
                    Label(
                        localizedAppText("Load this page as context", de: "Diese Webseite als Kontext laden"),
                        systemImage: "globe"
                    )
                }
                .toggleStyle(.checkbox)
            }

            TextEditor(text: $text)
                .font(draft.kind == .code ? .system(.body, design: .monospaced) : .body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140, maxHeight: 280)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .center) {
                    if draft.kind == .empty || draft.kind == .unsupportedImage {
                        Text(localizedAppText("No text content to send", de: "Kein Text zum Senden vorhanden"))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Button(localizedAppText("Cancel", de: "Abbrechen")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localizedAppText("Send", de: "Senden")) {
                    let contextURLs = includeURLAsContext
                        ? [text.trimmingCharacters(in: .whitespacesAndNewlines)]
                        : []
                    onSubmit(text, contextURLs, Array(contextFileURLs))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var kindTitle: String {
        switch draft.kind {
        case .empty: localizedAppText("Empty", de: "Leer")
        case .text: localizedAppText("Text", de: "Text")
        case .code: localizedAppText("Code", de: "Code")
        case .url: localizedAppText("Web link", de: "Weblink")
        case .files: localizedAppText("Files", de: "Dateien")
        case .unsupportedImage: localizedAppText("Image", de: "Bild")
        }
    }
}

private enum ChatWorkspaceCommand: CaseIterable, Identifiable {
    case newChat
    case searchChats
    case paste
    case toggleContext
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .newChat: localizedAppText("New chat", de: "Neuer Chat")
        case .searchChats: localizedAppText("Search chats", de: "Chats durchsuchen")
        case .paste: localizedAppText("Open Paste Studio", de: "Einfüge-Studio öffnen")
        case .toggleContext: localizedAppText("Show or hide context", de: "Kontext ein- oder ausblenden")
        case .settings: localizedAppText("Open settings", de: "Einstellungen öffnen")
        }
    }

    var icon: String {
        switch self {
        case .newChat: "plus.bubble"
        case .searchChats: "magnifyingglass"
        case .paste: "clipboard"
        case .toggleContext: "sidebar.right"
        case .settings: "gear"
        }
    }
}

private struct ChatCommandPalette: View {
    let execute: (ChatWorkspaceCommand) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var commands: [ChatWorkspaceCommand] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatWorkspaceCommand.allCases.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField(localizedAppText("Type a command", de: "Befehl eingeben"), text: $searchText)
                .textFieldStyle(.roundedBorder)
            List(commands) { command in
                Button {
                    execute(command)
                    dismiss()
                } label: {
                    Label(command.title, systemImage: command.icon)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
        .padding(16)
        .frame(width: 440, height: 300)
    }
}

private struct ChatFeedbackBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(localizedAppText("Dismiss", de: "Schließen"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.1))
    }
}

// MARK: - TextKit-backed text view (fast for very long content)

private struct MessageTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }
}

// MARK: - Markdown Content View (renders markdown with code blocks and copy buttons)

private struct MarkdownContentView: View {
    let text: String
    let contentBackground: Color
    let onCopyCode: (String) -> Void

    private enum Segment {
        case text(String)
        case code(String)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        let pattern = try? NSRegularExpression(pattern: "```(?:\\w+\\s*\\n)?([\\s\\S]*?)```", options: [])
        guard let regex = pattern else {
            result.append(.text(text))
            return result
        }
        var lastEnd = text.startIndex
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        for match in matches {
            if match.range.location > lastEnd.utf16Offset(in: text) {
                let textRange = lastEnd..<text.index(text.startIndex, offsetBy: match.range.location)
                let textContent = String(text[textRange])
                if !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.text(textContent))
                }
            }
            let codeRange = match.range(at: 1)
            let code = nsText.substring(with: codeRange).trimmingCharacters(in: .newlines)
            if !code.isEmpty {
                result.append(.code(code))
            }
            lastEnd = text.index(text.startIndex, offsetBy: match.range.location + match.range.length)
        }
        if lastEnd < text.endIndex {
            let remaining = String(text[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.text(remaining))
            }
        }
        if result.isEmpty {
            result.append(.text(text))
        }
        return result
    }

    private func markdownText(_ content: String) -> AttributedString {
        (try? AttributedString(markdown: content)) ?? AttributedString(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                switch segment {
                case .text(let content):
                    Text(markdownText(content))
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let code):
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack {
                            Spacer()
                            Button {
                                onCopyCode(code)
                            } label: {
                                Label(localizedAppText("Copy", de: "Kopieren"), systemImage: "doc.on.doc")
                                    .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                        MessageTextView(text: code)
                            .frame(minHeight: 36, maxHeight: 300)
                            .padding(8)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(contentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
