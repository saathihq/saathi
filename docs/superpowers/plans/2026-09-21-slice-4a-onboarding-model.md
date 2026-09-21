# Slice 4a — The Onboarding Model: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything first run *decides* — the order of steps, what unlocks Continue, what a spoken answer means, what Saathi says at each point, and what ends up in `shell.json` — exists as pure, tested values in SaathiKit, with no window behind it.

**Architecture:** One value type, `OnboardingModel`, folded from `OnboardingEvent`s the way `CompanionStateMachine` is folded from `CompanionEvent`s: the app sends what happened (a button, a permission verdict, a transcript, a trial answer) and renders `model.step`. Parsing spoken answers lives in `OnboardingAnswers`; every line Saathi speaks lives in `OnboardingScript`, so "everything on a card is also spoken" is one table with a completeness test. Nothing here imports AppKit, SwiftUI, AVFoundation or Speech.

**Tech Stack:** Swift 6, SwiftPM, XCTest, in `macos/Saathi` (`SaathiKit` target). Depends on `SaathiContract` for `Tone`, `Pace`, `ProviderKind`, `SaathiConfiguration`.

**Spec:** `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md`, section "First run" and the `OnboardingModel` bullets under "Testing" and "Error handling".

## Why slice 4 is two plans

Build-order item 4 is "Onboarding model and cards". They are different kinds of work. The model is decidable from the spec and checkable by tests, so it is planned here in full. The cards are a look, and the look of this app has been rejected twice in use and reworked toward OpenClicky's; planning their pixels without the user in front of a build would be planning the third rejection. **Slice 4b (cards, the notch permission wizard, the demo card, wiring into `AppController`, "Run onboarding again") gets its plan after this lands and after the user has seen a first card.** 4b renders `OnboardingModel.step`, speaks `OnboardingScript.line(for:)`, and sends `OnboardingEvent`s; that interface is what this plan fixes.

## Global Constraints

- **Prerequisite:** slice 3 Task 1 has landed — `SaathiConfiguration` has `name`, `colour`, `tone`, `pace`, `firstGoal`, `onboarded`, `deviceId`, `startAtLogin`. Check with `grep -n "public var onboarded" macos/Saathi/Sources/SaathiContract/SaathiContract.swift`; if it prints nothing, stop and do that task first.
- Spoken lines quoted in the spec are copied **verbatim**, including punctuation: the welcome, "I live up here now. I need three permissions to get started.", "Turn your sound on. Meet Saathi.", the three permission reasons (already `Permission.reason` — reuse it, do not retype it), and the hosted-service disclosure before the trial chat.
- Permissions asked during first run are exactly three, in this order: microphone, speech recognition, input monitoring. Screen Recording and Accessibility are asked when sight is first wanted, not here (`Permission.isRequired` is the same set).
- A denied permission never blocks: onboarding continues and the denial is recorded.
- A refused trial never blocks: the step says the exact reason in words and offers Skip. **Never a fallback to hosted** — "hosted" can only be chosen when a trial token was actually issued.
- The manner choices are exactly: calm and slow (`.calm`, `.slow`), warm and normal (`.encouraging`, `.normal`), plain (`.neutral`, `.normal`).
- `language` is a BCP 47 tag chosen only from the tags the app passes in as supported.
- No file in this plan imports a UI or audio framework. `import Foundation` and `import SaathiContract` only.
- Commit messages are full sentences, no `feat:` prefix, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Run tests with plain `swift test`; never set `SAATHI_AUDIO_TESTS=1`.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/SaathiKit/OnboardingModel.swift` | Steps, events, the fold, `canContinue`, `apply(to:)` |
| `Sources/SaathiKit/OnboardingAnswers.swift` | What a spoken or typed answer means: name, goal, manner, language |
| `Sources/SaathiKit/OnboardingScript.swift` | Every line Saathi says during first run |
| `Tests/SaathiKitTests/OnboardingModelTests.swift` | Step order and branches |
| `Tests/SaathiKitTests/OnboardingAnswersTests.swift` | Parsing |
| `Tests/SaathiKitTests/OnboardingScriptTests.swift` | Verbatim lines and completeness |

All paths below are relative to `macos/Saathi/`.

---

### Task 1: What an answer means — `OnboardingAnswers`

**Files:**
- Create: `Sources/SaathiKit/OnboardingAnswers.swift`
- Test: `Tests/SaathiKitTests/OnboardingAnswersTests.swift`

**Interfaces:**
- Consumes: `Tone`, `Pace` from `SaathiContract`.
- Produces:
  - `public enum OnboardingQuestion: String, CaseIterable, Sendable { case name, firstGoal, manner, language }`
  - `public enum Manner: String, CaseIterable, Sendable { case calmAndSlow, warmAndNormal, plain }` with `tone: Tone`, `pace: Pace`, `title: String`, `static func parse(_ spoken: String) -> Manner?`
  - `public struct OnboardingAnswers: Equatable, Sendable { var name: String?; var firstGoal: String?; var manner: Manner?; var language: String? }`
  - `public enum AnswerParser { static func name(from:) -> String?; static func goal(from:) -> String?; static func language(from:supported:) -> String? }`

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/OnboardingAnswersTests.swift`:

