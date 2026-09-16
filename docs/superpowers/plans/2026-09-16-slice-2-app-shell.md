# Slice 2: App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn `Saathi.app` from a CLI in a bundle into a menu-bar app with a notch panel and a pointer companion that show the character's state while the existing voice session runs, driven by holding control and option.

**Architecture:** Testable logic goes into libraries; the executable is three lines. `SaathiKit` gains the pure `CompanionStateMachine`, the `HoldToTalkTracker` (pure) plus its `CGEventTap` monitor, `Permissions`, a `SerialTaskQueue` that fixes the speaker race, and an `ObservedSpeaker` wrapper that reports speech start and stop. A new `SaathiShell` library (Kit + Mascot) holds the state-to-expression table, pure geometry for the panels, the two `NSPanel`s, the menu-bar controller, and an `AppController` that wires everything. `SaathiApp` is the executable. The release script learns to ship both executables and the mascot resource bundle so the app can be launched through LaunchServices, which is what makes permission prompts attribute to Saathi.

**Tech Stack:** Swift 5.9 package, macOS 13 floor, AppKit, Core Graphics event taps, AVFoundation, Speech, ServiceManagement (`SMAppService`), XCTest. No third-party packages.

**Spec:** `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md`, sections "Architecture", "State", "Push-to-talk", "Permissions", "Surfaces" (menu-bar item, notch panel, companion panel), "Error handling" and "Bundle and release" (the layout part). Onboarding cards and the trial are slices 3 and 4.

## Global Constraints

- Package: `macos/Saathi/Package.swift`, `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. Every API above macOS 13 is guarded with `#available`. No third-party packages.
- Tests are XCTest, run with `cd macos/Saathi && swift test`. All 117 existing tests must keep passing.
- `SaathiKit` must not import `SaathiMascot` or AppKit UI; `SaathiMascot` must not import `SaathiKit`. Only `SaathiShell` sees both.
- Every AppKit class in `SaathiShell` is `@MainActor`. Voice callbacks arrive on arbitrary threads and must hop to the main actor before touching state or views.
- Hold-to-talk is control and option held together, as `CGEventFlags` `[.maskControl, .maskAlternate]`, via a listen-only `CGEventTap`; it needs Input Monitoring and must never install without it.
- The state word strings are exactly: Asleep, Ready, Listening, Thinking, Speaking, "Step N of M", Done, the alert message, Bye.
- Commit messages: plain sentence title, short body, and every commit ends with these two trailer lines, character for character:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6
  ```
- Two spec deviations are ruled on in this plan and amended in the spec in Task 6: the state-to-expression table lives in `SaathiShell` (Kit cannot see `MascotExpression`), and speech observation is an `ObservedSpeaker` wrapper rather than a change to the `Speaker` protocol.

---

## File map

| Path | Responsibility |
|---|---|
| `macos/Saathi/Sources/SaathiKit/SerialTaskQueue.swift` | Create: run async operations one at a time, cancellable. |
| `macos/Saathi/Sources/SaathiKit/Speakers.swift` | Modify: `SystemSpeaker` uses the queue; add `ObservedSpeaker`. |
| `macos/Saathi/Sources/SaathiKit/CompanionState.swift` | Create: `CompanionState`, `CompanionEvent`, `CompanionStateMachine`. |
| `macos/Saathi/Sources/SaathiKit/HoldToTalk.swift` | Create: `HoldToTalkCombination`, `HoldToTalkTracker`, `HoldToTalkMonitor`. |
| `macos/Saathi/Sources/SaathiKit/Permissions.swift` | Create: `Permission`, `PermissionStatus`, `Permissions`. |
| `macos/Saathi/Sources/SaathiMascot/MascotData.swift` | Modify: add `bodyOutline()`. |
| `macos/Saathi/Sources/SaathiShell/ExpressionTable.swift` | Create: `CompanionState.mascotExpression`. |
| `macos/Saathi/Sources/SaathiShell/PointerFollower.swift` | Create: eased pointer following, pure. |
| `macos/Saathi/Sources/SaathiShell/NotchGeometry.swift` | Create: where the notch panel sits, pure. |
| `macos/Saathi/Sources/SaathiShell/MenuBarIcon.swift` | Create: the 16 pt template image from the body path. |
| `macos/Saathi/Sources/SaathiShell/CompanionPanel.swift` | Create: the floating click-through mascot. |
| `macos/Saathi/Sources/SaathiShell/NotchPanel.swift` | Create: the notch / pill panel with the state word. |
| `macos/Saathi/Sources/SaathiShell/MenuBarController.swift` | Create: status item and menu. |
| `macos/Saathi/Sources/SaathiShell/AppController.swift` | Create: wiring of config, voice session, state machine, monitor, panels, menu. |
| `macos/Saathi/Sources/SaathiApp/main.swift` | Create: the executable. |
| `macos/Saathi/Package.swift` | Modify: `SaathiShell`, `SaathiApp`, `SaathiShellTests`. |
| `macos/Saathi/scripts/release.sh`, `macos/Saathi/Resources/Info.plist` | Modify: bundle layout with both executables and the resource bundle. |
| `macos/Saathi/Tests/SaathiKitTests/{SerialTaskQueueTests,SpeakerTests,CompanionStateTests,HoldToTalkTests,PermissionsTests}.swift` | Tests. |
| `macos/Saathi/Tests/SaathiShellTests/{ExpressionTableTests,PointerFollowerTests,NotchGeometryTests,MenuBarIconTests,PanelTests}.swift` | Tests. |

---

### Task 1: The speaker runs one utterance at a time, and reports when it speaks

**Files:**
- Create: `macos/Saathi/Sources/SaathiKit/SerialTaskQueue.swift`
- Modify: `macos/Saathi/Sources/SaathiKit/Speakers.swift` (the `SystemSpeaker` class; add `ObservedSpeaker` after it)
- Test: `macos/Saathi/Tests/SaathiKitTests/SerialTaskQueueTests.swift`
- Test: `macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift` (append)

**Interfaces:**
- Consumes: `Speaker` protocol (`func speak(_ text: String, tone: Tone) async`), `RecordingSpeaker` (tests), `UtteranceWaiter` (existing).
- Produces: `public final class SerialTaskQueue { public init(); public func run(_ operation: @escaping @Sendable () async -> Void) async }`; `public final class ObservedSpeaker: Speaker { public init(_ inner: any Speaker, onSpeakingChanged: @escaping @Sendable (Bool) -> Void) }`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiKitTests/SerialTaskQueueTests.swift`:

```swift
//
//  SerialTaskQueueTests.swift
//  SaathiKitTests
//

import Foundation
import os
import XCTest
@testable import SaathiKit

final class SerialTaskQueueTests: XCTestCase {

    func testOperationsNeverOverlapEvenWhenCalledConcurrently() async {
        let queue = SerialTaskQueue()
        let tally = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0, finished: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await queue.run {
                        tally.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) }
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        tally.withLock { $0.running -= 1; $0.finished += 1 }
                    }
                }
            }
        }
        let result = tally.withLock { $0 }
        XCTAssertEqual(result.peak, 1, "two operations ran at once")
        XCTAssertEqual(result.finished, 20)
    }

    func testCancellingTheCallerCancelsItsOperation() async {
        let queue = SerialTaskQueue()
        let sawCancellation = OSAllocatedUnfairLock(initialState: false)
        let caller = Task {
            await queue.run {
                let deadline = Date().addingTimeInterval(2)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                sawCancellation.withLock { $0 = Task.isCancelled }
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        caller.cancel()
        await caller.value
        XCTAssertTrue(sawCancellation.withLock { $0 }, "the operation should have seen the cancellation, not run to its deadline")
    }

    func testACancelledCallerThatNeverStartedDoesNotRunItsOperation() async {
        let queue = SerialTaskQueue()
        let ran = OSAllocatedUnfairLock(initialState: false)
        let blocker = Task { await queue.run { try? await Task.sleep(nanoseconds: 150_000_000) } }
        try? await Task.sleep(nanoseconds: 10_000_000)
        let waiting = Task { await queue.run { ran.withLock { $0 = true } } }
        waiting.cancel()
        await waiting.value
        await blocker.value
        XCTAssertFalse(ran.withLock { $0 })
    }
}
```

Append to `macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift`:

```swift

final class ObservedSpeakerTests: XCTestCase {

    func testItReportsStartAndStopAroundTheInnerSpeaker() async {
        let inner = RecordingSpeaker()
        let events = OSAllocatedUnfairLock(initialState: [Bool]())
        let speaker = ObservedSpeaker(inner) { speaking in events.withLock { $0.append(speaking) } }
        await speaker.speak("hello", tone: .calm)
        XCTAssertEqual(events.withLock { $0 }, [true, false])
        XCTAssertEqual(inner.lines, [RecordingSpeaker.Line(text: "hello", tone: .calm)])
    }

    func testStopIsReportedEvenIfTheInnerSpeakerIsCancelled() async {
        struct Slow: Speaker {
            func speak(_ text: String, tone: Tone) async { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        let events = OSAllocatedUnfairLock(initialState: [Bool]())
        let speaker = ObservedSpeaker(Slow()) { speaking in events.withLock { $0.append(speaking) } }
        let task = Task { await speaker.speak("x", tone: .neutral) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await task.value
        XCTAssertEqual(events.withLock { $0 }, [true, false])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter "SerialTaskQueueTests|ObservedSpeakerTests" 2>&1 | tail -3`
Expected: compile errors, `cannot find 'SerialTaskQueue'` and `cannot find 'ObservedSpeaker'`.

