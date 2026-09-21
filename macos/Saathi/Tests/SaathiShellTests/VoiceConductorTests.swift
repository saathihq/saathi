//
//  VoiceConductorTests.swift
//  SaathiShellTests
//
//  The ordering rules of the voice session's life, run rather than read. Each one was found by
//  something going wrong — two sessions on one microphone, a turn ended that never opened, a press
//  that did nothing and said nothing — and until the conductor took a session maker, none of them
//  could be checked without building the whole app.
//

import XCTest
import os
import SaathiContract
import SaathiKit
@testable import SaathiShell

/// A session that records what was asked of it, in order, into a log shared between sessions.
private final class FakeSession: VoiceSession, @unchecked Sendable {
    let lane: VoiceLane = .chain
    let speaksForItself: Bool
    let name: String
    let log: OSAllocatedUnfairLock<[String]>
    let endDelay: UInt64
    private let callbacks = OSAllocatedUnfairLock<VoiceSessionCallbacks?>(initialState: nil)

    init(_ name: String, log: OSAllocatedUnfairLock<[String]>, speaksForItself: Bool = false, endDelay: UInt64 = 0) {
        self.name = name
        self.log = log
        self.speaksForItself = speaksForItself
        self.endDelay = endDelay
    }

    func start(callbacks: VoiceSessionCallbacks) async throws {
        self.callbacks.withLock { $0 = callbacks }
        note("start")
    }
    func beginTurn() async throws { note("begin") }
    func endTurn() async throws {
        if endDelay > 0 { try? await Task.sleep(nanoseconds: endDelay) }
        note("end")
    }
    func stop() async { note("stop") }

    func emit(_ action: SaathiAction) { callbacks.withLock { $0 }?.onAction?(action) }
    private func note(_ what: String) { log.withLock { $0.append("\(name).\(what)") } }
}

@MainActor
final class VoiceConductorTests: XCTestCase {

    private let log = OSAllocatedUnfairLock(initialState: [String]())
    private var events: [CompanionEvent] = []
    private var performed: OSAllocatedUnfairLock<[SaathiAction]> = .init(initialState: [])

    private func conductor(_ make: @escaping VoiceConductor.SessionMaker) -> VoiceConductor {
        let performed = self.performed
        let log = self.log
        return VoiceConductor(
            makeSession: make,
            perform: { action in performed.withLock { $0.append(action) } },
            stopSpeaking: { log.withLock { $0.append("speaker.stop") } },
            onEvent: { [weak self] in self?.events.append($0) })
    }

    /// Two realtime sessions must never hold the microphone at once: the old one is stopped before
    /// the new one is even made.
    func testReconfigureStopsTheOldSessionBeforeStartingTheNew() async {
        var made = 0
        let log = self.log
        let voice = conductor { _ in
            made += 1
            return FakeSession(made == 1 ? "old" : "new", log: log)
        }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()

        let swapped = await voice.reconfigure(to: SaathiConfiguration(provider: .local))
        await voice.settle()

        XCTAssertTrue(swapped)
        XCTAssertEqual(log.withLock { $0 }, ["old.start", "speaker.stop", "old.stop", "new.start"])
        XCTAssertFalse(voice.isReconfiguring)
    }

    /// Keys are usually already up by the time someone presses Save, so `isOpen` reads false while
    /// `endTurn()` is still finishing underneath. The teardown waits for it anyway.
    func testReconfigureWaitsForAnEndCallThatIsStillRunning() async {
        var made = 0
        let log = self.log
        let voice = conductor { _ in
            made += 1
            return FakeSession(made == 1 ? "old" : "new", log: log, endDelay: made == 1 ? 80_000_000 : 0)
        }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()
        voice.keysBegan()
        voice.keysEnded()
        XCTAssertFalse(voice.isTurnOpen, "closed synchronously, while the end call is still queued")

        await voice.reconfigure(to: SaathiConfiguration(provider: .local))

        let order = log.withLock { $0 }
        let end = try? XCTUnwrap(order.firstIndex(of: "old.end"))
        let stop = try? XCTUnwrap(order.firstIndex(of: "old.stop"))
        XCTAssertNotNil(end)
        XCTAssertNotNil(stop)
        if let end, let stop { XCTAssertLessThan(end, stop, "the session was stopped under its own endTurn: \(order)") }
    }

