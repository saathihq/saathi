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

public final class RealtimeVoiceSession: NSObject, VoiceSession, SharedMicrophone, @unchecked Sendable {

    public let lane: VoiceLane = .realtime
    public let speaksForItself = true

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
        private var _disconnectReason: String?
        private var _connectedAt: Date?
        private var _handsFree = false
        private var _sharer: (@Sendable (Data) -> Void)?
        private var _forwardingBeforeSharing = false
        private var _lastHeard: Date?
        private var _forwarding = false
        private var _responseInProgress = false
        private var _activeResponseId: String?
        private var _cancelledResponseIds: Set<String> = []
        private var _needsContinuation = false
        private var _pendingLooks = 0
        private var _playbackActive = false
        private var _assistantBuffer = ""
        private var _turnAudio = Data()
        private var _turnAudioBytes = 0

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
        var sharer: (@Sendable (Data) -> Void)? {
            get { withLock { $0._sharer } }
            set { withLock { $0._sharer = newValue } as Void }
        }
        var forwardingBeforeSharing: Bool {
            get { withLock { $0._forwardingBeforeSharing } }
            set { withLock { $0._forwardingBeforeSharing = newValue } as Void }
        }
        var handsFree: Bool {
            get { withLock { $0._handsFree } }
            set { withLock { $0._handsFree = newValue } as Void }
        }
        /// When this socket was opened, and when the server was last heard from on it.
        var connectedAt: Date? {
            get { withLock { $0._connectedAt } }
            set { withLock { $0._connectedAt = newValue } as Void }
        }
        var lastHeard: Date? {
            get { withLock { $0._lastHeard } }
            set { withLock { $0._lastHeard = newValue } as Void }
        }
        /// Why the socket went away, so a later press can say so rather than just "not connected".
        var disconnectReason: String? {
            get { withLock { $0._disconnectReason } }
            set { withLock { $0._disconnectReason = newValue } as Void }
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
        /// Screen looks that have been asked for and not yet answered: each one ends in a
        /// continuation, so the reply is not over while any is outstanding.
        func beginLook() { withLock { $0._pendingLooks += 1 } as Void }
        func endLook() { withLock { $0._pendingLooks = max(0, $0._pendingLooks - 1) } as Void }
        var playbackActive: Bool {
            get { withLock { $0._playbackActive } }
            set { withLock { $0._playbackActive = newValue } as Void }
        }
        /// More audio is still to come for this reply: a response is streaming, a continuation is
        /// armed, or a look is out. A drained playback queue in that state is an underrun or the
        /// gap before a continuation, not the end.
        var replyUnfinished: Bool {
            withLock { $0._responseInProgress || $0._needsContinuation || $0._pendingLooks > 0 }
        }
        func markCancelled(_ id: String) { withLock { _ = $0._cancelledResponseIds.insert(id) } }
        func wasCancelled(_ id: String) -> Bool { withLock { $0._cancelledResponseIds.contains(id) } }
        func countTurnAudio(_ bytes: Int) { withLock { $0._turnAudioBytes += bytes } as Void }
        func takeTurnAudioBytes() -> Int { withLock { let bytes = $0._turnAudioBytes; $0._turnAudioBytes = 0; return bytes } }
        func appendTurnAudio(_ data: Data) { withLock { $0._turnAudio.append(data) } as Void }
        func takeTurnAudio() -> Data { withLock { let d = $0._turnAudio; $0._turnAudio = Data(); return d } }
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
        let connection = try await openSocket()

        // Build the audio graph once here and release it right away in push-to-talk, so key-down is
        // a fast engine restart rather than a full CoreAudio setup.
        engine.setCallbacks(
            onMicrophoneFrame: { [weak self] data, _ in self?.forwardMicrophone(data) },
            // Playing a reply restarts the engine, microphone tap included; without this the
            // engine stayed up after the reply and the orange microphone light stayed on for as
            // long as Saathi ran. Pause it again once the reply has been played, unless a turn has
            // opened meanwhile — then the microphone is exactly what is wanted.
            onPlaybackActiveChanged: { [weak self] active in
                guard let self else { return }
                self.state.playbackActive = active
                self.releaseMicrophoneIfTheReplyIsOver()
            }
        )
        let audioDescription = try await engine.start()
        if mode == .pushToTalk { engine.pause() }

        try finishConnecting(connection)
        state.callbacks.onStatus?("connected to \(connection.host) (\(connection.model)) — \(audioDescription)")
    }

