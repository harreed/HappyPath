import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import ProjectDomain
import Security

private struct LinearConnection: Codable {
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

private enum LinearConnectionStore {
    private static let service = "dev.agentic.HappyPath.linear-mcp"
    private static let account = "readonly-oauth"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> LinearConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(LinearConnection.self, from: data)
    }

    static func save(_ connection: LinearConnection) throws {
        let data = try JSONEncoder().encode(connection)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw LinearImportError.keychain }
        var item = query
        item[kSecValueData as String] = data
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LinearImportError.keychain }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LinearImportError.keychain }
    }
}

enum LinearImportError: LocalizedError {
    case invalidURL, connectionRequired, keychain, authentication, response, issueUnavailable, missingTool, missingCriteria

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Paste a Linear issue URL or an issue ID such as TEAM-123."
        case .connectionRequired: "Connect Linear to read this ticket."
        case .keychain: "Could not save the Linear connection in Keychain."
        case .authentication: "Linear sign-in did not complete. Try connecting again."
        case .response: "Linear returned a response the app could not read."
        case .issueUnavailable: "This ticket could not be found in the connected Linear workspace."
        case .missingTool: "The Linear connection does not offer issue lookup."
        case .missingCriteria: "Add a visible success description before creating the test."
        }
    }
}

private final class LinearAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow()
    }
}