```swift
//
//  OnboardingAnswersTests.swift
//  SaathiKitTests
//
//  What someone says when a voice asks their name is not their name: it is "my name is Asha", or
//  "uh, Asha.", or "call me Ash". These pin what is kept.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class OnboardingAnswersTests: XCTestCase {

    func testANameIsTakenOutOfTheSentenceItArrivedIn() {
        XCTAssertEqual(AnswerParser.name(from: "Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "my name is Asha."), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "My name's Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "I'm Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "I am Asha Rao"), "Asha Rao")
        XCTAssertEqual(AnswerParser.name(from: "call me Ash!"), "Ash")
        XCTAssertEqual(AnswerParser.name(from: "you can call me Ash"), "Ash")
        XCTAssertEqual(AnswerParser.name(from: "it's Asha"), "Asha")
        XCTAssertEqual(AnswerParser.name(from: "uh, Asha"), "Asha")
    }

    /// Speech recognition lower-cases freely; a name is given back with its first letters raised.
    /// A name typed with its own capitals is left alone.
    func testALowercasedNameIsCapitalisedAndATypedOneIsLeftAlone() {
        XCTAssertEqual(AnswerParser.name(from: "my name is asha rao"), "Asha Rao")
        XCTAssertEqual(AnswerParser.name(from: "McKenzie"), "McKenzie")
        XCTAssertEqual(AnswerParser.name(from: "அஷா"), "அஷா", "a name in another script is kept as given")
    }

    func testNothingUsableIsNil() {
        XCTAssertNil(AnswerParser.name(from: ""))
        XCTAssertNil(AnswerParser.name(from: "   "))
        XCTAssertNil(AnswerParser.name(from: "my name is"))
        XCTAssertNil(AnswerParser.name(from: "..."))
    }

    /// A name is a few words. A paragraph is a misheard room, not a name.
    func testAVeryLongAnswerIsNotAName() {
        XCTAssertNil(AnswerParser.name(from: "well I was thinking about what to have for lunch today and"))
    }

    func testAGoalLosesItsPreambleAndKeepsItsWords() {
        XCTAssertEqual(AnswerParser.goal(from: "I want to learn the tabla"), "the tabla")
        XCTAssertEqual(AnswerParser.goal(from: "I'd like to learn how to edit video."), "how to edit video")
        XCTAssertEqual(AnswerParser.goal(from: "I want to play with Blender"), "Blender")
        XCTAssertEqual(AnswerParser.goal(from: "spreadsheets"), "spreadsheets")
        XCTAssertNil(AnswerParser.goal(from: "  "))
    }

    func testTheThreeMannersAreTheSpecsThree() {
        XCTAssertEqual(Manner.calmAndSlow.tone, .calm);        XCTAssertEqual(Manner.calmAndSlow.pace, .slow)
        XCTAssertEqual(Manner.warmAndNormal.tone, .encouraging); XCTAssertEqual(Manner.warmAndNormal.pace, .normal)
        XCTAssertEqual(Manner.plain.tone, .neutral);           XCTAssertEqual(Manner.plain.pace, .normal)
        XCTAssertEqual(Manner.allCases.map(\.title), ["calm and slow", "warm and normal", "plain"])
    }

    func testAMannerIsHeardFromAnyOfItsWords() {
        XCTAssertEqual(Manner.parse("calm and slow"), .calmAndSlow)
        XCTAssertEqual(Manner.parse("slow please"), .calmAndSlow)
        XCTAssertEqual(Manner.parse("the first one"), .calmAndSlow)
        XCTAssertEqual(Manner.parse("Warm."), .warmAndNormal)
        XCTAssertEqual(Manner.parse("normal is fine"), .warmAndNormal)
        XCTAssertEqual(Manner.parse("second"), .warmAndNormal)
        XCTAssertEqual(Manner.parse("just plain"), .plain)
        XCTAssertEqual(Manner.parse("the last one"), .plain)
        XCTAssertNil(Manner.parse("whatever you think"))
        XCTAssertNil(Manner.parse(""))
    }

    /// "Normal" is in the second choice's name and "slow" in the first's; an answer naming two
    /// different choices is not an answer.
    func testAnAnswerThatNamesTwoMannersIsNotAnAnswer() {
        XCTAssertNil(Manner.parse("calm or plain, I don't mind"))
    }

    func testALanguageIsChosenOnlyFromWhatThisMacSupports() {
        let supported = ["en-US", "en-IN", "hi-IN", "ta-IN", "ko-KR"]
        XCTAssertEqual(AnswerParser.language(from: "Hindi", supported: supported), "hi-IN")
        XCTAssertEqual(AnswerParser.language(from: "let's talk in tamil", supported: supported), "ta-IN")
        XCTAssertEqual(AnswerParser.language(from: "हिन्दी", supported: supported), "hi-IN", "its own name for itself counts")
        XCTAssertEqual(AnswerParser.language(from: "한국어", supported: supported), "ko-KR")
        XCTAssertNil(AnswerParser.language(from: "Klingon", supported: supported))
        XCTAssertNil(AnswerParser.language(from: "French", supported: supported), "a real language this Mac cannot recognise is still a no")
    }

    /// Several regions of one language: the first listed wins, so the app decides by ordering —
    /// it puts the machine's own region first.
    func testTheFirstSupportedRegionOfALanguageWins() {
        XCTAssertEqual(AnswerParser.language(from: "English", supported: ["en-IN", "en-US"]), "en-IN")
        XCTAssertEqual(AnswerParser.language(from: "English", supported: ["en-US", "en-IN"]), "en-US")
    }

    func testATagSaidOrTypedExactlyIsAccepted() {
        XCTAssertEqual(AnswerParser.language(from: "ta-IN", supported: ["en-US", "ta-IN"]), "ta-IN")
    }
}
```

- [ ] **Step 2: Run to see it fail.**

Run: `cd macos/Saathi && swift build --build-tests 2>&1 | grep error | head -3`
Expected: `error: cannot find 'AnswerParser' in scope`

- [ ] **Step 3: Implement.** Create `Sources/SaathiKit/OnboardingAnswers.swift`:

