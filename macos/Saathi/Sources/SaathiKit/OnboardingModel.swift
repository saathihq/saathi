//
//  OnboardingModel.swift
//  SaathiKit
//
//  First run, as a value. The app sends what happened — a button, macOS's answer about a
//  permission, a transcript, the backend's answer about a trial — and draws whatever `step` says.
//
//  It is a fold, like `CompanionStateMachine`, and for the same reason: the order of first run and
//  the two things that must never block it (a denied permission, a refused trial) are rules, and
//  rules that live in view code are rules nobody can run. Nothing here knows what a card is.
//
//  Two decisions worth knowing before changing anything:
//
//  • "Hosted" can be chosen only if a trial token was actually issued. The spec's words are "never
//    a fallback to hosted", and an onboarding that let someone pick a provider they have no token
//    for would end with a companion that answers nothing.
//  • `apply(to:)` writes `onboarded` only at `.finished`. Quit halfway and first run comes back;
//    what was already answered is kept, so it is not asked again as if for the first time — 4b
//    seeds a fresh model from the configuration if it wants that, this type does not guess.
//

import Foundation
import SaathiContract

public enum DemoStep: Equatable, Sendable {
    case micCheck
    case holdToTalk
    case question(OnboardingQuestion)
    case trialChat
    case providerChoice
}

public enum OnboardingStep: Equatable, Sendable {
    case welcome
    case colour
    case intoNotch
    case permission(Permission)
    case allSet
    case demo(DemoStep)
    case finished
}

public enum TrialState: Equatable, Sendable {
    case notAsked
    case asking
    case ready
    /// The reason, in the backend's own words or the transport's.
    case failed(String)
}

public enum ProviderChoice: String, CaseIterable, Sendable {
    case hosted
    case local
    case ownKey
}

public enum OnboardingEvent: Equatable, Sendable {
    /// The card's primary button: Let's start, Continue.
    case next
    case choseColour(String)
    /// macOS answered, or System Settings was polled and the answer changed.
    case permissionResolved(Permission, PermissionStatus)
    /// A transcript arrived, from the mic check or a held turn.
    case heard(String)
    case keysHeld
    /// An answer to the current question, spoken or typed.
    case answered(String)
    case skipDemo
    case trialRequested
    case trialIssued
    case trialFailed(String)
    case skipTrial
    case choseProvider(ProviderChoice)
}

public struct OnboardingModel: Equatable, Sendable {

    public static let permissionOrder: [Permission] = [.microphone, .speechRecognition, .inputMonitoring]
    public static let defaultColour = "blue"

    public private(set) var step: OnboardingStep = .welcome
    public private(set) var answers = OnboardingAnswers()
    public private(set) var colour: String?
    public private(set) var permissions: [Permission: PermissionStatus] = [:]
    public private(set) var heardSomething = false
    public private(set) var lastHeard = ""
    public private(set) var heldKeys = false
    public private(set) var trial: TrialState = .notAsked
    public private(set) var providerChoice: ProviderChoice?
    /// The current question was answered once with something unreadable and is being asked again.
    public private(set) var isReasking = false

    private let supportedLanguages: [String]
    private let palette: [String]

    /// `supportedLanguages`: BCP 47 tags this Mac can recognise, the machine's own first — the
    /// first is the default. `palette`: the mascot's colour names.
    public init(supportedLanguages: [String], palette: [String]) {
        self.supportedLanguages = supportedLanguages
        self.palette = palette
    }

    // MARK: what the card can ask

    /// Whether the primary button does anything right now.
    public var canContinue: Bool {
        switch step {
        case .welcome, .colour, .intoNotch, .allSet: return true
        case .permission, .finished: return false
        case .demo(.micCheck): return heardSomething
        // Someone without Input Monitoring can never hold the keys; the step must not trap them.
        case .demo(.holdToTalk): return heldKeys || permissions[.inputMonitoring] != .granted
        case .demo(.question): return false
        case .demo(.trialChat): return trial == .ready
        case .demo(.providerChoice): return false
        }
    }

    /// Hosted only with a token in hand.
    public var availableProviderChoices: [ProviderChoice] {
        trial == .ready ? [.hosted, .local, .ownKey] : [.local, .ownKey]
    }

    /// In the order they were asked, for the "Fix permissions" entry and the island's rows.
    public var deniedPermissions: [Permission] {
        Self.permissionOrder.filter { permission in
            guard let status = permissions[permission] else { return false }
            return status != .granted
        }
    }

    /// First run ended without a provider being chosen — own key, or the demo was skipped — so
    /// the island should open on Setup, which is where keys are pasted and the provider follows.
    public var opensSetupAfterwards: Bool {
        step == .finished && (providerChoice == nil || providerChoice == .ownKey)
    }

    // MARK: the fold

    /// Applies `event`. Returns whether anything changed; an event that does not belong to the
    /// current step is ignored, never an error — buttons and callbacks arrive late.
    @discardableResult
    public mutating func handle(_ event: OnboardingEvent) -> Bool {
        let before = self
        apply(event)
        return self != before
    }

