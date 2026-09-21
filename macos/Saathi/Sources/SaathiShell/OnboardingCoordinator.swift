//
//  OnboardingCoordinator.swift
//  SaathiShell
//
//  First run, connected to the world: the `OnboardingModel` decides what happens next, and this
//  does the things deciding cannot — speak the line, ask macOS for a permission, ask the backend
//  for a trial, write `shell.json` — then feeds what came of it back in as an event.
//
//  Everything it touches arrives as a closure in `OnboardingEffects`, for the reason
//  `VoiceConductor` takes a session maker: the rules here are about *order* — the acknowledgement
//  before the next question, the device id on disk before the network, nothing saved as onboarded
//  until the end — and order is only checkable if a test can stand where the world would.
//
//  The views read `model`, `bubble`, `waitingOnSettings` and `isBusy`, and call the methods. They
//  decide nothing.
//

import Foundation
import SaathiContract
import SaathiKit

/// The world, as first run needs it.
public struct OnboardingEffects {
    /// Says a line and returns when it has been said. Cancelling the calling task must cut it off.
    public var speak: @MainActor (String, Tone) async -> Void = { _, _ in }
    public var stopSpeaking: @MainActor () -> Void = {}
    /// Prompts if macOS will, and reports what it decided.
    public var requestPermission: @MainActor (Permission) async -> PermissionStatus = { _ in .notDetermined }
    public var permissionStatus: @MainActor (Permission) -> PermissionStatus = { _ in .notDetermined }
    public var openSettings: @MainActor (Permission) -> Void = { _ in }
    /// Asks the backend for a trial and saves the token. Throws the reason when it cannot.
    public var enrollTrial: @MainActor () async throws -> Void = {}
    /// Writes what the model has learned so far into `shell.json`.
    public var save: @MainActor (OnboardingModel) -> Void = { _ in }
    /// The trial chat is about to start, or has ended: the app swaps the voice session to match.
    public var trialChatChanged: @MainActor (_ active: Bool) -> Void = { _ in }
    /// First run is over, by finishing or by skipping. Called exactly once.
    public var finish: @MainActor (OnboardingModel) -> Void = { _ in }

    public init() {}
}

@MainActor
public final class OnboardingCoordinator: ObservableObject {

    @Published public private(set) var model: OnboardingModel
    /// What the speech bubble shows: the last thing heard on the listening steps.
    @Published public private(set) var bubble = ""
    /// Set while System Settings is open for a permission macOS will not grant from a dialog. The
    /// card then offers "I've turned it on" and "Skip for now" instead of "Allow".
    @Published public private(set) var waitingOnSettings: Permission?
    /// A permission request or a trial request is in flight; buttons wait.
    @Published public private(set) var isBusy = false
    @Published public private(set) var isSpeaking = false

    private let effects: OnboardingEffects
    private var speech: Task<Void, Never>?
    private var finished = false

    public init(model: OnboardingModel, effects: OnboardingEffects) {
        self.model = model
        self.effects = effects
    }

    /// Shows the first card and says the first line.
    public func begin() {
        say(OnboardingScript.line(for: model), after: nil)
    }

    // MARK: what the cards send

    public func next() { send(.next) }
    public func skipDemo() { send(.skipDemo) }
    public func skipTrial() { send(.skipTrial) }
    public func choose(colour: String) { send(.choseColour(colour)) }
    public func choose(provider: ProviderChoice) { send(.choseProvider(provider)) }

    /// The "Or type here" field, and the manner and language pickers.
    public func answer(_ text: String) { send(.answered(text)) }

    /// A transcript from the voice session. On a question it is the answer; on the two listening
    /// steps it is proof of being heard; anywhere else it is not first run's business.
    public func heard(_ text: String) {
        switch model.step {
        case .demo(.question):
            bubble = text
            send(.answered(text))
        case .demo(.micCheck), .demo(.holdToTalk):
            bubble = text
            send(.heard(text))
        default:
            break
        }
    }

    public func keysHeld() { send(.keysHeld) }

    /// "Allow" on a permission card.
    public func requestCurrentPermission() {
        guard case let .permission(permission) = model.step, !isBusy else { return }
        isBusy = true
        Task {
            let status = await effects.requestPermission(permission)
            isBusy = false
            if status == .granted {
                send(.permissionResolved(permission, status))
            } else if permission == .inputMonitoring, status != .denied {
                // No dialog can grant this one: it is a switch in System Settings, and the answer
                // arrives whenever the learner gets there. Wait on the card rather than moving on
                // as if they had said no.
                waitingOnSettings = permission
                effects.openSettings(permission)
            } else {
                send(.permissionResolved(permission, status))
            }
        }
    }

    /// "I've turned it on" and "Skip for now": both read what macOS says now and move on with it.
    public func settlePermissionFromSettings() {
        guard let permission = waitingOnSettings else { return }
        waitingOnSettings = nil
        send(.permissionResolved(permission, effects.permissionStatus(permission)))
    }

    /// "Start the chat" on the trial card, and "Try again" after a refusal.
    public func startTrial() {
        guard model.step == .demo(.trialChat), !isBusy else { return }
        isBusy = true
        send(.trialRequested)
        Task {
            do {
                try await effects.enrollTrial()
                isBusy = false
                effects.trialChatChanged(true)
                send(.trialIssued)
            } catch {
                isBusy = false
                // A `TrialError` carries the backend's own sentence; anything else gets the system's.
                let reason = (error as? TrialError)?.description ?? error.localizedDescription
                send(.trialFailed(reason))
            }
        }
    }

    // MARK: the loop

    private func send(_ event: OnboardingEvent) {
        let before = model
        guard model.handle(event) else { return }

        effects.save(model)

        if before.step == .demo(.trialChat), model.step != .demo(.trialChat) {
            effects.trialChatChanged(false)
        }

        // Speak when there is something new to say: a new step, a question being asked again, or
        // the trial card's state changing under the same title.
        let line = OnboardingScript.line(for: model)
        if line != OnboardingScript.line(for: before) {
            var acknowledgement: String?
            if case let .demo(.question(question)) = before.step, before.step != model.step {
                acknowledgement = OnboardingScript.acknowledgement(of: question, in: model.answers)
            }
            if before.step != model.step { bubble = "" }
            say(line, after: acknowledgement)
        }

        if model.step == .finished, !finished {
            finished = true
            effects.finish(model)
        }
    }

    /// Says `line`, after `acknowledgement` when there is one, cutting off whatever was being said:
    /// a card that has been left has nothing more to say.
    private func say(_ line: OnboardingLine, after acknowledgement: String?) {
        speech?.cancel()
        effects.stopSpeaking()
        speech = Task { [effects] in
            isSpeaking = true
            defer { if !Task.isCancelled { isSpeaking = false } }
            if let acknowledgement {
                await effects.speak(acknowledgement, .encouraging)
                guard !Task.isCancelled else { return }
            }
            await effects.speak(line.spoken, line.tone)
        }
    }

    /// Waits for whatever is being said. Tests use it.
    func settle() async {
        await speech?.value
    }

    /// Closing the window is skipping what is left: nothing more is said, and what was answered
    /// has already been saved.
    public func close() {
        speech?.cancel()
        effects.stopSpeaking()
        if model.step == .demo(.trialChat) { effects.trialChatChanged(false) }
        guard !finished else { return }
        finished = true
        effects.finish(model)
    }
}
