import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sprachhilfe", category: "ChatService")

@MainActor
class ChatService: ObservableObject {
    /// Fixed pseudo-session that owns documents belonging to the global, cross-chat library.
    static let globalLibrarySessionId = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!

    private var modelContainer: ModelContainer?
    private var modelContext: ModelContext?

    @Published private(set) var sessions: [ChatSession] = []

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {
        setupModelContainer(appSupportDirectory: appSupportDirectory)
    }

    private func setupModelContainer(appSupportDirectory: URL) {
        let schema = Schema([ChatSession.self, ChatMessage.self, ChatDocument.self, SystemPromptPreset.self, ChatPreset.self])
        let storeDir = appSupportDirectory
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("chat.store")
        let config = ModelConfiguration(url: storeURL)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                let url = storeDir.appendingPathComponent("chat.store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                modelContainer = try ModelContainer(for: schema, configurations: [config])
            } catch {
                logger.error("Failed to create chat ModelContainer after reset: \(error.localizedDescription)")
                return
            }
        }
        modelContext = ModelContext(modelContainer!)
        modelContext?.autosaveEnabled = true
        loadSessions()
    }

    // MARK: - Sessions

    func loadSessions() {
        guard let context = modelContext else { return }
        do {
            let descriptor = FetchDescriptor<ChatSession>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            sessions = try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch chat sessions: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func createSession(providerId: String, modelId: String?, memoryPluginId: String) -> ChatSession? {
        guard let context = modelContext else { return nil }
        let session = ChatSession(
            providerId: providerId,
            modelId: modelId,
            memoryPluginId: memoryPluginId
        )
        context.insert(session)
        save()
        loadSessions()
        return session
    }

    func deleteSession(_ session: ChatSession) {
        guard let context = modelContext else { return }
        let sessionId = session.id
        context.delete(session)
        if let msgDelete = try? context.delete(
            model: ChatMessage.self,
            where: #Predicate { $0.sessionId == sessionId }
        ) {
            _ = msgDelete
        }
        save()
        loadSessions()
    }

    func updateSession(_ session: ChatSession) {
        session.updatedAt = Date()
        save()
        loadSessions()
    }

    // MARK: - System Prompt Presets

    func presets() -> [SystemPromptPreset] {
        guard let context = modelContext else { return [] }
        do {
            let descriptor = FetchDescriptor<SystemPromptPreset>(
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch system prompt presets: \(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func createPreset(title: String, content: String) -> SystemPromptPreset? {
        guard let context = modelContext else { return nil }
        let preset = SystemPromptPreset(title: title, content: content)
        context.insert(preset)
        save()
        return preset
    }

    func updatePreset(_ preset: SystemPromptPreset) {
        preset.updatedAt = Date()
        save()
    }

    func deletePreset(_ preset: SystemPromptPreset) {
        guard let context = modelContext else { return }
        context.delete(preset)
        save()
    }

    // MARK: - Messages

    func messages(for sessionId: UUID) -> [ChatMessage] {
        guard let context = modelContext else { return [] }
        do {
            let descriptor = FetchDescriptor<ChatMessage>(
                predicate: #Predicate { $0.sessionId == sessionId },
                sortBy: [SortDescriptor(\.timestamp, order: .forward)]
            )
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch messages: \(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func addMessage(
        sessionId: UUID,
        role: String,
        content: String,
        retrievalSummary: String? = nil
    ) -> ChatMessage? {
        guard let context = modelContext else { return nil }
        let message = ChatMessage(
            sessionId: sessionId,
            role: role,
            content: content,
            retrievalSummary: retrievalSummary
        )
        context.insert(message)
        if let session = sessions.first(where: { $0.id == sessionId }) {
            session.updatedAt = Date()
            if role == "user" && session.title == String(localized: "New Chat") {
                session.title = String(content.prefix(40))
            }
        }
        save()
        return message
    }

    func clearMessages(for sessionId: UUID) {
        guard let context = modelContext else { return }
        try? context.delete(
            model: ChatMessage.self,
            where: #Predicate { $0.sessionId == sessionId }
        )
        save()
    }

    func updateMessage(_ message: ChatMessage, content: String) {
        message.content = content
        save()
    }

    /// Creates a new assistant message that replaces the given one (conversation branch).
    /// The old message is preserved but hidden; the new one carries `replacesMessageId`.
    @discardableResult
    func replaceMessage(_ message: ChatMessage, withContent content: String, retrievalSummary: String? = nil) -> ChatMessage? {
        guard let context = modelContext else { return nil }
        let newMessage = ChatMessage(
            sessionId: message.sessionId,
            role: message.role,
            content: content,
            retrievalSummary: retrievalSummary,
            replacesMessageId: message.id
        )
        context.insert(newMessage)
        if let session = sessions.first(where: { $0.id == message.sessionId }) {
            session.updatedAt = Date()
        }
        save()
        return newMessage
    }

    /// All branch variants of a message, newest first. When a message has no branches,
    /// returns only itself.
    func branchVariants(of message: ChatMessage, in sessionId: UUID) -> [ChatMessage] {
        guard let context = modelContext else { return [message] }
        let all = (try? context.fetch(FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionId == sessionId },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        ))) ?? []
        // Include the message itself plus any that replace it, plus any that replace those
        var variants: [ChatMessage] = [message]
        var candidates = all.filter { $0.replacesMessageId == message.id }
        while let next = candidates.first {
            variants.append(next)
            candidates = all.filter { $0.replacesMessageId == next.id }
        }
        return variants
    }

    /// Deletes all messages in `sessionId` that come after `message` (by timestamp) — used by
    /// edit-and-resend and regenerate, which replace everything from that point onward.
    func deleteMessages(after message: ChatMessage, in sessionId: UUID) {
        guard let context = modelContext else { return }
        let cutoff = message.timestamp
        try? context.delete(
            model: ChatMessage.self,
            where: #Predicate { $0.sessionId == sessionId && $0.timestamp > cutoff }
        )
        save()
    }

    // MARK: - Documents

    func documents(for sessionId: UUID) -> [ChatDocument] {
        guard let context = modelContext else { return [] }
        do {
            let descriptor = FetchDescriptor<ChatDocument>(
                predicate: #Predicate { $0.sessionId == sessionId },
                sortBy: [SortDescriptor(\.importedAt, order: .forward)]
            )
            return try context.fetch(descriptor)
        } catch {
            logger.error("Failed to fetch documents: \(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func addDocument(
        id: UUID,
        sessionId: UUID,
        fileName: String,
        fileSize: Int64,
        chunkCount: Int,
        isGlobal: Bool = false,
        category: String = "",
        memoryPluginId: String
    ) -> ChatDocument? {
        guard let context = modelContext else { return nil }
        let doc = ChatDocument(
            id: id,
            sessionId: sessionId,
            fileName: fileName,
            fileSize: fileSize,
            chunkCount: chunkCount,
            isGlobal: isGlobal,
            category: category,
            indexDocumentId: id,
            memoryPluginId: memoryPluginId
        )
        context.insert(doc)
        save()
        return doc
    }

    func deleteDocument(_ document: ChatDocument) {
        guard let context = modelContext else { return }
        let docId = document.id
        context.delete(document)
        save()
        _ = docId
    }

    /// Distinct set of non-empty categories across all stored documents, used to power category
    /// autocomplete when the user assigns/filters categories.
    func allDocumentCategories() -> [String] {
        guard let context = modelContext else { return [] }
        do {
            let descriptor = FetchDescriptor<ChatDocument>()
            let all = try context.fetch(descriptor)
            let categories = Set(all.map(\.category).filter { !$0.isEmpty })
            return categories.sorted()
        } catch {
            logger.error("Failed to fetch document categories: \(error.localizedDescription)")
            return []
        }
    }

    func updateDocumentCategory(_ document: ChatDocument, category: String) {
        document.category = category
        save()
    }

    // MARK: - Chat Presets

    func chatPresets() -> [ChatPreset] {
        guard let context = modelContext else { return [] }
        do {
            return try context.fetch(FetchDescriptor<ChatPreset>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
        } catch {
            logger.error("Failed to fetch chat presets: \(error.localizedDescription)")
            return []
        }
    }

    func createChatPreset(from session: ChatSession) -> ChatPreset? {
        guard let context = modelContext else { return nil }
        let prefix = String(localized: "Preset: ")
        let preset = ChatPreset(
            title: prefix + session.title,
            providerId: session.providerId,
            modelId: session.modelId,
            memoryPluginId: session.memoryPluginId,
            responseMode: session.responseMode,
            systemPrompt: session.systemPrompt
        )
        context.insert(preset)
        save()
        return preset
    }

    func applyPreset(_ preset: ChatPreset, to session: ChatSession) {
        session.providerId = preset.providerId
        session.modelId = preset.modelId
        session.memoryPluginId = preset.memoryPluginId
        session.responseMode = preset.responseMode
        session.systemPrompt = preset.systemPrompt
        updateSession(session)
    }

    func deleteChatPreset(_ preset: ChatPreset) {
        guard let context = modelContext else { return }
        context.delete(preset)
        save()
    }

    // MARK: - Private

    private func save() {
        guard let context = modelContext else { return }
        do {
            try context.save()
        } catch {
            logger.error("Failed to save: \(error.localizedDescription)")
        }
    }
}
