//
//  ChainLaneTests.swift
//  SaathiKitTests
//
//  The chain lane, run: a turn heard by whatever ears it was handed, the request a model is
//  actually sent, and what is made of every kind of answer — words, a tool call, a look at the
//  screen, a refusal, and an answer the learner has already talked over.
//
//  None of this could be tested while the session did its own listening: building one opened the
//  recogniser. It is handed its ears now, so a test hands it a pair that hears what the test says.
//

import Foundation
import os
import XCTest
@testable import SaathiContract
@testable import SaathiKit

/// Ears that hear what a test says they heard.
final class FakeEars: Ears, @unchecked Sendable {
    let calls = Collected<String>()
    private let heard: Result<String, any Error>

    init(hearing heard: String = "") { self.heard = .success(heard) }
    init(failing error: any Error) { self.heard = .failure(error) }

    func prepare() async throws -> String {
        calls.add("prepare")
        return "ready — a test's ears"
    }

    func begin(_ feedback: EarsFeedback) async throws {
        calls.add("begin")
        feedback.onLevel?(0.5)
        feedback.onPartial?("hel")
    }

    func finish() async throws -> String {
        calls.add("finish")
        return try heard.get()
    }

    func cancel() { calls.add("cancel") }
}

/// Ears that are still working out what was said — a request to Saaras that has not come back —
/// until whoever is waiting on them is cancelled.
final class SlowEars: Ears, @unchecked Sendable {
    let calls = Collected<String>()

    func prepare() async throws -> String { "ready — slow ears" }
    func begin(_ feedback: EarsFeedback) async throws { calls.add("begin") }

    func finish() async throws -> String {
        calls.add("finish")
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return "far too late"
    }

    func cancel() { calls.add("cancel") }
}

/// A speaker that writes what it said, and that it was stopped, into a log shared with whatever
/// else a test wants to see the order of.
final class LoggingSpeaker: Speaker, StoppableSpeaker, @unchecked Sendable {
    let log: Collected<String>

    init(log: Collected<String> = Collected()) { self.log = log }

    func speak(_ text: String, tone: Tone) async { log.add("say: \(text)") }
    func stop() { log.add("stop") }

    var said: [String] { log.all.filter { $0.hasPrefix("say: ") }.map { String($0.dropFirst(5)) } }
}

final class ChainLaneTests: XCTestCase {

    private let sarvam = SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-sarvam")

    /// Everything a session reported, by kind.
    private final class Heard: @unchecked Sendable {
        let user = Collected<String>()
        let saathi = Collected<String>()
        let actions = Collected<SaathiAction>()
        let statuses = Collected<String>()
        let looks = Collected<String>()
        let points = Collected<ScreenTarget>()
        let levels = Collected<Float>()
        let partials = Collected<String>()

        var callbacks: VoiceSessionCallbacks {
            VoiceSessionCallbacks(
                onUserTranscript: { self.user.add($0) },
                onSaathiTranscript: { self.saathi.add($0) },
                onAction: { self.actions.add($0) },
                onStatus: { self.statuses.add($0) },
                onScreenLook: { question, answer in self.looks.add("\(question) → \(answer)") },
                onPointAt: { self.points.add($0) },
                onInputLevel: { self.levels.add($0) },
                onPartialTranscript: { self.partials.add($0) })
        }
    }

    private func makeSession(
        _ replies: [StubHTTP.Reply],
        configuration: SaathiConfiguration? = nil,
        speaker: any Speaker = LoggingSpeaker(),
        ears: any Ears = FakeEars(),
        thinks: Bool = true,
        look: @escaping @Sendable (String) async -> ScreenLook = { _ in ScreenLook(answer: "nothing much") }
    ) -> ChainVoiceSession {
        ChainVoiceSession(
            configuration: configuration ?? sarvam, speaker: speaker, ears: ears,
            urlSession: StubHTTP.session(replies), thinks: thinks, look: look)
    }