    /// Resolves where to connect and opens the socket. The session is configured, and counted as
    /// connected, only in `finishConnecting` — at launch the audio engine is built in between.
    private func openSocket() async throws -> Connection {
        // Where to connect and what to present depends on who holds the key, and the two cases go
        // to genuinely different hosts. Getting this wrong is not a small bug: pointing the socket
        // at Saathi's backend would mean every learner's audio crossing our infrastructure, which
        // is exactly what minting a short-lived secret exists to avoid.
        let connection = try await resolveConnection()

        var request = URLRequest(url: connection.url)
        request.setValue("Bearer \(connection.credential)", forHTTPHeaderField: "Authorization")
        // No `OpenAI-Beta: realtime=v1`. That header came across with the port from OpenClicky and
        // asks for the beta wire shape, which OpenAI has retired: the socket still opens — a clean
        // 101 — and the server then rejects the FIRST message with `beta_api_shape_disabled` and
        // closes with code 4000. `receiveLoop` sets `connected = false`, and the next press of the
        // keys says "not connected", which points at the network rather than at the header that
        // actually caused it. Sending no version header at all selects the GA shape, which is what
        // `sessionUpdate()` below already speaks.

        let socket = urlSession.webSocketTask(with: request)
        state.socket = socket
        socket.resume()
        return connection
    }

    private func finishConnecting(_ connection: Connection) throws {
        guard let socket = state.socket else { throw notConnected() }
        try send(sessionUpdate())
        state.disconnectReason = nil
        state.connectedAt = Date()
        state.lastHeard = Date()
        state.connected = true
        receiveLoop(socket)
    }

    /// OpenAI ends a realtime session after 60 minutes, and sleep or a network change kills the
    /// socket without a word. The connection used to be opened once at launch and never again, so
    /// the first press after any of that failed with "send failed" and kept failing until Saathi
    /// was restarted. Every press now makes sure there is a live socket first, and reconnects —
    /// quietly, in the key-down — when there is not.
    private func ensureConnected() async throws {
        let now = Date()
        if state.connected, !Self.isTooOld(connectedAt: state.connectedAt, now: now) {
            // Heard from recently: trust it. Quiet for a while: a sleep can leave a socket that
            // still looks open, so ask it before speaking into it.
            if !Self.needsPing(lastHeard: state.lastHeard, now: now) { return }
            if let socket = state.socket, await Self.ping(socket) {
                state.lastHeard = Date()
                return
            }
        }
        let old = state.socket
        state.connected = false
        state.socket = nil
        old?.cancel(with: .goingAway, reason: nil)
        state.callbacks.onStatus?("reconnecting…")
        let connection = try await openSocket()
        try finishConnecting(connection)
        state.callbacks.onStatus?("connected to \(connection.host) (\(connection.model))")
    }

    /// OpenAI refuses to commit less than 100 ms of audio; a turn shorter than that heard nothing.
    static func hasEnoughAudioForATurn(pcm16Bytes: Int) -> Bool {
        pcm16Bytes >= Int(VoiceAudioEngine.sampleRate * 0.1) * MemoryLayout<Int16>.size
    }

    /// Under OpenAI's 60-minute cap with room to finish a conversation.
    static let maximumSocketAge: TimeInterval = 50 * 60
    /// How long without a word from the server before a press checks the socket is still there.
    static let pingAfterSilence: TimeInterval = 60

    static func isTooOld(connectedAt: Date?, now: Date) -> Bool {
        guard let connectedAt else { return true }
        return now.timeIntervalSince(connectedAt) >= maximumSocketAge
    }

    static func needsPing(lastHeard: Date?, now: Date) -> Bool {
        guard let lastHeard else { return true }
        return now.timeIntervalSince(lastHeard) >= pingAfterSilence
    }

