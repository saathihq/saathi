//
//  RealtimeVoiceSession.swift
//  SaathiKit
//
//  The fast lane: speech in and speech out over one OpenAI Realtime socket, no transcribe → think →
//  synthesize chain. Ported from OpenClicky's `RealtimeVoiceClient` (openclicky@21d41f9).
//
//  What came across: the connection and session setup, the push-to-talk tail, the server event
//  handling, barge-in, and the tool-call continuation rule that took a while to get right (a model
//  may emit several tool calls in one response; each output goes out immediately so the action
//  happens while Saathi is still talking, but the follow-up `response.create` is sent ONCE, on
//  `response.done` — a second one while a response is active is rejected by the server).
//
//  What did not: screenshots, cursor pointing, OCR, and handing work to an agent subprocess. Those
//  were OpenClicky's product, not this one.
//
//  What changed: the tool list is no longer hand-written. It is the generated contract bytes
//  (`SaathiTools.json`), so the Windows client shows a model the same tools without anyone
//  remembering to copy them.
//

import Foundation
import SaathiContract

public final class RealtimeVoiceSession: NSObject, VoiceSession, @unchecked Sendable {

    public let lane: VoiceLane = .realtime

    /// How a turn is delimited. Push-to-talk is the default because it is the one that works in a
    /// room with other people in it.
    public enum TurnMode: Sendable {
        case pushToTalk
        case alwaysOn
    }

    private let configuration: SaathiConfiguration
    private let engine: VoiceAudioEngine
    private let mode: TurnMode
    private let urlSession: URLSession

    private let state = SessionState()

    /// Mutable session state, all of it behind one lock. Not an actor: the websocket completion
    /// handlers, the audio thread and the caller all touch this, none of them is the main thread, and
    /// an `await` on every read would put suspension points inside the event loop.
    private final class SessionState: @unchecked Sendable {
        private let lock = NSLock()
        private var _callbacks = VoiceSessionCallbacks()
        private var _socket: URLSessionWebSocketTask?
        private var _connected = false
        private var _forwarding = false
        private var _responseInProgress = false
        private var _activeResponseId: String?
        private var _cancelledResponseIds: Set<String> = []
        private var _needsContinuation = false
        private var _assistantBuffer = ""

        func withLock<T>(_ body: (SessionState) -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body(self)
        }

        var callbacks: VoiceSessionCallbacks {
            get { withLock { $0._callbacks } }
            set { withLock { $0._callbacks = newValue } as Void }
        }
        var socket: URLSessionWebSocketTask? {
            get { withLock { $0._socket } }
            set { withLock { $0._socket = newValue } as Void }
        }
        var connected: Bool {
            get { withLock { $0._connected } }
            set { withLock { $0._connected = newValue } as Void }
        }
        var forwarding: Bool {
            get { withLock { $0._forwarding } }
            set { withLock { $0._forwarding = newValue } as Void }
        }
        var responseInProgress: Bool {
            get { withLock { $0._responseInProgress } }
            set { withLock { $0._responseInProgress = newValue } as Void }
        }
        var activeResponseId: String? {
            get { withLock { $0._activeResponseId } }
            set { withLock { $0._activeResponseId = newValue } as Void }
        }
        var needsContinuation: Bool {
            get { withLock { $0._needsContinuation } }
            set { withLock { $0._needsContinuation = newValue } as Void }
        }
        func markCancelled(_ id: String) { withLock { _ = $0._cancelledResponseIds.insert(id) } }
        func wasCancelled(_ id: String) -> Bool { withLock { $0._cancelledResponseIds.contains(id) } }
        func appendAssistant(_ text: String) { withLock { $0._assistantBuffer += text } as Void }
        func takeAssistantBuffer() -> String {
            withLock { box in
                let value = box._assistantBuffer
                box._assistantBuffer = ""
                return value
            }
        }
    }

