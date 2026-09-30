//
//  VoiceLaneReport.swift
//  SaathiKit
//
//  "If I talk to Saathi, where does my voice go?"
//
//  The sibling of ProviderReport, and asked for the same reason: a companion you speak to is
//  handling the most identifying thing you produce. The answer is not the same as the provider
//  answer, and that is the point of having it separately — in the `chain` lane your VOICE never
//  leaves the machine even when the provider is a cloud one, because speech-to-text and
//  text-to-speech both run on-device and only the transcript is sent. Someone deciding whether to
//  narrate what they are struggling with deserves to know that distinction exists.
//
//  The one exception is asked for by name: `speech: sarvam` hands the chain lane's ears and mouth
//  to Sarvam, and then the audio does leave — whoever is doing the thinking. This is where that
//  is said.
//
//  Pure, like ProviderReport: the resolved configuration in, the same bytes out on either platform,
//  so `scripts/check-parity.sh` can diff the macOS and Windows clients against each other. Anything
//  that depends on this particular machine — which microphone, whether a local model is actually
//  running — belongs behind a flag, the way `provider --probe` already is.
//

import Foundation
import SaathiContract

public enum VoiceLaneReport {

    /// Deterministic. Same configuration in, same bytes out, on either platform.
    public static func describe(_ configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        let chosenExplicitly = configuration.provider != nil
        let model = configuration.resolvedModel.isEmpty ? "chosen by the backend" : configuration.resolvedModel

        var lines: [String] = []
        lines.append("provider: \(row.kind.rawValue)\(chosenExplicitly ? "" : "  (default — nothing configured)")")
        lines.append("  \(laneSummary(row.voice))")
        lines.append("")
        lines.append("  lane       \(row.voice.rawValue)")
        lines.append("  speech in  \(speechEnd(configuration))")
        lines.append("  thinking   \(model) @ \(configuration.resolvedProviderBaseURL)")
        lines.append("  speech out \(speechEnd(configuration))")
        lines.append("  your voice \(voicePrivacy(configuration))")
        lines.append("  turn       \(turnShape(row.voice))")
        return lines.joined(separator: "\n")
    }

    private static func laneSummary(_ lane: VoiceLane) -> String {
        switch lane {
        case .realtime:
            return "One open connection carries speech in and speech out — the companion can be interrupted mid-sentence."
        case .chain:
            return "Speech in, think, speech out as three separate steps. Slower, and it works with any model."
        }
    }

    /// Where speech is heard, and where it is made: the same place, on either lane. In the chain
    /// lane that is this machine, whoever the provider is — not a fallback, but the reason the
    /// chain lane is worth having at all — unless Sarvam's ears and mouth were asked for.
    private static func speechEnd(_ configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        if row.voice == .realtime { return "\(row.kind.rawValue), over the open connection" }
        return SarvamSpeech.isOn(configuration) ? "sarvam, over the network" : "on this machine"
    }

    private static func voicePrivacy(_ configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        if row.voice == .realtime { return "leaves this machine as audio" }
        if SarvamSpeech.isOn(configuration) { return "leaves this machine as audio, to Sarvam" }
        if row.sendsDataOffMachine { return "stays on this machine — only the transcript is sent" }
        return "stays on this machine"
    }

    private static func turnShape(_ lane: VoiceLane) -> String {
        switch lane {
        case .realtime: return "one connection, no round trip per step"
        case .chain: return "three steps per turn, so expect a pause before Saathi answers"
        }
    }
}
