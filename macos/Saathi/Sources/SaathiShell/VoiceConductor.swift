//
//  VoiceConductor.swift
//  SaathiShell
//
//  The life of the voice session, and nothing else: making one, starting it, opening and closing
//  turns on it, swapping it for another without a relaunch, and putting it down at quit.
//
//  It lived in `AppController`, between the menu wiring and the island wording, where the ordering
//  rules it depends on — close the turn, drain the end call, cancel the start, stop the old session,
//  only then start the new one — could be read but not run. Every one of those rules was found the
//  hard way, and none of them had a test, because building an `AppController` builds two panels and
//  a status item. This takes a session *maker* instead of reaching for `VoiceSessionFactory`, so a
//  test hands it a fake and checks the order.
//
//  It knows nothing about views. What happens is reported as `CompanionEvent`s through one closure,
//  the same events the controller already feeds its state machine.
//

import Foundation
import SaathiContract
import SaathiKit

@MainActor
public final class VoiceConductor {

    public typealias SessionMaker = @MainActor (SaathiConfiguration) throws -> any VoiceSession

    private let makeSession: SessionMaker
    private let perform: @Sendable (SaathiAction) async throws -> Void
    private let stopSpeaking: @MainActor () -> Void
    private let onEvent: @MainActor (CompanionEvent) -> Void
    private let onScreenLook: @MainActor (_ question: String, _ answer: String) -> Void

    private var session: (any VoiceSession)?
    private var turns: TurnCoordinator?
    /// The in-flight `session.start(callbacks:)` call, held so a reconfigure can cancel it before
    /// stopping the session it belongs to — otherwise a start still resolving a connection can
    /// resume and open a socket after the replacement session already exists.
    private var startTask: Task<Void, Never>?
    /// Why there is no voice session, kept so a press can say so instead of doing nothing.
    private var startFailure: String?

    /// Set while a reconfigure is waiting for an open turn to finish, so a second Save does not
    /// start a second teardown alongside the first.
    public private(set) var isReconfiguring = false

    /// Whether a session exists to talk to.
    public var hasSession: Bool { session != nil }
    public var isTurnOpen: Bool { turns?.isOpen ?? false }

    public init(
        makeSession: @escaping SessionMaker,
        perform: @escaping @Sendable (SaathiAction) async throws -> Void,
        stopSpeaking: @escaping @MainActor () -> Void,
        onEvent: @escaping @MainActor (CompanionEvent) -> Void,
        onScreenLook: @escaping @MainActor (_ question: String, _ answer: String) -> Void = { _, _ in }
    ) {
        self.makeSession = makeSession
        self.perform = perform
        self.stopSpeaking = stopSpeaking
        self.onEvent = onEvent
        self.onScreenLook = onScreenLook
    }

    // MARK: starting

    public func start(with configuration: SaathiConfiguration) {
        startFailure = nil
        do {
            let session = try makeSession(configuration)
            self.session = session
            turns = TurnCoordinator(
                begin: { try await session.beginTurn() },
                end: { try await session.endTurn() },
                onFailure: { [weak self] message in self?.onEvent(.failure(message)) })
            let callbacks = VoiceSessionCallbacks(
                onUserTranscript: { [weak self] text in Task { @MainActor in self?.onEvent(.userSpoke(text)) } },
                onSaathiTranscript: { [weak self] text in Task { @MainActor in self?.onEvent(.saathiSpoke(text)) } },
                onAction: { [weak self] action in
                    Task { @MainActor in
                        guard let self else { return }
                        self.onEvent(.action(action))
                        guard Self.performs(action, sessionSpeaksForItself: session.speaksForItself) else { return }
                        let perform = self.perform
                        Task {
                            do {
                                try await perform(action)
                            } catch {
                                await MainActor.run { self.onEvent(.failure(error.localizedDescription)) }
                            }
                        }
                    }
                },
                onStatus: { [weak self] status in Task { @MainActor in self?.onEvent(.status(status)) } },
                onScreenLook: { [weak self] question, answer in
                    Task { @MainActor in self?.onScreenLook(question, answer) }
                }
            )
            // Cancelling any previous start before racing a fresh one in keeps at most one
            // start in flight — see `startTask`'s doc comment.
            startTask?.cancel()
            startTask = Task {
                do {
                    try await session.start(callbacks: callbacks)
                } catch is CancellationError {
                    // Superseded by a reconfigure; the session this call belonged to is already
                    // gone, so there is nothing left to report.
                } catch let error as URLError where error.code == .cancelled {
                    // URLSession reports a cancelled task this way, not as `CancellationError` — the
                    // same supersede-by-reconfigure case as above, just surfaced by the transport
                    // instead of the task tree. (The own-key branch of `resolveConnection()` has no
                    // real suspension point, so this arm is dead there — harmless, since the worst
                    // case is an extra banner, never a swallowed failure.)
                } catch {
                    await MainActor.run { self.onEvent(.failure(error.localizedDescription)) }
                }
            }
        } catch {
            startFailure = error.localizedDescription
            onEvent(.failure(error.localizedDescription))
        }
    }