private final class RejectLinearRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class LinearMCPClient {
    static let shared = LinearMCPClient()
    private let endpoint = URL(string: "https://mcp.linear.app/mcp/readonly")!
    private let issuer = URL(string: "https://mcp.linear.app")!
    private let redirectURI = "happypath-linear://oauth/callback"
    private let presenter = LinearAuthPresenter()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RejectLinearRedirects(), delegateQueue: nil)
    }()
    private var authenticationSession: ASWebAuthenticationSession?
    var isConnected: Bool { LinearConnectionStore.load() != nil }

    func disconnect() throws { try LinearConnectionStore.remove() }

    func connect() async throws {
        let metadata = try await getJSON(issuer.appendingPathComponent(".well-known/oauth-authorization-server"))
        guard let register = url(metadata["registration_endpoint"]),
              let authorize = url(metadata["authorization_endpoint"]),
              let token = url(metadata["token_endpoint"]),
              register.host == issuer.host, authorize.host == issuer.host, token.host == issuer.host else {
            throw LinearImportError.authentication
        }
        let registration = try await postJSON(register, object: [
            "client_name": "HappyPath",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        guard let clientID = registration["client_id"] as? String else { throw LinearImportError.authentication }
        let verifier = Self.randomURLSafeString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomURLSafeString()
        var components = URLComponents(url: authorize, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: "read"),
            .init(name: "resource", value: endpoint.absoluteString),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        guard let authURL = components.url else { throw LinearImportError.authentication }
        let callback = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "happypath-linear") { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? LinearImportError.authentication) }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            if !session.start() {
                authenticationSession = nil
                continuation.resume(throwing: LinearImportError.authentication)
            }
        }
        authenticationSession = nil
        let response = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let returnedIssuer = response?.queryItems?.first(where: { $0.name == "iss" })?.value
        guard callback.scheme == "happypath-linear", returnedIssuer == nil || returnedIssuer == issuer.absoluteString,
              response?.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = response?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw LinearImportError.authentication
        }
        let tokens = try await postForm(token, fields: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI,
            "client_id": clientID, "code_verifier": verifier, "resource": endpoint.absoluteString
        ])
        guard let accessToken = tokens["access_token"] as? String else { throw LinearImportError.authentication }
        let lifetime = tokens["expires_in"] as? Double
        try LinearConnectionStore.save(.init(clientID: clientID, accessToken: accessToken,
            refreshToken: tokens["refresh_token"] as? String,
            expiresAt: lifetime.map { Date().addingTimeInterval($0) }))
    }

    func fetchIssue(_ input: String) async throws -> LinearIssueDraft {
        let identifier = try Self.issueIdentifier(input)
        let token = try await accessToken()
        var sessionID: String?
        let initialization = try await rpc("initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [:],
            "clientInfo": ["name": "HappyPath", "version": "0.2.0"]
        ], id: 1, token: token, sessionID: &sessionID)
        guard initialization["result"] is [String: Any] else { throw LinearImportError.response }
        _ = try await rpc("notifications/initialized", params: [:], id: nil, token: token, sessionID: &sessionID)
        var tools: [[String: Any]] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let listing = try await rpc("tools/list", params: params, id: 2, token: token, sessionID: &sessionID)
            guard let page = listing["result"] as? [String: Any] else { throw LinearImportError.response }
            tools += page["tools"] as? [[String: Any]] ?? []
            cursor = page["nextCursor"] as? String
            if let cursor, !seenCursors.insert(cursor).inserted { throw LinearImportError.response }
        } while cursor != nil && !tools.contains(where: { ($0["name"] as? String) == "get_issue" })
        guard let lookup = tools.first(where: { ($0["name"] as? String) == "get_issue" }),
              let name = lookup["name"] as? String else { throw LinearImportError.missingTool }
        let schema = lookup["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let key = ["id", "issueId", "identifier"].first(where: { properties[$0] != nil }) ?? "id"
        let result = try await rpc("tools/call", params: [
            "name": name, "arguments": [key: identifier]
        ], id: 3, token: token, sessionID: &sessionID)
        guard let payload = result["result"] as? [String: Any], payload["isError"] as? Bool != true,
              let issue = Self.findIssue(in: payload),
              let returnedID = issue["identifier"] as? String,
              returnedID.caseInsensitiveCompare(identifier) == .orderedSame,
              let title = issue["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LinearImportError.issueUnavailable
        }
        let pastedURL = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines))
        let sourceURL = ((issue["url"] as? String).flatMap(URL.init(string:)) ?? pastedURL)
            .flatMap { $0.scheme == "https" && ["linear.app", "www.linear.app"].contains($0.host?.lowercased() ?? "") ? $0 : nil }
            ?? URL(string: "https://linear.app/issue/\(identifier)")!
        return LinearIssueDraft(identifier: returnedID, title: title,
            description: issue["description"] as? String ?? "", url: sourceURL)
    }

    static func issueIdentifier(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil {
            return trimmed.uppercased()
        }
        guard let url = URL(string: trimmed), url.scheme == "https",
              ["linear.app", "www.linear.app"].contains(url.host?.lowercased() ?? "") else {
            throw LinearImportError.invalidURL
        }
        let segments = url.pathComponents
        guard let segment = segments.first(where: {
            $0.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+(?:-|$)"#, options: .regularExpression) != nil
        }), let match = segment.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+"#, options: .regularExpression) else {
            throw LinearImportError.invalidURL
        }
        return String(segment[match]).uppercased()
    }

    private func accessToken() async throws -> String {
        guard var connection = LinearConnectionStore.load() else { throw LinearImportError.connectionRequired }
        if let expiresAt = connection.expiresAt, expiresAt <= Date().addingTimeInterval(60) {
            guard let refreshToken = connection.refreshToken else { throw LinearImportError.connectionRequired }
            let tokens = try await postForm(issuer.appendingPathComponent("token"), fields: [
                "grant_type": "refresh_token", "refresh_token": refreshToken,
                "client_id": connection.clientID, "resource": endpoint.absoluteString
            ])
            guard let newAccessToken = tokens["access_token"] as? String else { throw LinearImportError.connectionRequired }
            connection.accessToken = newAccessToken
            connection.refreshToken = tokens["refresh_token"] as? String ?? refreshToken
            connection.expiresAt = (tokens["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
            try LinearConnectionStore.save(connection)
        }
        return connection.accessToken
    }

    private func rpc(_ method: String, params: [String: Any], id: Int?, token: String,
                     sessionID: inout String?) async throws -> [String: Any] {
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { body["id"] = id }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw LinearImportError.response }
        if response.statusCode == 401 { throw LinearImportError.connectionRequired }
        guard (200...299).contains(response.statusCode) else { throw LinearImportError.response }
        if let value = response.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionID = value }
        if id == nil { return [:] }
        let json: Any
        if response.mimeType == "text/event-stream" {
            let events = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
                .filter { $0.hasPrefix("data:") }
                .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            guard let event = events.last, let eventData = event.data(using: .utf8) else { throw LinearImportError.response }
            json = try JSONSerialization.jsonObject(with: eventData)
        } else { json = try JSONSerialization.jsonObject(with: data) }
        guard let object = json as? [String: Any], object["error"] == nil else { throw LinearImportError.response }
        return object
    }

    private static func findIssue(in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if object["identifier"] is String, object["title"] is String { return object }
            for key in ["issue", "data", "structuredContent", "content"] {
                if let nested = object[key], let issue = findIssue(in: nested) { return issue }
            }
            if let text = object["text"] as? String, let data = text.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) {
                return findIssue(in: decoded)
            }
        }
        if let values = value as? [Any] {
            for item in values { if let issue = findIssue(in: item) { return issue } }
        }
        return nil
    }

    private func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await send(URLRequest(url: url))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinearImportError.response
        }
        return result
    }

    private func postJSON(_ url: URL, object: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: object)
        return try await performJSON(request)
    }

    private func postForm(_ url: URL, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields.map { key, value in
            "\(key.formEncoded)=\(value.formEncoded)"
        }.sorted().joined(separator: "&").data(using: .utf8)
        return try await performJSON(request)
    }

    private func performJSON(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await send(request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LinearImportError.authentication
        }
        return result
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        guard data.count <= 2_000_000 else { throw LinearImportError.response }
        return (data, response)
    }

    private func url(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text), url.scheme == "https" else { return nil }
        return url
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension String {
    var formEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? self
    }
}