```swift
//
//  OnboardingAnswers.swift
//  SaathiKit
//
//  What an answer to one of first run's four questions means.
//
//  The questions are spoken and so, mostly, are the answers — which means what arrives is a
//  sentence from a speech recogniser, not a form field: "my name is asha", lower-cased, with a
//  full stop it invented. Onboarding that greets someone as "My name is asha." for the rest of
//  their time with it has failed at the first thing it did. So each question has a small, strict
//  reading here, and anything it cannot read is nil: the model asks once more and then moves on
//  with a default, rather than guessing.
//

import Foundation
import SaathiContract

public enum OnboardingQuestion: String, CaseIterable, Sendable {
    case name
    case firstGoal
    case manner
    case language
}

/// How Saathi should speak. Three offers, because a tone and a pace asked separately is two
/// questions about one feeling.
public enum Manner: String, CaseIterable, Sendable {
    case calmAndSlow
    case warmAndNormal
    case plain

    public var tone: Tone {
        switch self {
        case .calmAndSlow: return .calm
        case .warmAndNormal: return .encouraging
        case .plain: return .neutral
        }
    }

    public var pace: Pace {
        switch self {
        case .calmAndSlow: return .slow
        case .warmAndNormal, .plain: return .normal
        }
    }

    /// As offered out loud and on the card.
    public var title: String {
        switch self {
        case .calmAndSlow: return "calm and slow"
        case .warmAndNormal: return "warm and normal"
        case .plain: return "plain"
        }
    }

    /// Words that mean each choice, including its place in the list as it was read out.
    private var cues: [String] {
        switch self {
        case .calmAndSlow: return ["calm", "slow", "first"]
        case .warmAndNormal: return ["warm", "normal", "second", "middle"]
        case .plain: return ["plain", "third", "last"]
        }
    }

    /// The one manner the answer names. Nil when it names none, or more than one.
    public static func parse(_ spoken: String) -> Manner? {
        let words = Set(AnswerParser.words(in: spoken))
        let named = allCases.filter { manner in manner.cues.contains { words.contains($0) } }
        return named.count == 1 ? named[0] : nil
    }
}

public struct OnboardingAnswers: Equatable, Sendable {
    public var name: String?
    public var firstGoal: String?
    public var manner: Manner?
    public var language: String?

    public init(name: String? = nil, firstGoal: String? = nil, manner: Manner? = nil, language: String? = nil) {
        self.name = name
        self.firstGoal = firstGoal
        self.manner = manner
        self.language = language
    }
}

public enum AnswerParser {

    /// Lower-cased words, split on anything that is not a letter, a number or an apostrophe.
    static func words(in text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’")).inverted
        return text.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }

    /// Trimmed of whitespace and of the punctuation a recogniser adds at either end.
    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// `text` without the longest of `prefixes` it starts with, compared case-insensitively and
    /// only at a word boundary ("I'm" must not eat the start of "Imran").
    static func dropping(_ prefixes: [String], from text: String) -> String {
        let lower = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            guard lower.hasPrefix(prefix) else { continue }
            let rest = text.dropFirst(prefix.count)
            if rest.isEmpty || rest.first == " " || rest.first == "," { return trimmed(String(rest)) }
        }
        return text
    }

    private static let fillers = ["uh", "um", "er", "erm", "hmm", "well", "oh", "so", "hi", "hello", "hey"]

    private static let namePreambles = [
        "my name is", "my name's", "the name is", "the name's", "i am", "i'm", "im",
        "you can call me", "call me", "just call me", "it is", "it's", "its", "this is",
    ]

    /// The name in an answer to "what should I call you?". At most four words: more than that is
    /// a misheard room, not a name.
    public static func name(from spoken: String) -> String? {
        var text = trimmed(spoken)
        text = dropping(fillers, from: text)
        text = dropping(namePreambles, from: text)
        text = trimmed(text)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: " ")
        guard parts.count <= 4 else { return nil }
        // Only an all-lower-case answer is re-capitalised: that is what a recogniser produces, and
        // "McKenzie" typed by its owner is already right.
        guard text == text.lowercased(), text != text.uppercased() else { return text }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let goalPreambles = [
        "i want to learn", "i'd like to learn", "i would like to learn", "i want to play with",
        "i'd like to play with", "i want to try", "i'd like to try", "i want to", "i'd like to",
        "learn", "to learn", "maybe", "probably",
    ]

    /// What the learner wants to start with, without "I want to learn". Kept in their words: this
    /// is read back to them, and later handed to a model as context.
    public static func goal(from spoken: String) -> String? {
        var text = trimmed(spoken)
        text = dropping(fillers, from: text)
        text = dropping(goalPreambles, from: text)
        text = trimmed(text)
        return text.isEmpty ? nil : text
    }

    /// The supported tag the answer names, by its English name ("Hindi"), by its own name for
    /// itself ("हिन्दी"), or by the tag. Only ever one of `supported`; the first listed region of a
    /// language wins.
    public static func language(from spoken: String, supported: [String]) -> String? {
        let answer = trimmed(spoken)
        guard !answer.isEmpty else { return nil }
        if let exact = supported.first(where: { $0.caseInsensitiveCompare(answer) == .orderedSame }) { return exact }

        let lower = answer.lowercased()
        let english = Locale(identifier: "en")
        for tag in supported {
            let code = Locale(identifier: tag).language.languageCode?.identifier ?? tag
            let names = [
                english.localizedString(forLanguageCode: code),
                Locale(identifier: code).localizedString(forLanguageCode: code),
            ].compactMap { $0?.lowercased() }.filter { !$0.isEmpty }
            if names.contains(where: { lower.contains($0) }) { return tag }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests.**

Run: `swift test --filter OnboardingAnswersTests 2>&1 | grep -E "error:|failed|Executed"`
Expected: `Executed 11 tests, with 0 failures`.

If `testANameIsTakenOutOfTheSentenceItArrivedIn` fails on `"uh, Asha"`: `dropping` leaves `", Asha"` trimmed to `"Asha"` — check `trimmed` is applied to the remainder (it is, inside `dropping`). If the Hindi autonym test fails, print `Locale(identifier: "hi").localizedString(forLanguageCode: "hi")` — ICU spells it "हिन्दी"; if this macOS spells it differently, change the test's literal to what ICU returns rather than loosening the match.

- [ ] **Step 5: Commit.**

```bash
git add Sources/SaathiKit/OnboardingAnswers.swift Tests/SaathiKitTests/OnboardingAnswersTests.swift
git commit -m "First run can tell a name from the sentence it arrived in"
```

---

### Task 2: The steps and their order — `OnboardingModel`

**Files:**
- Create: `Sources/SaathiKit/OnboardingModel.swift`
- Test: `Tests/SaathiKitTests/OnboardingModelTests.swift`

**Interfaces:**
- Consumes: `OnboardingQuestion`, `Manner`, `OnboardingAnswers`, `AnswerParser` (Task 1); `Permission`, `PermissionStatus` (`Sources/SaathiKit/Permissions.swift`); `SaathiConfiguration`, `ProviderKind` (`SaathiContract`).
- Produces:
  - `public enum DemoStep: Equatable, Sendable { case micCheck, holdToTalk, question(OnboardingQuestion), trialChat, providerChoice }`
  - `public enum OnboardingStep: Equatable, Sendable { case welcome, colour, intoNotch, permission(Permission), allSet, demo(DemoStep), finished }`
  - `public enum TrialState: Equatable, Sendable { case notAsked, asking, ready, failed(String) }`
  - `public enum ProviderChoice: String, CaseIterable, Sendable { case hosted, local, ownKey }`
  - `public enum OnboardingEvent: Equatable, Sendable { case next, choseColour(String), permissionResolved(Permission, PermissionStatus), heard(String), keysHeld, answered(String), skipDemo, trialRequested, trialIssued, trialFailed(String), skipTrial, choseProvider(ProviderChoice) }`
  - `public struct OnboardingModel: Equatable, Sendable` with `init(supportedLanguages: [String], palette: [String])`, read-only `step`, `answers`, `colour`, `permissions`, `heardSomething`, `lastHeard`, `heldKeys`, `trial`, `providerChoice`, `isReasking`, `canContinue`, `availableProviderChoices`, `deniedPermissions`, `opensSetupAfterwards`; `@discardableResult mutating func handle(_ event: OnboardingEvent) -> Bool`; `func apply(to configuration: inout SaathiConfiguration)`; `static let permissionOrder: [Permission]`; `static let defaultColour = "blue"`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/OnboardingModelTests.swift`:

```swift
//
//  OnboardingModelTests.swift
//  SaathiKitTests
//
//  First run, driven by events with no window behind it: the order, what unlocks Continue, the
//  two branches the spec says must never block (a denied permission, a refused trial), and what
//  ends up in shell.json.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class OnboardingModelTests: XCTestCase {

    private let palette = ["green", "blue", "red", "teal"]
    private let languages = ["en-IN", "hi-IN", "ta-IN"]

    private func model() -> OnboardingModel {
        OnboardingModel(supportedLanguages: languages, palette: palette)
    }

    /// Sends events and returns the steps visited, without consecutive repeats.
    private func walk(_ model: inout OnboardingModel, _ events: [OnboardingEvent]) -> [OnboardingStep] {
        var steps = [model.step]
        for event in events {
            model.handle(event)
            if model.step != steps.last { steps.append(model.step) }
        }
        return steps
    }

    private let throughPermissions: [OnboardingEvent] = [
        .next, .choseColour("teal"), .next, .next,
        .permissionResolved(.microphone, .granted),
        .permissionResolved(.speechRecognition, .granted),
        .permissionResolved(.inputMonitoring, .granted),
    ]

    private var throughQuestions: [OnboardingEvent] {
        throughPermissions + [
            .next,                                   // all set → mic check
            .heard("hello"), .next,                  // → hold to talk
            .keysHeld, .next,                        // → questions
            .answered("my name is asha"), .answered("I want to learn the tabla"),
            .answered("calm and slow"), .answered("Tamil"),
        ]
    }

    func testTheWholeHappyPathInOrder() {
        var m = model()
        let steps = walk(&m, throughQuestions + [.trialRequested, .trialIssued, .next, .choseProvider(.hosted)])
        XCTAssertEqual(steps, [
            .welcome, .colour, .intoNotch,
            .permission(.microphone), .permission(.speechRecognition), .permission(.inputMonitoring),
            .allSet,
            .demo(.micCheck), .demo(.holdToTalk),
            .demo(.question(.name)), .demo(.question(.firstGoal)), .demo(.question(.manner)), .demo(.question(.language)),
            .demo(.trialChat), .demo(.providerChoice),
            .finished,
        ])
    }

    func testTheThreePermissionsAreTheRequiredThreeInTheSpecsOrder() {
        XCTAssertEqual(OnboardingModel.permissionOrder, [.microphone, .speechRecognition, .inputMonitoring])
        XCTAssertEqual(Set(OnboardingModel.permissionOrder), Set(Permission.allCases.filter(\.isRequired)))
    }

    // MARK: colour

    func testAColourOutsideThePaletteIsIgnoredAndNoChoiceMeansBlue() {
        var m = model()
        m.handle(.next)
        XCTAssertFalse(m.handle(.choseColour("mauve")))
        XCTAssertNil(m.colour)
        m.handle(.next)
        XCTAssertEqual(m.step, .intoNotch)
        var configuration = SaathiConfiguration()
        m.apply(to: &configuration)
        XCTAssertEqual(configuration.colour, "blue")
    }

    func testChoosingAColourDoesNotLeaveTheCard() {
        var m = model()
        m.handle(.next)
        XCTAssertTrue(m.handle(.choseColour("teal")))
        XCTAssertTrue(m.handle(.choseColour("red")), "they are trying colours on; the mascot follows")
        XCTAssertEqual(m.step, .colour)
        XCTAssertEqual(m.colour, "red")
    }

    // MARK: permissions

    /// "A denied permission shows why it matters and how to grant it later; onboarding continues."
    func testADeniedPermissionIsRecordedAndDoesNotBlock() {
        var m = model()
        let steps = walk(&m, [
            .next, .next, .next,
            .permissionResolved(.microphone, .denied),
            .permissionResolved(.speechRecognition, .granted),
            .permissionResolved(.inputMonitoring, .notDetermined),
        ])
        XCTAssertEqual(steps.last, .allSet)
        XCTAssertEqual(m.deniedPermissions, [.microphone, .inputMonitoring])
    }

    func testNextDoesNothingOnAPermissionStepUntilMacOSHasAnswered() {
        var m = model()
        _ = walk(&m, [.next, .next, .next])
        XCTAssertEqual(m.step, .permission(.microphone))
        XCTAssertFalse(m.canContinue)
        XCTAssertFalse(m.handle(.next))
        XCTAssertEqual(m.step, .permission(.microphone))
    }

    /// The Input Monitoring grant lands seconds later, from System Settings, possibly while a
    /// different step is showing. It is recorded; it does not move anything.
    func testAVerdictForAPermissionThatIsNotTheCurrentStepIsRecordedOnly() {
        var m = model()
        _ = walk(&m, [.next, .next, .next, .permissionResolved(.microphone, .denied)])
        XCTAssertEqual(m.step, .permission(.speechRecognition))
        m.handle(.permissionResolved(.microphone, .granted))
        XCTAssertEqual(m.step, .permission(.speechRecognition))
        XCTAssertEqual(m.deniedPermissions, [])
    }

    // MARK: demo gates

    func testTheMicCheckContinuesOnlyOnceSomethingWasHeard() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next])
        XCTAssertEqual(m.step, .demo(.micCheck))
        XCTAssertFalse(m.canContinue)
        XCTAssertFalse(m.handle(.next))
        m.handle(.heard("   "))
        XCTAssertFalse(m.canContinue, "silence transcribed as whitespace is not hearing someone")
        m.handle(.heard("hello saathi"))
        XCTAssertTrue(m.canContinue)
        XCTAssertEqual(m.lastHeard, "hello saathi")
        m.handle(.next)
        XCTAssertEqual(m.step, .demo(.holdToTalk))
    }

    func testHoldToTalkContinuesOnlyOnceTheKeysWereHeld() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next])
        XCTAssertFalse(m.canContinue)
        m.handle(.heard("hi"))
        XCTAssertFalse(m.canContinue, "talking without the keys is not what this step teaches")
        m.handle(.keysHeld)
        XCTAssertTrue(m.canContinue)
    }

    /// Someone whose Input Monitoring was denied can never hold the keys. The step must not trap them.
    func testHoldToTalkIsPassableWhenInputMonitoringWasNotGranted() {
        var m = model()
        _ = walk(&m, [
            .next, .next, .next,
            .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted),
            .permissionResolved(.inputMonitoring, .notDetermined),
            .next, .heard("hi"), .next,
        ])
        XCTAssertEqual(m.step, .demo(.holdToTalk))
        XCTAssertTrue(m.canContinue)
    }

    func testSkipDemoFinishesFromAnyDemoStepAndFromNowhereElse() {
        var early = model()
        XCTAssertFalse(early.handle(.skipDemo), "there is no Skip demo on the welcome card")

        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha")])
        XCTAssertTrue(m.handle(.skipDemo))
        XCTAssertEqual(m.step, .finished)
        var configuration = SaathiConfiguration()
        m.apply(to: &configuration)
        XCTAssertEqual(configuration.name, "Asha", "what was already answered is kept")
        XCTAssertEqual(configuration.onboarded, true)
        XCTAssertNil(configuration.provider, "skipping never chooses where Saathi thinks")
        XCTAssertTrue(m.opensSetupAfterwards)
    }

    // MARK: questions

    func testAnAnswerItCannotReadIsAskedOnceMoreThenDefaulted() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha"), .answered("the tabla")])
        XCTAssertEqual(m.step, .demo(.question(.manner)))

        m.handle(.answered("whatever you think"))
        XCTAssertEqual(m.step, .demo(.question(.manner)))
        XCTAssertTrue(m.isReasking)

        m.handle(.answered("I really don't mind"))
        XCTAssertEqual(m.step, .demo(.question(.language)))
        XCTAssertFalse(m.isReasking, "the next question starts fresh")
        XCTAssertEqual(m.answers.manner, .warmAndNormal, "the default is the middle one")

        m.handle(.answered("Klingon")); m.handle(.answered("Klingon"))
        XCTAssertEqual(m.step, .demo(.trialChat))
        XCTAssertEqual(m.answers.language, "en-IN", "the default is the first supported tag — the app lists the machine's own first")
    }

    func testAnEmptyNameIsAskedOnceMoreThenLeftUnset() {
        var m = model()
        _ = walk(&m, throughPermissions + [.next, .heard("hi"), .next, .keysHeld, .next])
        m.handle(.answered("..."))
        XCTAssertEqual(m.step, .demo(.question(.name)))
        m.handle(.answered(""))
        XCTAssertEqual(m.step, .demo(.question(.firstGoal)))
        XCTAssertNil(m.answers.name, "nobody is called a default")
    }

    func testAnsweredIsIgnoredOutsideAQuestion() {
        var m = model()
        XCTAssertFalse(m.handle(.answered("Asha")))
        XCTAssertNil(m.answers.name)
    }

    // MARK: trial and provider

    /// "Trial refused: step 6.4 says the exact reason in words and offers Skip; nothing else changes."
    func testARefusedTrialKeepsItsReasonOffersSkipAndNeverOffersHosted() {
        var m = model()
        _ = walk(&m, throughQuestions)
        XCTAssertEqual(m.step, .demo(.trialChat))
        m.handle(.trialRequested)
        XCTAssertEqual(m.trial, .asking)
        XCTAssertFalse(m.canContinue)

        m.handle(.trialFailed("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertEqual(m.trial, .failed("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertFalse(m.handle(.next), "there is no chat to have had")

        XCTAssertTrue(m.handle(.skipTrial))
        XCTAssertEqual(m.step, .demo(.providerChoice))
        XCTAssertEqual(m.availableProviderChoices, [.local, .ownKey])
        XCTAssertFalse(m.handle(.choseProvider(.hosted)), "never a fallback to hosted")
        XCTAssertEqual(m.step, .demo(.providerChoice))
    }

    func testATrialCanBeRetriedAfterAFailure() {
        var m = model()
        _ = walk(&m, throughQuestions + [.trialRequested, .trialFailed("could not reach the backend")])
        m.handle(.trialRequested)
        XCTAssertEqual(m.trial, .asking)
        m.handle(.trialIssued)
        XCTAssertEqual(m.trial, .ready)
        XCTAssertTrue(m.canContinue)
        XCTAssertEqual(m.availableProviderChoices, [.hosted, .local, .ownKey])
    }

    func testTrialEventsAreIgnoredOutsideTheTrialStep() {
        var m = model()
        XCTAssertFalse(m.handle(.trialIssued))
        XCTAssertEqual(m.trial, .notAsked)
    }

    // MARK: what is written

    func testApplyWritesWhatWasLearnedAndLeavesTheRestAlone() {
        var m = model()
        _ = walk(&m, throughQuestions + [.trialRequested, .trialIssued, .next, .choseProvider(.hosted)])
        var configuration = SaathiConfiguration(openaiKey: "sk-kept", token: "saathi_trial_abc", deviceId: "d")
        m.apply(to: &configuration)

        XCTAssertEqual(configuration.name, "Asha")
        XCTAssertEqual(configuration.colour, "teal")
        XCTAssertEqual(configuration.firstGoal, "the tabla")
        XCTAssertEqual(configuration.tone, .calm)
        XCTAssertEqual(configuration.pace, .slow)
        XCTAssertEqual(configuration.language, "ta-IN")
        XCTAssertEqual(configuration.provider, .hosted)
        XCTAssertEqual(configuration.onboarded, true)
        XCTAssertEqual(configuration.openaiKey, "sk-kept")
        XCTAssertEqual(configuration.token, "saathi_trial_abc", "the token is TrialEnrollment's to write, not this model's")
        XCTAssertFalse(m.opensSetupAfterwards)
    }

    func testLocalIsWrittenAndOwnKeyLeavesTheProviderForSetup() {
        var local = model()
        _ = walk(&local, throughQuestions + [.skipTrial, .choseProvider(.local)])
        var a = SaathiConfiguration(provider: .openai)
        local.apply(to: &a)
        XCTAssertEqual(a.provider, .local)
        XCTAssertFalse(local.opensSetupAfterwards)

        var own = model()
        _ = walk(&own, throughQuestions + [.skipTrial, .choseProvider(.ownKey)])
        var b = SaathiConfiguration()
        own.apply(to: &b)
        XCTAssertNil(b.provider, "Setup decides the provider from the keys that validate, as it does today")
        XCTAssertTrue(own.opensSetupAfterwards)
        XCTAssertEqual(own.step, .finished)
    }

    /// Quitting halfway must not mark first run done, or it never comes back.
    func testApplyBeforeTheEndDoesNotClaimToBeOnboarded() {
        var m = model()
        _ = walk(&m, throughPermissions)
        var configuration = SaathiConfiguration()
        m.apply(to: &configuration)
        XCTAssertNil(configuration.onboarded)
        XCTAssertEqual(configuration.colour, "teal", "what was chosen is still kept")
    }

    func testRunningItAgainStartsFromTheTopWithNothingRemembered() {
        var m = model()
        _ = walk(&m, throughQuestions)
        m = model()
        XCTAssertEqual(m.step, .welcome)
        XCTAssertEqual(m.answers, OnboardingAnswers())
    }
}
```

