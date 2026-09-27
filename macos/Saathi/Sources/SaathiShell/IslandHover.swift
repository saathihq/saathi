//
//  IslandHover.swift
//  SaathiShell
//
//  When the island is down and when it goes back up. Two things open it: the pointer reaching the
//  top of the screen, which opens it fully and at once, and Saathi being busy, which opens a
//  compact strip on its own. Both close on a grace period rather than immediately, so a pointer
//  that skims past the edge does not make the island flicker. Pure and clock-free: time is an
//  argument, so this is all checkable with numbers.
//

import Foundation

public enum IslandState: Equatable {
    /// Nothing but the notch (or the handle): the resting state.
    case collapsed
    /// A narrow strip that opens by itself while Saathi is listening, thinking or speaking.
    case compact
    /// The full island, opened by the pointer.
    case open
}

public struct IslandHover: Equatable {

    /// How long the island stays down after the reason for it being down goes away.
    public var grace: TimeInterval = 0.4

    public private(set) var state: IslandState = .collapsed

    private var hovering = false
    private var busy = false
    /// When the pending collapse is due; nil when nothing is pending.
    private var collapseAt: TimeInterval?

    public init() {}

    /// Where the island settles once every grace period has run out.
    private var resting: IslandState { busy ? .compact : .collapsed }

    /// Pointer inside the hover rect or not. Opening is immediate; leaving arms the grace.
    ///
    /// Only a *change* counts. The panel polls this every 50 ms, so a plain `false` every tick
    /// would re-arm the grace for ever and the island would never come back up.
    @discardableResult
    public mutating func setHovering(_ hovering: Bool, now: TimeInterval) -> IslandState {
        guard hovering != self.hovering else { return state }
        self.hovering = hovering
        if hovering {
            state = .open
            collapseAt = nil
        } else {
            collapseAt = now + grace
        }
        return state
    }

    /// Listening / thinking / speaking / alerting is busy. Becoming busy opens the compact strip
    /// (unless the pointer is there, which keeps the island fully open); becoming idle arms the
    /// grace. As with hovering, only a change counts.
    @discardableResult
    public mutating func setBusy(_ busy: Bool, now: TimeInterval) -> IslandState {
        guard busy != self.busy else { return state }
        self.busy = busy
        if busy {
            if !hovering, state == .open, collapseAt != nil {
                // The pointer has just left and the open island is living out its grace. Let it:
                // the grace ends in `resting`, which is now the strip. Snapping to the strip here
                // cut the grace short the instant Saathi started listening — which, since leaving
                // the island to hold the keys is the ordinary thing to do, was most of the time.
            } else {
                if !hovering { state = .compact }
                collapseAt = nil
            }
        } else if !hovering {
            collapseAt = now + grace
        }
        return state
    }

    /// Time passing: past the grace, settle to the resting state.
    @discardableResult
    public mutating func tick(now: TimeInterval) -> IslandState {
        if let at = collapseAt, now >= at {
            collapseAt = nil
            state = hovering ? .open : resting
        }
        return state
    }
}
