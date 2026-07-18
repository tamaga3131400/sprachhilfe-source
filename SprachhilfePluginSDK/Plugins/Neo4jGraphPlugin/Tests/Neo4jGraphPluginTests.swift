import Foundation
import XCTest
import SprachhilfePluginSDK
@_spi(Testing) import SprachhilfePluginSDKTesting
@testable import Neo4jGraphPlugin

final class Neo4jGraphPluginTests: XCTestCase {
    func testEndpointPolicyNormalizesBrowserAndAllowsOnlyLocalHTTP() throws {
        let browserEndpoint = try Neo4jEndpoint.parse("https://graph.example:7473/browser/")
        XCTAssertEqual(browserEndpoint.url.absoluteString, "https://graph.example:7473")

        let remoteWithoutScheme = try Neo4jEndpoint.parse("graph.example:7473/browser")
        XCTAssertEqual(remoteWithoutScheme.url.absoluteString, "https://graph.example:7473")

        let localWithoutScheme = try Neo4jEndpoint.parse("localhost:7474/browser")
        XCTAssertEqual(localWithoutScheme.url.absoluteString, "http://localhost:7474")

        for rawURL in [
            "http://printer.local:7474",
            "http://10.0.0.8:7474",
            "http://169.254.4.8:7474",
            "http://[::1]:7474",
            "http://[0:0:0:0:0:0:0:1]:7474",
            "http://[fd12::1]:7474",
            "http://[fe80::1%25en0]:7474",
            "http://[::ffff:192.168.1.8]:7474",
        ] {
            XCTAssertEqual(try Neo4jEndpoint.parse(rawURL).url.scheme?.lowercased(), "http", rawURL)
        }

        assertEndpointError("http://neo4.example:7474", .insecureRemoteHTTP)
        assertEndpointError("http://8.8.8.8:7474", .publicIPAddress)
        assertEndpointError("https://8.8.8.8:7474", .publicIPAddress)
        assertEndpointError("bolt://localhost:7687", .unsupportedScheme("bolt"))
        assertEndpointError("neo4j://localhost:7687", .unsupportedScheme("neo4j"))
        assertEndpointError("https://neo4j:secret@graph.example:7473", .credentialsInURL)
    }

