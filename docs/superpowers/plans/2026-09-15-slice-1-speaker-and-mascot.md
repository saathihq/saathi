# Slice 1: Speaker Fix and Mascot Renderer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make spoken output audible from the CLI, and add a native `SaathiMascot` library that draws and animates the pointer character from a JSON port of the mascot data, proven by a preview app showing every expression.

**Architecture:** `SystemSpeaker` waits on the synthesizer delegate instead of polling a flag that is false for the first 50 ms. `SaathiMascot` is a new SwiftPM library target with no dependency on SaathiKit: a `Decodable` model of `mascot.json`, a tiny SVG path parser, pure geometry functions ported from the web renderer's draw loop, and a layer-backed `MascotView` that ticks at display rate. `MascotPreview` is an executable target that shows all 39 expressions in a grid so a human can verify the port.

**Tech Stack:** Swift 5.9 package, macOS 13 floor, AppKit + Core Animation, AVFoundation, XCTest. No third-party dependencies. Python 3 for the one-off data port script.

**Spec:** `docs/superpowers/specs/2026-09-15-app-shell-and-onboarding-design.md` (sections "The mascot renderer" and "The silent speech bug"). This is slice 1 of 5 in the spec's build order; later slices get their own plans.

## Global Constraints

- Package: `macos/Saathi/Package.swift`, `swift-tools-version: 5.9`, `platforms: [.macOS(.v13)]`. Every new API use above macOS 13 is guarded with `#available`.
- No third-party packages.
- Tests are XCTest, run with `cd macos/Saathi && swift test`. All 68 existing tests must keep passing.
- The mascot source data lives outside the repo at `/Users/prasanthsasikumar/pointer-mascots/build_data.json`. The ported `mascot.json` is checked in so the package builds without it.
- Commit messages follow the repo's style: a plain sentence as the title, a short body explaining why, no conventional-commit prefixes. Every commit ends with these two trailer lines:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6
  ```
- Coordinates in `mascot.json` are SVG, y-down. `MascotView` is a flipped `NSView` so the numbers are used unchanged.
- Expression names in code are exactly the JSON keys (for example `powering-down`), so the app, the JSON and the web demo share one vocabulary.

---

## File map

| Path | Responsibility |
|---|---|
| `macos/Saathi/Sources/SaathiKit/Speakers.swift` | Modify: `SystemSpeaker` waits on a delegate; new `UtteranceWaiter`. |
| `macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift` | Create: tests for `UtteranceWaiter`. |
| `macos/Saathi/Package.swift` | Modify: add `SaathiMascot`, `MascotPreview`, `SaathiMascotTests`. |
| `macos/Saathi/scripts/port-mascot.py` | Create: ports `build_data.json` to `mascot.json`. |
| `macos/Saathi/Sources/SaathiMascot/Resources/mascot.json` | Create (generated, checked in): the character data. |
| `macos/Saathi/Sources/SaathiMascot/MascotData.swift` | Create: `Decodable` model and loader. |
| `macos/Saathi/Sources/SaathiMascot/SVGPath.swift` | Create: `M`/`L`/`C`/`Z` path string to `CGPath`. |
| `macos/Saathi/Sources/SaathiMascot/FaceGeometry.swift` | Create: eye and mouth placement maths. |
| `macos/Saathi/Sources/SaathiMascot/MotionTransform.swift` | Create: body motion presets to an affine transform. |
| `macos/Saathi/Sources/SaathiMascot/MascotColor.swift` | Create: palette colour and gradient stops. |
| `macos/Saathi/Sources/SaathiMascot/Expression.swift` | Create: the `Expression` enum. |
| `macos/Saathi/Sources/SaathiMascot/MascotView.swift` | Create: the layer-backed animated view. |
| `macos/Saathi/Sources/MascotPreview/main.swift` | Create: the preview app. |
| `macos/Saathi/Tests/SaathiMascotTests/*.swift` | Create: one test file per source file above. |

---

### Task 1: SystemSpeaker waits for the delegate, not a flag

**Files:**
- Modify: `macos/Saathi/Sources/SaathiKit/Speakers.swift:19-46`
- Test: `macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift`

**Interfaces:**
- Consumes: `Speaker` protocol (`func speak(_ text: String, tone: Tone) async`) from `ActionPerformer.swift`, unchanged.
- Produces: `final class UtteranceWaiter: NSObject, AVSpeechSynthesizerDelegate` with `func wait() async`, internal to SaathiKit (tests use `@testable import`).

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift`:

```swift
//
//  SpeakerTests.swift
//  SaathiKitTests
//
//  AVSpeechSynthesizer reports `isSpeaking == false` for tens of milliseconds after `speak()`,
//  so a poll on that flag returns before any audio and a CLI exits silent. These pin the
//  delegate-driven wait that replaced it.
//

import AVFoundation
import Foundation
import os
import XCTest
@testable import SaathiKit

final class UtteranceWaiterTests: XCTestCase {

    private let synthesizer = AVSpeechSynthesizer()
    private let utterance = AVSpeechUtterance(string: "x")

    func testWaitDoesNotReturnUntilTheDelegateReportsAFinish() async {
        let waiter = UtteranceWaiter()
        let finished = OSAllocatedUnfairLock(initialState: false)
        let waiting = Task {
            await waiter.wait()
            finished.withLock { $0 = true }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished.withLock { $0 }, "wait() returned before the delegate said anything")

        waiter.speechSynthesizer(synthesizer, didFinish: utterance)
        await waiting.value
        XCTAssertTrue(finished.withLock { $0 })
    }

    func testAFinishThatArrivesBeforeWaitDoesNotHang() async {
        let waiter = UtteranceWaiter()
        waiter.speechSynthesizer(synthesizer, didFinish: utterance)
        await waiter.wait()   // would hang forever if the early finish were lost
    }

    func testACancelAlsoEndsTheWait() async {
        let waiter = UtteranceWaiter()
        let waiting = Task { await waiter.wait() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.speechSynthesizer(synthesizer, didCancel: utterance)
        await waiting.value
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter UtteranceWaiterTests 2>&1 | tail -5`
Expected: compile error, `cannot find 'UtteranceWaiter' in scope`.

- [ ] **Step 3: Replace the polling loop with a delegate wait**

In `macos/Saathi/Sources/SaathiKit/Speakers.swift`, replace the whole `SystemSpeaker` class (lines 19 to 46) with:

```swift
public final class SystemSpeaker: Speaker, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()

    public init() {}

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

        // A CLI exits the moment its work is done, which would cut the sentence off — or, as it
        // turned out, before it started: `isSpeaking` stays false for ~50 ms after `speak()`, so
        // polling it returned at once and every spoken command was silent. The delegate is the
        // only signal that means what it says.
        let waiter = UtteranceWaiter()
        synthesizer.delegate = waiter
        synthesizer.speak(utterance)
        await waiter.wait()
        synthesizer.delegate = nil
    }
}

/// Turns the synthesizer's "finished" and "cancelled" delegate calls into one awaitable.
///
/// Handles both orders: `wait()` before the delegate fires (the normal case) and after (a very
/// short utterance on a fast machine), so neither can hang.
final class UtteranceWaiter: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private struct State {
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyFinished = state.withLock { box -> Bool in
                if box.finished { return true }
                box.continuation = continuation
                return false
            }
            if alreadyFinished { continuation.resume() }
        }
    }

    private func finish() {
        let continuation = state.withLock { box -> CheckedContinuation<Void, Never>? in
            box.finished = true
            defer { box.continuation = nil }
            return box.continuation
        }
        continuation?.resume()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finish()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed|error|failed" | tail -3`
Expected: `Executed 71 tests, with 0 failures`.

- [ ] **Step 5: Verify it is audible from the CLI**

Run: `cd macos/Saathi && swift build 2>&1 | tail -1 && time ./.build/debug/saathi say "Hello, I am Saathi." --tone=calm`
Expected: the sentence is heard through the speakers and `real` is between 1.5 s and 4 s. Before this change it was 0.04 s. If it is still under 0.5 s, the delegate is not being delivered on the CLI's main queue: report that with the timing rather than adding a sleep.

- [ ] **Step 6: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiKit/Speakers.swift macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift
git commit -m "Spoken commands were silent: wait for the synthesizer's delegate, not its flag

AVSpeechSynthesizer reports isSpeaking == false for about 50 ms after speak(), so the poll that
was meant to keep the CLI alive until the sentence ended returned immediately and the process
exited before audio began. Every spoken command in 0.5.0 shipped this way. The delegate's
didFinish and didCancel are now the signal, with both orderings handled so nothing hangs.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 2: The `SaathiMascot` target and the ported `mascot.json`

**Files:**
- Modify: `macos/Saathi/Package.swift`
- Create: `macos/Saathi/scripts/port-mascot.py`
- Create: `macos/Saathi/Sources/SaathiMascot/Resources/mascot.json` (generated by the script)
- Create: `macos/Saathi/Sources/SaathiMascot/MascotData.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/MascotDataTests.swift`

**Interfaces:**
- Produces: `public struct MascotData: Decodable, Sendable` with the fields listed in Step 4, `public static func load() throws -> MascotData`, and nested `Box`, `Transform`, `MotionPreset`. Later tasks read `data.faces`, `data.mouths`, `data.gaze`, `data.expressions`, `data.motion`, `data.faceInterval`, `data.blinkInterval`, `data.palette`, `data.bodyPath`, `data.bodyTransform`, `data.faceTransform`, `data.eyeRefX`, `data.viewBox`.

- [ ] **Step 1: Add the targets to the package**

In `macos/Saathi/Package.swift`, add to `products`:

```swift
        .library(name: "SaathiMascot", targets: ["SaathiMascot"]),
```

and add to `targets`, after the `saathi` executable target:

```swift
        // The character. Draws and animates the pointer mascot from Resources/mascot.json, and
        // knows nothing about voice, actions or Saathi — so it can be previewed and tested alone.
        .target(name: "SaathiMascot", resources: [.copy("Resources/mascot.json")]),

        // `swift run MascotPreview`: every expression in a grid, for eyes rather than tests.
        .executableTarget(name: "MascotPreview", dependencies: ["SaathiMascot"]),

        .testTarget(name: "SaathiMascotTests", dependencies: ["SaathiMascot"]),
```

- [ ] **Step 2: Write the port script**

Create `macos/Saathi/scripts/port-mascot.py`:

```python
#!/usr/bin/env python3
"""Ports the pointer-mascot data into Sources/SaathiMascot/Resources/mascot.json.

    scripts/port-mascot.py ~/pointer-mascots/build_data.json

The source lives outside the repository (it was extracted from a web page's bundle by the scripts
in that folder); the output is checked in so the package builds without it. Re-run when the source
changes, and commit the result.

What changes in the port:
  - keys become camelCase and the effects/glyph markup are dropped (the app does not use them);
  - the two SVG transform strings become numbers. The web renderer draws the body through a
    <use> of a path that itself carries translate(210 80), then applies `fit`; both are folded
    into one scale-then-translate `bodyTransform`. The face group's
    translate(anchor) scale(anchor.scale) translate(-120 -122.5) becomes `faceTransform` the
    same way.
"""
import json
import os
import re
import sys

if len(sys.argv) != 2:
    sys.exit(__doc__)

source = json.load(open(sys.argv[1]))
package_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out_path = os.path.join(package_dir, "Sources", "SaathiMascot", "Resources", "mascot.json")

x, y, width, height = (float(v) for v in source["viewBox"].split())
fit = re.fullmatch(r"translate\(([-\d.]+) ([-\d.]+)\) scale\(([-\d.]+)\)", source["fit"])
if not fit:
    sys.exit(f"unexpected fit transform: {source['fit']!r}")
fit_tx, fit_ty, fit_scale = (float(v) for v in fit.groups())
anchor = source["anchor"]

data = {
    "bodyPath": source["body_path"],
    "viewBox": {"x": x, "y": y, "width": width, "height": height},
    "bodyTransform": {
        "scale": fit_scale,
        "tx": 210 * fit_scale + fit_tx,
        "ty": 80 * fit_scale + fit_ty,
    },
    "faceTransform": {
        "scale": anchor["scale"],
        "tx": anchor["x"] - 120 * anchor["scale"],
        "ty": anchor["y"] - 122.5 * anchor["scale"],
    },
    "eyeRefX": source["eyeRefX"],
    "faces": source["faces"],
    "mouths": source["mouths"],
    "gaze": source["gaze"],
    "expressions": source["expressions"],
    "motion": source["motion"],
    "faceInterval": source["faceInterval"],
    "blinkInterval": source["blinkInterval"],
    "palette": source["palette"],
}

os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(data, f, separators=(",", ":"))
    f.write("\n")
print(f"wrote {out_path} ({os.path.getsize(out_path)} bytes)")
```

- [ ] **Step 3: Run the port**

Run: `cd macos/Saathi && chmod +x scripts/port-mascot.py && scripts/port-mascot.py /Users/prasanthsasikumar/pointer-mascots/build_data.json && python3 -c "import json; d=json.load(open('Sources/SaathiMascot/Resources/mascot.json')); print(len(d['faces']), d['bodyTransform'], d['faceTransform'])"`
Expected: `wrote ... mascot.json`, then `25 {'scale': 0.593899, 'tx': 68.16239..., 'ty': 9.83682...} {'scale': 0.74, 'tx': 4.2..., 'ty': 10.35...}`.

- [ ] **Step 4: Write the failing test**

Create `macos/Saathi/Tests/SaathiMascotTests/MascotDataTests.swift`:

```swift
//
//  MascotDataTests.swift
//  SaathiMascotTests
//

import XCTest
@testable import SaathiMascot

final class MascotDataTests: XCTestCase {

    func testTheBundledDataLoads() throws {
        let data = try MascotData.load()
        XCTAssertEqual(data.faces.count, 25)
        XCTAssertEqual(data.mouths.count, 25)
        XCTAssertEqual(data.gaze.count, 25)
        XCTAssertTrue(data.faces.allSatisfy { $0.count == 2 }, "every face is a left and a right eye")
        XCTAssertTrue(data.faces.allSatisfy { $0.allSatisfy { $0.count == 48 } }, "every eye is 48 points")
        XCTAssertTrue(data.mouths.allSatisfy { $0.count == 4 }, "a mouth is half-width, curve, drop, tilt")
    }

    func testTheViewBoxAndTransformsAreTheOnesTheWebRendererUses() throws {
        let data = try MascotData.load()
        XCTAssertEqual(data.viewBox.x, -15)
        XCTAssertEqual(data.viewBox.width, 258.541, accuracy: 0.001)
        XCTAssertEqual(data.eyeRefX, 114.2705, accuracy: 0.0001)
        XCTAssertEqual(data.bodyTransform.scale, 0.593899, accuracy: 0.000001)
        XCTAssertEqual(data.faceTransform.scale, 0.74, accuracy: 0.000001)
    }

    func testEveryExpressionPointsAtRealFacesAndHasTiming() throws {
        let data = try MascotData.load()
        XCTAssertFalse(data.expressions.isEmpty)
        for (name, faces) in data.expressions {
            XCTAssertFalse(faces.isEmpty, "\(name) lists no faces")
            XCTAssertTrue(faces.allSatisfy { (0..<data.faces.count).contains($0) }, "\(name) points off the end")
            XCTAssertNotNil(data.faceInterval[name], "\(name) has no face interval entry")
            XCTAssertNotNil(data.blinkInterval[name], "\(name) has no blink interval entry (null is fine, absent is not)")
        }
    }

    func testMotionPresetsDecodeBothShapesOfValue() throws {
        let data = try MascotData.load()
        XCTAssertEqual(data.motion["sleeping"]?.pulse, [0.028, 4600])
        XCTAssertEqual(data.motion["sleeping"]?.tilt, 2)
        XCTAssertEqual(data.motion["working"]?.squash, 0.22)
        XCTAssertEqual(data.motion["powering-down"]?.settle, 0.05)
        XCTAssertNil(data.motion["idle"]?.bob)
    }

    func testThePaletteHasSaathiBlue() throws {
        XCTAssertEqual(try MascotData.load().palette["blue"], "#377FE6")
    }
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter MascotDataTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'MascotData' in scope`.

- [ ] **Step 6: Write the model**

Create `macos/Saathi/Sources/SaathiMascot/MascotData.swift`:

```swift
//
//  MascotData.swift
//  SaathiMascot
//
//  The character as data: one body outline, 25 faces, and the tables that say which faces an
//  expression uses and how the body moves while it holds one. Ported from the web renderer's
//  bundle by scripts/port-mascot.py; nothing here is hand-typed.
//

import Foundation

public struct MascotData: Decodable, Sendable {

    public struct Box: Decodable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
    }

    /// Scale first, then translate: p' = p * scale + (tx, ty).
    public struct Transform: Decodable, Sendable {
        public var scale: Double
        public var tx: Double
        public var ty: Double

        public var affine: CGAffineTransform {
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
        }
    }

    /// How the body moves while an expression is held. Pairs are [amplitude, period in ms].
    public struct MotionPreset: Decodable, Sendable {
        public var pulse: [Double]?
        public var bob: [Double]?
        public var sway: [Double]?
        public var circle: [Double]?
        public var jitter: [Double]?
        /// [starting scale, duration in ms] — grows in from the starting scale.
        public var enter: [Double]?
        /// Degrees.
        public var tilt: Double?
        /// How much a bob flattens the body at the bottom of its travel.
        public var squash: Double?
        /// Final scale, eased to over 1.4 s.
        public var settle: Double?
    }

    public var bodyPath: String
    public var viewBox: Box
    public var bodyTransform: Transform
    public var faceTransform: Transform
    /// The x the face wraps around when it turns: the centre of the drawing.
    public var eyeRefX: Double
    /// face → eye (left, right) → point → [x, y]
    public var faces: [[[[Double]]]]
    /// face → [half-width, curve, drop below the eyes, tilt in degrees]
    public var mouths: [[Double]]
    /// face → [dx, dy] the whole face drifts by when "look around" is on
    public var gaze: [[Double]]
    /// expression name → face indices, first one shown on entry
    public var expressions: [String: [Int]]
    public var motion: [String: MotionPreset]
    /// expression → [min, max] ms between face changes; null means the face never changes
    public var faceInterval: [String: [Double]?]
    /// expression → [min, max] ms between blinks; null means no auto-blink
    public var blinkInterval: [String: [Double]?]
    public var palette: [String: String]

    public enum LoadError: Error {
        case missingResource
    }

    public static func load() throws -> MascotData {
        guard let url = Bundle.module.url(forResource: "mascot", withExtension: "json") else {
            throw LoadError.missingResource
        }
        return try JSONDecoder().decode(MascotData.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter MascotDataTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 8: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Package.swift macos/Saathi/scripts/port-mascot.py macos/Saathi/Sources/SaathiMascot macos/Saathi/Tests/SaathiMascotTests
git commit -m "SaathiMascot: the character's data, ported from the pointer-mascots bundle

A new library target that will draw the pointer character natively. This commit is the data
and its model only: scripts/port-mascot.py turns build_data.json into mascot.json, folding the
two SVG transform strings into numbers, and MascotData decodes it. The JSON is checked in so the
package builds without the source folder.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 3: SVG path string to `CGPath`

**Files:**
- Create: `macos/Saathi/Sources/SaathiMascot/SVGPath.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/SVGPathTests.swift`

**Interfaces:**
- Consumes: `MascotData.bodyPath: String`.
- Produces: `enum SVGPath { static func cgPath(from d: String) throws -> CGPath }` and `SVGPath.ParseError`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiMascotTests/SVGPathTests.swift`:

```swift
//
//  SVGPathTests.swift
//  SaathiMascotTests
//

import CoreGraphics
import XCTest
@testable import SaathiMascot

final class SVGPathTests: XCTestCase {

    func testMoveCurveAndCloseProduceTheExpectedBounds() throws {
        let path = try SVGPath.cgPath(from: "M0 0 C1 1 2 2 3 3 Z")
        XCTAssertEqual(path.boundingBox, CGRect(x: 0, y: 0, width: 3, height: 3))
    }

    func testLinesAndCommasAndNegativeNumbersAreAccepted() throws {
        let path = try SVGPath.cgPath(from: "M-1,-1 L2,3 L2 -1 Z")
        XCTAssertEqual(path.boundingBox, CGRect(x: -1, y: -1, width: 3, height: 4))
    }

    func testARunOfCurvesAfterOneCommandLetter() throws {
        // SVG lets one C carry several sextuplets.
        let path = try SVGPath.cgPath(from: "M0 0 C0 1 1 1 1 0 1 -1 2 -1 2 0")
        XCTAssertEqual(path.boundingBox.width, 2, accuracy: 0.001)
        XCTAssertEqual(path.currentPoint, CGPoint(x: 2, y: 0))
    }

    func testUnsupportedCommandsAreAnErrorNotAGuess() {
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 Q1 1 2 2")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .unsupportedCommand("Q"))
        }
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 c1 1 2 2 3 3")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .unsupportedCommand("c"))
        }
    }

    func testWrongArgumentCountsAreAnError() {
        XCTAssertThrowsError(try SVGPath.cgPath(from: "M0 0 C1 1 2 2")) { error in
            XCTAssertEqual(error as? SVGPath.ParseError, .wrongArgumentCount(command: "C", found: 4))
        }
    }

    func testTheMascotBodyParsesToASensibleShape() throws {
        let data = try MascotData.load()
        let body = try SVGPath.cgPath(from: data.bodyPath)
        let box = body.boundingBoxOfPath   // tight; `boundingBox` would include control points
        // In the path's own units the pointer is roughly 240 wide and 256 tall, starting near 0,0.
        XCTAssertEqual(box.minX, 0, accuracy: 2)
        XCTAssertEqual(box.minY, 0, accuracy: 2)
        XCTAssertGreaterThan(box.width, 200)
        XCTAssertLessThan(box.width, 260)
        XCTAssertGreaterThan(box.height, 200)
        XCTAssertLessThan(box.height, 270)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter SVGPathTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'SVGPath' in scope`.

- [ ] **Step 3: Write the parser**

Create `macos/Saathi/Sources/SaathiMascot/SVGPath.swift`:

```swift
//
//  SVGPath.swift
//  SaathiMascot
//
//  Just enough of the SVG path grammar for the mascot body: absolute M, L, C and Z. Anything else
//  is an error, because a silently wrong outline is worse than a loud one.
//

import CoreGraphics

enum SVGPath {

    enum ParseError: Error, Equatable {
        case unsupportedCommand(Character)
        case malformedNumber(String)
        case wrongArgumentCount(command: Character, found: Int)
    }

    static func cgPath(from d: String) throws -> CGPath {
        let path = CGMutablePath()
        var command: Character?
        var numbers: [CGFloat] = []
        var token = ""

        func flushToken() throws {
            guard !token.isEmpty else { return }
            guard let value = Double(token) else { throw ParseError.malformedNumber(token) }
            numbers.append(CGFloat(value))
            token = ""
        }

        func apply() throws {
            guard let c = command else { return }
            switch c {
            case "M":
                guard numbers.count == 2 else { throw ParseError.wrongArgumentCount(command: c, found: numbers.count) }
                path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L":
                guard numbers.count == 2 else { throw ParseError.wrongArgumentCount(command: c, found: numbers.count) }
                path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C":
                guard !numbers.isEmpty, numbers.count % 6 == 0 else {
                    throw ParseError.wrongArgumentCount(command: c, found: numbers.count)
                }
                for i in stride(from: 0, to: numbers.count, by: 6) {
                    path.addCurve(
                        to: CGPoint(x: numbers[i + 4], y: numbers[i + 5]),
                        control1: CGPoint(x: numbers[i], y: numbers[i + 1]),
                        control2: CGPoint(x: numbers[i + 2], y: numbers[i + 3])
                    )
                }
            case "Z":
                guard numbers.isEmpty else { throw ParseError.wrongArgumentCount(command: c, found: numbers.count) }
                path.closeSubpath()
            default:
                throw ParseError.unsupportedCommand(c)
            }
            numbers.removeAll()
        }

        for character in d {
            if character.isLetter {
                try flushToken()
                try apply()
                command = character
            } else if character == " " || character == "," || character == "\n" || character == "\t" {
                try flushToken()
            } else if character == "-", !token.isEmpty, !token.hasSuffix("e"), !token.hasSuffix("E") {
                // "1-2" is two numbers; "1e-2" is one.
                try flushToken()
                token = "-"
            } else {
                token.append(character)
            }
        }
        try flushToken()
        try apply()
        return path
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter SVGPathTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiMascot/SVGPath.swift macos/Saathi/Tests/SaathiMascotTests/SVGPathTests.swift
git commit -m "SaathiMascot: parse the body outline from its SVG path string

Absolute M, L, C and Z only, which is all the mascot body uses. Anything else throws, so a new
body drawing that leans on a command this does not know fails a test instead of drawing wrong.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 4: Face geometry, ported from the web draw loop

**Files:**
- Create: `macos/Saathi/Sources/SaathiMascot/FaceGeometry.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/FaceGeometryTests.swift`

**Interfaces:**
- Consumes: `MascotData.faces`, `.mouths`, `.eyeRefX`.
- Produces:
  ```swift
  enum FaceGeometry {
      struct Eye { var points: [CGPoint]; var centroid: CGPoint { get }; var halfHeight: CGFloat { get } }
      struct Placement { var path: CGPath; var transform: CGAffineTransform; var visible: Bool }
      static func eyes(from face: [[[Double]]], drift: CGPoint) -> [Eye]
      static func eyePlacement(_ eye: Eye, blink: CGFloat, turn: CGFloat, shift: CGPoint, eyeRefX: CGFloat) -> Placement
      static func mouthPlacement(eyes: [Eye], mouth: [Double], turn: CGFloat, shift: CGPoint, eyeRefX: CGFloat) -> Placement
  }
  ```
  `turn` is radians of head turn (spin), `shift` is the pointer-follow offset in face units, `drift` is the per-face gaze offset already multiplied by "look around".

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiMascotTests/FaceGeometryTests.swift`:

```swift
//
//  FaceGeometryTests.swift
//  SaathiMascotTests
//
//  The maths is a port of the web renderer's draw loop. These pin the properties a face must have
//  at rest, on a blink, and when turned away — with numbers, not pixels.
//

import CoreGraphics
import XCTest
@testable import SaathiMascot

final class FaceGeometryTests: XCTestCase {

    private var data: MascotData!
    private var eyes: [FaceGeometry.Eye]!

    override func setUpWithError() throws {
        data = try MascotData.load()
        eyes = FaceGeometry.eyes(from: data.faces[1], drift: .zero)   // the "listening" face
    }

    func testAtRestAnEyeStaysWhereItWasDrawn() {
        for eye in eyes {
            let placement = FaceGeometry.eyePlacement(eye, blink: 1, turn: 0, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
            let moved = eye.centroid.applying(placement.transform)
            XCTAssertEqual(moved.x, eye.centroid.x, accuracy: 0.001)
            XCTAssertEqual(moved.y, eye.centroid.y, accuracy: 0.001)
            XCTAssertTrue(placement.visible)
            XCTAssertGreaterThan(placement.path.boundingBox.width, 5, "a real outline, not a point")
        }
    }

    func testABlinkSquashesTheEyeVertically() {
        let placement = FaceGeometry.eyePlacement(eyes[0], blink: 0.04, turn: 0, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
        XCTAssertEqual(placement.transform.d, 0.04, accuracy: 0.0001, "y scale is the blink")
        XCTAssertEqual(placement.transform.a, 1, accuracy: 0.0001, "x scale is untouched")
    }

    func testAFullTurnHidesTheEyes() {
        let placement = FaceGeometry.eyePlacement(eyes[0], blink: 1, turn: .pi, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
        XCTAssertFalse(placement.visible)
    }

    func testThePointerShiftMovesTheEyeByTheSameAmount() {
        let placement = FaceGeometry.eyePlacement(eyes[0], blink: 1, turn: 0, shift: CGPoint(x: 5, y: -3), eyeRefX: CGFloat(data.eyeRefX))
        let moved = eyes[0].centroid.applying(placement.transform)
        XCTAssertEqual(moved.x, eyes[0].centroid.x + 5, accuracy: 0.001)
        XCTAssertEqual(moved.y, eyes[0].centroid.y - 3, accuracy: 0.001)
    }

    func testTheMouthSitsBelowBothEyes() {
        let placement = FaceGeometry.mouthPlacement(eyes: eyes, mouth: data.mouths[1], turn: 0, shift: .zero, eyeRefX: CGFloat(data.eyeRefX))
        let lowestEye = max(eyes[0].centroid.y, eyes[1].centroid.y)
        XCTAssertGreaterThan(placement.path.boundingBox.minY, lowestEye, "y is down; the mouth is under the eyes")
        XCTAssertTrue(placement.visible)
        XCTAssertEqual(placement.path.boundingBox.width, CGFloat(data.mouths[1][0]) * 2, accuracy: 0.5, "as wide as twice the half-width")
    }

    func testDriftMovesTheWholeFace() {
        let drifted = FaceGeometry.eyes(from: data.faces[1], drift: CGPoint(x: 2, y: 4))
        XCTAssertEqual(drifted[0].centroid.x, eyes[0].centroid.x + 2, accuracy: 0.001)
        XCTAssertEqual(drifted[1].centroid.y, eyes[1].centroid.y + 4, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter FaceGeometryTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'FaceGeometry' in scope`.

- [ ] **Step 3: Write the geometry**

Create `macos/Saathi/Sources/SaathiMascot/FaceGeometry.swift`:

```swift
//
//  FaceGeometry.swift
//  SaathiMascot
//
//  Where the eyes and mouth go for one face, ported from the web renderer's draw loop. The face
//  is treated as wrapped around a head of radius 105: turning it slides features sideways and
//  narrows them, and a feature past the edge is hidden. Pure functions — no layers, no clocks —
//  so the port can be checked with numbers.
//

import CoreGraphics
import Foundation

enum FaceGeometry {

    struct Eye {
        var points: [CGPoint]

        var centroid: CGPoint {
            let n = CGFloat(points.count)
            return CGPoint(
                x: points.reduce(0) { $0 + $1.x } / n,
                y: points.reduce(0) { $0 + $1.y } / n
            )
        }

        var halfHeight: CGFloat {
            let ys = points.map(\.y)
            return ((ys.max() ?? 0) - (ys.min() ?? 0)) / 2
        }
    }

    /// A path in face units plus the transform that places it, and whether it faces the viewer.
    struct Placement {
        var path: CGPath
        var transform: CGAffineTransform
        var visible: Bool
    }

    /// Radius of the imaginary head the face wraps around, in face units.
    static let headRadius: CGFloat = 105
    /// Scale limits the web renderer clamps to, so a feature never collapses or explodes.
    static let scaleRange: ClosedRange<CGFloat> = 0.02...2.4

    static func eyes(from face: [[[Double]]], drift: CGPoint) -> [Eye] {
        face.map { eye in
            Eye(points: eye.map { CGPoint(x: CGFloat($0[0]) + drift.x, y: CGFloat($0[1]) + drift.y) })
        }
    }

    static func eyePlacement(_ eye: Eye, blink: CGFloat, turn: CGFloat, shift: CGPoint, eyeRefX: CGFloat) -> Placement {
        let c = eye.centroid
        let restAngle = asin(clamp((c.x - eyeRefX) / headRadius, -1...1))
        let angle = restAngle + turn
        let facing = cos(angle)
        let narrowing = max(facing, 0.02) / max(cos(restAngle), 0.02)

        let path = CGMutablePath()
        path.addLines(between: eye.points)
        path.closeSubpath()

        let transform = CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: clamp(narrowing, scaleRange), y: clamp(blink, scaleRange)))
            .concatenating(CGAffineTransform(translationX: eyeRefX + headRadius * sin(angle) + shift.x, y: c.y + shift.y))

        return Placement(path: path, transform: transform, visible: facing > 0.02)
    }

    static func mouthPlacement(eyes: [Eye], mouth: [Double], turn: CGFloat, shift: CGPoint, eyeRefX: CGFloat) -> Placement {
        let left = eyes[0].centroid, right = eyes[1].centroid
        let halfWidth = CGFloat(mouth[0]), curve = CGFloat(mouth[1]), drop = CGFloat(mouth[2]), tilt = CGFloat(mouth[3])

        let across = atan2(right.y - left.y, right.x - left.x)
        let distance = (eyes.map(\.halfHeight).max() ?? 0) + drop
        let centre = CGPoint(
            x: (left.x + right.x) / 2 - sin(across) * distance,
            y: (left.y + right.y) / 2 + cos(across) * distance
        )
        let angle = across + tilt * .pi / 180

        let restAngle = asin(clamp((centre.x - eyeRefX) / headRadius, -1...1))
        let turned = restAngle + turn
        let facing = cos(turned)
        let stretch = max(facing, 0.02) / max(cos(restAngle), 0.02)

        let ct = cos(angle), st = sin(angle)
        func rotated(_ along: CGFloat, _ down: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + along * ct - down * st, y: centre.y + along * st + down * ct)
        }
        let path = CGMutablePath()
        path.move(to: rotated(-halfWidth, 0))
        path.addQuadCurve(to: rotated(halfWidth, 0), control: rotated(0, curve))

        let transform = CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(CGAffineTransform(scaleX: clamp(stretch, scaleRange), y: 1))
            .concatenating(CGAffineTransform(translationX: eyeRefX + headRadius * sin(turned) + shift.x, y: centre.y + shift.y))

        return Placement(path: path, transform: transform, visible: facing > 0.02)
    }

    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter FaceGeometryTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiMascot/FaceGeometry.swift macos/Saathi/Tests/SaathiMascotTests/FaceGeometryTests.swift
git commit -m "SaathiMascot: place the eyes and mouth the way the web renderer does

A port of the draw loop's maths as pure functions: the face wraps a head of radius 105, so a
turn slides features sideways and narrows them; a blink is a vertical squash; the mouth hangs
below the eye line by the mouth's own drop. Tested with numbers so the port can be trusted
before a single layer exists.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 5: Motion presets, palette colour, and the `Expression` enum

**Files:**
- Create: `macos/Saathi/Sources/SaathiMascot/MotionTransform.swift`
- Create: `macos/Saathi/Sources/SaathiMascot/MascotColor.swift`
- Create: `macos/Saathi/Sources/SaathiMascot/Expression.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/MotionTransformTests.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/MascotColorTests.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/ExpressionTests.swift`

**Interfaces:**
- Consumes: `MascotData.MotionPreset`, `MascotData.palette`, `MascotData.expressions`.
- Produces:
  ```swift
  enum MotionTransform {
      static func transform(preset: MascotData.MotionPreset?, elapsed: TimeInterval, strength: CGFloat, pivot: CGPoint, baseline: CGFloat) -> CGAffineTransform
  }
  public struct MascotColor: Equatable, Sendable {
      public var hex: String                       // "#RRGGBB"
      public init(hex: String)
      public init?(paletteName: String, in data: MascotData)
      public var light: String { get }  public var dark: String { get }   // gradient ends
      public var cgColor: CGColor { get }
      public static func cgColor(hex: String) -> CGColor
      public static func mix(_ a: String, _ b: String, _ amount: Double) -> String
  }
  public enum Expression: String, CaseIterable, Sendable   // 39 cases, rawValue == JSON key
  ```

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiMascotTests/MotionTransformTests.swift`:

```swift
//
//  MotionTransformTests.swift
//  SaathiMascotTests
//

import CoreGraphics
import XCTest
@testable import SaathiMascot

final class MotionTransformTests: XCTestCase {

    private let pivot = CGPoint(x: 114.2705, y: 114.2705)
    private let baseline: CGFloat = 228.541

    private func preset(_ name: String) throws -> MascotData.MotionPreset? {
        try MascotData.load().motion[name]
    }

    func testNoPresetAndZeroStrengthAreTheIdentity() throws {
        XCTAssertEqual(MotionTransform.transform(preset: nil, elapsed: 1, strength: 1, pivot: pivot, baseline: baseline), .identity)
        XCTAssertEqual(MotionTransform.transform(preset: try preset("excited"), elapsed: 1, strength: 0, pivot: pivot, baseline: baseline), .identity)
    }

    func testIdleStartsAtRest() throws {
        // idle is a pulse only; sin(0) == 0 so at t = 0 there is nothing to see.
        let t = MotionTransform.transform(preset: try preset("idle"), elapsed: 0, strength: 1, pivot: pivot, baseline: baseline)
        XCTAssertEqual(t.a, 1, accuracy: 1e-9); XCTAssertEqual(t.d, 1, accuracy: 1e-9)
        XCTAssertEqual(t.tx, 0, accuracy: 1e-9); XCTAssertEqual(t.ty, 0, accuracy: 1e-9)
    }

    func testSleepingTiltsByTwoDegreesAroundThePivot() throws {
        let t = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 0, strength: 1, pivot: pivot, baseline: baseline)
        XCTAssertEqual(atan2(t.b, t.a) * 180 / .pi, 2, accuracy: 1e-6)
        let stillPivot = pivot.applying(t)
        XCTAssertEqual(stillPivot.x, pivot.x, accuracy: 1e-6)
        XCTAssertEqual(stillPivot.y, pivot.y, accuracy: 1e-6)
    }

    func testAPulseIsLargestAQuarterPeriodIn() throws {
        // sleeping: pulse [0.028, 4600 ms]
        let t = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 1.15, strength: 1, pivot: pivot, baseline: baseline)
        XCTAssertEqual(hypot(t.a, t.b), 1.028, accuracy: 1e-6)
    }

    func testABobLiftsTheBodyAQuarterPeriodIn() throws {
        // listening: bob [2, 2600 ms] — y is down, so a lift is negative.
        let t = MotionTransform.transform(preset: try preset("listening"), elapsed: 0.65, strength: 1, pivot: pivot, baseline: baseline)
        let moved = pivot.applying(t)
        XCTAssertLessThan(moved.y, pivot.y - 1.9)
    }

    func testStrengthScalesEverything() throws {
        let full = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 0, strength: 1, pivot: pivot, baseline: baseline)
        let half = MotionTransform.transform(preset: try preset("sleeping"), elapsed: 0, strength: 0.5, pivot: pivot, baseline: baseline)
        XCTAssertEqual(atan2(half.b, half.a), atan2(full.b, full.a) / 2, accuracy: 1e-9)
    }

    func testSquashKeepsTheBaselineStill() throws {
        // working: bob [2.5, 900] + squash 0.22. Three-quarters through the period the bob wave is
        // -1, the body is at the bottom of its travel and squashed; the baseline must not move.
        let t = MotionTransform.transform(preset: try preset("working"), elapsed: 0.675, strength: 1, pivot: pivot, baseline: baseline)
        let foot = CGPoint(x: pivot.x, y: baseline).applying(t)
        XCTAssertEqual(foot.x, pivot.x, accuracy: 1e-6)
        XCTAssertEqual(foot.y, baseline + 2.5, accuracy: 1e-6, "only the bob moves it")
    }
}
```

Create `macos/Saathi/Tests/SaathiMascotTests/MascotColorTests.swift`:

```swift
//
//  MascotColorTests.swift
//  SaathiMascotTests
//

import XCTest
@testable import SaathiMascot

final class MascotColorTests: XCTestCase {

    func testMixMatchesTheWebRendererRounding() {
        XCTAssertEqual(MascotColor.mix("#000000", "#ffffff", 0.5), "#808080")
        XCTAssertEqual(MascotColor.mix("#377FE6", "#ffffff", 0), "#377fe6")
        XCTAssertEqual(MascotColor.mix("#377FE6", "#ffffff", 1), "#ffffff")
    }

    func testTheGradientEndsAreLighterAndDarkerThanTheBase() {
        let blue = MascotColor(hex: "#377FE6")
        XCTAssertEqual(blue.light, MascotColor.mix("#377FE6", "#ffffff", 0.55))
        XCTAssertEqual(blue.dark, MascotColor.mix("#377FE6", "#000000", 0.42))
    }

    func testPaletteLookup() throws {
        let data = try MascotData.load()
        XCTAssertEqual(MascotColor(paletteName: "blue", in: data)?.hex, "#377FE6")
        XCTAssertNil(MascotColor(paletteName: "mauve", in: data))
    }

    func testCGColorComponents() {
        let components = MascotColor.cgColor(hex: "#ff8000").components ?? []
        XCTAssertEqual(components.count, 4)
        XCTAssertEqual(components[0], 1, accuracy: 0.001)
        XCTAssertEqual(components[1], 128.0 / 255.0, accuracy: 0.001)
        XCTAssertEqual(components[2], 0, accuracy: 0.001)
    }
}
```

Create `macos/Saathi/Tests/SaathiMascotTests/ExpressionTests.swift`:

```swift
//
//  ExpressionTests.swift
//  SaathiMascotTests
//

import XCTest
@testable import SaathiMascot

final class ExpressionTests: XCTestCase {

    /// The enum and the JSON must agree exactly: a case with no data would show a blank face, and
    /// data with no case would be unreachable.
    func testTheEnumAndTheDataNameTheSameExpressions() throws {
        let data = try MascotData.load()
        let inCode = Set(Expression.allCases.map(\.rawValue))
        let inData = Set(data.expressions.keys)
        XCTAssertEqual(inCode.subtracting(inData), [], "cases with no data")
        XCTAssertEqual(inData.subtracting(inCode), [], "data with no case")
        XCTAssertEqual(Set(data.motion.keys), inCode, "every expression has a motion preset")
    }

    func testTheNamesTheAppWillUseExist() {
        for name in ["idle", "sleeping", "listening", "thinking", "dictating", "working", "celebrate", "alerting", "powering-down"] {
            XCTAssertNotNil(Expression(rawValue: name), name)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter "MotionTransformTests|MascotColorTests|ExpressionTests" 2>&1 | tail -3`
Expected: compile errors for `MotionTransform`, `MascotColor`, `Expression`.

- [ ] **Step 3: Write the three source files**

Create `macos/Saathi/Sources/SaathiMascot/MotionTransform.swift`:

```swift
//
//  MotionTransform.swift
//  SaathiMascot
//
//  How the whole body moves while an expression is held: a port of the web renderer's
//  motionTransform. Everything is a function of elapsed time, so there is no state to get wrong.
//

import CoreGraphics
import Foundation

enum MotionTransform {

    /// - Parameters:
    ///   - pivot: where rotation and scaling turn about — the centre of the drawing.
    ///   - baseline: the y the body stands on; a squash flattens toward it.
    static func transform(
        preset: MascotData.MotionPreset?,
        elapsed: TimeInterval,
        strength: CGFloat,
        pivot: CGPoint,
        baseline: CGFloat
    ) -> CGAffineTransform {
        guard let preset, strength > 0 else { return .identity }
        let ms = elapsed * 1000

        func wave(_ period: Double, _ phase: Double = 0) -> CGFloat {
            CGFloat(sin(ms / period * .pi * 2 + phase))
        }

        var dx: CGFloat = 0, dy: CGFloat = 0
        var rotationDegrees: CGFloat = preset.tilt.map { CGFloat($0) * strength } ?? 0
        var scale: CGFloat = 1
        var squashX: CGFloat = 1, squashY: CGFloat = 1

        if let bob = preset.bob {
            let w = wave(bob[1])
            dy -= CGFloat(bob[0]) * strength * w
            if let squash = preset.squash {
                let amount = CGFloat(squash) * strength * max(0, -w)
                squashY = 1 - 0.5 * amount
                squashX = 1 + 0.5 * amount
            }
        }
        if let circle = preset.circle {
            dx += CGFloat(circle[0]) * strength * wave(circle[1])
            dy += CGFloat(circle[0]) * strength * wave(circle[1], .pi / 2)
        }
        if let sway = preset.sway {
            rotationDegrees += CGFloat(sway[0]) * strength * wave(sway[1])
        }
        if let pulse = preset.pulse {
            scale *= 1 + CGFloat(pulse[0]) * strength * wave(pulse[1])
        }
        if let jitter = preset.jitter {
            dx += CGFloat(jitter[0]) * strength * wave(jitter[1])
            dy += CGFloat(jitter[0]) * strength * wave(0.63 * jitter[1], 1.1)
        }
        if let enter = preset.enter {
            let progress = ms / enter[1]
            if progress < 1 {
                let r = progress - 1
                scale *= CGFloat(enter[0] + (1 - enter[0]) * (1 + 2.7 * r * r * r + 1.7 * r * r))
            }
        }
        if let settle = preset.settle {
            let p = min(max(ms / 1400, 0), 1)
            let eased = p < 0.5 ? 2 * p * p : 1 - 2 * (1 - p) * (1 - p)
            scale *= 1 + CGFloat(settle - 1) * CGFloat(eased) * strength
        }

        // Same order as the SVG transform list: squash about the baseline first, then scale and
        // rotate about the pivot, then translate.
        let squash = about(CGPoint(x: pivot.x, y: baseline), CGAffineTransform(scaleX: squashX, y: squashY))
        let grow = about(pivot, CGAffineTransform(scaleX: scale, y: scale))
        let turn = about(pivot, CGAffineTransform(rotationAngle: rotationDegrees * .pi / 180))
        let slide = CGAffineTransform(translationX: dx, y: dy)
        return squash.concatenating(grow).concatenating(turn).concatenating(slide)
    }

    private static func about(_ centre: CGPoint, _ transform: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -centre.x, y: -centre.y)
            .concatenating(transform)
            .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }
}
```

Create `macos/Saathi/Sources/SaathiMascot/MascotColor.swift`:

```swift
//
//  MascotColor.swift
//  SaathiMascot
//
//  One body colour and the two gradient ends the web renderer derives from it.
//

import CoreGraphics
import Foundation

public struct MascotColor: Equatable, Sendable {
    /// "#RRGGBB", as in the palette.
    public var hex: String

    public init(hex: String) {
        self.hex = hex
    }

    public init?(paletteName: String, in data: MascotData) {
        guard let hex = data.palette[paletteName] else { return nil }
        self.hex = hex
    }

    /// Top-right of the body.
    public var light: String { Self.mix(hex, "#ffffff", 0.55) }
    /// Bottom-left of the body.
    public var dark: String { Self.mix(hex, "#000000", 0.42) }

    public var cgColor: CGColor { Self.cgColor(hex: hex) }

    public static func cgColor(hex: String) -> CGColor {
        let (r, g, b) = channels(hex)
        return CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Linear per-channel blend with the web renderer's rounding, returned lower-case.
    public static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        let (ar, ag, ab) = channels(a), (br, bg, bb) = channels(b)
        func blend(_ x: Int, _ y: Int) -> Int { Int((Double(x) + Double(y - x) * amount).rounded()) }
        return String(format: "#%02x%02x%02x", blend(ar, br), blend(ag, bg), blend(ab, bb))
    }

    private static func channels(_ hex: String) -> (Int, Int, Int) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = Int(digits, radix: 16) ?? 0
        return ((value >> 16) & 255, (value >> 8) & 255, value & 255)
    }
}
```

Create `macos/Saathi/Sources/SaathiMascot/Expression.swift`:

```swift
//
//  Expression.swift
//  SaathiMascot
//
//  Every face the character can hold. The raw values are the keys in mascot.json and the names
//  in the web demo, so the three never drift; a test pins that.
//

public enum Expression: String, CaseIterable, Sendable {
    case sleeping, waking, idle, listening, thinking, searching, working, excited, surprised,
         suspicious, angry, drowsy, happy, curious, confused, bored, proud, shy, sad, laughing,
         scared, playful, celebrate, orbit, radar, progress, spawning, humming, loading, dictating,
         sending, receiving, uploading, writing, notifying, alerting, bouncing, dragging
    case poweringDown = "powering-down"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter "MotionTransformTests|MascotColorTests|ExpressionTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiMascot/MotionTransform.swift macos/Saathi/Sources/SaathiMascot/MascotColor.swift macos/Saathi/Sources/SaathiMascot/Expression.swift macos/Saathi/Tests/SaathiMascotTests/MotionTransformTests.swift macos/Saathi/Tests/SaathiMascotTests/MascotColorTests.swift macos/Saathi/Tests/SaathiMascotTests/ExpressionTests.swift
git commit -m "SaathiMascot: body motion, palette colour, and the expression vocabulary

MotionTransform is the web renderer's motion presets as a function of elapsed time. MascotColor
derives the gradient ends the same way the demo page does. Expression's raw values are the JSON
keys, and a test refuses any drift between the enum and the data in either direction.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 6: `MascotView`

**Files:**
- Create: `macos/Saathi/Sources/SaathiMascot/MascotView.swift`
- Test: `macos/Saathi/Tests/SaathiMascotTests/MascotViewTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2 to 5.
- Produces:
  ```swift
  public final class MascotView: NSView {
      public init(data: MascotData, color: MascotColor, expression: Expression, frame: NSRect)
      public var expression: Expression           // morphs on change
      public var color: MascotColor
      public var lookAround: CGFloat               // 0...1, default 0.5: how much each face's own gaze drifts it
      public var motionStrength: CGFloat          // default 1
      public var animates: Bool                   // default true: auto-blink and face cycling
      public func lookAt(_ point: CGPoint?)       // view coordinates; nil looks straight ahead
      public func blinkNow()
      public func spin()
      public func tick(now: TimeInterval)         // one frame; the ticker calls it, tests can too
  }
  ```

- [ ] **Step 1: Write the failing tests**

Create `macos/Saathi/Tests/SaathiMascotTests/MascotViewTests.swift`:

```swift
//
//  MascotViewTests.swift
//  SaathiMascotTests
//
//  The view is checked by eye in MascotPreview; these only pin the state it exposes and that a
//  frame can be drawn for every expression without an out-of-range face.
//

import AppKit
import XCTest
@testable import SaathiMascot

final class MascotViewTests: XCTestCase {

    private func makeView() throws -> MascotView {
        MascotView(data: try MascotData.load(), color: MascotColor(hex: "#377FE6"), expression: .idle,
                   frame: NSRect(x: 0, y: 0, width: 96, height: 96))
    }

    func testEveryExpressionCanDrawAFrame() throws {
        let view = try makeView()
        for expression in Expression.allCases {
            view.expression = expression
            view.tick(now: 0)
            view.tick(now: 0.5)
            XCTAssertEqual(view.expression, expression)
        }
    }

    func testChangingExpressionSwitchesToItsFirstFace() throws {
        let view = try makeView()
        let data = try MascotData.load()
        view.expression = .listening
        XCTAssertEqual(view.faceIndex, data.expressions["listening"]?.first)
        view.expression = .celebrate
        XCTAssertEqual(view.faceIndex, data.expressions["celebrate"]?.first)
    }

    func testLookAtMapsTheViewToMinusOneToOne() throws {
        let view = try makeView()
        view.lookAt(CGPoint(x: 96, y: 0))       // top-right corner in flipped coordinates
        XCTAssertEqual(view.pointerGazeTarget.x, 1, accuracy: 0.001)
        XCTAssertEqual(view.pointerGazeTarget.y, -1, accuracy: 0.001)
        view.lookAt(nil)
        XCTAssertEqual(view.pointerGazeTarget, .zero)
    }

    func testAutoBlinkIsScheduledOnlyWhereTheDataAllowsIt() throws {
        let view = try makeView()
        view.expression = .idle
        XCTAssertNotNil(view.nextBlinkAt, "idle blinks")
        view.expression = .sleeping
        XCTAssertNil(view.nextBlinkAt, "sleeping does not")
    }

    func testTheViewIsFlippedSoTheJSONCoordinatesAreUsedAsIs() throws {
        XCTAssertTrue(try makeView().isFlipped)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter MascotViewTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'MascotView' in scope`.

- [ ] **Step 3: Write the view**

Create `macos/Saathi/Sources/SaathiMascot/MascotView.swift`:

```swift
//
//  MascotView.swift
//  SaathiMascot
//
//  The character on screen. Core Animation layers for the body (a gradient masked by the outline),
//  the eyes and the mouth (white shapes, clipped to the body), all inside a motion layer; one tick
//  per frame recomputes placements from FaceGeometry and MotionTransform. The view is flipped so
//  the JSON's y-down coordinates are used unchanged.
//

import AppKit
import QuartzCore

public final class MascotView: NSView {

    public let data: MascotData

    public var expression: Expression {
        didSet { if expression != oldValue { enter(expression, hard: false) } }
    }

    public var color: MascotColor {
        didSet { applyColor() }
    }

    /// How much each face's own gaze offset drifts the whole face. The demo page defaults to 0.5.
    public var lookAround: CGFloat = 0.5
    public var motionStrength: CGFloat = 1
    /// Auto-blink and cycling between an expression's faces. Off, the face holds still.
    public var animates = true

    // MARK: layers

    private let scaled = CALayer()
    private let motion = CALayer()
    private let bodyGradient = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let faceContainer = CALayer()
    private let faceClip = CAShapeLayer()
    private let face = CALayer()
    private let eyeLeft = CAShapeLayer()
    private let eyeRight = CAShapeLayer()
    private let mouth = CAShapeLayer()

    // MARK: state, internal so tests can read it

    private(set) var faceIndex = 0
    private var fromEyes: [[CGPoint]] = []
    private var toEyes: [[CGPoint]] = []
    private var fromMouth: [Double] = []
    private var toMouth: [Double] = []
    private var fromGaze: CGPoint = .zero
    private var toGaze: CGPoint = .zero
    /// 0 = fully the previous face, 1 = fully the new one.
    private var morph: CGFloat = 1
    private var stateStart: TimeInterval = 0
    private var nextFaceAt: TimeInterval = .infinity
    private(set) var nextBlinkAt: TimeInterval?
    private var blinkStart: TimeInterval?
    private var spinStart: TimeInterval?
    private var pointerGaze: CGPoint = .zero
    private(set) var pointerGazeTarget: CGPoint = .zero
    private var lastNow: TimeInterval = 0
    private var ticker: Ticker?

    private let bodyOutline: CGPath

    public override var isFlipped: Bool { true }

    public init(data: MascotData, color: MascotColor, expression: Expression, frame: NSRect) {
        self.data = data
        self.color = color
        self.expression = expression
        // Decoded once at construction; a bad outline is a programming error, not a runtime case.
        self.bodyOutline = (try? SVGPath.cgPath(from: data.bodyPath)) ?? CGMutablePath()
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
        applyColor()
        enter(expression, hard: true)
        tick(now: CACurrentMediaTime())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("MascotView is built in code") }

    // MARK: public controls

    /// Point in this view's (flipped) coordinates; nil looks straight ahead.
    public func lookAt(_ point: CGPoint?) {
        guard let point else { pointerGazeTarget = .zero; return }
        let half = CGSize(width: bounds.width / 2, height: bounds.height / 2)
        pointerGazeTarget = CGPoint(
            x: FaceGeometry.clamp((point.x - half.width) / max(half.width, 1), -1...1),
            y: FaceGeometry.clamp((point.y - half.height) / max(half.height, 1), -1...1)
        )
    }

    public func blinkNow() {
        blinkStart = lastNow
    }

    public func spin() {
        spinStart = lastNow
    }

    // MARK: lifecycle

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ticker?.invalidate()
        ticker = nil
        if window != nil {
            ticker = Ticker(view: self) { [weak self] in self?.tick(now: CACurrentMediaTime()) }
        }
    }

    public override func layout() {
        super.layout()
        // Map viewBox units to points: scale to fit, keeping the aspect (the box is square).
        let k = min(bounds.width / CGFloat(data.viewBox.width), bounds.height / CGFloat(data.viewBox.height))
        var t = CATransform3DMakeScale(k, k, 1)
        t = CATransform3DTranslate(t, -CGFloat(data.viewBox.x), -CGFloat(data.viewBox.y), 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scaled.transform = t
        CATransaction.commit()
    }

    // MARK: building

    private func buildLayers() {
        guard let root = layer else { return }
        for l in [scaled, motion, bodyGradient, bodyMask, faceContainer, faceClip, face, eyeLeft, eyeRight, mouth] {
            l.anchorPoint = .zero
            l.position = .zero
            l.masksToBounds = false
            l.contentsScale = window?.backingScaleFactor ?? 2
        }
        let inner = CGFloat(data.eyeRefX) * 2   // the body's own square, 0...228.541
        let box = CGRect(x: 0, y: 0, width: inner, height: inner)
        scaled.bounds = box
        motion.bounds = box

        var bodyTransform = data.bodyTransform.affine
        let placedOutline = bodyOutline.copy(using: &bodyTransform) ?? bodyOutline

        bodyGradient.frame = box
        bodyGradient.startPoint = CGPoint(x: 1, y: 0)
        bodyGradient.endPoint = CGPoint(x: 0, y: 1)
        bodyGradient.locations = [0, 0.55, 1]
        bodyMask.frame = box
        bodyMask.path = placedOutline
        bodyGradient.mask = bodyMask

        faceContainer.frame = box
        faceClip.frame = box
        faceClip.path = placedOutline
        faceContainer.mask = faceClip

        face.bounds = box
        face.setAffineTransform(data.faceTransform.affine)
        for eye in [eyeLeft, eyeRight] {
            eye.fillColor = CGColor(gray: 1, alpha: 1)
            eye.bounds = box
        }
        mouth.fillColor = nil
        mouth.strokeColor = CGColor(gray: 1, alpha: 1)
        mouth.lineWidth = 7.5
        mouth.lineCap = .round
        mouth.bounds = box

        face.addSublayer(eyeLeft)
        face.addSublayer(eyeRight)
        face.addSublayer(mouth)
        faceContainer.addSublayer(face)
        motion.addSublayer(bodyGradient)
        motion.addSublayer(faceContainer)
        scaled.addSublayer(motion)
        root.addSublayer(scaled)
        needsLayout = true
    }

    private func applyColor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyGradient.colors = [
            MascotColor.cgColor(hex: color.light),
            color.cgColor,
            MascotColor.cgColor(hex: color.dark),
        ]
        CATransaction.commit()
    }

    // MARK: expressions

    private func enter(_ expression: Expression, hard: Bool) {
        let now = lastNow
        let first = data.expressions[expression.rawValue]?.first ?? 0
        setFace(first, hard: hard, now: now)
        stateStart = now
        scheduleFace(now: now)
        scheduleBlink(now: now)
    }

    private func setFace(_ index: Int, hard: Bool, now: TimeInterval) {
        let count = data.faces.count
        let wrapped = ((index % count) + count) % count
        if wrapped == faceIndex, morph >= 1, !fromEyes.isEmpty {
            stateStart = now
            return
        }
        let target = data.faces[wrapped].map { $0.map { CGPoint(x: CGFloat($0[0]), y: CGFloat($0[1])) } }
        if hard || fromEyes.isEmpty {
            fromEyes = target
            fromMouth = data.mouths[wrapped]
            fromGaze = gazePoint(wrapped)
            morph = 1
        } else {
            fromEyes = currentEyes()
            fromMouth = currentMouth()
            fromGaze = currentGaze()
            morph = 0
        }
        toEyes = target
        toMouth = data.mouths[wrapped]
        toGaze = gazePoint(wrapped)
        faceIndex = wrapped
    }

    private func gazePoint(_ index: Int) -> CGPoint {
        let g = data.gaze[index]
        return CGPoint(x: CGFloat(g[0]), y: CGFloat(g[1]))
    }

    private func scheduleFace(now: TimeInterval) {
        if let window = data.faceInterval[expression.rawValue] ?? nil, window.count == 2 {
            nextFaceAt = now + Double.random(in: window[0]...window[1]) / 1000
        } else {
            nextFaceAt = .infinity
        }
    }

    private func scheduleBlink(now: TimeInterval) {
        if let window = data.blinkInterval[expression.rawValue] ?? nil, window.count == 2 {
            nextBlinkAt = now + Double.random(in: window[0]...window[1]) / 1000
        } else {
            nextBlinkAt = nil
        }
    }

    // MARK: interpolation

    private func currentEyes() -> [[CGPoint]] {
        zip(fromEyes, toEyes).map { from, to in
            zip(from, to).map { a, b in CGPoint(x: a.x + (b.x - a.x) * morph, y: a.y + (b.y - a.y) * morph) }
        }
    }

    private func currentMouth() -> [Double] {
        zip(fromMouth, toMouth).map { $0 + ($1 - $0) * Double(morph) }
    }

    private func currentGaze() -> CGPoint {
        CGPoint(x: fromGaze.x + (toGaze.x - fromGaze.x) * morph, y: fromGaze.y + (toGaze.y - fromGaze.y) * morph)
    }

    // MARK: the frame

    public func tick(now: TimeInterval) {
        lastNow = now

        if animates, let at = nextBlinkAt, now >= at {
            blinkNow()
            scheduleBlink(now: now)
        }
        if animates, now >= nextFaceAt {
            let sequence = data.expressions[expression.rawValue] ?? [0]
            let others = sequence.filter { $0 != faceIndex }
            setFace(others.randomElement() ?? sequence[0], hard: false, now: now)
            scheduleFace(now: now)
        }

        if morph < 1 { morph = min(1, morph + (1 - morph) * 0.18 + 0.01) }
        pointerGaze.x += (pointerGazeTarget.x - pointerGaze.x) * 0.12
        pointerGaze.y += (pointerGazeTarget.y - pointerGaze.y) * 0.12

        var blink: CGFloat = 1
        if let start = blinkStart {
            let r = CGFloat((now - start) / 0.32)
            if r >= 1 { blinkStart = nil } else { blink = max(r < 0.42 ? 1 - r / 0.42 : (r - 0.42) / 0.58, 0.04) }
        }
        var spinDegrees: CGFloat = 0
        if let start = spinStart {
            let e = CGFloat((now - start) / 0.9)
            if e >= 1 { spinStart = nil } else { spinDegrees = 360 * e }
        }
        let turn = spinDegrees * .pi / 180

        let drift = CGPoint(x: currentGaze().x * lookAround, y: currentGaze().y * lookAround)
        let eyes = currentEyes().map { points in
            FaceGeometry.Eye(points: points.map { CGPoint(x: $0.x + drift.x, y: $0.y + drift.y) })
        }
        let shift = CGPoint(x: 13.2 * pointerGaze.x, y: 8.4 * pointerGaze.y)
        let eyeRefX = CGFloat(data.eyeRefX)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place(eyeLeft, FaceGeometry.eyePlacement(eyes[0], blink: blink, turn: turn, shift: shift, eyeRefX: eyeRefX))
        place(eyeRight, FaceGeometry.eyePlacement(eyes[1], blink: blink, turn: turn, shift: shift, eyeRefX: eyeRefX))
        place(mouth, FaceGeometry.mouthPlacement(eyes: eyes, mouth: currentMouth(), turn: turn, shift: shift, eyeRefX: eyeRefX))
        motion.setAffineTransform(MotionTransform.transform(
            preset: data.motion[expression.rawValue],
            elapsed: now - stateStart,
            strength: motionStrength,
            pivot: CGPoint(x: eyeRefX, y: eyeRefX),
            baseline: eyeRefX * 2
        ))
        CATransaction.commit()
    }

    private func place(_ layer: CAShapeLayer, _ placement: FaceGeometry.Placement) {
        layer.path = placement.path
        layer.setAffineTransform(placement.transform)
        layer.isHidden = !placement.visible
    }
}

/// One callback per display refresh: CADisplayLink on macOS 14, a 60 Hz timer before that.
/// Stored as AnyObject because the CADisplayLink type only exists on 14.
final class Ticker {
    private var timer: Timer?
    private var displayLink: AnyObject?
    private let tick: () -> Void

    init(view: NSView, tick: @escaping () -> Void) {
        self.tick = tick
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(fire))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc private func fire() { tick() }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.invalidate() }
        displayLink = nil
    }

    deinit { invalidate() }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed|error:|failed" | tail -3`
Expected: `Executed 106 tests, with 0 failures` (68 existing + 3 speaker + 35 mascot).

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/SaathiMascot/MascotView.swift macos/Saathi/Tests/SaathiMascotTests/MascotViewTests.swift
git commit -m "SaathiMascot: MascotView draws and animates the character with Core Animation

A gradient body masked by the outline, white eyes and mouth clipped to it, all under a motion
layer; one tick per frame recomputes placements from the pure geometry. Expressions morph
between faces, blink and cycle on the data's intervals, and the eyes follow a point. Flipped so
the JSON's y-down numbers are used as they are.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

### Task 7: `MascotPreview` and the eyeball check

**Files:**
- Create: `macos/Saathi/Sources/MascotPreview/main.swift`

**Interfaces:**
- Consumes: `MascotView`, `MascotColor`, `Expression`, `MascotData.load()`.
- Produces: `swift run MascotPreview` opens a window with every expression.

- [ ] **Step 1: Write the preview app**

Create `macos/Saathi/Sources/MascotPreview/main.swift`:

```swift
//
//  main.swift
//  MascotPreview
//
//  Every expression in a grid, a colour menu, and eyes that follow the pointer. For looking at,
//  not for shipping: `swift run MascotPreview`.
//

import AppKit
import SaathiMascot

let data = try MascotData.load()
let app = NSApplication.shared
app.setActivationPolicy(.regular)

final class PreviewController: NSObject {
    var mascots: [MascotView] = []
    let colorMenu = NSPopUpButton(frame: .zero, pullsDown: false)

    @objc func colorChanged(_ sender: NSPopUpButton) {
        guard let name = sender.titleOfSelectedItem, let color = MascotColor(paletteName: name, in: data) else { return }
        for m in mascots { m.color = color }
    }

    @objc func blinkAll(_ sender: Any?) { mascots.forEach { $0.blinkNow() } }
    @objc func spinAll(_ sender: Any?) { mascots.forEach { $0.spin() } }
}

let controller = PreviewController()
let cell: CGFloat = 96
let columns = 8
let rows = Int((Double(Expression.allCases.count) / Double(columns)).rounded(.up))
let content = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(columns) * (cell + 24) + 24, height: CGFloat(rows) * (cell + 36) + 80))
content.wantsLayer = true
content.layer?.backgroundColor = CGColor(gray: 0.06, alpha: 1)

let blue = MascotColor(paletteName: "blue", in: data)!
for (i, expression) in Expression.allCases.enumerated() {
    let column = i % columns, row = i / columns
    let x = 24 + CGFloat(column) * (cell + 24)
    let y = content.bounds.height - 80 - CGFloat(row + 1) * (cell + 36)
    let mascot = MascotView(data: data, color: blue, expression: expression, frame: NSRect(x: x, y: y + 24, width: cell, height: cell))
    content.addSubview(mascot)
    controller.mascots.append(mascot)

    let label = NSTextField(labelWithString: expression.rawValue)
    label.frame = NSRect(x: x - 12, y: y, width: cell + 24, height: 18)
    label.alignment = .center
    label.font = .systemFont(ofSize: 11)
    label.textColor = NSColor(white: 0.6, alpha: 1)
    content.addSubview(label)
}

controller.colorMenu.frame = NSRect(x: 24, y: content.bounds.height - 56, width: 140, height: 28)
controller.colorMenu.addItems(withTitles: data.palette.keys.sorted())
controller.colorMenu.selectItem(withTitle: "blue")
controller.colorMenu.target = controller
controller.colorMenu.action = #selector(PreviewController.colorChanged(_:))
content.addSubview(controller.colorMenu)

let blink = NSButton(title: "Blink", target: controller, action: #selector(PreviewController.blinkAll(_:)))
blink.frame = NSRect(x: 180, y: content.bounds.height - 56, width: 80, height: 28)
content.addSubview(blink)
let spin = NSButton(title: "Spin", target: controller, action: #selector(PreviewController.spinAll(_:)))
spin.frame = NSRect(x: 270, y: content.bounds.height - 56, width: 80, height: 28)
content.addSubview(spin)

let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
window.title = "Saathi mascot — \(Expression.allCases.count) expressions"
window.contentView = content
window.center()
window.makeKeyAndOrderFront(nil)

// Eyes follow the pointer anywhere in the window.
_ = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
    for m in controller.mascots {
        m.lookAt(m.convert(event.locationInWindow, from: nil))
    }
    return event
}
window.acceptsMouseMovedEvents = true

app.activate(ignoringOtherApps: true)
app.run()
```

- [ ] **Step 2: Build and run it**

Run: `cd macos/Saathi && swift build 2>&1 | grep -E "error|warning: unre" ; swift run MascotPreview`
Expected: a dark window titled "Saathi mascot — 39 expressions" with eight columns of blue pointer characters, each labelled. The executor should check, and report on, each of these:

- every cell shows a pointer body with a lighter top-right and darker bottom-left; no cell is blank;
- every cell shows two white eyes and a mouth inside the body, none drawn outside the outline;
- `sleeping` and `drowsy` have closed or narrow eyes; `celebrate`, `happy` and `laughing` have wide eyes and a big smile; `angry` has a frown;
- `idle` cells blink every few seconds; `sleeping` never blinks; `excited` and `bouncing` bob visibly; `sleeping` is tilted a couple of degrees;
- moving the pointer across the window makes every pair of eyes follow it;
- picking `orange` from the menu recolours every body; Blink and Spin act on all of them.

If the gradient is upside down (light at bottom-left), swap `startPoint` and `endPoint` in `MascotView.buildLayers` and re-run. If the face draws mirrored or offset outside the body, the flip is wrong: check that `isFlipped` is honoured by confirming `view.layer?.isGeometryFlipped == true` at runtime, and report what you see rather than patching coordinates by hand.

- [ ] **Step 3: Capture a screenshot for the record**

With the preview still open, in another shell run: `screencapture -x -T 2 /Users/prasanthsasikumar/Documents/GitHub/saathi/macos/Saathi/dist/mascot-preview.png` and view the file. `dist/` is untracked; the image is for the reviewer, not the repo.

- [ ] **Step 4: Run the full test suite one last time**

Run: `cd macos/Saathi && swift test 2>&1 | grep -E "Executed|error:|failed" | tail -2`
Expected: `Executed 106 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
git add macos/Saathi/Sources/MascotPreview/main.swift
git commit -m "MascotPreview: every expression in a window, for eyes rather than tests

swift run MascotPreview shows the 39 expressions in a grid with a colour menu, blink and spin
buttons, and eyes that follow the pointer. It is how the port of the web renderer was checked
and how a change to the drawing gets checked again.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AEU3ZMCHVZiteJzD4Kstn6"
```

---

## Done when

- `saathi say` is audible and takes as long as the sentence.
- `swift test` passes with 106 tests.
- `swift run MascotPreview` shows all 39 expressions animating, verified by a human or by the executor's report against the checklist in Task 7.
- Nothing in SaathiKit depends on SaathiMascot yet; that join is slice 2.