    /// Whether an action goes to the performer at all. The performer reads `say` and `show_step`
    /// out through the system voice, which is right on the chain lane — it has no other voice —
    /// and wrong on a lane whose session speaks for itself: the realtime model's own audio already
    /// carries what it wants to say, and the system voice reading a step over it is the second,
    /// robot-sounding speaker that was reported. The island shows the step either way, because
    /// the `.action` event is sent before this is asked; and an `open_url` is always opened.
    static func performs(_ action: SaathiAction, sessionSpeaksForItself: Bool) -> Bool {
        switch action {
        case .say, .showStep: return !sessionSpeaksForItself
        case .openUrl, .lookAtScreen: return true
        }
    }

    // MARK: turns

    /// The keys went down. Says why when there is nothing to talk to — a dead session that answers
    /// nothing reads as a broken key — and refuses, out loud, in the middle of a reconfigure:
    /// opening a turn on a coordinator that is being torn down is the same "two things holding
    /// the microphone" hazard the teardown ordering exists to prevent, entered from the input side.
    public func keysBegan() {
        guard let turns else { reportNoVoice(); return }
        if isReconfiguring { reportReconfiguring(); return }
        if turns.open() { onEvent(.keysHeld) }
    }

    /// The keys came up. Unguarded on purpose: `reconfigure` closes any open turn itself,
    /// synchronously, before its first await, so by the time `isReconfiguring` is observably true
    /// here `turns.isOpen` already reads false and this is a no-op. If a future await ever lands
    /// above that `close()`, this comment is the tripwire.
    public func keysEnded() {
        guard let turns else { return }
        if turns.close() { onEvent(.keysReleased) }
    }

    /// The menu's and the island's Talk: press to start, press to stop.
    public func toggleTalk() {
        if isReconfiguring { reportReconfiguring(); return }
        guard let turns else { reportNoVoice(); return }
        if turns.isOpen {
            turns.close(); onEvent(.keysReleased)
        } else {
            turns.open(); onEvent(.keysHeld)
        }
    }

    public func reportReconfiguring() {
        onEvent(.failure("switching over — try again in a moment"))
    }

    private func reportNoVoice() {
        onEvent(.failure(startFailure ?? "voice is not available"))
    }

    /// Waits for every queued begin and end. Tests use it.
    func settle() async {
        await turns?.settle()
        await startTask?.value
    }

    // MARK: swapping and stopping

    /// Swaps in a session for `updated` without a relaunch. Returns false, having done nothing,
    /// when a reconfigure is already under way.
    ///
    /// The order is not negotiable. A turn is closed before anything is torn down — `TurnCoordinator`
    /// exists because a turn that never opened must not be ended, and ripping a session out from
    /// under an open turn is the same bug approached from the other side. The old socket is closed
    /// before a new one opens, so two realtime sessions never hold the microphone at once.
    @discardableResult
    public func reconfigure(to updated: SaathiConfiguration) async -> Bool {
        guard !isReconfiguring else { return false }
        isReconfiguring = true
        defer { isReconfiguring = false }

        if let turns {
            if turns.isOpen {
                _ = turns.close()
                onEvent(.keysReleased)
            }
            // Drain whatever end call is queued, whether or not a turn is open right now.
            // `close()` marks `isOpen` false synchronously, but the end call it queues can still be
            // running long after that flips — and gating this wait behind `isOpen` skipped it in
            // exactly the ordinary case that matters: keys are usually already released by the time
            // someone opens Setup and hits Save, so `isOpen` already reads false while `endTurn()`
            // is still finishing underneath. Waiting unconditionally is free when nothing is
            // queued — `work` is never nilled, so awaiting a finished task returns immediately.
            await turns.settle()
        }

        // The old session's start may still be resolving a connection or opening a socket; cancel
        // it before stopping the session, or it can resume afterwards and open a second live
        // socket after the new session already exists — the same hazard this ordering exists to
        // prevent, entered from the start side instead of the stop side.
        startTask?.cancel()
        stopSpeaking()
        await session?.stop()
        session = nil
        turns = nil

        start(with: updated)
        return true
    }

    /// Quit: whatever it was saying does not outlive the goodbye, and an in-flight start must not
    /// open a socket during power-down.
    public func shutDown() async {
        stopSpeaking()
        startTask?.cancel()
        await session?.stop()
    }
}
