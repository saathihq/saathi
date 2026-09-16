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

public struct SetupPlan: Equatable, Sendable {

    public let provider: ProviderKind
    public let model: String
    /// Empty on the chain lane, which opens no socket.
    public let voiceModel: String
    public let lane: VoiceLane
    /// One line, Saathi's voice, saying what it chose and what that means for the learner.
    public let explanation: String
    /// Keys that were accepted and saved but that nothing will call. Named rather than hidden: a
    /// panel that quietly banks an Anthropic key lets someone believe Claude is answering them.
    public let storedButUnused: [ProviderKind]

    /// The decision, from the only two facts that matter: which keys actually worked.
    ///
    /// OpenAI wins whenever it is available, because it is the only provider with a duplex realtime
    /// socket — the difference between a companion that feels instant and one that feels operated.
    /// That is a capability, not a preference, which is why this is not a setting.
    public static func make(openAIKeyValid: Bool, anthropicKeyValid: Bool) -> SetupPlan {
        if openAIKeyValid {
            let row = SaathiProvider.of(.openai)
            return SetupPlan(
                provider: .openai,
                model: row.defaultModel,
                voiceModel: row.defaultVoiceModel,
                lane: row.voice,
                explanation: "I will talk with you through OpenAI's realtime voice. Your voice "
                    + "leaves this machine as audio, straight to OpenAI — Saathi's servers are not "
                    + "in the conversation.",
                storedButUnused: anthropicKeyValid ? [.anthropic] : [])
        }

        if anthropicKeyValid {
            let row = SaathiProvider.of(.anthropic)
            return SetupPlan(
                provider: .anthropic,
                model: row.defaultModel,
                voiceModel: row.defaultVoiceModel,
                lane: row.voice,
                explanation: "I will listen on this Mac and think with Claude. Your voice stays "
                    + "here — only the words you said are sent.",
                storedButUnused: [])
        }

        let row = SaathiProvider.of(.local)
        return SetupPlan(
            provider: .local,
            model: row.defaultModel,
            voiceModel: row.defaultVoiceModel,
            lane: row.voice,
            explanation: "No key yet, so I will look for a model already running on this machine. "
                + "Start Ollama or LM Studio, or add a key above.",
            storedButUnused: [])
    }

    /// Folds this plan and the keys that earned it into a configuration, leaving everything the
    /// person set by hand — a backend URL, an account token — exactly as it was.
    ///
    /// A key is stored only when it validated. Banking a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working, which is a much worse bug to be
    /// handed than "that key was refused".
    public func applied(
        to existing: SaathiConfiguration,
        openAIKey: String,
        anthropicKey: String
    ) -> SaathiConfiguration {
        var updated = existing
        updated.provider = provider
        updated.model = model
        updated.voiceModel = voiceModel.isEmpty ? nil : voiceModel

        let usesOpenAI = provider == .openai
        let anthropicUsable = provider == .anthropic || storedButUnused.contains(.anthropic)

        updated.openaiKey = usesOpenAI ? Self.cleaned(openAIKey) : existing.openaiKey
        updated.anthropicKey = anthropicUsable ? Self.cleaned(anthropicKey) : existing.anthropicKey
        return updated
    }

    /// A pasted key routinely arrives with a trailing newline, and an untrimmed one is refused in a
    /// way indistinguishable from a wrong key.
    private static func cleaned(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
