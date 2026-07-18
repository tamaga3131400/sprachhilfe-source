import Foundation
import AppKit
import Combine
import SprachhilfePluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sprachhilfe", category: "ChatViewModel")

struct ChatDocumentImportActivity: Identifiable, Equatable {
    enum State: Equatable {
        case importing
        case failed(String)
    }

    let id: UUID
    let name: String
    let state: State
}

private struct ChatGenerationResult {
    let text: String
    let retrievalSummary: String?
}

@MainActor
final class ChatViewModel: ObservableObject {
    let chatService: ChatService
    let documentService: DocumentService
    private let promptProcessingService: PromptProcessingService
    private let pluginManager: PluginManager
    private let audioRecorderService: AudioRecorderService
    private let modelManagerService: ModelManagerService
    private let settingsViewModel: SettingsViewModel

    @Published var sessions: [ChatSession] = []
    @Published var currentSession: ChatSession?
    @Published var messages: [ChatMessage] = []
    @Published var documents: [ChatDocument] = []
    /// One-shot delivery of a finished dictation to the (isolated) input bar subview, which
    /// appends it to its own local text. Avoids a published per-keystroke input store.
    @Published var dictatedText: String?
    @Published var isSending: Bool = false
    @Published var isRecording: Bool = false
    @Published var isTranscribingVoice: Bool = false
    @Published var processingStatus: String?
    @Published var errorMessage: String?
    @Published private(set) var importActivities: [ChatDocumentImportActivity] = []
    /// Non-nil while a message row is in inline-edit mode.
    @Published var editingMessageId: UUID?

    /// The in-flight response task, if any. Stored so `stopGenerating()` can cancel it.
    private var sendTask: Task<Void, Never>?

    /// Inputs longer than this (by lines or chars) are processed in chunks (map-reduce) so
    /// local models never receive a context large enough to crash the MLX runtime.
    private static let chunkMaxLines = 300
    static let chunkMaxCharsDefault = 24000
    static let chunkMaxCharsRange = 4000...200000
    /// Safety cap on how many times the reduce step recurses before returning what it has.
    private static let maxReduceDepth = 4

    /// User-configurable budget (≈ chars per chunk). Higher = fewer, larger chunks (faster but
    /// more memory). Persisted; the user tunes it per their model/machine.
    @Published var chunkMaxChars: Int {
        didSet {
            let clamped = min(max(chunkMaxChars, Self.chunkMaxCharsRange.lowerBound), Self.chunkMaxCharsRange.upperBound)
            if clamped != chunkMaxChars {
                chunkMaxChars = clamped
                return
            }
            UserDefaults.standard.set(chunkMaxChars, forKey: UserDefaultsKeys.chatChunkMaxChars)
        }
    }

    var availableLLMProviders: [(id: String, displayName: String)] {
        promptProcessingService.availableProviders.map { (id: $0.id, displayName: $0.displayName) }
    }

    var availableMemoryPlugins: [MemoryStoragePlugin] {
        pluginManager.memoryStoragePlugins
    }

    var activeSessions: [ChatSession] {
        sessions.filter { !$0.isArchived }
    }

    var archivedSessions: [ChatSession] {
        sessions.filter(\.isArchived)
    }

    var isImportingDocuments: Bool {
        importActivities.contains { activity in
            if case .importing = activity.state { return true }
            return false
        }
    }

    var currentResponseMode: ChatResponseMode {
        guard let rawValue = currentSession?.responseMode else { return .balanced }
        return ChatResponseMode(rawValue: rawValue) ?? .balanced
    }

    private func memoryPluginId(of plugin: MemoryStoragePlugin) -> String {
        type(of: plugin).pluginId
    }

    init(
        chatService: ChatService,
        documentService: DocumentService,
        promptProcessingService: PromptProcessingService,
        pluginManager: PluginManager,
        audioRecorderService: AudioRecorderService,
        modelManagerService: ModelManagerService,
        settingsViewModel: SettingsViewModel
    ) {
        self.chatService = chatService
        self.documentService = documentService
        self.promptProcessingService = promptProcessingService
        self.pluginManager = pluginManager
        self.audioRecorderService = audioRecorderService
        self.modelManagerService = modelManagerService
        self.settingsViewModel = settingsViewModel
        let storedChunk = UserDefaults.standard.integer(forKey: UserDefaultsKeys.chatChunkMaxChars)
        self.chunkMaxChars = storedChunk == 0
            ? Self.chunkMaxCharsDefault
            : min(max(storedChunk, Self.chunkMaxCharsRange.lowerBound), Self.chunkMaxCharsRange.upperBound)
        self.sessions = chatService.sessions
        observeChatService()
    }

