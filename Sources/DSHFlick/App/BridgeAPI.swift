import Foundation

// MARK: - Bridge payloads
//
// The DSH plugin exposes a tiny loopback API under `/dsh-flick/api`. The menu bar
// app uses it for data that only the Host knows (recent sessions) and for UI
// commands that must run inside the DSH page (new session / open session).

struct BridgeRecentItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String?
    let detail: String?
    let createdAt: Double?
}

struct BridgePing: Decodable, Equatable {
    let ok: Bool
    let version: String?
    let language: String?
    let clientReady: Bool?
    let autoOpenApprovals: Bool?
    let approvalCount: Int?
    let lastAckAction: String?
    let lastAckAt: Double?
}

struct BridgeApprovalItem: Codable, Equatable, Identifiable {
    let key: String
    let clientId: String?
    let sessionId: String
    let sessionTitle: String?
    let cwd: String?
    let toolName: String?
    let reason: String?
    let displayReason: [String: String]?
    let isSubagent: Bool?
    let createdAt: Double?
    let firstSeenAt: Double?

    var id: String { key }
}

private struct BridgeApprovalsResponse: Decodable {
    let ok: Bool
    let autoOpen: Bool?
    let items: [BridgeApprovalItem]?
    let updatedAt: Double?
}

private struct BridgeApprovalAnswerRequest: Encodable {
    let key: String
    let decision: String
    let clientId: String?
}

private struct BridgeRecentResponse: Decodable {
    let ok: Bool
    let items: [BridgeRecentItem]?
}

private struct BridgeActionResponse: Decodable {
    let ok: Bool
    let message: String?
}

private struct BridgeActionRequest: Encodable {
    let action: String
    let sessionId: String?
}

enum BridgeAPIError: Error, LocalizedError {
    case unavailable
    case http(Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "DSH 插件桥接未连接"
        case .http(let status):
            return "DSH 插件桥接返回 HTTP \(status)"
        case .invalidResponse(let detail):
            return "DSH 插件桥接响应无效：\(detail)"
        }
    }
}

/// Minimal authenticated client for the plugin's loopback bridge.
struct BridgeAPI {
    let connection: DSHConnection

    private var baseURL: URL { connection.baseURL }

    func ping() async throws -> BridgePing {
        let data = try await perform(path: "ping", method: "GET", body: nil)
        return try decode(BridgePing.self, from: data)
    }

    func recent(limit: Int = 5) async throws -> [BridgeRecentItem] {
        let data = try await perform(path: "recent?limit=\(limit)", method: "GET", body: nil)
        let response = try decode(BridgeRecentResponse.self, from: data)
        return response.items ?? []
    }

    func approvals() async throws -> (items: [BridgeApprovalItem], autoOpen: Bool) {
        let data = try await perform(path: "approvals", method: "GET", body: nil)
        let response = try decode(BridgeApprovalsResponse.self, from: data)
        guard response.ok else {
            throw BridgeAPIError.invalidResponse("approvals rejected")
        }
        return (response.items ?? [], response.autoOpen ?? true)
    }

    func answerApproval(key: String, decision: String, clientId: String?) async throws {
        let request = BridgeApprovalAnswerRequest(
            key: key,
            decision: decision,
            clientId: clientId
        )
        let body = try JSONEncoder().encode(request)
        let data = try await perform(path: "approval-answer", method: "POST", body: body)
        let response = try decode(BridgeActionResponse.self, from: data)
        guard response.ok else {
            throw BridgeAPIError.invalidResponse(response.message ?? "approval rejected")
        }
    }

    func send(action: String, sessionId: String? = nil) async throws {
        let request = BridgeActionRequest(action: action, sessionId: sessionId)
        let body = try JSONEncoder().encode(request)
        let data = try await perform(path: "action", method: "POST", body: body)
        let response = try decode(BridgeActionResponse.self, from: data)
        guard response.ok else {
            throw BridgeAPIError.invalidResponse(response.message ?? "action rejected")
        }
    }

    // MARK: - Transport

    private func perform(path: String, method: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:\(connection.port)/dsh-flick/api/\(path)") else {
            throw BridgeAPIError.invalidResponse("bad URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 4
        request.setValue(
            "\(connection.cookieName)=\(connection.cookieValue)",
            forHTTPHeaderField: "Cookie"
        )
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BridgeAPIError.unavailable
        }

        guard let http = response as? HTTPURLResponse else {
            throw BridgeAPIError.invalidResponse("not an HTTP response")
        }
        if http.statusCode == 404 {
            throw BridgeAPIError.unavailable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BridgeAPIError.http(http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw BridgeAPIError.invalidResponse(error.localizedDescription)
        }
    }
}
