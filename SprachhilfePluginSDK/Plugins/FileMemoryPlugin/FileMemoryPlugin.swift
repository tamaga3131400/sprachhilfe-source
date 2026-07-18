import Foundation
import SwiftUI
import NaturalLanguage
import SprachhilfePluginSDK

// MARK: - Plugin Entry Point

@objc(FileMemoryPlugin)
final class FileMemoryPlugin: NSObject, SprachhilfePlugin, MemoryStoragePlugin, @unchecked Sendable {
    static let pluginId = "com.sprachhilfe.memory.file"
    static let pluginName = "File Memory"

    var storageName: String { "File Memory" }
    var isReady: Bool { host != nil }
    var memoryCount: Int { memories.count }

    private var host: HostServices?
    private var memories: [MemoryEntry] = []
    private var memoriesFileURL: URL?
    private var isDirty = false
    private var saveTask: Task<Void, Never>?

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        self.host = host
        memoriesFileURL = host.pluginDataDirectory.appendingPathComponent("memories.json")
        loadMemories()
    }

    func deactivate() {
        saveTask?.cancel()
        if isDirty { persistNow() }
        host = nil
        memories = []
        memoriesFileURL = nil
    }

    var settingsView: AnyView? {
        AnyView(FileMemorySettingsView(plugin: self))
    }

    // MARK: - MemoryStoragePlugin

    func store(_ entries: [MemoryEntry]) async throws {
        // Compute a semantic embedding per entry (best-effort; nil falls back to keyword search).
        let enriched = entries.map { entry -> MemoryEntry in
            guard entry.embedding == nil else { return entry }
            var e = entry
            e.embedding = embed(entry.content)
            return e
        }
        memories.append(contentsOf: enriched)
        scheduleSave()
    }

    func search(_ query: MemoryQuery) async throws -> [MemorySearchResult] {
        let now = Date()
        let queryVector = embed(query.text)
        let queryTokens = tokenize(query.text)
        guard queryVector != nil || !queryTokens.isEmpty else { return [] }

        var results: [MemorySearchResult] = []

        for memory in memories {
            guard memory.confidence >= query.minConfidence else { continue }
            if let types = query.types, !types.contains(memory.type) { continue }

            let daysSinceAccess = now.timeIntervalSince(memory.lastAccessedAt) / 86400
            let recencyBoost = 1.0 / (1.0 + daysSinceAccess * 0.01)

            // Prefer semantic similarity when both query and entry have embeddings;
            // otherwise fall back to keyword/token overlap.
            if let qv = queryVector, let mv = memory.embedding {
                let similarity = cosineSimilarity(qv, mv)
                guard similarity > 0.15 else { continue }
                results.append(MemorySearchResult(entry: memory, relevanceScore: similarity * memory.confidence * recencyBoost))
            } else {
                let memoryTokens = tokenize(memory.content)
                guard !memoryTokens.isEmpty, !queryTokens.isEmpty else { continue }
                let matchCount = queryTokens.filter { qt in
                    memoryTokens.contains { $0.contains(qt) || qt.contains($0) }
                }.count
                guard matchCount > 0 else { continue }
                let overlap = Double(matchCount) / Double(queryTokens.count)
                results.append(MemorySearchResult(entry: memory, relevanceScore: overlap * memory.confidence * recencyBoost))
            }
        }

        return Array(results.sorted { $0.relevanceScore > $1.relevanceScore }.prefix(query.maxResults))
    }

    func delete(_ ids: [UUID]) async throws {
        memories.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func update(_ entry: MemoryEntry) async throws {
        guard let index = memories.firstIndex(where: { $0.id == entry.id }) else { return }
        memories[index] = entry
        scheduleSave()
    }

    func listAll(offset: Int, limit: Int) async throws -> [MemoryEntry] {
        let sorted = memories.sorted { $0.createdAt > $1.createdAt }
        let start = min(offset, sorted.count)
        return Array(sorted[start..<min(start + limit, sorted.count)])
    }

    func deleteAll() async throws {
        memories.removeAll()
        persistNow()
    }

    // MARK: - Persistence (coalesced)

    private func scheduleSave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    private func persistNow() {
        guard isDirty, let url = memoriesFileURL else { return }
        isDirty = false
        guard let data = try? JSONEncoder.memoryEncoder.encode(memories) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadMemories() {
        guard let url = memoriesFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        memories = (try? JSONDecoder.memoryDecoder.decode([MemoryEntry].self, from: data)) ?? []
    }

    // MARK: - Tokenization

    private func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
    }

    // MARK: - Semantic Embeddings (NLContextualEmbedding, multilingual via Latin script)

    private var embedderLoaded = false
    private var embedder: NLContextualEmbedding?

    /// Lazily loads a contextual embedding model. If the language assets are not present, it
    /// kicks off a background download for next time and returns nil now (→ keyword fallback).
    private func ensureEmbedder() -> NLContextualEmbedding? {
        if embedderLoaded { return embedder }
        embedderLoaded = true
        guard let model = NLContextualEmbedding(script: .latin) else { return nil }
        guard model.hasAvailableAssets else {
            model.requestAssets { _, _ in } // best-effort; available on a later launch
            return nil
        }
        do {
            try model.load()
            embedder = model
        } catch {
            embedder = nil
        }
        return embedder
    }

    /// Mean-pooled sentence vector for a piece of text, or nil if embeddings are unavailable.
    private func embed(_ text: String) -> [Float]? {
        guard let model = ensureEmbedder() else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let result = try? model.embeddingResult(for: trimmed, language: nil) else { return nil }

        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return sum.map { Float($0 / Double(count)) }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (sqrt(normA) * sqrt(normB))
    }

    // MARK: - Settings View Accessors

    func getAllMemories() -> [MemoryEntry] {
        memories.sorted { $0.createdAt > $1.createdAt }
    }

    func deleteMemory(_ id: UUID) {
        memories.removeAll { $0.id == id }
        scheduleSave()
    }

    func updateMemoryContent(_ id: UUID, newContent: String) {
        guard let index = memories.firstIndex(where: { $0.id == id }) else { return }
        memories[index].content = newContent
        memories[index].lastAccessedAt = Date()
        scheduleSave()
    }

    func clearAll() {
        memories.removeAll()
        persistNow()
    }
}

// MARK: - Settings View

private struct FileMemorySettingsView: View {
    let plugin: FileMemoryPlugin
    @State private var memories: [MemoryEntry] = []
    @State private var searchText = ""

    var filteredMemories: [MemoryEntry] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(memories.count) memories stored", systemImage: "brain.filled.head.profile")
                    .font(.headline)
                Spacer()
                Button(role: .destructive) {
                    plugin.clearAll()
                    memories = []
                } label: {
                    Label(String(localized: "Clear All"), systemImage: "trash")
                }
                .disabled(memories.isEmpty)
            }

            TextField(String(localized: "Search memories..."), text: $searchText)
                .textFieldStyle(.roundedBorder)

            if filteredMemories.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Memories"), systemImage: "brain")
                } description: {
                    Text(searchText.isEmpty
                         ? String(localized: "Memories will appear here after transcriptions are processed.")
                         : String(localized: "No memories match your search."))
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRowView(
                            memory: memory,
                            onDelete: {
                                plugin.deleteMemory(memory.id)
                                memories = plugin.getAllMemories()
                            },
                            onSave: { newContent in
                                plugin.updateMemoryContent(memory.id, newContent: newContent)
                                memories = plugin.getAllMemories()
                            }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .onAppear { memories = plugin.getAllMemories() }
    }
}