- [ ] **Step 3: Write the queue**

Create `macos/Saathi/Sources/SaathiKit/SerialTaskQueue.swift`:

```swift
//
//  SerialTaskQueue.swift
//  SaathiKit
//
//  Runs async operations strictly one after another, in the order they were chained, with a
//  caller's cancellation reaching its own operation. The chaining happens under ONE lock
//  acquisition — read the tail, create the successor, store it — so two callers cannot both see
//  the same predecessor and then run side by side, which is the race an earlier version had.
//

import Foundation
import os

public final class SerialTaskQueue: @unchecked Sendable {

    private struct State {
        var tail: Task<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func run(_ operation: @escaping @Sendable () async -> Void) async {
        let task: Task<Void, Never> = state.withLock { box in
            let previous = box.tail
            let next = Task {
                await previous?.value
                guard !Task.isCancelled else { return }
                await operation()
            }
            box.tail = next
            return next
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
```

- [ ] **Step 4: Use it in `SystemSpeaker`, and add `ObservedSpeaker`**

In `macos/Saathi/Sources/SaathiKit/Speakers.swift`, replace the `SystemSpeaker` class body from `private let synthesizer` down to the end of `speak` (keep `say` and the comment above it) with:

```swift
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = SerialTaskQueue()

    public init() {}

    // Two overlapping calls run one after the other instead of the first being stranded, and a
    // caller's cancellation reaches the utterance it is waiting on (see `say`).
    public func speak(_ text: String, tone: Tone) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        switch tone {
        case .calm:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
            utterance.pitchMultiplier = 0.95
        case .encouraging:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.08
        case .neutral:
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
        }

        await queue.run { await self.say(utterance) }
    }
```

Delete the old `private struct State { var inFlight ... }` and `private let state = OSAllocatedUnfairLock(...)` from `SystemSpeaker`. Then add, after the `SystemSpeaker` class and before `UtteranceWaiter`:

```swift
/// Wraps any speaker and reports when speech starts and stops, so the companion's face can follow
/// its own voice without the speaker protocol knowing about faces. Stop is reported on every exit,
/// including cancellation.
public final class ObservedSpeaker: Speaker, @unchecked Sendable {
    private let inner: any Speaker
    private let onSpeakingChanged: @Sendable (Bool) -> Void

    public init(_ inner: any Speaker, onSpeakingChanged: @escaping @Sendable (Bool) -> Void) {
        self.inner = inner
        self.onSpeakingChanged = onSpeakingChanged
    }

    public func speak(_ text: String, tone: Tone) async {
        onSpeakingChanged(true)
        defer { onSpeakingChanged(false) }
        await inner.speak(text, tone: tone)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -2`
Expected: `Executed 122 tests, with 0 failures` (117 + 3 + 2).

- [ ] **Step 6: Audible check**

Run: `cd macos/Saathi && swift build 2>&1 | grep -E "error|warning" ; ./.build/debug/saathi say "One at a time." --tone=calm`
Expected: audible, no build warnings.

- [ ] **Step 7: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiKit/SerialTaskQueue.swift macos/Saathi/Sources/SaathiKit/Speakers.swift macos/Saathi/Tests/SaathiKitTests/SerialTaskQueueTests.swift macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift
git commit -m "SystemSpeaker: chain utterances under one lock, and let a wrapper watch them

The previous serialisation read the in-flight task and registered the next one under two
separate lock acquisitions, so two truly concurrent calls could both see the same predecessor
and run side by side; and the inner task was unstructured, so a caller's cancellation never
reached stopSpeaking. SerialTaskQueue does the chaining atomically and propagates
cancellation. ObservedSpeaker reports start and stop around any speaker so the app shell can
show a speaking face without the Speaker protocol learning about faces.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 2: The companion state machine

**Files:**
- Create: `macos/Saathi/Sources/SaathiKit/CompanionState.swift`
- Test: `macos/Saathi/Tests/SaathiKitTests/CompanionStateTests.swift`

**Interfaces:**
- Consumes: `SaathiAction`, `ShowStepAction`, `SayAction` from `SaathiContract`.
- Produces:
  ```swift
  public enum CompanionState: Equatable, Sendable { case asleep, idle, listening, thinking, speaking, showingStep(index: Int, total: Int), celebrating, alert(String), poweringDown; public var word: String }
  public enum CompanionEvent: Equatable, Sendable { case keysHeld, keysReleased, talkPressed, status(String), userSpoke(String), saathiSpoke(String), action(SaathiAction), speakingChanged(Bool), failure(String), quit }
  public struct CompanionStateMachine: Equatable, Sendable {
      public private(set) var state: CompanionState
      public var idleDelay: TimeInterval      // 2
      public var sleepAfter: TimeInterval     // 180
      public init(now: TimeInterval, state: CompanionState = .idle)
      @discardableResult public mutating func apply(_ event: CompanionEvent, now: TimeInterval) -> CompanionState
      @discardableResult public mutating func tick(now: TimeInterval) -> CompanionState
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiKitTests/CompanionStateTests.swift`:

```swift
//
//  CompanionStateTests.swift
//  SaathiKitTests
//
//  The face follows the voice session. These pin the folding of session events into a state,
//  with time passed in rather than read, so every transition is a plain function of its inputs.
//

import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class CompanionStateTests: XCTestCase {

    private var machine = CompanionStateMachine(now: 1_000)

    func testHoldingTheKeysListensAndReleasingThinks() {
        XCTAssertEqual(machine.apply(.keysHeld, now: 1_001), .listening)
        XCTAssertEqual(machine.apply(.keysReleased, now: 1_003), .thinking)
    }

    func testReleasingTheKeysWhenNotListeningChangesNothing() {
        XCTAssertEqual(machine.apply(.keysReleased, now: 1_001), .idle)
    }

    func testTheTalkMenuItemToggles() {
        XCTAssertEqual(machine.apply(.talkPressed, now: 1_001), .listening)
        XCTAssertEqual(machine.apply(.talkPressed, now: 1_002), .thinking)
    }

    func testTheLanesStatusLinesDriveTheState() {
        XCTAssertEqual(machine.apply(.status("listening…"), now: 1_001), .listening)
        XCTAssertEqual(machine.apply(.status("thinking…"), now: 1_002), .thinking)
        XCTAssertEqual(machine.apply(.status("ready — on-device speech recognition (en_US)"), now: 1_003), .thinking, "a readiness note is not a state")
        XCTAssertEqual(machine.apply(.status("did not catch that"), now: 1_004), .alert("did not catch that"))
    }

    func testAnAlertGivesWayToIdleAfterTwiceTheIdleDelay() {
        machine.apply(.failure("no model reachable"), now: 1_000)
        XCTAssertEqual(machine.state, .alert("no model reachable"))
        XCTAssertEqual(machine.tick(now: 1_003), .alert("no model reachable"))
        XCTAssertEqual(machine.tick(now: 1_004), .idle)
    }

    func testSpeakingThenSilenceSettlesToIdleAfterTheDelay() {
        XCTAssertEqual(machine.apply(.speakingChanged(true), now: 1_000), .speaking)
        XCTAssertEqual(machine.apply(.speakingChanged(false), now: 1_005), .speaking, "the face holds for a moment")
        XCTAssertEqual(machine.tick(now: 1_006.9), .speaking)
        XCTAssertEqual(machine.tick(now: 1_007), .idle)
    }

    func testARealtimeReplyCountsAsSpeaking() {
        XCTAssertEqual(machine.apply(.saathiSpoke("Sure."), now: 1_000), .speaking)
        XCTAssertEqual(machine.tick(now: 1_002), .idle)
    }

    func testAStepShowsAndKeepsShowingWhileNarrated() {
        let step = ShowStepAction(title: "Open the lid", index: 2, total: 3)
        XCTAssertEqual(machine.apply(.action(.showStep(step)), now: 1_000), .showingStep(index: 2, total: 3))
        XCTAssertEqual(machine.apply(.speakingChanged(true), now: 1_000.1), .showingStep(index: 2, total: 3))
        XCTAssertEqual(machine.apply(.speakingChanged(false), now: 1_004), .showingStep(index: 2, total: 3))
        XCTAssertEqual(machine.tick(now: 1_006), .idle)
    }

    func testTheLastStepCelebrates() {
        let last = ShowStepAction(title: "Tell Saathi how that went", index: 3, total: 3)
        XCTAssertEqual(machine.apply(.action(.showStep(last)), now: 1_000), .celebrating)
    }

    func testASayActionWaitsForTheSpeakerToReport() {
        XCTAssertEqual(machine.apply(.action(.say(SayAction(text: "Hi"))), now: 1_000), .idle)
        XCTAssertEqual(machine.apply(.speakingChanged(true), now: 1_000.1), .speaking)
    }

    func testQuietForThreeMinutesFallsAsleepAndAnyEventWakes() {
        XCTAssertEqual(machine.tick(now: 1_179), .idle)
        XCTAssertEqual(machine.tick(now: 1_180), .asleep)
        XCTAssertEqual(machine.apply(.keysHeld, now: 1_181), .listening)
    }

    func testTheUsersWordsMeanThinking() {
        machine.apply(.keysHeld, now: 1_000)
        XCTAssertEqual(machine.apply(.userSpoke("hello"), now: 1_002), .thinking)
    }

    func testPoweringDownIsTerminal() {
        XCTAssertEqual(machine.apply(.quit, now: 1_000), .poweringDown)
        XCTAssertEqual(machine.apply(.keysHeld, now: 1_001), .poweringDown)
        XCTAssertEqual(machine.tick(now: 2_000), .poweringDown)
    }

    func testTheWords() {
        XCTAssertEqual(CompanionState.idle.word, "Ready")
        XCTAssertEqual(CompanionState.showingStep(index: 2, total: 5).word, "Step 2 of 5")
        XCTAssertEqual(CompanionState.alert("no model reachable").word, "no model reachable")
        XCTAssertEqual(CompanionState.poweringDown.word, "Bye")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter CompanionStateTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'CompanionStateMachine'`.

