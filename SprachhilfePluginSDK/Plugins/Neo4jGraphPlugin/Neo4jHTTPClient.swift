import Darwin
import Foundation
import SprachhilfePluginSDK

enum Neo4jEndpointError: Error, LocalizedError, Equatable, Sendable {
    case emptyURL
    case invalidURL
    case unsupportedScheme(String)
    case credentialsInURL
    case publicIPAddress
    case insecureRemoteHTTP

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            localizedGraphText("Enter a Neo4j URL.", de: "Bitte eine Neo4j-URL eingeben.")
        case .invalidURL:
            localizedGraphText("Enter a valid Neo4j URL.", de: "Bitte eine gültige Neo4j-URL eingeben.")
        case .unsupportedScheme(let scheme):
            localizedGraphText(
                "The \(scheme) scheme is not supported. Use HTTPS, or HTTP only for a local Neo4j server.",
                de: "Das Schema \(scheme) wird nicht unterstützt. Verwende HTTPS oder HTTP nur für einen lokalen Neo4j-Server."
            )
        case .credentialsInURL:
            localizedGraphText(
                "Do not put credentials in the Neo4j URL. Use the username and password fields.",
                de: "Bitte keine Zugangsdaten in die Neo4j-URL eintragen. Verwende die Felder für Benutzername und Passwort."
            )
        case .publicIPAddress:
            localizedGraphText(
                "Public IP addresses are not allowed for Neo4j. Use a HTTPS hostname instead.",
                de: "Öffentliche IP-Adressen sind für Neo4j nicht erlaubt. Verwende stattdessen einen HTTPS-Hostnamen."
            )
        case .insecureRemoteHTTP:
            localizedGraphText(
                "Remote Neo4j servers require HTTPS. HTTP is allowed only for localhost, .local, or private network addresses.",
                de: "Remote-Neo4j-Server benötigen HTTPS. HTTP ist nur für localhost, .local oder private Netzwerkadressen erlaubt."
            )
        }
    }
}

/// One validated Neo4j server endpoint. The policy is intentionally centralized here so the
/// settings UI, persistence and request construction cannot drift apart.
struct Neo4jEndpoint: Sendable, Equatable {
    let url: URL

    var usesPlaintextLocalHTTP: Bool {
        url.scheme?.lowercased() == "http"
    }

    static func parse(_ raw: String) throws -> Neo4jEndpoint {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw Neo4jEndpointError.emptyURL }

        if !value.contains("://") {
            guard let candidate = URLComponents(string: "http://\(value)"),
                  let host = candidate.host,
                  !host.isEmpty else {
                throw Neo4jEndpointError.invalidURL
            }
            value = "\(isLocal(host: host) ? "http" : "https")://\(value)"
        }

        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              components.url != nil else {
            throw Neo4jEndpointError.invalidURL
        }
        guard components.user == nil, components.password == nil else {
            throw Neo4jEndpointError.credentialsInURL
        }
        guard components.query == nil, components.fragment == nil else {
            throw Neo4jEndpointError.invalidURL
        }
        guard scheme == "http" || scheme == "https" else {
            throw Neo4jEndpointError.unsupportedScheme(scheme)
        }

        switch hostKind(host) {
        case .invalid:
            throw Neo4jEndpointError.invalidURL
        case .publicIPAddress:
            throw Neo4jEndpointError.publicIPAddress
        case .local, .hostname:
            if scheme == "http", !isLocal(host: host) {
                throw Neo4jEndpointError.insecureRemoteHTTP
            }
        }

        // Neo4j Browser URLs are convenient to paste directly. Keep a reverse-proxy prefix
        // if present, but remove Browser and everything behind it before appending /db/... .
        let path = components.path
        if let range = path.range(of: "/browser", options: .caseInsensitive) {
            let suffix = String(path[range.lowerBound...])
            if suffix.caseInsensitiveCompare("/browser") == .orderedSame
                || suffix.lowercased().hasPrefix("/browser/") {
                components.path = String(path[..<range.lowerBound])
            }
        }
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.scheme = scheme

        guard let url = components.url else { throw Neo4jEndpointError.invalidURL }
        return Neo4jEndpoint(url: url)
    }

    private enum HostKind {
        case local
        case hostname
        case publicIPAddress
        case invalid
    }

    private static func hostKind(_ rawHost: String) -> HostKind {
        let host = rawHost
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return .invalid }

        if host == "localhost" || host.hasSuffix(".local") {
            return .local
        }
        if let octets = ipv4Octets(host) {
            return isLocalIPv4(octets) ? .local : .publicIPAddress
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            // Do not let malformed numeric addresses fall through to hostname handling.
            return .invalid
        }
        if host.contains(":") {
            return isLocalIPv6(host) ? .local : .publicIPAddress
        }
        return .hostname
    }

    private static func isLocal(host: String) -> Bool {
        hostKind(host) == .local
    }

    private static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }

        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  (part.count == 1 || part.first != "0"),
                  let value = UInt8(part) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isLocalIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        return switch octets[0] {
        case 10, 127:
            true
        case 169:
            octets[1] == 254
        case 172:
            (16...31).contains(octets[1])
        case 192:
            octets[1] == 168
        default:
            false
        }
    }

    private static func isLocalIPv6(_ rawHost: String) -> Bool {
        // URLComponents leaves a link-local interface scope in the host. It does not affect
        // the address range, so remove it solely for classification. Foundation includes
        // square brackets in URLComponents.host for literal IPv6 URLs.
        let unbracketed = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let host = String(unbracketed.prefix { $0 != "%" }).lowercased()
        guard !host.isEmpty else { return false }

        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        guard bytes.count == 16 else { return false }

        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        // fc00::/7 (unique local) and fe80::/10 (link-local).
        let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff

        if isIPv4Mapped {
            return isLocalIPv4(Array(bytes[12...15]))
        }
        return isLoopback || isUniqueLocal || isLinkLocal
    }
}