    public init(
        configuration: SaathiConfiguration,
        engine: VoiceAudioEngine = VoiceAudioEngine(),
        mode: TurnMode = .pushToTalk,
        urlSession: URLSession = URLSession(configuration: .default)
    ) {
        self.configuration = configuration
        self.engine = engine
        self.mode = mode
        self.urlSession = urlSession
        super.init()
    }

    /// Builds the realtime websocket URL for a model name.
    ///
    /// `model` can arrive verbatim from a backend's JSON response, so a malformed or hostile value
    /// (a stray space, an unescaped character) must not force-unwrap into a crash. Pure and static
    /// so it can be tested without opening a connection — which is the only reason the predecessor
    /// ever found out that it could not.
    public static func socketURL(baseURL: String, model: String) -> URL? {
        let host = baseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        let trimmed = host.hasSuffix("/") ? String(host.dropLast()) : host
        guard let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return URL(string: "\(trimmed)/realtime?model=\(escaped)")
    }

    // MARK: Lifecycle

    public func start(callbacks: VoiceSessionCallbacks) async throws {
        state.callbacks = callbacks

        // Where to connect and what to present depends on who holds the key, and the two cases go
        // to genuinely different hosts. Getting this wrong is not a small bug: pointing the socket
        // at Saathi's backend would mean every learner's audio crossing our infrastructure, which
        // is exactly what minting a short-lived secret exists to avoid.
        let connection = try await resolveConnection()

        var request = URLRequest(url: connection.url)
        request.setValue("Bearer \(connection.credential)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        let socket = urlSession.webSocketTask(with: request)
        state.socket = socket
        socket.resume()

        // Build the audio graph once here and release it right away in push-to-talk, so key-down is
        // a fast engine restart rather than a full CoreAudio setup.
        engine.setCallbacks(
            onMicrophoneFrame: { [weak self] data, _ in self?.forwardMicrophone(data) },
            onPlaybackActiveChanged: { _ in }
        )
        let audioDescription = try await engine.start()
        if mode == .pushToTalk { engine.pause() }

        try send(sessionUpdate())
        state.connected = true
        state.callbacks.onStatus?("connected to \(connection.host) (\(connection.model)) — \(audioDescription)")
        receiveLoop(socket)
    }

    struct Connection {
        let url: URL
        let credential: String
        let model: String
        /// For the status line, so a person can see where their audio actually went.
        let host: String
    }

    /// Two paths, and the difference is who holds the provider key.
    ///
    /// **Own key (`openai`).** The key is already on this machine; routing the audio through
    /// someone else's server to use it would be strictly worse for the user. Connect directly.
    ///
    /// **Hosted.** The key lives in Saathi's backend and must never reach this process. The backend
    /// mints a client secret that expires in about a minute, and this connects to the PROVIDER with
    /// it. Saathi's servers are out of the conversation from that point on — they never carry a
    /// frame of audio. `VoiceLaneReport` says "leaves this machine as audio" either way, because it
    /// does; what it does not do is leave via us.
    func resolveConnection() async throws -> Connection {
        let row = configuration.providerRow

        if !row.requiresToken {
            guard let key = configuration.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty else {
                throw VoiceError.notConfigured("\(row.kind.rawValue) mode needs an API key in ~/.saathi/shell.json")
            }
            let model = configuration.resolvedModel.isEmpty ? "gpt-realtime" : configuration.resolvedModel
            guard let url = Self.socketURL(baseURL: configuration.resolvedProviderBaseURL, model: model) else {
                throw VoiceError.transport("cannot build a realtime URL for model \"\(model)\"")
            }
            return Connection(url: url, credential: key, model: model, host: url.host ?? "the provider")
        }

        guard let token = configuration.token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw VoiceError.notConfigured("hosted mode needs an account token in ~/.saathi/shell.json")
        }

        let backend = configuration.resolvedBaseURL
        guard let grantURL = URL(string: "\(backend.hasSuffix("/") ? String(backend.dropLast()) : backend)/realtime/session") else {
            throw VoiceError.transport("\(backend) is not a usable backend URL")
        }
        var grantRequest = URLRequest(url: grantURL)
        grantRequest.httpMethod = "POST"
        grantRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        grantRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await urlSession.data(for: grantRequest)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceError.transport("no answer from \(backend)")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200...299).contains(http.statusCode) else {
            // The backend's own wording is the useful one here — it distinguishes "this deployment
            // offers no hosted voice" from "you are over your limit", and a person can act on both.
            let message = (body?["error"] as? String) ?? "the backend refused (\(http.statusCode))"
            throw VoiceError.transport(message)
        }
        guard let grant = body,
              let secret = grant["value"] as? String, !secret.isEmpty,
              let urlString = grant["url"] as? String else {
            throw VoiceError.transport("the backend returned no realtime credential")
        }
        // `url` arrives verbatim from a response, so it is parsed rather than trusted, and it must
        // be a websocket URL — a backend answering with an https URL would mean connecting to
        // something that is not a realtime socket at all.
        guard let url = URL(string: urlString), url.scheme == "wss" || url.scheme == "ws" else {
            throw VoiceError.transport("the backend returned \"\(urlString)\", which is not a websocket URL")
        }
        let model = (grant["model"] as? String) ?? configuration.resolvedModel
        return Connection(url: url, credential: secret, model: model, host: url.host ?? "the provider")
    }

    public func beginTurn() async throws {
        guard state.connected else { throw VoiceError.transport("not connected") }
        _ = try await engine.start()
        state.forwarding = true
        state.callbacks.onStatus?("listening…")
        engine.flushPlayback()
        if state.responseInProgress { cancelActiveResponse() }
    }

    public func endTurn() async throws {
        guard state.connected else { throw VoiceError.transport("not connected") }
        // A 400 ms tail: people release a push-to-talk key before they have finished the last
        // syllable, and without this the final word is clipped off every single turn.
        try? await Task.sleep(nanoseconds: 400_000_000)
        state.forwarding = false
        engine.pause()
        try send(["type": "input_audio_buffer.commit"])
        try send(["type": "response.create"])
        state.callbacks.onStatus?("thinking…")
    }

    public func stop() async {
        state.connected = false
        state.forwarding = false
        state.socket?.cancel(with: .goingAway, reason: nil)
        state.socket = nil
        await engine.releaseNow()
    }

    // MARK: Session configuration

    private func sessionUpdate() -> [String: Any] {
        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": Int(VoiceAudioEngine.sampleRate)],
            "transcription": ["model": "gpt-4o-mini-transcribe"],
        ]
        switch mode {
        case .pushToTalk:
            // No server VAD: the shortcut delimits the turn, and letting the server also decide
            // means two things racing to end the same sentence.
            input["turn_detection"] = NSNull()
        case .alwaysOn:
            input["turn_detection"] = ["type": "server_vad", "create_response": true]
        }

        let tools = (try? VoiceToolCall.toolDefinitions()) ?? []
        return [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": Self.instructions,
                "audio": [
                    "input": input,
                    "output": ["format": ["type": "audio/pcm", "rate": Int(VoiceAudioEngine.sampleRate)]],
                ],
                "tools": tools,
                "tool_choice": "auto",
            ],
        ]
    }

    static let instructions = """
    You are Saathi, a companion helping someone learn and play with something new. Speak the \
    language the learner speaks. Keep spoken replies short — one or two sentences — and never read \
    a long list aloud. You are not doing the task for them; you are keeping them company while \
    they do it, so prefer a question or a nudge over an instruction. When you walk someone through \
    something, call show_step once per step, in order, and keep talking between the calls so the \
    silence never feels like a hang. Say what is happening before it happens. If you did not \
    understand, say so plainly and ask again rather than guessing — a wrong guess acted on is much \
    worse here than an honest "say that once more".
    """

    // MARK: Transport

    private func send(_ object: [String: Any]) throws {
        guard let socket = state.socket else { throw VoiceError.transport("not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.state.callbacks.onStatus?("send failed: \(error.localizedDescription)") }
        }
    }

    private func forwardMicrophone(_ pcm16: Data) {
        guard state.forwarding, state.connected else { return }
        try? send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self, self.state.socket === socket else { return }
            switch result {
            case let .failure(error):
                self.state.connected = false
                self.state.socket = nil
                self.state.forwarding = false
                self.state.callbacks.onStatus?("disconnected: \(error.localizedDescription)")
            case let .success(message):
                if case let .string(text) = message { self.handleServerEvent(text) }
                self.receiveLoop(socket)
            }
        }
    }

    private func handleServerEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }

        switch type {
        case "input_audio_buffer.speech_started":
            // Barge-in. The learner started talking, so Saathi stops — immediately, and without
            // waiting for the server to agree.
            engine.flushPlayback()
            if state.responseInProgress { cancelActiveResponse() }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = (event["transcript"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !transcript.isEmpty {
                state.callbacks.onUserTranscript?(transcript)
            }

        case "response.created":
            state.responseInProgress = true
            state.activeResponseId = (event["response"] as? [String: Any])?["id"] as? String
            _ = state.takeAssistantBuffer()

        case "response.output_audio.delta", "response.audio.delta":
            if let delta = event["delta"] as? String, let audio = Data(base64Encoded: delta) {
                engine.enqueue(pcm16: audio)
            }

        case "response.output_audio_transcript.delta", "response.audio_transcript.delta":
            state.appendAssistant(event["delta"] as? String ?? "")

        case "response.output_audio_transcript.done", "response.audio_transcript.done":
            let buffered = state.takeAssistantBuffer()
            let transcript = ((event["transcript"] as? String) ?? buffered)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty { state.callbacks.onSaathiTranscript?(transcript) }

        case "response.function_call_arguments.done":
            handleToolCall(event)

        case "response.done":
            state.responseInProgress = false
            let responseId = state.activeResponseId
            state.activeResponseId = nil
            let status = (event["response"] as? [String: Any])?["status"] as? String
            let wantsContinuation = state.needsContinuation
            state.needsContinuation = false
            // A cancelled response's late tool calls still get an output item, but must never arm a
            // continuation — asking for one would restart a turn the learner just interrupted.
            let cancelled = status == "cancelled" || (responseId.map { state.wasCancelled($0) } ?? false)
            if wantsContinuation, !cancelled {
                try? send(["type": "response.create"])
            }

        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? text
            state.callbacks.onStatus?("realtime error: \(message)")

        default:
            break
        }
    }

    private func handleToolCall(_ event: [String: Any]) {
        let callId = event["call_id"] as? String ?? ""
        let name = event["name"] as? String ?? ""
        var arguments: [String: Any] = [:]
        if let argumentsText = event["arguments"] as? String,
           let parsed = try? JSONSerialization.jsonObject(with: Data(argumentsText.utf8)) as? [String: Any] {
            arguments = parsed
        }

        let outputText: String
        switch VoiceToolCall.parse(name: name, arguments: arguments) {
        case let .success(action):
            state.callbacks.onAction?(action)
            outputText = "done"
        case let .failure(failure):
            // Hand the reason back to the model rather than dropping it. It can then say something
            // true to the learner instead of narrating an action that never happened.
            outputText = "not done — \(failure.description)"
        }

        // Sent immediately so the action lands while Saathi is still speaking; the continuation is
        // armed for `response.done` rather than requested now, because a second `response.create`
        // during an active response is rejected.
        try? send([
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callId, "output": outputText],
        ])
        state.needsContinuation = true
    }

    private func cancelActiveResponse() {
        if let id = state.activeResponseId { state.markCancelled(id) }
        try? send(["type": "response.cancel"])
        state.responseInProgress = false
    }
}
