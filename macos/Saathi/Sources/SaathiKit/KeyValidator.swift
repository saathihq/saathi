//
//  KeyValidator.swift
//  SaathiKit
//
//  Asking a vendor whether a key works, before anything is saved.
//
//  Three outcomes rather than a Bool, because "that key was refused" and "I could not reach OpenAI"
//  send a person to two completely different places. Collapsing them would send someone who is
//  simply offline off to generate a replacement key.
//
//  OpenAI and Anthropic are asked for their model lists: free, instant, and unambiguous about
//  authentication. Sarvam's model list is public, so it is asked something else — see `probe`.
//

import Foundation
import SaathiContract

public enum KeyCheck: Equatable, Sendable {
    case valid
    /// The vendor said no. The message names which vendor, because a panel with three key fields
    /// in it needs to say which of them is the problem.
    case rejected(String)
    /// Nothing could be concluded — no network, DNS failure, or the vendor having a bad day.
    case unreachable(String)
}

public struct KeyValidator: Sendable {

    private let urlSession: URLSession

    public init(urlSession: URLSession = URLSession(configuration: .ephemeral)) {
        self.urlSession = urlSession
    }

    /// How each vendor is asked, and what it is called when telling a person it said no.
    private struct Probe {
        let name: String
        let url: URL
        var method = "GET"
        var body: Data?
        /// Statuses beyond 2xx that still mean the key was let in.
        var letIn: Set<Int> = []
    }

    private func probe(for kind: ProviderKind) -> Probe? {
        switch kind {
        case .openai: return Probe(name: "OpenAI", url: URL(string: "https://api.openai.com/v1/models")!)
        case .anthropic: return Probe(name: "Anthropic", url: URL(string: "https://api.anthropic.com/v1/models")!)
        case .sarvam:
            // Sarvam's model list answers 200 to no key at all, so asking it proved nothing and
            // every string ever pasted passed as a key. Its chat endpoint does check, and checks
            // before it reads the body: an empty request is refused with 403 for a wrong key and
            // with 400 — "missing model" — for a right one. Nothing is run and nothing is billed.
            return Probe(
                name: "Sarvam", url: URL(string: "https://api.sarvam.ai/v1/chat/completions")!,
                method: "POST", body: Data("{}".utf8), letIn: [400, 422])
        case .local, .hosted: return nil
        }
    }

    public func check(_ kind: ProviderKind, key: String) async -> KeyCheck {
        guard let probe = probe(for: kind) else {
            return .rejected("\(kind.rawValue) mode takes no key of its own, so there is nothing to check here.")
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected("Paste a \(probe.name) key first.")
        }

        var request = URLRequest(url: probe.url)
        request.httpMethod = probe.method
        if let body = probe.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The header and its prefix come from the contract row, so a new vendor is a row in the
        // schema rather than another branch here.
        let row = SaathiProvider.of(kind)
        if let header = row.authorizationHeader(credential: trimmed) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        // Anthropic refuses any request without this, key or no key, and the refusal looks exactly
        // like a bad key if the header is missing.
        if kind == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("\(probe.name) gave an answer that could not be read.")
            }
            switch http.statusCode {
            case 200...299:
                return .valid
            case let status where probe.letIn.contains(status):
                return .valid
            case 401, 403:
                return .rejected("\(probe.name) did not accept that key.")
            case 429 where Self.errorCode(in: data) == "insufficient_quota_error":
                // The key is real and the account behind it is empty. Not a wrong key, and not
                // something that waiting will fix.
                return .unreachable(
                    "\(probe.name) knows that key, but its account is out of credits. Top it up, then save the key again.")
            default:
                // Anything else says nothing about the key — a 429 or a 500 is the vendor's state,
                // not the credential's, and telling someone their key is bad on a 500 is a lie.
                return .unreachable("\(probe.name) answered \(http.statusCode). That is not about your key; try again shortly.")
            }
        } catch {
            return .unreachable("Could not reach \(probe.name). Are you online?")
        }
    }

    /// `error.code` in a vendor's refusal, when it has one.
    private static func errorCode(in body: Data) -> String? {
        let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (answer?["error"] as? [String: Any])?["code"] as? String
    }
}
