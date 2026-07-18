import Foundation
import SwiftUI
import SprachhilfePluginSDK

/// This plugin bundle is a separate compiled module from the main app, so the app's own
/// `localizedAppText` helper (Sprachhilfe/ViewModels/ProfilesViewModel.swift) isn't visible
/// here - this mirrors its exact logic (shared `UserDefaults.standard` key) locally.
func localizedGraphText(_ english: String, de german: String) -> String {
    let code = UserDefaults.standard.string(forKey: "preferredAppLanguage")
        ?? Bundle.main.preferredLocalizations.first
        ?? Locale.current.language.languageCode?.identifier
        ?? "de"
    return code.hasPrefix("de") ? german : english
}

@objc(Neo4jGraphPlugin)
final class Neo4jGraphPlugin: NSObject, SprachhilfePlugin, GraphStoragePlugin, @unchecked Sendable {
    static let pluginId = "com.sprachhilfe.neo4jgraph"
    static let pluginName = "Wissensgraph (Neo4j)"

    private enum Schema {
        static let entityLabel = "SprachhilfeGraphEntity"
        static let documentLabel = "SprachhilfeGraphDocument"
        static let mentionType = "SPRACHHILFE_MENTIONS"
        static let relationType = "SPRACHHILFE_RELATES"
        static let entityConstraint = "sprachhilfe_graph_entity_id"
        static let documentConstraint = "sprachhilfe_graph_document_id"
        static let mentionFullTextIndex = "sprachhilfe_graph_mention_fts"
    }

    var graphName: String { "Neo4j" }
    private(set) var isReady: Bool = false

    private var host: HostServices?
    private var baseURLString: String = ""
    private var database: String = "neo4j"
    private var username: String = "neo4j"
    private var password: String = ""
    private var schemaEnsured = false
    private var requestExecutorOverride: Neo4jHTTPClient.RequestExecutor?

    required override init() {
        super.init()
    }

    /// Internal test seam: production instances use the redirect-blocking default transport.
    convenience init(requestExecutorForTesting: @escaping Neo4jHTTPClient.RequestExecutor) {
        self.init()
        requestExecutorOverride = requestExecutorForTesting
    }

    func activate(host: HostServices) {
        self.host = host
        baseURLString = (host.userDefault(forKey: "baseURL") as? String) ?? ""
        database = (host.userDefault(forKey: "database") as? String) ?? "neo4j"
        username = (host.userDefault(forKey: "username") as? String) ?? "neo4j"
        password = host.loadSecret(key: "neo4j-password") ?? ""
        if !baseURLString.isEmpty && !password.isEmpty {
            Task { [weak self] in await self?.testConnection() }
        }
    }

    func deactivate() {
        host = nil
    }

    var settingsView: AnyView? {
        AnyView(Neo4jGraphSettingsView(plugin: self))
    }

    // MARK: - Connection

    static func endpoint(for raw: String) throws -> Neo4jEndpoint {
        try Neo4jEndpoint.parse(raw)
    }

    private func client() throws -> Neo4jHTTPClient {
        guard !password.isEmpty else {
            throw Neo4jConnectionError(underlying: localizedGraphText("Password required.", de: "Passwort erforderlich."))
        }
        let endpoint = try Self.endpoint(for: baseURLString)
        if let requestExecutorOverride {
            return try Neo4jHTTPClient(
                baseURL: endpoint.url,
                database: database,
                username: username,
                password: password,
                requestExecutor: requestExecutorOverride
            )
        }
        return try Neo4jHTTPClient(
            baseURL: endpoint.url,
            database: database,
            username: username,
            password: password
        )
    }

    @discardableResult
    func testConnection() async -> Result<String, Error> {
        do {
            let client = try client()
            let version = try await client.testConnection()
            isReady = true
            host?.notifyCapabilitiesChanged()
            if !schemaEnsured {
                try? await ensureSchema(client: client)
            }
            return .success(version)
        } catch {
            isReady = false
            host?.notifyCapabilitiesChanged()
            return .failure(error)
        }
    }

    private func ensureSchema(client: Neo4jHTTPClient) async throws {
        _ = try await client.run([
            Neo4jStatement(
                statement: "CREATE CONSTRAINT \(Schema.entityConstraint) IF NOT EXISTS FOR (e:\(Schema.entityLabel)) REQUIRE e.id IS UNIQUE",
                parameters: [:]
            ),
            Neo4jStatement(
                statement: "CREATE CONSTRAINT \(Schema.documentConstraint) IF NOT EXISTS FOR (d:\(Schema.documentLabel)) REQUIRE d.id IS UNIQUE",
                parameters: [:]
            ),
            Neo4jStatement(
                statement: "CREATE FULLTEXT INDEX \(Schema.mentionFullTextIndex) IF NOT EXISTS FOR ()-[m:\(Schema.mentionType)]-() ON EACH [m.name, m.summary]",
                parameters: [:]
            ),
        ])
        schemaEnsured = true
    }