struct Neo4jStatement {
    let statement: String
    let parameters: [String: Any]
}

struct Neo4jQueryError: Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { "\(code): \(message)" }
}

struct Neo4jConnectionError: Error, LocalizedError {
    let underlying: String
    var errorDescription: String? { underlying }
}

/// Thin client for Neo4j's classic transactional HTTP endpoint (`/db/{name}/tx/commit`).
/// Deliberately not the newer Query API (`/query/v2`): that needs Neo4j 5.19+ and is
/// disabled by default on self-managed servers before 5.25, while tx/commit runs
/// unconditionally on 4.x/5.x/2025.x - important since connected instances can be
/// anything from a hosted server to a stock `docker run neo4j`.
struct Neo4jHTTPClient: Sendable {
    typealias RequestExecutor = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    let baseURL: URL
    let database: String
    let username: String
    let password: String
    private let requestExecutor: RequestExecutor

    init(
        baseURL: URL,
        database: String,
        username: String,
        password: String,
        requestExecutor: @escaping RequestExecutor = { request in
            try await Neo4jHTTPClient.dataWithoutRedirects(for: request)
        }
    ) throws {
        self.baseURL = try Neo4jEndpoint.parse(baseURL.absoluteString).url
        self.database = database
        self.username = username
        self.password = password
        self.requestExecutor = requestExecutor
    }

    /// Runs one or more Cypher statements as a single transaction. Returns one array of
    /// row-dictionaries (column name -> value) per statement, in order.
    func run(_ statements: [Neo4jStatement]) async throws -> [[[String: Any]]] {
        var request = URLRequest(url: transactionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        let credentials = Data("\(username):\(password)".utf8).base64EncodedString()
        request.addValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "statements": statements.map { ["statement": $0.statement, "parameters": $0.parameters] }
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await requestExecutor(request)
        } catch {
            throw Neo4jConnectionError(underlying: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Neo4jConnectionError(underlying: "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw Neo4jConnectionError(underlying: "HTTP \(http.statusCode)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Neo4jConnectionError(underlying: "Invalid JSON response")
        }
        // Neo4j answers HTTP 200 even when a statement fails - errors must be checked explicitly.
        if let errors = json["errors"] as? [[String: Any]], let first = errors.first {
            throw Neo4jQueryError(
                code: first["code"] as? String ?? "Unknown",
                message: first["message"] as? String ?? "Unknown error"
            )
        }
        guard let results = json["results"] as? [[String: Any]] else { return [] }
        return results.map { result in
            guard let columns = result["columns"] as? [String],
                  let dataRows = result["data"] as? [[String: Any]] else { return [] }
            return dataRows.compactMap { rowEntry -> [String: Any]? in
                guard let row = rowEntry["row"] as? [Any] else { return nil }
                var dict: [String: Any] = [:]
                for (index, column) in columns.enumerated() where index < row.count {
                    dict[column] = row[index]
                }
                return dict
            }
        }
    }

    /// Connection probe. `RETURN 1` is mandatory; the version lookup is optional because
    /// restricted service accounts often lack permission for `dbms.components()`.
    func testConnection() async throws -> String {
        _ = try await run([Neo4jStatement(statement: "RETURN 1", parameters: [:])])
        do {
            let rows = try await run([Neo4jStatement(
                statement: "CALL dbms.components() YIELD name, versions WHERE name = 'Neo4j Kernel' RETURN versions",
                parameters: [:]
            )])
            if let versions = rows.first?.first?["versions"] as? [Any], let version = versions.first as? String {
                return version
            }
        } catch {
            // The mandatory transaction probe succeeded. Version information is optional.
        }
        return "?"
    }

    private var transactionURL: URL {
        baseURL
            .appendingPathComponent("db", isDirectory: true)
            .appendingPathComponent(database, isDirectory: true)
            .appendingPathComponent("tx", isDirectory: true)
            .appendingPathComponent("commit")
    }

    /// Neo4j credentials must never follow a server-controlled redirect to a different
    /// authority or from HTTPS to HTTP. An ephemeral session retains macOS' normal TLS
    /// certificate validation while this task delegate explicitly rejects every redirect.
    private static func dataWithoutRedirects(for request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await session.data(for: request, delegate: NoRedirectDelegate.shared)
    }

    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = NoRedirectDelegate()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