- [ ] **Step 2: Run to see it fail.**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `error: cannot find 'OnboardingModel' in scope`

- [ ] **Step 3: Implement.** Create `Sources/SaathiKit/OnboardingModel.swift`:

```swift
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
```

- [ ] **Step 4: Run the tests.**

Run: `swift test --filter OnboardingModelTests 2>&1 | grep -E "error:|failed|Executed"`
Expected: `Executed 21 tests, with 0 failures`.

Note on `testAColourOutsideThePaletteIsIgnoredAndNoChoiceMeansBlue`: `apply(to:)` writes the default colour once the welcome card has been left, which that test has. Note on `testLocalIsWrittenAndOwnKeyLeavesTheProviderForSetup`: `.skipTrial` from `.notAsked` is allowed on purpose — someone who does not want their voice on Saathi's servers even for these minutes must be able to say so before the request is made.

- [ ] **Step 5: Run the whole suite, then commit.**

Run: `swift test 2>&1 | grep -E "error:|failed"`
Expected: no output.

```bash
git add Sources/SaathiKit/OnboardingModel.swift Tests/SaathiKitTests/OnboardingModelTests.swift
git commit -m "First run is a value: its order, its gates, and the two things that must never block it"
```

---

### Task 3: Everything Saathi says — `OnboardingScript`