    // MARK: - GraphStoragePlugin

    func upsert(nodes: [GraphNode], edges: [GraphEdge], docId: String) async throws {
        let client = try client()
        if !nodes.isEmpty {
            let nodeParams = nodes.map { ["id": $0.id, "name": $0.name, "type": $0.type, "summary": $0.summary] }
            _ = try await client.run([Neo4jStatement(
                statement: """
                UNWIND $nodes AS n
                MERGE (d:\(Schema.documentLabel) {id: $docId})
                MERGE (e:\(Schema.entityLabel) {id: n.id})
                MERGE (d)-[m:\(Schema.mentionType)]->(e)
                SET m.name = n.name, m.type = n.type, m.summary = n.summary
                """,
                parameters: ["nodes": nodeParams, "docId": docId]
            )])
        }
        if !edges.isEmpty {
            let edgeParams = edges.map { ["from": $0.from, "to": $0.to, "type": $0.type, "summary": $0.summary] }
            _ = try await client.run([Neo4jStatement(
                statement: """
                UNWIND $edges AS ed
                MATCH (a:\(Schema.entityLabel) {id: ed.from}), (b:\(Schema.entityLabel) {id: ed.to})
                MERGE (a)-[r:\(Schema.relationType) {type: ed.type, docId: $docId}]->(b)
                SET r.summary = ed.summary
                """,
                parameters: ["edges": edgeParams, "docId": docId]
            )])
        }
    }

    func retrieveSubgraph(
        matching query: String,
        allowedDocumentIDs: [String],
        maxNodes: Int,
        maxEdges: Int,
        charBudget: Int
    ) async throws -> GraphContext {
        guard !allowedDocumentIDs.isEmpty else {
            return GraphContext(nodes: [], edges: [], promptBlock: "")
        }
        let client = try client()

        // (1) Seeds via the private full-text index; then fall back to an allowed-document
        // relevance match. Both queries rank the entire allowed scope before applying the
        // prompt-context limit, so a database's incidental storage order never selects facts.
        var seedRows: [[String: Any]] = (try? await client.run([Neo4jStatement(
            statement: """
            CALL db.index.fulltext.queryRelationships('\(Schema.mentionFullTextIndex)', $q) YIELD relationship AS mention, score
            WITH mention, score, startNode(mention) AS d, endNode(mention) AS node
            WHERE d:\(Schema.documentLabel) AND node:\(Schema.entityLabel) AND d.id IN $docIds
            WITH node, mention, score
            ORDER BY score DESC, toLower(mention.name) ASC, node.id ASC
            WITH node, collect({name: mention.name, type: mention.type, summary: mention.summary, score: score})[0] AS best
            RETURN node.id AS id, best.name AS name, best.type AS type, best.summary AS summary, best.score AS score
            ORDER BY score DESC, toLower(name) ASC, id ASC
            LIMIT $limit
            """,
            parameters: ["q": query, "docIds": allowedDocumentIDs, "limit": maxNodes]
        )]).first) ?? []

        if seedRows.isEmpty {
            let words = query.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }
            if !words.isEmpty {
                seedRows = try await client.run([Neo4jStatement(
                    statement: """
                    MATCH (d:\(Schema.documentLabel))-[m:\(Schema.mentionType)]->(e:\(Schema.entityLabel))
                    WHERE d.id IN $docIds
                    WITH e, m, reduce(score = 0, w IN $words |
                        score + CASE
                            WHEN toLower(m.name) = w THEN 3
                            WHEN toLower(m.name) CONTAINS w THEN 2
                            WHEN toLower(coalesce(m.summary, '')) CONTAINS w THEN 1
                            ELSE 0
                        END
                    ) AS score
                    WHERE score > 0
                    ORDER BY score DESC, toLower(m.name) ASC, e.id ASC
                    WITH e, collect({name: m.name, type: m.type, summary: m.summary, score: score})[0] AS best
                    RETURN e.id AS id, best.name AS name, best.type AS type, best.summary AS summary, best.score AS score
                    ORDER BY score DESC, toLower(name) ASC, id ASC
                    LIMIT $limit
                    """,
                    parameters: ["words": words, "docIds": allowedDocumentIDs, "limit": maxNodes]
                )]).first ?? []
            }
        }

