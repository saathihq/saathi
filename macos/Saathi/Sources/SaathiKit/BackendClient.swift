//
//  BackendClient.swift
//  SaathiKit
//
//  The only thing that talks to the backend. Provider keys live there and never reach this process.
//

import Foundation
import SaathiContract

public struct BackendHealth: Codable, Sendable, Equatable {
    public let ok: Bool
    public let version: String?
}

/// What `/skills/create` gives back: the drafted SKILL.md, plus the name the model chose so the
/// caller can say what it made without parsing the markdown twice.
public struct BackendSkillDraft: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let markdown: String
}

public enum BackendError: Error, CustomStringConvertible, Equatable {
    case badBaseUrl(String)
    case notAuthenticated
    case http(status: Int, body: String)
    case transport(String)

    public var description: String {
        switch self {
        case let .badBaseUrl(raw): return "\(raw) is not a usable backend URL"
        case .notAuthenticated: return "no token in ~/.saathi/shell.json — sign in first"
        case let .http(status, body): return "backend returned \(status): \(body)"
        case let .transport(reason): return "could not reach the backend: \(reason)"
        }
    }
}

public struct BackendClient: Sendable {
    private let baseUrl: URL
    private let token: String?
    private let session: URLSession

    public init(configuration: SaathiConfiguration, session: URLSession = .shared) throws {
        guard let url = URL(string: configuration.resolvedBaseURL), url.scheme != nil else {
            throw BackendError.badBaseUrl(configuration.resolvedBaseURL)
        }
        self.baseUrl = url
        self.token = configuration.token
        self.session = session
    }

    public func health() async throws -> BackendHealth {
        try await get("/health", authenticated: false)
    }

    /// Asks the backend to draft one SKILL.md from a sentence. The model that writes it runs on the
    /// backend's key, which is the whole reason this is a route rather than a call from the app:
    /// creating a skill must work in `hosted` mode, where the client holds no provider key at all.
    ///
    /// `capabilities` names what this machine can actually do, so the draft never invents a tool.
    public func createSkill(request: String, capabilities: [String] = []) async throws -> BackendSkillDraft {
        try await post(
            "/skills/create",
            body: ["request": request, "capabilities": capabilities],
            // 90 s: one non-streaming model call, and the honest ceiling is well past URLSession's
            // default patience for a request that is doing real work.
            timeout: 90
        )
    }

    private func get<Response: Decodable>(_ path: String, authenticated: Bool) async throws -> Response {
        var request = URLRequest(url: baseUrl.appendingPathComponent(path))
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        if authenticated {
            guard let token, !token.isEmpty else { throw BackendError.notAuthenticated }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Capped: an upstream error page should not become the whole error message, and a
            // backend is entitled to return something enormous when it is unhappy.
            let body = String(data: data.prefix(512), encoding: .utf8) ?? "<unreadable>"
            throw BackendError.http(status: status, body: body)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BackendError.transport("unexpected response shape: \(error.localizedDescription)")
        }
    }

    /// Every authenticated POST goes through here. Shares `get`'s error mapping deliberately: two
    /// verbs that disagree about what an HTTP 401 means is how a caller ends up reporting "could
    /// not reach the backend" for a request the backend answered perfectly clearly.
    private func post<Response: Decodable>(
        _ path: String,
        body: [String: Any],
        timeout: TimeInterval
    ) async throws -> Response {
        guard let token, !token.isEmpty else { throw BackendError.notAuthenticated }

        var request = URLRequest(url: baseUrl.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // The backend states its refusals in an `error` field; surfacing that rather than the
            // raw envelope is the difference between "backend returned 503" and a sentence the
            // person reading the panel can act on.
            let stated = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw BackendError.http(
                status: status,
                body: stated ?? String(data: data.prefix(512), encoding: .utf8) ?? "<unreadable>"
            )
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BackendError.transport("unexpected response shape: \(error.localizedDescription)")
        }
    }
}