- [ ] **Step 3: Write the state machine**

Create `macos/Saathi/Sources/SaathiKit/CompanionState.swift`:

```swift
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
        lastActivity = now
        settleAt = nil

        switch event {
        case .quit:
            state = .poweringDown
        case .keysHeld:
            state = .listening
        case .keysReleased:
            if state == .listening { state = .thinking }
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
            switch action {
            case let .showStep(step):
                state = step.index >= step.total
                    ? .celebrating
                    : .showingStep(index: step.index, total: step.total)
            case .say, .openUrl:
                break   // the speaker reports when it starts
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter CompanionStateTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 14 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiKit/CompanionState.swift macos/Saathi/Tests/SaathiKitTests/CompanionStateTests.swift
git commit -m "CompanionState: fold the voice session's events into what the face should show

A pure state machine with time as an argument: keys held means listening, released means
thinking, the lanes' status lines and the speaker's start/stop drive the rest, a shown step
holds while it is narrated, the last step celebrates, an alert and a spoken line settle back to
idle after a delay, three quiet minutes fall asleep. The state word lives here too, so the
notch and VoiceOver say the same thing the face shows.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 3: Hold-to-talk and permissions

**Files:**
- Create: `macos/Saathi/Sources/SaathiKit/HoldToTalk.swift`
- Create: `macos/Saathi/Sources/SaathiKit/Permissions.swift`
- Test: `macos/Saathi/Tests/SaathiKitTests/HoldToTalkTests.swift`
- Test: `macos/Saathi/Tests/SaathiKitTests/PermissionsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct HoldToTalkCombination: Equatable, Sendable { public var required: CGEventFlags; public static let controlOption; public var spoken: String }
  public enum HoldToTalkEvent: Equatable, Sendable { case began, ended }
  public struct HoldToTalkTracker: Equatable, Sendable { public init(combination:); public private(set) var isHeld: Bool; public mutating func update(flags: CGEventFlags) -> HoldToTalkEvent? }
  public enum HoldToTalkError: Error, Equatable { case notPermitted, tapFailed }
  public final class HoldToTalkMonitor { public static func isPermitted() -> Bool; public static func requestPermission() -> Bool; public init(combination:onEvent:); public func start() throws; public func stop() }
  public enum PermissionStatus: Equatable, Sendable { case granted, denied, notDetermined }
  public enum Permission: CaseIterable, Equatable, Sendable { case microphone, speechRecognition, inputMonitoring; public var title: String; public var reason: String; public var settingsURL: URL }
  public enum Permissions { public static func status(of:) -> PermissionStatus; public static func request(_:) async -> PermissionStatus }
  ```

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiKitTests/HoldToTalkTests.swift`:

```swift
//
//  HoldToTalkTests.swift
//  SaathiKitTests
//
//  The tracker is the whole decision; the monitor only feeds it flag changes from an event tap.
//

import CoreGraphics
import XCTest
@testable import SaathiKit

final class HoldToTalkTrackerTests: XCTestCase {

    private var tracker = HoldToTalkTracker()

    func testBothKeysDownBeginsAndEitherUpEnds() {
        XCTAssertNil(tracker.update(flags: [.maskControl]))
        XCTAssertEqual(tracker.update(flags: [.maskControl, .maskAlternate]), .began)
        XCTAssertTrue(tracker.isHeld)
        XCTAssertNil(tracker.update(flags: [.maskControl, .maskAlternate, .maskShift]), "an extra key does not end the hold")
        XCTAssertEqual(tracker.update(flags: [.maskAlternate]), .ended)
        XCTAssertFalse(tracker.isHeld)
    }

    func testRepeatedFlagChangesWhileHeldAreQuiet() {
        _ = tracker.update(flags: [.maskControl, .maskAlternate])
        XCTAssertNil(tracker.update(flags: [.maskControl, .maskAlternate]))
        XCTAssertNil(tracker.update(flags: [.maskControl, .maskAlternate, .maskCommand]))
    }

    func testOtherModifiersAloneNeverBegin() {
        XCTAssertNil(tracker.update(flags: [.maskCommand, .maskShift]))
        XCTAssertNil(tracker.update(flags: [.maskAlternate, .maskCommand]))
    }

    func testTheCombinationHasASpokenName() {
        XCTAssertEqual(HoldToTalkCombination.controlOption.spoken, "control and option")
    }
}
```

Create `macos/Saathi/Tests/SaathiKitTests/PermissionsTests.swift`:

```swift
//
//  PermissionsTests.swift
//  SaathiKitTests
//

import AVFoundation
import Speech
import XCTest
@testable import SaathiKit

final class PermissionsTests: XCTestCase {

    func testEveryPermissionExplainsItselfAndKnowsItsSettingsPane() {
        for permission in Permission.allCases {
            XCTAssertFalse(permission.title.isEmpty)
            XCTAssertFalse(permission.reason.isEmpty, "\(permission) has no reason")
            XCTAssertEqual(permission.settingsURL.scheme, "x-apple.systempreferences", "\(permission)")
            XCTAssertTrue(permission.settingsURL.absoluteString.contains("Privacy_"), "\(permission)")
        }
    }

    func testMicrophoneStatusesMap() {
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.denied), .denied)
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.restricted), .denied)
        XCTAssertEqual(Permissions.map(AVAuthorizationStatus.notDetermined), .notDetermined)
    }

    func testSpeechStatusesMap() {
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.authorized), .granted)
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.denied), .denied)
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.restricted), .denied)
        XCTAssertEqual(Permissions.map(SFSpeechRecognizerAuthorizationStatus.notDetermined), .notDetermined)
    }

    func testStatusOfInputMonitoringNeverThrowsAndIsNeverDenied() {
        // The API cannot tell "asked and refused" from "never asked", so we never claim denied.
        XCTAssertNotEqual(Permissions.status(of: .inputMonitoring), .denied)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter "HoldToTalkTrackerTests|PermissionsTests" 2>&1 | tail -3`
Expected: compile errors for `HoldToTalkTracker` and `Permissions`.

- [ ] **Step 3: Write hold-to-talk**

Create `macos/Saathi/Sources/SaathiKit/HoldToTalk.swift`:

```swift
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

/// The event tap. Main-thread only: the run-loop source is added to the main run loop and the
/// callback runs there.
public final class HoldToTalkMonitor {

    public static func isPermitted() -> Bool {
        CGPreflightListenEventAccess()
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

    public init(combination: HoldToTalkCombination = .controlOption, onEvent: @escaping (HoldToTalkEvent) -> Void) {
        self.tracker = HoldToTalkTracker(combination: combination)
        self.onEvent = onEvent
    }

    public func start() throws {
        guard tap == nil else { return }
        guard Self.isPermitted() else { throw HoldToTalkError.notPermitted }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<HoldToTalkMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw HoldToTalkError.tapFailed
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
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
```

- [ ] **Step 4: Write permissions**

Create `macos/Saathi/Sources/SaathiKit/Permissions.swift`:

```swift
//
//  Permissions.swift
//  SaathiKit
//
//  The three things Saathi asks macOS for, each with the one-line reason it gives, so the shell,
//  onboarding and the menu all say the same words.
//

import AVFoundation
import CoreGraphics
import Foundation
import Speech

public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public enum Permission: CaseIterable, Equatable, Sendable {
    case microphone
    case speechRecognition
    case inputMonitoring

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .inputMonitoring: return "Input Monitoring"
        }
    }

    /// Spoken and shown when asking. One line, Saathi's voice.
    public var reason: String {
        switch self {
        case .microphone: return "This lets me hear you. Only while you hold the keys."
        case .speechRecognition: return "Turns your voice into words on this Mac. Nothing is sent anywhere."
        case .inputMonitoring: return "Lets me notice when you hold control and option, in any app."
        }
    }

    /// The System Settings pane that holds the switch.
    public var settingsURL: URL {
        let pane: String
        switch self {
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
}

public enum Permissions {

    public static func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone:
            return map(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return map(SFSpeechRecognizer.authorizationStatus())
        case .inputMonitoring:
            // The API answers yes or no; it cannot tell "refused" from "never asked".
            return CGPreflightListenEventAccess() ? .granted : .notDetermined
        }
    }

    /// Prompts if the system will, then reports what it decided.
    public static func request(_ permission: Permission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return status(of: .microphone)
        case .speechRecognition:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: map($0)) }
            }
        case .inputMonitoring:
            return CGRequestListenEventAccess() ? .granted : .notDetermined
        }
    }

    static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -2`
Expected: `Executed 144 tests, with 0 failures` (136 + 4 + 4).

- [ ] **Step 6: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiKit/HoldToTalk.swift macos/Saathi/Sources/SaathiKit/Permissions.swift macos/Saathi/Tests/SaathiKitTests/HoldToTalkTests.swift macos/Saathi/Tests/SaathiKitTests/PermissionsTests.swift
git commit -m "Hold control and option to talk, and the three permissions with their reasons