    /// A pong within two seconds, or the socket is treated as gone.
    private static func ping(_ socket: URLSessionWebSocketTask) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<Bool, Never>?
            init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
            func resume(_ value: Bool) {
                lock.lock(); let c = continuation; continuation = nil; lock.unlock()
                c?.resume(returning: value)
            }
        }
        return await withCheckedContinuation { continuation in
            let once = Once(continuation)
            socket.sendPing { error in once.resume(error == nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.resume(false) }
        }
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
            // The vendor field first, then the legacy shared one. A config holding both an OpenAI
            // and an Anthropic key must present the OpenAI one here, not whichever was written last.
            guard let key = configuration.credential(for: row.kind) else {
                throw VoiceError.notConfigured("\(row.kind.rawValue) mode needs an API key in ~/.saathi/shell.json")
            }
            // The VOICE model, never `resolvedModel`. A realtime socket opened with the thinking
            // model is refused by the provider, and the refusal arrives as an opaque socket close
            // that looks like a network problem — which is how this went unnoticed.
            let model = configuration.resolvedVoiceModel
            guard !model.isEmpty else {
                throw VoiceError.notConfigured(
                    "\(row.kind.rawValue) names no realtime voice model, so it has no socket to open")
            }
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
        // Hands-free is already listening, and the server decides where a turn ends.
        if state.handsFree { return }
        try await ensureConnected()
        // `forwarding` before the engine is asked for, not after: a reply that drains while
        // `start()` is in flight fires `onPlaybackActiveChanged(false)`, and with `forwarding`
        // still false that pauses the engine under the turn that is just opening.
        if Self.keepsLastTurn { _ = state.takeTurnAudio() }
        _ = state.takeTurnAudioBytes()
        state.forwarding = true
        do {
            let audio = try await engine.start()
            if Self.keepsLastTurn {
                let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".saathi/last-turn.txt")
                try? "\(Date()) \(audio)\n".write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            state.forwarding = false
            throw error
        }
        state.callbacks.onStatus?("listening…")
        engine.flushPlayback()
        if state.responseInProgress { cancelActiveResponse() }
    }

    public func endTurn() async throws {
        if state.handsFree { return }
        guard state.connected else { throw notConnected() }
        // A 400 ms tail: people release a push-to-talk key before they have finished the last
        // syllable, and without this the final word is clipped off every single turn.
        try? await Task.sleep(nanoseconds: 400_000_000)
        state.forwarding = false
        engine.pause()
        if Self.keepsLastTurn { Self.writeLastTurn(state.takeTurnAudio()) }
        // No audio, no turn. An empty commit is refused by OpenAI ("buffer only has 0.00ms of
        // audio") and the reply requested after it answers nothing the learner said — the sibling
        // app OpenClicky invented a task that way and handed it to its agent.
        let turnAudioBytes = state.takeTurnAudioBytes()
        guard Self.hasEnoughAudioForATurn(pcm16Bytes: turnAudioBytes) else {
            try? send(["type": "input_audio_buffer.clear"])
            state.callbacks.onStatus?("did not catch that — hold the keys while you talk")
            return
        }
        try send(["type": "input_audio_buffer.commit"])
        try send(["type": "response.create"])
        state.callbacks.onStatus?("thinking…")
    }

    public func startSharing(_ sink: @escaping @Sendable (Data) -> Void) async throws {
        // Hands-free is forwarding already; what is dictated is not said to Saathi.
        state.forwardingBeforeSharing = state.forwarding
        state.forwarding = false
        state.sharer = sink
        do {
            _ = try await engine.start()
        } catch {
            stopSharing()
            throw error
        }
    }

    public func stopSharing() {
        state.sharer = nil
        state.forwarding = state.forwardingBeforeSharing
        state.forwardingBeforeSharing = false
        releaseMicrophoneIfTheReplyIsOver()
    }

    public func sendText(_ text: String) async throws {
        try await ensureConnected()
        engine.flushPlayback()
        if state.responseInProgress { cancelActiveResponse() }
        try send([
            "type": "conversation.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]],
        ])
        try send(["type": "response.create"])
        state.callbacks.onUserTranscript?(text)
        state.callbacks.onStatus?("thinking…")
    }

    public func setHandsFree(_ on: Bool) async throws {
        try await ensureConnected()
        state.handsFree = on
        try send(Self.turnDetectionUpdate(serverDecides: on))
        if on {
            state.forwarding = true
            _ = try await engine.start()
            state.callbacks.onStatus?("listening, hands-free")
        } else {
            state.forwarding = false
            try? send(["type": "input_audio_buffer.clear"])
            releaseMicrophoneIfTheReplyIsOver()
            state.callbacks.onStatus?("hands-free off")
        }
    }

    /// Only the turn detection changes; everything else in the session stays as it was set.
    static func turnDetectionUpdate(serverDecides: Bool) -> [String: Any] {
        let detection: Any = serverDecides
            ? ["type": "server_vad", "create_response": true, "interrupt_response": true] as [String: Any]
            : NSNull()
        return [
            "type": "session.update",
            "session": ["type": "realtime", "audio": ["input": ["turn_detection": detection]]] as [String: Any],
        ]
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
            // The language is named so the transcript is not a guess either: unpinned, clean English
            // audio came back as "怎麼這樣?" and "どうぞ。", and the model read those as the learner
            // switching language.
            "transcription": ["model": "gpt-4o-mini-transcribe", "language": Self.transcriptionLanguage(configuration.resolvedLanguage)],
        ]
        switch state.handsFree ? .alwaysOn : mode {
        case .pushToTalk:
            // No server VAD: the shortcut delimits the turn, and letting the server also decide
            // means two things racing to end the same sentence.
            input["turn_detection"] = NSNull()
        case .alwaysOn:
            input["turn_detection"] = ["type": "server_vad", "create_response": true]
        }

        // Every tool but `say`. The model speaks in its own voice here; offered `say` as well, it
        // called it, the system voice read the line out over the model's audio, and two speakers
        // answered one question. `show_step` stays: the island shows the step, and the shell
        // knows not to narrate it on this lane.
        let tools = ((try? VoiceToolCall.toolDefinitions()) ?? [])
            .filter { ($0["name"] as? String) != SayAction.wireName }
        return [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": Self.instructions(for: configuration),
                "audio": [
                    "input": input,
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Int(VoiceAudioEngine.sampleRate)],
                        // Chosen rather than defaulted. A companion whose whole premise is sounding
                        // like a person should not inherit whatever the provider picks this month.
                        "voice": configuration.resolvedVoice,
                    ],
                ],
                "tools": tools,
                "tool_choice": "auto",
            ],
        ]
    }

    /// The session update as it would be sent. Exists so the voice and the audio format can be
    /// asserted on without opening a socket — the two things that make a session silent if wrong.
    func sessionUpdateForTesting() -> [String: Any] { sessionUpdate() }

    /// The prompt, with the language named rather than guessed.
    ///
    /// Any freedom to switch was used: with "you may answer in the learner's language", and then
    /// with "answer in the language they spoke", an English speaker was answered in Italian,
    /// Japanese and Portuguese — the audio was clean; the model followed its own earlier replies.
    /// So there is one language, the one in Settings, and nothing in the conversation moves it.
    ///
    /// The old text said "Speak the language the learner speaks" and left it there. With nothing to
    /// go on the model simply picks one — it answered a Delhi user in Korean — and being replied to
    /// in a language you cannot read is a worse failure than any wording. So the language is stated,
    /// and where the config does not name one it comes from the machine's own language rather than
    /// from the model's imagination.
    /// The prompt for a configuration: the language, and whatever first run learned about the
    /// learner. Both lanes use this, so they are told the same things about the same person.
    static func instructions(for configuration: SaathiConfiguration) -> String {
        let learner = LearnerProfile.paragraph(for: configuration)
        let prompt = instructions(language: configuration.resolvedLanguage)
        return learner.isEmpty ? prompt : prompt + "\n\n" + learner
    }

    /// ISO-639-1, which is all the transcription model takes: "en-US" is sent as "en".
    static func transcriptionLanguage(_ tag: String) -> String {
        String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en").lowercased()
    }

    static func instructions(language: String) -> String {
        let named = Locale.current.localizedString(forLanguageCode: language) ?? language
        return base + """

        Always speak and write in \(named) (\(language)). Every reply is in \(named): whatever \
        language the learner seems to use, whatever language the transcript shows, and whatever \
        language any earlier reply in this conversation was in. Only the learner changes this, in \
        Saathi's settings.

        If a turn is silent, is only noise, or is too short or unclear to make out, do not invent \
        what was said and do not act on it: say in \(named) that you did not catch that, and ask \
        them to say it again.
        """
    }

    static let base = """
    You are Saathi, a companion helping someone learn and play with something new. Keep spoken replies short — one or two sentences — and never read \
    a long list aloud. You are not doing the task for them; you are keeping them company while \
    they do it, so prefer a question or a nudge over an instruction. When you walk someone through \
    something, call show_step once per step, in order, and keep talking between the calls so the \
    silence never feels like a hang. Say what is happening before it happens. If you did not \
    understand, say so plainly and ask again rather than guessing — a wrong guess acted on is much \
    worse here than an honest "say that once more".

    You can look at the screen, and only by asking. Call look_at_screen whenever the learner asks \
    about something they can see — a folder, a window, an error, a button, "what is this" — and use \
    what comes back. Do not guess first and look afterwards; looking is quick and guessing about \
    someone's own screen is the worst thing you can do here, because they will believe you.

    Whenever the learner says "this", "that", "here", "it" or "the one" about something they might \
    be looking at — "how do I play this song", "what is this", "why is that red" — they are pointing \
    at their screen. Call look_at_screen first, every time, before answering. Do not ask what they \
    mean and do not answer from the words alone: asked "how do I play this song", you once asked \
    back which instrument they play, while the song sat under their pointer.

    You have no camera and no view of the room, and you cannot see the screen at any other moment: \
    one frame is captured when you call the tool and at no other time. If look_at_screen comes back \
    saying it could not look, tell the learner exactly why — a missing permission is something they \
    can fix, and a vague "I cannot see" is not. Never describe a screen, a photograph or a room as \
    though you could see it without having looked.
    """

    // MARK: Transport

    private func send(_ object: [String: Any]) throws {
        guard let socket = state.socket else { throw VoiceError.transport("not connected") }
        let data = try JSONSerialization.data(withJSONObject: object)
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            guard let self, let error else { return }
            // A failed send means the socket is gone. Marking it so makes the next press reconnect
            // instead of speaking into it again.
            if self.state.socket === socket {
                self.state.connected = false
                self.state.socket = nil
                self.state.forwarding = false
                self.state.disconnectReason = "the connection dropped (\(error.localizedDescription))"
            }
            self.state.callbacks.onStatus?("connection dropped — press again to reconnect")
        }
    }

    /// Whether the engine — and with it the microphone — should be paused now that playback has
    /// changed state. Only when it has just gone quiet, only in push-to-talk (always-on listens by
    /// definition), and only if no turn is open: `beginTurn` sets `forwarding` before it flushes
    /// playback, so a barge-in's "went quiet" arrives with `forwarding` already true.
    ///
    /// And only if the reply is actually over. The queue also runs dry when audio arrives slower
    /// than it plays, and between a tool call's response and its continuation; pausing there stops
    /// the engine mid-sentence and restarts it on the next delta, which is a gap the learner hears.
    static func releasesMicrophoneAfterPlayback(active: Bool, mode: TurnMode, forwarding: Bool, replyUnfinished: Bool) -> Bool {
        !active && mode == .pushToTalk && !forwarding && !replyUnfinished
    }

    /// Asked from both ends of a reply: when playback drains, and when the response finishes —
    /// whichever comes last is the one that finds everything quiet.
    private func releaseMicrophoneIfTheReplyIsOver() {
        guard state.sharer == nil, Self.releasesMicrophoneAfterPlayback(
            active: state.playbackActive, mode: state.handsFree ? .alwaysOn : mode,
            forwarding: state.forwarding, replyUnfinished: state.replyUnfinished) else { return }
        engine.pause()
    }

    private func forwardMicrophone(_ pcm16: Data) {
        state.sharer?(pcm16)
        guard state.forwarding, state.connected else { return }
        if Self.keepsLastTurn { state.appendTurnAudio(pcm16) }
        state.countTurnAudio(pcm16.count)
        try? send(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    /// `SAATHI_KEEP_LAST_TURN=1`: the exact audio sent for the last turn, as a WAV in
    /// `~/.saathi/last-turn.wav`, overwritten every turn and never sent anywhere. For the question
    /// "what did the model actually hear" — an English speaker transcribed as Chinese and answered
    /// in Japanese is either the prompt or the audio, and only listening tells which.
    static let keepsLastTurn = ProcessInfo.processInfo.environment["SAATHI_KEEP_LAST_TURN"] == "1"

    static func writeLastTurn(_ pcm16: Data) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".saathi/last-turn.wav")
        try? WaveFile.wrap(pcm16: pcm16, sampleRate: Int(VoiceAudioEngine.sampleRate)).write(to: url, options: .atomic)
    }

    private func notConnected() -> VoiceError {
        .transport("not connected" + (state.disconnectReason.map { " — \($0)" } ?? ""))
    }

    /// A refused handshake surfaces from URLSession as "bad server response", which reads as a
    /// network fault. The status says what actually happened: a 401 is a key the provider does
    /// not accept, and that is the one thing a person can fix from the Setup tab.
    static func disconnectReason(handshakeStatus: Int?, error: String, host: String?) -> String {
        let provider = host ?? "the provider"
        switch handshakeStatus {
        case 401: return "\(provider) rejected the API key — put a new one in Setup"
        case 403: return "\(provider) refused this key access to the realtime model"
        case 429: return "\(provider) says this key is over its limit or out of credit"
        case let status? where status >= 400: return "\(provider) refused the connection (\(status))"
        default: return error
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self, self.state.socket === socket else { return }
            switch result {
            case let .failure(error):
                let reason = Self.disconnectReason(
                    handshakeStatus: (socket.response as? HTTPURLResponse)?.statusCode,
                    error: error.localizedDescription,
                    host: socket.originalRequest?.url?.host)
                self.state.connected = false
                self.state.socket = nil
                self.state.forwarding = false
                self.state.disconnectReason = reason
                self.state.callbacks.onStatus?("disconnected: \(reason)")
            case let .success(message):
                self.state.lastHeard = Date()
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
            } else {
                // Playback usually outlasts the response and releases the microphone itself; after
                // an underrun it has already drained, and this is the only end the reply has left.
                releaseMicrophoneIfTheReplyIsOver()
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

        // Looking is the one tool whose *answer* is the point, and the answer takes a second or two
        // to fetch. Everything else is fire-and-forget with a "done", so it is handled inline; this
        // one goes away, captures the screen, asks a vision model, and posts the output when it has
        // something true to post.
        if name == LookAtScreenAction.wireName {
            let question = (arguments["question"] as? String) ?? "What is on the screen?"
            state.callbacks.onStatus?("looking at the screen…")
            state.beginLook()
            Task { [weak self] in
                guard let self else { return }
                defer { self.state.endLook() }
                let answer: String
                do {
                    answer = try await ScreenSight(configuration: self.configuration).look(question: question)
                } catch {
                    // The model is told what went wrong so it can say something true — "I need
                    // Screen Recording permission" is a useful sentence; silence is not.
                    answer = "could not look: \((error as? ScreenSightError)?.description ?? error.localizedDescription)"
                }
                self.state.callbacks.onScreenLook?(question, answer)
                try? self.send([
                    "type": "conversation.item.create",
                    "item": ["type": "function_call_output", "call_id": callId, "output": answer],
                ])
                // The response that asked for this has long since finished, so the continuation is
                // requested directly rather than armed for `response.done`.
                if !self.state.responseInProgress {
                    try? self.send(["type": "response.create"])
                } else {
                    self.state.needsContinuation = true
                }
            }
            return
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