    private func says(_ content: String) -> StubHTTP.Reply {
        .json(["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func calls(
        _ name: String, _ arguments: String, id: String = "call_1", saying content: String? = nil
    ) -> StubHTTP.Reply {
        let call: [String: Any] = [
            "id": id, "type": "function", "function": ["name": name, "arguments": arguments],
        ]
        var message: [String: Any] = ["role": "assistant", "tool_calls": [call]]
        if let content { message["content"] = content } else { message["content"] = NSNull() }
        return .json(["choices": [["message": message]]])
    }

    /// The messages of the nth request, system prompt first.
    private func messages(of request: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let seen = StubHTTP.seen
        guard request < seen.count else {
            XCTFail("only \(seen.count) request(s) were made", file: file, line: line)
            return []
        }
        return try XCTUnwrap(seen[request].json["messages"] as? [[String: Any]], file: file, line: line)
    }

    private func roles(_ messages: [[String: Any]]) -> [String] {
        messages.map { $0["role"] as? String ?? "?" }
    }

    // MARK: the ears it is handed

    func testATurnIsHeardByWhateverEarsItWasHandedAndThenThoughtAbout() async throws {
        let ears = FakeEars(hearing: "  what is a raga  ")
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says("A melodic frame.")], speaker: speaker, ears: ears)

        try await session.start(callbacks: heard.callbacks)
        try await session.beginTurn()
        try await session.endTurn()

        XCTAssertEqual(ears.calls.all, ["prepare", "begin", "finish"])
        XCTAssertEqual(heard.user.all, ["what is a raga"], "trimmed")
        XCTAssertEqual(speaker.said, ["A melodic frame."])
        XCTAssertEqual(heard.statuses.all, ["ready — a test's ears", "listening…", "thinking…"])
        XCTAssertEqual(heard.levels.all, [0.5], "the ears' level reaches whoever draws the bars")
        XCTAssertEqual(heard.partials.all, ["hel"])
        let sent = try messages(of: 0)
        XCTAssertEqual(sent.last?["content"] as? String, "what is a raga")
    }

