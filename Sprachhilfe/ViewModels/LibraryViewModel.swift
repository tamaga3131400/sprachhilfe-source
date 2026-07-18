import Foundation
import Combine
import SprachhilfePluginSDK

/// Manages the global, cross-chat document library. Documents added here are tagged
/// `scope=global` in the vector store and can be pulled into any chat that opts in via
/// "Globale Bibliothek einbeziehen".
enum LibrarySection: Hashable {
    case documents
    case prompts
}

@MainActor
final class LibraryViewModel: ObservableObject {
    private let chatService: ChatService
    private let documentService: DocumentService
    private let pluginManager: PluginManager

    @Published var section: LibrarySection = .documents
    @Published var documents: [ChatDocument] = []
    @Published var presets: [SystemPromptPreset] = []
    @Published var isImporting: Bool = false
    @Published var errorMessage: String?
    @Published var knownCategories: [String] = []

    init(
        chatService: ChatService,
        documentService: DocumentService,
        pluginManager: PluginManager
    ) {
        self.chatService = chatService
        self.documentService = documentService
        self.pluginManager = pluginManager
        reload()
    }

    var availableMemoryPlugins: [MemoryStoragePlugin] {
        pluginManager.memoryStoragePlugins
    }

    func resolvedMemoryPlugin() -> MemoryStoragePlugin? {
        availableMemoryPlugins.first(where: { $0.isReady }) ?? availableMemoryPlugins.first
    }

    func reload() {
        documents = chatService.documents(for: ChatService.globalLibrarySessionId)
        knownCategories = chatService.allDocumentCategories()
        reloadPresets()
    }

    // MARK: - System Prompt Presets

    func reloadPresets() {
        presets = chatService.presets()
    }

    func createPreset() {
        _ = chatService.createPreset(
            title: String(localized: "New preset"),
            content: ""
        )
        reloadPresets()
    }

    func updatePreset(_ preset: SystemPromptPreset, title: String, content: String) {
        preset.title = title
        preset.content = content
        chatService.updatePreset(preset)
        reloadPresets()
    }

    func deletePreset(_ preset: SystemPromptPreset) {
        chatService.deletePreset(preset)
        reloadPresets()
    }

    func importDocument(url: URL, category: String = "") {
        guard let memoryPlugin = resolvedMemoryPlugin(), memoryPlugin.isReady else {
            errorMessage = String(localized: "No memory storage plugin ready. Enable one in Integrations.")
            return
        }
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let document = try await documentService.importDocument(
                    url: url,
                    sessionId: ChatService.globalLibrarySessionId,
                    memoryPlugin: memoryPlugin,
                    chatService: chatService,
                    isGlobal: true,
                    category: category
                )
                await MainActor.run {
                    self.reload()
                    self.isImporting = false
                    Self.autoExtractGraphIfEnabled(document: document, memoryPlugin: memoryPlugin)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isImporting = false
                }
            }
        }
    }

    func importURL(_ urlString: String, category: String = "") {
        guard let memoryPlugin = resolvedMemoryPlugin(), memoryPlugin.isReady else {
            errorMessage = String(localized: "No memory storage plugin ready. Enable one in Integrations.")
            return
        }
        isImporting = true
        errorMessage = nil
        Task {
            do {
                let document = try await documentService.importURL(
                    urlString: urlString,
                    sessionId: ChatService.globalLibrarySessionId,
                    memoryPlugin: memoryPlugin,
                    chatService: chatService,
                    isGlobal: true,
                    category: category
                )
                await MainActor.run {
                    self.reload()
                    self.isImporting = false
                    Self.autoExtractGraphIfEnabled(document: document, memoryPlugin: memoryPlugin)
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isImporting = false
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

    func updateDocumentCategory(_ document: ChatDocument, category: String) {
        guard let memoryPlugin = resolvedMemoryPlugin(for: document), memoryPlugin.isReady else {
            errorMessage = String(localized: "The storage used by this document is not available. Re-enable it before changing its category.")
            return
        }
        Task {
            do {
                try await documentService.updateDocumentCategory(
                    document,
                    category: category,
                    memoryPlugin: memoryPlugin,
                    chatService: chatService
                )
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    /// Manually triggers knowledge-graph extraction for `document`. No-op if its storage
    /// isn't ready or no graph plugin is connected (the triggering button is hidden in that
    /// case, but this guards direct callers too).
    func extractToGraph(_ document: ChatDocument) {
        guard let memoryPlugin = resolvedMemoryPlugin(for: document), memoryPlugin.isReady else {
            errorMessage = String(localized: "The storage used by this document is not available. Re-enable it before extracting to the knowledge graph.")
            return
        }
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
                await MainActor.run { self.reload() }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }

    private func resolvedMemoryPlugin(for document: ChatDocument) -> MemoryStoragePlugin? {
        if let pluginId = document.memoryPluginId, !pluginId.isEmpty {
            return availableMemoryPlugins.first(where: { type(of: $0).pluginId == pluginId })
        }
        return resolvedMemoryPlugin()
    }
}