        var nodesById: [String: GraphNode] = [:]
        var nodeOrder: [String] = []
        for row in seedRows {
            guard let id = row["id"] as? String, let name = row["name"] as? String else { continue }
            guard nodesById[id] == nil else { continue }
            nodesById[id] = GraphNode(
                id: id,
                name: name,
                type: row["type"] as? String ?? "",
                summary: row["summary"] as? String ?? ""
            )
            nodeOrder.append(id)
        }
        guard !nodesById.isEmpty else { return GraphContext(nodes: [], edges: [], promptBlock: "") }

        var edgesByKey: [String: GraphEdge] = [:]
        var edgeOrder: [String] = []
        var frontier = nodeOrder

        // Depth 1, then depth 2 neighbor expansion. Each edge and node summary is tied to an
        // allowed source document, so an excluded document cannot leak through a shared entity.
        for _ in 0..<2 {
            guard !frontier.isEmpty, edgesByKey.count < maxEdges else { break }
            let rows = try await client.run([Neo4jStatement(
                statement: """
                UNWIND range(0, size($ids) - 1) AS seedRank
                WITH $ids[seedRank] AS seedId, seedRank
                MATCH (seed:\(Schema.entityLabel) {id: seedId})-[r:\(Schema.relationType)]-(nb:\(Schema.entityLabel))
                WHERE r.docId IN $docIds
                MATCH (d:\(Schema.documentLabel))-[m:\(Schema.mentionType)]->(nb)
                WHERE d.id = r.docId
                WITH seedRank, r, nb, collect(m)[0] AS mention
                RETURN startNode(r).id AS fromId, endNode(r).id AS toId, r.type AS type, r.summary AS summary,
                       nb.id AS nbId, mention.name AS nbName, mention.type AS nbType, mention.summary AS nbSummary
                ORDER BY seedRank ASC, toLower(mention.name) ASC, nb.id ASC, r.type ASC
                LIMIT $limit
                """,
                parameters: ["ids": frontier, "docIds": allowedDocumentIDs, "limit": maxEdges]
            )]).first ?? []

            var newFrontier: [String] = []
            for row in rows {
                guard let fromId = row["fromId"] as? String,
                      let toId = row["toId"] as? String,
                      let type = row["type"] as? String,
                      let nbId = row["nbId"] as? String,
                      let nbName = row["nbName"] as? String else { continue }

                if nodesById[nbId] == nil, nodesById.count < maxNodes {
                    nodesById[nbId] = GraphNode(
                        id: nbId,
                        name: nbName,
                        type: row["nbType"] as? String ?? "",
                        summary: row["nbSummary"] as? String ?? ""
                    )
                    nodeOrder.append(nbId)
                    newFrontier.append(nbId)
                }

                let key = "\(fromId)|\(type)|\(toId)"
                if edgesByKey[key] == nil {
                    edgesByKey[key] = GraphEdge(
                        from: fromId,
                        to: toId,
                        type: type,
                        summary: row["summary"] as? String ?? "",
                        metadata: [
                            "fromName": fromId == nbId ? nbName : (nodesById[fromId]?.name ?? ""),
                            "toName": toId == nbId ? nbName : (nodesById[toId]?.name ?? ""),
                        ]
                    )
                    edgeOrder.append(key)
                }
                if edgesByKey.count >= maxEdges { break }
            }
            frontier = newFrontier
        }

