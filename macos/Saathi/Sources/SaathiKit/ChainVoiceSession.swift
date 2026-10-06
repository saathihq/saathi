//
//  ChainVoiceSession.swift
//  SaathiKit
//
//  The lane that works everywhere: speech in, think, speech out, as three separate steps.
//
//  This is the slower path — the predecessor moved away from exactly this shape because a turn took
//  seconds rather than being instant. It exists here anyway, and it is not a consolation prize:
//
//  - It is the ONLY lane that works in `local` mode, which is Saathi's default. A companion whose
//    default mode cannot be spoken to would have the accessibility premise backwards.
//  - By default both ends run on-device (`DeviceEars`, the system voice), so even with a cloud
//    provider doing the thinking, the learner's VOICE never leaves the machine — only the
//    transcript does. For someone narrating what they are struggling with, that is a materially
//    different promise from the realtime lane, and `VoiceLaneReport` says so out loud.
//  - It is the lane Sarvam rides: with `speech: sarvam` the ears are Saaras and the mouth is
//    Bulbul, which is the only way to be heard in most Indian languages. The voice then does leave
//    the machine, and the same report says that instead.
//
//  The session does not know whose ears it has. It is handed a pair, and a speaker, and does the
//  step in the middle: an OpenAI-compatible `/chat/completions` with the generated contract tools
//  attached, which is why Ollama, LM Studio, llama.cpp and Sarvam all work through one code path.
//

import Foundation
import os
import SaathiContract

public final class ChainVoiceSession: VoiceSession, @unchecked Sendable {

    public let lane: VoiceLane = .chain
    public let speaksForItself = false

    private let configuration: SaathiConfiguration
    private let speaker: any Speaker
    let ears: any Ears
    private let urlSession: URLSession
    private let look: @Sendable (String) async -> ScreenLook
    /// False for a session that only listens: a turn ends with the transcript and nothing is sent
    /// to any model. First run uses it — "can I hear you?" and "what should I call you?" are
    /// answered by what was heard, and must work before a model has been chosen at all.
    public let thinks: Bool

    /// How many times the model may be asked in one turn: once, and again after it has looked at
    /// the screen or been told a tool call could not be done. A model that keeps asking is
    /// stopped here rather than left to spend the learner's patience and their credit.
    static let mostRequestsPerTurn = 3

    /// Everything touched from more than one thread, behind one scoped lock. `withLock` cannot
    /// span an `await`, which is the property that matters.
    private struct State {
        var callbacks = VoiceSessionCallbacks()
        /// Bumped whenever the learner starts something new. An answer from before it is never
        /// spoken: they have moved on, and talking over them is the one thing a companion that
        /// listens must not do.
        var epoch = 0
        /// The turn being answered — heard, thought about, looked for, spoken — so an interruption
        /// can drop all of it at once. Saaras, a look and Bulbul are requests too, and a turn left
        /// waiting on any of them keeps the next one from opening the microphone.
        var turn: Task<Void, any Error>?
        /// The conversation so far. The chain lane has no server-side session, so continuity is
        /// this. Behind the lock, and written only by the turn that is current: a typed question
        /// can arrive while a spoken one is still being answered.
        var history: [[String: Any]] = []
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// The most messages kept. A conversation is not resent whole for ever: each turn would cost
    /// more than the last, and in the end more than the model takes.
    static let longestHistory = 40

    /// `ears`: on-device ones in the language of Settings unless a pair is handed in.
    /// `look`: what answers a `look_at_screen`; `ScreenSight` unless a test says otherwise.
    public init(
        configuration: SaathiConfiguration,
        speaker: any Speaker,
        ears: (any Ears)? = nil,
        urlSession: URLSession = URLSession(configuration: .default),
        thinks: Bool = true,
        look: (@Sendable (String) async -> ScreenLook)? = nil
    ) {
        self.configuration = configuration
        self.speaker = speaker
        self.ears = ears ?? DeviceEars(language: configuration.resolvedLanguage)
        self.urlSession = urlSession
        self.thinks = thinks
        self.look = look ?? { question in
            await ScreenSight(configuration: configuration).answer(question)
        }
    }

    public func start(callbacks: VoiceSessionCallbacks) async throws {
        state.withLockUnchecked { $0.callbacks = callbacks }
        // The ears ask for what they need, once, up front, and say what is being asked for. Being
        // surprised by a permission dialog mid-sentence is exactly what this project should not do.
        callbacks.onStatus?(try await ears.prepare())
    }

