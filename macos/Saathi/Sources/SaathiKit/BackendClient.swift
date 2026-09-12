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
}