        let materializedNodes = nodeOrder.prefix(maxNodes).compactMap { nodesById[$0] }
        let materializedEdges = edgeOrder.prefix(maxEdges).compactMap { edgesByKey[$0] }
        return GraphContext(
            nodes: materializedNodes,
            edges: materializedEdges,
            promptBlock: Self.serialize(nodes: materializedNodes, edges: materializedEdges, charBudget: charBudget)
        )
    }

    func deleteAll(forDocId docId: String) async throws {
        let client = try client()
        _ = try await client.run([
            Neo4jStatement(
                statement: "MATCH ()-[r:\(Schema.relationType) {docId: $docId}]->() DELETE r",
                parameters: ["docId": docId]
            ),
            Neo4jStatement(
                statement: "MATCH (d:\(Schema.documentLabel) {id: $docId})-[m:\(Schema.mentionType)]->() DELETE m",
                parameters: ["docId": docId]
            ),
            Neo4jStatement(
                statement: "MATCH (d:\(Schema.documentLabel) {id: $docId}) DELETE d",
                parameters: ["docId": docId]
            ),
            Neo4jStatement(
                statement: """
                MATCH (e:\(Schema.entityLabel))
                WHERE NOT EXISTS {
                    MATCH (:\(Schema.documentLabel))-[:\(Schema.mentionType)]->(e)
                }
                  AND NOT EXISTS {
                    MATCH (e)--()
                }
                DELETE e
                """,
                parameters: [:]
            ),
        ])
    }

    func stats() async throws -> GraphStats {
        let client = try client()
        let nodeRows = try await client.run([
            Neo4jStatement(statement: "MATCH (e:\(Schema.entityLabel)) RETURN count(e) AS c", parameters: [:])
        ]).first ?? []
        let edgeRows = try await client.run([
            Neo4jStatement(
                statement: "MATCH (:\(Schema.entityLabel))-[r:\(Schema.relationType)]->(:\(Schema.entityLabel)) RETURN count(r) AS c",
                parameters: [:]
            )
        ]).first ?? []
        let nodeCount = (nodeRows.first?["c"] as? Int) ?? 0
        let edgeCount = (edgeRows.first?["c"] as? Int) ?? 0
        return GraphStats(nodeCount: nodeCount, edgeCount: edgeCount)
    }

    func deleteAll() async throws {
        let client = try client()
        _ = try await client.run([
            Neo4jStatement(statement: "MATCH ()-[r:\(Schema.relationType)]->() DELETE r", parameters: [:]),
            Neo4jStatement(statement: "MATCH (d:\(Schema.documentLabel))-[m:\(Schema.mentionType)]->() DELETE m", parameters: [:]),
            Neo4jStatement(
                statement: """
                MATCH (d:\(Schema.documentLabel))
                WHERE NOT EXISTS { MATCH (d)--() }
                DELETE d
                """,
                parameters: [:]
            ),
            Neo4jStatement(
                statement: """
                MATCH (e:\(Schema.entityLabel))
                WHERE NOT EXISTS { MATCH (e)--() }
                DELETE e
                """,
                parameters: [:]
            ),
        ])
    }

    // MARK: - Serialization (budget-truncated, relevance-ranked relations first)

    private static func serialize(nodes: [GraphNode], edges: [GraphEdge], charBudget: Int) -> String {
        let header = "--- KNOWLEDGE GRAPH ---\n"
        let footer = "\n--- END KNOWLEDGE GRAPH ---"
        let bodyBudget = charBudget - header.count - footer.count
        guard bodyBudget > 0 else { return "" }

        func clipped(_ text: String, _ limit: Int = 200) -> String {
            text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        let nodeNames = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.name) })

        var edgeLines: [String] = []
        for edge in edges {
            guard let fromName = nodeNames[edge.from] ?? edge.metadata["fromName"],
                  let toName = nodeNames[edge.to] ?? edge.metadata["toName"],
                  !fromName.isEmpty,
                  !toName.isEmpty else { continue }
            edgeLines.append("- \(fromName) —\(edge.type)→ \(toName): \(clipped(edge.summary))")
        }

        var lines: [String] = []
        if !edgeLines.isEmpty {
            lines.append(localizedGraphText("Relations:", de: "Beziehungen:"))
            lines.append(contentsOf: edgeLines)
        }
        if !nodes.isEmpty {
            lines.append(localizedGraphText("Entities:", de: "Entitäten:"))
            for node in nodes {
                lines.append("- \(node.name) (\(node.type)): \(clipped(node.summary))")
            }
        }

        var budgeted: [String] = []
        var used = 0
        var truncated = false
        for line in lines {
            let cost = line.count + 1
            if used + cost > bodyBudget {
                truncated = true
                break
            }
            budgeted.append(line)
            used += cost
        }
        guard !budgeted.isEmpty else { return "" }
        let truncationMarker = "\n… (gekürzt)"
        if truncated {
            while !budgeted.isEmpty && used + truncationMarker.count > bodyBudget {
                let removed = budgeted.removeLast()
                used -= removed.count + 1
            }
        }
        guard !budgeted.isEmpty else { return "" }
        var body = budgeted.joined(separator: "\n")
        if truncated { body += truncationMarker }
        return header + body + footer
    }

    // MARK: - Settings accessors (internal - used by Neo4jGraphSettingsView in this target)

    func currentConnectionSettings() -> (baseURL: String, database: String, username: String, password: String) {
        (baseURLString, database, username, password)
    }

    @discardableResult
    func saveConnectionSettings(baseURL: String, database: String, username: String, password: String) -> Result<Void, Error> {
        do {
            let endpoint = try Self.endpoint(for: baseURL)
            baseURLString = endpoint.url.absoluteString
            self.database = database.isEmpty ? "neo4j" : database
            self.username = username.isEmpty ? "neo4j" : username
            self.password = password
            schemaEnsured = false
            isReady = false
            host?.setUserDefault(baseURLString, forKey: "baseURL")
            host?.setUserDefault(self.database, forKey: "database")
            host?.setUserDefault(self.username, forKey: "username")
            try? host?.storeSecret(key: "neo4j-password", value: password)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func fetchStats() async -> GraphStats? {
        try? await stats()
    }

    func clearGraph() async -> Result<Void, Error> {
        do {
            try await deleteAll()
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