**Files:**
- Create: `Sources/SaathiKit/OnboardingScript.swift`
- Test: `Tests/SaathiKitTests/OnboardingScriptTests.swift`

**Interfaces:**
- Consumes: `OnboardingModel`, `OnboardingStep`, `DemoStep`, `OnboardingQuestion`, `Manner`, `TrialState`, `ProviderChoice` (Tasks 1–2); `Permission.reason`, `Permission.title`.
- Produces:
  - `public struct OnboardingLine: Equatable, Sendable { let title: String; let spoken: String; let tone: Tone }`
  - `public enum OnboardingScript { static func line(for model: OnboardingModel) -> OnboardingLine; static func acknowledgement(of question: OnboardingQuestion, in answers: OnboardingAnswers) -> String; static func deniedNote(for permission: Permission) -> String; static func title(for choice: ProviderChoice) -> String; static func detail(for choice: ProviderChoice) -> String; static let hostedDisclosure: String; static let startAtLoginNote: String; static let inputMonitoringHelper: String }`
  - 4b speaks `line.spoken` with `line.tone` on entering a step, shows `line.title` on the card, and speaks `acknowledgement` when a question step is left.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/OnboardingScriptTests.swift`:

```swift
//
//  OnboardingScriptTests.swift
//  SaathiKitTests
//
//  "Everything on a card is also spoken." These pin the sentences the spec wrote out, and check
//  that no step anywhere in first run is reached with nothing to say.
//

import XCTest
import SaathiContract
@testable import SaathiKit

final class OnboardingScriptTests: XCTestCase {

    private func model(after events: [OnboardingEvent]) -> OnboardingModel {
        var m = OnboardingModel(supportedLanguages: ["en-IN", "ta-IN"], palette: ["blue", "teal"])
        for event in events { m.handle(event) }
        return m
    }

    private let toAllSet: [OnboardingEvent] = [
        .next, .next, .next,
        .permissionResolved(.microphone, .granted), .permissionResolved(.speechRecognition, .granted),
        .permissionResolved(.inputMonitoring, .granted),
    ]
    private var toTrial: [OnboardingEvent] {
        toAllSet + [.next, .heard("hi"), .next, .keysHeld, .next,
                    .answered("Asha"), .answered("the tabla"), .answered("plain"), .answered("Tamil")]
    }

    func testTheSentencesTheSpecWroteOutAreSpokenVerbatim() {
        XCTAssertEqual(
            OnboardingScript.line(for: model(after: [])).spoken,
            "Namaste. I'm Saathi, a companion for learning new things. I'll talk you through this.")
        XCTAssertEqual(
            OnboardingScript.line(for: model(after: [.next, .next])).spoken,
            "I live up here now. I need three permissions to get started.")
        XCTAssertEqual(
            OnboardingScript.line(for: model(after: toAllSet)).spoken,
            "Turn your sound on. Meet Saathi.")
        XCTAssertEqual(
            OnboardingScript.hostedDisclosure,
            "For this chat I'll use Saathi's hosted service. Your voice goes to Saathi's servers and its "
                + "provider for these minutes. After this you choose where I think.")
        XCTAssertEqual(OnboardingScript.inputMonitoringHelper, "I'm Saathi. Turn me on in the list.")
    }

    func testTheDemoCardsCarryTheSpecsTitles() {
        XCTAssertEqual(OnboardingScript.line(for: model(after: toAllSet + [.next])).title, "Can I hear you?")
        XCTAssertEqual(OnboardingScript.line(for: model(after: toAllSet + [.next, .heard("hi"), .next])).title, "This is how you talk to me.")
        XCTAssertEqual(OnboardingScript.line(for: model(after: toTrial)).title, "Talk to me properly.")
        XCTAssertEqual(OnboardingScript.line(for: model(after: toTrial + [.skipTrial])).title, "Where should I think from now on?")
    }

    /// One source of truth: the reason on the permission step is the reason everywhere else.
    func testAPermissionStepSaysThatPermissionsOwnReason() {
        let line = OnboardingScript.line(for: model(after: [.next, .next, .next]))
        XCTAssertEqual(line.title, "Microphone")
        XCTAssertEqual(line.spoken, Permission.microphone.reason)
    }

    func testTheTrialStepSaysTheDisclosureBeforeAndTheExactReasonAfterARefusal() {
        XCTAssertEqual(OnboardingScript.line(for: model(after: toTrial)).spoken, OnboardingScript.hostedDisclosure)

        let refused = model(after: toTrial + [.trialRequested, .trialFailed("that is five trial requests from this network today; try again tomorrow")])
        let line = OnboardingScript.line(for: refused)
        XCTAssertTrue(line.spoken.contains("that is five trial requests from this network today; try again tomorrow"))
        XCTAssertTrue(line.spoken.contains("skip"), "the refusal offers the way on")
        XCTAssertEqual(line.tone, .calm)
    }