    func testTransactionPayloadUsesBasicAuthAndTransactionalEndpoint() async throws {
        let recorder = RequestRecorder(payloads: [Self.neo4jPayload()])
        let client = try Neo4jHTTPClient(
            baseURL: URL(string: "https://graph.example")!,
            database: "neo4j",
            username: "neo4j",
            password: "secret",
            requestExecutor: { request in try await recorder.execute(request) }
        )

        _ = try await client.run([
            Neo4jStatement(statement: "RETURN $value AS value", parameters: ["value": 42]),
        ])

        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/db/neo4j/tx/commit")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Basic \(Data("neo4j:secret".utf8).base64EncodedString())"
        )

        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let statements = try XCTUnwrap(payload["statements"] as? [[String: Any]])
        let statement = try XCTUnwrap(statements.first)
        XCTAssertEqual(statement["statement"] as? String, "RETURN $value AS value")
        let parameters = try XCTUnwrap(statement["parameters"] as? [String: Any])
        XCTAssertEqual((parameters["value"] as? NSNumber)?.intValue, 42)
    }

    func testNeo4jStatementErrorsAreSurfaced() async throws {
        let recorder = RequestRecorder(payloads: [Self.neo4jPayload(errors: [[
            "code": "Neo.ClientError.Statement.SyntaxError",
            "message": "Bad Cypher",
        ]])])
        let client = try makeClient(recorder: recorder)

        do {
            _ = try await client.run([Neo4jStatement(statement: "BROKEN", parameters: [:])])
            XCTFail("Expected the Neo4j error payload to throw")
        } catch let error as Neo4jQueryError {
            XCTAssertEqual(error.code, "Neo.ClientError.Statement.SyntaxError")
            XCTAssertEqual(error.message, "Bad Cypher")
        }
    }

    func testRestrictedAccountStillPassesMandatoryConnectionProbe() async throws {
        let recorder = RequestRecorder(payloads: [
            Self.neo4jPayload(results: [[
                "columns": ["one"],
                "data": [["row": [1]]],
            ]]),
            Self.neo4jPayload(errors: [[
                "code": "Neo.ClientError.Security.Forbidden",
                "message": "Access denied",
            ]]),
        ])
        let client = try makeClient(recorder: recorder)

        let version = try await client.testConnection()
        XCTAssertEqual(version, "?")

        let statements = try recorder.requests.map(Self.firstStatement)
        XCTAssertEqual(statements.first, "RETURN 1")
        XCTAssertTrue(statements.dropFirst().first?.contains("dbms.components()") == true)
    }

    func testPluginUsesNamespacedQueriesAndAllowedDocumentScope() async throws {
        let recorder = RequestRecorder(payloads: Array(repeating: Self.neo4jPayload(), count: 5))
        let plugin = try configuredPlugin(recorder: recorder)
        let nodes = [
            GraphNode(name: "Kunde", type: "Tabelle", summary: "Kundendaten."),
            GraphNode(name: "Rechnung", type: "Tabelle", summary: "Rechnungen."),
        ]
        let edges = [
            GraphEdge(from: nodes[0].id, to: nodes[1].id, type: "hat_rechnung", summary: "Kunden haben Rechnungen."),
        ]

        try await plugin.upsert(nodes: nodes, edges: edges, docId: "allowed-document")
        let context = try await plugin.retrieveSubgraph(
            matching: "kunde rechnung",
            allowedDocumentIDs: ["allowed-document"],
            maxNodes: 25,
            maxEdges: 50,
            charBudget: 4000
        )
        try await plugin.deleteAll()

        XCTAssertTrue(context.nodes.isEmpty)
        XCTAssertTrue(context.edges.isEmpty)

        let payloads = try recorder.requests.map(Self.payload)
        XCTAssertEqual(payloads.count, 5)

        let nodeUpsert = try Self.firstStatement(payloads[0])
        XCTAssertTrue(nodeUpsert.contains("SprachhilfeGraphDocument"))
        XCTAssertTrue(nodeUpsert.contains("SprachhilfeGraphEntity"))
        XCTAssertTrue(nodeUpsert.contains("SPRACHHILFE_MENTIONS"))
        XCTAssertTrue(nodeUpsert.contains("m.name"))
        XCTAssertFalse(nodeUpsert.contains(":Entity"))

        let edgeUpsert = try Self.firstStatement(payloads[1])
        XCTAssertTrue(edgeUpsert.contains("SPRACHHILFE_RELATES"))
        XCTAssertTrue(edgeUpsert.contains("docId: $docId"))
        XCTAssertFalse(edgeUpsert.contains(":RELATES"))

        let fullTextPayload = payloads[2]
        let fullTextStatement = try Self.firstStatement(fullTextPayload)
        XCTAssertTrue(fullTextStatement.contains("queryRelationships('sprachhilfe_graph_mention_fts'"))
        XCTAssertTrue(fullTextStatement.contains("d.id IN $docIds"))
        XCTAssertFalse(fullTextStatement.contains("e.name"))
        XCTAssertEqual(try Self.documentIDs(from: fullTextPayload), ["allowed-document"])

        let fallbackPayload = payloads[3]
        let fallbackStatement = try Self.firstStatement(fallbackPayload)
        XCTAssertTrue(fallbackStatement.contains("m.name"))
        XCTAssertTrue(fallbackStatement.contains("d.id IN $docIds"))
        XCTAssertEqual(try Self.documentIDs(from: fallbackPayload), ["allowed-document"])

        let clearStatements = try Self.statements(payloads[4]).joined(separator: "\n")
        XCTAssertTrue(clearStatements.contains("SprachhilfeGraphDocument"))
        XCTAssertTrue(clearStatements.contains("SprachhilfeGraphEntity"))
        XCTAssertTrue(clearStatements.contains("SPRACHHILFE_MENTIONS"))
        XCTAssertTrue(clearStatements.contains("SPRACHHILFE_RELATES"))
        XCTAssertFalse(clearStatements.contains(":Entity"))
        XCTAssertFalse(clearStatements.contains(":RELATES"))
    }

    func testRankedCandidatesAreNotAlphabeticallyReslicedAtContextLimit() async throws {
        let rankedRows: [[Any]] = [
            ["critical", "Zulu", "Concept", "Most relevant fact.", 100.0],
            ["alpha", "Alpha", "Concept", "First tie.", 10.0],
            ["beta", "Beta", "Concept", "Second tie.", 10.0],
        ] + (1...24).map { index in
            ["low-\(index)", "Low \(index)", "Concept", "Low relevance \(index).", 1.0] as [Any]
        }

        let recorder = RequestRecorder(payloads: [
            Self.neo4jRows(
                columns: ["id", "name", "type", "summary", "score"],
                rows: rankedRows
            ),
        ])
        let plugin = try configuredPlugin(recorder: recorder)

        let context = try await plugin.retrieveSubgraph(
            matching: "critical concept",
            allowedDocumentIDs: ["allowed-document"],
            maxNodes: 25,
            maxEdges: 0,
            charBudget: 10_000
        )

        XCTAssertEqual(context.nodes.count, 25)
        XCTAssertEqual(context.nodes.prefix(3).map(\.id), ["critical", "alpha", "beta"])
        XCTAssertTrue(context.nodes.contains(where: { $0.id == "critical" }))
        XCTAssertFalse(context.nodes.contains(where: { $0.id == "low-24" }))

        let payload = try Self.payload(XCTUnwrap(recorder.requests.first))
        let statement = try Self.firstStatement(payload)
        XCTAssertTrue(statement.contains("WITH node, collect({name: mention.name"))
        XCTAssertTrue(statement.contains("ORDER BY score DESC, toLower(name) ASC, id ASC"))
        XCTAssertEqual(try Self.documentIDs(from: payload), ["allowed-document"])
    }

    func testFallbackRanksMatchesByScoreThenNameAndID() async throws {
        let recorder = RequestRecorder(payloads: [
            Self.neo4jPayload(errors: [[
                "code": "Neo.ClientError.Procedure.ProcedureNotFound",
                "message": "Full-text index is unavailable",
            ]]),
            Self.neo4jRows(
                columns: ["id", "name", "type", "summary", "score"],
                rows: [
                    ["zebra", "Zebra", "Concept", "Two matching terms.", 4],
                    ["alpha", "Alpha", "Concept", "One matching term.", 2],
                    ["beta", "Beta", "Concept", "One matching term.", 2],
                ]
            ),
        ])
        let plugin = try configuredPlugin(recorder: recorder)

        let context = try await plugin.retrieveSubgraph(
            matching: "zebra alpha",
            allowedDocumentIDs: ["allowed-document"],
            maxNodes: 25,
            maxEdges: 0,
            charBudget: 10_000
        )

        XCTAssertEqual(context.nodes.map(\.id), ["zebra", "alpha", "beta"])

        let payload = try Self.payload(XCTUnwrap(recorder.requests.last))
        let statement = try Self.firstStatement(payload)
        XCTAssertTrue(statement.contains("reduce(score = 0, w IN $words"))
        XCTAssertTrue(statement.contains("WHERE score > 0"))
        XCTAssertTrue(statement.contains("ORDER BY score DESC, toLower(name) ASC, id ASC"))
        XCTAssertEqual(try Self.documentIDs(from: payload), ["allowed-document"])
    }

    func testPromptPrioritizesScopedRelationsWithinCharacterBudget() async throws {
        let seedSummary = String(repeating: "s", count: 240)
        let otherSummary = String(repeating: "o", count: 240)
        let recorder = RequestRecorder(payloads: [
            Self.neo4jRows(
                columns: ["id", "name", "type", "summary", "score"],
                rows: [
                    ["seed", "Seed", "Concept", seedSummary, 10.0],
                    ["other", "Other", "Concept", otherSummary, 9.0],
                ]
            ),
            Self.neo4jRows(
                columns: ["fromId", "toId", "type", "summary", "nbId", "nbName", "nbType", "nbSummary"],
                rows: [[
                    "seed", "neighbor", "uses", "Short scoped relation.",
                    "neighbor", "Neighbor", "Concept", "Neighbor summary.",
                ]]
            ),
        ])
        let plugin = try configuredPlugin(recorder: recorder)

        let context = try await plugin.retrieveSubgraph(
            matching: "seed",
            allowedDocumentIDs: ["allowed-document"],
            maxNodes: 2,
            maxEdges: 1,
            charBudget: 400
        )

        XCTAssertEqual(context.nodes.map(\.id), ["seed", "other"])
        XCTAssertEqual(context.edges.count, 1)
        XCTAssertTrue(context.promptBlock.contains("Seed —uses→ Neighbor: Short scoped relation."))
        XCTAssertTrue(context.promptBlock.contains("- Seed (Concept):"))
        XCTAssertTrue(context.promptBlock.contains("… (gekürzt)"))
        XCTAssertFalse(context.promptBlock.contains(String(repeating: "o", count: 20)))
        XCTAssertLessThanOrEqual(context.promptBlock.count, 400)

        let neighborPayload = try Self.payload(recorder.requests[1])
        let neighborStatement = try Self.firstStatement(neighborPayload)
        XCTAssertTrue(neighborStatement.contains("r.docId IN $docIds"))
        XCTAssertTrue(neighborStatement.contains("d.id = r.docId"))
        XCTAssertEqual(try Self.documentIDs(from: neighborPayload), ["allowed-document"])
    }

    func testNoAllowedDocumentSkipsGraphRequest() async throws {
        let recorder = RequestRecorder(payloads: [])
        let plugin = try configuredPlugin(recorder: recorder)

        let context = try await plugin.retrieveSubgraph(
            matching: "kunde",
            allowedDocumentIDs: [],
            maxNodes: 25,
            maxEdges: 50,
            charBudget: 4000
        )

        XCTAssertTrue(context.nodes.isEmpty)
        XCTAssertTrue(context.edges.isEmpty)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    private func assertEndpointError(_ rawURL: String, _ expected: Neo4jEndpointError) {
        XCTAssertThrowsError(try Neo4jEndpoint.parse(rawURL)) { error in
            XCTAssertEqual(error as? Neo4jEndpointError, expected, rawURL)
        }
    }

    private func makeClient(recorder: RequestRecorder) throws -> Neo4jHTTPClient {
        try Neo4jHTTPClient(
            baseURL: URL(string: "https://graph.example")!,
            database: "neo4j",
            username: "neo4j",
            password: "secret",
            requestExecutor: { request in try await recorder.execute(request) }
        )
    }

    private func configuredPlugin(recorder: RequestRecorder) throws -> Neo4jGraphPlugin {
        let plugin = Neo4jGraphPlugin(requestExecutorForTesting: { request in
            try await recorder.execute(request)
        })
        let host = try PluginTestHostServices(defaults: [
            "baseURL": "https://graph.example",
            "database": "neo4j",
            "username": "neo4j",
        ])
        plugin.activate(host: host)
        if case .failure(let error) = plugin.saveConnectionSettings(
            baseURL: "https://graph.example",
            database: "neo4j",
            username: "neo4j",
            password: "secret"
        ) {
            throw error
        }
        return plugin
    }

    private static func neo4jPayload(
        results: [[String: Any]] = [],
        errors: [[String: Any]] = []
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: ["results": results, "errors": errors])
    }

    private static func neo4jRows(columns: [String], rows: [[Any]]) -> Data {
        neo4jPayload(results: [[
            "columns": columns,
            "data": rows.map { ["row": $0] },
        ]])
    }

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func statements(_ payload: [String: Any]) throws -> [String] {
        let statementDictionaries = try XCTUnwrap(payload["statements"] as? [[String: Any]])
        return try statementDictionaries.map { try XCTUnwrap($0["statement"] as? String) }
    }

    private static func firstStatement(_ request: URLRequest) throws -> String {
        try firstStatement(payload(request))
    }

    private static func firstStatement(_ payload: [String: Any]) throws -> String {
        try XCTUnwrap(statements(payload).first)
    }

    private static func documentIDs(from payload: [String: Any]) throws -> [String] {
        let statementDictionaries = try XCTUnwrap(payload["statements"] as? [[String: Any]])
        let firstStatement = try XCTUnwrap(statementDictionaries.first)
        let parameters = try XCTUnwrap(firstStatement["parameters"] as? [String: Any])
        return try XCTUnwrap(parameters["docIds"] as? [String])
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [Data]
    private var requestsStorage: [URLRequest] = []

    init(payloads: [Data]) {
        self.payloads = payloads
    }

    func execute(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let payload = lock.withLock { () -> Data? in
            requestsStorage.append(request)
            guard !payloads.isEmpty else { return nil }
            return payloads.removeFirst()
        }
        guard let payload, let url = request.url else {
            throw URLError(.badServerResponse)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (payload, response)
    }

    var requests: [URLRequest] {
        lock.withLock { requestsStorage }
    }
}
