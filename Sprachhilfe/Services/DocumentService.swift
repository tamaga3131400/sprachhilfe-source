import Foundation
import SprachhilfePluginSDK
import PDFKit
import AppKit
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Sprachhilfe", category: "DocumentService")

@MainActor
class DocumentService {
    static let chunkSize = 1000
    static let chunkOverlap = 200

    struct ImportError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func importDocument(
        url: URL,
        sessionId: UUID,
        memoryPlugin: MemoryStoragePlugin,
        chatService: ChatService,
        isGlobal: Bool = false,
        category: String = ""
    ) async throws -> ChatDocument {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        guard url.isFileURL else {
            throw ImportError(message: String(localized: "Invalid file URL."))
        }

        let data = try Data(contentsOf: url)
        let text = try Self.extractText(from: url, data: data)

        return try await persist(
            text: text,
            fileName: url.lastPathComponent,
            byteSize: Int64(data.count),
            sessionId: sessionId,
            memoryPlugin: memoryPlugin,
            chatService: chatService,
            isGlobal: isGlobal,
            category: category
        )
    }

    /// Fetches a web page, extracts its readable text, and stores it like a document so it
    /// becomes part of the chat's RAG context. Zero-config: no API key or search service.
    func importURL(
        urlString: String,
        sessionId: UUID,
        memoryPlugin: MemoryStoragePlugin,
        chatService: ChatService,
        isGlobal: Bool = false,
        category: String = ""
    ) async throws -> ChatDocument {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), let host = url.host else {
            throw ImportError(message: String(localized: "Invalid web address."))
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh) Sprachhilfe/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError(message: String(localized: "Could not load the page (HTTP \(http.statusCode)).") )
        }

        let mime = (response.mimeType ?? "").lowercased()
        let text = try Self.extractWebText(data: data, mimeType: mime, url: url)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError(message: String(localized: "No readable text found on the page."))
        }

        return try await persist(
            text: text,
            fileName: host,
            byteSize: Int64(data.count),
            sessionId: sessionId,
            memoryPlugin: memoryPlugin,
            chatService: chatService,
            isGlobal: isGlobal,
            category: category,
            extraMetadata: ["sourceURL": normalized]
        )
    }

    /// Shared storage path: chunk text, write embeddings-bearing entries to the vector store,
    /// and record a ChatDocument. Used by both file and URL import.
    private func persist(
        text: String,
        fileName: String,
        byteSize: Int64,
        sessionId: UUID,
        memoryPlugin: MemoryStoragePlugin,
        chatService: ChatService,
        isGlobal: Bool,
        category: String = "",
        extraMetadata: [String: String] = [:]
    ) async throws -> ChatDocument {
        let chunks = DocumentService.chunk(text: text, size: Self.chunkSize, overlap: Self.chunkOverlap)
        guard !chunks.isEmpty else {
            throw ImportError(message: String(localized: "Document is empty."))
        }

        let documentId = UUID()
        // Scope tags let the chat retrieval filter results: global-library chunks vs. chunks
        // that belong to one specific chat session.
        let scopeMetadata: [String: String] = isGlobal
            ? ["scope": "global"]
            : ["scope": "session", "sessionId": sessionId.uuidString]
        let entries = chunks.enumerated().map { index, chunkText in
            var metadata: [String: String] = [
                "docId": documentId.uuidString,
                "fileName": fileName,
                "chunkIndex": "\(index)",
                "chunkCount": "\(chunks.count)"
            ]
            .merging(scopeMetadata) { _, new in new }
            .merging(extraMetadata) { _, new in new }
            if !category.isEmpty {
                metadata["category"] = category
            }
            return MemoryEntry(
                content: chunkText,
                type: .context,
                source: MemorySource(appName: nil, bundleIdentifier: nil, ruleName: fileName, timestamp: Date()),
                metadata: metadata,
                confidence: 1.0
            )
        }

        try await memoryPlugin.store(entries)
        logger.info("Stored \(entries.count) chunks for \(fileName)")

        let doc = chatService.addDocument(
            id: documentId,
            sessionId: sessionId,
            fileName: fileName,
            fileSize: byteSize,
            chunkCount: chunks.count,
            isGlobal: isGlobal,
            category: category,
            memoryPluginId: type(of: memoryPlugin).pluginId
        )

        return doc ?? ChatDocument(
            id: documentId,
            sessionId: sessionId,
            fileName: fileName,
            fileSize: byteSize,
            chunkCount: chunks.count,
            isGlobal: isGlobal,
            category: category,
            indexDocumentId: documentId,
            memoryPluginId: type(of: memoryPlugin).pluginId
        )
    }

    func deleteDocument(
        _ document: ChatDocument,
        memoryPlugin: MemoryStoragePlugin,
        chatService: ChatService
    ) async throws {
        let graphExtractionService: GraphExtractionService? = GraphExtractionService.shared
        graphExtractionService?.beginDeletion(for: document.id)
        var deletionSucceeded = false
        defer {
            graphExtractionService?.finishDeletion(for: document.id, succeeded: deletionSucceeded)
        }

        if let graphExtractionService {
            await graphExtractionService.cancelAndWait(document.id)
        }

        let allEntries = try await memoryPlugin.listAll(offset: 0, limit: 10000)
        let docEntryIds = entries(for: document, in: allEntries).map(\.id)
        if document.indexDocumentId == nil, docEntryIds.isEmpty {
            throw ImportError(message: String(localized: "No indexed chunks were found for this older document in the selected storage. Select its original vector store and try again."))
        }
        if !docEntryIds.isEmpty {
            try await memoryPlugin.delete(docEntryIds)
            logger.info("Deleted \(docEntryIds.count) chunks for document \(document.fileName)")
        }
        if let indexDocumentId = document.indexDocumentId {
            for graphPlugin in PluginManager.shared.graphStoragePlugins {
                try? await graphPlugin.deleteAll(forDocId: indexDocumentId.uuidString)
            }
        }
        chatService.deleteDocument(document)
        deletionSucceeded = true
    }

    func updateDocumentCategory(
        _ document: ChatDocument,
        category: String,
        memoryPlugin: MemoryStoragePlugin,
        chatService: ChatService
    ) async throws {
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let allEntries = try await memoryPlugin.listAll(offset: 0, limit: 10000)
        let documentEntries = entries(for: document, in: allEntries)
        if document.indexDocumentId == nil, documentEntries.isEmpty {
            throw ImportError(message: String(localized: "No indexed chunks were found for this older document in the selected storage. Select its original vector store and try again."))
        }
        for entry in documentEntries {
            var metadata = entry.metadata
            if normalizedCategory.isEmpty {
                metadata.removeValue(forKey: "category")
            } else {
                metadata["category"] = normalizedCategory
            }
            try await memoryPlugin.update(MemoryEntry(
                id: entry.id,
                content: entry.content,
                type: entry.type,
                source: entry.source,
                metadata: metadata,
                createdAt: entry.createdAt,
                lastAccessedAt: entry.lastAccessedAt,
                accessCount: entry.accessCount,
                confidence: entry.confidence,
                embedding: entry.embedding
            ))
        }
        chatService.updateDocumentCategory(document, category: normalizedCategory)
    }

    /// Resolves which stored chunks belong to `document` - used for deletion, category
    /// updates, and (by `GraphExtractionService`) fetching a document's full text for
    /// knowledge-graph extraction.
    func entries(for document: ChatDocument, in entries: [MemoryEntry]) -> [MemoryEntry] {
        if let indexDocumentId = document.indexDocumentId {
            return entries.filter { $0.metadata["docId"] == indexDocumentId.uuidString }
        }

        // Imports made before stable index IDs used a random metadata ID. Their filename and
        // scope are the only safe association left, so clean all matching legacy chunks.
        return entries.filter { entry in
            let metadata = entry.metadata
            guard metadata["fileName"] == document.fileName else { return false }
            if document.isGlobal {
                return metadata["scope"] == "global"
            }
            return metadata["scope"] == "session" && metadata["sessionId"] == document.sessionId.uuidString
        }
    }

    /// Extracts plain text from a document, branching on file type. Supports PDF (PDFKit),
    /// Word/RTF (NSAttributedString), and plain UTF-8 text — all macOS-native, no dependencies.
    static func extractText(from url: URL, data: Data) throws -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(data: data), let text = pdf.string, !text.isEmpty else {
                throw ImportError(message: String(localized: "Could not extract text from PDF (it may be scanned/image-only)."))
            }
            return text
        case "docx", "doc", "rtf":
            let docType: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
            guard let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: docType],
                documentAttributes: nil
            ), !attributed.string.isEmpty else {
                throw ImportError(message: String(localized: "Could not read the document."))
            }
            return attributed.string
        default:
            guard let text = String(data: data, encoding: .utf8) else {
                throw ImportError(message: String(localized: "Could not read file as UTF-8 text."))
            }
            return text
        }
    }

    /// Extracts readable text from a fetched web resource. HTML is stripped to plain text via
    /// NSAttributedString (no JS execution), PDFs via PDFKit, otherwise treated as UTF-8 text.
    static func extractWebText(data: Data, mimeType: String, url: URL) throws -> String {
        if mimeType.contains("application/pdf") || url.pathExtension.lowercased() == "pdf" {
            if let pdf = PDFDocument(data: data), let text = pdf.string { return text }
        }
        if mimeType.contains("html") || mimeType.isEmpty {
            if let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            ) {
                return attributed.string
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func chunk(text: String, size: Int, overlap: Int) -> [String] {
        let chars = Array(text)
        guard chars.count > size else {
            return [text]
        }

        var chunks: [String] = []
        var position = 0

        while position < chars.count {
            let end = min(position + size, chars.count)
            let chunk = String(chars[position..<end])
            chunks.append(chunk)
            position += size - overlap
            if position >= end { break }
        }

        return chunks
    }
}