    func testAReaskIsWordedDifferentlyFromTheFirstAsking() {
        let asking = model(after: toAllSet + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha"), .answered("the tabla")])
        let reasking = model(after: toAllSet + [.next, .heard("hi"), .next, .keysHeld, .next, .answered("Asha"), .answered("the tabla"), .answered("dunno")])
        XCTAssertNotEqual(OnboardingScript.line(for: asking).spoken, OnboardingScript.line(for: reasking).spoken)
        for manner in Manner.allCases {
            XCTAssertTrue(OnboardingScript.line(for: reasking).spoken.contains(manner.title), "the re-ask repeats the choices")
        }
    }

    func testAcknowledgementsUseWhatWasSaidAndSurviveNothingHavingBeenSaid() {
        let answers = OnboardingAnswers(name: "Asha", firstGoal: "the tabla", manner: .calmAndSlow, language: "ta-IN")
        XCTAssertTrue(OnboardingScript.acknowledgement(of: .name, in: answers).contains("Asha"))
        XCTAssertTrue(OnboardingScript.acknowledgement(of: .firstGoal, in: answers).contains("the tabla"))
        XCTAssertTrue(OnboardingScript.acknowledgement(of: .language, in: answers).contains("Tamil"))
        for question in OnboardingQuestion.allCases {
            XCTAssertFalse(OnboardingScript.acknowledgement(of: question, in: answers).isEmpty)
            XCTAssertFalse(OnboardingScript.acknowledgement(of: question, in: OnboardingAnswers()).isEmpty, "\(question) with no answer")
        }
    }

    func testEveryStepHasSomethingToShowAndSomethingToSay() {
        var steps: [OnboardingModel] = [model(after: [])]
        var m = model(after: [])
        for event in toTrial + [.trialRequested, .trialIssued, .next, .choseProvider(.local)] {
            m.handle(event)
            steps.append(m)
        }
        XCTAssertEqual(steps.last?.step, .finished)
        for snapshot in steps {
            let line = OnboardingScript.line(for: snapshot)
            XCTAssertFalse(line.title.isEmpty, "\(snapshot.step) has no title")
            XCTAssertFalse(line.spoken.isEmpty, "\(snapshot.step) has nothing to say")
        }
    }

    func testEveryProviderChoiceSaysWhereTheVoiceGoes() {
        for choice in ProviderChoice.allCases {
            XCTAssertFalse(OnboardingScript.title(for: choice).isEmpty)
            XCTAssertFalse(OnboardingScript.detail(for: choice).isEmpty)
        }
        XCTAssertTrue(OnboardingScript.detail(for: .local).contains("stays on this Mac"))
        XCTAssertTrue(OnboardingScript.detail(for: .hosted).contains("Saathi's servers"))
    }

    func testEveryPermissionHasADeniedNoteThatSaysHowToFixItLater() {
        for permission in OnboardingModel.permissionOrder {
            XCTAssertTrue(OnboardingScript.deniedNote(for: permission).contains("System Settings"), "\(permission)")
        }
    }
}
```

- [ ] **Step 2: Run to see it fail.**

Run: `swift build --build-tests 2>&1 | grep error | head -3`
Expected: `error: cannot find 'OnboardingScript' in scope`

- [ ] **Step 3: Implement.** Create `Sources/SaathiKit/OnboardingScript.swift`:

```swift
//
//  OnboardingScript.swift
//  SaathiKit
//
//  Every line Saathi says during first run, and the title of the card it says it on.
//
//  The spec's rule is that everything on a card is also spoken: someone who cannot see the card
//  must be able to complete first run, which is the whole premise of the product applied to its own
//  front door. One table makes that checkable — a step with nothing to say fails a test — where
//  sentences scattered through view code would have it true of the steps someone remembered.
//
//  Sentences the spec wrote out are verbatim. The rest are in the same voice: short, first person,
//  said the way you would say them to someone sitting next to you.
//

import Foundation
import SaathiContract

public struct OnboardingLine: Equatable, Sendable {
    /// Shown on the card or in the notch panel.
    public let title: String
    /// Spoken when the step is entered.
    public let spoken: String
    public let tone: Tone

    public init(title: String, spoken: String, tone: Tone = .encouraging) {
        self.title = title
        self.spoken = spoken
        self.tone = tone
    }
}

public enum OnboardingScript {

    public static let hostedDisclosure =
        "For this chat I'll use Saathi's hosted service. Your voice goes to Saathi's servers and its "
        + "provider for these minutes. After this you choose where I think."

    /// Said once on the welcome card, next to the switch that undoes it.
    public static let startAtLoginNote = "I've set myself to start when you log in. You can turn that off right here."

    /// The floating card beside System Settings while Input Monitoring is being granted.
    public static let inputMonitoringHelper = "I'm Saathi. Turn me on in the list."

    public static func line(for model: OnboardingModel) -> OnboardingLine {
        switch model.step {
        case .welcome:
            return OnboardingLine(
                title: "Namaste",
                spoken: "Namaste. I'm Saathi, a companion for learning new things. I'll talk you through this.")
        case .colour:
            return OnboardingLine(title: "Pick a colour", spoken: "Pick a colour for me. Any of these ten. You can change it later.")
        case .intoNotch:
            return OnboardingLine(
                title: "I live up here now",
                spoken: "I live up here now. I need three permissions to get started.")
        case let .permission(permission):
            return OnboardingLine(title: permission.title, spoken: permission.reason, tone: .calm)
        case .allSet:
            return OnboardingLine(title: "All set", spoken: "Turn your sound on. Meet Saathi.")
        case let .demo(demo):
            return line(for: demo, in: model)
        case .finished:
            return OnboardingLine(
                title: "Ready",
                spoken: model.opensSetupAfterwards
                    ? "That's everything. I've opened Setup, so you can tell me where to think."
                    : "That's everything. Hold control and option whenever you want me.")
        }
    }

    private static func line(for demo: DemoStep, in model: OnboardingModel) -> OnboardingLine {
        switch demo {
        case .micCheck:
            return OnboardingLine(
                title: "Can I hear you?",
                spoken: "Can I hear you? Say anything. You'll see the bars move, and I'll show you what I heard.")
        case .holdToTalk:
            return OnboardingLine(
                title: "This is how you talk to me.",
                spoken: model.permissions[.inputMonitoring] == .granted
                    ? "This is how you talk to me. Hold control and option, and say hi."
                    : "This is how you talk to me: hold control and option, and speak. That needs Input Monitoring, which isn't on yet, so for now use Talk in the menu.")
        case let .question(question):
            return OnboardingLine(
                title: title(for: question),
                spoken: model.isReasking ? reask(question) : ask(question),
                tone: .calm)
        case .trialChat:
            return trialLine(for: model.trial)
        case .providerChoice:
            return OnboardingLine(
                title: "Where should I think from now on?",
                spoken: model.availableProviderChoices.contains(.hosted)
                    ? "Where should I think from now on? Keep using Saathi's service, use a model on this Mac, or use your own key."
                    : "Where should I think from now on? A model on this Mac, or your own key.",
                tone: .calm)
        }
    }

    private static func trialLine(for trial: TrialState) -> OnboardingLine {
        let title = "Talk to me properly."
        switch trial {
        case .notAsked:
            return OnboardingLine(title: title, spoken: hostedDisclosure, tone: .calm)
        case .asking:
            return OnboardingLine(title: title, spoken: "One moment. I'm setting that up.", tone: .calm)
        case .ready:
            return OnboardingLine(title: title, spoken: "Ready. Hold control and option, and ask me anything.")
        case let .failed(reason):
            return OnboardingLine(
                title: title,
                spoken: "I couldn't set that up: \(reason). You can try again, or skip this and choose where I think.",
                tone: .calm)
        }
    }

