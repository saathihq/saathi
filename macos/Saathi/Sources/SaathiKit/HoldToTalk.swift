//
//  HoldToTalk.swift
//  SaathiKit
//
//  Hold control and option to talk, in any app. The decision is a pure tracker fed with modifier
//  flags; the monitor is a listen-only CGEventTap that feeds it. The tap needs Input Monitoring,
//  and the monitor refuses to install without it rather than failing silently.
//

import CoreGraphics
import Foundation

public struct HoldToTalkCombination: Equatable, Sendable {
    public var required: CGEventFlags

    public init(required: CGEventFlags) {
        self.required = required
    }

    public static let controlOption = HoldToTalkCombination(required: [.maskControl, .maskAlternate])

    /// How Saathi says it out loud.
    public var spoken: String {
        var parts: [String] = []
        if required.contains(.maskControl) { parts.append("control") }
        if required.contains(.maskAlternate) { parts.append("option") }
        if required.contains(.maskShift) { parts.append("shift") }
        if required.contains(.maskCommand) { parts.append("command") }
        return parts.joined(separator: " and ")
    }
}

public enum HoldToTalkEvent: Equatable, Sendable {
    case began
    case ended
}

/// Feeds on modifier-flag changes, emits began when every required key is down and ended when
/// any of them lifts. Extra keys held alongside are ignored.
public struct HoldToTalkTracker: Equatable, Sendable {
    public let combination: HoldToTalkCombination
    public private(set) var isHeld = false

    public init(combination: HoldToTalkCombination = .controlOption) {
        self.combination = combination
    }

    public mutating func update(flags: CGEventFlags) -> HoldToTalkEvent? {
        let allDown = flags.intersection(combination.required) == combination.required
        switch (isHeld, allDown) {
        case (false, true):
            isHeld = true
            return .began
        case (true, false):
            isHeld = false
            return .ended
        default:
            return nil
        }
    }
}

/// What the four shortcuts on the Home panel ask for.
public enum ShortcutEvent: Equatable, Sendable {
    /// Talk: control and option held.
    case talkBegan, talkEnded
    /// Dictate: fn and control held. `dictateEnded` types what was said; `dictateCancelled` is a
    /// press too short to have been speech — the first half of a Hands-free double tap, usually.
    case dictateBegan, dictateEnded, dictateCancelled
    /// Text: control tapped twice on its own.
    case textRequested
    /// Hands-free: fn and control tapped twice.
    case handsFreeToggled
}

/// All four shortcuts, from modifier changes, ordinary key presses and the time. Pure, so every
/// timing rule is a test rather than something found by pressing keys.
///
/// A tap is a press shorter than `tapLimit` with nothing else in it; a double tap is a second tap
/// starting within `doubleTapWindow` of the first ending. Any ordinary key while control is down
/// spoils the tap, so control-C is never a Text tap, and another modifier joining does too.
public struct ShortcutTracker: Equatable, Sendable {
    public static let tapLimit: TimeInterval = 0.3
    public static let doubleTapWindow: TimeInterval = 0.4

    private var talk = HoldToTalkTracker(combination: .controlOption)
    private var dictateSince: TimeInterval?
    private var lastDictateTap: TimeInterval?
    /// Set by a Hands-free toggle, so its second press does not also start a dictation.
    private var dictateSpent = false
    private var controlSince: TimeInterval?
    private var controlSpoiled = false
    private var lastControlTap: TimeInterval?

    public init() {}

    public var isTalking: Bool { talk.isHeld }
    public var isDictating: Bool { dictateSince != nil }

    public mutating func keyPressed() {
        controlSpoiled = true
        lastControlTap = nil
        lastDictateTap = nil
    }

