//
//  SetupPlan.swift
//  SaathiKit
//
//  What "give me your keys and I will set myself up" actually decides.
//
//  This is a value type with no network, no file system and no clock, so the whole of that promise
//  is covered by unit tests rather than by pasting a key and listening. The panel asks it what to
//  do and then does exactly that; it holds no policy of its own.
//

import Foundation
import SaathiContract

/// One string for each vendor a key can be pasted for: the text in Setup's three fields, and the
/// keys a plan is applied with.
public struct VendorKeys: Equatable, Sendable {
    public var openAI: String
    public var sarvam: String
    public var anthropic: String

    public init(openAI: String = "", sarvam: String = "", anthropic: String = "") {
        self.openAI = openAI
        self.sarvam = sarvam
        self.anthropic = anthropic
    }

    /// By vendor. A provider that takes no key of its own has none here: it reads as empty, and
    /// writing to it does nothing.
    public subscript(kind: ProviderKind) -> String {
        get {
            switch kind {
            case .openai: return openAI
            case .sarvam: return sarvam
            case .anthropic: return anthropic
            case .local, .hosted: return ""
            }
        }
        set {
            switch kind {
            case .openai: openAI = newValue
            case .sarvam: sarvam = newValue
            case .anthropic: anthropic = newValue
            case .local, .hosted: break
            }
        }
    }
}

public struct SetupPlan: Equatable, Sendable {

    /// The vendors a key can be pasted for, in the order Setup lists them.
    public static let vendors: [ProviderKind] = [.openai, .sarvam, .anthropic]

    public let provider: ProviderKind
    public let model: String
    /// Empty on the chain lane, which opens no socket.
    public let voiceModel: String
    public let lane: VoiceLane
    /// Whose ears and mouth a chain-lane turn uses. Sarvam's only when the sentence says so: Setup
    /// never sends a voice anywhere `explanation` has not named.
    public let speech: SpeechEngine
    /// One line, Saathi's voice, saying what it chose and what that means for the learner.
    public let explanation: String
    /// Every vendor whose key was accepted, in Setup's order. All of them are saved.
    public let stored: [ProviderKind]
    /// The vendor whose key looks at the screen when a turn asks about something on it, if there
    /// is one: Anthropic's when it is there, OpenAI's otherwise — the choice `ScreenSight` makes.
    public let eye: ProviderKind?
    /// Keys that were accepted and saved and that nothing will call. Named rather than hidden: a
    /// panel that quietly banks a key lets someone believe it is doing something.
    public let storedButUnused: [ProviderKind]

    /// The decision, from four facts: which keys work, which of them were pasted just now, what is
    /// in use, and whose ears and mouth the file asks for.
    ///
    /// - A key that has just been pasted is a statement of what its owner wants — for the two
    ///   vendors that can carry a conversation end to end. Paste an OpenAI key and Saathi moves to
    ///   OpenAI; paste a Sarvam key and it moves to Sarvam, whatever was there before. Both at
    ///   once is OpenAI, because it is the only one with a duplex realtime socket — the difference
    ///   between a companion that feels instant and one that feels operated.
    /// - With nothing new pasted, what is in use stays in use for as long as it can be used. An
    ///   Anthropic key on its own never moves anyone off a provider they chose: it looks at the
    ///   screen.
    /// - Otherwise the most capable key there is, and this machine when there is none.
    ///
    /// Sarvam's ears and mouth are asked for, not assumed. Arriving at Sarvam asks for them, and
    /// so does pasting its key; arriving anywhere else puts speech back on this Mac. While the
    /// provider stays where it is, what the file says stands — so a configuration that thinks
    /// with Sarvam and listens on this Mac is not quietly turned into one that sends audio, and
    /// one that thinks with Claude and listens through Sarvam is not quietly turned back.
    ///
    /// `current` is the provider written in the file, and nil when none is, or when it is one that
    /// can no longer be used for a reason this type cannot see — hosted with no token.
    public static func make(
        valid: Set<ProviderKind>,
        typed: Set<ProviderKind> = [],
        current: ProviderKind? = nil,
        speech: SpeechEngine = .device
    ) -> SetupPlan {
        let provider = chosen(valid: valid, typed: typed, current: current)
        let arrivedAtSarvam = provider == .sarvam && (provider != current || typed.contains(.sarvam))
        let stayed = provider == current
        return plan(
            for: provider, valid: valid,
            wantsSarvamSpeech: arrivedAtSarvam || (stayed && speech == .sarvam))
    }

    /// The plan for a provider someone picked by hand, with whatever keys there are. Picking
    /// Sarvam is picking it whole; picking anything else puts speech back on this Mac.
    public static func choosing(_ provider: ProviderKind, valid: Set<ProviderKind>) -> SetupPlan {
        plan(for: provider, valid: valid, wantsSarvamSpeech: provider == .sarvam)
    }

