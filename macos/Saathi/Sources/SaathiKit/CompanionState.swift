//
//  CompanionState.swift
//  SaathiKit
//
//  What the companion is doing right now, folded from the voice session's events and the keys.
//  Pure and clock-free: time is an argument, so the shell can drive it from a timer and the tests
//  from numbers. The face and the state word both derive from this, which is what makes the
//  character a redundant cue rather than a separate channel.
//

import Foundation
import SaathiContract

public enum CompanionState: Equatable, Sendable {
    case asleep
    case idle
    case listening
    case thinking
    case speaking
    case showingStep(index: Int, total: Int)
    case celebrating
    case alert(String)
    case poweringDown

    /// The word the notch shows and VoiceOver reads. Short on purpose.
    public var word: String {
        switch self {
        case .asleep: return "Asleep"
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case let .showingStep(index, total): return "Step \(index) of \(total)"
        case .celebrating: return "Done"
        case let .alert(message): return message
        case .poweringDown: return "Bye"
        }
    }
}

public enum CompanionEvent: Equatable, Sendable {
    /// Control and option went down together.
    case keysHeld
    /// Either key lifted.
    case keysReleased
    /// The menu's Talk item, for people who cannot hold keys: press to start, press to stop.
    case talkPressed
    /// A lane's free-text status line ("listening…", "thinking…", "did not catch that", …).
    case status(String)
    case userSpoke(String)
    /// The realtime lane's reply text; the chain lane reports speech through `speakingChanged`.
    case saathiSpoke(String)
    case action(SaathiAction)
    case speakingChanged(Bool)
    case failure(String)
    case quit
}

public struct CompanionStateMachine: Equatable, Sendable {

    public private(set) var state: CompanionState
    /// How long a spoken line, a step or a reply stays on the face after it ends.
    public var idleDelay: TimeInterval = 2
    /// How long the companion sits idle before it falls asleep.
    public var sleepAfter: TimeInterval = 180

    private var lastActivity: TimeInterval
    /// When the current transient state (speaking, step, alert) gives way to idle.
    private var settleAt: TimeInterval?

    public init(now: TimeInterval, state: CompanionState = .idle) {
        self.state = state
        self.lastActivity = now
    }

    @discardableResult
    public mutating func apply(_ event: CompanionEvent, now: TimeInterval) -> CompanionState {
        guard state != .poweringDown else { return state }

        // Events that change nothing must not disturb a pending settle: a stray key release or a
        // readiness note arriving mid-reply would otherwise strand the face outside idle for good.
        switch event {
        case .keysReleased where state != .listening,
             .action(.say), .action(.openUrl):
            lastActivity = now
            return state
        case let .status(text) where Self.state(forStatus: text, current: state) == state:
            lastActivity = now
            return state
        default:
            break
        }

        lastActivity = now
        settleAt = nil

        switch event {
        case .quit:
            state = .poweringDown
        case .keysHeld:
            state = .listening
        case .keysReleased:
            state = .thinking
        case .talkPressed:
            state = state == .listening ? .thinking : .listening
        case let .status(text):
            state = Self.state(forStatus: text, current: state)
            if case .alert = state { settleAt = now + idleDelay }
        case .userSpoke:
            state = .thinking
        case .saathiSpoke:
            if !isShowingStep { state = .speaking }
            settleAt = now + idleDelay
        case let .action(action):
            if case let .showStep(step) = action {
                state = step.index >= step.total
                    ? .celebrating
                    : .showingStep(index: step.index, total: step.total)
            }
        case let .speakingChanged(speaking):
            if speaking {
                if !isShowingStep { state = .speaking }
            } else {
                settleAt = now + idleDelay
            }
        case let .failure(message):
            state = .alert(message)
            settleAt = now + idleDelay * 2
        }
        return state
    }

    @discardableResult
    public mutating func tick(now: TimeInterval) -> CompanionState {
        guard state != .poweringDown else { return state }
        if let at = settleAt, now >= at {
            settleAt = nil
            state = .idle
        }
        if state == .idle, now - lastActivity >= sleepAfter {
            state = .asleep
        }
        return state
    }

    private var isShowingStep: Bool {
        switch state {
        case .showingStep, .celebrating: return true
        default: return false
        }
    }

    /// Which status lines are states, and which are just notes. The lanes' wording is pinned by
    /// their own tests; this only reads the beginnings.
    static func state(forStatus text: String, current: CompanionState) -> CompanionState {
        let lower = text.lowercased()
        if lower.hasPrefix("listening") { return .listening }
        if lower.hasPrefix("thinking") { return .thinking }
        let trouble = ["did not catch", "ignored", "realtime error", "disconnected", "send failed", "not authorised", "refused"]
        if trouble.contains(where: { lower.hasPrefix($0) }) { return .alert(text) }
        return current
    }
}