    public mutating func update(flags: CGEventFlags, at time: TimeInterval) -> [ShortcutEvent] {
        var events: [ShortcutEvent] = []
        let control = flags.contains(.maskControl)
        let option = flags.contains(.maskAlternate)
        let fn = flags.contains(.maskSecondaryFn)
        let others = flags.contains(.maskCommand) || flags.contains(.maskShift)

        // Talk first: it is the shortcut people already use, and it wins over a dictation that
        // was starting on the same keys.
        switch talk.update(flags: flags) {
        case .began?:
            if dictateSince != nil { dictateSince = nil; events.append(.dictateCancelled) }
            events.append(.talkBegan)
        case .ended?:
            events.append(.talkEnded)
        case nil:
            break
        }

        // Dictate, and Hands-free as its double tap.
        let dictateChord = control && fn && !option && !talk.isHeld
        if dictateChord, dictateSince == nil, !dictateSpent {
            if let last = lastDictateTap, time - last <= Self.doubleTapWindow {
                lastDictateTap = nil
                dictateSpent = true
                events.append(.handsFreeToggled)
            } else {
                dictateSince = time
                events.append(.dictateBegan)
            }
        } else if !dictateChord, let since = dictateSince {
            dictateSince = nil
            if time - since < Self.tapLimit {
                lastDictateTap = time
                events.append(.dictateCancelled)
            } else {
                lastDictateTap = nil
                events.append(.dictateEnded)
            }
        }
        if !control && !fn { dictateSpent = false }

        // Text: control on its own, tapped twice.
        if control {
            if controlSince == nil {
                controlSince = time
                controlSpoiled = option || fn || others
            } else if option || fn || others {
                controlSpoiled = true
            }
        } else if let since = controlSince {
            controlSince = nil
            if !controlSpoiled, time - since < Self.tapLimit {
                if let last = lastControlTap, time - last <= Self.doubleTapWindow + Self.tapLimit {
                    lastControlTap = nil
                    events.append(.textRequested)
                } else {
                    lastControlTap = time
                }
            } else {
                lastControlTap = nil
            }
        }
        return events
    }
}

public enum HoldToTalkError: Error, Equatable, CustomStringConvertible {
    case notPermitted
    case tapFailed

    public var description: String {
        switch self {
        case .notPermitted: return "Input Monitoring is not granted, so Saathi cannot notice the keys"
        case .tapFailed: return "the system refused to install the key monitor"
        }
    }
}

/// What the tap actually points at. It is retained by the tap for as long as the tap exists and
/// only weakly reaches the monitor, so a callback that races the monitor's deinit finds nil
/// instead of freed memory.
private final class TapRelay {
    weak var monitor: HoldToTalkMonitor?
    init(_ monitor: HoldToTalkMonitor) { self.monitor = monitor }
}

/// The event tap. Main-thread only for `start()` (enforced) and `handle()`; `stop()` and
/// `deinit` may run anywhere because they never touch the tracker and the relay is released
/// on the main queue.
public final class HoldToTalkMonitor {

    public static func isPermitted() -> Bool {
        Permissions.status(of: .inputMonitoring) == .granted
    }

    /// Shows the system prompt the first time; afterwards the answer is remembered and this just
    /// reports it.
    public static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    private var tracker = ShortcutTracker()
    private let onEvent: (ShortcutEvent) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var relay: UnsafeMutableRawPointer?

    public init(onEvent: @escaping (ShortcutEvent) -> Void) {
        self.onEvent = onEvent
    }

    public func start() throws {
        precondition(Thread.isMainThread, "HoldToTalkMonitor is main-thread only")
        guard tap == nil else { return }
        guard Self.isPermitted() else { throw HoldToTalkError.notPermitted }

        // Key presses too, only so a control-C spoils a control tap; nothing is read from them.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passRetained(TapRelay(self)).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<TapRelay>.fromOpaque(refcon).takeUnretainedValue().monitor?.handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Unmanaged<TapRelay>.fromOpaque(refcon).release()
            throw HoldToTalkError.tapFailed
        }
        self.tap = tap
        self.relay = refcon
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let relay {
            DispatchQueue.main.async { Unmanaged<TapRelay>.fromOpaque(relay).release() }
        }
        tap = nil
        source = nil
        relay = nil
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables a tap that is slow to respond, and after sleep; re-enable and go on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown {
            tracker.keyPressed()
            return
        }
        for change in tracker.update(flags: event.flags, at: ProcessInfo.processInfo.systemUptime) {
            onEvent(change)
        }
    }
}
