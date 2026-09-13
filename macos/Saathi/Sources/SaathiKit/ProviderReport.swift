//
//  ProviderReport.swift
//  SaathiKit
//
//  "Which mode am I actually in, and does anything I say leave this machine?"
//
//  That question deserves a first-class answer rather than a paragraph in a README. It is also the
//  one thing a person has to be able to check before trusting a companion with what they are
//  struggling to learn.
//
//  The report is pure: it renders the resolved configuration and nothing else, so both clients
//  produce byte-identical output and `scripts/check-parity.sh` can diff them. Reachability is a
//  separate, opt-in step because it touches the network and its answer depends on the machine.
//

import Foundation
import SaathiContract

public enum ProviderReport {

    /// Deterministic. Same configuration in, same bytes out, on either platform.
    public static func describe(_ configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        let chosenExplicitly = configuration.provider != nil

        var lines: [String] = []
        lines.append("provider: \(row.kind.rawValue)\(chosenExplicitly ? "" : "  (default — nothing configured)")")
        lines.append("  \(row.summary)")
        lines.append("")
        lines.append("  base url   \(configuration.resolvedProviderBaseURL)")
        lines.append("  model      \(configuration.resolvedModel.isEmpty ? "chosen by the backend" : configuration.resolvedModel)")
        lines.append("  your key   \(keyLine(row: row, configuration: configuration))")
        lines.append("  account    \(tokenLine(row: row, configuration: configuration))")
        lines.append("  privacy    \(row.sendsDataOffMachine ? "leaves this machine" : "stays on this machine")")
        return lines.joined(separator: "\n")
    }

    private static func keyLine(row: SaathiProvider, configuration: SaathiConfiguration) -> String {
        guard row.requiresKey else { return "not needed" }
        let present = !(configuration.apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Never the key itself, and never a prefix of it: a logged prefix is still a logged secret.
        return present ? "set" : "MISSING — this mode cannot run without it"
    }

    private static func tokenLine(row: SaathiProvider, configuration: SaathiConfiguration) -> String {
        guard row.requiresToken else { return "not needed" }
        let present = !(configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return present ? "signed in" : "MISSING — sign in, or switch to a mode that needs no account"
    }

    /// Is the configured provider actually there? Opt-in, because it touches the network.
    ///
    /// Any HTTP answer counts as reachable — the question is whether something is listening, not
    /// whether this particular path exists.
    public static func reachability(
        of configuration: SaathiConfiguration,
        session: URLSession = .shared,
        timeout: TimeInterval = 3
    ) async -> String {
        guard let url = URL(string: configuration.resolvedProviderBaseURL) else {
            return "cannot check — \(configuration.resolvedProviderBaseURL) is not a usable URL"
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            _ = try await session.data(for: request)
            return "reachable"
        } catch {
            if configuration.resolvedProvider == .local {
                return "not reachable — start Ollama or LM Studio, or point providerBaseUrl elsewhere"
            }
            return "not reachable — \(error.localizedDescription)"
        }
    }
}