HoldToTalkTracker decides began/ended from modifier flags and is tested as numbers;
HoldToTalkMonitor is the listen-only event tap that feeds it, which needs Input Monitoring and
refuses to install without it. Permissions names microphone, speech recognition and input
monitoring with the one-line reason Saathi gives for each and the System Settings pane that
holds the switch.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 4: The `SaathiShell` target and its pure pieces

**Files:**
- Modify: `macos/Saathi/Package.swift`
- Modify: `macos/Saathi/Sources/SaathiMascot/MascotData.swift` (add `bodyOutline()`)
- Create: `macos/Saathi/Sources/SaathiShell/ExpressionTable.swift`
- Create: `macos/Saathi/Sources/SaathiShell/PointerFollower.swift`
- Create: `macos/Saathi/Sources/SaathiShell/NotchGeometry.swift`
- Create: `macos/Saathi/Sources/SaathiShell/MenuBarIcon.swift`
- Create: `macos/Saathi/Sources/SaathiApp/main.swift` (stub until Task 6)
- Test: `macos/Saathi/Tests/SaathiShellTests/ExpressionTableTests.swift`, `PointerFollowerTests.swift`, `NotchGeometryTests.swift`, `MenuBarIconTests.swift`

**Interfaces:**
- Consumes: `CompanionState` (Task 2), `MascotExpression`, `MascotData`, `SVGPath` (internal to SaathiMascot; hence the new public `bodyOutline()`).
- Produces:
  ```swift
  // SaathiMascot
  extension MascotData { public func bodyOutline() throws -> CGPath }   // already in body-square coordinates (0...2*eyeRefX)
  // SaathiShell
  extension CompanionState { public var mascotExpression: MascotExpression }
  public struct PointerFollower: Equatable { public var offset: CGVector; public var response: TimeInterval; public private(set) var position: CGPoint; public init(start: CGPoint); public mutating func follow(_ pointer: CGPoint, dt: TimeInterval) -> CGPoint; public func origin(forPanelOf size: CGSize) -> CGPoint }
  public enum NotchGeometry { public static let lip: CGFloat; public static let pillWidth: CGFloat; public static let pillHeight: CGFloat; public static func collapsedFrame(screen: CGRect, safeAreaTop: CGFloat, leftAuxiliary: CGRect?, rightAuxiliary: CGRect?) -> CGRect; public static func expandedFrame(collapsed: CGRect, height: CGFloat, minWidth: CGFloat) -> CGRect }
  public enum MenuBarIcon { public static func image(data: MascotData, side: CGFloat = 18) -> NSImage }
  ```

- [ ] **Step 1: Add the targets**

In `macos/Saathi/Package.swift` add to `products`:

```swift
        .library(name: "SaathiShell", targets: ["SaathiShell"]),
        .executable(name: "SaathiApp", targets: ["SaathiApp"]),
```

and to `targets`, after `SaathiMascotTests`:

```swift
        // The app shell: everything with a window in it, as a library so it can be tested. The
        // only target that sees both the voice side (SaathiKit) and the character (SaathiMascot).
        .target(name: "SaathiShell", dependencies: ["SaathiKit", "SaathiMascot"]),

        // The bundle's main executable. Three lines: it exists so LaunchServices has something
        // to launch and TCC has something to attribute permissions to.
        .executableTarget(name: "SaathiApp", dependencies: ["SaathiShell"]),

        .testTarget(name: "SaathiShellTests", dependencies: ["SaathiShell"]),
```

Create `macos/Saathi/Sources/SaathiApp/main.swift` with one line: `// Filled in by Task 6.`

- [ ] **Step 2: Write the failing tests**

Create `macos/Saathi/Tests/SaathiShellTests/ExpressionTableTests.swift`:

```swift
//
//  ExpressionTableTests.swift
//  SaathiShellTests
//

import XCTest
import SaathiKit
import SaathiMascot
@testable import SaathiShell

final class ExpressionTableTests: XCTestCase {

    func testEveryStateHasAFace() {
        let states: [CompanionState] = [
            .asleep, .idle, .listening, .thinking, .speaking,
            .showingStep(index: 1, total: 3), .celebrating, .alert("x"), .poweringDown,
        ]
        let expected: [MascotExpression] = [
            .sleeping, .idle, .listening, .thinking, .dictating,
            .working, .celebrate, .alerting, .poweringDown,
        ]
        XCTAssertEqual(states.map(\.mascotExpression), expected)
    }
}
```

Create `macos/Saathi/Tests/SaathiShellTests/PointerFollowerTests.swift`:

```swift
//
//  PointerFollowerTests.swift
//  SaathiShellTests
//

import XCTest
@testable import SaathiShell

final class PointerFollowerTests: XCTestCase {

    func testNoTimeMeansNoMovement() {
        var follower = PointerFollower(start: CGPoint(x: 100, y: 100))
        XCTAssertEqual(follower.follow(CGPoint(x: 500, y: 500), dt: 0), CGPoint(x: 100, y: 100))
    }

    func testItApproachesThePointerPlusTheOffsetAndGetsThereGivenTime() {
        var follower = PointerFollower(start: CGPoint(x: 0, y: 0))
        let pointer = CGPoint(x: 300, y: 200)
        let target = CGPoint(x: pointer.x + follower.offset.dx, y: pointer.y + follower.offset.dy)
        let first = follower.follow(pointer, dt: 1.0 / 60)
        XCTAssertGreaterThan(first.x, 0)
        XCTAssertLessThan(first.x, target.x)
        for _ in 0..<600 { _ = follower.follow(pointer, dt: 1.0 / 60) }
        XCTAssertEqual(follower.position.x, target.x, accuracy: 0.01)
        XCTAssertEqual(follower.position.y, target.y, accuracy: 0.01)
    }

    func testTheOffsetSitsBelowAndToTheRightOfThePointerInScreenCoordinates() {
        let follower = PointerFollower(start: .zero)
        XCTAssertGreaterThan(follower.offset.dx, 0, "right")
        XCTAssertLessThan(follower.offset.dy, 0, "below — screen y goes up")
    }

    func testThePanelOriginCentresThePanelOnThePosition() {
        var follower = PointerFollower(start: CGPoint(x: 100, y: 100))
        _ = follower.follow(CGPoint(x: 100 - follower.offset.dx, y: 100 - follower.offset.dy), dt: 10)
        XCTAssertEqual(follower.origin(forPanelOf: CGSize(width: 72, height: 72)), CGPoint(x: 64, y: 64))
    }
}
```

Create `macos/Saathi/Tests/SaathiShellTests/NotchGeometryTests.swift`:

```swift
//
//  NotchGeometryTests.swift
//  SaathiShellTests
//

import XCTest
@testable import SaathiShell

final class NotchGeometryTests: XCTestCase {

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testOnANotchedScreenThePanelCoversTheNotchAndALipBelowIt() {
        // A 14-inch MacBook Pro: 32 pt safe area, the notch between the two auxiliary areas.
        let left = CGRect(x: 0, y: 950, width: 656, height: 32)
        let right = CGRect(x: 856, y: 950, width: 656, height: 32)
        let frame = NotchGeometry.collapsedFrame(screen: screen, safeAreaTop: 32, leftAuxiliary: left, rightAuxiliary: right)
        XCTAssertEqual(frame.minX, 656)
        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.maxY, 982, "flush with the top")
        XCTAssertEqual(frame.height, 32 + NotchGeometry.lip)
    }

    func testWithoutANotchItIsAPillUnderTheMenuBar() {
        let frame = NotchGeometry.collapsedFrame(screen: screen, safeAreaTop: 0, leftAuxiliary: nil, rightAuxiliary: nil)
        XCTAssertEqual(frame.midX, screen.midX)
        XCTAssertEqual(frame.width, NotchGeometry.pillWidth)
        XCTAssertEqual(frame.height, NotchGeometry.pillHeight)
        XCTAssertEqual(frame.maxY, 982 - NotchGeometry.menuBarHeight)
    }

    func testExpandingKeepsTheTopEdgeAndGrowsDownAndOut() {
        let collapsed = CGRect(x: 656, y: 922, width: 200, height: 60)
        let expanded = NotchGeometry.expandedFrame(collapsed: collapsed, height: 180, minWidth: 320)
        XCTAssertEqual(expanded.maxY, collapsed.maxY)
        XCTAssertEqual(expanded.height, 180)
        XCTAssertEqual(expanded.width, 320)
        XCTAssertEqual(expanded.midX, collapsed.midX)
    }
}
```

Create `macos/Saathi/Tests/SaathiShellTests/MenuBarIconTests.swift`:

```swift
//
//  MenuBarIconTests.swift
//  SaathiShellTests
//

import AppKit
import XCTest
import SaathiMascot
@testable import SaathiShell

final class MenuBarIconTests: XCTestCase {

    func testTheIconIsATemplateOfTheRightSizeWithSomethingDrawnInIt() throws {
        let image = MenuBarIcon.image(data: try MascotData.load(), side: 18)
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))

        // Draw it into a bitmap of known layout and count the opaque pixels.
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 18, pixelsHigh: 18, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        var opaque = 0
        for y in 0..<18 {
            for x in 0..<18 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
        }
        XCTAssertGreaterThan(opaque, 40, "the pointer should cover a good part of 18×18")
        XCTAssertLessThan(opaque, 18 * 18 - 40, "and not all of it")
    }

    func testTheBodyOutlineIsInTheBodySquare() throws {
        let data = try MascotData.load()
        let box = try data.bodyOutline().boundingBoxOfPath
        XCTAssertGreaterThan(box.minX, 0)
        XCTAssertLessThan(box.maxX, CGFloat(data.eyeRefX) * 2)
        XCTAssertEqual(box.maxY, CGFloat(data.eyeRefX) * 2, accuracy: 0.5)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter "ExpressionTableTests|PointerFollowerTests|NotchGeometryTests|MenuBarIconTests" 2>&1 | tail -3`