    func testNothingHeardIsSaidSoAndNothingIsSent() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says("should never be asked")], speaker: speaker, ears: FakeEars(hearing: "   "))

        try await session.start(callbacks: heard.callbacks)
        try await session.beginTurn()
        try await session.endTurn()

        XCTAssertEqual(speaker.said, ["I did not catch that. Say it once more?"])
        XCTAssertTrue(heard.statuses.all.contains("did not catch that"))
        XCTAssertTrue(heard.user.all.isEmpty)
        XCTAssertTrue(StubHTTP.seen.isEmpty, "silence is not a question")
    }

    /// First run listens before any model has been chosen: a turn ends with the transcript.
    func testASessionThatOnlyListensSendsNothingAnywhere() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says("should never be asked")], speaker: speaker, ears: FakeEars(hearing: "Asha"), thinks: false)

        try await session.start(callbacks: heard.callbacks)
        try await session.beginTurn()
        try await session.endTurn()
        try await session.sendText("typed instead")

        XCTAssertEqual(heard.user.all, ["Asha", "typed instead"])
        XCTAssertTrue(heard.statuses.all.contains("heard"))
        XCTAssertTrue(speaker.said.isEmpty)
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    func testEarsThatCannotHearFailTheTurnWithTheirOwnReason() async throws {
        let session = makeSession([says("x")], ears: FakeEars(failing: SarvamError.outOfCredits))
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.beginTurn()
        do {
            try await session.endTurn()
            XCTFail("the ears refused")
        } catch {
            XCTAssertEqual(error as? SarvamError, .outOfCredits)
        }
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    func testStoppingTheSessionLetsGoOfTheMicrophone() async {
        let ears = FakeEars()
        let session = makeSession([], ears: ears)
        await session.stop()
        XCTAssertEqual(ears.calls.all, ["cancel"])
    }

    // MARK: what a model is sent

    private func requestBody(_ configuration: SaathiConfiguration, history: [[String: Any]] = []) throws -> (URLRequest, [String: Any]) {
        let request = try ChainVoiceSession.completionRequest(configuration: configuration, history: history)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return (request, body)
    }

    /// The generated list is in the realtime socket's shape, with `type` beside the name. Nested as
    /// it stood, every server was handed a `function` with a `type` inside it.
    func testTheToolsGoOutInTheChatCompletionsEnvelope() throws {
        let (_, body) = try requestBody(sarvam)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, SaathiAction.allWireNames.count)
        for tool in tools {
            XCTAssertEqual(Set(tool.keys), ["type", "function"])
            XCTAssertEqual(tool["type"] as? String, "function")
            let function = try XCTUnwrap(tool["function"] as? [String: Any])
            XCTAssertEqual(Set(function.keys), ["name", "description", "parameters"], "no `type` inside the function")
        }
        XCTAssertEqual(
            tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String },
            SaathiAction.allWireNames)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
    }

    /// Sarvam-105B reasons before it answers unless told not to, and bills the reasoning.
    func testSarvamIsAskedNotToThinkAloudAndNobodyElseIsToldAnything() throws {
        let (_, asked) = try requestBody(sarvam)
        XCTAssertTrue(asked.keys.contains("reasoning_effort"))
        XCTAssertTrue(asked["reasoning_effort"] is NSNull, "null is how Sarvam is told not to")

        for other in [SaathiConfiguration(), SaathiConfiguration(provider: .anthropic, anthropicKey: "k")] {
            let (_, body) = try requestBody(other)
            XCTAssertFalse(body.keys.contains("reasoning_effort"), "\(other.resolvedProvider)")
        }
    }

    func testTheRequestGoesToTheProviderWithItsOwnKeyItsOwnModelAndThePromptFirst() throws {
        let (request, asked) = try requestBody(sarvam, history: [["role": "user", "content": "namaste"]])
        XCTAssertEqual(request.url?.absoluteString, "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-sarvam")
        XCTAssertEqual(asked["model"] as? String, "sarvam-105b")
        let messages = try XCTUnwrap(asked["messages"] as? [[String: Any]])
        XCTAssertEqual(roles(messages), ["system", "user"])
        XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("You are Saathi"))

        let (local, _) = try requestBody(SaathiConfiguration())
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"), "a local model is asked with no key at all")
    }

    /// The default mode's own server. Ollama serves chat completions under `/v1` and nowhere else,
    /// and the local row's base has no path: posted to as it stood, the lane that needs no key got
    /// a 404 from the one server it was written for.
    func testABaseWithNoPathIsAskedUnderV1AndOneThatNamesAPathIsTakenAtItsWord() {
        func url(_ base: String) -> String? { ChainVoiceSession.chatCompletionsURL(base: base)?.absoluteString }
        XCTAssertEqual(url("http://localhost:11434"), "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(url("http://localhost:11434/"), "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(url("http://192.168.1.9:11434"), "http://192.168.1.9:11434/v1/chat/completions")
        XCTAssertEqual(url("https://api.anthropic.com"), "https://api.anthropic.com/v1/chat/completions")
        XCTAssertEqual(url("https://api.sarvam.ai/v1"), "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("http://box.local:8080/proxy/llm"), "http://box.local:8080/proxy/llm/chat/completions")
        XCTAssertNil(url("not a url"))
        XCTAssertNil(url(""))

        XCTAssertEqual(
            try? ChainVoiceSession.completionRequest(configuration: SaathiConfiguration(), history: []).url?.absoluteString,
            "http://localhost:11434/v1/chat/completions")
    }

    // MARK: what is made of an answer

    func testAReplyIsSpokenShownAndRemembered() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says(" Namaste. "), says("Again.")], speaker: speaker)
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("hello")
        try await session.sendText("and again")

        XCTAssertEqual(speaker.said, ["Namaste.", "Again."])
        XCTAssertEqual(heard.saathi.all, ["Namaste.", "Again."])
        XCTAssertEqual(heard.user.all, ["hello", "and again"])
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "user"], "the chain lane keeps its own history")
        XCTAssertEqual(second[2]["content"] as? String, " Namaste. ")
    }

    /// Asked "what is this?", the model called `look_at_screen`, the lane did not know the tool,
    /// and Saathi said it was not sure what to do with that.
    func testALookIsAnsweredAndTheModelSaysWhatItSaw() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let asked = Collected<String>()
        let session = makeSession(
            [calls("look_at_screen", #"{"question":"what is this?"}"#), says("It is the Saathi folder.")],
            speaker: speaker,
            look: { question in
                asked.add(question)
                return ScreenLook(answer: "a folder called Saathi")
            })
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("what is this?")

        XCTAssertEqual(asked.all, ["what is this?"])
        XCTAssertEqual(heard.looks.all, ["what is this? → a folder called Saathi"], "kept in the conversation log")
        XCTAssertTrue(heard.statuses.all.contains("looking at the screen…"))
        XCTAssertEqual(speaker.said, ["It is the Saathi folder."])
        XCTAssertEqual(StubHTTP.seen.count, 2)
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(second[3]["content"] as? String, "a folder called Saathi")
    }

    /// A look that is about somewhere on the screen says where, and the buddy is told before the
    /// model says what it saw: the words and the pointer arrive together.
    func testWhereALookPointsReachesWhoeverMovesTheBuddy() async throws {
        let heard = Heard()
        let target = ScreenTarget(point: CGPoint(x: 118, y: 42), visibleText: nil, how: "the eye alone")
        let session = makeSession(
            [calls("look_at_screen", #"{"question":"which button"}"#), says("The green one.")],
            look: { _ in ScreenLook(answer: "The green button at the top left.", target: target) })
        try await session.start(callbacks: heard.callbacks)
        try await session.sendText("which button makes this full screen")
        XCTAssertEqual(heard.points.all, [target])
        XCTAssertEqual(heard.looks.all, ["which button → The green button at the top left."], "the tag never reaches the model")
        let second = try messages(of: 1)
        XCTAssertEqual(second[3]["content"] as? String, "The green button at the top left.")
    }

    /// "Let me see" belongs in front of the pause, not after it.
    func testWordsThatComeWithALookAreSaidBeforeIt() async throws {
        let log = Collected<String>()
        let session = makeSession(
            [calls("look_at_screen", #"{"question":"this"}"#, saying: "Let me look."), says("A folder.")],
            speaker: LoggingSpeaker(log: log),
            look: { _ in
                log.add("look")
                return ScreenLook(answer: "a folder")
            })
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("what is this")
        XCTAssertEqual(log.all, ["stop", "say: Let me look.", "look", "say: A folder."])
    }

    /// A reply with a tool call in it must be followed by an answer to that call, or the next
    /// request is a conversation no OpenAI-compatible server is obliged to accept.
    func testEveryToolCallIsAnsweredSoTheNextTurnIsAConversationAServerWillTake() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession(
            [calls("say", #"{"text":"hello there","tone":"calm"}"#), says("You are welcome.")], speaker: speaker)
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("greet me")
        XCTAssertEqual(heard.actions.all, [.say(SayAction(text: "hello there", tone: .calm))])
        XCTAssertEqual(StubHTTP.seen.count, 1, "a say is done, not discussed: nothing more is asked about it")
        XCTAssertTrue(speaker.said.isEmpty, "the performer says a `say`; the session has nothing to add")

        try await session.sendText("thanks")
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "tool", "user"])
        XCTAssertTrue(second[2]["content"] is NSNull, "a reply that is only a tool call has no words")
        XCTAssertNotNil(second[2]["tool_calls"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(second[3]["content"] as? String, "done")
    }

    /// Handed back rather than dropped, so the model can say something true instead of narrating
    /// an action that never happened.
    func testAToolSaathiDoesNotHaveIsToldSoAndTheModelGetsToAnswer() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([calls("delete_everything", "{}"), says("I cannot do that.")], speaker: speaker)
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("delete everything")

        XCTAssertTrue(heard.actions.all.isEmpty)
        XCTAssertTrue(heard.statuses.all.contains("ignored a tool call: delete_everything is not an action Saathi has"))
        XCTAssertEqual(speaker.said, ["I cannot do that."])
        let second = try messages(of: 1)
        XCTAssertEqual(second.last?["content"] as? String, "not done — delete_everything is not an action Saathi has")
    }

    /// A call that cannot even be read still has an id, and the id still has to be answered.
    func testAMalformedToolCallIsAnsweredTooRatherThanLeftAsAHole() async throws {
        let broken = StubHTTP.Reply.json(["choices": [["message": [
            "role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_9", "type": "function"]],
        ]]]])
        let session = makeSession([broken, says("Sorry.")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("do something")
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call_9")
    }

    /// Ollama sends a call's arguments as an object; everyone else as a string of JSON.
    func testArgumentsAreReadAsAStringOfJSONOrAsAnObject() {
        let asString = ChainVoiceSession.toolCalls(in: ["tool_calls": [[
            "id": "a", "function": ["name": "open_url", "arguments": #"{"url":"https://saathi.dev"}"#],
        ]]])
        let asObject = ChainVoiceSession.toolCalls(in: ["tool_calls": [[
            "function": ["name": "open_url", "arguments": ["url": "https://saathi.dev"]],
        ]]])
        XCTAssertEqual(asString.first?.arguments["url"] as? String, "https://saathi.dev")
        XCTAssertEqual(asObject.first?.arguments["url"] as? String, "https://saathi.dev")
        XCTAssertEqual(asObject.first?.id, "", "an id a server left out is an empty one, not a crash")
        XCTAssertTrue(ChainVoiceSession.toolCalls(in: ["content": "just words"]).isEmpty)
    }

    /// A model that keeps asking to look is stopped, rather than left to spend the learner's
    /// patience and their credit.
    func testAModelIsNotAskedForEver() async throws {
        let speaker = LoggingSpeaker()
        let session = makeSession([calls("look_at_screen", #"{"question":"again"}"#)], speaker: speaker)
        try await session.start(callbacks: VoiceSessionCallbacks())

        try await session.sendText("look")

        XCTAssertEqual(StubHTTP.seen.count, ChainVoiceSession.mostRequestsPerTurn)
        XCTAssertEqual(speaker.said, ["I am not sure what to do with that."])
        let third = roles(try messages(of: 2))
        XCTAssertEqual(third, ["system", "user", "assistant", "tool", "assistant", "tool"], "and what it did ask is still a whole conversation")
    }

    func testAnAnswerWithNeitherWordsNorAnActionIsNotLeftAsSilence() async throws {
        let speaker = LoggingSpeaker()
        let session = makeSession([says("   ")], speaker: speaker)
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("hmm")
        XCTAssertEqual(speaker.said, ["I am not sure what to do with that."])
    }

    /// Sarvam's thinking arrives beside its answer. Sent back, it would be billed a second time.
    func testThinkingAndWhateverElseAServerAddsIsNotSentBack() async throws {
        let thoughtful = StubHTTP.Reply.json(["choices": [["message": [
            "role": "assistant", "content": "Hi.", "reasoning_content": "The user greeted me…", "refusal": NSNull(),
        ]]]])
        let session = makeSession([thoughtful, says("Yes.")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("hello")
        try await session.sendText("still there?")
        let kept = try messages(of: 1)[2]
        XCTAssertEqual(Set(kept.keys), ["role", "content"])
        XCTAssertEqual(kept["content"] as? String, "Hi.")
    }

    // MARK: talking over it

    /// The learner starts talking while an answer is still on its way. It is dropped — the request
    /// for it included, so the microphone is not kept waiting — and that is not a failure.
    func testAnAnswerTheLearnerTalkedOverIsNeverSpokenAndIsNotAFailure() async throws {
        let speaker = LoggingSpeaker()
        let session = makeSession([says("far too late")], speaker: speaker)
        try await session.start(callbacks: VoiceSessionCallbacks())
        StubHTTP.hold()

        let turn = Task { try await session.sendText("tell me a very long story") }
        for _ in 0..<400 where StubHTTP.seen.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(StubHTTP.seen.count, 1, "the question went out")

        session.interrupt()
        try await turn.value

        XCTAssertTrue(speaker.said.isEmpty)
        XCTAssertEqual(speaker.log.all.filter { $0 == "stop" }.count, 2, "once for the typed question, once for the interruption")
    }

    /// Saaras is a request too, and so is a look. While either is out the turn is still busy, and
    /// the next one cannot open the microphone until it is not: the island says "listening" and
    /// the first words are lost. Talking over a turn ends all of it, not only the question to the
    /// model — and ends it quietly.
    func testTalkingOverWhileTheEarsAreStillWorkingEndsTheTurnAtOnce() async throws {
        let ears = SlowEars()
        let speaker = LoggingSpeaker()
        let session = makeSession([says("never asked")], speaker: speaker, ears: ears)
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.beginTurn()

        let ending = Task { try await session.endTurn() }
        for _ in 0..<400 where !ears.calls.all.contains("finish") { try await Task.sleep(nanoseconds: 5_000_000) }
        session.interrupt()

        let result = await outcome(of: ending)
        XCTAssertNotNil(result, "the turn was still waiting on its ears two seconds after being talked over")
        if case let .failure(error)? = result { XCTFail("being talked over is not a failure: \(error)") }
        XCTAssertTrue(speaker.said.isEmpty)
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    func testTalkingOverDuringALookEndsTheTurnAtOnce() async throws {
        let speaker = LoggingSpeaker()
        let looking = Collected<String>()
        let session = makeSession(
            [calls("look_at_screen", #"{"question":"this"}"#), says("never said")],
            speaker: speaker,
            look: { question in
                looking.add(question)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                return ScreenLook(answer: "far too late")
            })
        try await session.start(callbacks: VoiceSessionCallbacks())

        let turn = Task { try await session.sendText("what is this") }
        for _ in 0..<400 where looking.all.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        session.interrupt()

        let result = await outcome(of: turn)
        XCTAssertNotNil(result, "the turn was still looking two seconds after being talked over")
        if case let .failure(error)? = result { XCTFail("being talked over is not a failure: \(error)") }
        XCTAssertTrue(speaker.said.isEmpty)
        XCTAssertEqual(StubHTTP.seen.count, 1, "and the model is not asked what it saw")
    }

    /// What a dropped turn asked is dropped with it. Left in the conversation, the question nobody
    /// wanted answered would be answered along with the next one.
    func testATurnThatWasTalkedOverLeavesNothingBehind() async throws {
        let session = makeSession([says("Four.")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        StubHTTP.hold()
        let dropped = Task { try await session.sendText("tell me a very long story") }
        for _ in 0..<400 where StubHTTP.seen.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        session.interrupt()
        _ = await outcome(of: dropped)
        StubHTTP.release()

        try await session.sendText("what is two and two")

        let next = try messages(of: 1)
        XCTAssertEqual(roles(next), ["system", "user"])
        XCTAssertEqual(next.last?["content"] as? String, "what is two and two")
    }

    /// The same for a turn that failed: the question it never got an answer to is not sent again
    /// behind the next one.
    func testATurnThatFailedLeavesNothingBehind() async throws {
        let session = makeSession([.failing(), says("Hello.")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        do {
            try await session.sendText("are you there")
            XCTFail("there was no network")
        } catch {}

        try await session.sendText("hello")

        let next = try messages(of: 1)
        XCTAssertEqual(roles(next), ["system", "user"])
        XCTAssertEqual(next.last?["content"] as? String, "hello")
    }

    /// A conversation is not resent whole for ever: each turn would cost more than the last, and
    /// in the end more than the model takes. What is kept starts at the start of a turn — never
    /// at a tool's answer to a call that has been cut away, which a server would refuse.
    func testALongConversationIsTrimmedFromTheFrontAtTheStartOfATurn() async throws {
        func message(_ role: String, _ text: String) -> [String: Any] { ["role": role, "content": text] }
        let history = [
            message("user", "1"), message("assistant", "1"),
            message("user", "2"), message("assistant", "look"), message("tool", "seen"), message("assistant", "2"),
            message("user", "3"), message("assistant", "3"),
        ]
        XCTAssertEqual(ChainVoiceSession.trimmed(history, keeping: 8).count, 8, "short enough: left alone")
        let kept = ChainVoiceSession.trimmed(history, keeping: 4)
        XCTAssertEqual(roles(kept), ["user", "assistant"], "four would begin at a tool's answer; it begins at the next turn instead")
        XCTAssertEqual(kept.first?["content"] as? String, "3")
        XCTAssertEqual(ChainVoiceSession.trimmed(history, keeping: 6).first?["content"] as? String, "2")

        // And through a session: many turns on, a request is no longer than the limit and the prompt.
        let session = makeSession([says("ok")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        let turns = ChainVoiceSession.longestHistory / 2 + 5
        for turn in 1...turns { try await session.sendText("question \(turn)") }
        let last = try messages(of: turns - 1)
        XCTAssertLessThanOrEqual(last.count, ChainVoiceSession.longestHistory + 1)
        XCTAssertEqual(roles(last).prefix(2), ["system", "user"])
        XCTAssertEqual(last.last?["content"] as? String, "question \(turns)")
    }

    /// An interruption stops what is being said, there and then.
    func testInterruptingStopsTheSpeaker() {
        let speaker = LoggingSpeaker()
        let session = makeSession([], speaker: speaker)
        session.interrupt()
        XCTAssertEqual(speaker.log.all, ["stop"])
    }

    // MARK: when it does not work

    func testSarvamSayingNoIsASentenceNotAPageOfJSON() async throws {
        func failure(_ status: Int, _ code: String) async -> (any Error)? {
            let refusal = StubHTTP.Reply.json(["error": ["message": "no", "code": code]], status: status)
            let session = makeSession([refusal])
            do {
                try await session.start(callbacks: VoiceSessionCallbacks())
                try await session.sendText("hello")
                return nil
            } catch {
                return error
            }
        }
        let refused = await failure(403, "invalid_api_key_error")
        XCTAssertEqual(refused as? SarvamError, .keyRefused)
        let spent = await failure(429, "insufficient_quota_error")
        XCTAssertEqual(spent as? SarvamError, .outOfCredits)
        let busy = await failure(429, "rate_limit_exceeded_error")
        XCTAssertEqual(busy as? SarvamError, .busy)
    }

    func testALocalModelThatIsNotThereSaysWhatToStart() async throws {
        let session = makeSession([.failing(.cannotConnectToHost)], configuration: SaathiConfiguration())
        try await session.start(callbacks: VoiceSessionCallbacks())
        do {
            try await session.sendText("hello")
            XCTFail("nothing is listening")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Is Ollama or LM Studio running?"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("http://localhost:11434"), error.localizedDescription)
        }
    }

    func testARefusalIsTheServersOwnWordsWhereItHasAny() {
        let openAIShaped = Data(#"{"error":{"message":"model 'llama9' not found","type":"invalid_request_error"}}"#.utf8)
        XCTAssertEqual(ChainVoiceSession.statedReason(in: openAIShaped), "model 'llama9' not found")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data(#"{"error":"no such model"}"#.utf8)), "no such model")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data(#"{"detail":"Method Not Allowed"}"#.utf8)), "Method Not Allowed")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data("404 page not found\n".utf8)), "404 page not found")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data()), "no response body")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data(String(repeating: "x", count: 5_000).utf8)).count, 300)

        let local = ChainVoiceSession.refusal(status: 404, body: openAIShaped, configuration: SaathiConfiguration())
        XCTAssertTrue(local.localizedDescription.contains("model 'llama9' not found"), local.localizedDescription)
        XCTAssertTrue(local.localizedDescription.contains("Ollama"), local.localizedDescription)
    }

    func testAnAnswerThatIsNotAnAnswerSaysSo() async throws {
        let session = makeSession([.json(["unexpected": true])])
        try await session.start(callbacks: VoiceSessionCallbacks())
        do {
            try await session.sendText("hello")
            XCTFail("there was no message in that")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not read the model's answer"), error.localizedDescription)
        }
    }
}