    public func beginTurn() async throws {
        let callbacks = state.withLockUnchecked { $0.callbacks }
        try await ears.begin(EarsFeedback(
            onLevel: callbacks.onInputLevel, onPartial: callbacks.onPartialTranscript))
        callbacks.onStatus?("listening…")
    }

    public func endTurn() async throws {
        let (callbacks, epoch) = state.withLockUnchecked { ($0.callbacks, $0.epoch) }
        try await run(epoch: epoch) { [self] in
            let heard = try await ears.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCurrent(epoch) else { return }
            guard !heard.isEmpty else {
                callbacks.onStatus?("did not catch that")
                // A listen-only session leaves the asking-again to whoever is listening through it.
                if thinks { await speaker.speak("I did not catch that. Say it once more?", tone: .calm) }
                return
            }
            callbacks.onUserTranscript?(heard)
            guard thinks else {
                callbacks.onStatus?("heard")
                return
            }
            callbacks.onStatus?("thinking…")
            try await think(about: heard, epoch: epoch, callbacks: callbacks)
        }
    }

    public func sendText(_ text: String) async throws {
        // A typed question supersedes whatever was being said or thought about, as a held turn does.
        interrupt()
        let (callbacks, epoch) = state.withLockUnchecked { ($0.callbacks, $0.epoch) }
        callbacks.onUserTranscript?(text)
        guard thinks else { return }
        callbacks.onStatus?("thinking…")
        try await run(epoch: epoch) { [self] in
            try await think(about: text, epoch: epoch, callbacks: callbacks)
        }
    }

    /// The learner has started talking. Whatever Saathi was saying stops, and the turn it was in
    /// the middle of is dropped whole — what it was hearing, asking, looking at or about to say —
    /// so the microphone is not kept waiting on any of it.
    public func interrupt() {
        let turn = state.withLockUnchecked { state -> Task<Void, any Error>? in
            state.epoch += 1
            // What the dropped turn asked goes with it. Left in the conversation, the question
            // nobody wanted answered would be answered along with the next one.
            if state.history.last?["role"] as? String == "user" { state.history.removeLast() }
            defer { state.turn = nil }
            return state.turn
        }
        turn?.cancel()
        (speaker as? StoppableSpeaker)?.stop()
    }

    /// One turn's work, as a task an interruption can cancel.
    ///
    /// A turn the learner talked over ends quietly whatever it was doing: its requests were
    /// cancelled on purpose, and reporting that as a failure would put an alert on the island for
    /// doing the right thing. A turn that fails for real leaves no unanswered question behind it.
    private func run(epoch: Int, _ work: @escaping @Sendable () async throws -> Void) async throws {
        let turn = Task { try await work() }
        state.withLockUnchecked { $0.turn = turn }
        defer { state.withLockUnchecked { if $0.turn == turn { $0.turn = nil } } }
        do {
            try await withTaskCancellationHandler {
                try await turn.value
            } onCancel: {
                turn.cancel()
            }
        } catch {
            let current = state.withLockUnchecked { state -> Bool in
                guard state.epoch == epoch else { return false }
                if state.history.last?["role"] as? String == "user" { state.history.removeLast() }
                return true
            }
            if current { throw error }
        }
    }

    /// Adds to the conversation, if this turn is still the one being answered. One that has been
    /// talked over can no longer write to it.
    private func record(_ messages: [[String: Any]], epoch: Int) -> Bool {
        state.withLockUnchecked { state in
            guard state.epoch == epoch else { return false }
            state.history = Self.trimmed(state.history + messages)
            return true
        }
    }

    /// The end of a conversation, cut at the start of a turn — never at a tool's answer to a call
    /// that has been cut away, which a server would refuse.
    static func trimmed(_ history: [[String: Any]], keeping limit: Int = longestHistory) -> [[String: Any]] {
        guard history.count > limit else { return history }
        var start = history.count - limit
        while start < history.count, history[start]["role"] as? String != "user" { start += 1 }
        return start < history.count ? Array(history[start...]) : history
    }

    public func stop() async {
        interrupt()
        ears.cancel()
    }

    private func isCurrent(_ epoch: Int) -> Bool {
        state.withLockUnchecked { $0.epoch == epoch }
    }

    // MARK: The thinking step