Expected: compile errors in the new test target.

- [ ] **Step 4: Add `bodyOutline()` to `MascotData`**

In `macos/Saathi/Sources/SaathiMascot/MascotData.swift`, after `load()`:

```swift
    /// The body outline as a path in the body's own square (0…2·eyeRefX), ready to draw.
    public func bodyOutline() throws -> CGPath {
        var transform = bodyTransform.affine
        let raw = try SVGPath.cgPath(from: bodyPath)
        return raw.copy(using: &transform) ?? raw
    }
```

- [ ] **Step 5: Write the four shell files**

Create `macos/Saathi/Sources/SaathiShell/ExpressionTable.swift`:

```swift
//
//  ExpressionTable.swift
//  SaathiShell
//
//  One face per state. Lives here rather than in SaathiKit because the kit does not know the
//  character exists; this is the only module that sees both.
//

import SaathiKit
import SaathiMascot

public extension CompanionState {
    var mascotExpression: MascotExpression {
        switch self {
        case .asleep: return .sleeping
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .dictating
        case .showingStep: return .working
        case .celebrating: return .celebrate
        case .alert: return .alerting
        case .poweringDown: return .poweringDown
        }
    }
}
```

Create `macos/Saathi/Sources/SaathiShell/PointerFollower.swift`:

```swift
//
//  PointerFollower.swift
//  SaathiShell
//
//  Where the companion sits relative to the pointer, eased so it trails rather than jitters.
//  Screen coordinates (y up). Pure, so the easing can be tested with numbers.
//

import CoreGraphics
import Foundation

public struct PointerFollower: Equatable {
    /// Right of and below the pointer, so it never covers what is being pointed at.
    public var offset = CGVector(dx: 28, dy: -36)
    /// Seconds to close about two-thirds of the remaining gap.
    public var response: TimeInterval = 0.12
    public private(set) var position: CGPoint

    public init(start: CGPoint) {
        position = start
    }

    @discardableResult
    public mutating func follow(_ pointer: CGPoint, dt: TimeInterval) -> CGPoint {
        guard dt > 0 else { return position }
        let target = CGPoint(x: pointer.x + offset.dx, y: pointer.y + offset.dy)
        let k = 1 - exp(-dt / response)
        position.x += (target.x - position.x) * k
        position.y += (target.y - position.y) * k
        return position
    }

    /// The panel's bottom-left so the character is centred on the position.
    public func origin(forPanelOf size: CGSize) -> CGPoint {
        CGPoint(x: position.x - size.width / 2, y: position.y - size.height / 2)
    }
}
```

Create `macos/Saathi/Sources/SaathiShell/NotchGeometry.swift`:

```swift
//
//  NotchGeometry.swift
//  SaathiShell
//
//  Where the notch panel sits. On a notched screen the panel covers the notch (which is black
//  hardware, so anything drawn there is invisible) plus a lip below it where the mascot and the
//  state word live. Without a notch it is a pill under the menu bar. Pure.
//

import CoreGraphics

public enum NotchGeometry {
    /// Height of the visible strip under the notch.
    public static let lip: CGFloat = 28
    public static let pillWidth: CGFloat = 180
    public static let pillHeight: CGFloat = 30
    public static let menuBarHeight: CGFloat = 24

    public static func collapsedFrame(screen: CGRect, safeAreaTop: CGFloat, leftAuxiliary: CGRect?, rightAuxiliary: CGRect?) -> CGRect {
        if safeAreaTop > 0, let left = leftAuxiliary, let right = rightAuxiliary, right.minX > left.maxX {
            let height = safeAreaTop + lip
            return CGRect(x: left.maxX, y: screen.maxY - height, width: right.minX - left.maxX, height: height)
        }
        return CGRect(
            x: screen.midX - pillWidth / 2,
            y: screen.maxY - menuBarHeight - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
    }

    /// Grows down from the collapsed frame's top edge, centred, at least `minWidth` wide.
    public static func expandedFrame(collapsed: CGRect, height: CGFloat, minWidth: CGFloat) -> CGRect {
        let width = max(collapsed.width, minWidth)
        return CGRect(x: collapsed.midX - width / 2, y: collapsed.maxY - height, width: width, height: height)
    }
}
```

Create `macos/Saathi/Sources/SaathiShell/MenuBarIcon.swift`:

```swift
//
//  MenuBarIcon.swift
//  SaathiShell
//
//  The menu-bar image: the pointer body from the mascot data, drawn as a template so macOS tints
//  it for light and dark menu bars. No eyes — at 18 pt they are under a pixel, which is also why
//  the app icon's 16 pt variant drops them.
//

import AppKit
import SaathiMascot

public enum MenuBarIcon {
    public static func image(data: MascotData, side: CGFloat = 18) -> NSImage {
        let outline = (try? data.bodyOutline()) ?? CGMutablePath()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let bounds = outline.boundingBoxOfPath
            // Fit the body's bounding box into the square with a 1 pt margin, centred.
            let scale = (side - 2) / max(bounds.width, bounds.height)
            context.translateBy(x: rect.midX - bounds.midX * scale, y: rect.midY - bounds.midY * scale)
            context.scaleBy(x: scale, y: scale)
            context.addPath(outline)
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -2`
Expected: `Executed 154 tests, with 0 failures` (144 + 1 + 4 + 3 + 2).

- [ ] **Step 7: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Package.swift macos/Saathi/Sources/SaathiMascot/MascotData.swift macos/Saathi/Sources/SaathiShell macos/Saathi/Sources/SaathiApp/main.swift macos/Saathi/Tests/SaathiShellTests
git commit -m "SaathiShell: the app's testable pieces, and an empty SaathiApp to hang them on

A library between the kit and the character: the state-to-face table, the eased pointer
following, where the notch panel sits (over the notch plus a lip, or a pill under the menu bar),
and the menu-bar template image drawn from the mascot's own outline. MascotData gains
bodyOutline() so the shell can draw the body without the parser being public.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 5: The two panels

**Files:**
- Create: `macos/Saathi/Sources/SaathiShell/CompanionPanel.swift`
- Create: `macos/Saathi/Sources/SaathiShell/NotchPanel.swift`
- Test: `macos/Saathi/Tests/SaathiShellTests/PanelTests.swift`

**Interfaces:**
- Consumes: `MascotView`, `MascotData`, `MascotColor`, `PointerFollower`, `NotchGeometry`, `CompanionState.mascotExpression`, `CompanionState.word`.
- Produces:
  ```swift
  @MainActor public final class CompanionPanel: NSPanel { public static let side: CGFloat = 72; public let mascot: MascotView; public init(data: MascotData, color: MascotColor); public func show(); public func hide(); public var isShowing: Bool; public func setState(_ state: CompanionState); func step(pointer: CGPoint, dt: TimeInterval) }
  @MainActor public final class NotchPanel: NSPanel { public let mascot: MascotView; public init(data: MascotData, color: MascotColor, screen: NSScreen); public func show(); public func setState(_ state: CompanionState); public var word: String { get } }
  ```

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiShellTests/PanelTests.swift`:

```swift
//
//  PanelTests.swift
//  SaathiShellTests
//
//  Panels are checked by eye in the running app; these only pin what they expose and that they
//  can be built and driven without a run loop.
//

import AppKit
import XCTest
import SaathiKit
import SaathiMascot
@testable import SaathiShell

@MainActor
final class PanelTests: XCTestCase {

    private func data() throws -> MascotData { try MascotData.load() }
    private let blue = MascotColor(hex: "#377FE6")

