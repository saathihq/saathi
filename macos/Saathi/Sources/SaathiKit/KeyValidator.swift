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
//  Both endpoints are model lists: free, instant, and unambiguous about authentication.
//

import Foundation
import SaathiContract

public enum KeyCheck: Equatable, Sendable {
    case valid
    /// The vendor said no. The message names which vendor, because a panel with two key fields in
    /// it needs to say which of them is the problem.
    case rejected(String)
    /// Nothing could be concluded — no network, DNS failure, or the vendor having a bad day.
    case unreachable(String)
}

public struct KeyValidator: Sendable {

    private let urlSession: URLSession

    public init(urlSession: URLSession = URLSession(configuration: .ephemeral)) {
        self.urlSession = urlSession
    }

    /// Where each vendor is asked, and what it is called when telling a person it said no.
    private struct Probe {
        let url: URL
        let name: String
    }

    private func probe(for kind: ProviderKind) -> Probe? {
        switch kind {
        case .openai: return Probe(url: URL(string: "https://api.openai.com/v1/models")!, name: "OpenAI")
        case .anthropic: return Probe(url: URL(string: "https://api.anthropic.com/v1/models")!, name: "Anthropic")
        case .sarvam: return Probe(url: URL(string: "https://api.sarvam.ai/v1/models")!, name: "Sarvam")
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
        request.httpMethod = "GET"
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
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("\(probe.name) gave an answer that could not be read.")
            }
            switch http.statusCode {
            case 200...299:
                return .valid
            case 401, 403:
                return .rejected("\(probe.name) did not accept that key.")
            default:
                // Anything else says nothing about the key — a 429 or a 500 is the vendor's state,
                // not the credential's, and telling someone their key is bad on a 500 is a lie.
                return .unreachable("\(probe.name) answered \(http.statusCode). That is not about your key; try again shortly.")
            }
        } catch {
            return .unreachable("Could not reach \(probe.name). Are you online?")
        }
    }
}
