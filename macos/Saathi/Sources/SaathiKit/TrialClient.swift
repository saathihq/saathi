//
//  TrialClient.swift
//  SaathiKit
//
//  Asking the hosted backend for a trial, on first run, before there is an account or a key.
//
//  The one request Saathi makes with no token, because it is the request that gets one. What is
//  sent is a device id and nothing else — no name, no address, nothing about the machine — and the
//  id exists only so that the same Mac asking again gets the same seven days rather than seven
//  more. It is made once, kept in `shell.json`, and written to disk *before* the network is
//  touched: a refused ask that left no id behind would mint a new one next time, and a new id is
//  a new trial.
//
//  Refusals keep the backend's own sentence. Onboarding promises "the exact reason in words", and
//  the backend is the one that knows whether it was the network's fifth ask or the trial's eighth
//  day.
//

import Foundation
import SaathiContract

public struct TrialGrant: Codable, Sendable, Equatable {
    public let token: String
    /// ISO 8601, as the backend sent it.
    public let expiresAt: String
    public let dailyVoiceSessions: Int

    public init(token: String, expiresAt: String, dailyVoiceSessions: Int) {
        self.token = token
        self.expiresAt = expiresAt
        self.dailyVoiceSessions = dailyVoiceSessions
    }
}

public enum TrialError: Error, CustomStringConvertible, Equatable {
    case badBaseUrl(String)
    /// The backend answered and said no: rate limited, or this Mac's trial has ended. Its words.
    case refused(String)
    /// This backend does not do trials at all — a self-hosted one, or one older than they are.
    case notOffered(String)
    case transport(String)

    public var description: String {
        switch self {
        case let .badBaseUrl(raw): return "\(raw) is not a usable backend URL"
        case let .refused(reason): return reason
        case let .notOffered(reason): return reason
        case let .transport(reason): return "could not set up a trial: \(reason)"
        }
    }
}

public struct TrialClient: Sendable {
    private let baseUrl: URL
    private let session: URLSession

    public init(configuration: SaathiConfiguration, session: URLSession = .shared) throws {
        guard let url = URL(string: configuration.resolvedBaseURL), url.scheme != nil else {
            throw TrialError.badBaseUrl(configuration.resolvedBaseURL)
        }
        self.baseUrl = url
        self.session = session
    }

    public func requestTrial(device: String) async throws -> TrialGrant {
        var request = URLRequest(url: baseUrl.appendingPathComponent("/trial"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["device": device])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TrialError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let stated = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        switch status {
        case 200..<300:
            do {
                return try JSONDecoder().decode(TrialGrant.self, from: data)
            } catch {
                throw TrialError.transport("unexpected response shape: \(error.localizedDescription)")
            }
        case 403, 429:
            throw TrialError.refused(stated ?? "the trial was refused (\(status))")
        case 404, 501:
            throw TrialError.notOffered(stated ?? "this backend does not offer trials")
        default:
            throw TrialError.transport(stated ?? "the backend returned \(status)")
        }
    }
}

public enum TrialEnrollment {

    /// This machine's device id: the stored one, or a new lowercase v4 UUID written into
    /// `configuration`. The caller saves it.
    public static func deviceId(in configuration: inout SaathiConfiguration) -> String {
        let stored = (configuration.deviceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        let made = UUID().uuidString.lowercased()
        configuration.deviceId = made
        return made
    }

    /// Asks for a trial and keeps the answer: the device id is saved before the request, the token
    /// after it. Nothing else in the file changes — in particular not `provider`; where Saathi
    /// thinks afterwards is the learner's choice, made at the end of onboarding.
    public static func enroll(at path: URL, session: URLSession = .shared) async throws -> TrialGrant {
        var configuration = try ConfigurationStore.load(from: path)
        let hadDevice = !(configuration.deviceId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let device = deviceId(in: &configuration)
        if !hadDevice { try ConfigurationStore.save(configuration, to: path) }

        let grant = try await TrialClient(configuration: configuration, session: session).requestTrial(device: device)

        // Onto what is on disk *now*. The request takes seconds, and first run saves on every
        // change: writing back the copy loaded before it would undo whatever was saved meanwhile —
        // `onboarded`, if the demo was skipped while this was in flight.
        var current = (try? ConfigurationStore.load(from: path)) ?? configuration
        current.deviceId = device
        current.token = grant.token
        try ConfigurationStore.save(current, to: path)
        return grant
    }
}