    func testTheCompanionIsClickThroughFloatingAndOnEverySpace() throws {
        let panel = CompanionPanel(data: try data(), color: blue)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.frame.size, NSSize(width: CompanionPanel.side, height: CompanionPanel.side))
        XCTAssertFalse(panel.isShowing)
    }

    func testTheCompanionFollowsAPointerAndLooksAtIt() throws {
        let panel = CompanionPanel(data: try data(), color: blue)
        let before = panel.frame.origin
        panel.step(pointer: CGPoint(x: before.x + 400, y: before.y + 300), dt: 10)
        XCTAssertGreaterThan(panel.frame.origin.x, before.x)
        XCTAssertGreaterThan(panel.frame.origin.y, before.y)
    }

    func testTheCompanionShowsTheStateOnItsFaceAndForVoiceOver() throws {
        let panel = CompanionPanel(data: try data(), color: blue)
        panel.setState(.listening)
        XCTAssertEqual(panel.mascot.expression, .listening)
        XCTAssertEqual(panel.mascot.accessibilityLabel(), "Listening")
    }

    func testTheNotchPanelShowsTheWordAndTheFace() throws {
        let screen = try XCTUnwrap(NSScreen.main, "needs a display")
        let panel = NotchPanel(data: try data(), color: blue, screen: screen)
        panel.setState(.thinking)
        XCTAssertEqual(panel.word, "Thinking")
        XCTAssertEqual(panel.mascot.expression, .thinking)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY - (screen.safeAreaInsets.top > 0 ? 0 : NotchGeometry.menuBarHeight), accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter PanelTests 2>&1 | tail -3`
Expected: compile errors for `CompanionPanel` and `NotchPanel`.

- [ ] **Step 3: Write the companion panel**

Create `macos/Saathi/Sources/SaathiShell/CompanionPanel.swift`:

```swift
//
//  CompanionPanel.swift
//  SaathiShell
//
//  The character next to the pointer: a small transparent panel that floats above everything,
//  on every Space, and lets every click through. It trails the pointer with an easing so it
//  reads as company rather than as a cursor. It is a redundant cue by design — the notch shows
//  the same state in words, and VoiceOver reads the same word from this view.
//

import AppKit
import SaathiKit
import SaathiMascot

@MainActor
public final class CompanionPanel: NSPanel {

    public static let side: CGFloat = 72

    public let mascot: MascotView
    private var follower: PointerFollower
    private var timer: Timer?
    private var lastStep: TimeInterval = CACurrentMediaTime()

    public private(set) var isShowing = false

    public init(data: MascotData, color: MascotColor) {
        let size = NSSize(width: Self.side, height: Self.side)
        mascot = MascotView(data: data, color: color, expression: .idle, frame: NSRect(origin: .zero, size: size))
        follower = PointerFollower(start: NSEvent.mouseLocation)
        super.init(
            contentRect: NSRect(origin: follower.origin(forPanelOf: size), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = mascot
        mascot.setAccessibilityElement(true)
        mascot.setAccessibilityRole(.image)
        setState(.idle)
    }

    public func show() {
        guard !isShowing else { return }
        isShowing = true
        lastStep = CACurrentMediaTime()
        orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = CACurrentMediaTime()
                self.step(pointer: NSEvent.mouseLocation, dt: now - self.lastStep)
                self.lastStep = now
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func hide() {
        timer?.invalidate()
        timer = nil
        isShowing = false
        orderOut(nil)
    }

    public func setState(_ state: CompanionState) {
        mascot.expression = state.mascotExpression
        mascot.setAccessibilityLabel(state.word)
    }

    /// One frame of following. Internal so tests can drive it without a timer.
    func step(pointer: CGPoint, dt: TimeInterval) {
        follower.follow(pointer, dt: dt)
        setFrameOrigin(follower.origin(forPanelOf: frame.size))
        // Look toward the pointer: convert the screen point into the (flipped) mascot view.
        let inWindow = convertPoint(fromScreen: pointer)
        mascot.lookAt(mascot.convert(inWindow, from: nil))
    }
}
```

- [ ] **Step 4: Write the notch panel**

Create `macos/Saathi/Sources/SaathiShell/NotchPanel.swift`:

```swift
//
//  NotchPanel.swift
//  SaathiShell
//
//  The state in words, where HeyClicky puts it: a black panel over the notch with a lip below it
//  holding a small mascot and the state word. Without a notch it is a pill under the menu bar.
//  Expansion for onboarding steps and tips is slice 4; this slice is the collapsed strip.
//

import AppKit
import SaathiKit
import SaathiMascot

@MainActor
public final class NotchPanel: NSPanel {

    public let mascot: MascotView
    private let label = NSTextField(labelWithString: CompanionState.idle.word)
    private let collapsedFrame: NSRect

    public var word: String { label.stringValue }

    public init(data: MascotData, color: MascotColor, screen: NSScreen) {
        collapsedFrame = NotchGeometry.collapsedFrame(
            screen: screen.frame,
            safeAreaTop: screen.safeAreaInsets.top,
            leftAuxiliary: screen.auxiliaryTopLeftArea,
            rightAuxiliary: screen.auxiliaryTopRightArea
        )
        let side: CGFloat = 22
        mascot = MascotView(data: data, color: color, expression: .idle, frame: NSRect(x: 0, y: 0, width: side, height: side))
        super.init(contentRect: collapsedFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: collapsedFrame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        content.layer?.cornerRadius = 12
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        contentView = content

        // Everything visible lives in the bottom lip; the notch itself hides whatever is under it.
        let lipHeight = min(NotchGeometry.lip, collapsedFrame.height)
        let lipY = (lipHeight - side) / 2
        mascot.frame = NSRect(x: 10, y: lipY, width: side, height: side)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 10 + side + 8, y: (lipHeight - 16) / 2, width: collapsedFrame.width - side - 28, height: 16)
        content.addSubview(mascot)
        content.addSubview(label)
        mascot.setAccessibilityElement(true)
        mascot.setAccessibilityRole(.image)
        setState(.idle)
    }

    public func show() {
        setFrame(collapsedFrame, display: true)
        orderFrontRegardless()
    }

    public func setState(_ state: CompanionState) {
        mascot.expression = state.mascotExpression
        label.stringValue = state.word
        mascot.setAccessibilityLabel(state.word)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter PanelTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 4 tests, with 0 failures`. If the last test fails on a display-less machine, that is the `XCTUnwrap(NSScreen.main)` skip path: report it, do not weaken the test.

- [ ] **Step 6: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiShell/CompanionPanel.swift macos/Saathi/Sources/SaathiShell/NotchPanel.swift macos/Saathi/Tests/SaathiShellTests/PanelTests.swift
git commit -m "The two panels: a click-through companion by the pointer, and the state word in the notch

CompanionPanel floats the mascot next to the pointer on every Space, trailing it with the
eased follower, and labels itself for VoiceOver with the same word the notch shows. NotchPanel
is the black strip over the notch (or a pill under the menu bar) with a small mascot and the
state word; expansion for onboarding is slice 4.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 6: The menu bar, the controller, and the executable

**Files:**
- Create: `macos/Saathi/Sources/SaathiShell/MenuBarController.swift`
- Create: `macos/Saathi/Sources/SaathiShell/AppController.swift`
- Modify: `macos/Saathi/Sources/SaathiApp/main.swift`
- Modify: `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md` (two amendments)
- Test: `macos/Saathi/Tests/SaathiShellTests/MenuBarControllerTests.swift`

**Interfaces:**
- Consumes: everything above; `VoiceSessionFactory.make(configuration:speaker:)`, `VoiceSessionCallbacks`, `ActionPerformer`, `SystemSpeaker`, `SystemUrlOpener`, `ConfigurationStore`, `ProviderReport.describe`, `VoiceLaneReport.describe`.
- Produces:
  ```swift
  @MainActor public final class MenuBarController: NSObject { public var onTalk, onQuit, onProvider, onFixPermissions: () -> Void; public var onToggleCompanion, onToggleStartAtLogin: (Bool) -> Void; public init(icon: NSImage); public func setState(_:); public func setCompanionVisible(_:); public func setStartAtLogin(_:); public func setPermissionsNeeded(_ titles: [String]); public var menu: NSMenu }
  @MainActor public final class AppController { public init() throws; public func start() }
  ```

- [ ] **Step 1: Write the failing test**

Create `macos/Saathi/Tests/SaathiShellTests/MenuBarControllerTests.swift`:

```swift
//
//  MenuBarControllerTests.swift
//  SaathiShellTests
//

import AppKit
import XCTest
import SaathiKit
import SaathiMascot
@testable import SaathiShell

@MainActor
final class MenuBarControllerTests: XCTestCase {

    private func controller() throws -> MenuBarController {
        MenuBarController(icon: MenuBarIcon.image(data: try MascotData.load()))
    }

    func testTheMenuHasTheItemsTheSpecLists() throws {
        let titles = try controller().menu.items.map(\.title).filter { !$0.isEmpty }
        for expected in ["Ready", "Talk", "Companion", "Start at login", "Provider…", "Run onboarding again", "Quit Saathi"] {
            XCTAssertTrue(titles.contains(expected), "missing \(expected) in \(titles)")
        }
    }

    func testTheStateWordAndTheTalkItemFollowTheState() throws {
        let menu = try controller()
        menu.setState(.listening)
        XCTAssertEqual(menu.menu.items.first?.title, "Listening")
        XCTAssertTrue(menu.menu.items.contains { $0.title == "Stop talking" })
        menu.setState(.idle)
        XCTAssertTrue(menu.menu.items.contains { $0.title == "Talk" })
    }

    func testPermissionsItemAppearsOnlyWhenSomethingIsMissing() throws {
        let menu = try controller()
        XCTAssertFalse(menu.menu.items.contains { $0.title.hasPrefix("Fix permissions") })
        menu.setPermissionsNeeded(["Input Monitoring"])
        XCTAssertTrue(menu.menu.items.contains { $0.title == "Fix permissions: Input Monitoring…" })
        menu.setPermissionsNeeded([])
        XCTAssertFalse(menu.menu.items.contains { $0.title.hasPrefix("Fix permissions") })
    }

    func testTheCheckboxesReflectWhatTheyAreTold() throws {
        let menu = try controller()
        menu.setCompanionVisible(false)
        XCTAssertEqual(menu.menu.items.first { $0.title == "Companion" }?.state, .off)
        menu.setStartAtLogin(true)
        XCTAssertEqual(menu.menu.items.first { $0.title == "Start at login" }?.state, .on)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter MenuBarControllerTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'MenuBarController'`.

- [ ] **Step 3: Write the menu-bar controller**

Create `macos/Saathi/Sources/SaathiShell/MenuBarController.swift`:

```swift
//
//  MenuBarController.swift
//  SaathiShell
//
//  The status item and its menu. It knows nothing about voice: it shows what it is told and
//  reports clicks through closures, so the menu can be tested without a session behind it.
//

import AppKit
import SaathiKit

@MainActor
public final class MenuBarController: NSObject {

    public var onTalk: () -> Void = {}
    public var onToggleCompanion: (Bool) -> Void = { _ in }
    public var onToggleStartAtLogin: (Bool) -> Void = { _ in }
    public var onProvider: () -> Void = {}
    public var onRunOnboarding: () -> Void = {}
    public var onFixPermissions: () -> Void = {}
    public var onQuit: () -> Void = {}

    public let menu = NSMenu()
    private let statusItem: NSStatusItem?

    private let stateItem = NSMenuItem(title: CompanionState.idle.word, action: nil, keyEquivalent: "")
    private let talkItem = NSMenuItem(title: "Talk", action: #selector(talk), keyEquivalent: "")
    private let companionItem = NSMenuItem(title: "Companion", action: #selector(toggleCompanion), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Start at login", action: #selector(toggleStartAtLogin), keyEquivalent: "")
    private let providerItem = NSMenuItem(title: "Provider…", action: #selector(provider), keyEquivalent: "")
    private let onboardingItem = NSMenuItem(title: "Run onboarding again", action: #selector(runOnboarding), keyEquivalent: "")
    private let permissionsItem = NSMenuItem(title: "Fix permissions…", action: #selector(fixPermissions), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "Quit Saathi", action: #selector(quit), keyEquivalent: "q")

    /// - Parameter installStatusItem: false in tests, where there is no status bar to put it in.
    public init(icon: NSImage, installStatusItem: Bool = false) {
        statusItem = installStatusItem ? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) : nil
        super.init()
        statusItem?.button?.image = icon
        statusItem?.button?.toolTip = "Saathi"
        statusItem?.menu = menu

        menu.autoenablesItems = false   // we set isEnabled ourselves; AppKit would re-enable by target/action
        stateItem.isEnabled = false
        onboardingItem.isEnabled = false   // slice 4
        companionItem.state = .on

        for item in [stateItem, NSMenuItem.separator(), talkItem, companionItem, loginItem, providerItem, onboardingItem, permissionsItem, NSMenuItem.separator(), quitItem] {
            item.target = self
            menu.addItem(item)
        }
        setPermissionsNeeded([])
    }

    public func setState(_ state: CompanionState) {
        stateItem.title = state.word
        talkItem.title = state == .listening ? "Stop talking" : "Talk"
    }

    public func setCompanionVisible(_ visible: Bool) {
        companionItem.state = visible ? .on : .off
    }

    public func setStartAtLogin(_ enabled: Bool) {
        loginItem.state = enabled ? .on : .off
    }

    /// Titles of permissions still missing; empty hides the item.
    public func setPermissionsNeeded(_ titles: [String]) {
        permissionsItem.isHidden = titles.isEmpty
        permissionsItem.title = "Fix permissions: \(titles.joined(separator: ", "))…"
    }

    @objc private func talk() { onTalk() }
    @objc private func toggleCompanion() {
        companionItem.state = companionItem.state == .on ? .off : .on
        onToggleCompanion(companionItem.state == .on)
    }
    @objc private func toggleStartAtLogin() {
        loginItem.state = loginItem.state == .on ? .off : .on
        onToggleStartAtLogin(loginItem.state == .on)
    }
    @objc private func provider() { onProvider() }
    @objc private func runOnboarding() { onRunOnboarding() }
    @objc private func fixPermissions() { onFixPermissions() }
    @objc private func quit() { onQuit() }
}
```

Note for the test in Step 1: `menu.items` includes hidden items, so the permissions test must check `isHidden` rather than presence. Adjust that test to:

```swift
    func testPermissionsItemAppearsOnlyWhenSomethingIsMissing() throws {
        let menu = try controller()
        let item = try XCTUnwrap(menu.menu.items.first { $0.title.hasPrefix("Fix permissions") })
        XCTAssertTrue(item.isHidden)
        menu.setPermissionsNeeded(["Input Monitoring"])
        XCTAssertFalse(item.isHidden)
        XCTAssertEqual(item.title, "Fix permissions: Input Monitoring…")
        menu.setPermissionsNeeded([])
        XCTAssertTrue(item.isHidden)
    }
```

- [ ] **Step 4: Write the app controller**

Create `macos/Saathi/Sources/SaathiShell/AppController.swift`:

```swift
//
//  AppController.swift
//  SaathiShell
//
//  Wires the pieces: configuration, the voice session and its callbacks, the state machine, the
//  hold-to-talk monitor, the two panels and the menu. Everything that touches a view happens on
//  the main actor; session callbacks arrive on other threads and are hopped over.
//

import AppKit
import SaathiContract
import SaathiKit
import SaathiMascot
import ServiceManagement

@MainActor
public final class AppController {

    private let configuration: SaathiConfiguration
    private let data: MascotData
    private let color: MascotColor

    private var machine: CompanionStateMachine
    private var shown: CompanionState = .idle

    private let companion: CompanionPanel
    private let notch: NotchPanel?
    private let menu: MenuBarController

    private var speaker: ObservedSpeaker!
    private var performer: ActionPerformer!
    private var session: (any VoiceSession)?
    private var turnOpen = false
    private var monitor: HoldToTalkMonitor?
    private var ticker: Timer?

    public init() throws {
        configuration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
        data = try MascotData.load()
        color = MascotColor(paletteName: "blue", in: data) ?? MascotColor(hex: "#377FE6")
        machine = CompanionStateMachine(now: CACurrentMediaTime())
        companion = CompanionPanel(data: data, color: color)
        notch = NSScreen.main.map { NotchPanel(data: data, color: color, screen: $0) }
        menu = MenuBarController(icon: MenuBarIcon.image(data: data), installStatusItem: true)

        speaker = ObservedSpeaker(SystemSpeaker()) { [weak self] speaking in
            Task { @MainActor in self?.handle(.speakingChanged(speaking)) }
        }
        performer = ActionPerformer(speaker: speaker, urlOpener: SystemUrlOpener())
        wireMenu()
    }

    public func start() {
        notch?.show()
        companion.show()
        menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        render(force: true)
        startTicking()
        startVoice()
        startHoldToTalk()
        refreshPermissions()
    }

    // MARK: events

    private func handle(_ event: CompanionEvent) {
        machine.apply(event, now: CACurrentMediaTime())
        render()
    }

    private func render(force: Bool = false) {
        let state = machine.state
        guard force || state != shown else { return }
        shown = state
        companion.setState(state)
        notch?.setState(state)
        menu.setState(state)
    }

    private func startTicking() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.machine.tick(now: CACurrentMediaTime())
                self.render()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    // MARK: voice

    private func startVoice() {
        do {
            let session = try VoiceSessionFactory.make(configuration: configuration, speaker: speaker)
            self.session = session
            let callbacks = VoiceSessionCallbacks(
                onUserTranscript: { [weak self] text in Task { @MainActor in self?.handle(.userSpoke(text)) } },
                onSaathiTranscript: { [weak self] text in Task { @MainActor in self?.handle(.saathiSpoke(text)) } },
                onAction: { [weak self] action in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handle(.action(action))
                        Task { try? await self.performer.perform(action) }
                    }
                },
                onStatus: { [weak self] status in Task { @MainActor in self?.handle(.status(status)) } }
            )
            Task {
                do {
                    try await session.start(callbacks: callbacks)
                } catch {
                    await MainActor.run { self.handle(.failure(error.localizedDescription)) }
                }
            }
        } catch {
            handle(.failure(error.localizedDescription))
        }
    }

    private func beginTurn() {
        guard let session, !turnOpen else { return }
        turnOpen = true
        Task {
            do { try await session.beginTurn() } catch { await MainActor.run { self.handle(.failure(error.localizedDescription)) } }
        }
    }

    private func endTurn() {
        guard let session, turnOpen else { return }
        turnOpen = false
        Task {
            do { try await session.endTurn() } catch { await MainActor.run { self.handle(.failure(error.localizedDescription)) } }
        }
    }

    // MARK: hold to talk

    private func startHoldToTalk() {
        let monitor = HoldToTalkMonitor { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .began:
                    self.beginTurn()
                    self.handle(.keysHeld)
                case .ended:
                    self.endTurn()
                    self.handle(.keysReleased)
                }
            }
        }
        do {
            try monitor.start()
            self.monitor = monitor
        } catch {
            // Not permitted: the menu's Fix permissions item opens the pane; the Talk item still works.
            self.monitor = nil
        }
    }

    private func refreshPermissions() {
        let missing = Permission.allCases.filter { Permissions.status(of: $0) != .granted }.map(\.title)
        menu.setPermissionsNeeded(missing)
    }

    // MARK: menu

    private func wireMenu() {
        menu.onTalk = { [weak self] in
            guard let self else { return }
            if self.turnOpen { self.endTurn() } else { self.beginTurn() }
            self.handle(.talkPressed)
        }
        menu.onToggleCompanion = { [weak self] visible in
            guard let self else { return }
            if visible { self.companion.show() } else { self.companion.hide() }
        }
        menu.onToggleStartAtLogin = { [weak self] enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                self?.handle(.failure("start at login: \(error.localizedDescription)"))
            }
            self?.menu.setStartAtLogin(SMAppService.mainApp.status == .enabled)
        }
        menu.onProvider = { [weak self] in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = "Where Saathi thinks"
            alert.informativeText = ProviderReport.describe(self.configuration) + "\n\n" + VoiceLaneReport.describe(self.configuration)
            alert.runModal()
        }
        menu.onFixPermissions = { [weak self] in
            guard let self else { return }
            if Permissions.status(of: .inputMonitoring) != .granted, self.monitor == nil {
                _ = HoldToTalkMonitor.requestPermission()
                NSWorkspace.shared.open(Permission.inputMonitoring.settingsURL)
                // If the grant arrives while we run, the tap can be installed next time Talk is used.
            } else if let first = Permission.allCases.first(where: { Permissions.status(of: $0) != .granted }) {
                NSWorkspace.shared.open(first.settingsURL)
            }
            self.refreshPermissions()
        }
        menu.onQuit = { [weak self] in
            guard let self else { return }
            self.handle(.quit)
            Task {
                await self.session?.stop()
                try? await Task.sleep(nanoseconds: 1_400_000_000)   // let powering-down settle
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}
```

- [ ] **Step 5: Write the executable**

Replace `macos/Saathi/Sources/SaathiApp/main.swift` with:

```swift
//
//  main.swift
//  SaathiApp
//
//  The bundle's main executable. Everything lives in SaathiShell so it can be tested; this only
//  starts it.
//

import AppKit
import SaathiShell

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar app: no Dock tile, no main window

let controller: AppController = {
    do {
        return try AppController()
    } catch {
        let alert = NSAlert()
        alert.messageText = "Saathi could not start"
        alert.informativeText = "\(error)"
        alert.runModal()
        exit(1)
    }
}()
controller.start()
app.run()
```

- [ ] **Step 6: Amend the spec**

In `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md`:
- In the targets table, change the `SaathiKit` row's purpose to end with "…and the onboarding model. All testable without a window. The state-to-expression table lives in `SaathiShell`, a new library between the kit and the character, because the kit cannot see `MascotExpression`." and add a row: `| \`SaathiShell\` | library | Kit, Mascot | The app's testable pieces: state-to-face table, panel geometry, the panels, the menu, the controller. |`
- In "State", replace "The `Speaker` protocol gains `onSpeakingChanged: ((Bool) -> Void)?` so the state machine can see speech start and stop." with "An `ObservedSpeaker` wrapper reports speech start and stop around any speaker, so the state machine can see it without the `Speaker` protocol changing."

- [ ] **Step 7: Run the tests and the app**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|failed" | tail -2`
Expected: `Executed 162 tests, with 0 failures` (154 + 4 + 4).

Run: `cd macos/Saathi && swift build 2>&1 | grep -E "error|warning"; swift run SaathiApp &` then, after five seconds, `pgrep -fl SaathiApp`.
Expected: a pointer icon appears in the menu bar and a small blue mascot floats near the pointer; no build warnings. Launched this way the process is a child of the terminal, so Input Monitoring cannot be granted to it; the menu's "Fix permissions" item should list Input Monitoring. The proper launch is Task 7. Quit with the menu's Quit item or `pkill -f SaathiApp`.

- [ ] **Step 8: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiShell/MenuBarController.swift macos/Saathi/Sources/SaathiShell/AppController.swift macos/Saathi/Sources/SaathiApp/main.swift macos/Saathi/Tests/SaathiShellTests/MenuBarControllerTests.swift docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md
git commit -m "SaathiApp: a menu-bar app with the companion and the notch strip, driven by the voice session

AppController loads the configuration, starts the voice session with callbacks that feed the
state machine, installs the hold-to-talk tap when Input Monitoring allows it, and keeps the
companion, the notch strip and the menu showing the same state word. The menu carries Talk for
people who cannot hold keys, the companion switch, start at login through SMAppService, the
provider report, and a Fix permissions item that appears only when something is missing.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 7: The bundle ships both executables, and the first real launch

**Files:**
- Modify: `macos/Saathi/scripts/release.sh` (build and assemble sections)
- Modify: `macos/Saathi/Resources/Info.plist` (`CFBundleExecutable`)

**Interfaces:**
- Consumes: the `SaathiApp` and `saathi` products; the `SaathiMascot_SaathiMascot.bundle` SwiftPM resource bundle that `MascotData.load()` finds through `Bundle.main.resourceURL`.
- Produces: `dist/Saathi.app` whose main executable is `SaathiApp`, with `Contents/MacOS/saathi` beside it and `Contents/Resources/SaathiMascot_SaathiMascot.bundle` inside.

- [ ] **Step 1: Change the executable name in the plist**

In `macos/Saathi/Resources/Info.plist`, change `<string>saathi</string>` under `CFBundleExecutable` to `<string>SaathiApp</string>`, and update the comment near `LSUIElement` (which says "this build is the CLI inside a bundle") to: "No Dock tile: Saathi is a menu-bar item plus panels. The CLI still ships beside the app as Contents/MacOS/saathi, which the Homebrew cask symlinks."

- [ ] **Step 2: Build and copy both executables and the resource bundle**

In `macos/Saathi/scripts/release.sh`, replace the build and assemble sections (from `echo "▸ building universal"` through `cp "$BINARY" "$APP/Contents/MacOS/saathi"`) with:

```bash
echo "▸ building universal (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 >/dev/null
PRODUCTS="$PACKAGE_DIR/.build/apple/Products/Release"
CLI="$PRODUCTS/saathi"
APP_BINARY="$PRODUCTS/SaathiApp"
MASCOT_BUNDLE="$PRODUCTS/SaathiMascot_SaathiMascot.bundle"
for needed in "$CLI" "$APP_BINARY" "$MASCOT_BUNDLE"; do
  [[ -e "$needed" ]] || { echo "build produced nothing at $needed" >&2; exit 1; }
done

# ── assemble ─────────────────────────────────────────────────────────────────
# Two executables in one bundle: SaathiApp is what LaunchServices launches and what permission
# prompts are attributed to; saathi is the CLI the cask symlinks onto PATH. The mascot's data
# travels as the SwiftPM resource bundle, found through Bundle.main.resourceURL.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$APP_BINARY" "$APP/Contents/MacOS/SaathiApp"
cp "$CLI" "$APP/Contents/MacOS/saathi"
cp -R "$MASCOT_BUNDLE" "$APP/Contents/Resources/"
```

Then make the signing step sign the nested pieces before the app (codesign seals the outer bundle over whatever is inside it, so inner code must already be signed). The script has a `sign()` helper (hardened runtime, timestamp, entitlements) and an ad-hoc branch. Replace the `if [[ "$SIGN_IDENTITY" == "-" ]]; then … fi` block with:

```bash
NESTED_BUNDLE="$APP/Contents/Resources/SaathiMascot_SaathiMascot.bundle"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ signing ad-hoc (this Mac only, not distributable)"
  codesign --force --sign - "$NESTED_BUNDLE"
  codesign --force --sign - --entitlements "$PACKAGE_DIR/Resources/Saathi.entitlements" "$APP/Contents/MacOS/saathi"
  codesign --force --sign - --entitlements "$PACKAGE_DIR/Resources/Saathi.entitlements" "$APP"
else
  echo "▸ signing"
  # A resource bundle has no executable, so no hardened runtime or entitlements — just a seal.
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$NESTED_BUNDLE"
  sign "$APP/Contents/MacOS/saathi"
  sign "$APP"
fi
```

Also update the `try it:` line at the end of the script to print both: `open "$APP"` and the CLI path.

- [ ] **Step 3: Build the ad-hoc bundle**

Run: `cd macos/Saathi && scripts/release.sh --adhoc 2>&1 | tail -8 && ls dist/Saathi.app/Contents/MacOS dist/Saathi.app/Contents/Resources && plutil -p dist/Saathi.app/Contents/Info.plist | grep CFBundleExecutable && codesign --verify --deep --strict dist/Saathi.app && echo "signature ok"`
Expected: both executables and the icon plus the mascot bundle listed, `CFBundleExecutable => "SaathiApp"`, signature ok.

- [ ] **Step 4: Launch it properly and hand over to the human**

Run: `open /Users/prasanthsasikumar/Documents/GitHub/saathi/macos/Saathi/dist/Saathi.app && sleep 4 && pgrep -fl SaathiApp`
Expected: the process is running, launched through LaunchServices.

Then stop and report DONE_WITH_CONCERNS with this checklist for the human, verbatim, because only a person at the machine can do it:

1. A pointer icon is in the menu bar; a small blue character floats near the pointer and follows it; the notch (or a pill under the menu bar) shows "Ready".
2. Open the menu: it shows Ready, Talk, Companion, Start at login, Provider…, Run onboarding again (greyed), and Fix permissions: Input Monitoring…, then Quit Saathi.
3. Click Fix permissions. macOS should show the Input Monitoring prompt or open System Settings; turn Saathi on there. Quit Saathi from the menu and reopen it with `open dist/Saathi.app` so the tap installs.
4. Hold control and option: the face and the word go to Listening. Say "hello" and release: Thinking, then either a spoken reply (Speaking) or "did not catch that" / the local-model-unreachable alert, then Ready. Without Ollama the alert is the expected outcome and still proves the loop.
5. Companion off and on from the menu hides and shows the character.
6. Quit: the character powers down and the app exits after about a second.

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/scripts/release.sh macos/Saathi/Resources/Info.plist
git commit -m "The bundle launches SaathiApp, and carries the CLI and the mascot data beside it

CFBundleExecutable is now the menu-bar app, so LaunchServices launches it and permission
prompts are attributed to Saathi rather than to a terminal; saathi still ships in Contents/MacOS
for the cask's symlink, and the SwiftPM resource bundle for the mascot lands in Resources where
Bundle.main.resourceURL finds it. Both nested pieces are signed before the app is.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

## Done when

- `swift test` passes with 162 tests.
- `open dist/Saathi.app` shows the menu-bar icon, the companion and the notch strip, and the human checklist in Task 7 passes, with the Input Monitoring grant made once by the human.
- Holding control and option drives a full voice turn through the existing chain lane, ending in either a reply or an honest alert.