    private func think(about said: String, epoch: Int, callbacks: VoiceSessionCallbacks) async throws {
        guard record([["role": "user", "content": said]], epoch: epoch) else { return }

        var spoke = false
        var acted = false

        for _ in 0..<Self.mostRequestsPerTurn {
            let message = try await complete()
            guard isCurrent(epoch) else { return }

            let calls = Self.toolCalls(in: message)
            let content = (message["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let looks = calls.contains { $0.name == LookAtScreenAction.wireName }

            // Words that come with a look are said before it: "let me see" belongs in front of the
            // pause, not after it. Everything else keeps the other order — doing the thing before
            // narrating it reads as competent, and a failed tool call changes what there is to say.
            if looks, !content.isEmpty {
                callbacks.onSaathiTranscript?(content)
                await speaker.speak(content, tone: .neutral)
                spoke = true
                guard isCurrent(epoch) else { return }
            }

            // What this round adds to the conversation: the reply, and an answer to every tool call
            // in it. Kept aside until the round is whole, because a reply with tool calls and no
            // answers to them is a conversation the next request would be refused for.
            var round: [[String: Any]] = [Self.kept(message)]
            var owesAnAnswer = false
            for call in calls {
                if call.name == LookAtScreenAction.wireName {
                    // Looking is the one tool whose *answer* is the point. It goes back to the
                    // model, which then says what it saw.
                    let question = (call.arguments["question"] as? String) ?? said
                    callbacks.onStatus?("looking at the screen…")
                    let seen = await look(question)
                    guard isCurrent(epoch) else { return }
                    callbacks.onScreenLook?(question, seen.answer)
                    if let target = seen.target { callbacks.onPointAt?(target) }
                    round.append(Self.toolResult(call.id, seen.answer))
                    owesAnAnswer = true
                    continue
                }
                switch VoiceToolCall.parse(name: call.name, arguments: call.arguments) {
                case let .success(action):
                    callbacks.onAction?(action)
                    acted = true
                    round.append(Self.toolResult(call.id, "done"))
                case let .failure(failure):
                    // Handed back rather than dropped, so the model can say something true instead
                    // of narrating an action that never happened.
                    callbacks.onStatus?("ignored a tool call: \(failure.description)")
                    round.append(Self.toolResult(call.id, "not done — \(failure.description)"))
                    owesAnAnswer = true
                }
            }
            guard record(round, epoch: epoch) else { return }

            if !looks, !content.isEmpty {
                callbacks.onSaathiTranscript?(content)
                await speaker.speak(content, tone: .neutral)
                spoke = true
                guard isCurrent(epoch) else { return }
            }

            guard owesAnAnswer else { break }
            callbacks.onStatus?("thinking…")
        }

        if !spoke, !acted, isCurrent(epoch) {
            // Neither words nor an action. Saying nothing at all reads as a hang to someone who
            // cannot see a spinner.
            await speaker.speak("I am not sure what to do with that.", tone: .calm)
        }
    }

    /// One request to the model with the conversation so far, and the message it answered with.
    private func complete() async throws -> [String: Any] {
        let history = state.withLockUnchecked { $0.history }
        let request = try Self.completionRequest(configuration: configuration, history: history)

        let data: Data
        let response: URLResponse
        do {
            // Cancelled with the turn it belongs to, when the learner talks over it.
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw Self.unreachable(error, configuration: configuration)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Self.refusal(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, configuration: configuration)
        }
        guard let message = Self.message(in: data) else {
            throw VoiceError.transport("could not read the model's answer")
        }
        return message
    }

    // MARK: What is sent, and what is kept

    /// The request for one reply. Pure, so what a provider is actually sent can be read in a test
    /// — and so `saathi sarvam` can send exactly what a turn would.
    static func completionRequest(configuration: SaathiConfiguration, history: [[String: Any]]) throws -> URLRequest {
        let row = configuration.providerRow
        let base = configuration.resolvedProviderBaseURL
        guard let url = chatCompletionsURL(base: base) else {
            throw VoiceError.transport("\(base) is not a usable base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The credential and how to present it both come from the contract row, so adding a
        // provider stays a row in the schema rather than a branch here.
        let credential = (row.requiresToken ? configuration.token : configuration.credential(for: row.kind)) ?? ""
        if let header = row.authorizationHeader(credential: credential) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let instructions: [String: Any] = [
            "role": "system", "content": RealtimeVoiceSession.instructions(for: configuration),
        ]
        var body: [String: Any] = [
            "model": configuration.resolvedModel,
            "messages": [instructions] + history,
            "tools": try chatTools(),
            "tool_choice": "auto",
        ]
        // Sarvam-105B reasons before it answers unless told not to, and bills the reasoning. A
        // spoken reply is a sentence or two; the pause in front of it is the cost that matters.
        if row.kind == .sarvam { body["reasoning_effort"] = NSNull() }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Where a provider's chat completions live: `/chat/completions` on its base, and a base that
    /// names no path at all gets `/v1` first.
    ///
    /// Every OpenAI-compatible server Saathi is pointed at serves them under `/v1` — Ollama,
    /// LM Studio, llama.cpp, Anthropic's compatibility layer. The local row's base is
    /// `http://localhost:11434`, which is also how anyone would write another Ollama host, and
    /// `/chat/completions` straight on that is a 404 from the very server the default mode is for.
    /// A base that already names a path is taken at its word.
    static func chatCompletionsURL(base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: root), url.scheme != nil, url.host != nil else { return nil }
        return URL(string: "\(root)\(url.path.isEmpty ? "/v1" : "")/chat/completions")
    }

    /// The contract's tools in the chat-completions envelope: `{"type": "function", "function":
    /// {name, description, parameters}}`. The generated list is in the realtime socket's shape,
    /// with `type` beside the name, and it used to be nested as it stood — so every server was
    /// handed a `function` with a `type` inside it, which a strict one is entitled to refuse.
    static func chatTools() throws -> [[String: Any]] {
        try VoiceToolCall.toolDefinitions().map { tool in
            var function = tool
            function.removeValue(forKey: "type")
            return ["type": "function", "function": function]
        }
    }

    static func message(in data: Data) -> [String: Any]? {
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = answer["choices"] as? [[String: Any]] else { return nil }
        return choices.first?["message"] as? [String: Any]
    }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: [String: Any]
    }

    /// Every tool call in a reply, a malformed one included: each has an id the next request must
    /// answer, so one that cannot be read is kept — with no name, which nothing will accept — and
    /// answered with why, rather than left as a hole in the conversation.
    static func toolCalls(in message: [String: Any]) -> [ToolCall] {
        ((message["tool_calls"] as? [[String: Any]]) ?? []).map { call in
            let function = call["function"] as? [String: Any]
            var arguments: [String: Any] = [:]
            if let text = function?["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                arguments = parsed
            } else if let object = function?["arguments"] as? [String: Any] {
                // Ollama sends the arguments as an object rather than as a string of JSON.
                arguments = object
            }
            return ToolCall(
                id: (call["id"] as? String) ?? "",
                name: (function?["name"] as? String) ?? "",
                arguments: arguments)
        }
    }

    static func toolResult(_ id: String, _ content: String) -> [String: Any] {
        ["role": "tool", "tool_call_id": id, "content": content]
    }

    /// What of a reply goes back to the model next turn: its words and its tool calls. Not
    /// `reasoning_content` — Sarvam's thinking, which it would bill a second time for being sent
    /// back — nor anything else a server adds to its own messages.
    static func kept(_ message: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = ["role": "assistant"]
        let content = message["content"] as? String
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            kept["tool_calls"] = calls
            // A reply that is only tool calls has no words, and says so with a null.
            if let content { kept["content"] = content } else { kept["content"] = NSNull() }
        } else {
            kept["content"] = content ?? ""
        }
        return kept
    }

    // MARK: When it does not work

    /// A provider's no, as a sentence someone can act on.
    static func refusal(status: Int, body: Data, configuration: SaathiConfiguration) -> any Error {
        switch configuration.resolvedProvider {
        case .sarvam:
            return SarvamError.refusal(status: status, body: body)
        case .local:
            return VoiceError.transport(
                "the local model at \(configuration.resolvedProviderBaseURL) did not answer. "
                + "Is Ollama or LM Studio running? (\(statedReason(in: body)))")
        default:
            return VoiceError.transport(statedReason(in: body))
        }
    }

    /// No answer at all. A cancelled request stays a cancellation: it was dropped on purpose.
    static func unreachable(_ error: any Error, configuration: SaathiConfiguration) -> any Error {
        if error is CancellationError { return error }
        if let url = error as? URLError, url.code == .cancelled { return CancellationError() }
        switch configuration.resolvedProvider {
        case .sarvam:
            return SarvamError.unreachable(error.localizedDescription)
        case .local:
            return VoiceError.transport(
                "the local model at \(configuration.resolvedProviderBaseURL) did not answer. "
                + "Is Ollama or LM Studio running? (\(error.localizedDescription))")
        default:
            return VoiceError.transport(error.localizedDescription)
        }
    }

    /// A server's own words for a refusal — `error.message`, or `error`, or `detail` — and the
    /// body itself, clipped, when it is none of those. A page of JSON is not a sentence.
    static func statedReason(in body: Data) -> String {
        if let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let stated = (answer["error"] as? [String: Any])?["message"] as? String { return stated }
            if let stated = answer["error"] as? String { return stated }
            if let stated = answer["detail"] as? String { return stated }
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no response body" : text
    }
}
