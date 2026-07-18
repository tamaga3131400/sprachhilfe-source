import Foundation
import SwiftData

enum ChatResponseMode: String, CaseIterable, Identifiable {
    case balanced
    case documentGrounded
    case general
    case logAnalysis

    var id: String { rawValue }
}

@Model
final class ChatSession {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var providerId: String
    var modelId: String?
    var memoryPluginId: String
    var systemPrompt: String = ""
    var includeGlobalLibrary: Bool = false
    var activeDocumentCategories: [String] = []
    var inactiveDocumentIds: [String] = []
    var useKnowledgeGraph: Bool = false
    var responseMode: String = ChatResponseMode.balanced.rawValue
    var isPinned: Bool = false
    var isArchived: Bool = false

    init(
        id: UUID = UUID(),
        title: String = String(localized: "New Chat"),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        providerId: String = "",
        modelId: String? = nil,
        memoryPluginId: String = "",
        systemPrompt: String = "",
        includeGlobalLibrary: Bool = false,
        activeDocumentCategories: [String] = [],
        inactiveDocumentIds: [String] = [],
        useKnowledgeGraph: Bool = false,
        responseMode: String = ChatResponseMode.balanced.rawValue,
        isPinned: Bool = false,
        isArchived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.providerId = providerId
        self.modelId = modelId
        self.memoryPluginId = memoryPluginId
        self.systemPrompt = systemPrompt
        self.includeGlobalLibrary = includeGlobalLibrary
        self.activeDocumentCategories = activeDocumentCategories
        self.inactiveDocumentIds = inactiveDocumentIds
        self.useKnowledgeGraph = useKnowledgeGraph
        self.responseMode = responseMode
        self.isPinned = isPinned
        self.isArchived = isArchived
    }
}

@Model
final class SystemPromptPreset {
    var id: UUID
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

@Model
final class ChatMessage {
    var id: UUID
    var sessionId: UUID
    var role: String
    var content: String
    var timestamp: Date
    /// Short, persisted explanation of whether and how document retrieval informed this answer.
    var retrievalSummary: String?
    /// When non-nil, this message is a newer variant of the message with the given ID.
    /// Used for conversation branches: regenerating creates a new message that replaces
    /// the old one in the UI while keeping the full history.
    var replacesMessageId: UUID?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        role: String,
        content: String,
        timestamp: Date = Date(),
        retrievalSummary: String? = nil,
        replacesMessageId: UUID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.retrievalSummary = retrievalSummary
        self.replacesMessageId = replacesMessageId
    }
}

@Model
final class ChatDocument {
    var id: UUID
    var sessionId: UUID
    var fileName: String
    var fileSize: Int64
    var chunkCount: Int
    var importedAt: Date
    var isGlobal: Bool = false
    var category: String = ""
    /// Stable ID shared with the vector-entry metadata. Older imports may not have one.
    var indexDocumentId: UUID?
    /// The storage plugin that owns the indexed chunks for this document.
    var memoryPluginId: String?

    init(
        id: UUID = UUID(),
        sessionId: UUID,
        fileName: String,
        fileSize: Int64,
        chunkCount: Int,
        importedAt: Date = Date(),
        isGlobal: Bool = false,
        category: String = "",
        indexDocumentId: UUID? = nil,
        memoryPluginId: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.fileName = fileName
        self.fileSize = fileSize
        self.chunkCount = chunkCount
        self.importedAt = importedAt
        self.isGlobal = isGlobal
        self.category = category
        self.indexDocumentId = indexDocumentId
        self.memoryPluginId = memoryPluginId
    }
}

@Model
final class ChatPreset {
    var id: UUID
    var title: String
    var providerId: String
    var modelId: String?
    var memoryPluginId: String
    var responseMode: String
    var systemPrompt: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        title: String = String(localized: "New Preset"),
        providerId: String = "",
        modelId: String? = nil,
        memoryPluginId: String = "",
        responseMode: String = ChatResponseMode.balanced.rawValue,
        systemPrompt: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.providerId = providerId
        self.modelId = modelId
        self.memoryPluginId = memoryPluginId
        self.responseMode = responseMode
        self.systemPrompt = systemPrompt
        self.createdAt = createdAt
    }
}