    /// A turn that is open when Save is pressed is closed — and the state machine told — before
    /// anything is torn down.
    func testReconfigureClosesAnOpenTurnFirst() async {
        let log = self.log
        let voice = conductor { _ in FakeSession("s", log: log) }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()
        voice.keysBegan()
        XCTAssertTrue(voice.isTurnOpen)

        await voice.reconfigure(to: SaathiConfiguration(provider: .local))

        XCTAssertEqual(events.filter { $0 == .keysHeld || $0 == .keysReleased }, [.keysHeld, .keysReleased])
        let order = log.withLock { $0 }
        XCTAssertEqual(Array(order.prefix(5)), ["s.start", "s.begin", "s.end", "speaker.stop", "s.stop"])
    }

    /// A press during the switch-over is refused out loud, not swallowed and not honoured.
    func testAPressDuringAReconfigureIsRefusedOutLoud() async {
        var made = 0
        let log = self.log
        let voice = conductor { _ in
            made += 1
            return FakeSession("s\(made)", log: log, endDelay: 80_000_000)
        }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()
        voice.keysBegan()
        voice.keysEnded()

        let swap = Task { await voice.reconfigure(to: SaathiConfiguration(provider: .local)) }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(voice.isReconfiguring)
        voice.keysBegan()
        voice.toggleTalk()
        let second = await voice.reconfigure(to: SaathiConfiguration(provider: .local))
        _ = await swap.value

        XCTAssertFalse(second, "a second reconfigure alongside the first does nothing")
        XCTAssertEqual(events.filter { $0 == .failure("switching over — try again in a moment") }.count, 2)
        XCTAssertEqual(log.withLock { $0 }.filter { $0.hasSuffix(".begin") }.count, 1, "no turn opened mid-teardown")
    }

    /// No session is not silence: the press says why.
    func testAPressWithNoSessionSaysWhyThereIsNoVoice() {
        struct NoKey: LocalizedError { var errorDescription: String? { "openai needs your own API key" } }
        let voice = conductor { _ in throw NoKey() }
        voice.start(with: SaathiConfiguration(provider: .local))
        XCTAssertFalse(voice.hasSession)
        events.removeAll()

        voice.keysBegan()
        voice.toggleTalk()
        voice.keysEnded()

        XCTAssertEqual(events, [.failure("openai needs your own API key"), .failure("openai needs your own API key")])
    }

    /// One question, one voice: on a session that speaks for itself a `say` is shown, not spoken
    /// again by the system voice. An `open_url` is opened on every lane.
    func testASessionThatSpeaksForItselfIsNotReadOutASecondTime() async throws {
        let log = self.log
        let session = FakeSession("rt", log: log, speaksForItself: true)
        let voice = conductor { _ in session }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()

        let say = SaathiAction.say(SayAction(text: "hello", tone: .calm))
        let open = SaathiAction.openUrl(OpenUrlAction(url: "https://saathi.dev"))
        session.emit(say)
        session.emit(open)
        for _ in 0..<50 where performed.withLock({ $0.count }) < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(events.filter { if case .action = $0 { return true } else { return false } }.count, 2, "both are shown")
        XCTAssertEqual(performed.withLock { $0 }, [open], "only the URL is performed")
    }

    func testTalkTogglesATurn() async {
        let log = self.log
        let voice = conductor { _ in FakeSession("s", log: log) }
        voice.start(with: SaathiConfiguration(provider: .local))
        voice.toggleTalk()
        XCTAssertTrue(voice.isTurnOpen)
        voice.toggleTalk()
        XCTAssertFalse(voice.isTurnOpen)
        await voice.settle()
        XCTAssertEqual(events, [.keysHeld, .keysReleased])
        XCTAssertEqual(log.withLock { $0 }.sorted(), ["s.begin", "s.end", "s.start"])
    }
}
