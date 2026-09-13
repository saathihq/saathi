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
//  - Both ends run on-device (`SFSpeechRecognizer` with on-device recognition required,
//    `AVSpeechSynthesizer`), so even with a cloud provider doing the thinking, the learner's VOICE
//    never leaves the machine — only the transcript does. For someone narrating what they are
//    struggling with, that is a materially different promise from the realtime lane, and
//    `VoiceLaneReport` says so out loud.
//
//  The thinking step talks to an OpenAI-compatible `/chat/completions` with the generated contract
//  tools attached, which is why Ollama, LM Studio, llama.cpp and Sarvam all work through one code
//  path. Anthropic's messages API has a different tool envelope; that is handled at the request
//  boundary rather than by a second session class.
//

import AVFoundation
import Foundation
import os
import SaathiContract
import Speech

public final class ChainVoiceSession: NSObject, VoiceSession, @unchecked Sendable {

    public let lane: VoiceLane = .chain

    private let configuration: SaathiConfiguration
    private let speaker: any Speaker
    private let urlSession: URLSession

    /// Everything touched from both the caller and the recognition callback, behind one scoped
    /// lock. `NSLock.lock()` is unavailable from an async context in the Swift 6 language mode —
    /// and rightly so, since holding a lock across a suspension point is how deadlocks are made.
    /// `withLock` cannot span an `await`, which is the property that matters.
    private struct State {
        var callbacks = VoiceSessionCallbacks()
        var request: SFSpeechAudioBufferRecognitionRequest?
        var recognitionTask: SFSpeechRecognitionTask?
        var audioEngine: AVAudioEngine?
        var latestTranscript = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var recognizer: SFSpeechRecognizer?
    /// The conversation so far. The chain lane has no server-side session, so continuity is this.
    /// Only ever touched from `think`, which is serial per turn.
    private var history: [[String: Any]] = []

    public init(
        configuration: SaathiConfiguration,
        speaker: any Speaker,
        urlSession: URLSession = URLSession(configuration: .default)
    ) {
        self.configuration = configuration
        self.speaker = speaker
        self.urlSession = urlSession
        super.init()
    }

    public func start(callbacks: VoiceSessionCallbacks) async throws {
        state.withLock { $0.callbacks = callbacks }

        // Ask once, up front, and say what is being asked for. Being surprised by a permission
        // dialog mid-sentence is exactly the kind of thing this project should not do.
        let authorized = await Self.requestSpeechAuthorization()
        guard authorized else {
            throw VoiceError.notConfigured(
                "Saathi needs permission to use speech recognition. Grant it in System Settings → Privacy & Security → Speech Recognition.")
        }

        let recognizer = SFSpeechRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            throw VoiceError.notConfigured("no speech recogniser is available for this locale")
        }
        // The on-device requirement is the promise, not an optimisation. Without it Apple may send
        // audio to its own servers, which would make the report's "your voice stays on this
        // machine" line false — so an unavailable on-device recogniser is an error, not a fallback.
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.notConfigured(
                "on-device speech recognition is not available for \(recognizer.locale.identifier). "
                + "Add the language under System Settings → Keyboard → Dictation to download it.")
        }
        self.recognizer = recognizer
        callbacks.onStatus?("ready — on-device speech recognition (\(recognizer.locale.identifier))")
    }

    public func beginTurn() async throws {
        guard let recognizer else { throw VoiceError.notConfigured("start() was not called") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.audio("no microphone input available")
        }
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        let callbacks = state.withLock { box -> VoiceSessionCallbacks in
            box.request = request
            box.audioEngine = engine
            box.latestTranscript = ""
            return box.callbacks
        }

        callbacks.onStatus?("listening…")
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            self.state.withLock { $0.latestTranscript = text }
        }
        state.withLock { $0.recognitionTask = task }
    }

    public func endTurn() async throws {
        let (engine, request, callbacks) = state.withLock { box in
            (box.audioEngine, box.request, box.callbacks)
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()

        // Recognition finishes slightly after the audio does. Poll briefly rather than racing it —
        // the alternative is dropping the last word of every turn.
        var transcript = ""
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            transcript = state.withLock { $0.latestTranscript }
            if !transcript.isEmpty { break }
        }
        state.withLock { box in
            box.recognitionTask?.cancel()
            box.recognitionTask = nil
            box.audioEngine = nil
            box.request = nil
        }

        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else {
            callbacks.onStatus?("did not catch that")
            await speaker.speak("I did not catch that. Say it once more?", tone: .calm)
            return
        }
        callbacks.onUserTranscript?(heard)
        callbacks.onStatus?("thinking…")

        try await think(about: heard, callbacks: callbacks)
    }

    public func stop() async {
        let engine = state.withLock { $0.audioEngine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        state.withLock { box in
            box.recognitionTask?.cancel()
            box.recognitionTask = nil
            box.audioEngine = nil
            box.request = nil
        }
    }

    // MARK: The thinking step

    private func think(about transcript: String, callbacks: VoiceSessionCallbacks) async throws {
        history.append(["role": "user", "content": transcript])

        let row = configuration.providerRow
        let base = configuration.resolvedProviderBaseURL
        guard let url = URL(string: "\(base.hasSuffix("/") ? String(base.dropLast()) : base)/chat/completions") else {
            throw VoiceError.transport("\(base) is not a usable base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The credential and how to present it both come from the contract row, so adding a
        // provider stays a row in the schema rather than a branch here.
        let credential = (row.requiresToken ? configuration.token : configuration.apiKey) ?? ""
        if let header = row.authorizationHeader(credential: credential) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        var messages: [[String: Any]] = [["role": "system", "content": RealtimeVoiceSession.instructions]]
        messages.append(contentsOf: history)

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": configuration.resolvedModel,
            "messages": messages,
            "tools": try VoiceToolCall.toolDefinitions().map { ["type": "function", "function": $0] },
            "tool_choice": "auto",
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "no response body"
            if configuration.resolvedProvider == .local {
                throw VoiceError.transport(
                    "the local model at \(base) did not answer. Is Ollama or LM Studio running? (\(detail))")
            }
            throw VoiceError.transport(detail)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw VoiceError.transport("could not read the model's answer")
        }
        history.append(message)

        // Tool calls first: doing the thing before narrating it is the order that reads as
        // competent, and a failed tool call changes what there is to say.
        var performedAnything = false
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                var arguments: [String: Any] = [:]
                if let argumentsText = function["arguments"] as? String,
                   let parsed = try? JSONSerialization.jsonObject(with: Data(argumentsText.utf8)) as? [String: Any] {
                    arguments = parsed
                }
                switch VoiceToolCall.parse(name: name, arguments: arguments) {
                case let .success(action):
                    callbacks.onAction?(action)
                    performedAnything = true
                case let .failure(failure):
                    callbacks.onStatus?("ignored a tool call: \(failure.description)")
                }
            }
        }

        if let content = (message["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            callbacks.onSaathiTranscript?(content)
            await speaker.speak(content, tone: .neutral)
        } else if !performedAnything {
            // Neither words nor an action. Saying nothing at all reads as a hang to someone who
            // cannot see a spinner.
            await speaker.speak("I am not sure what to do with that.", tone: .calm)
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
