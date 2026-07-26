import XCTest
@testable import Sprachhilfe

final class TextDiffServiceTests: XCTestCase {
    func testExtractCorrectionsFindsLocalizedWordReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "teh quick brown fox",
            edited: "the quick brown fox"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testExtractCorrectionsSkipsLargeRewrites() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "one two three",
            edited: "completely different rewrite here"
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testPasteDraftClassifiesTextCodeURLFilesAndUnsupportedImages() {
        XCTAssertEqual(
            ChatPasteDraft(text: "https://example.com/reference", fileURLs: [], containsUnsupportedImage: false).kind,
            .url
        )
        XCTAssertEqual(
            ChatPasteDraft(
                text: "import Foundation\nfunc hello() {\n    print(\"Hi\");\n}",
                fileURLs: [],
                containsUnsupportedImage: false
            ).kind,
            .code
        )
        XCTAssertEqual(
            ChatPasteDraft(text: "", fileURLs: [URL(fileURLWithPath: "/tmp/context.md")], containsUnsupportedImage: false).kind,
            .files
        )
        XCTAssertEqual(
            ChatPasteDraft(text: "", fileURLs: [], containsUnsupportedImage: true).kind,
            .unsupportedImage
        )
    }

    @MainActor
    func testChatClipboardCopiesPlainTextMarkdownAndRichText() {
        let pasteboard = NSPasteboard(name: .init("SprachhilfeTests.ChatClipboard.\(UUID().uuidString)"))
        let markdown = "**Bold** and `code`"

        ChatClipboardService.copy(markdown, as: .plainText, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold and code")

        ChatClipboardService.copy(markdown, as: .markdown, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), markdown)

        ChatClipboardService.copy(markdown, as: .richText, to: pasteboard)
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold and code")
    }

    @MainActor
    func testChatClipboardReportsMissingExternalTarget() async {
        do {
            _ = try await ChatClipboardService.insertIntoLastExternalApplication(
                "Answer",
                using: TextInsertionService(),
                targetApplication: nil
            )
            XCTFail("Expected an error without an external target application")
        } catch let error as ChatClipboardService.Error {
            XCTAssertEqual(error, .noExternalApplication)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testChatSearchReturnsACompactMessageSnippet() {
        let text = "The deployment was blocked because the signing certificate expired yesterday."
        let snippet = ChatSearch.matchingSnippet(in: text, query: "certificate")

        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet?.localizedCaseInsensitiveContains("certificate") == true)
        XCTAssertNil(ChatSearch.matchingSnippet(in: text, query: "missing"))
    }

    @MainActor
    func testChatDocumentKeepsOptionalSourceURLAndMessageSources() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = ChatService(appSupportDirectory: appSupportDirectory)
        let session = try XCTUnwrap(service.createSession(providerId: "provider", modelId: nil, memoryPluginId: "memory"))
        let document = try XCTUnwrap(service.addDocument(
            id: UUID(),
            sessionId: session.id,
            fileName: "example.com",
            fileSize: 12,
            chunkCount: 1,
            memoryPluginId: "memory",
            sourceURL: "https://example.com/reference"
        ))
        let message = try XCTUnwrap(service.addMessage(
            sessionId: session.id,
            role: "assistant",
            content: "Answer",
            sourceDocumentIds: [document.id.uuidString]
        ))

        XCTAssertEqual(document.sourceURL, "https://example.com/reference")
        XCTAssertEqual(message.sourceDocumentIds, [document.id.uuidString])
    }
}
