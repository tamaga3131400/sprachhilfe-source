import Foundation
import SprachhilfePluginSDK
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sprachhilfe", category: "GraphExtractionService")

struct GraphExtractionProgress: Sendable {
    var completedSegments: Int
    var totalSegments: Int
    var isFinished: Bool
    var entityCount: Int = 0
    var relationCount: Int = 0
    var errorMessage: String?
}

/// Turns an already-imported document's chunks into knowledge-graph nodes/edges via an LLM,
/// then upserts them into whichever `GraphStoragePlugin` is ready. Runs incrementally per
/// text segment so a cancelled/failed extraction keeps whatever already succeeded (upserts
/// are idempotent, so re-running is always safe).
@MainActor
final class GraphExtractionService: ObservableObject {
    nonisolated(unsafe) static var shared: GraphExtractionService!

    @Published private(set) var activeExtractions: [UUID: GraphExtractionProgress] = [:]

    private let documentService: DocumentService
    private let promptProcessingService: PromptProcessingService
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Document IDs whose deletion has started. Successful deletions retain their tombstone so
    /// a late UI action cannot start a new extraction for a document being removed.
    private var deletionTombstones = Set<UUID>()

    private static let segmentSize = 3500
    /// Matches DocumentService.chunkOverlap - each chunk after the first repeats this many
    /// leading characters from the previous one, which must be stripped before concatenation.
    private static let chunkOverlap = 200

    static let extractionPrompt = """
    Du extrahierst einen Wissensgraphen aus Dokumenttext. Der Text stammt oft aus Analysen \
    von Ninox-Datenbanken (Tabellen, Felder, Relationen, Formeln, Skripte), kann aber \
    beliebiger Text sein.

    Antworte AUSSCHLIESSLICH mit einem JSON-Objekt, ohne Markdown, ohne Erklärung:
    {
      "entities": [
        { "name": "string, kanonischer Name",
          "type": "string, z. B. Tabelle | Feld | Formel | Skript | Ansicht | Person | Prozess | Konzept",
          "summary": "string, 1 Satz, max. 200 Zeichen" }
      ],
      "relations": [
        { "from": "name einer Entität aus entities",
          "to": "name einer Entität aus entities",
          "type": "string, snake_case, z. B. verknuepft_mit | hat_feld | berechnet_aus | gehoert_zu | verwendet | loest_aus",
          "summary": "string, 1 Satz, max. 200 Zeichen" }
      ]
    }

    Regeln:
    - Nur Entitäten mit klarer Bedeutung, keine generischen Wörter. Max. 15 Entitäten, 20 Relationen.
    - Bei Ninox-Inhalten: Tabellen, wichtige Felder (v. a. Referenz- und Formelfelder), Skripte \
    und deren Wirkungen als Entitäten; Tabellenbeziehungen und Formelabhängigkeiten als Relationen.
    - "from"/"to" müssen exakt Namen aus "entities" sein.
    - Keine Duplikate. Verwende konsistente Namen (Singular/Plural wie im Text).
    - Gibt es nichts Sinnvolles: {"entities": [], "relations": []}
    """

    init(documentService: DocumentService, promptProcessingService: PromptProcessingService) {
        self.documentService = documentService
        self.promptProcessingService = promptProcessingService
    }

    func isExtracting(_ documentId: UUID) -> Bool {
        tasks[documentId] != nil
    }

    func cancel(_ documentId: UUID) {
        tasks[documentId]?.cancel()
    }

    /// Prevents new extractions while a document is being deleted.
    func beginDeletion(for documentId: UUID) {
        deletionTombstones.insert(documentId)
    }

    /// Releases a deletion gate only when deletion failed. A successfully deleted document
    /// keeps its tombstone because its UUID must never become extractable again.
    func finishDeletion(for documentId: UUID, succeeded: Bool) {
        if !succeeded {
            deletionTombstones.remove(documentId)
        }
    }

    /// Cancels a document extraction and waits until it cannot write another graph fact.
    /// Deletion uses this before removing vector and graph data, preventing an in-flight LLM
    /// response from reintroducing facts after the graph cleanup.
    func cancelAndWait(_ documentId: UUID) async {
        guard let task = tasks[documentId] else { return }
        task.cancel()
        _ = await task.value
    }