    private static func title(for question: OnboardingQuestion) -> String {
        switch question {
        case .name: return "What should I call you?"
        case .firstGoal: return "What do you want to start with?"
        case .manner: return "How should I speak?"
        case .language: return "Which language?"
        }
    }

    private static var mannerChoices: String {
        let titles = Manner.allCases.map(\.title)
        return titles.dropLast().joined(separator: ", ") + ", or " + (titles.last ?? "")
    }

    private static func ask(_ question: OnboardingQuestion) -> String {
        switch question {
        case .name: return "What should I call you?"
        case .firstGoal: return "What do you want to learn, or play with, first?"
        case .manner: return "How would you like me to speak: \(mannerChoices)?"
        case .language: return "Which language shall we talk in?"
        }
    }

    private static func reask(_ question: OnboardingQuestion) -> String {
        switch question {
        case .name: return "Sorry, I didn't catch a name. What should I call you? You can type it too."
        case .firstGoal: return "Sorry, I missed that. What would you like to start with? You can type it too."
        case .manner: return "Sorry, I need one of these: \(mannerChoices). Which would you like?"
        case .language: return "Sorry, that isn't one I can listen in on this Mac. You can pick from the list on the card."
        }
    }

    /// Said on leaving a question. Works with nothing answered, because a question can be left
    /// that way.
    public static func acknowledgement(of question: OnboardingQuestion, in answers: OnboardingAnswers) -> String {
        switch question {
        case .name:
            return answers.name.map { "Good to meet you, \($0)." } ?? "That's fine. We can do names later."
        case .firstGoal:
            return answers.firstGoal.map { "\($0). Good, we'll start there." } ?? "No hurry. We'll find something."
        case .manner:
            return "Okay, \((answers.manner ?? .warmAndNormal).title) it is."
        case .language:
            let name = answers.language.flatMap { tag -> String? in
                let code = Locale(identifier: tag).language.languageCode?.identifier ?? tag
                return Locale(identifier: "en").localizedString(forLanguageCode: code)
            }
            return name.map { "\($0) it is." } ?? "We'll carry on as we are."
        }
    }

    public static func deniedNote(for permission: Permission) -> String {
        let cost: String
        switch permission {
        case .microphone: cost = "Without the microphone I can't hear you at all."
        case .speechRecognition: cost = "Without it I can't turn your voice into words on this Mac."
        case .inputMonitoring: cost = "Without it I can't notice the keys, so you'd use Talk in the menu instead."
        case .screenRecording: cost = "Without it I can't look at your screen when you ask."
        case .accessibility: cost = "Without it I'm less sure exactly what your pointer is on."
        }
        return "\(cost) You can turn it on later in System Settings, under Privacy and Security, \(permission.title)."
    }

    public static func title(for choice: ProviderChoice) -> String {
        switch choice {
        case .hosted: return "Keep using Saathi's service"
        case .local: return "A model on this Mac"
        case .ownKey: return "Your own key"
        }
    }

    public static func detail(for choice: ProviderChoice) -> String {
        switch choice {
        case .hosted: return "Your voice goes to Saathi's servers and its provider. Three conversations a day, for the rest of your seven-day trial."
        case .local: return "Everything stays on this Mac. It needs a local model running; I'll tell you if I can't find one."
        case .ownKey: return "Your voice goes straight to the provider whose key you paste, never through Saathi's servers."
        }
    }
}
```

- [ ] **Step 4: Run the tests.**

Run: `swift test --filter OnboardingScriptTests 2>&1 | grep -E "error:|failed|Executed"`
Expected: `Executed 9 tests, with 0 failures`.

- [ ] **Step 5: Run the whole suite, then commit.**

Run: `swift test 2>&1 | grep -E "error:|failed"`
Expected: no output.

```bash
git add Sources/SaathiKit/OnboardingScript.swift Tests/SaathiKitTests/OnboardingScriptTests.swift
git commit -m "Every step of first run has something to say, and the spec's sentences are said as written"
```

---

## What 4b picks up

Recorded here so the next plan starts from decisions, not from a re-read:

- **Entry.** `configuration.onboarded != true` at launch → first run. The menu's "Run onboarding again" makes a fresh `OnboardingModel`.
- **Inputs the app owes the model.** `supportedLanguages`: `SFSpeechRecognizer.supportedLocales()` as BCP 47 tags, with `Locale.current`'s own tag moved to the front. `palette`: `MascotData.palette.keys`, in `mascot.json`'s order.
- **Event sources.** Buttons → `.next`, `.skipDemo`, `.skipTrial`, `.choseColour`, `.choseProvider`. `Permissions.request` and the existing permission poll → `.permissionResolved`. The voice session's `onUserTranscript` → `.heard` on the first two demo steps and `.answered` on a question step; the "Or type here" field → `.answered`. `HoldToTalkMonitor`'s `.began` → `.keysHeld`. `TrialEnrollment.enroll` → `.trialRequested` before, `.trialIssued` or `.trialFailed(error.description)` after.
- **Persistence.** After every handled event that returns true: `model.apply(to: &configuration)` and save, so a quit halfway loses nothing that was answered.
- **Speech.** On every step change, speak `OnboardingScript.line(for:)`; on leaving a question, speak `acknowledgement` first. On the realtime trial chat the session speaks for itself (`VoiceConductor.performs` already knows).
- **Open, for the user's eye:** whether cards are a centred `NSWindow` as the spec says or live in the island as everything else now does; the mic-check level bars need a tap on `VoiceAudioEngine` that does not exist yet; the two-second model reaction to each answer (spec step 6.3) is unplanned and may be cut.

## Self-Review

- **Spec coverage.** Steps 1–7 of "First run" map onto `OnboardingStep` one to one; step 6's five demo steps are `DemoStep`, with 6.3's four questions as `OnboardingQuestion`. Denied-permission and trial-refused branches → `testADeniedPermissionIsRecordedAndDoesNotBlock`, `testARefusedTrialKeepsItsReasonOffersSkipAndNeverOffersHosted`. "Continue enables when a transcript arrives" → `canContinue`. Tone/pace offer → `Manner`. Language from supported tags only → `AnswerParser.language`. `onboarded = true` at 6.5 → `apply(to:)`. Config round-trip with the new fields is slice 3 Task 1's test, not repeated here.
- **Deliberately absent:** the login-item registration (an `SMAppService` call, 4b — only its sentence is here), the card-shrinks-into-notch animation, level bars, the device picker, the model's one-line reaction.
- **Types.** `OnboardingEvent.heard` / `.answered` / `.keysHeld` are used identically in Tasks 2 and 3's tests. `availableProviderChoices`, `opensSetupAfterwards`, `isReasking`, `deniedPermissions` are defined in Task 2 and consumed in Task 3 under those names. `Permission.isRequired` exists as of commit 6114b29.
