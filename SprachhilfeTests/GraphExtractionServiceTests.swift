import XCTest
@testable import Sprachhilfe

final class GraphExtractionServiceTests: XCTestCase {
    @MainActor
    func testParseAcceptsJSONWrappedInProseAndMarkdownFence() {
        let result = GraphExtractionService.parse("""
        Die extrahierten Fakten:
        ```json
        {
          "entities": [
            { "name": "Kunden", "type": "Tabelle", "summary": "Enthält Kundendaten." },
            { "name": "Aufträge", "type": "Tabelle", "summary": "Enthält Aufträge." }
          ],
          "relations": [
            { "from": "Kunden", "to": "Aufträge", "type": "hat_auftrag", "summary": "Kunden haben Aufträge." }
          ]
        }
        ```
        Ende der Extraktion.
        """)

        XCTAssertEqual(result.nodes.map(\.name), ["Kunden", "Aufträge"])
        XCTAssertEqual(result.nodes[0].type, "Tabelle")
        XCTAssertEqual(result.edges.count, 1)
        XCTAssertEqual(result.edges[0].from, "kunden")
        XCTAssertEqual(result.edges[0].to, "auftrage")
        XCTAssertEqual(result.edges[0].type, "hat_auftrag")
    }

    @MainActor
    func testParseDeduplicatesEntitiesByNormalizedID() {
        let result = GraphExtractionService.parse("""
        {
          "entities": [
            { "name": "Kunde", "type": "Tabelle", "summary": "Erster Eintrag." },
            { "name": "  kunde  ", "type": "Duplikat", "summary": "Zweiter Eintrag." },
            { "name": "Rechnung", "type": "Tabelle", "summary": "Rechnungen." }
          ],
          "relations": []
        }
        """)

        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.nodes.map(\.name), ["Kunde", "Rechnung"])
        XCTAssertEqual(result.nodes[0].id, "kunde")
    }

    @MainActor
    func testParseKeepsOnlyKnownNonSelfRelations() {
        let result = GraphExtractionService.parse("""
        {
          "entities": [
            { "name": "Kunde", "type": "Tabelle", "summary": "Kundendaten." },
            { "name": "Rechnung", "type": "Tabelle", "summary": "Rechnungen." }
          ],
          "relations": [
            { "from": "Kunde", "to": "Rechnung", "type": "hat_rechnung", "summary": "Gültig." },
            { "from": "Unbekannt", "to": "Rechnung", "type": "hat_rechnung", "summary": "Ungültig." },
            { "from": "Kunde", "to": "Kunde", "type": "referenziert", "summary": "Ungültig." }
          ]
        }
        """)

        XCTAssertEqual(result.edges.count, 1)
        XCTAssertEqual(result.edges[0].from, "kunde")
        XCTAssertEqual(result.edges[0].to, "rechnung")
        XCTAssertEqual(result.edges[0].type, "hat_rechnung")
    }

    @MainActor
    func testParseReturnsEmptyGraphForMalformedPayload() {
        let result = GraphExtractionService.parse("""
        ```json
        { "entities": [ }
        ```
        """)

        XCTAssertTrue(result.nodes.isEmpty)
        XCTAssertTrue(result.edges.isEmpty)
    }
}
