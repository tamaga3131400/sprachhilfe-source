import SwiftUI
import SprachhilfePluginSDK

struct Neo4jGraphSettingsView: View {
    let plugin: Neo4jGraphPlugin

    @State private var baseURL = ""
    @State private var database = "neo4j"
    @State private var username = "neo4j"
    @State private var password = ""
    @State private var isPasswordVisible = false

    @State private var isTesting = false
    @State private var testResultText: String?
    @State private var testSucceeded = false

    @State private var stats: GraphStats?
    @State private var isLoadingStats = false
    @State private var showClearConfirmation = false
    @State private var isClearing = false
    @State private var graphResultText: String?
    @State private var graphActionSucceeded = false

    private var endpointValidation: Result<Neo4jEndpoint, Error> {
        Result { try Neo4jGraphPlugin.endpoint(for: baseURL) }
    }

    private var endpointErrorText: String? {
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard case .failure(let error) = endpointValidation else { return nil }
        return error.localizedDescription
    }

    private var hasValidEndpoint: Bool {
        if case .success = endpointValidation { return true }
        return false
    }

    private var showsPlaintextWarning: Bool {
        guard case .success(let endpoint) = endpointValidation else { return false }
        return endpoint.usesPlaintextLocalHTTP
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionSection
            Divider()
            graphSection
            Divider()
            Text(localizedGraphText(
                "The extraction LLM (which model turns documents into graph entities) is chosen under Settings → Advanced → Knowledge Graph.",
                de: "Das Extraktions-LLM (welches Modell Dokumente in Graph-Entitäten umwandelt) wählst du unter Einstellungen → Erweitert → Wissensgraph."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(minWidth: 420, minHeight: 380)
        .onAppear {
            let current = plugin.currentConnectionSettings()
            baseURL = current.baseURL
            database = current.database
            username = current.username
            password = current.password
            if plugin.isReady { Task { await loadStats() } }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localizedGraphText("Connection", de: "Verbindung"), systemImage: "network")
                .font(.headline)

            TextField(localizedGraphText("URL, e.g. http://localhost:7474", de: "URL, z. B. http://localhost:7474"), text: $baseURL)
                .textFieldStyle(.roundedBorder)
            Text(localizedGraphText(
                "You can paste the Neo4j Browser URL as-is - the \"/browser\" part is stripped automatically.",
                de: "Du kannst die Neo4j-Browser-URL direkt einfügen — der „/browser“-Teil wird automatisch entfernt."
            ))
            .font(.caption2)
            .foregroundStyle(.tertiary)

            HStack {
                TextField(localizedGraphText("Database", de: "Datenbank"), text: $database)
                    .textFieldStyle(.roundedBorder)
                TextField(localizedGraphText("Username", de: "Benutzername"), text: $username)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                if isPasswordVisible {
                    TextField(localizedGraphText("Password", de: "Passwort"), text: $password)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(localizedGraphText("Password", de: "Passwort"), text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                Button { isPasswordVisible.toggle() } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                }.buttonStyle(.borderless)
            }

            if let endpointErrorText {
                Label(endpointErrorText, systemImage: "xmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if showsPlaintextWarning {
                Label(
                    localizedGraphText(
                        "Local HTTP is permitted only for trusted local/private networks. Credentials are sent unencrypted.",
                        de: "Lokales HTTP ist nur für vertrauenswürdige lokale/private Netzwerke erlaubt. Zugangsdaten werden unverschlüsselt übertragen."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack {
                Button(localizedGraphText("Save & Test Connection", de: "Speichern & Verbindung testen")) {
                    switch plugin.saveConnectionSettings(
                        baseURL: baseURL,
                        database: database,
                        username: username,
                        password: password
                    ) {
                    case .success:
                        if case .success(let endpoint) = endpointValidation {
                            baseURL = endpoint.url.absoluteString
                        }
                        Task { await testConnection() }
                    case .failure(let error):
                        testSucceeded = false
                        testResultText = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting || !hasValidEndpoint || password.isEmpty)

                if isTesting {
                    ProgressView().controlSize(.small)
                }
            }

            if let testResultText {
                Label(testResultText, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(testSucceeded ? .green : .red)
            } else {
                Label(
                    plugin.isReady ? localizedGraphText("Connected", de: "Verbunden") : localizedGraphText("Not configured", de: "Nicht konfiguriert"),
                    systemImage: plugin.isReady ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(plugin.isReady ? .green : .secondary)
            }
        }
    }

    private var graphSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(localizedGraphText("Graph", de: "Graph"), systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            HStack(spacing: 16) {
                if isLoadingStats {
                    ProgressView().controlSize(.small)
                } else if let stats {
                    Label("\(stats.nodeCount) " + localizedGraphText("entities", de: "Entitäten"), systemImage: "circle.fill")
                        .font(.caption)
                    Label("\(stats.edgeCount) " + localizedGraphText("relations", de: "Beziehungen"), systemImage: "arrow.left.and.right")
                        .font(.caption)
                } else {
                    Text(localizedGraphText("Not connected", de: "Nicht verbunden"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await loadStats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(!plugin.isReady)
            }

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                if isClearing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(localizedGraphText("Clear Graph", de: "Graph leeren"), systemImage: "trash")
                }
            }
            .disabled(!plugin.isReady || isClearing)
            .confirmationDialog(
                localizedGraphText("Clear the Sprachhilfe knowledge graph?", de: "Den Sprachhilfe-Wissensgraphen leeren?"),
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button(localizedGraphText("Clear Graph", de: "Graph leeren"), role: .destructive) {
                    Task { await clearGraph() }
                }
                Button(localizedGraphText("Cancel", de: "Abbrechen"), role: .cancel) {}
            } message: {
                Text(localizedGraphText(
                    "This removes all entities and relations created by Sprachhilfe. Other data in the same Neo4j database is not affected.",
                    de: "Entfernt alle von Sprachhilfe angelegten Entitäten und Beziehungen. Andere Daten in derselben Neo4j-Datenbank bleiben unberührt."
                ))
            }

            if let graphResultText {
                Label(graphResultText, systemImage: graphActionSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(graphActionSucceeded ? .green : .red)
            }
        }
    }

    private func testConnection() async {
        isTesting = true
        testResultText = nil
        let result = await plugin.testConnection()
        switch result {
        case .success(let version):
            testSucceeded = true
            testResultText = version == "?"
                ? localizedGraphText("Connected.", de: "Verbunden.")
                : localizedGraphText("Connected (Neo4j \(version))", de: "Verbunden (Neo4j \(version))")
            await loadStats()
        case .failure(let error):
            testSucceeded = false
            testResultText = error.localizedDescription
        }
        isTesting = false
    }

    private func loadStats() async {
        isLoadingStats = true
        stats = await plugin.fetchStats()
        isLoadingStats = false
    }

    private func clearGraph() async {
        isClearing = true
        graphResultText = nil
        switch await plugin.clearGraph() {
        case .success:
            graphActionSucceeded = true
            graphResultText = localizedGraphText("Sprachhilfe knowledge graph cleared.", de: "Sprachhilfe-Wissensgraph geleert.")
            await loadStats()
        case .failure(let error):
            graphActionSucceeded = false
            graphResultText = localizedGraphText(
                "Could not clear the Sprachhilfe knowledge graph: \(error.localizedDescription)",
                de: "Sprachhilfe-Wissensgraph konnte nicht geleert werden: \(error.localizedDescription)"
            )
        }
        isClearing = false
    }
}