    static func chosen(valid: Set<ProviderKind>, typed: Set<ProviderKind>, current: ProviderKind?) -> ProviderKind {
        for talker in [ProviderKind.openai, .sarvam] where typed.contains(talker) && valid.contains(talker) {
            return talker
        }
        // A vendor stays only while its key works. This machine and the hosted service take no
        // key of their own, so there is nothing here to have stopped working.
        if let current, !vendors.contains(current) || valid.contains(current) { return current }
        return vendors.first(where: valid.contains) ?? .local
    }

    private static func plan(for provider: ProviderKind, valid: Set<ProviderKind>, wantsSarvamSpeech: Bool) -> SetupPlan {
        let row = SaathiProvider.of(provider)
        let stored = vendors.filter(valid.contains)
        let eye: ProviderKind? = valid.contains(.anthropic) ? .anthropic : valid.contains(.openai) ? .openai : nil
        // Only on the chain lane — the realtime lane carries its own speech — and only with a key
        // to do it with. Asked for without one, it is this Mac's, and the sentence says so.
        let speech: SpeechEngine = row.voice == .chain && wantsSarvamSpeech && valid.contains(.sarvam) ? .sarvam : .device
        return SetupPlan(
            provider: provider,
            model: row.defaultModel,
            voiceModel: row.defaultVoiceModel,
            lane: row.voice,
            speech: speech,
            explanation: explanation(for: provider, speech: speech, hasKeys: !valid.isEmpty),
            stored: stored,
            eye: eye,
            storedButUnused: stored.filter { key in
                key != provider && key != eye && !(key == .sarvam && speech == .sarvam)
            })
    }

    /// The most consequential sentences in the app: each says where the learner's voice goes.
    private static func explanation(for provider: ProviderKind, speech: SpeechEngine, hasKeys: Bool) -> String {
        let toSarvam = "Your voice leaves this machine as audio, straight to Sarvam — Saathi's servers "
            + "are not in the conversation."
        switch (provider, speech) {
        case (.openai, _):
            return "I will talk with you through OpenAI's realtime voice. Your voice "
                + "leaves this machine as audio, straight to OpenAI — Saathi's servers are not "
                + "in the conversation."
        case (.hosted, _):
            return "I will talk with you through Saathi's hosted service. Your voice leaves this "
                + "machine as audio, to the provider Saathi uses."
        case (.sarvam, .sarvam):
            return "I will listen, think and speak through Sarvam, in the language chosen below. " + toSarvam
        case (.sarvam, .device):
            return "I will listen on this Mac and think with Sarvam. Your voice stays "
                + "here — only the words you said are sent."
        case (.anthropic, .sarvam):
            return "I will listen and speak through Sarvam, in the language chosen below, and think "
                + "with Claude. " + toSarvam
        case (.anthropic, .device):
            return "I will listen on this Mac and think with Claude. Your voice stays "
                + "here — only the words you said are sent."
        case (.local, .sarvam):
            return "I will listen and speak through Sarvam, in the language chosen below, and think "
                + "with a model on this Mac. " + toSarvam
        case (.local, .device):
            return hasKeys
                ? "I will listen and think on this Mac, with a model already running on it — "
                    + "Ollama or LM Studio. Nothing you say leaves it."
                : "No key yet, so I will look for a model already running on this machine. "
                    + "Start Ollama or LM Studio, or add a key above."
        }
    }

    /// Folds this plan and the keys that earned it into a configuration, leaving everything the
    /// person set by hand — a backend URL, an account token — exactly as it was.
    ///
    /// A key is stored only when it validated. Banking a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working, which is a much worse bug to be
    /// handed than "that key was refused". A blank for a vendor that did validate keeps the key
    /// already on disk: blank means nothing was typed, not "forget it".
    ///
    /// The model, the voice model and the voice are the new provider's when the provider changes,
    /// and left alone when it does not — so a model chosen by hand survives a key being replaced,
    /// and a voice chosen for one provider is never sent to another that does not have it.
    public func applied(to existing: SaathiConfiguration, keys: VendorKeys) -> SaathiConfiguration {
        var updated = existing
        if existing.resolvedProvider != provider {
            updated.model = model.isEmpty ? nil : model
            updated.voiceModel = voiceModel.isEmpty ? nil : voiceModel
            updated.voice = nil
        }
        updated.provider = provider
        updated.speech = speech == .device ? nil : speech

        for vendor in stored {
            let key = Self.cleaned(keys[vendor])
            switch vendor {
            case .openai: updated.openaiKey = key ?? existing.openaiKey
            case .sarvam: updated.sarvamKey = key ?? existing.sarvamKey
            case .anthropic: updated.anthropicKey = key ?? existing.anthropicKey
            case .local, .hosted: break
            }
        }
        return updated
    }

    /// A pasted key routinely arrives with a trailing newline, and an untrimmed one is refused in a
    /// way indistinguishable from a wrong key.
    private static func cleaned(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
