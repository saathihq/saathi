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

    private var tracker: HoldToTalkTracker
    private let onEvent: (HoldToTalkEvent) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var relay: UnsafeMutableRawPointer?

    public init(combination: HoldToTalkCombination = .controlOption, onEvent: @escaping (HoldToTalkEvent) -> Void) {
        self.tracker = HoldToTalkTracker(combination: combination)
        self.onEvent = onEvent
    }

    public func start() throws {
        precondition(Thread.isMainThread, "HoldToTalkMonitor is main-thread only")
        guard tap == nil else { return }
        guard Self.isPermitted() else { throw HoldToTalkError.notPermitted }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
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
        if let change = tracker.update(flags: event.flags) {
            onEvent(change)
        }
    }
}