    /// True when the active chat uses an in-process local model (where the chunk-size setting
    /// actually applies). Used to show/hide the chunk-size control.
    var isCurrentProviderLocal: Bool {
        guard let providerId = currentSession?.providerId, !providerId.isEmpty else { return false }
        return PluginManager.shared.llmProvider(for: providerId)?.isLocalModel ?? false
    }

    private func observeChatService() {
        chatService.$sessions
            .receive(on: DispatchQueue.main)
            .assign(to: &$sessions)
    }

    // MARK: - Session Management

    func createNewSession() {
        let defaultProvider = promptProcessingService.selectedProviderId
        let defaultModel = promptProcessingService.selectedCloudModel
        let defaultMemory = availableMemoryPlugins.first(where: { $0.isReady }).map { memoryPluginId(of: $0) } ?? ""

        guard let session = chatService.createSession(
            providerId: defaultProvider,
            modelId: defaultModel.isEmpty ? nil : defaultModel,
            memoryPluginId: defaultMemory
        ) else { return }
        selectSession(session)
    }

    func selectSession(_ session: ChatSession) {
        currentSession = session
        messages = chatService.messages(for: session.id)
        documents = chatService.documents(for: session.id)
        errorMessage = nil
    }

    func deleteSession(_ session: ChatSession) {
        Task {
            do {
                let sessionDocuments = chatService.documents(for: session.id)
                for document in sessionDocuments {
                    guard let memoryPlugin = resolvedMemoryPlugin(for: document), memoryPlugin.isReady else {
                        throw DocumentService.ImportError(message: String(localized: "The document storage used by this chat is not available. Re-enable it before deleting the chat."))
                    }
                    try await documentService.deleteDocument(
                        document,
                        memoryPlugin: memoryPlugin,
                        chatService: chatService
                    )
                }

                chatService.deleteSession(session)
                if self.currentSession?.id == session.id {
                    if let nextSession = self.activeSessions.first(where: { $0.id != session.id }) {
                        self.selectSession(nextSession)
                    } else {
                        self.currentSession = nil
                        self.messages = []
                        self.documents = []
                    }
                }
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func updateSessionProvider(_ providerId: String) {
        guard let session = currentSession else { return }
        session.providerId = providerId
        chatService.updateSession(session)
    }

    func updateSessionModel(_ modelId: String?) {
        guard let session = currentSession else { return }
        session.modelId = modelId
        chatService.updateSession(session)
    }

    func updateSessionMemoryPlugin(_ pluginId: String) {
        guard let session = currentSession else { return }
        session.memoryPluginId = pluginId
        chatService.updateSession(session)
    }

    func updateSessionResponseMode(_ mode: ChatResponseMode) {
        guard let session = currentSession else { return }
        session.responseMode = mode.rawValue
        chatService.updateSession(session)
        objectWillChange.send()
    }

    func isDocumentIncluded(_ document: ChatDocument) -> Bool {
        !(currentSession?.inactiveDocumentIds.contains(document.id.uuidString) ?? false)
    }

    func toggleDocumentInclusion(_ document: ChatDocument) {
        guard let session = currentSession else { return }
        let id = document.id.uuidString
        if let index = session.inactiveDocumentIds.firstIndex(of: id) {
            session.inactiveDocumentIds.remove(at: index)
        } else {
            session.inactiveDocumentIds.append(id)
        }
        chatService.updateSession(session)
        objectWillChange.send()
    }

    func renameSession(_ session: ChatSession, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        session.title = trimmed
        chatService.updateSession(session)
    }

    func togglePinned(_ session: ChatSession) {
        session.isPinned.toggle()
        chatService.updateSession(session)
    }

    func archiveSession(_ session: ChatSession) {
        session.isArchived = true
        session.isPinned = false
        chatService.updateSession(session)
        if currentSession?.id == session.id {
            if let nextSession = activeSessions.first(where: { $0.id != session.id }) {
                selectSession(nextSession)
            } else {
                currentSession = nil
                messages = []
                documents = []
            }
        }
    }

    func restoreSession(_ session: ChatSession) {
        session.isArchived = false
        chatService.updateSession(session)
    }

    /// Cheap, per-keystroke-safe update: mutate the model in place and let SwiftData autosave
    /// persist it. Deliberately does NOT reload the session list or bump `updatedAt` (which
    /// would re-fetch + re-sort + rebuild the sidebar on every character → severe typing lag).
    func updateSessionSystemPrompt(_ prompt: String) {
        guard let session = currentSession else { return }
        session.systemPrompt = prompt
    }

    var systemPromptPresets: [SystemPromptPreset] {
        chatService.presets()
    }

    func updateSessionIncludeGlobalLibrary(_ include: Bool) {
        guard let session = currentSession else { return }
        session.includeGlobalLibrary = include
        chatService.updateSession(session)
        objectWillChange.send()
    }

    func updateSessionActiveDocumentCategories(_ categories: [String]) {
        guard let session = currentSession else { return }
        session.activeDocumentCategories = categories
        chatService.updateSession(session)
        objectWillChange.send()
    }

    func updateSessionUseKnowledgeGraph(_ use: Bool) {
        guard let session = currentSession else { return }
        session.useKnowledgeGraph = use
        chatService.updateSession(session)
        objectWillChange.send()
    }

    /// Distinct categories currently present among the global-library documents, for building
    /// the category filter menu. Session-scoped documents are excluded — categories only apply
    /// to the global library per the filtering design.
    var globalLibraryCategories: [String] {
        chatService.documents(for: ChatService.globalLibrarySessionId)
            .map(\.category)
            .filter { !$0.isEmpty }
            .reduce(into: Set<String>()) { $0.insert($1) }
            .sorted()
    }

    // MARK: - Voice Input (Dictation)

    func toggleRecording() {
        if isRecording {
            Task { await stopRecordingAndTranscribe() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        errorMessage = nil
        do {
            _ = try await audioRecorderService.startRecording(
                micEnabled: true,
                systemAudioEnabled: false,
                format: .wav
            )
            isRecording = true
        } catch {
            isRecording = false
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecordingAndTranscribe() async {
        isRecording = false
        _ = await audioRecorderService.stopRecording()
        let buffer = audioRecorderService.getCurrentBuffer()
        guard buffer.count > 8000 else { return } // at least ~0.5s of audio

        isTranscribingVoice = true
        defer { isTranscribingVoice = false }
        do {
            let result = try await modelManagerService.transcribe(
                audioSamples: buffer,
                languageSelection: settingsViewModel.languageSelection,
                task: .transcribe
            )
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            dictatedText = text
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func modelsForProvider(_ providerId: String) -> [PluginModelInfo] {
        promptProcessingService.modelsForProvider(providerId)
    }

    // MARK: - Document Import

    func importDocument(url: URL) {
        guard let session = currentSession else { return }
        guard let memoryPlugin = resolvedMemoryPlugin(), memoryPlugin.isReady else {
            errorMessage = String(localized: "Select a ready vector store before importing documents.")
            return
        }

        let activityId = beginImport(named: url.lastPathComponent)

        Task {
            do {
                let document = try await documentService.importDocument(
                    url: url,
                    sessionId: session.id,
                    memoryPlugin: memoryPlugin,
                    chatService: chatService
                )
                await MainActor.run {
                    self.documents = self.chatService.documents(for: session.id)
                    self.finishImport(activityId)
                    Self.autoExtractGraphIfEnabled(document: document, memoryPlugin: memoryPlugin)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.failImport(activityId, message: error.localizedDescription)
                }
            }
        }
    }

    func importURL(_ urlString: String) {
        guard let session = currentSession else { return }
        guard let memoryPlugin = resolvedMemoryPlugin(), memoryPlugin.isReady else {
            errorMessage = String(localized: "Select a ready vector store before importing documents.")
            return
        }
        let name = URL(string: urlString)?.host ?? urlString
        let activityId = beginImport(named: name)
        Task {
            do {
                let document = try await documentService.importURL(
                    urlString: urlString,
                    sessionId: session.id,
                    memoryPlugin: memoryPlugin,
                    chatService: chatService
                )
                await MainActor.run {
                    self.documents = self.chatService.documents(for: session.id)
                    self.finishImport(activityId)
                    Self.autoExtractGraphIfEnabled(document: document, memoryPlugin: memoryPlugin)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.failImport(activityId, message: error.localizedDescription)
                }
            }
        }
    }

    /// Fire-and-forget knowledge-graph extraction, only when the user opted into automatic
    /// extraction on import (default off - extraction costs several LLM calls per document)
    /// and a graph plugin is actually ready; a no-op otherwise.
    fileprivate static func autoExtractGraphIfEnabled(document: ChatDocument, memoryPlugin: MemoryStoragePlugin) {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.graphAutoExtract) else { return }
        GraphExtractionService.shared?.extract(document: document, memoryPlugin: memoryPlugin)
    }

    func deleteDocument(_ document: ChatDocument) {
        guard let memoryPlugin = resolvedMemoryPlugin(for: document), memoryPlugin.isReady else {
            errorMessage = String(localized: "The storage used by this document is not available. Re-enable it before deleting the document.")
            return
        }
        Task {
            do {
                try await documentService.deleteDocument(
                    document,
                    memoryPlugin: memoryPlugin,
                    chatService: chatService
                )
                await MainActor.run {
                    if let sessionId = self.currentSession?.id {
                        self.currentSession?.inactiveDocumentIds.removeAll { $0 == document.id.uuidString }
                        if let session = self.currentSession {
                            self.chatService.updateSession(session)
                        }
                        self.documents = self.chatService.documents(for: sessionId)
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func dismissImportActivity(_ activity: ChatDocumentImportActivity) {
        importActivities.removeAll { $0.id == activity.id }
    }

    // MARK: - Chat (RAG Flow)

    func clearDictatedText() {
        dictatedText = nil
    }

    func send(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let session = currentSession else {
            errorMessage = String(localized: "No active chat session.")
            return
        }
        guard !session.providerId.isEmpty else {
            errorMessage = String(localized: "No LLM provider selected.")
            return
        }

        chatService.addMessage(sessionId: session.id, role: "user", content: text)
        messages = chatService.messages(for: session.id)

        generateAndAppendResponse(question: text, session: session)
    }

    func stopGenerating() {
        sendTask?.cancel()
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Edit & Regenerate

    func beginEditing(_ message: ChatMessage) {
        editingMessageId = message.id
    }

    func cancelEditing() {
        editingMessageId = nil
    }

    /// Saves the edited text, drops everything that came after the original message (its old
    /// reply and any later turns), and regenerates a response using the session's current
    /// provider/model — this is how switching the LLM before saving takes effect.
    func saveEdit(_ message: ChatMessage, newContent: String) {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = currentSession else { return }

        chatService.updateMessage(message, content: trimmed)
        chatService.deleteMessages(after: message, in: session.id)
        messages = chatService.messages(for: session.id)
        editingMessageId = nil

        generateAndAppendResponse(question: trimmed, session: session)
    }

    /// Regenerates the reply to the user message that preceded `assistantMessage`, creating
    /// a new conversation branch instead of deleting the old reply.
    func regenerate(_ assistantMessage: ChatMessage) {
        guard let session = currentSession,
              let index = messages.firstIndex(where: { $0.id == assistantMessage.id }),
              let precedingUserMessage = messages[..<index].last(where: { $0.role == "user" })
        else { return }

        messages = chatService.messages(for: session.id)

        generateBranchResponse(question: precedingUserMessage.content, replaceMessage: assistantMessage, session: session)
    }

    func branchVariants(of message: ChatMessage) -> [ChatMessage] {
        guard let session = currentSession else { return [message] }
        return chatService.branchVariants(of: message, in: session.id)
    }

    func switchToBranch(_ branch: ChatMessage, in session: ChatSession) {
        guard let originalId = branch.replacesMessageId else { return }
        let allMessages = chatService.messages(for: session.id)
        // Find all messages in the chain that this branch replaces (original + any intermediate)
        var replacedIds = Set<UUID>()
        var currentId: UUID? = originalId
        while let id = currentId {
            replacedIds.insert(id)
            currentId = allMessages.first(where: { $0.replacesMessageId == id })?.id
        }
        // Add self and any newer branches to the hidden set
        var cursor = branch
        replacedIds.insert(cursor.id)
        while let newer = allMessages.first(where: { $0.replacesMessageId == cursor.id }) {
            replacedIds.insert(newer.id)
            cursor = newer
        }
        // Re-evaluate: we want to show the branch chain from the top
        messages = chatService.messages(for: session.id)
        objectWillChange.send()
    }

    // MARK: - Chat Presets

    var chatPresets: [ChatPreset] {
        chatService.chatPresets()
    }

    func saveCurrentAsPreset() {
        guard let session = currentSession else { return }
        _ = chatService.createChatPreset(from: session)
    }

    func applyPresetToCurrent(_ preset: ChatPreset) {
        guard let session = currentSession else { return }
        chatService.applyPreset(preset, to: session)
        // Refresh local state
        messages = chatService.messages(for: session.id)
        documents = chatService.documents(for: session.id)
        objectWillChange.send()
    }

    func deletePreset(_ preset: ChatPreset) {
        chatService.deleteChatPreset(preset)
    }

    /// Runs the model (RAG or, for local models, chunked map-reduce) for `question` and appends
    /// the assistant's reply. Shared by `send`, `saveEdit`, and `regenerate`. Cancellable via
    /// `stopGenerating()` — cancellation ends the run silently (no error, no partial message).
    private func generateAndAppendResponse(question: String, session: ChatSession) {
        isSending = true
        errorMessage = nil

        // Only in-process local models (MLX/Gemma) need chunking — they crash on oversized
        // context. Cloud providers get the full text in a single pass.
        let isLocal = PluginManager.shared.llmProvider(for: session.providerId)?.isLocalModel ?? false
        let maxChars = chunkMaxChars

        sendTask = Task {
            do {
                let chunks = Self.makeChunks(question, maxLines: Self.chunkMaxLines, maxChars: maxChars)
                let generation: ChatGenerationResult
                if isLocal && chunks.count > 1 && currentResponseMode != .documentGrounded {
                    generation = ChatGenerationResult(
                        text: try await runChunkedAnalysis(chunks: chunks, session: session),
                        retrievalSummary: String(localized: "Document retrieval was skipped because this long local-model request was processed in parts.")
                    )
                } else {
                    generation = try await runRAGFlow(question: question, session: session)
                }
                try Task.checkCancellation()
                await MainActor.run {
                    self.chatService.addMessage(
                        sessionId: session.id,
                        role: "assistant",
                        content: generation.text,
                        retrievalSummary: generation.retrievalSummary
                    )
                    self.messages = self.chatService.messages(for: session.id)
                    self.isSending = false
                    self.processingStatus = nil
                }
            } catch {
                await MainActor.run {
                    self.isSending = false
                    self.processingStatus = nil
                    let wasCancelled = (error is CancellationError)
                        || Task.isCancelled
                        || (error as? URLError)?.code == .cancelled
                    if !wasCancelled {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Like `generateAndAppendResponse`, but replaces an existing assistant message
    /// (conversation branch) instead of appending.
    private func generateBranchResponse(question: String, replaceMessage: ChatMessage, session: ChatSession) {
        isSending = true
        errorMessage = nil

        let isLocal = PluginManager.shared.llmProvider(for: session.providerId)?.isLocalModel ?? false
        let maxChars = chunkMaxChars

        sendTask = Task {
            do {
                let chunks = Self.makeChunks(question, maxLines: Self.chunkMaxLines, maxChars: maxChars)
                let generation: ChatGenerationResult
                if isLocal && chunks.count > 1 && currentResponseMode != .documentGrounded {
                    generation = ChatGenerationResult(
                        text: try await runChunkedAnalysis(chunks: chunks, session: session),
                        retrievalSummary: String(localized: "Document retrieval was skipped because this long local-model request was processed in parts.")
                    )
                } else {
                    generation = try await runRAGFlow(question: question, session: session)
                }
                try Task.checkCancellation()
                await MainActor.run {
                    _ = self.chatService.replaceMessage(
                        replaceMessage,
                        withContent: generation.text,
                        retrievalSummary: generation.retrievalSummary
                    )
                    self.messages = self.chatService.messages(for: session.id)
                    self.isSending = false
                    self.processingStatus = nil
                }
            } catch {
                await MainActor.run {
                    self.isSending = false
                    self.processingStatus = nil
                    let wasCancelled = (error is CancellationError)
                        || Task.isCancelled
                        || (error as? URLError)?.code == .cancelled
                    if !wasCancelled {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Map-reduce over an oversized input: analyze each chunk, then synthesize one answer.
    private func runChunkedAnalysis(chunks: [String], session: ChatSession) async throws -> String {
        let custom = session.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = custom.isEmpty
            ? "You are a helpful assistant. Analyze the provided text clearly and concisely."
            : custom

        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            await MainActor.run {
                self.processingStatus = String(localized: "Analyzing part \(index + 1)/\(chunks.count)…")
            }
            let prompt = """
            \(base)

            This is part \(index + 1) of \(chunks.count) of a longer text. Analyze only this part.
            """
            let part = try await promptProcessingService.process(
                prompt: prompt,
                text: chunk,
                providerOverride: session.providerId,
                cloudModelOverride: session.modelId,
                skipMemoryInjection: true
            )
            // Local models may end their generation stream early on cancellation without
            // throwing (the plugin call returns "successfully" with partial/empty text) — check
            // again here so a stop request during this chunk still discards the result.
            try Task.checkCancellation()
            partials.append(part.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Merge the partials into ONE coherent analysis, recursively if they don't fit in a
        // single reduce call (so large outputs still converge instead of being dumped as parts).
        return try await hierarchicalReduce(partials, base: base, session: session, depth: 0)
    }

    /// Recursively merges partial analyses into a single result. If the combined text is too
    /// large for one synthesis call, it is reduced in groups, level by level, until one remains.
    private func hierarchicalReduce(
        _ texts: [String],
        base: String,
        session: ChatSession,
        depth: Int
    ) async throws -> String {
        try Task.checkCancellation()
        if texts.count == 1 { return texts[0] }

        let joined = texts.joined(separator: "\n\n---\n\n")
        let groups = Self.makeChunks(joined, maxLines: Self.chunkMaxLines, maxChars: chunkMaxChars)

        let synthesisPrompt = """
        \(base)

        Below are analyses of consecutive parts of ONE log/text. Merge them into a single \
        coherent overall analysis: group recurring or identical findings together and count how \
        often they occur, remove duplicates, and present the result in a clear, structured way.
        """

        // Base case: everything fits → one final synthesis.
        if groups.count <= 1 {
            await MainActor.run { self.processingStatus = String(localized: "Combining results…") }
            let synthesized = try await promptProcessingService.process(
                prompt: synthesisPrompt,
                text: joined,
                providerOverride: session.providerId,
                cloudModelOverride: session.modelId,
                skipMemoryInjection: true
            )
            try Task.checkCancellation()
            return synthesized.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Safety net: stop recursing and return what we have rather than loop forever.
        guard depth < Self.maxReduceDepth else { return joined }

        var reduced: [String] = []
        for (index, group) in groups.enumerated() {
            try Task.checkCancellation()
            await MainActor.run {
                self.processingStatus = String(localized: "Combining results (level \(depth + 1), \(index + 1)/\(groups.count))…")
            }
            let synthesized = try await promptProcessingService.process(
                prompt: synthesisPrompt,
                text: group,
                providerOverride: session.providerId,
                cloudModelOverride: session.modelId,
                skipMemoryInjection: true
            )
            try Task.checkCancellation()
            reduced.append(synthesized.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try await hierarchicalReduce(reduced, base: base, session: session, depth: depth + 1)
    }

    /// Splits text into chunks of at most `maxLines` lines and `maxChars` characters.
    static func makeChunks(_ text: String, maxLines: Int, maxChars: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var currentChars = 0
        for line in lines {
            if !current.isEmpty && (current.count >= maxLines || currentChars + line.count > maxChars) {
                chunks.append(current.joined(separator: "\n"))
                current = []
                currentChars = 0
            }
            current.append(line)
            currentChars += line.count + 1
        }
        if !current.isEmpty {
            chunks.append(current.joined(separator: "\n"))
        }
        return chunks
    }

    private func allowedGraphDocumentIDs(for session: ChatSession) -> [String] {
        let sessionDocumentIDs = chatService.documents(for: session.id)
            .filter { !session.inactiveDocumentIds.contains($0.id.uuidString) }
            .compactMap(\.indexDocumentId)
            .map { $0.uuidString }

        let globalDocumentIDs: [String]
        if session.includeGlobalLibrary {
            globalDocumentIDs = chatService.documents(for: ChatService.globalLibrarySessionId)
                .filter { document in
                    guard !session.activeDocumentCategories.isEmpty else { return true }
                    return !document.category.isEmpty
                        && session.activeDocumentCategories.contains(document.category)
                }
                .compactMap(\.indexDocumentId)
                .map { $0.uuidString }
        } else {
            globalDocumentIDs = []
        }

        return Array(Set(sessionDocumentIDs + globalDocumentIDs)).sorted()
    }

    private func runRAGFlow(question: String, session: ChatSession) async throws -> ChatGenerationResult {
        var contextBlock = ""
        var retrievalSummary: String?
        let responseMode = ChatResponseMode(rawValue: session.responseMode) ?? .balanced

        // Kicked off before the vector search so the Neo4j round-trip overlaps with it instead
        // of adding to the total latency; awaited further down once both are in flight.
        let graphPlugin: GraphStoragePlugin? = (responseMode != .general && session.useKnowledgeGraph)
            ? pluginManager.graphStoragePlugins.first(where: { $0.isReady })
            : nil
        let allowedGraphDocumentIDs = allowedGraphDocumentIDs(for: session)
        let graphTask: Task<GraphContext?, Never>?
        if let graphPlugin, !allowedGraphDocumentIDs.isEmpty {
            graphTask = Task {
                do {
                    return try await graphPlugin.retrieveSubgraph(
                        matching: question,
                        allowedDocumentIDs: allowedGraphDocumentIDs,
                        maxNodes: 25,
                        maxEdges: 50,
                        charBudget: 4000
                    )
                } catch {
                    logger.warning("Knowledge graph retrieval failed: \(error.localizedDescription)")
                    return nil
                }
            }
        } else {
            graphTask = nil
        }

        if responseMode != .general, let memoryPlugin = resolvedMemoryPlugin(), memoryPlugin.isReady {
            let query = MemoryQuery(
                text: question,
                maxResults: 50,
                minConfidence: 0.3
            )
            do {
                let allResults = try await memoryPlugin.search(query)
                // Scope filter: only this chat's documents, plus opted-in global-library
                // documents. Legacy unscoped memories are deliberately excluded so personal
                // memory cannot silently become document context.
                let results = allResults.filter { result in
                    let meta = result.entry.metadata
                    if meta["scope"] == "session", meta["sessionId"] == session.id.uuidString {
                        guard let documentId = meta["docId"] else { return false }
                        return !session.inactiveDocumentIds.contains(documentId)
                    }
                    if meta["scope"] == "global" {
                        guard session.includeGlobalLibrary else { return false }
                        guard !session.activeDocumentCategories.isEmpty else { return true }
                        guard let category = meta["category"], !category.isEmpty else { return false }
                        return session.activeDocumentCategories.contains(category)
                    }
                    return false
                }
                .prefix(5)
                if !results.isEmpty {
                    let contextText = results
                        .map { result in
                            let source = result.entry.metadata["fileName"] ?? "Context"
                            let imported = result.entry.createdAt.formatted(date: .numeric, time: .omitted)
                            return "[\(source) (imported \(imported))]\n\(result.entry.content)"
                        }
                        .joined(separator: "\n---\n")
                    contextBlock = """

                    --- DOCUMENT CONTEXT ---
                    \(contextText)
                    --- END DOCUMENT CONTEXT ---
                    """
                    let sources = Array(Set(results.compactMap { $0.entry.metadata["fileName"] })).sorted()
                    retrievalSummary = String(localized: "Used \(results.count) document excerpt(s) from \(sources.joined(separator: ", ")).")
                } else {
                    retrievalSummary = String(localized: "No relevant document excerpts were found for this question.")
                }
            } catch {
                logger.warning("Memory search failed: \(error.localizedDescription)")
                retrievalSummary = String(localized: "Document search failed; the answer was generated without document context.")
            }
        } else if responseMode == .general {
            retrievalSummary = String(localized: "Document retrieval is turned off by General Chat mode.")
        } else if session.memoryPluginId.isEmpty {
            retrievalSummary = String(localized: "Document retrieval is turned off for this chat.")
        } else {
            retrievalSummary = String(localized: "The selected document store is not ready; the answer was generated without document context.")
        }

        if let graphTask, let graphContext = await graphTask.value, !graphContext.isEmpty {
            contextBlock += (contextBlock.isEmpty ? "" : "\n") + graphContext.promptBlock
            let graphSummary = String(localized: "Knowledge graph: \(graphContext.nodes.count) entities, \(graphContext.edges.count) relations.")
            retrievalSummary = [retrievalSummary, graphSummary].compactMap { $0 }.joined(separator: " ")
        }

        let history = messages
            .filter { $0.role != "system" }
            .suffix(10)
            .map { msg -> String in
                let speaker = msg.role == "user" ? "User" : "Assistant"
                return "\(speaker): \(msg.content)"
            }
            .joined(separator: "\n")

        if responseMode == .documentGrounded, contextBlock.isEmpty {
            return ChatGenerationResult(
                text: String(localized: "I could not find relevant information in the selected documents."),
                retrievalSummary: retrievalSummary
            )
        }

        let dateContext = ", and today is \(Date.now.formatted(date: .long, time: .omitted))"
        let customPrompt = session.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultPrompt: String
        switch responseMode {
        case .balanced, .general:
            defaultPrompt = "You are a helpful assistant. Answer the user's questions clearly and concisely."
        case .documentGrounded:
            defaultPrompt = "You are a document-grounded assistant. Answer only from the supplied document context."
        case .logAnalysis:
            defaultPrompt = "You are a log analysis assistant. Identify the important errors, likely causes, affected components, and practical next steps."
        }
        let basePrompt = (customPrompt.isEmpty ? defaultPrompt : customPrompt) + dateContext

        let modeInstruction: String
        switch responseMode {
        case .balanced:
            modeInstruction = "Use the document context below when relevant. If the answer is not in the context, say so honestly, and cite which document section your answer comes from."
        case .documentGrounded:
            modeInstruction = "Use only the document context below. Do not add facts that are not present in it. Cite the document section used."
        case .general:
            modeInstruction = ""
        case .logAnalysis:
            modeInstruction = "When document context is present, separate observed evidence from assumptions and structure the result with findings, likely causes, and next steps."
        }

        let systemPrompt: String
        if contextBlock.isEmpty {
            systemPrompt = basePrompt
        } else {
            systemPrompt = """
            \(basePrompt)

            \(modeInstruction)
            \(contextBlock)
            """
        }

        let userText: String
        if history.isEmpty {
            userText = question
        } else {
            userText = """
            Previous conversation:
            \(history)

            Current question:
            \(question)
            """
        }

        let answer = try await promptProcessingService.process(
            prompt: systemPrompt,
            text: userText,
            providerOverride: session.providerId,
            cloudModelOverride: session.modelId,
            skipMemoryInjection: true
        )
        return ChatGenerationResult(text: answer, retrievalSummary: retrievalSummary)
    }

    // MARK: - Helpers

    func resolvedMemoryPlugin() -> MemoryStoragePlugin? {
        guard let session = currentSession else { return nil }
        if !session.memoryPluginId.isEmpty {
            return availableMemoryPlugins.first(where: { memoryPluginId(of: $0) == session.memoryPluginId })
        }
        return availableMemoryPlugins.first(where: { $0.isReady })
    }

    private func resolvedMemoryPlugin(for document: ChatDocument) -> MemoryStoragePlugin? {
        if let pluginId = document.memoryPluginId, !pluginId.isEmpty {
            return availableMemoryPlugins.first(where: { memoryPluginId(of: $0) == pluginId })
        }
        return resolvedMemoryPlugin()
    }

    func displayName(forMemoryPlugin pluginId: String) -> String {
        availableMemoryPlugins.first(where: { memoryPluginId(of: $0) == pluginId })?.storageName ?? pluginId
    }

    private func beginImport(named name: String) -> UUID {
        let id = UUID()
        importActivities.append(ChatDocumentImportActivity(id: id, name: name, state: .importing))
        return id
    }

    private func finishImport(_ id: UUID) {
        importActivities.removeAll { $0.id == id }
    }

    private func failImport(_ id: UUID, message: String) {
        guard let index = importActivities.firstIndex(where: { $0.id == id }) else { return }
        let activity = importActivities[index]
        importActivities[index] = ChatDocumentImportActivity(
            id: activity.id,
            name: activity.name,
            state: .failed(message)
        )
    }
}