    private mutating func apply(_ event: OnboardingEvent) {
        // Recorded whatever is showing: the Input Monitoring grant lands seconds later, from
        // System Settings, possibly while a different step is up.
        if case let .permissionResolved(permission, status) = event {
            permissions[permission] = status
            if case .permission(permission) = step { advanceFromPermission(permission) }
            return
        }

        if event == .skipDemo {
            if case .demo = step { step = .finished }
            return
        }

        switch (step, event) {
        case (.welcome, .next):
            step = .colour

        case let (.colour, .choseColour(name)):
            if palette.contains(name) { colour = name }
        case (.colour, .next):
            step = .intoNotch

        case (.intoNotch, .next):
            step = .permission(Self.permissionOrder[0])

        case (.allSet, .next):
            step = .demo(.micCheck)

        case let (.demo(.micCheck), .heard(text)):
            note(heard: text)
        case (.demo(.micCheck), .next):
            if canContinue { step = .demo(.holdToTalk) }

        case (.demo(.holdToTalk), .keysHeld):
            heldKeys = true
        case let (.demo(.holdToTalk), .heard(text)):
            note(heard: text)
        case (.demo(.holdToTalk), .next):
            if canContinue { step = .demo(.question(OnboardingQuestion.allCases[0])) }

        case let (.demo(.question(question)), .answered(text)):
            answer(question, with: text)

        case (.demo(.trialChat), .trialRequested):
            if trial != .asking && trial != .ready { trial = .asking }
        case (.demo(.trialChat), .trialIssued):
            trial = .ready
        case let (.demo(.trialChat), .trialFailed(reason)):
            trial = .failed(reason)
        case (.demo(.trialChat), .next):
            if canContinue { step = .demo(.providerChoice) }
        case (.demo(.trialChat), .skipTrial):
            step = .demo(.providerChoice)

        case let (.demo(.providerChoice), .choseProvider(choice)):
            guard availableProviderChoices.contains(choice) else { return }
            providerChoice = choice
            step = .finished

        default:
            break
        }
    }

    private mutating func note(heard text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        heardSomething = true
        lastHeard = trimmed
    }

    private mutating func advanceFromPermission(_ permission: Permission) {
        guard let index = Self.permissionOrder.firstIndex(of: permission) else { return }
        let next = index + 1
        step = next < Self.permissionOrder.count ? .permission(Self.permissionOrder[next]) : .allSet
    }

    /// Reads the answer; asks once more if it cannot; then moves on with the default. Twice is
    /// the limit because a third "sorry, which one?" is the point at which a spoken interface
    /// stops being a conversation and becomes an obstacle.
    private mutating func answer(_ question: OnboardingQuestion, with text: String) {
        let understood: Bool
        switch question {
        case .name:
            let name = AnswerParser.name(from: text)
            if name != nil { answers.name = name }
            understood = name != nil
        case .firstGoal:
            let goal = AnswerParser.goal(from: text)
            if goal != nil { answers.firstGoal = goal }
            understood = goal != nil
        case .manner:
            let manner = Manner.parse(text)
            if manner != nil { answers.manner = manner }
            understood = manner != nil
        case .language:
            let language = AnswerParser.language(from: text, supported: supportedLanguages)
            if language != nil { answers.language = language }
            understood = language != nil
        }

        if !understood && !isReasking {
            isReasking = true
            return
        }
        if !understood { applyDefault(for: question) }
        isReasking = false

        let all = OnboardingQuestion.allCases
        let index = all.firstIndex(of: question)! + 1
        step = index < all.count ? .demo(.question(all[index])) : .demo(.trialChat)
    }

    /// A manner and a language have sensible defaults. A name and a goal do not: nobody is called
    /// a default, and Saathi manages without either.
    private mutating func applyDefault(for question: OnboardingQuestion) {
        switch question {
        case .name, .firstGoal: break
        case .manner: answers.manner = .warmAndNormal
        case .language: answers.language = supportedLanguages.first
        }
    }

    // MARK: what is written

    /// Writes what first run learned into `configuration`, and nothing else. Safe to call at any
    /// step — `onboarded` is only set at the end. The trial token is not this type's to write:
    /// `TrialEnrollment.enroll` already saved it.
    public func apply(to configuration: inout SaathiConfiguration) {
        if step != .welcome { configuration.colour = colour ?? Self.defaultColour }
        if let name = answers.name { configuration.name = name }
        if let goal = answers.firstGoal { configuration.firstGoal = goal }
        if let manner = answers.manner {
            configuration.tone = manner.tone
            configuration.pace = manner.pace
        }
        if let language = answers.language { configuration.language = language }

        guard step == .finished else { return }
        configuration.onboarded = true
        switch providerChoice {
        case .hosted: configuration.provider = .hosted
        case .local: configuration.provider = .local
        // Setup decides the provider from the keys that validate, as it does today.
        case .ownKey, .none: break
        }
    }
}