    /// Starts extraction for `document` if a graph plugin is ready and nothing is already
    /// running for it. Returns false if no ready graph plugin exists (caller should hide/
    /// disable the triggering UI in that case rather than call this at all).
    @discardableResult
    func extract(document: ChatDocument, memoryPlugin: MemoryStoragePlugin) -> Bool {
        guard !deletionTombstones.contains(document.id) else { return false }
        guard let graphPlugin = PluginManager.shared.graphStoragePlugins.first(where: { $0.isReady }) else {
            return false
        }
        guard tasks[document.id] == nil else { return true }

        activeExtractions[document.id] = GraphExtractionProgress(completedSegments: 0, totalSegments: 0, isFinished: false)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runExtraction(document: document, memoryPlugin: memoryPlugin, graphPlugin: graphPlugin)
        }
        tasks[document.id] = task
        return true
    }

    private func runExtraction(document: ChatDocument, memoryPlugin: MemoryStoragePlugin, graphPlugin: GraphStoragePlugin) async {
        defer { tasks[document.id] = nil }

        guard !Task.isCancelled else {
            finishCancelledExtraction(for: document.id)
            return
        }

        guard let docId = document.indexDocumentId?.uuidString else {
            activeExtractions[document.id] = GraphExtractionProgress(
                completedSegments: 0, totalSegments: 0, isFinished: true,
                errorMessage: String(localized: "Dieses ältere Dokument kann nicht extrahiert werden (keine stabile Dokument-ID).")
            )
            return
        }

        let text = await fetchDocumentText(document: document, memoryPlugin: memoryPlugin)
        guard !Task.isCancelled else {
            finishCancelledExtraction(for: document.id)
            return
        }
        guard !text.isEmpty else {
            activeExtractions[document.id] = GraphExtractionProgress(
                completedSegments: 0, totalSegments: 0, isFinished: true,
                errorMessage: String(localized: "Kein Text für dieses Dokument gefunden.")
            )
            return
        }

        let providerId = UserDefaults.standard.string(forKey: UserDefaultsKeys.graphExtractionProvider) ?? ""
        guard !providerId.isEmpty else {
            activeExtractions[document.id] = GraphExtractionProgress(
                completedSegments: 0, totalSegments: 0, isFinished: true,
                errorMessage: String(localized: "Kein Extraktions-Modell ausgewählt (Einstellungen → Erweitert → Wissensgraph).")
            )
            return
        }
        let model = UserDefaults.standard.string(forKey: UserDefaultsKeys.graphExtractionModel) ?? ""

        let segments = Self.segment(text, size: Self.segmentSize)
        var totalEntities = 0
        var totalRelations = 0
        var completedSegments = 0
        var successfulSegments = 0
        var failedSegments = 0
        activeExtractions[document.id] = GraphExtractionProgress(completedSegments: 0, totalSegments: segments.count, isFinished: false)

        for (index, segment) in segments.enumerated() {
            if Task.isCancelled { break }
            do {
                let result = try await promptProcessingService.process(
                    prompt: Self.extractionPrompt,
                    text: segment,
                    providerOverride: providerId,
                    cloudModelOverride: model.isEmpty ? nil : model,
                    skipMemoryInjection: true
                )
                try Task.checkCancellation()
                let (nodes, edges) = Self.parse(result)
                try Task.checkCancellation()
                if !nodes.isEmpty || !edges.isEmpty {
                    try await graphPlugin.upsert(nodes: nodes, edges: edges, docId: docId)
                    try Task.checkCancellation()
                    totalEntities += nodes.count
                    totalRelations += edges.count
                }
                successfulSegments += 1
            } catch {
                if Task.isCancelled { break }
                failedSegments += 1
                logger.error("Graph extraction segment \(index) failed: \(error.localizedDescription)")
            }
            completedSegments = index + 1
            activeExtractions[document.id] = GraphExtractionProgress(
                completedSegments: completedSegments, totalSegments: segments.count, isFinished: false,
                entityCount: totalEntities, relationCount: totalRelations
            )
        }

        if Task.isCancelled {
            finishCancelledExtraction(
                for: document.id,
                completedSegments: completedSegments,
                totalSegments: segments.count,
                entityCount: totalEntities,
                relationCount: totalRelations
            )
            return
        }

        activeExtractions[document.id] = GraphExtractionProgress(
            completedSegments: segments.count, totalSegments: segments.count, isFinished: true,
            entityCount: totalEntities,
            relationCount: totalRelations,
            errorMessage: successfulSegments == 0 && failedSegments == segments.count
                ? String(localized: "Die Wissensgraph-Extraktion ist für alle Textabschnitte fehlgeschlagen.")
                : nil
        )
    }

    private func finishCancelledExtraction(
        for documentId: UUID,
        completedSegments: Int? = nil,
        totalSegments: Int? = nil,
        entityCount: Int? = nil,
        relationCount: Int? = nil
    ) {
        let progress = activeExtractions[documentId]
        activeExtractions[documentId] = GraphExtractionProgress(
            completedSegments: completedSegments ?? progress?.completedSegments ?? 0,
            totalSegments: totalSegments ?? progress?.totalSegments ?? 0,
            isFinished: true,
            entityCount: entityCount ?? progress?.entityCount ?? 0,
            relationCount: relationCount ?? progress?.relationCount ?? 0
        )
    }

    /// Reassembles a document's full text from its already-stored chunks (no re-import,
    /// no re-reading the source file) - mirrors DocumentService.deleteDocument's chunk
    /// resolution so extraction sees exactly the chunks a delete would remove.
    private func fetchDocumentText(document: ChatDocument, memoryPlugin: MemoryStoragePlugin) async -> String {
        guard let allEntries = try? await memoryPlugin.listAll(offset: 0, limit: 10000) else { return "" }
        let chunks = documentService.entries(for: document, in: allEntries)
            .sorted { (Int($0.metadata["chunkIndex"] ?? "0") ?? 0) < (Int($1.metadata["chunkIndex"] ?? "0") ?? 0) }
        guard !chunks.isEmpty else { return "" }

        var combined = ""
        for (index, chunk) in chunks.enumerated() {
            if index == 0 || chunk.content.count <= Self.chunkOverlap {
                combined += chunk.content
            } else {
                combined += String(chunk.content.dropFirst(Self.chunkOverlap))
            }
        }
        return combined
    }

    /// Splits text into ~`size`-character segments, preferring a paragraph break near the
    /// boundary over a hard mid-word cut.
    private static func segment(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var segments: [String] = []
        var remaining = Substring(text)
        while !remaining.isEmpty {
            if remaining.count <= size {
                segments.append(String(remaining))
                break
            }
            let limit = remaining.index(remaining.startIndex, offsetBy: size)
            let splitIndex = remaining.range(of: "\n\n", options: .backwards, range: remaining.startIndex..<limit)?.upperBound ?? limit
            segments.append(String(remaining[remaining.startIndex..<splitIndex]))
            remaining = remaining[splitIndex...]
        }
        return segments
    }

    /// Tolerant JSON parsing: strips markdown fences, extracts the outermost {...}, drops
    /// relations whose from/to don't match a known entity rather than failing the whole segment.
    static func parse(_ raw: String) -> (nodes: [GraphNode], edges: [GraphEdge]) {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "{"), let end = cleaned.lastIndex(of: "}"), start < end {
            cleaned = String(cleaned[start...end])
        }

        struct RawEntity: Codable { let name: String; let type: String?; let summary: String? }
        struct RawRelation: Codable { let from: String; let to: String; let type: String?; let summary: String? }
        struct RawPayload: Codable { let entities: [RawEntity]?; let relations: [RawRelation]? }

        guard let data = cleaned.data(using: .utf8),
              let payload = try? JSONDecoder().decode(RawPayload.self, from: data) else {
            return ([], [])
        }

        var nodes: [GraphNode] = []
        var knownIds = Set<String>()
        for entity in (payload.entities ?? []).prefix(15) {
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let node = GraphNode(name: name, type: entity.type ?? "", summary: entity.summary ?? "")
            guard knownIds.insert(node.id).inserted else { continue }
            nodes.append(node)
        }

        var edges: [GraphEdge] = []
        for relation in (payload.relations ?? []).prefix(20) {
            let fromId = GraphNode.normalizedId(for: relation.from)
            let toId = GraphNode.normalizedId(for: relation.to)
            guard knownIds.contains(fromId), knownIds.contains(toId), fromId != toId else { continue }
            edges.append(GraphEdge(from: fromId, to: toId, type: relation.type ?? "verknuepft_mit", summary: relation.summary ?? ""))
        }
        return (nodes, edges)
    }
}
