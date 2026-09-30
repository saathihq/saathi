# Sarvam, Heard and Spoken — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Someone who pastes a Sarvam key into Setup can talk to Saathi in an Indian language and be answered in it: Saaras hears them, Sarvam-105B thinks, Bulbul speaks, and every report says where their voice went.

**Architecture:** Sarvam stays on the chain lane (three steps), and the chain lane stops owning its ears and its mouth. `ChainVoiceSession` is handed a pair of `Ears` and a `Speaker`; `DeviceEars` is the on-device recogniser it used to contain and `SarvamEars` records a turn and sends it to Saaras. `CompanionVoice` is the app's one speaker and chooses between this Mac's voice and `SarvamSpeaker` (Bulbul). Which is used is a config field, `speech`, written by Setup when Sarvam is arrived at — or by a switch beside the language — and read by both clients' reports. The chain lane itself is finished on the way: tool results go back to the model, `look_at_screen` is answered, the request is the shape a strict server takes, and a held turn interrupts.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, XCTest (`macos/Saathi`); C# / .NET 8, xUnit (`windows`); Node 22 for the contract generator; bash for `scripts/check-parity.sh`. Sarvam's REST API (`api.sarvam.ai`), read on 2026-09-30.

**Spec:** `docs/superpowers/specs/2026-09-30-sarvam-heard-and-spoken-design.md`

**Code blocks in this plan are the code as built.** It was drafted before anything was compiled, and regenerated from the files once the work was done, so a block here and the file in the tree are the same bytes.

## Global Constraints

- **No test opens the microphone, plays a sound, or uses the network.** The recorder and the player are protocols with fakes; every request goes to `StubHTTP`. Run tests with plain `swift test`; never set `SAATHI_AUDIO_TESTS=1`.
- **Nothing is verified against a real Sarvam key** — there is none on this Mac. Every request is written field for field from `docs.sarvam.ai` as read on 2026-09-30, and `saathi sarvam` is the command that finds out. Do not claim otherwise anywhere.
- `contract/schema/saathi.json` is the only hand-edited contract file. After changing it run `npm run generate` and commit the three generated files with it.
- Contract version: `0.9.0`.
- **A voice never goes anywhere the report has not said.** `speech` unset means `device`. Setup writes `speech: sarvam` only in a plan whose sentence says the voice leaves as audio, straight to Sarvam.
- **No silent fallback.** A language Sarvam does not speak, or `speech: sarvam` with no Sarvam key, stops the session with a sentence. It never quietly listens on this Mac instead.
- Sarvam's wire details, verbatim: auth header `api-subscription-key: <key>` on the speech endpoints, `Authorization: Bearer <key>` on chat; `POST https://api.sarvam.ai/speech-to-text` (multipart: `file`, `language_code`); `POST https://api.sarvam.ai/text-to-speech` (JSON: `text`, `language_code`, `speaker`, `model: "bulbul:v3"`, optional `pace` 0.5–2); `POST https://api.sarvam.ai/v1/chat/completions`; a refused key is **403** `invalid_api_key_error`; spent credits are 429 `insufficient_quota_error`.
- Languages Sarvam both hears and speaks: `bn en gu hi kn ml mr od pa ta te`, each as `<code>-IN`; Odia is `or` in `shell.json` and `od-IN` to Sarvam.
- The Swift and C# reports must print the same bytes for the same config: `scripts/check-parity.sh` diffs them, and a change to one report is a change to both.
- Commit messages are full sentences, no `feat:` prefix, ending with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Commits stay local: nothing is pushed.
- Local CI for every task: `bash <scratchpad>/ci-local.sh` (contract, backend, mac, runner, win, parity). dotnet is in the scratchpad, not on the system.

## Review Focus

The inputs and failures the spec implies that are most likely to bite someone using this, each pinned by a test in the task that owns the code:

1. **The microphone gives silence** (a closed input, or the first turn after switching from OpenAI without a relaunch). Expected: nothing is sent to Saaras; the turn fails with a sentence that names the microphone and says to reopen Saathi. — Task 6, `testAMicrophoneThatGaveNothingSaysSoInsteadOfAskingSaaras`.
2. **The learner talks over an answer that is still on its way.** Expected: the answer is never spoken, the request for it is dropped, and no alert is raised for it. — Task 5, `testAnAnswerTheLearnerTalkedOverIsNeverSpokenAndIsNotAFailure`; Task 7, `testALineAskedForBeforeAStopIsNotSaidAfterIt`.
3. **Sarvam says no** — a revoked key, an empty account, a rate limit — on any of the three requests. Expected: three different sentences, none of them raw JSON, and an out-of-credits account is never called a wrong key. — Task 2, Task 4 `testEachRefusalIsReadAsWhatItIs`, Task 5 `testSarvamSayingNoIsASentenceNotAPageOfJSON`.
4. **The language in Settings is one Sarvam does not speak** (French, Korean). Expected: a refusal that names the language and the two ways out; never on-device listening in its place. — Task 7 `testALanguageSarvamDoesNotSpeakIsARefusalThatNamesIt`, Task 8 factory tests.
5. **A key is replaced, or the provider is switched, on a config someone edited by hand** (a chosen model, a chosen voice, a legacy shared `apiKey`, `speech` set one way or the other). Expected: the model survives a key change; a voice never follows a change of provider; a legacy key is filed under its vendor rather than lost; and a Save about something else never starts, or stops, sending the voice to Sarvam. — Task 10 `testAModelChosenByHandSurvivesAKeyBeingReplaced`, `testAVoiceDoesNotFollowAChangeOfProvider`, `testSarvamsSpeechIsAskedForNotAssumed`, `testAnUnrelatedSaveDoesNotStartSendingTheVoiceToSarvam`, `testPickingAnotherProviderKeepsALegacyKeyWithItsVendor`.

## File Structure

All Swift paths are relative to `macos/Saathi/`.

| File | Responsibility |
|---|---|
| `contract/schema/saathi.json` | + `sarvamKey`, `speech`, `SpeechEngine`; version 0.9.0 |
| `contract/generate.mjs` | + `resolvedSpeech`; Sarvam's own field in `credential(for:)` |
| `Sources/SaathiKit/KeyValidator.swift` | A probe per vendor; Sarvam's actually needs a key |
| `Sources/SaathiKit/SarvamLanguage.swift` | **new** — a BCP 47 tag in Sarvam's spelling |
| `Sources/SaathiKit/WaveFile.swift` | **new** — PCM16 into a WAV; how long a WAV is |
| `Sources/SaathiKit/SarvamClient.swift` | **new** — the Saaras and Bulbul requests, and reading a refusal |
| `Sources/SaathiKit/Ears.swift` | **new** — `Ears`, and `DeviceEars` (the recogniser the session used to contain) |
| `Sources/SaathiKit/ChainVoiceSession.swift` | **rewritten** — handed its ears; tool loop; interruption; the request a strict server takes |
| `Sources/SaathiKit/SarvamEars.swift` | **new** — `TurnRecorder`, the real microphone, and ears that ask Saaras |
| `Sources/SaathiKit/SarvamSpeaker.swift` | **new** — `AudioOutput`, the real player, and a speaker that asks Bulbul |
| `Sources/SaathiKit/CompanionVoice.swift` | **new** — `SarvamSpeech` (what the config asks for) and the app's one voice |
| `Sources/SaathiKit/VoiceSession.swift` | `interrupt()`; the factory chooses the ears |
| `Sources/SaathiKit/VoiceLaneReport.swift`, `ProviderReport.swift` | Say where the voice goes with `speech: sarvam` |
| `Sources/SaathiKit/SetupPlan.swift` | **rewritten** — three vendors, what was just pasted, what is in use |
| `Sources/SaathiKit/SarvamSelfTest.swift` | **new** — what `saathi sarvam` runs |
| `Sources/SaathiShell/AppController+Setup.swift` | **new** — the Setup tab's actions, out of `wireNotch` |
| `Sources/SaathiShell/AppController+Wording.swift` | Decisions and sentences over three vendors; the picker's choices; `describe(_:on:)` |
| `Sources/SaathiShell/IslandModel.swift`, `IslandSetupView.swift` | A Sarvam row, the picker, the switch, two more languages |
| `Tests/SaathiShellTests/IslandSetupSnapshotTests.swift` | **new**, opt-in — the Setup tab drawn to PNGs |
| `Sources/SaathiShell/AppController.swift`, `VoiceConductor.swift` | The app's voice is `CompanionVoice`; a held turn interrupts |
| `Sources/saathi/main.swift` | `saathi sarvam`; the CLI speaks with the configured voice |
| `windows/src/Saathi.Core/VoiceLaneReport.cs`, `ProviderReport.cs` | The same sentences as Swift |
| `scripts/check-parity.sh` | Four configs with `speech` in them |
| `README.md`, `docs/HAND-TEST.md` | What exists now, and what to try with a real key |

---

### Task 1: Contract 0.9.0 — a key of its own, and a say in where speech happens

**Files:**
- Modify: `contract/schema/saathi.json`, `contract/generate.mjs`, `contract/fixtures/config.json`
- Regenerate: `macos/Saathi/Sources/SaathiContract/SaathiContract.swift`, `windows/src/Saathi.Contract/SaathiContract.cs`, `backend/src/contract.ts`
- Test: `macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift`, `windows/tests/Saathi.Core.Tests/SharedFixtureTests.cs`

**Interfaces:**
- Produces (Swift): `SaathiConfiguration.sarvamKey: String?`, `.speech: SpeechEngine?`, `.resolvedSpeech: SpeechEngine`; `enum SpeechEngine: String { case device, sarvam }`; `credential(for: .sarvam)` reads `sarvamKey` then `apiKey`. Memberwise init gains `sarvamKey:` after `anthropicKey:` and `speech:` after `voice:`.
- Produces (C#): `SarvamKey`, `Speech`, `ResolvedSpeech`, `SpeechEngine.Device/.Sarvam`, `Credential(ProviderKind.Sarvam)`.

- [ ] **Step 1: Write the failing tests (Swift).** In `SaathiKitTests.swift`:

In `SharedFixtureTests.testTheSharedConfigFixtureParses`, after the `anthropicKey` assertion add:

```swift
        XCTAssertEqual(configuration.sarvamKey, "not-a-real-sarvam-key")
```

and after the `voice` assertion add:

```swift
        XCTAssertEqual(configuration.speech, .sarvam, "an enum config field must parse from its wire spelling")
```

In `testResolutionThroughTheFixtureMatches` add:

```swift
        XCTAssertEqual(
            configuration.credential(for: .sarvam), "not-a-real-sarvam-key",
            "Sarvam's own field wins over the legacy shared one, as the other vendors' do")
        XCTAssertEqual(configuration.resolvedSpeech, .sarvam)
```

In `CredentialResolutionTests` add:

```swift
    /// Sarvam has a field of its own, like the other two, and the legacy shared key still stands
    /// in for it on a config written before there was one.
    func testSarvamHasItsOwnFieldAndStillReadsTheLegacyOne() {
        let own = SaathiConfiguration(apiKey: "legacy", openaiKey: "sk-openai", sarvamKey: " sk-sarvam \n")
        XCTAssertEqual(own.credential(for: .sarvam), "sk-sarvam")
        XCTAssertEqual(own.credential(for: .openai), "sk-openai")
        XCTAssertEqual(SaathiConfiguration(apiKey: "legacy").credential(for: .sarvam), "legacy")
        XCTAssertNil(
            SaathiConfiguration(openaiKey: "sk-openai").credential(for: .sarvam),
            "another vendor's key is not Sarvam's")
    }
```

After `CredentialResolutionTests` add a new class:

```swift
/// Whose ears and mouth a chain-lane turn uses. Unset must mean this machine's: a config written
/// before the field existed promised that the voice stays here, and an update must not change that.
final class SpeechEngineTests: XCTestCase {

    func testUnsetMeansThisMachine() {
        XCTAssertNil(SaathiConfiguration(provider: .sarvam, apiKey: "k").speech)
        XCTAssertEqual(SaathiConfiguration(provider: .sarvam, apiKey: "k").resolvedSpeech, .device)
        XCTAssertEqual(SaathiConfiguration().resolvedSpeech, .device)
    }

    func testAChoiceIsKept() {
        XCTAssertEqual(SaathiConfiguration(speech: .sarvam).resolvedSpeech, .sarvam)
        XCTAssertEqual(SaathiConfiguration(speech: .device).resolvedSpeech, .device)
    }

    func testTheTwoEnginesAreSpelledAsTheSchemaSpellsThem() {
        XCTAssertEqual(SpeechEngine.allCases.map(\.rawValue), ["device", "sarvam"])
    }
}
```

In `ConfigurationRoundTripTests.testEveryNewFieldSurvivesAWriteAndARead` replace the `written` value and add two assertions:

```swift
        let written = SaathiConfiguration(
            provider: .openai, model: "gpt-4o", openaiKey: "sk-o", anthropicKey: "sk-a", sarvamKey: "sk-s",
            voiceModel: "gpt-realtime", voice: "cedar", speech: .sarvam)
```

```swift
        XCTAssertEqual(read.sarvamKey, "sk-s")
        XCTAssertEqual(read.speech, .sarvam)
```

- [ ] **Step 2: Run them to see them fail.**

Run: `cd macos/Saathi && swift build --build-tests 2>&1 | grep -E "error:" | head`
Expected: FAIL to compile — `value of type 'SaathiConfiguration' has no member 'sarvamKey'`, `cannot find 'SpeechEngine' in scope`.

- [ ] **Step 3: Change the schema.** In `contract/schema/saathi.json`:

`"version": "0.8.0"` → `"version": "0.9.0"`.

Replace the `apiKey` doc with `"Deprecated: use openaiKey, sarvamKey or anthropicKey. Still read when no vendor-specific key is set, so existing configs keep working."`

Replace the `anthropicKey` field and add `sarvamKey` after it:

```json
      {
        "name": "anthropicKey",
        "type": "string",
        "optional": true,
        "doc": "Your own Anthropic key. Looks at the screen when a turn asks about something on it, and thinks when nothing else can. Never sent to Saathi's servers."
      },
      {
        "name": "sarvamKey",
        "type": "string",
        "optional": true,
        "doc": "Your own Sarvam AI key. Thinks with Sarvam, and hears and speaks with it when speech is sarvam. Never sent to Saathi's servers."
      },
```

Replace the `voice` field and add `speech` after it:

```json
      {
        "name": "voice",
        "type": "string",
        "optional": true,
        "doc": "The voice's name: the realtime voice on the realtime lane, Sarvam's speaker when speech is sarvam. Defaults to the provider's."
      },
      {
        "name": "speech",
        "type": "SpeechEngine",
        "optional": true,
        "doc": "Whose ears and mouth a chain-lane turn uses. Unset means this machine's. The realtime lane carries its own speech and does not read this."
      },
```

Add an enum after `VoiceLane`:

```json
    {
      "name": "SpeechEngine",
      "doc": "Where speech becomes text and text becomes speech on the chain lane. With device the learner's voice never leaves the machine. With sarvam it is sent to Sarvam as audio — the only way to be heard in most Indian languages, and never done unless asked for.",
      "cases": [
        "device",
        "sarvam"
      ]
    }
```

In the `providers` `$comment` array, after the line `"have the accessibility premise backwards.",` add:

```json
      "",
      "Sarvam's speech models are where that leaves a gap. The chain lane's ears and mouth are the",
      "machine's own by default, and the machine's own cannot hear most Indian languages at all.",
      "So `speech` — a config field, not a column here — says whose they are: `device`, or `sarvam`",
      "for Saaras and Bulbul. It is a field rather than a column because it changes where a voice",
      "goes, and that is the learner's to ask for, not something a provider row decides for them.",
```

- [ ] **Step 4: Change the generator.** In `contract/generate.mjs`, Swift section — after the `resolvedLanguage` block (the line `out.push("    }\n");` that follows `return trimmed.isEmpty ? \"en\" : trimmed`) add:

```js
  out.push("    /// Whose ears and mouth a chain-lane turn uses: the config's choice, this machine's");
  out.push("    /// until one is made. The realtime lane carries its own speech and does not read this.");
  out.push("    public var resolvedSpeech: SpeechEngine { speech ?? .device }\n");
```

Replace the four `credential` comment lines and the switch:

```js
  out.push("    /// The credential for a provider: its own vendor field first, then the legacy shared");
  out.push("    /// `apiKey`. Vendor-specific wins, so a config holding keys for several vendors is");
  out.push("    /// unambiguous — which is the whole reason the vendor fields exist. Providers that");
  out.push("    /// need no key of their own get nil even when keys are present.");
  out.push("    public func credential(for kind: ProviderKind) -> String? {");
  out.push("        guard SaathiProvider.of(kind).requiresKey else { return nil }");
  out.push("        let candidates: [String?]");
  out.push("        switch kind {");
  out.push("        case .openai: candidates = [openaiKey, apiKey]");
  out.push("        case .anthropic: candidates = [anthropicKey, apiKey]");
  out.push("        case .sarvam: candidates = [sarvamKey, apiKey]");
  out.push("        default: candidates = [apiKey]");
  out.push("        }");
```

C# section — after the `ResolvedLanguage` lines add:

```js
  out.push("    /// <summary>Whose ears and mouth a chain-lane turn uses: the config's choice, this machine's");
  out.push("    /// until one is made. The realtime lane carries its own speech and does not read this.</summary>");
  out.push("    public SpeechEngine ResolvedSpeech => Speech ?? global::Saathi.Contract.SpeechEngine.Device;\n");
```

and in `Credential` add one arm after the Anthropic one:

```js
  out.push("            global::Saathi.Contract.ProviderKind.Sarvam => new[] { SarvamKey, ApiKey },");
```

- [ ] **Step 5: The fixture.** In `contract/fixtures/config.json` add after `"anthropicKey"`:

```json
  "sarvamKey": "not-a-real-sarvam-key",
```

and after `"voice"`:

```json
  "speech": "sarvam",
```

- [ ] **Step 6: Regenerate, and the C# tests.**

Run: `npm run generate && npm run check:contract`
Expected: three files written; `contract 0.9.0: generated files are up to date`.

In `windows/tests/Saathi.Core.Tests/SharedFixtureTests.cs`, in `TheSharedConfigFixtureParses` add:

```csharp
        Assert.Equal("not-a-real-sarvam-key", configuration.SarvamKey);
        Assert.Equal(SpeechEngine.Sarvam, configuration.Speech);
```

in `ResolutionThroughTheFixtureMatches` add:

```csharp
        Assert.Equal("not-a-real-sarvam-key", configuration.Credential(ProviderKind.Sarvam));
        Assert.Equal(SpeechEngine.Sarvam, configuration.ResolvedSpeech);
```

and add two tests:

```csharp
    /// <summary>Unset must mean this machine's: a config written before the field existed promised
    /// the voice stays here, and an update must not change that.</summary>
    [Fact]
    public void SpeechIsThisMachinesUntilItIsAskedFor()
    {
        Assert.Equal(SpeechEngine.Device, new SaathiConfiguration { Provider = ProviderKind.Sarvam, ApiKey = "k" }.ResolvedSpeech);
        Assert.Equal(SpeechEngine.Sarvam, new SaathiConfiguration { Speech = SpeechEngine.Sarvam }.ResolvedSpeech);
    }

    [Fact]
    public void SarvamHasItsOwnFieldAndStillReadsTheLegacyOne()
    {
        var own = new SaathiConfiguration { ApiKey = "legacy", OpenaiKey = "sk-openai", SarvamKey = " sk-sarvam " };
        Assert.Equal("sk-sarvam", own.Credential(ProviderKind.Sarvam));
        Assert.Equal("legacy", new SaathiConfiguration { ApiKey = "legacy" }.Credential(ProviderKind.Sarvam));
        Assert.Null(new SaathiConfiguration { OpenaiKey = "sk-openai" }.Credential(ProviderKind.Sarvam));
    }
```

- [ ] **Step 7: Run everything.**

Run: `bash <scratchpad>/ci-local.sh`
Expected: every job ✓. The `actions` line of both CLIs now reads `contract 0.9.0`.

- [ ] **Step 8: Commit.**

```bash
git add contract backend/src/contract.ts macos/Saathi/Sources/SaathiContract macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift windows
git commit   # "Sarvam has a key of its own, and a config can ask for its ears and mouth (contract 0.9.0)"
```

---

### Task 2: A Sarvam key is actually checked

**Files:**
- Modify: `Sources/SaathiKit/KeyValidator.swift`
- Test: `Tests/SaathiKitTests/KeyValidatorTests.swift`

**Interfaces:**
- Consumes: `SaathiProvider.authorizationHeader(credential:)`.
- Produces: `KeyValidator.check(.sarvam, key:)` → `.valid` for 2xx/400/422, `.rejected` for 401/403, `.unreachable` otherwise (with a sentence about credits for 429 `insufficient_quota_error`). Signature unchanged.

- [ ] **Step 1: Write the failing tests.** In `KeyValidatorTests.swift`, let the stub carry a body: replace the three `static` lines and `reset` in `KeyStubProtocol` with

```swift
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var shouldFail = false
    nonisolated(unsafe) static var body = Data("{}".utf8)
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset(status: Int, shouldFail: Bool = false, body: Data = Data("{}".utf8)) {
        self.status = status
        self.shouldFail = shouldFail
        self.body = body
        self.lastRequest = nil
    }
```

replace `client?.urlProtocol(self, didLoad: Data("{}".utf8))` with `client?.urlProtocol(self, didLoad: Self.body)`, and replace `keyStub(status:)` with

```swift
    static func keyStub(status: Int, body: Data = Data("{}".utf8)) -> URLSession {
        KeyStubProtocol.reset(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubProtocol.self]
        return URLSession(configuration: configuration)
    }
```

Then add to `KeyValidatorTests`:

```swift
    // MARK: Sarvam, whose model list is open to anyone

    /// `GET /v1/models` answers 200 to no key at all — and to a wrong one — so asking it accepted
    /// every string ever pasted. Sarvam is asked something that needs a key instead.
    func testSarvamIsAskedSomethingThatNeedsAKey() async {
        _ = await KeyValidator(urlSession: .keyStub(status: 400)).check(.sarvam, key: " sk-s \n")
        let request = KeyStubProtocol.lastRequest
        XCTAssertEqual(request?.url?.absoluteString, "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-s")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// The question is an empty request. Sarvam checks the key before it reads the body, so "your
    /// request is missing a model" can only be said to a key it has let in — and nothing is run,
    /// and nothing is billed.
    func testSarvamFindingTheRequestEmptyMeansTheKeyWasLetIn() async {
        for status in [400, 422] {
            let result = await KeyValidator(urlSession: .keyStub(status: status)).check(.sarvam, key: "sk-s")
            XCTAssertEqual(result, .valid, "\(status)")
        }
    }

    /// Sarvam refuses a key with 403, not 401.
    func testSarvamRefusingTheKeyNamesSarvam() async {
        guard case let .rejected(message) = await KeyValidator(urlSession: .keyStub(status: 403)).check(.sarvam, key: "nope") else {
            return XCTFail("a 403 from Sarvam is the key being refused")
        }
        XCTAssertEqual(message, "Sarvam did not accept that key.")
    }

    /// "Bad request" is only good news from the one vendor that is asked an empty question.
    func testABadRequestFromAVendorAskedForItsModelsIsNotAWorkingKey() async {
        for kind in [ProviderKind.openai, .anthropic] {
            guard case .unreachable = await KeyValidator(urlSession: .keyStub(status: 400)).check(kind, key: "sk") else {
                return XCTFail("\(kind): a 400 to a model list says nothing good about the key")
            }
        }
    }

    /// A real key on an account with nothing left is not a wrong key, and "try again shortly"
    /// would be a lie: it will not work shortly.
    func testAnAccountOutOfCreditsIsSaidInThoseWords() async {
        let body = Data(#"{"error":{"message":"Credits exhausted","code":"insufficient_quota_error"}}"#.utf8)
        let validator = KeyValidator(urlSession: .keyStub(status: 429, body: body))
        guard case let .unreachable(message) = await validator.check(.sarvam, key: "sk-s") else {
            return XCTFail("out of credits is not a rejected key")
        }
        XCTAssertTrue(message.contains("out of credits"), message)
        XCTAssertFalse(message.contains("try again shortly"), message)
    }

    func testSarvamBeingBusyIsStillNotAboutTheKey() async {
        let body = Data(#"{"error":{"message":"Rate limit exceeded","code":"rate_limit_exceeded_error"}}"#.utf8)
        let validator = KeyValidator(urlSession: .keyStub(status: 429, body: body))
        guard case let .unreachable(message) = await validator.check(.sarvam, key: "sk-s") else {
            return XCTFail("a rate limit is not a rejected key")
        }
        XCTAssertTrue(message.contains("429"), message)
    }
```

- [ ] **Step 2: Run to see them fail.**

Run: `cd macos/Saathi && swift test --filter KeyValidatorTests 2>&1 | grep -E "error:|failed|Executed" | tail`
Expected: `testSarvamIsAskedSomethingThatNeedsAKey` fails (`…/v1/models`, `GET`), `testSarvamFindingTheRequestEmptyMeansTheKeyWasLetIn` fails (`.unreachable`), `testAnAccountOutOfCreditsIsSaidInThoseWords` fails.

- [ ] **Step 3: Implement.** In `KeyValidator.swift` replace the header comment's last line, the `Probe` struct and `probe(for:)`, and the request and status handling in `check`:

```swift
//  OpenAI and Anthropic are asked for their model lists: free, instant, and unambiguous about
//  authentication. Sarvam's model list is public, so it is asked something else — see `probe`.
```

```swift
    /// How each vendor is asked, and what it is called when telling a person it said no.
    private struct Probe {
        let name: String
        let url: URL
        var method = "GET"
        var body: Data?
        /// Statuses beyond 2xx that still mean the key was let in.
        var letIn: Set<Int> = []
    }

    private func probe(for kind: ProviderKind) -> Probe? {
        switch kind {
        case .openai: return Probe(name: "OpenAI", url: URL(string: "https://api.openai.com/v1/models")!)
        case .anthropic: return Probe(name: "Anthropic", url: URL(string: "https://api.anthropic.com/v1/models")!)
        case .sarvam:
            // Sarvam's model list answers 200 to no key at all, so asking it proved nothing and
            // every string ever pasted passed as a key. Its chat endpoint does check, and checks
            // before it reads the body: an empty request is refused with 403 for a wrong key and
            // with 400 — "missing model" — for a right one. Nothing is run and nothing is billed.
            return Probe(
                name: "Sarvam", url: URL(string: "https://api.sarvam.ai/v1/chat/completions")!,
                method: "POST", body: Data("{}".utf8), letIn: [400, 422])
        case .local, .hosted: return nil
        }
    }
```

```swift
        var request = URLRequest(url: probe.url)
        request.httpMethod = probe.method
        if let body = probe.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
```

```swift
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("\(probe.name) gave an answer that could not be read.")
            }
            switch http.statusCode {
            case 200...299:
                return .valid
            case let status where probe.letIn.contains(status):
                return .valid
            case 401, 403:
                return .rejected("\(probe.name) did not accept that key.")
            case 429 where Self.errorCode(in: data) == "insufficient_quota_error":
                // The key is real and the account behind it is empty. Not a wrong key, and not
                // something that waiting will fix.
                return .unreachable("\(probe.name) knows that key, but its account is out of credits. Top it up, then save the key again.")
            default:
                // Anything else says nothing about the key — a 429 or a 500 is the vendor's state,
                // not the credential's, and telling someone their key is bad on a 500 is a lie.
                return .unreachable("\(probe.name) answered \(http.statusCode). That is not about your key; try again shortly.")
            }
        } catch {
            return .unreachable("Could not reach \(probe.name). Are you online?")
        }
    }

    /// `error.code` in a vendor's refusal, when it has one.
    private static func errorCode(in body: Data) -> String? {
        let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return (answer?["error"] as? [String: Any])?["code"] as? String
    }
```

- [ ] **Step 4: Run to see them pass.**

Run: `cd macos/Saathi && swift test --filter KeyValidatorTests 2>&1 | grep -E "error:|failed|Executed" | tail -3`
Expected: all pass, the nine older ones included.

- [ ] **Step 5: Check the two facts this rests on against the live API (no key is used).**

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://api.sarvam.ai/v1/models                                   # 200: public
curl -s -w "\n%{http_code}\n" -H "Authorization: Bearer nope" -H "Content-Type: application/json" -d '{}' \
  https://api.sarvam.ai/v1/chat/completions                                                                # 403 invalid_api_key_error
```

- [ ] **Step 6: Commit** — "A Sarvam key is checked by asking something that needs one".

---

### Task 3: A language in Sarvam's spelling, and sound in a WAV

**Files:**
- Create: `Sources/SaathiKit/SarvamLanguage.swift`, `Sources/SaathiKit/WaveFile.swift`
- Modify: `Sources/SaathiKit/RealtimeVoiceSession.swift` (`writeLastTurn` uses `WaveFile`)
- Test: `Tests/SaathiKitTests/SarvamLanguageTests.swift`

**Interfaces:**
- Produces: `SarvamLanguage.code(for: String) -> String?`, `SarvamLanguage.name(of: String) -> String`, `SarvamLanguage.spoken: Set<String>`; `WaveFile.wrap(pcm16: Data, sampleRate: Int) -> Data`, `WaveFile.seconds(of: Data) -> Double?`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/SarvamLanguageTests.swift`:

```swift
//
//  SarvamLanguageTests.swift
//  SaathiKitTests
//
//  The two small things under Sarvam's speech: a language tag in Sarvam's spelling, and sound in
//  the container it is sent and returned in.
//

import Foundation
import XCTest
@testable import SaathiKit

final class SarvamLanguageTests: XCTestCase {

    func testALanguageBecomesSarvamsCodeForIt() {
        XCTAssertEqual(SarvamLanguage.code(for: "ml"), "ml-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "ml-IN"), "ml-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "hi_IN"), "hi-IN")
        XCTAssertEqual(SarvamLanguage.code(for: " TA "), "ta-IN")
    }

    /// Bulbul has one English, and it is India's. Whichever English was asked for, that is the one.
    func testEveryEnglishIsIndianEnglish() {
        XCTAssertEqual(SarvamLanguage.code(for: "en"), "en-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "en-US"), "en-IN")
    }

    /// "or" to everything else on this Mac, "od-IN" to Sarvam.
    func testOdiaIsSpelledSarvamsWay() {
        XCTAssertEqual(SarvamLanguage.code(for: "or"), "od-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "or-IN"), "od-IN")
        XCTAssertEqual(SarvamLanguage.code(for: "od-IN"), "od-IN")
        XCTAssertEqual(SarvamLanguage.name(of: "od-IN"), "Odia")
    }

    /// Saaras hears Urdu and Bulbul does not speak it. A companion has to do both.
    func testALanguageSarvamCannotBothHearAndSpeakIsNotGuessedAt() {
        for tag in ["fr", "ja", "ko-KR", "zh", "ur", "es-ES", "", "   "] {
            XCTAssertNil(SarvamLanguage.code(for: tag), "\"\(tag)\"")
        }
    }

    func testALanguageIsNamedInWordsForTheSentenceThatRefusesIt() {
        XCTAssertEqual(SarvamLanguage.name(of: "fr"), "French")
        XCTAssertEqual(SarvamLanguage.name(of: "ml-IN"), "Malayalam")
        XCTAssertEqual(SarvamLanguage.name(of: "zz"), "zz", "a tag nobody has a name for is shown as it is")
    }
}

final class WaveFileTests: XCTestCase {

    func testPCMIsWrappedAsAMonoSixteenBitWav() {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])
        let wav = WaveFile.wrap(pcm16: pcm, sampleRate: 16_000)

        func u32(_ offset: Int) -> UInt32 {
            wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ offset: Int) -> UInt16 {
            wav.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }
        func text(_ range: Range<Int>) -> String { String(decoding: wav.subdata(in: range), as: UTF8.self) }

        XCTAssertEqual(wav.count, 48)
        XCTAssertEqual(text(0..<4), "RIFF")
        XCTAssertEqual(u32(4), 40, "the file's size, less the eight bytes that say so")
        XCTAssertEqual(text(8..<16), "WAVEfmt ")
        XCTAssertEqual(u16(20), 1, "PCM")
        XCTAssertEqual(u16(22), 1, "mono")
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(u32(28), 32_000, "bytes a second")
        XCTAssertEqual(u16(32), 2, "bytes a sample")
        XCTAssertEqual(u16(34), 16, "bits a sample")
        XCTAssertEqual(text(36..<40), "data")
        XCTAssertEqual(u32(40), 4)
        XCTAssertEqual(wav.subdata(in: 44..<48), pcm)
    }

    func testAWavSaysHowLongItIs() {
        let second = WaveFile.wrap(pcm16: Data(count: 48_000), sampleRate: 24_000)
        XCTAssertEqual(WaveFile.seconds(of: second) ?? -1, 1, accuracy: 0.001)
        let half = WaveFile.wrap(pcm16: Data(count: 16_000), sampleRate: 16_000)
        XCTAssertEqual(WaveFile.seconds(of: half) ?? -1, 0.5, accuracy: 0.001)
    }

    func testSomethingThatIsNotAWavHasNoLength() {
        XCTAssertNil(WaveFile.seconds(of: Data()))
        XCTAssertNil(WaveFile.seconds(of: Data("not a wav at all, just some text".utf8)))
        XCTAssertNil(WaveFile.seconds(of: Data("RIFF\0\0\0\0WAVE".utf8)), "a header with no sound in it")
    }

    /// A slice of a larger buffer keeps its parent's indices; reading it from zero would trap.
    func testASliceIsReadFromItsOwnStart() {
        let padded = Data([9, 9, 9]) + WaveFile.wrap(pcm16: Data(count: 32_000), sampleRate: 16_000)
        XCTAssertEqual(WaveFile.seconds(of: padded.dropFirst(3)) ?? -1, 1, accuracy: 0.001)
    }

    /// A streamed WAV can claim more sound than it holds. What is there is what plays.
    func testAWavThatClaimsMoreThanItHoldsIsMeasuredByWhatItHolds() {
        var wav = WaveFile.wrap(pcm16: Data(count: 32_000), sampleRate: 16_000)
        wav.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(WaveFile.seconds(of: wav) ?? -1, 1, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run to see them fail.** `swift build --build-tests` → `cannot find 'SarvamLanguage' in scope`, `cannot find 'WaveFile' in scope`.

- [ ] **Step 3: Implement.** Create `Sources/SaathiKit/SarvamLanguage.swift`:

```swift
//
//  SarvamLanguage.swift
//  SaathiKit
//
//  Saathi's language tags, in Sarvam's spelling.
//
//  Saathi keeps a BCP 47 tag in `shell.json` — "ml", "hi-IN". Sarvam's speech models take their own
//  list of codes: always with the region, always India, and Odia spelled "od" where every other
//  system on this Mac calls it "or". This is the one place that knows the difference.
//

import Foundation

public enum SarvamLanguage {

    /// What Bulbul speaks. Saaras hears all of these and twelve more, but a companion has to do
    /// both, so the shorter list is the list.
    static let spoken: Set<String> = ["bn", "en", "gu", "hi", "kn", "ml", "mr", "od", "pa", "ta", "te"]

    /// Sarvam's code for a tag — "ml" and "ml-IN" are both "ml-IN" — or nil when Sarvam cannot both
    /// hear and speak the language. English is "en-IN" whichever English was asked for: it is the
    /// only one Bulbul has.
    public static func code(for tag: String) -> String? {
        let language = primary(tag)
        let sarvam = language == "or" ? "od" : language
        return spoken.contains(sarvam) ? "\(sarvam)-IN" : nil
    }

    /// The language's name in English, for a sentence that has to say Sarvam does not speak it.
    public static func name(of tag: String) -> String {
        let language = primary(tag)
        return Locale(identifier: "en").localizedString(forLanguageCode: language == "od" ? "or" : language) ?? tag
    }

    private static func primary(_ tag: String) -> String {
        tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { $0.lowercased() } ?? ""
    }
}
```

Create `Sources/SaathiKit/WaveFile.swift`:

```swift
//
//  WaveFile.swift
//  SaathiKit
//
//  PCM16 into a WAV file, and how long a WAV is.
//
//  A WAV is the one audio container every speech service takes without being told what is in it:
//  forty-four bytes that say the rate, the width and the length, and then the samples. Saaras is
//  sent a turn in one; Bulbul answers in one.
//

import Foundation

public enum WaveFile {

    /// `pcm16` — mono, 16-bit, little-endian — as a WAV file at `sampleRate`.
    public static func wrap(pcm16: Data, sampleRate: Int) -> Data {
        var header = Data(capacity: 44)
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm16.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); put(UInt32(pcm16.count))
        return header + pcm16
    }

    /// How long a WAV plays for, from its own header: the bytes of sound over the bytes a second.
    /// Nil for anything that is not a WAV with both of those in it.
    public static func seconds(of wav: Data) -> Double? {
        // A slice keeps its parent's indices; a copy starts at zero, which is what the offsets
        // below assume.
        let wav = Data(wav)
        guard wav.count >= 12,
              wav.subdata(in: 0..<4) == Data("RIFF".utf8),
              wav.subdata(in: 8..<12) == Data("WAVE".utf8) else { return nil }

        func u32(_ offset: Int) -> UInt32 {
            wav.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }

        var bytesPerSecond: UInt32?
        var soundBytes: Int?
        var offset = 12
        while offset + 8 <= wav.count {
            let id = wav.subdata(in: offset..<offset + 4)
            let size = Int(u32(offset + 4))
            let body = offset + 8
            if id == Data("fmt ".utf8), body + 12 <= wav.count {
                bytesPerSecond = u32(body + 8)
            } else if id == Data("data".utf8) {
                // A streamed WAV may claim more than it holds; what is there is what plays.
                soundBytes = min(size, wav.count - body)
            }
            offset = body + size + size % 2
        }
        guard let bytesPerSecond, bytesPerSecond > 0, let soundBytes else { return nil }
        return Double(soundBytes) / Double(bytesPerSecond)
    }
}
```

In `RealtimeVoiceSession.swift` replace the body of `writeLastTurn` — the hand-written header — with the shared one:

```swift
    static func writeLastTurn(_ pcm16: Data) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".saathi/last-turn.wav")
        try? WaveFile.wrap(pcm16: pcm16, sampleRate: Int(VoiceAudioEngine.sampleRate)).write(to: url, options: .atomic)
    }
```

- [ ] **Step 4: Run to see them pass.** `swift test --filter "SarvamLanguageTests|WaveFileTests"` → all pass.

- [ ] **Step 5: Commit** — "A language tag in Sarvam's spelling, and PCM in the container speech services take".

---

### Task 4: The two requests — Saaras and Bulbul

**Files:**
- Create: `Sources/SaathiKit/SarvamClient.swift`
- Test: `Tests/SaathiKitTests/StubHTTP.swift` (shared helper), `Tests/SaathiKitTests/SarvamClientTests.swift`

**Interfaces:**
- Consumes: `WaveFile` (tests only).
- Produces:
  - `enum SarvamError: LocalizedError, Equatable { case keyRefused, outOfCredits, busy, refused(status: Int, message: String), unreadable(String), unreachable(String) }`, `static func refusal(status: Int, body: Data) -> SarvamError`
  - `struct SarvamClient { init(key: String, urlSession: URLSession = SarvamClient.session, host: URL = SarvamClient.host); func transcribe(wav: Data, language: String) async throws -> String; func synthesize(_ text: String, language: String, speaker: String = defaultSpeaker, pace: Double = 1) async throws -> [Data] }`
  - `SarvamClient.defaultSpeaker = "shubh"`, `.speakers: Set<String>`, `.longestUtterance = 2500`, `.session`
  - Test helper `StubHTTP.session(_ replies: Reply...) -> URLSession`, `StubHTTP.seen: [Seen]` (`request`, `body`, `json`), `StubHTTP.hold()`, `StubHTTP.Reply.json(_:status:)`, `.failing(_:)`; `Collected<Value>` with `add(_:)` and `all`.

- [ ] **Step 1: The stub.** Create `Tests/SaathiKitTests/StubHTTP.swift`:

```swift
//
//  StubHTTP.swift
//  SaathiKitTests
//
//  A URLSession that answers from a script and remembers what it was asked, bodies included.
//
//  Everything Saathi sends to Sarvam, and everything the chain lane sends to a model, is tested
//  against this rather than against a network: what matters is the exact request, and what is made
//  of each kind of answer. It can also hold an answer back, for the one question that needs the
//  moment between asking and hearing — what happens when the learner talks over it.
//

import Foundation
import os

final class StubHTTP: URLProtocol, @unchecked Sendable {

    struct Reply {
        var status = 200
        var body = Data()
        var failure: URLError.Code?

        static func json(_ object: Any, status: Int = 200) -> Reply {
            Reply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }

        /// No answer at all: the network is not there.
        static func failing(_ code: URLError.Code = .notConnectedToInternet) -> Reply {
            Reply(failure: code)
        }
    }

    struct Seen {
        let request: URLRequest
        let body: Data

        /// The body as the JSON object it was sent as.
        var json: [String: Any] {
            ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
        }
    }

    private struct Script {
        var replies: [Reply] = []
        var seen: [Seen] = []
        var holding = false
    }
    private static let script = OSAllocatedUnfairLock(initialState: Script())

    /// A session answered by `replies`, in order; the last one goes on answering. Starts a fresh
    /// script, so each test sees only its own requests.
    static func session(_ replies: [Reply]) -> URLSession {
        script.withLock { $0 = Script(replies: replies) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubHTTP.self]
        return URLSession(configuration: configuration)
    }

    static func session(_ replies: Reply...) -> URLSession {
        session(replies)
    }

    /// Every request since the session was made.
    static var seen: [Seen] {
        script.withLock { $0.seen }
    }

    /// From here on a request is taken and never answered, until its task is cancelled.
    static func hold() {
        script.withLock { $0.holding = true }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // URLProtocol hands the body over as a stream, never as `httpBody`.
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
        }

        let seen = Seen(request: request, body: body)
        let (reply, holding) = Self.script.withLock { script -> (Reply, Bool) in
            script.seen.append(seen)
            let reply = script.replies.count > 1 ? script.replies.removeFirst() : (script.replies.first ?? Reply())
            return (reply, script.holding)
        }
        if holding { return }

        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Collects what callbacks were handed, from whichever thread they arrive on.
final class Collected<Value: Sendable>: @unchecked Sendable {
    private let values = OSAllocatedUnfairLock(initialState: [Value]())

    func add(_ value: Value) {
        values.withLock { $0.append(value) }
    }

    var all: [Value] {
        values.withLock { $0 }
    }
}
```

- [ ] **Step 2: Write the failing tests.** Create `Tests/SaathiKitTests/SarvamClientTests.swift`:

```swift
//
//  SarvamClientTests.swift
//  SaathiKitTests
//
//  What is sent to Saaras and to Bulbul, and what is made of each kind of answer. Written against
//  Sarvam's reference as it stood on 2026-09-30: the requests here are the documented ones, field
//  for field, and the answers are the documented shapes. No key, no network.
//

import Foundation
import XCTest
@testable import SaathiKit

final class SarvamClientTests: XCTestCase {

    private func client(_ replies: StubHTTP.Reply...) -> SarvamClient {
        SarvamClient(key: " sk-sarvam \n", urlSession: StubHTTP.session(replies))
    }

    private let turn = WaveFile.wrap(pcm16: Data(repeating: 7, count: 320), sampleRate: 16_000)

    // MARK: ears

    func testATurnGoesToSaarasAsAMultipartWavWithItsLanguage() async throws {
        let sarvam = client(.json(["request_id": "r", "transcript": " നമസ്കാരം ", "language_code": "ml-IN"]))

        let heard = try await sarvam.transcribe(wav: turn, language: "ml-IN")
        XCTAssertEqual(heard, "നമസ്കാരം", "trimmed")

        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(StubHTTP.seen.count, 1)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.sarvam.ai/speech-to-text")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(
            seen.request.value(forHTTPHeaderField: "api-subscription-key"), "sk-sarvam",
            "a pasted key brings a newline with it; an untrimmed one is refused like a wrong one")

        let type = try XCTUnwrap(seen.request.value(forHTTPHeaderField: "Content-Type"))
        let prefix = "multipart/form-data; boundary="
        XCTAssertTrue(type.hasPrefix(prefix), type)
        let boundary = String(type.dropFirst(prefix.count))

        XCTAssertNotNil(seen.body.range(of: Data("name=\"language_code\"\r\n\r\nml-IN\r\n".utf8)))
        XCTAssertNotNil(seen.body.range(of: Data(
            "name=\"file\"; filename=\"turn.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)))
        XCTAssertNotNil(seen.body.range(of: turn), "the WAV itself, byte for byte")
        XCTAssertTrue(seen.body.starts(with: Data("--\(boundary)\r\n".utf8)))
        let closing = Data("\r\n--\(boundary)--\r\n".utf8)
        XCTAssertEqual(Data(seen.body.suffix(closing.count)), closing, "closed with the final boundary")
    }

    /// Saaras's current model is its default. Naming a version would only be a way to be left
    /// behind by the next one.
    func testNoModelIsNamedForTheEars() async throws {
        _ = try await client(.json(["transcript": "hello"])).transcribe(wav: turn, language: "en-IN")
        let body = try XCTUnwrap(StubHTTP.seen.first?.body)
        XCTAssertNil(body.range(of: Data("name=\"model\"".utf8)))
    }

    func testAnAnswerWithNoTranscriptIsAnErrorNotSilence() async {
        do {
            _ = try await client(.json(["request_id": "r"])).transcribe(wav: turn, language: "en-IN")
            XCTFail("an answer with nothing in it must not read as a turn in which nothing was said")
        } catch {
            XCTAssertEqual(error as? SarvamError, .unreadable("there was no transcript in it"))
        }
    }

    // MARK: mouth

    func testASentenceGoesToBulbulAndComesBackAsAudio() async throws {
        let clip = WaveFile.wrap(pcm16: Data(repeating: 1, count: 100), sampleRate: 24_000)
        let sarvam = client(.json(["request_id": "r", "audios": [clip.base64EncodedString()]]))

        let clips = try await sarvam.synthesize("നമസ്കാരം", language: "ml-IN")
        XCTAssertEqual(clips, [clip])

        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.sarvam.ai/text-to-speech")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "api-subscription-key"), "sk-sarvam")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(seen.json["text"] as? String, "നമസ്കാരം")
        XCTAssertEqual(seen.json["language_code"] as? String, "ml-IN")
        XCTAssertEqual(seen.json["speaker"] as? String, "shubh")
        XCTAssertEqual(seen.json["model"] as? String, "bulbul:v3")
        XCTAssertEqual(
            Set(seen.json.keys), ["text", "language_code", "speaker", "model"],
            "the fewest fields the reference allows: every one not sent is one that cannot be refused")
    }

    func testAPaceIsAskedForOnlyWhenItIsNotTheOrdinaryOneAndKeptInsideWhatBulbulTakes() async throws {
        let clip = Data("clip".utf8).base64EncodedString()
        func pace(_ asked: Double) async throws -> Double? {
            _ = try await client(.json(["audios": [clip]])).synthesize("x", language: "en-IN", pace: asked)
            return StubHTTP.seen.first?.json["pace"] as? Double
        }
        let ordinary = try await pace(1)
        XCTAssertNil(ordinary)
        // Calm and slow, as the speaker works it out: 0.9 × 0.85 in single precision.
        let calmAndSlow = try await pace(Double(Float(0.9) * Float(0.85)))
        XCTAssertEqual(calmAndSlow, 0.76)
        XCTAssertNotNil(
            StubHTTP.seen.first?.body.range(of: Data("\"pace\":0.76".utf8)),
            "two decimals on the wire, not the seventeen digits a float makes of it")
        let tooSlow = try await pace(0.1)
        XCTAssertEqual(tooSlow, 0.5)
        let tooFast = try await pace(5)
        XCTAssertEqual(tooFast, 2)
    }

    /// The reference says a list of base64 strings; its troubleshooting page reads `.audio` off
    /// each one. Whichever arrives is played.
    func testAudioWrappedInAnObjectIsReadToo() async throws {
        let clip = Data("a clip".utf8)
        let clips = try await client(.json(["audios": [["audio": clip.base64EncodedString()]]]))
            .synthesize("x", language: "en-IN")
        XCTAssertEqual(clips, [clip])
    }

    func testAnAnswerWithNoAudioInItIsAnError() async {
        for answer in [["request_id": "r"], ["audios": []], ["audios": [""]], ["audios": [42]]] as [[String: Any]] {
            do {
                _ = try await client(.json(answer)).synthesize("x", language: "en-IN")
                XCTFail("\(answer) has nothing to play in it")
            } catch {
                XCTAssertEqual(error as? SarvamError, .unreadable("there was no audio in it"))
            }
        }
    }

    // MARK: refusals

    /// Sarvam says no to a key with 403, not 401 — and says "out of credits" and "slow down" with
    /// the same 429. Only the code in the body tells them apart, and the difference is the whole
    /// of what the person needs to know.
    func testEachRefusalIsReadAsWhatItIs() {
        func refusal(_ status: Int, _ code: String) -> SarvamError {
            SarvamError.refusal(status: status, body: Data(#"{"error":{"message":"m","code":"\#(code)"}}"#.utf8))
        }
        XCTAssertEqual(refusal(403, "invalid_api_key_error"), .keyRefused)
        XCTAssertEqual(refusal(401, "anything"), .keyRefused)
        XCTAssertEqual(SarvamError.refusal(status: 403, body: Data()), .keyRefused, "a bare 403 is the key")
        XCTAssertEqual(refusal(403, "some_other_error"), .refused(status: 403, message: "m"), "let in, then told no")
        XCTAssertEqual(refusal(429, "insufficient_quota_error"), .outOfCredits)
        XCTAssertEqual(refusal(429, "rate_limit_exceeded_error"), .busy)
        XCTAssertEqual(refusal(503, "rate_limit_exceeded_error"), .busy)
        XCTAssertEqual(refusal(422, "unprocessable_entity_error"), .refused(status: 422, message: "m"))
        XCTAssertEqual(
            SarvamError.refusal(status: 500, body: Data("upstream fell over".utf8)),
            .refused(status: 500, message: "upstream fell over"),
            "not JSON: the body itself, as far as it goes")
    }

    func testEveryRefusalIsASentenceThatNamesSarvam() {
        let all: [SarvamError] = [
            .keyRefused, .outOfCredits, .busy, .refused(status: 422, message: "m"),
            .unreadable("x"), .unreachable("offline"),
        ]
        for error in all {
            XCTAssertTrue(error.localizedDescription.contains("Sarvam"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("couldn’t be completed"), error.localizedDescription)
        }
        XCTAssertTrue(SarvamError.keyRefused.localizedDescription.contains("Setup"))
        XCTAssertTrue(SarvamError.outOfCredits.localizedDescription.contains("credits"))
    }

    func testARefusalFromEitherEndpointIsThrownAsItself() async {
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "invalid_api_key_error"]], status: 403)
        do {
            _ = try await client(refused).transcribe(wav: turn, language: "en-IN")
            XCTFail("a 403 is not a transcript")
        } catch {
            XCTAssertEqual(error as? SarvamError, .keyRefused)
        }
        do {
            _ = try await client(refused).synthesize("x", language: "en-IN")
            XCTFail("a 403 is not audio")
        } catch {
            XCTAssertEqual(error as? SarvamError, .keyRefused)
        }
    }

    /// A wrong key and an aeroplane-mode laptop must never produce the same sentence.
    func testBeingOfflineIsNotARefusal() async {
        do {
            _ = try await client(.failing()).synthesize("x", language: "en-IN")
            XCTFail("there was no network")
        } catch {
            guard case .unreachable = error as? SarvamError else {
                return XCTFail("no network is unreachable, not \(error)")
            }
        }
    }
}
```

- [ ] **Step 3: Run to see them fail.** `swift build --build-tests` → `cannot find 'SarvamClient' in scope`.

- [ ] **Step 4: Implement.** Create `Sources/SaathiKit/SarvamClient.swift`:

```swift
//
//  SarvamClient.swift
//  SaathiKit
//
//  Sarvam's ears and mouth: a held turn of speech to Saaras, a sentence to Bulbul.
//
//  Two requests and one way of reading a refusal, and nothing else — no microphone, no playback,
//  no state. The thinking does not come through here: Sarvam's chat endpoint is OpenAI-shaped and
//  the chain lane already speaks that to everyone.
//
//  One request per step rather than Sarvam's streaming sockets. The REST endpoints are exactly what
//  the reference specifies and can be written against a stub with confidence; a socket protocol
//  written with no key to try it on is a guess. The price is no words appearing as they are said,
//  and a reply that starts once all of it has been synthesised rather than during.
//
//  Written from docs.sarvam.ai as it stood on 2026-09-30, and never yet run against a real key.
//  `saathi sarvam` is the command that finds out.
//

import Foundation

public enum SarvamError: Error, LocalizedError, Equatable, Sendable {
    /// The key is missing, wrong or revoked.
    case keyRefused
    /// The key is fine and the account behind it has nothing left.
    case outOfCredits
    /// Too many requests, or Sarvam is under load. Worth trying again.
    case busy
    /// Any other no, in Sarvam's own words.
    case refused(status: Int, message: String)
    /// An answer that was not the shape the reference shows.
    case unreadable(String)
    /// No answer at all.
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .keyRefused:
            return "Sarvam did not accept the key. Put a new one in Setup."
        case .outOfCredits:
            return "Sarvam says this account is out of credits. Add some at dashboard.sarvam.ai."
        case .busy:
            return "Sarvam is busy, or this key is asking too fast. Try again in a moment."
        case let .refused(status, message):
            return "Sarvam refused (\(status)): \(message)"
        case let .unreadable(what):
            return "Sarvam's answer could not be read: \(what)."
        case let .unreachable(reason):
            return "Could not reach Sarvam: \(reason)"
        }
    }

    /// Reads a refusal.
    ///
    /// Sarvam says no to a key with 403, not 401, and uses 403 for "let in, and then told no" as
    /// well: only `error.code` tells them apart. A spent account and a rate limit are both 429, and
    /// the difference matters to the person reading — one is fixed by waiting and the other is not.
    public static func refusal(status: Int, body: Data) -> SarvamError {
        let stated = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"] as? [String: Any]
        let code = stated?["code"] as? String ?? ""
        let message = (stated?["message"] as? String) ?? String(decoding: body.prefix(300), as: UTF8.self)

        if code == "insufficient_quota_error" { return .outOfCredits }
        switch status {
        case 401:
            return .keyRefused
        case 403 where code.isEmpty || code == "invalid_api_key_error" || code == "authentication_error":
            return .keyRefused
        case 429, 503:
            return .busy
        default:
            return .refused(status: status, message: message)
        }
    }
}

public struct SarvamClient: Sendable {

    public static let host = URL(string: "https://api.sarvam.ai")!

    /// Bulbul's own default, and one of the two voices its reference calls a safe start in every
    /// language. Named rather than left to the default: a companion's voice should not change
    /// because a provider changed its mind about a default.
    public static let defaultSpeaker = "shubh"

    /// Bulbul v3's speakers, as its reference listed them on 2026-09-30. A name that is not here is
    /// not sent — see `SarvamSpeech.speaker(named:)` — so a new voice cannot be chosen until this
    /// catches up, and a stale or mistyped one cannot fail every sentence.
    public static let speakers: Set<String> = [
        "shubh", "aditya", "ritu", "priya", "neha", "rahul", "pooja", "rohan", "simran", "kavya",
        "amit", "dev", "ishita", "shreya", "ratan", "varun", "manan", "sumit", "roopa", "kabir",
        "aayan", "ashutosh", "advait", "anand", "tanya", "tarun", "sunny", "mani", "gokul", "vijay",
        "shruti", "suhani", "mohit", "kavitha", "rehan", "soham", "rupali",
    ]

    static let speechModel = "bulbul:v3"

    /// Bulbul v3 takes 2500 characters a request.
    public static let longestUtterance = 2500

    /// One session for every client: nothing is cached and no cookie is kept, and a session per
    /// voice would be a session per change of language.
    public static let session = URLSession(configuration: .ephemeral)

    private let key: String
    private let urlSession: URLSession
    private let host: URL

    public init(key: String, urlSession: URLSession = SarvamClient.session, host: URL = SarvamClient.host) {
        // A pasted key routinely brings a newline with it, and an untrimmed one is refused in a
        // way indistinguishable from a wrong one.
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.urlSession = urlSession
        self.host = host
    }

    // MARK: ears

    /// What was said in `wav`, in `language` — Sarvam's code, "ml-IN". Up to thirty seconds.
    public func transcribe(wav: Data, language: String) async throws -> String {
        let data = try await send(Self.transcriptionRequest(wav: wav, language: language, key: key, host: host))
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transcript = answer["transcript"] as? String else {
            throw SarvamError.unreadable("there was no transcript in it")
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// No `model` is named: Saaras's current one is the default, and naming a version here would
    /// only be a way to be left behind by the next. The language is named, because the person chose
    /// it in Settings, and an unpinned transcript is how clean English once came back as Chinese.
    static func transcriptionRequest(
        wav: Data, language: String, key: String, host: URL,
        boundary: String = "saathi-\(UUID().uuidString)"
    ) -> URLRequest {
        var request = URLRequest(url: host.appendingPathComponent("speech-to-text"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func text(_ string: String) { body.append(Data(string.utf8)) }
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"language_code\"\r\n\r\n\(language)\r\n")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"turn.wav\"\r\n")
        text("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        text("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    // MARK: mouth

    /// `text` as speech: one WAV, or several to be played in order. Up to `longestUtterance`
    /// characters. `pace` is 1 for ordinary speed.
    public func synthesize(
        _ text: String, language: String, speaker: String = SarvamClient.defaultSpeaker, pace: Double = 1
    ) async throws -> [Data] {
        let request = try Self.speechRequest(
            text: text, language: language, speaker: speaker, pace: pace, key: key, host: host)
        let data = try await send(request)
        let audios = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["audios"] as? [Any] ?? []
        let clips = audios.compactMap { entry -> Data? in
            // The reference says a list of base64 strings; the troubleshooting page reads `.audio`
            // off each one. Either is taken.
            let encoded = (entry as? String) ?? ((entry as? [String: Any])?["audio"] as? String)
            let clip = encoded.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
            return clip?.isEmpty == false ? clip : nil
        }
        guard !clips.isEmpty else { throw SarvamError.unreadable("there was no audio in it") }
        return clips
    }

    /// The fewest fields the reference allows: the text, its language, the voice and the model.
    /// The sample rate and the container are left to Bulbul's defaults — a WAV — because the player
    /// reads both from the file, and every field not sent is a field that cannot be refused.
    static func speechRequest(
        text: String, language: String, speaker: String, pace: Double, key: String, host: URL
    ) throws -> URLRequest {
        var request = URLRequest(url: host.appendingPathComponent("text-to-speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "api-subscription-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "text": text, "language_code": language, "speaker": speaker, "model": speechModel,
        ]
        // Bulbul v3 takes 0.5 to 2. Two decimals, so calm-and-slow is sent as 0.76 and not as the
        // seventeen digits a float makes of 0.9 × 0.85.
        if abs(pace - 1) > 0.001 { body["pace"] = (min(2, max(0.5, pace)) * 100).rounded() / 100 }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: the wire

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports a cancelled task this way. It is not Sarvam being unreachable.
            throw CancellationError()
        } catch {
            throw SarvamError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SarvamError.unreadable("it was not an HTTP answer")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SarvamError.refusal(status: http.statusCode, body: data)
        }
        return data
    }
}
```

- [ ] **Step 5: Run to see them pass.** `swift test --filter SarvamClientTests`.

- [ ] **Step 6: Check the refusal shape against the live API (no key is used).**

```bash
curl -s -w "\n%{http_code}\n" -H "api-subscription-key: nope" -F language_code=hi-IN https://api.sarvam.ai/speech-to-text
curl -s -w "\n%{http_code}\n" -H "api-subscription-key: nope" -H "Content-Type: application/json" \
  -d '{"text":"hi","language_code":"en-IN"}' https://api.sarvam.ai/text-to-speech
```

Expected, both: `{"error":{"message":"…","code":"invalid_api_key_error",…}}` and `403`.

- [ ] **Step 7: Commit** — "Saaras and Bulbul, as two requests and one way of reading a no".

---

### Task 5: The chain lane, finished

**Files:**
- Create: `Sources/SaathiKit/Ears.swift`
- Rewrite: `Sources/SaathiKit/ChainVoiceSession.swift`
- Modify: `Sources/SaathiKit/VoiceSession.swift` (`interrupt()`), `Sources/SaathiKit/Speakers.swift` (`ObservedSpeaker` can be stopped as a `StoppableSpeaker`), `Sources/SaathiKit/ScreenSight.swift` (`answer(_:)`), `Sources/SaathiKit/RealtimeVoiceSession.swift` (uses `answer(_:)`), `Sources/SaathiShell/VoiceConductor.swift` (a held turn interrupts)
- Test: `Tests/SaathiKitTests/ChainLaneTests.swift`, `Tests/SaathiKitTests/VoiceTests.swift`, `Tests/SaathiShellTests/VoiceConductorTests.swift`

**Interfaces:**
- Consumes: `StubHTTP`, `Collected` (Task 4); `SarvamError.refusal` (Task 4); `SarvamLanguage` (Task 3).
- Produces:
  - `struct EarsFeedback { var onLevel: (@Sendable (Float) -> Void)?; var onPartial: (@Sendable (String) -> Void)? }`
  - `protocol Ears: Sendable { func prepare() async throws -> String; func begin(_ feedback: EarsFeedback) async throws; func finish() async throws -> String; func cancel() }`
  - `final class DeviceEars: Ears { init(language: String) }`, `enum Choice { own, locale(String), none }`, `static func choice(language:machine:supported:) -> Choice`, `static func settledFor(_:insteadOf:) -> String`
  - `ChainVoiceSession.init(configuration:speaker:ears: (any Ears)? = nil, urlSession:thinks:look: (@Sendable (String) async -> String)? = nil)`, `let ears: any Ears`, `func interrupt()`
  - `static func completionRequest(configuration:history:) throws -> URLRequest`, `chatCompletionsURL(base:) -> URL?`, `chatTools()`, `message(in:)`, `toolCalls(in:) -> [ToolCall]`, `kept(_:)`, `statedReason(in:)`, `refusal(status:body:configuration:)`, `mostRequestsPerTurn = 3`
  - `VoiceSession.interrupt()` (default: nothing)
  - `ScreenSight.answer(_ question: String) async -> String`
  - Test helpers `FakeEars`, `LoggingSpeaker`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/ChainLaneTests.swift`:

```swift
//
//  ChainLaneTests.swift
//  SaathiKitTests
//
//  The chain lane, run: a turn heard by whatever ears it was handed, the request a model is
//  actually sent, and what is made of every kind of answer — words, a tool call, a look at the
//  screen, a refusal, and an answer the learner has already talked over.
//
//  None of this could be tested while the session did its own listening: building one opened the
//  recogniser. It is handed its ears now, so a test hands it a pair that hears what the test says.
//

import Foundation
import os
import XCTest
@testable import SaathiContract
@testable import SaathiKit

/// Ears that hear what a test says they heard.
final class FakeEars: Ears, @unchecked Sendable {
    let calls = Collected<String>()
    private let heard: Result<String, any Error>

    init(hearing heard: String = "") { self.heard = .success(heard) }
    init(failing error: any Error) { self.heard = .failure(error) }

    func prepare() async throws -> String {
        calls.add("prepare")
        return "ready — a test's ears"
    }

    func begin(_ feedback: EarsFeedback) async throws {
        calls.add("begin")
        feedback.onLevel?(0.5)
        feedback.onPartial?("hel")
    }

    func finish() async throws -> String {
        calls.add("finish")
        return try heard.get()
    }

    func cancel() { calls.add("cancel") }
}

/// A speaker that writes what it said, and that it was stopped, into a log shared with whatever
/// else a test wants to see the order of.
final class LoggingSpeaker: Speaker, StoppableSpeaker, @unchecked Sendable {
    let log: Collected<String>

    init(log: Collected<String> = Collected()) { self.log = log }

    func speak(_ text: String, tone: Tone) async { log.add("say: \(text)") }
    func stop() { log.add("stop") }

    var said: [String] { log.all.filter { $0.hasPrefix("say: ") }.map { String($0.dropFirst(5)) } }
}

final class ChainLaneTests: XCTestCase {

    private let sarvam = SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-sarvam")

    /// Everything a session reported, by kind.
    private final class Heard: @unchecked Sendable {
        let user = Collected<String>()
        let saathi = Collected<String>()
        let actions = Collected<SaathiAction>()
        let statuses = Collected<String>()
        let looks = Collected<String>()
        let levels = Collected<Float>()
        let partials = Collected<String>()

        var callbacks: VoiceSessionCallbacks {
            VoiceSessionCallbacks(
                onUserTranscript: { self.user.add($0) },
                onSaathiTranscript: { self.saathi.add($0) },
                onAction: { self.actions.add($0) },
                onStatus: { self.statuses.add($0) },
                onScreenLook: { question, answer in self.looks.add("\(question) → \(answer)") },
                onInputLevel: { self.levels.add($0) },
                onPartialTranscript: { self.partials.add($0) })
        }
    }

    private func makeSession(
        _ replies: [StubHTTP.Reply],
        configuration: SaathiConfiguration? = nil,
        speaker: any Speaker = LoggingSpeaker(),
        ears: FakeEars = FakeEars(),
        thinks: Bool = true,
        look: @escaping @Sendable (String) async -> String = { _ in "nothing much" }
    ) -> ChainVoiceSession {
        ChainVoiceSession(
            configuration: configuration ?? sarvam, speaker: speaker, ears: ears,
            urlSession: StubHTTP.session(replies), thinks: thinks, look: look)
    }

    private func says(_ content: String) -> StubHTTP.Reply {
        .json(["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func calls(
        _ name: String, _ arguments: String, id: String = "call_1", saying content: String? = nil
    ) -> StubHTTP.Reply {
        let call: [String: Any] = [
            "id": id, "type": "function", "function": ["name": name, "arguments": arguments],
        ]
        var message: [String: Any] = ["role": "assistant", "tool_calls": [call]]
        if let content { message["content"] = content } else { message["content"] = NSNull() }
        return .json(["choices": [["message": message]]])
    }

    /// The messages of the nth request, system prompt first.
    private func messages(of request: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let seen = StubHTTP.seen
        guard request < seen.count else {
            XCTFail("only \(seen.count) request(s) were made", file: file, line: line)
            return []
        }
        return try XCTUnwrap(seen[request].json["messages"] as? [[String: Any]], file: file, line: line)
    }

    private func roles(_ messages: [[String: Any]]) -> [String] {
        messages.map { $0["role"] as? String ?? "?" }
    }

    // MARK: the ears it is handed

    func testATurnIsHeardByWhateverEarsItWasHandedAndThenThoughtAbout() async throws {
        let ears = FakeEars(hearing: "  what is a raga  ")
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says("A melodic frame.")], speaker: speaker, ears: ears)

        try await session.start(callbacks: heard.callbacks)
        try await session.beginTurn()
        try await session.endTurn()

        XCTAssertEqual(ears.calls.all, ["prepare", "begin", "finish"])
        XCTAssertEqual(heard.user.all, ["what is a raga"], "trimmed")
        XCTAssertEqual(speaker.said, ["A melodic frame."])
        XCTAssertEqual(heard.statuses.all, ["ready — a test's ears", "listening…", "thinking…"])
        XCTAssertEqual(heard.levels.all, [0.5], "the ears' level reaches whoever draws the bars")
        XCTAssertEqual(heard.partials.all, ["hel"])
        let sent = try messages(of: 0)
        XCTAssertEqual(sent.last?["content"] as? String, "what is a raga")
    }

    func testNothingHeardIsSaidSoAndNothingIsSent() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says("should never be asked")], speaker: speaker, ears: FakeEars(hearing: "   "))

        try await session.start(callbacks: heard.callbacks)
        try await session.beginTurn()
        try await session.endTurn()

        XCTAssertEqual(speaker.said, ["I did not catch that. Say it once more?"])
        XCTAssertTrue(heard.statuses.all.contains("did not catch that"))
        XCTAssertTrue(heard.user.all.isEmpty)
        XCTAssertTrue(StubHTTP.seen.isEmpty, "silence is not a question")
    }

    /// First run listens before any model has been chosen: a turn ends with the transcript.
    func testASessionThatOnlyListensSendsNothingAnywhere() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says("should never be asked")], speaker: speaker, ears: FakeEars(hearing: "Asha"), thinks: false)

        try await session.start(callbacks: heard.callbacks)
        try await session.beginTurn()
        try await session.endTurn()
        try await session.sendText("typed instead")

        XCTAssertEqual(heard.user.all, ["Asha", "typed instead"])
        XCTAssertTrue(heard.statuses.all.contains("heard"))
        XCTAssertTrue(speaker.said.isEmpty)
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    func testEarsThatCannotHearFailTheTurnWithTheirOwnReason() async throws {
        let session = makeSession([says("x")], ears: FakeEars(failing: SarvamError.outOfCredits))
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.beginTurn()
        do {
            try await session.endTurn()
            XCTFail("the ears refused")
        } catch {
            XCTAssertEqual(error as? SarvamError, .outOfCredits)
        }
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    func testStoppingTheSessionLetsGoOfTheMicrophone() async {
        let ears = FakeEars()
        let session = makeSession([], ears: ears)
        await session.stop()
        XCTAssertEqual(ears.calls.all, ["cancel"])
    }

    // MARK: what a model is sent

    private func requestBody(_ configuration: SaathiConfiguration, history: [[String: Any]] = []) throws -> (URLRequest, [String: Any]) {
        let request = try ChainVoiceSession.completionRequest(configuration: configuration, history: history)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        return (request, body)
    }

    /// The generated list is in the realtime socket's shape, with `type` beside the name. Nested as
    /// it stood, every server was handed a `function` with a `type` inside it.
    func testTheToolsGoOutInTheChatCompletionsEnvelope() throws {
        let (_, body) = try requestBody(sarvam)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, SaathiAction.allWireNames.count)
        for tool in tools {
            XCTAssertEqual(Set(tool.keys), ["type", "function"])
            XCTAssertEqual(tool["type"] as? String, "function")
            let function = try XCTUnwrap(tool["function"] as? [String: Any])
            XCTAssertEqual(Set(function.keys), ["name", "description", "parameters"], "no `type` inside the function")
        }
        XCTAssertEqual(
            tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String },
            SaathiAction.allWireNames)
        XCTAssertEqual(body["tool_choice"] as? String, "auto")
    }

    /// Sarvam-105B reasons before it answers unless told not to, and bills the reasoning.
    func testSarvamIsAskedNotToThinkAloudAndNobodyElseIsToldAnything() throws {
        let (_, asked) = try requestBody(sarvam)
        XCTAssertTrue(asked.keys.contains("reasoning_effort"))
        XCTAssertTrue(asked["reasoning_effort"] is NSNull, "null is how Sarvam is told not to")

        for other in [SaathiConfiguration(), SaathiConfiguration(provider: .anthropic, anthropicKey: "k")] {
            let (_, body) = try requestBody(other)
            XCTAssertFalse(body.keys.contains("reasoning_effort"), "\(other.resolvedProvider)")
        }
    }

    func testTheRequestGoesToTheProviderWithItsOwnKeyItsOwnModelAndThePromptFirst() throws {
        let (request, asked) = try requestBody(sarvam, history: [["role": "user", "content": "namaste"]])
        XCTAssertEqual(request.url?.absoluteString, "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-sarvam")
        XCTAssertEqual(asked["model"] as? String, "sarvam-105b")
        let messages = try XCTUnwrap(asked["messages"] as? [[String: Any]])
        XCTAssertEqual(roles(messages), ["system", "user"])
        XCTAssertTrue((messages[0]["content"] as? String ?? "").contains("You are Saathi"))

        let (local, _) = try requestBody(SaathiConfiguration())
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"), "a local model is asked with no key at all")
    }

    /// The default mode's own server. Ollama serves chat completions under `/v1` and nowhere else,
    /// and the local row's base has no path: posted to as it stood, the lane that needs no key got
    /// a 404 from the one server it was written for.
    func testABaseWithNoPathIsAskedUnderV1AndOneThatNamesAPathIsTakenAtItsWord() {
        func url(_ base: String) -> String? { ChainVoiceSession.chatCompletionsURL(base: base)?.absoluteString }
        XCTAssertEqual(url("http://localhost:11434"), "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(url("http://localhost:11434/"), "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(url("http://192.168.1.9:11434"), "http://192.168.1.9:11434/v1/chat/completions")
        XCTAssertEqual(url("https://api.anthropic.com"), "https://api.anthropic.com/v1/chat/completions")
        XCTAssertEqual(url("https://api.sarvam.ai/v1"), "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(url("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(url("http://box.local:8080/proxy/llm"), "http://box.local:8080/proxy/llm/chat/completions")
        XCTAssertNil(url("not a url"))
        XCTAssertNil(url(""))

        XCTAssertEqual(
            try? ChainVoiceSession.completionRequest(configuration: SaathiConfiguration(), history: []).url?.absoluteString,
            "http://localhost:11434/v1/chat/completions")
    }

    // MARK: what is made of an answer

    func testAReplyIsSpokenShownAndRemembered() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([says(" Namaste. "), says("Again.")], speaker: speaker)
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("hello")
        try await session.sendText("and again")

        XCTAssertEqual(speaker.said, ["Namaste.", "Again."])
        XCTAssertEqual(heard.saathi.all, ["Namaste.", "Again."])
        XCTAssertEqual(heard.user.all, ["hello", "and again"])
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "user"], "the chain lane keeps its own history")
        XCTAssertEqual(second[2]["content"] as? String, " Namaste. ")
    }

    /// Asked "what is this?", the model called `look_at_screen`, the lane did not know the tool,
    /// and Saathi said it was not sure what to do with that.
    func testALookIsAnsweredAndTheModelSaysWhatItSaw() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let asked = Collected<String>()
        let session = makeSession(
            [calls("look_at_screen", #"{"question":"what is this?"}"#), says("It is the Saathi folder.")],
            speaker: speaker,
            look: { question in
                asked.add(question)
                return "a folder called Saathi"
            })
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("what is this?")

        XCTAssertEqual(asked.all, ["what is this?"])
        XCTAssertEqual(heard.looks.all, ["what is this? → a folder called Saathi"], "kept in the conversation log")
        XCTAssertTrue(heard.statuses.all.contains("looking at the screen…"))
        XCTAssertEqual(speaker.said, ["It is the Saathi folder."])
        XCTAssertEqual(StubHTTP.seen.count, 2)
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(second[3]["content"] as? String, "a folder called Saathi")
    }

    /// "Let me see" belongs in front of the pause, not after it.
    func testWordsThatComeWithALookAreSaidBeforeIt() async throws {
        let log = Collected<String>()
        let session = makeSession(
            [calls("look_at_screen", #"{"question":"this"}"#, saying: "Let me look."), says("A folder.")],
            speaker: LoggingSpeaker(log: log),
            look: { _ in
                log.add("look")
                return "a folder"
            })
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("what is this")
        XCTAssertEqual(log.all, ["stop", "say: Let me look.", "look", "say: A folder."])
    }

    /// A reply with a tool call in it must be followed by an answer to that call, or the next
    /// request is a conversation no OpenAI-compatible server is obliged to accept.
    func testEveryToolCallIsAnsweredSoTheNextTurnIsAConversationAServerWillTake() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession(
            [calls("say", #"{"text":"hello there","tone":"calm"}"#), says("You are welcome.")], speaker: speaker)
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("greet me")
        XCTAssertEqual(heard.actions.all, [.say(SayAction(text: "hello there", tone: .calm))])
        XCTAssertEqual(StubHTTP.seen.count, 1, "a say is done, not discussed: nothing more is asked about it")
        XCTAssertTrue(speaker.said.isEmpty, "the performer says a `say`; the session has nothing to add")

        try await session.sendText("thanks")
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "tool", "user"])
        XCTAssertTrue(second[2]["content"] is NSNull, "a reply that is only a tool call has no words")
        XCTAssertNotNil(second[2]["tool_calls"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(second[3]["content"] as? String, "done")
    }

    /// Handed back rather than dropped, so the model can say something true instead of narrating
    /// an action that never happened.
    func testAToolSaathiDoesNotHaveIsToldSoAndTheModelGetsToAnswer() async throws {
        let speaker = LoggingSpeaker()
        let heard = Heard()
        let session = makeSession([calls("delete_everything", "{}"), says("I cannot do that.")], speaker: speaker)
        try await session.start(callbacks: heard.callbacks)

        try await session.sendText("delete everything")

        XCTAssertTrue(heard.actions.all.isEmpty)
        XCTAssertTrue(heard.statuses.all.contains("ignored a tool call: delete_everything is not an action Saathi has"))
        XCTAssertEqual(speaker.said, ["I cannot do that."])
        let second = try messages(of: 1)
        XCTAssertEqual(second.last?["content"] as? String, "not done — delete_everything is not an action Saathi has")
    }

    /// A call that cannot even be read still has an id, and the id still has to be answered.
    func testAMalformedToolCallIsAnsweredTooRatherThanLeftAsAHole() async throws {
        let broken = StubHTTP.Reply.json(["choices": [["message": [
            "role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_9", "type": "function"]],
        ]]]])
        let session = makeSession([broken, says("Sorry.")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("do something")
        let second = try messages(of: 1)
        XCTAssertEqual(roles(second), ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call_9")
    }

    /// Ollama sends a call's arguments as an object; everyone else as a string of JSON.
    func testArgumentsAreReadAsAStringOfJSONOrAsAnObject() {
        let asString = ChainVoiceSession.toolCalls(in: ["tool_calls": [[
            "id": "a", "function": ["name": "open_url", "arguments": #"{"url":"https://saathi.dev"}"#],
        ]]])
        let asObject = ChainVoiceSession.toolCalls(in: ["tool_calls": [[
            "function": ["name": "open_url", "arguments": ["url": "https://saathi.dev"]],
        ]]])
        XCTAssertEqual(asString.first?.arguments["url"] as? String, "https://saathi.dev")
        XCTAssertEqual(asObject.first?.arguments["url"] as? String, "https://saathi.dev")
        XCTAssertEqual(asObject.first?.id, "", "an id a server left out is an empty one, not a crash")
        XCTAssertTrue(ChainVoiceSession.toolCalls(in: ["content": "just words"]).isEmpty)
    }

    /// A model that keeps asking to look is stopped, rather than left to spend the learner's
    /// patience and their credit.
    func testAModelIsNotAskedForEver() async throws {
        let speaker = LoggingSpeaker()
        let session = makeSession([calls("look_at_screen", #"{"question":"again"}"#)], speaker: speaker)
        try await session.start(callbacks: VoiceSessionCallbacks())

        try await session.sendText("look")

        XCTAssertEqual(StubHTTP.seen.count, ChainVoiceSession.mostRequestsPerTurn)
        XCTAssertEqual(speaker.said, ["I am not sure what to do with that."])
        let third = roles(try messages(of: 2))
        XCTAssertEqual(third, ["system", "user", "assistant", "tool", "assistant", "tool"], "and what it did ask is still a whole conversation")
    }

    func testAnAnswerWithNeitherWordsNorAnActionIsNotLeftAsSilence() async throws {
        let speaker = LoggingSpeaker()
        let session = makeSession([says("   ")], speaker: speaker)
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("hmm")
        XCTAssertEqual(speaker.said, ["I am not sure what to do with that."])
    }

    /// Sarvam's thinking arrives beside its answer. Sent back, it would be billed a second time.
    func testThinkingAndWhateverElseAServerAddsIsNotSentBack() async throws {
        let thoughtful = StubHTTP.Reply.json(["choices": [["message": [
            "role": "assistant", "content": "Hi.", "reasoning_content": "The user greeted me…", "refusal": NSNull(),
        ]]]])
        let session = makeSession([thoughtful, says("Yes.")])
        try await session.start(callbacks: VoiceSessionCallbacks())
        try await session.sendText("hello")
        try await session.sendText("still there?")
        let kept = try messages(of: 1)[2]
        XCTAssertEqual(Set(kept.keys), ["role", "content"])
        XCTAssertEqual(kept["content"] as? String, "Hi.")
    }

    // MARK: talking over it

    /// The learner starts talking while an answer is still on its way. It is dropped — the request
    /// for it included, so the microphone is not kept waiting — and that is not a failure.
    func testAnAnswerTheLearnerTalkedOverIsNeverSpokenAndIsNotAFailure() async throws {
        let speaker = LoggingSpeaker()
        let session = makeSession([says("far too late")], speaker: speaker)
        try await session.start(callbacks: VoiceSessionCallbacks())
        StubHTTP.hold()

        let turn = Task { try await session.sendText("tell me a very long story") }
        for _ in 0..<400 where StubHTTP.seen.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(StubHTTP.seen.count, 1, "the question went out")

        session.interrupt()
        try await turn.value

        XCTAssertTrue(speaker.said.isEmpty)
        XCTAssertEqual(speaker.log.all.filter { $0 == "stop" }.count, 2, "once for the typed question, once for the interruption")
    }

    /// An interruption stops what is being said, there and then.
    func testInterruptingStopsTheSpeaker() {
        let speaker = LoggingSpeaker()
        let session = makeSession([], speaker: speaker)
        session.interrupt()
        XCTAssertEqual(speaker.log.all, ["stop"])
    }

    // MARK: when it does not work

    func testSarvamSayingNoIsASentenceNotAPageOfJSON() async throws {
        func failure(_ status: Int, _ code: String) async -> (any Error)? {
            let refusal = StubHTTP.Reply.json(["error": ["message": "no", "code": code]], status: status)
            let session = makeSession([refusal])
            do {
                try await session.start(callbacks: VoiceSessionCallbacks())
                try await session.sendText("hello")
                return nil
            } catch {
                return error
            }
        }
        let refused = await failure(403, "invalid_api_key_error")
        XCTAssertEqual(refused as? SarvamError, .keyRefused)
        let spent = await failure(429, "insufficient_quota_error")
        XCTAssertEqual(spent as? SarvamError, .outOfCredits)
        let busy = await failure(429, "rate_limit_exceeded_error")
        XCTAssertEqual(busy as? SarvamError, .busy)
    }

    func testALocalModelThatIsNotThereSaysWhatToStart() async throws {
        let session = makeSession([.failing(.cannotConnectToHost)], configuration: SaathiConfiguration())
        try await session.start(callbacks: VoiceSessionCallbacks())
        do {
            try await session.sendText("hello")
            XCTFail("nothing is listening")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Is Ollama or LM Studio running?"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("http://localhost:11434"), error.localizedDescription)
        }
    }

    func testARefusalIsTheServersOwnWordsWhereItHasAny() {
        let openAIShaped = Data(#"{"error":{"message":"model 'llama9' not found","type":"invalid_request_error"}}"#.utf8)
        XCTAssertEqual(ChainVoiceSession.statedReason(in: openAIShaped), "model 'llama9' not found")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data(#"{"error":"no such model"}"#.utf8)), "no such model")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data(#"{"detail":"Method Not Allowed"}"#.utf8)), "Method Not Allowed")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data("404 page not found\n".utf8)), "404 page not found")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data()), "no response body")
        XCTAssertEqual(ChainVoiceSession.statedReason(in: Data(String(repeating: "x", count: 5_000).utf8)).count, 300)

        let local = ChainVoiceSession.refusal(status: 404, body: openAIShaped, configuration: SaathiConfiguration())
        XCTAssertTrue(local.localizedDescription.contains("model 'llama9' not found"), local.localizedDescription)
        XCTAssertTrue(local.localizedDescription.contains("Ollama"), local.localizedDescription)
    }

    func testAnAnswerThatIsNotAnAnswerSaysSo() async throws {
        let session = makeSession([.json(["unexpected": true])])
        try await session.start(callbacks: VoiceSessionCallbacks())
        do {
            try await session.sendText("hello")
            XCTFail("there was no message in that")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not read the model's answer"), error.localizedDescription)
        }
    }
}
```

In `Tests/SaathiKitTests/VoiceTests.swift` add a class:

```swift
// MARK: - Which recogniser the on-device ears ask for

final class DeviceEarsTests: XCTestCase {

    private let supported = ["en-US", "en-GB", "en-IN", "fr-CA", "fr-FR", "hi-IN", "de-DE", "pt-BR"]

    /// It used to be the Mac's own language whatever Settings said: someone who chose French on an
    /// English Mac was heard as English words and answered in French.
    func testTheEarsAskForTheLanguageOfSettingsNotTheMacsOwn() {
        XCTAssertEqual(DeviceEars.choice(language: "hi", machine: "en_US", supported: supported), .locale("hi-IN"))
        XCTAssertEqual(DeviceEars.choice(language: "de-DE", machine: "en-US", supported: supported), .locale("de-DE"))
        XCTAssertEqual(
            DeviceEars.choice(language: "fr", machine: "en_US", supported: supported), .locale("fr-FR"),
            "a bare language gets its usual region, not the first in the alphabet")
        XCTAssertEqual(DeviceEars.choice(language: "fr-CA", machine: "en_US", supported: supported), .locale("fr-CA"))
        XCTAssertEqual(
            DeviceEars.choice(language: "pt", machine: "en_US", supported: supported), .locale("pt-BR"),
            "with no usual region on offer, whichever there is")
    }

    /// The Mac's own recogniser when it speaks the language: it knows which English its owner means.
    func testTheMacsOwnRecogniserIsKeptForItsOwnLanguage() {
        XCTAssertEqual(DeviceEars.choice(language: "en", machine: "en_US", supported: supported), .own)
        XCTAssertEqual(DeviceEars.choice(language: "en-IN", machine: "en_GB", supported: supported), .own)
    }

    func testALanguageThisMacHasNoRecogniserForIsNone() {
        for language in ["ml", "ta-IN", "or"] {
            XCTAssertEqual(DeviceEars.choice(language: language, machine: "en_US", supported: supported), .none, language)
        }
    }

    /// The Mac's own recogniser standing in is what this lane always did. It is said now, and the
    /// way out is named where there is one: Sarvam hears ten Indian languages this Mac cannot.
    func testSettlingForTheMacsOwnRecogniserIsSaidAndSoIsWhoCouldHear() {
        XCTAssertEqual(
            DeviceEars.settledFor("en-US", insteadOf: "ml"),
            "ready — on-device speech recognition (en-US). This Mac cannot hear Malayalam on its own. "
                + "Sarvam can hear it: add a Sarvam key, or turn its speech on, in Setup.")
        XCTAssertEqual(
            DeviceEars.settledFor("en-US", insteadOf: "sw"),
            "ready — on-device speech recognition (en-US). This Mac cannot hear Swahili on its own.")
    }
}
```

In `Tests/SaathiShellTests/VoiceConductorTests.swift` give `FakeSession` an optional note of interruptions — add a stored property and an init parameter, and the method:

```swift
    let notesInterruptions: Bool
```

```swift
    init(_ name: String, log: OSAllocatedUnfairLock<[String]>, speaksForItself: Bool = false, endDelay: UInt64 = 0, notesInterruptions: Bool = false) {
        self.name = name
        self.log = log
        self.speaksForItself = speaksForItself
        self.endDelay = endDelay
        self.notesInterruptions = notesInterruptions
    }
```

```swift
    func interrupt() { if notesInterruptions { note("interrupt") } }
```

and add two tests to `VoiceConductorTests`:

```swift
    /// Holding the keys while Saathi is talking, or thinking, stops it — before the turn opens,
    /// not after the answer nobody wanted has been said.
    func testOpeningATurnInterruptsWhateverWasUnderWay() async {
        let log = self.log
        let voice = conductor { _ in FakeSession("s", log: log, notesInterruptions: true) }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()

        voice.keysBegan()
        voice.keysEnded()
        await voice.settle()
        XCTAssertEqual(log.withLock { $0 }, ["s.start", "s.interrupt", "s.begin", "s.end"])

        log.withLock { $0.removeAll() }
        voice.toggleTalk()
        voice.toggleTalk()
        await voice.settle()
        XCTAssertEqual(log.withLock { $0 }, ["s.interrupt", "s.begin", "s.end"], "the menu's Talk does the same")
    }

    /// A second key-down while the turn is already open is not a second interruption.
    func testATurnAlreadyOpenIsNotInterruptedAgain() async {
        let log = self.log
        let voice = conductor { _ in FakeSession("s", log: log, notesInterruptions: true) }
        voice.start(with: SaathiConfiguration(provider: .local))
        await voice.settle()
        voice.keysBegan()
        voice.keysBegan()
        voice.keysEnded()
        await voice.settle()
        XCTAssertEqual(log.withLock { $0 }.filter { $0 == "s.interrupt" }.count, 1)
    }
```

- [ ] **Step 2: Run to see them fail.** `swift build --build-tests` → `cannot find type 'Ears' in scope`, `extra argument 'ears' in call`, `type 'ChainVoiceSession' has no member 'completionRequest'`, `'FakeSession' does not …`.

- [ ] **Step 3: The ears.** Create `Sources/SaathiKit/Ears.swift`:

```swift
//
//  Ears.swift
//  SaathiKit
//
//  One held turn of speech, turned into text.
//
//  The chain lane used to do its own listening, with Apple's on-device recogniser written straight
//  into the session. That recogniser knows English well and, on the Mac this was written on, has
//  no recogniser at all for Tamil, Telugu, Bengali, Marathi, Kannada, Malayalam, Gujarati, Punjabi
//  or Odia — so a lane that exists to work with any model could only be spoken to in one language.
//  Listening is a value now: the session is handed a pair of ears and does not know whose they are.
//

import AVFoundation
import Foundation
import os
import SaathiContract
import Speech

/// What a pair of ears can show while a turn is open. Nothing is decided from either.
public struct EarsFeedback: Sendable {
    /// How loud the microphone is, 0…1, a few times a second.
    public var onLevel: (@Sendable (Float) -> Void)?
    /// What has been made out so far. Only ears that recognise as they go have anything to say.
    public var onPartial: (@Sendable (String) -> Void)?

    public init(
        onLevel: (@Sendable (Float) -> Void)? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) {
        self.onLevel = onLevel
        self.onPartial = onPartial
    }
}

public protocol Ears: Sendable {
    /// Asks for what it needs, once, and says in a line what it will listen with. Throws, in words
    /// a person can act on, when it cannot listen at all.
    func prepare() async throws -> String
    /// The turn has opened.
    func begin(_ feedback: EarsFeedback) async throws
    /// The turn has closed: what was said, or "" when nothing was.
    func finish() async throws -> String
    /// Stop listening and keep nothing.
    func cancel()
}

/// Apple's recogniser, required on-device. The learner's voice never leaves the machine — that is
/// the promise, not an optimisation, which is why a language it cannot do on-device is left to the
/// Mac's own recogniser, out loud, and is never a quiet trip to Apple's servers.
public final class DeviceEars: Ears, @unchecked Sendable {

    private let language: String

    /// Everything touched from both the caller and the recognition callback, behind one scoped
    /// lock. `NSLock.lock()` is unavailable from an async context in the Swift 6 language mode —
    /// and rightly so, since holding a lock across a suspension point is how deadlocks are made.
    /// `withLock` cannot span an `await`, which is the property that matters.
    private struct State {
        var request: SFSpeechAudioBufferRecognitionRequest?
        var recognitionTask: SFSpeechRecognitionTask?
        var audioEngine: AVAudioEngine?
        var latestTranscript = ""
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    private var recognizer: SFSpeechRecognizer?

    /// `language`: the one in Settings, as a BCP 47 tag or a bare code.
    public init(language: String) {
        self.language = language
    }

    public func prepare() async throws -> String {
        // Ask once, up front, and say what is being asked for. Being surprised by a permission
        // dialog mid-sentence is exactly the kind of thing this project should not do.
        guard await Self.requestSpeechAuthorization() else {
            throw VoiceError.notConfigured(
                "Saathi needs permission to use speech recognition. Grant it in System Settings → Privacy & Security → Speech Recognition.")
        }

        // The recogniser for the language in Settings, when this Mac has one that works on-device.
        // It used to be `SFSpeechRecognizer()` and nothing else — the Mac's own language whatever
        // Settings said — so someone who chose French on an English Mac was heard as English words.
        let own = SFSpeechRecognizer()
        var recognizer = own
        var settled = false
        switch Self.choice(
            language: language,
            machine: own?.locale.identifier ?? Locale.current.identifier,
            supported: SFSpeechRecognizer.supportedLocales().map(\.identifier)
        ) {
        case .own:
            break
        case let .locale(identifier):
            if let theirs = SFSpeechRecognizer(locale: Locale(identifier: identifier)),
               theirs.isAvailable, theirs.supportsOnDeviceRecognition {
                recognizer = theirs
            } else {
                settled = true
            }
        case .none:
            settled = true
        }

        guard let recognizer, recognizer.isAvailable else {
            throw VoiceError.notConfigured("speech recognition is not available on this Mac right now")
        }
        // The on-device requirement is the promise, not an optimisation. Without it Apple may send
        // audio to its own servers, which would make the report's "your voice stays on this
        // machine" line false — so an unavailable on-device recogniser is an error, not a fallback.
        guard recognizer.supportsOnDeviceRecognition else {
            throw VoiceError.notConfigured(
                "on-device speech recognition is not available for \(recognizer.locale.identifier). "
                + "Add the language under System Settings → Keyboard → Dictation to download it."
                + Self.sarvamHint(language))
        }
        self.recognizer = recognizer
        // The Mac's own recogniser standing in is what this lane always did, and nothing leaves
        // the machine for it. It is said, because someone speaking Malayalam to an English
        // recogniser should be told why they are misheard and who would hear them.
        return settled
            ? Self.settledFor(recognizer.locale.identifier, insteadOf: language)
            : "ready — on-device speech recognition (\(recognizer.locale.identifier))"
    }

    public func begin(_ feedback: EarsFeedback) async throws {
        guard let recognizer else { throw VoiceError.notConfigured("start() was not called") }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceError.audio("no microphone input available")
        }
        let onLevel = feedback.onLevel
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: format) { buffer, _ in
            request.append(buffer)
            onLevel?(InputLevel.level(of: buffer))
        }
        engine.prepare()
        try engine.start()

        state.withLock { box in
            box.request = request
            box.audioEngine = engine
            box.latestTranscript = ""
        }

        let onPartial = feedback.onPartial
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            self.state.withLock { $0.latestTranscript = text }
            onPartial?(text)
        }
        state.withLock { $0.recognitionTask = task }
    }

    public func finish() async throws -> String {
        let (engine, request) = state.withLock { ($0.audioEngine, $0.request) }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        request?.endAudio()

        // Recognition finishes slightly after the audio does. Poll briefly rather than racing it —
        // the alternative is dropping the last word of every turn.
        var transcript = ""
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            transcript = state.withLock { $0.latestTranscript }
            if !transcript.isEmpty { break }
        }
        forget()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancel() {
        let engine = state.withLock { $0.audioEngine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        forget()
    }

    private func forget() {
        state.withLock { box in
            box.recognitionTask?.cancel()
            box.recognitionTask = nil
            box.audioEngine = nil
            box.request = nil
        }
    }

    // MARK: which recogniser

    /// Which recogniser to ask for.
    enum Choice: Equatable {
        /// The Mac's own: it speaks the language, and knows which English its owner means.
        case own
        /// One for the language in Settings, in this region.
        case locale(String)
        /// This Mac has none for that language.
        case none
    }

    /// Pure, so the rule is tested against lists rather than against whatever this Mac has.
    ///
    /// - `language`: the one in Settings, "fr" or "fr-CA".
    /// - `machine`: the locale of the Mac's own recogniser.
    /// - `supported`: every locale a recogniser exists for, as `supportedLocales()` lists them.
    static func choice(language: String, machine: String, supported: [String]) -> Choice {
        let wanted = languageCode(of: language)
        if wanted == languageCode(of: machine) { return .own }

        let spelled = { (tag: String) in tag.replacingOccurrences(of: "_", with: "-").lowercased() }
        let same = supported.filter { languageCode(of: $0) == wanted }
        if let exact = same.first(where: { spelled($0) == spelled(language) }) { return .locale(exact) }
        // A bare language gets its usual region, not whichever sorts first: "fr" is France's.
        if let usual = SpeechSettings.usualRegion[wanted],
           let match = same.first(where: { spelled($0) == spelled(usual) }) {
            return .locale(match)
        }
        return same.sorted().first.map(Choice.locale) ?? .none
    }

    private static func languageCode(of tag: String) -> String {
        Locale(identifier: tag).language.languageCode?.identifier.lowercased()
            ?? tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() }
            ?? tag.lowercased()
    }

    /// What is said when the Mac's own recogniser stands in for one it does not have.
    static func settledFor(_ own: String, insteadOf language: String) -> String {
        "ready — on-device speech recognition (\(own)). This Mac cannot hear "
            + "\(SarvamLanguage.name(of: language)) on its own." + sarvamHint(language)
    }

    /// The way out, when there is one: Sarvam hears ten Indian languages this Mac cannot.
    static func sarvamHint(_ language: String) -> String {
        SarvamLanguage.code(for: language) == nil
            ? ""
            : " Sarvam can hear it: add a Sarvam key, or turn its speech on, in Setup."
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
```

- [ ] **Step 4: The session.** Replace `Sources/SaathiKit/ChainVoiceSession.swift` with:

```swift
//
//  ChainVoiceSession.swift
//  SaathiKit
//
//  The lane that works everywhere: speech in, think, speech out, as three separate steps.
//
//  This is the slower path — the predecessor moved away from exactly this shape because a turn took
//  seconds rather than being instant. It exists here anyway, and it is not a consolation prize:
//
//  - It is the ONLY lane that works in `local` mode, which is Saathi's default. A companion whose
//    default mode cannot be spoken to would have the accessibility premise backwards.
//  - By default both ends run on-device (`DeviceEars`, the system voice), so even with a cloud
//    provider doing the thinking, the learner's VOICE never leaves the machine — only the
//    transcript does. For someone narrating what they are struggling with, that is a materially
//    different promise from the realtime lane, and `VoiceLaneReport` says so out loud.
//  - It is the lane Sarvam rides: with `speech: sarvam` the ears are Saaras and the mouth is
//    Bulbul, which is the only way to be heard in most Indian languages. The voice then does leave
//    the machine, and the same report says that instead.
//
//  The session does not know whose ears it has. It is handed a pair, and a speaker, and does the
//  step in the middle: an OpenAI-compatible `/chat/completions` with the generated contract tools
//  attached, which is why Ollama, LM Studio, llama.cpp and Sarvam all work through one code path.
//

import Foundation
import os
import SaathiContract

public final class ChainVoiceSession: VoiceSession, @unchecked Sendable {

    public let lane: VoiceLane = .chain
    public let speaksForItself = false

    private let configuration: SaathiConfiguration
    private let speaker: any Speaker
    let ears: any Ears
    private let urlSession: URLSession
    private let look: @Sendable (String) async -> String
    /// False for a session that only listens: a turn ends with the transcript and nothing is sent
    /// to any model. First run uses it — "can I hear you?" and "what should I call you?" are
    /// answered by what was heard, and must work before a model has been chosen at all.
    public let thinks: Bool

    /// How many times the model may be asked in one turn: once, and again after it has looked at
    /// the screen or been told a tool call could not be done. A model that keeps asking is
    /// stopped here rather than left to spend the learner's patience and their credit.
    static let mostRequestsPerTurn = 3

    /// Everything touched from more than one thread, behind one scoped lock. `withLock` cannot
    /// span an `await`, which is the property that matters.
    private struct State {
        var callbacks = VoiceSessionCallbacks()
        /// Bumped whenever the learner starts something new. An answer from before it is never
        /// spoken: they have moved on, and talking over them is the one thing a companion that
        /// listens must not do.
        var epoch = 0
        /// The request to the model that is in flight, so an interruption can drop it at once
        /// instead of waiting seconds for an answer nobody wants.
        var request: Task<(Data, URLResponse), any Error>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// The conversation so far. The chain lane has no server-side session, so continuity is this.
    /// Only ever touched from a turn, and turns are serial.
    private var history: [[String: Any]] = []

    /// `ears`: on-device ones in the language of Settings unless a pair is handed in.
    /// `look`: what answers a `look_at_screen`; `ScreenSight` unless a test says otherwise.
    public init(
        configuration: SaathiConfiguration,
        speaker: any Speaker,
        ears: (any Ears)? = nil,
        urlSession: URLSession = URLSession(configuration: .default),
        thinks: Bool = true,
        look: (@Sendable (String) async -> String)? = nil
    ) {
        self.configuration = configuration
        self.speaker = speaker
        self.ears = ears ?? DeviceEars(language: configuration.resolvedLanguage)
        self.urlSession = urlSession
        self.thinks = thinks
        self.look = look ?? { question in
            await ScreenSight(configuration: configuration).answer(question)
        }
    }

    public func start(callbacks: VoiceSessionCallbacks) async throws {
        state.withLock { $0.callbacks = callbacks }
        // The ears ask for what they need, once, up front, and say what is being asked for. Being
        // surprised by a permission dialog mid-sentence is exactly what this project should not do.
        callbacks.onStatus?(try await ears.prepare())
    }

    public func beginTurn() async throws {
        let callbacks = state.withLock { $0.callbacks }
        try await ears.begin(EarsFeedback(
            onLevel: callbacks.onInputLevel, onPartial: callbacks.onPartialTranscript))
        callbacks.onStatus?("listening…")
    }

    public func endTurn() async throws {
        let (callbacks, epoch) = state.withLock { ($0.callbacks, $0.epoch) }

        let heard = try await ears.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        guard isCurrent(epoch) else { return }
        guard !heard.isEmpty else {
            callbacks.onStatus?("did not catch that")
            // A listen-only session leaves the asking-again to whoever is listening through it.
            if thinks { await speaker.speak("I did not catch that. Say it once more?", tone: .calm) }
            return
        }
        callbacks.onUserTranscript?(heard)
        guard thinks else {
            callbacks.onStatus?("heard")
            return
        }
        callbacks.onStatus?("thinking…")
        try await answer(heard, epoch: epoch, callbacks: callbacks)
    }

    public func sendText(_ text: String) async throws {
        // A typed question supersedes whatever was being said or thought about, as a held turn does.
        interrupt()
        let (callbacks, epoch) = state.withLock { ($0.callbacks, $0.epoch) }
        callbacks.onUserTranscript?(text)
        guard thinks else { return }
        callbacks.onStatus?("thinking…")
        try await answer(text, epoch: epoch, callbacks: callbacks)
    }

    /// The learner has started talking. Whatever Saathi was saying stops, and whatever it was
    /// about to say is dropped — the request for it included, so the microphone is not kept
    /// waiting on an answer nobody wants any more.
    public func interrupt() {
        let request = state.withLock { state -> Task<(Data, URLResponse), any Error>? in
            state.epoch += 1
            return state.request
        }
        request?.cancel()
        (speaker as? StoppableSpeaker)?.stop()
    }

    public func stop() async {
        interrupt()
        ears.cancel()
    }

    private func isCurrent(_ epoch: Int) -> Bool {
        state.withLock { $0.epoch == epoch }
    }

    // MARK: The thinking step

    /// A turn the learner talked over ends quietly: its request was cancelled on purpose, and
    /// reporting that as a failure would put an alert on the island for doing the right thing.
    private func answer(_ said: String, epoch: Int, callbacks: VoiceSessionCallbacks) async throws {
        do {
            try await think(about: said, epoch: epoch, callbacks: callbacks)
        } catch {
            guard isCurrent(epoch) else { return }
            throw error
        }
    }

    private func think(about said: String, epoch: Int, callbacks: VoiceSessionCallbacks) async throws {
        history.append(["role": "user", "content": said])

        var spoke = false
        var acted = false

        for _ in 0..<Self.mostRequestsPerTurn {
            let message = try await complete()
            guard isCurrent(epoch) else { return }

            let calls = Self.toolCalls(in: message)
            let content = (message["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let looks = calls.contains { $0.name == LookAtScreenAction.wireName }

            // Words that come with a look are said before it: "let me see" belongs in front of the
            // pause, not after it. Everything else keeps the other order — doing the thing before
            // narrating it reads as competent, and a failed tool call changes what there is to say.
            if looks, !content.isEmpty {
                callbacks.onSaathiTranscript?(content)
                await speaker.speak(content, tone: .neutral)
                spoke = true
                guard isCurrent(epoch) else { return }
            }

            // What this round adds to the conversation: the reply, and an answer to every tool call
            // in it. Kept aside until the round is whole, because a reply with tool calls and no
            // answers to them is a conversation the next request would be refused for.
            var round: [[String: Any]] = [Self.kept(message)]
            var owesAnAnswer = false
            for call in calls {
                if call.name == LookAtScreenAction.wireName {
                    // Looking is the one tool whose *answer* is the point. It goes back to the
                    // model, which then says what it saw.
                    let question = (call.arguments["question"] as? String) ?? said
                    callbacks.onStatus?("looking at the screen…")
                    let seen = await look(question)
                    guard isCurrent(epoch) else { return }
                    callbacks.onScreenLook?(question, seen)
                    round.append(Self.toolResult(call.id, seen))
                    owesAnAnswer = true
                    continue
                }
                switch VoiceToolCall.parse(name: call.name, arguments: call.arguments) {
                case let .success(action):
                    callbacks.onAction?(action)
                    acted = true
                    round.append(Self.toolResult(call.id, "done"))
                case let .failure(failure):
                    // Handed back rather than dropped, so the model can say something true instead
                    // of narrating an action that never happened.
                    callbacks.onStatus?("ignored a tool call: \(failure.description)")
                    round.append(Self.toolResult(call.id, "not done — \(failure.description)"))
                    owesAnAnswer = true
                }
            }
            history.append(contentsOf: round)

            if !looks, !content.isEmpty {
                callbacks.onSaathiTranscript?(content)
                await speaker.speak(content, tone: .neutral)
                spoke = true
                guard isCurrent(epoch) else { return }
            }

            guard owesAnAnswer else { break }
            callbacks.onStatus?("thinking…")
        }

        if !spoke, !acted, isCurrent(epoch) {
            // Neither words nor an action. Saying nothing at all reads as a hang to someone who
            // cannot see a spinner.
            await speaker.speak("I am not sure what to do with that.", tone: .calm)
        }
    }

    /// One request to the model with the conversation so far, and the message it answered with.
    private func complete() async throws -> [String: Any] {
        let request = try Self.completionRequest(configuration: configuration, history: history)
        let urlSession = self.urlSession
        let inFlight = Task { try await urlSession.data(for: request) }
        state.withLock { $0.request = inFlight }
        defer { state.withLock { $0.request = nil } }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await withTaskCancellationHandler {
                try await inFlight.value
            } onCancel: {
                inFlight.cancel()
            }
        } catch {
            throw Self.unreachable(error, configuration: configuration)
        }

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Self.refusal(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data, configuration: configuration)
        }
        guard let message = Self.message(in: data) else {
            throw VoiceError.transport("could not read the model's answer")
        }
        return message
    }

    // MARK: What is sent, and what is kept

    /// The request for one reply. Pure, so what a provider is actually sent can be read in a test
    /// — and so `saathi sarvam` can send exactly what a turn would.
    static func completionRequest(configuration: SaathiConfiguration, history: [[String: Any]]) throws -> URLRequest {
        let row = configuration.providerRow
        let base = configuration.resolvedProviderBaseURL
        guard let url = chatCompletionsURL(base: base) else {
            throw VoiceError.transport("\(base) is not a usable base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The credential and how to present it both come from the contract row, so adding a
        // provider stays a row in the schema rather than a branch here.
        let credential = (row.requiresToken ? configuration.token : configuration.credential(for: row.kind)) ?? ""
        if let header = row.authorizationHeader(credential: credential) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }

        let instructions: [String: Any] = [
            "role": "system", "content": RealtimeVoiceSession.instructions(for: configuration),
        ]
        var body: [String: Any] = [
            "model": configuration.resolvedModel,
            "messages": [instructions] + history,
            "tools": try chatTools(),
            "tool_choice": "auto",
        ]
        // Sarvam-105B reasons before it answers unless told not to, and bills the reasoning. A
        // spoken reply is a sentence or two; the pause in front of it is the cost that matters.
        if row.kind == .sarvam { body["reasoning_effort"] = NSNull() }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Where a provider's chat completions live: `/chat/completions` on its base, and a base that
    /// names no path at all gets `/v1` first.
    ///
    /// Every OpenAI-compatible server Saathi is pointed at serves them under `/v1` — Ollama,
    /// LM Studio, llama.cpp, Anthropic's compatibility layer. The local row's base is
    /// `http://localhost:11434`, which is also how anyone would write another Ollama host, and
    /// `/chat/completions` straight on that is a 404 from the very server the default mode is for.
    /// A base that already names a path is taken at its word.
    static func chatCompletionsURL(base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: root), url.scheme != nil, url.host != nil else { return nil }
        return URL(string: "\(root)\(url.path.isEmpty ? "/v1" : "")/chat/completions")
    }

    /// The contract's tools in the chat-completions envelope: `{"type": "function", "function":
    /// {name, description, parameters}}`. The generated list is in the realtime socket's shape,
    /// with `type` beside the name, and it used to be nested as it stood — so every server was
    /// handed a `function` with a `type` inside it, which a strict one is entitled to refuse.
    static func chatTools() throws -> [[String: Any]] {
        try VoiceToolCall.toolDefinitions().map { tool in
            var function = tool
            function.removeValue(forKey: "type")
            return ["type": "function", "function": function]
        }
    }

    static func message(in data: Data) -> [String: Any]? {
        guard let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = answer["choices"] as? [[String: Any]] else { return nil }
        return choices.first?["message"] as? [String: Any]
    }

    struct ToolCall {
        let id: String
        let name: String
        let arguments: [String: Any]
    }

    /// Every tool call in a reply, a malformed one included: each has an id the next request must
    /// answer, so one that cannot be read is kept — with no name, which nothing will accept — and
    /// answered with why, rather than left as a hole in the conversation.
    static func toolCalls(in message: [String: Any]) -> [ToolCall] {
        ((message["tool_calls"] as? [[String: Any]]) ?? []).map { call in
            let function = call["function"] as? [String: Any]
            var arguments: [String: Any] = [:]
            if let text = function?["arguments"] as? String,
               let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                arguments = parsed
            } else if let object = function?["arguments"] as? [String: Any] {
                // Ollama sends the arguments as an object rather than as a string of JSON.
                arguments = object
            }
            return ToolCall(
                id: (call["id"] as? String) ?? "",
                name: (function?["name"] as? String) ?? "",
                arguments: arguments)
        }
    }

    static func toolResult(_ id: String, _ content: String) -> [String: Any] {
        ["role": "tool", "tool_call_id": id, "content": content]
    }

    /// What of a reply goes back to the model next turn: its words and its tool calls. Not
    /// `reasoning_content` — Sarvam's thinking, which it would bill a second time for being sent
    /// back — nor anything else a server adds to its own messages.
    static func kept(_ message: [String: Any]) -> [String: Any] {
        var kept: [String: Any] = ["role": "assistant"]
        let content = message["content"] as? String
        if let calls = message["tool_calls"] as? [[String: Any]], !calls.isEmpty {
            kept["tool_calls"] = calls
            // A reply that is only tool calls has no words, and says so with a null.
            if let content { kept["content"] = content } else { kept["content"] = NSNull() }
        } else {
            kept["content"] = content ?? ""
        }
        return kept
    }

    // MARK: When it does not work

    /// A provider's no, as a sentence someone can act on.
    static func refusal(status: Int, body: Data, configuration: SaathiConfiguration) -> any Error {
        switch configuration.resolvedProvider {
        case .sarvam:
            return SarvamError.refusal(status: status, body: body)
        case .local:
            return VoiceError.transport(
                "the local model at \(configuration.resolvedProviderBaseURL) did not answer. "
                + "Is Ollama or LM Studio running? (\(statedReason(in: body)))")
        default:
            return VoiceError.transport(statedReason(in: body))
        }
    }

    /// No answer at all. A cancelled request stays a cancellation: it was dropped on purpose.
    static func unreachable(_ error: any Error, configuration: SaathiConfiguration) -> any Error {
        if error is CancellationError { return error }
        if let url = error as? URLError, url.code == .cancelled { return CancellationError() }
        switch configuration.resolvedProvider {
        case .sarvam:
            return SarvamError.unreachable(error.localizedDescription)
        case .local:
            return VoiceError.transport(
                "the local model at \(configuration.resolvedProviderBaseURL) did not answer. "
                + "Is Ollama or LM Studio running? (\(error.localizedDescription))")
        default:
            return VoiceError.transport(error.localizedDescription)
        }
    }

    /// A server's own words for a refusal — `error.message`, or `error`, or `detail` — and the
    /// body itself, clipped, when it is none of those. A page of JSON is not a sentence.
    static func statedReason(in body: Data) -> String {
        if let answer = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            if let stated = (answer["error"] as? [String: Any])?["message"] as? String { return stated }
            if let stated = answer["error"] as? String { return stated }
            if let stated = answer["detail"] as? String { return stated }
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no response body" : text
    }
}
```

- [ ] **Step 5: The small changes it leans on.**

`VoiceSession.swift` — in the protocol, after `setHandsFree`:

```swift
    /// The learner has started talking over Saathi. Whatever is being said stops, and an answer
    /// still on its way is dropped rather than spoken over them. Called before a turn opens.
    func interrupt()
```

and in the `extension VoiceSession` a default:

```swift
    /// The realtime lane needs nothing here: opening a turn on it already flushes playback and
    /// cancels the response in flight.
    public func interrupt() {}
```

`Speakers.swift` — `public final class ObservedSpeaker: Speaker, @unchecked Sendable {` becomes

```swift
public final class ObservedSpeaker: Speaker, StoppableSpeaker, @unchecked Sendable {
```

`ScreenSight.swift` — after `look(question:)`:

```swift
    /// `look`, with a failure turned into a sentence for the model to repeat. "I need Screen
    /// Recording permission" is a useful thing to be told; silence is not.
    public func answer(_ question: String) async -> String {
        do {
            return try await look(question: question)
        } catch {
            return "could not look: \((error as? ScreenSightError)?.description ?? error.localizedDescription)"
        }
    }
```

`RealtimeVoiceSession.swift` — in `handleToolCall`, the `do`/`catch` that computes `answer` becomes

```swift
                // The model is told what went wrong so it can say something true — "I need
                // Screen Recording permission" is a useful sentence; silence is not.
                let answer = await ScreenSight(configuration: self.configuration).answer(question)
```

`VoiceConductor.swift` — in `keysBegan()`, before `if turns.open()`:

```swift
        // Talking over Saathi stops it, and drops an answer still on its way. Before the turn
        // opens: the begin is queued behind whatever the last turn is still doing, and on the
        // chain lane that is the very reply being talked over.
        if !turns.isOpen { session?.interrupt() }
```

and in `toggleTalk()`, the `else` branch becomes

```swift
            session?.interrupt()
            turns.open(); onEvent(.keysHeld)
```

- [ ] **Step 6: Run to see them pass.**

Run: `swift test --filter "ChainLaneTests|DeviceEarsTests|VoiceConductorTests|VoiceSessionFactoryTests|RealtimeVoiceNameTests"`
Expected: all pass.

- [ ] **Step 7: Check the `/v1` rule against the two servers that can be asked without a key.**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.anthropic.com/chat/completions      # 404
curl -s -o /dev/null -w "%{http_code}\n" -X POST https://api.anthropic.com/v1/chat/completions   # 401: it exists
```

Ollama's own documentation gives `http://localhost:11434/v1/chat/completions`.

- [ ] **Step 8: Commit** — "The chain lane is handed its ears, answers its tool calls, and can be talked over".

---

### Task 6: Sarvam's ears

**Files:**
- Create: `Sources/SaathiKit/SarvamEars.swift`
- Test: `Tests/SaathiKitTests/SarvamEarsTests.swift`

**Interfaces:**
- Consumes: `Ears`, `EarsFeedback` (Task 5); `SarvamClient.transcribe` (Task 4); `WaveFile.wrap` (Task 3); `ConverterBox`, `SharedFrames.peak` (already in `Dictation.swift`); `Permissions`, `InputLevel`.
- Produces: `struct RecordedTurn { var pcm16: Data; var peak: Float; var seconds: Double }`; `protocol TurnRecorder: Sendable { func prepare() async throws; func start(onLevel:) throws; func stop() -> RecordedTurn }`; `final class MicrophoneTurnRecorder: TurnRecorder`; `final class SarvamEars: Ears { init(client: SarvamClient, language: String, recorder: any TurnRecorder = MicrophoneTurnRecorder()) }`, `SarvamEars.sampleRate = 16_000`, `static func pieces(of: Data) -> [Data]`. Test helper `FakeRecorder`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/SarvamEarsTests.swift`:

```swift
//
//  SarvamEarsTests.swift
//  SaathiKitTests
//
//  Sarvam's ears, with a microphone a test controls: what is sent to Saaras for a held turn, what
//  is never sent at all, and what a long turn becomes. The real microphone is one small class
//  behind `TurnRecorder`; nothing here opens it.
//

import AVFoundation
import Foundation
import XCTest
@testable import SaathiKit

/// A microphone that "records" whatever a test hands it.
final class FakeRecorder: TurnRecorder, @unchecked Sendable {
    let calls = Collected<String>()
    private let turn: RecordedTurn
    private let refusal: (any Error)?

    init(recording turn: RecordedTurn = RecordedTurn(), refusing refusal: (any Error)? = nil) {
        self.turn = turn
        self.refusal = refusal
    }

    /// `seconds` of something at `peak`, as PCM16 at Saaras's rate.
    static func turn(seconds: Double, peak: Float = 0.3) -> RecordedTurn {
        let samples = Int(seconds * SarvamEars.sampleRate)
        return RecordedTurn(pcm16: Data(repeating: 3, count: samples * 2), peak: peak)
    }

    func prepare() async throws {
        calls.add("prepare")
        if let refusal { throw refusal }
    }

    func start(onLevel: (@Sendable (Float) -> Void)?) throws {
        calls.add("start")
        onLevel?(0.4)
    }

    func stop() -> RecordedTurn {
        calls.add("stop")
        return turn
    }
}

final class SarvamEarsTests: XCTestCase {

    private func makeEars(_ recorder: FakeRecorder, _ replies: StubHTTP.Reply...) -> SarvamEars {
        SarvamEars(
            client: SarvamClient(key: "sk-sarvam", urlSession: StubHTTP.session(replies)),
            language: "ml-IN", recorder: recorder)
    }

    func testAHeldTurnGoesToSaarasAsAWavInTheLanguageOfSettings() async throws {
        let recorder = FakeRecorder(recording: FakeRecorder.turn(seconds: 2))
        let ears = makeEars(recorder, .json(["transcript": "എന്താണ് ഇത്", "language_code": "ml-IN"]))
        let levels = Collected<Float>()

        let ready = try await ears.prepare()
        try await ears.begin(EarsFeedback(onLevel: { levels.add($0) }))
        let heard = try await ears.finish()

        XCTAssertEqual(ready, "ready — Sarvam hears you (ml-IN)")
        XCTAssertEqual(heard, "എന്താണ് ഇത്")
        XCTAssertEqual(recorder.calls.all, ["prepare", "start", "stop"])
        XCTAssertEqual(levels.all, [0.4], "the bars still move: the level comes from the microphone, not from Sarvam")

        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(StubHTTP.seen.count, 1)
        XCTAssertEqual(seen.request.url?.path, "/speech-to-text")
        XCTAssertNotNil(seen.body.range(of: Data("name=\"language_code\"\r\n\r\nml-IN\r\n".utf8)))
        let wav = WaveFile.wrap(pcm16: FakeRecorder.turn(seconds: 2).pcm16, sampleRate: 16_000)
        XCTAssertNotNil(seen.body.range(of: wav), "the turn, as a 16 kHz WAV")
    }

    /// The keys tapped, not held. Nothing worth sending, and nothing is sent.
    func testATapOfTheKeysIsNotSentAnywhere() async throws {
        let ears = makeEars(FakeRecorder(recording: FakeRecorder.turn(seconds: 0.1)), .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        let heard = try await ears.finish()
        XCTAssertEqual(heard, "")
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    /// A microphone that gave nothing is a different problem from speech that was not understood,
    /// and saying which is the difference between trying again and looking at Sound settings.
    /// Saaras is not asked to transcribe silence, and the learner's silence is not sent to it.
    func testAMicrophoneThatGaveNothingSaysSoInsteadOfAskingSaaras() async throws {
        let silent = FakeRecorder(recording: FakeRecorder.turn(seconds: 2, peak: 0.004))
        let ears = makeEars(silent, .json(["transcript": "never asked"]))
        try await ears.begin(EarsFeedback())
        do {
            _ = try await ears.finish()
            XCTFail("two seconds of nothing is not a turn")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("microphone gave no sound"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("quit and reopen"), error.localizedDescription)
        }
        XCTAssertTrue(StubHTTP.seen.isEmpty)
    }

    /// Saaras takes thirty seconds a request. A longer turn goes up in pieces rather than being
    /// refused whole.
    func testALongTurnGoesUpInPiecesAndComesBackAsOneSentence() async throws {
        let long = FakeRecorder.turn(seconds: 65)
        let ears = makeEars(
            FakeRecorder(recording: long),
            .json(["transcript": "one"]), .json(["transcript": ""]), .json(["transcript": "three"]))
        try await ears.begin(EarsFeedback())
        let heard = try await ears.finish()

        XCTAssertEqual(heard, "one three", "a piece with nothing in it adds nothing")
        XCTAssertEqual(StubHTTP.seen.count, 3)

        let pieces = SarvamEars.pieces(of: long.pcm16)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces.map(\.count).reduce(0, +), long.pcm16.count, "nothing is lost at the cuts")
        for piece in pieces {
            XCTAssertLessThanOrEqual(Double(piece.count / 2) / 16_000, 28)
            XCTAssertEqual(piece.count % 2, 0, "cut on a sample, never through one")
        }
        XCTAssertEqual(SarvamEars.pieces(of: FakeRecorder.turn(seconds: 5).pcm16).count, 1)
        XCTAssertTrue(SarvamEars.pieces(of: Data()).isEmpty)
    }

    func testSaarasRefusingIsTheRefusalItGave() async throws {
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "invalid_api_key_error"]], status: 403)
        let ears = makeEars(FakeRecorder(recording: FakeRecorder.turn(seconds: 2)), refused)
        try await ears.begin(EarsFeedback())
        do {
            _ = try await ears.finish()
            XCTFail("a refused key is not a turn in which nothing was said")
        } catch {
            XCTAssertEqual(error as? SarvamError, .keyRefused)
        }
    }

    func testARefusedMicrophoneStopsTheSessionBeforeItStarts() async {
        let denied = VoiceError.notConfigured("Saathi needs the microphone to hear you.")
        let ears = makeEars(FakeRecorder(refusing: denied), .json([:]))
        do {
            _ = try await ears.prepare()
            XCTFail("no microphone, no ears")
        } catch {
            XCTAssertEqual(error as? VoiceError, denied)
        }
    }

    func testCancellingLetsGoOfTheMicrophone() {
        let recorder = FakeRecorder()
        makeEars(recorder, .json([:])).cancel()
        XCTAssertEqual(recorder.calls.all, ["stop"])
    }

    func testARecordedTurnKnowsHowLongItIs() {
        XCTAssertEqual(FakeRecorder.turn(seconds: 2).seconds, 2, accuracy: 0.001)
        XCTAssertEqual(RecordedTurn().seconds, 0)
    }

    // MARK: the one step between the microphone and Saaras that can be tested without either

    /// A tap buffer as it arrives from a microphone — 48 kHz, float, more than one channel — comes
    /// out as PCM16 mono at 16 kHz. No audio hardware: the buffer is made by hand.
    func testATapBufferBecomesPCM16MonoAtSixteenKilohertz() throws {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: mono, to: MicrophoneTurnRecorder.format))

        var samples = 0
        var loudest: Int16 = 0
        for chunk in 0..<10 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_800))
            buffer.frameLength = 4_800
            let left = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<4_800 {
                left[index] = Float(sin(Double(chunk * 4_800 + index) * 2 * .pi * 440 / 48_000)) * 0.5
            }
            let pcm = MicrophoneTurnRecorder.convert(buffer, mono: mono, with: converter)
            XCTAssertEqual(pcm.count % 2, 0)
            samples += pcm.count / 2
            pcm.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) { loudest = max(loudest, abs(sample)) }
            }
        }
        XCTAssertEqual(Double(samples), 16_000, accuracy: 200, "a second in is a second out, at a third of the rate")
        XCTAssertGreaterThan(loudest, 12_000, "half scale in is about half scale out: the first channel, not silence")
        XCTAssertLessThan(loudest, 20_000)
    }

    func testAnEmptyBufferConvertsToNothing() throws {
        let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: mono, to: MicrophoneTurnRecorder.format))
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 16))
        XCTAssertTrue(MicrophoneTurnRecorder.convert(empty, mono: mono, with: converter).isEmpty)
    }
}
```

- [ ] **Step 2: Run to see them fail.** `swift build --build-tests` → `cannot find type 'TurnRecorder' in scope`.

- [ ] **Step 3: Implement.** Create `Sources/SaathiKit/SarvamEars.swift`:

```swift
//
//  SarvamEars.swift
//  SaathiKit
//
//  Sarvam's ears: a held turn is recorded, and Saaras is asked what was said.
//
//  This is the one place a learner's voice leaves the machine on the chain lane, and it happens
//  only when the configuration asks for it (`speech: sarvam`). `VoiceLaneReport` says so in words.
//  It exists because there is no other way to be heard in most Indian languages: Apple's
//  recogniser does not have them.
//
//  Nothing is sent while the keys are held. The turn is recorded here, and goes up as one WAV when
//  they are let go — which is also why no words appear as they are said.
//

@preconcurrency import AVFoundation
import Foundation
import os

/// What the microphone gave for one turn.
public struct RecordedTurn: Equatable, Sendable {
    /// PCM16, mono, little-endian, at `SarvamEars.sampleRate`.
    public var pcm16: Data
    /// The loudest moment, 0…1. A turn that never rose above a whisper was a closed microphone.
    public var peak: Float

    public init(pcm16: Data = Data(), peak: Float = 0) {
        self.pcm16 = pcm16
        self.peak = peak
    }

    public var seconds: Double {
        Double(pcm16.count / MemoryLayout<Int16>.size) / SarvamEars.sampleRate
    }
}

/// The microphone, for one held turn. A protocol so the ears can be tested with no microphone.
public protocol TurnRecorder: Sendable {
    /// Asks for the microphone if nobody has yet. Throws when the answer is no.
    func prepare() async throws
    func start(onLevel: (@Sendable (Float) -> Void)?) throws
    /// Stops, and hands over what was recorded. Empty when nothing was being recorded.
    func stop() -> RecordedTurn
}

/// A plain `AVAudioEngine`, as the on-device ears use — not the realtime lane's voice-processing
/// one. An engine opened beside a live voice-processing engine records silence; by the time this
/// one opens, a realtime session that ran earlier has been torn down, which should be enough and
/// has not been tried. `SarvamEars` says so out loud if a turn comes back silent.
public final class MicrophoneTurnRecorder: TurnRecorder, @unchecked Sendable {

    static let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: SarvamEars.sampleRate, channels: 1, interleaved: true)!

    private struct State {
        var engine: AVAudioEngine?
        var pcm16 = Data()
        var peak: Float = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func prepare() async throws {
        if Permissions.status(of: .microphone) == .granted { return }
        guard await Permissions.request(.microphone) == .granted else {
            throw VoiceError.notConfigured(
                "Saathi needs the microphone to hear you. Grant it in System Settings → Privacy & Security → Microphone.")
        }
    }

    public func start(onLevel: (@Sendable (Float) -> Void)?) throws {
        _ = stop()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else {
            throw VoiceError.audio("no microphone input available")
        }
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: mono, to: Self.format) else {
            throw VoiceError.audio("cannot convert \(hardware) to PCM16 at 16 kHz")
        }
        let box = ConverterBox(converter)

        input.installTap(onBus: 0, bufferSize: 2400, format: hardware) { [weak self] buffer, _ in
            let peak = SharedFrames.peak(buffer)
            let samples = Self.convert(buffer, mono: mono, with: box.converter)
            self?.state.withLock { state in
                state.pcm16.append(samples)
                state.peak = max(state.peak, peak)
            }
            onLevel?(InputLevel.level(of: buffer))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        state.withLock { $0.engine = engine }
    }

    public func stop() -> RecordedTurn {
        // The tap comes off before the samples are taken, so the last buffer is in them.
        let engine = state.withLock { $0.engine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        return state.withLock { state in
            defer { state = State() }
            return RecordedTurn(pcm16: state.pcm16, peak: state.peak)
        }
    }

    /// One tap buffer as PCM16 mono at 16 kHz. The first channel only: a multi-channel input handed
    /// to `AVAudioConverter` for a downmix comes out as silence, which is the bug the realtime
    /// engine already found. Not `private`, so it can be tested with a buffer made by hand.
    static func convert(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat, with converter: AVAudioConverter) -> Data {
        guard buffer.frameLength > 0, let source = buffer.floatChannelData?[0],
              let single = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let target = single.floatChannelData?[0] else { return Data() }
        target.update(from: source, count: Int(buffer.frameLength))
        single.frameLength = buffer.frameLength

        let ratio = format.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return Data() }
        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return single
        }
        guard error == nil, converted.frameLength > 0, let channel = converted.int16ChannelData else { return Data() }
        return Data(bytes: channel[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
    }
}

public final class SarvamEars: Ears, @unchecked Sendable {

    /// What Saaras asks for.
    public static let sampleRate: Double = 16_000
    /// Under this a turn was the keys being tapped, not a sentence.
    static let shortestTurn: TimeInterval = 0.3
    /// Under this the microphone gave nothing: the same line Dictate draws.
    static let silence: Float = 0.02
    /// Saaras takes thirty seconds a request; a longer turn goes up in pieces this long.
    static let longestPiece: TimeInterval = 28

    private let client: SarvamClient
    private let language: String
    private let recorder: any TurnRecorder

    /// `language`: Sarvam's code for it, "ml-IN".
    public init(client: SarvamClient, language: String, recorder: any TurnRecorder = MicrophoneTurnRecorder()) {
        self.client = client
        self.language = language
        self.recorder = recorder
    }

    public func prepare() async throws -> String {
        try await recorder.prepare()
        return "ready — Sarvam hears you (\(language))"
    }

    public func begin(_ feedback: EarsFeedback) async throws {
        try recorder.start(onLevel: feedback.onLevel)
    }

    public func finish() async throws -> String {
        let turn = recorder.stop()
        guard turn.seconds >= Self.shortestTurn else { return "" }
        // Not sent: Saaras would be asked to transcribe silence, and the person would be told it
        // did not catch that, when the truth is that nothing reached it.
        guard turn.peak >= Self.silence else {
            throw VoiceError.audio(
                "the microphone gave no sound. Check the input in Sound settings — and if Saathi has "
                + "only just switched to Sarvam, quit and reopen it.")
        }

        var heard: [String] = []
        for piece in Self.pieces(of: turn.pcm16) {
            let wav = WaveFile.wrap(pcm16: piece, sampleRate: Int(Self.sampleRate))
            let text = try await client.transcribe(wav: wav, language: language)
            if !text.isEmpty { heard.append(text) }
        }
        return heard.joined(separator: " ")
    }

    public func cancel() {
        _ = recorder.stop()
    }

    /// A turn cut into pieces Saaras will take. Cut on a sample, never through one; a word that
    /// straddles a cut may be heard badly, which is better than a long turn being refused whole.
    static func pieces(of pcm16: Data) -> [Data] {
        let longest = Int(longestPiece * sampleRate) * MemoryLayout<Int16>.size
        guard pcm16.count > longest else { return pcm16.isEmpty ? [] : [pcm16] }
        var pieces: [Data] = []
        var start = pcm16.startIndex
        while start < pcm16.endIndex {
            let end = min(start + longest, pcm16.endIndex)
            pieces.append(pcm16.subdata(in: start..<end))
            start = end
        }
        return pieces
    }
}
```

- [ ] **Step 4: Run to see them pass.** `swift test --filter SarvamEarsTests`.

- [ ] **Step 5: Commit** — "Sarvam's ears: a held turn is recorded and Saaras is asked what was said".

---

### Task 7: Sarvam's mouth, and the one voice that chooses

**Files:**
- Create: `Sources/SaathiKit/SarvamSpeaker.swift`, `Sources/SaathiKit/CompanionVoice.swift`
- Modify: `Sources/SaathiKit/Speakers.swift` (`installedVoiceLanguages` is public; `SpeechSettings.hasVoice`)
- Test: `Tests/SaathiKitTests/SarvamSpeakerTests.swift`

**Interfaces:**
- Consumes: `SarvamClient.synthesize`, `.speakers`, `.defaultSpeaker` (Task 4); `SarvamLanguage` (Task 3); `SpeechSettings.spokenLanguage`, `.rateMultiplier`; `SerialTaskQueue`; `SaathiConfiguration.resolvedSpeech` (Task 1).
- Produces:
  - `protocol AudioOutput: Sendable { func play(_ wav: Data) async throws; func stop() }`, `final class PlayerAudioOutput: AudioOutput`
  - `final class SarvamSpeaker: Speaker, StoppableSpeaker { struct Voice { language, speaker, pace }; typealias Fallback = @Sendable (String, Tone, String) async -> Void; init(client:voice:output:fallback:) }`, `static func code(for:in:) -> String`, `static func pieces(of:limit:) -> [String]`
  - `protocol DeviceVoice: Speaker, StoppableSpeaker { func apply(_ settings: SpeechSettings) }` (`SystemSpeaker` conforms)
  - `enum SarvamSpeech { static func isOn(_:) -> Bool; struct Settings { key, language, speaker }; static func settings(for:) throws -> Settings; static func speaker(named:) -> String }`
  - `final class CompanionVoice: Speaker, StoppableSpeaker { init(configuration:device:output:urlSession:installedVoices:); func apply(_:scripted:); static func deviceSettings(for:scripted:) -> SpeechSettings; var speaksThroughSarvam: Bool; func reportFailures(to:) }`
  - `SpeechSettings.hasVoice(for:available:) -> Bool`
  - Test helpers `FakeOutput`, `FakeDeviceVoice`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/SarvamSpeakerTests.swift`:

```swift
//
//  SarvamSpeakerTests.swift
//  SaathiKitTests
//
//  Sarvam's mouth, and the one voice that chooses between it and this Mac's. Nothing here makes a
//  sound: the player is a fake that writes down what it was handed, and the system voice is one
//  that writes down what it was asked to say.
//

import Foundation
import os
import XCTest
@testable import SaathiContract
@testable import SaathiKit

/// Writes down the clips it was asked to play. Can be told to wait, for tests about being stopped.
final class FakeOutput: AudioOutput, @unchecked Sendable {
    let played = Collected<Data>()
    let stops = Collected<Bool>()
    private let waits: Bool
    private let waiting = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    init(waits: Bool = false) { self.waits = waits }

    func play(_ wav: Data) async throws {
        played.add(wav)
        guard waits else { return }
        await withCheckedContinuation { continuation in
            waiting.withLock { $0 = continuation }
        }
    }

    func stop() {
        stops.add(true)
        let continuation = waiting.withLock { waiting -> CheckedContinuation<Void, Never>? in
            defer { waiting = nil }
            return waiting
        }
        continuation?.resume()
    }
}

/// This Mac's voice, as a test sees it: what it was told, what it said, and that it was stopped.
final class FakeDeviceVoice: DeviceVoice, @unchecked Sendable {
    let log = Collected<String>()
    let settings = Collected<SpeechSettings>()

    func apply(_ settings: SpeechSettings) { self.settings.add(settings) }
    func speak(_ text: String, tone: Tone) async { log.add("say: \(text)") }
    func stop() { log.add("stop") }

    var said: [String] { log.all.filter { $0.hasPrefix("say: ") }.map { String($0.dropFirst(5)) } }
}

final class SarvamSpeakerTests: XCTestCase {

    private let clip = WaveFile.wrap(pcm16: Data(repeating: 1, count: 64), sampleRate: 24_000)

    private var audio: StubHTTP.Reply { .json(["audios": [clip.base64EncodedString()]]) }

    private func speaker(
        _ replies: [StubHTTP.Reply],
        voice: SarvamSpeaker.Voice = SarvamSpeaker.Voice(language: "ml"),
        output: FakeOutput = FakeOutput(),
        fallback: @escaping SarvamSpeaker.Fallback = { _, _, _ in }
    ) -> SarvamSpeaker {
        SarvamSpeaker(
            client: SarvamClient(key: "sk-sarvam", urlSession: StubHTTP.session(replies)),
            voice: voice, output: output, fallback: fallback)
    }

    func testALineIsAskedOfBulbulAndPlayed() async throws {
        let output = FakeOutput()
        let sarvam = speaker([audio], voice: SarvamSpeaker.Voice(language: "ml", speaker: "ishita"), output: output)

        await sarvam.speak("നമസ്കാരം, ഞാൻ സഹായിക്കാം.", tone: .neutral)

        XCTAssertEqual(output.played.all, [clip])
        let seen = try XCTUnwrap(StubHTTP.seen.first)
        XCTAssertEqual(seen.json["text"] as? String, "നമസ്കാരം, ഞാൻ സഹായിക്കാം.")
        XCTAssertEqual(seen.json["language_code"] as? String, "ml-IN")
        XCTAssertEqual(seen.json["speaker"] as? String, "ishita")
        XCTAssertNil(seen.json["pace"])
    }

    /// Saathi's own fixed sentences are English. Bulbul is told so, as the system voice is, so that
    /// "I did not catch that" is read as English rather than normalised as Malayalam.
    func testALineIsSpokenInTheLanguageItIsWrittenIn() {
        XCTAssertEqual(SarvamSpeaker.code(for: "I did not catch that. Say it once more?", in: "ml"), "en-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "നമസ്കാരം, ഞാൻ സഹായിക്കാം.", in: "ml"), "ml-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "मैंने वह नहीं सुना। एक बार फिर कहिए।", in: "hi-IN"), "hi-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "Hello there, how can I help?", in: "en"), "en-IN")
        XCTAssertEqual(SarvamSpeaker.code(for: "OK", in: "ta"), "ta-IN", "too short to tell: the language of Settings")
    }

    /// Calm is a little slower, and a learner who asked for slow gets slower again — the same two
    /// numbers the system voice uses, sent as Bulbul's `pace`.
    func testTheToneAndThePaceAskedForReachBulbul() async throws {
        let sarvam = speaker([audio], voice: SarvamSpeaker.Voice(language: "hi", pace: .slow))
        await sarvam.speak("ठीक है, धीरे-धीरे चलते हैं।", tone: .calm)
        let pace = try XCTUnwrap(StubHTTP.seen.first?.json["pace"] as? Double)
        XCTAssertEqual(pace, 0.76, accuracy: 0.011)

        let ordinary = speaker([audio], voice: SarvamSpeaker.Voice(language: "hi"))
        await ordinary.speak("ठीक है।", tone: .neutral)
        XCTAssertNil(StubHTTP.seen.first?.json["pace"])
    }

    /// Bulbul takes 2500 characters. A reply is a sentence or two; this is for the one that is not.
    func testALongReplyIsCutWhereAListenerWouldBreathe() async throws {
        let sentence = "This is one sentence of a very long reply that goes on. "
        let long = String(repeating: sentence, count: 110)   // about 6,000 characters
        let pieces = SarvamSpeaker.pieces(of: long)

        XCTAssertGreaterThanOrEqual(pieces.count, 3)
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, SarvamClient.longestUtterance)
            XCTAssertTrue(piece.hasSuffix("goes on."), "cut at the end of a sentence, not through one")
        }
        XCTAssertEqual(
            pieces.joined(separator: " "), long.trimmingCharacters(in: .whitespaces),
            "every word is still there, in order")

        let output = FakeOutput()
        let sarvam = speaker([audio], voice: SarvamSpeaker.Voice(language: "en"), output: output)
        await sarvam.speak(long, tone: .neutral)
        XCTAssertEqual(StubHTTP.seen.count, pieces.count)
        XCTAssertEqual(output.played.all.count, pieces.count)
    }

    func testPiecesOfOrdinaryAndAwkwardText() {
        XCTAssertEqual(SarvamSpeaker.pieces(of: "  One short line.  "), ["One short line."])
        XCTAssertTrue(SarvamSpeaker.pieces(of: "   ").isEmpty)
        // One sentence longer than a request: cut at spaces.
        let run = String(repeating: "word ", count: 700)
        let cut = SarvamSpeaker.pieces(of: run, limit: 1_000)
        XCTAssertGreaterThan(cut.count, 1)
        XCTAssertTrue(cut.allSatisfy { $0.count <= 1_000 && !$0.hasPrefix(" ") && !$0.contains("wo rd") })
        XCTAssertEqual(cut.joined(separator: " "), run.trimmingCharacters(in: .whitespaces))
        // And a run with nowhere to cut at all is cut where the limit falls rather than refused.
        let solid = String(repeating: "x", count: 2_500)
        let chunks = SarvamSpeaker.pieces(of: solid, limit: 1_000)
        XCTAssertEqual(chunks.map(\.count), [1_000, 1_000, 500])
    }

    /// Going silent is the worse failure for someone who cannot see why.
    func testWhenBulbulCannotBeReachedTheLineGoesToTheFallbackWithTheReason() async {
        let handed = Collected<String>()
        let output = FakeOutput()
        let sarvam = speaker([.failing()], output: output, fallback: { text, tone, reason in
            handed.add("\(text) | \(tone.rawValue) | \(reason)")
        })

        await sarvam.speak("നമസ്കാരം.", tone: .calm)

        XCTAssertTrue(output.played.all.isEmpty)
        XCTAssertEqual(handed.all.count, 1)
        XCTAssertTrue(handed.all[0].hasPrefix("നമസ്കാരം. | calm | Could not reach Sarvam"), handed.all[0])
    }

    func testARefusalGoesToTheFallbackInSarvamsOwnSentence() async {
        let reasons = Collected<String>()
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "insufficient_quota_error"]], status: 429)
        let sarvam = speaker([refused], fallback: { _, _, reason in reasons.add(reason) })
        await sarvam.speak("नमस्ते।", tone: .neutral)
        XCTAssertEqual(reasons.all, [SarvamError.outOfCredits.localizedDescription])
    }

    /// Cut off on purpose is not a failure to speak: nothing goes to the fallback, and the rest of
    /// a long line is not asked for.
    func testStoppingCutsTheLineAndSaysNoMore() async throws {
        let output = FakeOutput(waits: true)
        let fellBack = Collected<String>()
        let long = String(repeating: "A sentence that is part of a long reply. ", count: 150)
        let sarvam = speaker(
            [audio], voice: SarvamSpeaker.Voice(language: "en"), output: output,
            fallback: { text, _, _ in fellBack.add(text) })

        let speaking = Task { await sarvam.speak(long, tone: .neutral) }
        for _ in 0..<400 where output.played.all.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(output.played.all.count, 1, "the first piece is playing")

        sarvam.stop()
        await speaking.value

        XCTAssertEqual(StubHTTP.seen.count, 1, "the second piece was never asked for")
        XCTAssertEqual(output.stops.all.count, 1)
        XCTAssertTrue(fellBack.all.isEmpty)
    }
}

final class SarvamSpeechTests: XCTestCase {

    func testSarvamsSpeechIsOnlyOnWhenItWasAskedForAndOnlyOnTheChainLane() {
        XCTAssertFalse(SarvamSpeech.isOn(SaathiConfiguration(provider: .sarvam, sarvamKey: "k")), "asked for, not assumed")
        XCTAssertTrue(SarvamSpeech.isOn(SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam)))
        XCTAssertTrue(SarvamSpeech.isOn(SaathiConfiguration(sarvamKey: "k", speech: .sarvam)), "a local model can have Sarvam's ears")
        XCTAssertFalse(SarvamSpeech.isOn(SaathiConfiguration(provider: .openai, openaiKey: "k", speech: .sarvam)), "the realtime lane carries its own")
        XCTAssertFalse(SarvamSpeech.isOn(SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .device)))
    }

    func testTheSettingsAreTheKeyTheLanguageInSarvamsSpellingAndTheVoice() throws {
        let settings = try SarvamSpeech.settings(for: SaathiConfiguration(
            provider: .sarvam, sarvamKey: " sk-sarvam ", voice: "Ishita", speech: .sarvam, language: "ml"))
        XCTAssertEqual(settings, SarvamSpeech.Settings(key: "sk-sarvam", language: "ml-IN", speaker: "ishita"))

        let plain = try SarvamSpeech.settings(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam))
        XCTAssertEqual(plain.language, "en-IN", "English until a language is chosen")
        XCTAssertEqual(plain.speaker, "shubh")
    }

    func testTheLegacySharedKeyStillServesAConfigThatNamesSarvam() throws {
        let legacy = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy", speech: .sarvam)
        XCTAssertEqual(try SarvamSpeech.settings(for: legacy).key, "sk-legacy")
    }

    func testNoKeyIsSaidNotWorkedAround() {
        XCTAssertThrowsError(try SarvamSpeech.settings(for: SaathiConfiguration(speech: .sarvam))) { error in
            XCTAssertTrue(error.localizedDescription.contains("needs a Sarvam key"), error.localizedDescription)
        }
    }

    /// French with Sarvam's speech does not quietly listen on this Mac instead.
    func testALanguageSarvamDoesNotSpeakIsARefusalThatNamesIt() {
        let french = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "fr")
        XCTAssertThrowsError(try SarvamSpeech.settings(for: french)) { error in
            XCTAssertTrue(error.localizedDescription.contains("French is not one of them"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Choose another language"), error.localizedDescription)
        }
    }

    /// A realtime voice left behind by another provider, or a typo, would fail every sentence.
    func testAVoiceBulbulDoesNotHaveIsNotSent() {
        XCTAssertEqual(SarvamSpeech.speaker(named: "cedar"), "shubh")
        XCTAssertEqual(SarvamSpeech.speaker(named: "  PRIYA "), "priya")
        XCTAssertEqual(SarvamSpeech.speaker(named: nil), "shubh")
        XCTAssertEqual(SarvamSpeech.speaker(named: ""), "shubh")
        XCTAssertTrue(SarvamClient.speakers.contains(SarvamClient.defaultSpeaker))
    }
}

final class CompanionVoiceTests: XCTestCase {

    private let malayalam = SaathiConfiguration(
        provider: .sarvam, sarvamKey: "sk-sarvam", speech: .sarvam, language: "ml", pace: .slow)
    private let clip = WaveFile.wrap(pcm16: Data(repeating: 1, count: 64), sampleRate: 24_000)

    private func voice(
        _ configuration: SaathiConfiguration,
        device: FakeDeviceVoice = FakeDeviceVoice(),
        output: FakeOutput = FakeOutput(),
        replies: [StubHTTP.Reply]? = nil,
        installedVoices: [String] = ["en-US", "hi-IN"]
    ) -> CompanionVoice {
        let audio = StubHTTP.Reply.json(["audios": [clip.base64EncodedString()]])
        return CompanionVoice(
            configuration: configuration, device: device, output: { output },
            urlSession: StubHTTP.session(replies ?? [audio]), installedVoices: installedVoices)
    }

    func testTheVoiceIsThisMacsUntilSarvamsIsAskedFor() async {
        let device = FakeDeviceVoice()
        let onDevice = voice(SaathiConfiguration(provider: .sarvam, sarvamKey: "k", language: "hi"), device: device)
        XCTAssertFalse(onDevice.speaksThroughSarvam)

        await onDevice.speak("नमस्ते।", tone: .neutral)
        XCTAssertEqual(device.said, ["नमस्ते।"])
        XCTAssertTrue(StubHTTP.seen.isEmpty, "nothing is sent to Sarvam that was not asked to be")
        XCTAssertEqual(device.settings.all.last, SpeechSettings(language: "hi", pace: nil), "and it is told the language to read in")
    }

    func testWithSarvamsSpeechEveryLineIsSarvams() async throws {
        let device = FakeDeviceVoice()
        let output = FakeOutput()
        let sarvam = voice(malayalam, device: device, output: output)
        XCTAssertTrue(sarvam.speaksThroughSarvam)

        await sarvam.speak("നമസ്കാരം.", tone: .neutral)

        XCTAssertEqual(output.played.all, [clip])
        XCTAssertTrue(device.said.isEmpty)
        let asked = try XCTUnwrap(StubHTTP.seen.first?.json)
        XCTAssertEqual(asked["language_code"] as? String, "ml-IN")
        XCTAssertNotNil(asked["pace"], "slow was asked for in first run, and Bulbul is told")
    }

    /// First run's lines are English, and are read by this Mac's English voice whatever has been
    /// configured — before anything has been said about where a voice might go.
    func testFirstRunIsAlwaysThisMacsEnglishVoice() async {
        let device = FakeDeviceVoice()
        let scripted = voice(malayalam, device: device)
        scripted.apply(malayalam, scripted: true)
        XCTAssertFalse(scripted.speaksThroughSarvam)
        XCTAssertEqual(device.settings.all.last, SpeechSettings(language: "en-US", pace: .slow), "the pace still follows at once")

        scripted.apply(malayalam)
        XCTAssertTrue(scripted.speaksThroughSarvam, "and afterwards it is whatever was chosen")
        XCTAssertEqual(CompanionVoice.deviceSettings(for: malayalam, scripted: false), SpeechSettings(language: "ml", pace: .slow))
    }

    func testAConfigurationSarvamCannotSpeakForFallsToThisMacsVoiceSoTheReasonCanBeSaid() {
        let french = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "fr")
        XCTAssertFalse(voice(french).speaksThroughSarvam)
        XCTAssertFalse(voice(SaathiConfiguration(speech: .sarvam)).speaksThroughSarvam, "no key")
        XCTAssertFalse(voice(SaathiConfiguration(provider: .openai, openaiKey: "k", speech: .sarvam)).speaksThroughSarvam)
    }

    /// When Bulbul cannot be reached Saathi still makes a sound, and says why where it can be seen.
    func testWhenSarvamCannotSpeakThisMacDoesIfItCanReadTheLanguageAndSaysSoIfItCannot() async {
        let hindi = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "hi")
        let reasons = Collected<String>()

        let device = FakeDeviceVoice()
        let canRead = voice(hindi, device: device, replies: [.failing()], installedVoices: ["en-US", "hi-IN"])
        canRead.reportFailures { reasons.add($0) }
        await canRead.speak("नमस्ते।", tone: .neutral)
        XCTAssertEqual(device.said, ["नमस्ते।"], "this Mac has a Hindi voice: the line itself")

        let other = FakeDeviceVoice()
        let cannotRead = voice(malayalam, device: other, replies: [.failing()], installedVoices: ["en-US", "hi-IN"])
        cannotRead.reportFailures { reasons.add($0) }
        await cannotRead.speak("നമസ്കാരം.", tone: .neutral)
        XCTAssertEqual(other.said, ["I could not reach Sarvam to speak."], "an English voice reading Malayalam script is noise")

        XCTAssertEqual(reasons.all.count, 2)
        XCTAssertTrue(reasons.all.allSatisfy { $0.hasPrefix("Sarvam could not speak: Could not reach Sarvam") }, "\(reasons.all)")
    }

    /// Holding the keys to talk over Saathi must not be answered by the next thing it had queued.
    func testALineAskedForBeforeAStopIsNotSaidAfterIt() async throws {
        let device = FakeDeviceVoice()
        let output = FakeOutput(waits: true)
        let sarvam = voice(malayalam, device: device, output: output)

        let first = Task { await sarvam.speak("ഒന്ന്.", tone: .neutral) }
        for _ in 0..<400 where output.played.all.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let second = Task { await sarvam.speak("രണ്ട്.", tone: .neutral) }
        try await Task.sleep(nanoseconds: 30_000_000)

        sarvam.stop()
        await first.value
        await second.value
        XCTAssertEqual(output.played.all.count, 1, "the queued line was dropped, not played late")
        XCTAssertEqual(device.log.all, ["stop"])

        let third = Task { await sarvam.speak("മൂന്ന്.", tone: .neutral) }
        for _ in 0..<400 where output.played.all.count < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(output.played.all.count, 2, "and a line asked for after the stop is said")
        sarvam.stop()
        await third.value
    }

    func testThisMacCanOnlyReadALanguageItHasAVoiceFor() {
        let installed = ["en-US", "en-IN", "hi-IN", "ta-IN"]
        XCTAssertTrue(SpeechSettings.hasVoice(for: "hi", available: installed))
        XCTAssertTrue(SpeechSettings.hasVoice(for: "TA-in", available: installed))
        XCTAssertFalse(SpeechSettings.hasVoice(for: "ml", available: installed))
        XCTAssertFalse(SpeechSettings.hasVoice(for: "e", available: installed), "a prefix of a code is not the code")
    }
}
```

- [ ] **Step 2: Run to see them fail.** `swift build --build-tests` → `cannot find type 'AudioOutput' in scope`.

- [ ] **Step 3: Implement.** In `Speakers.swift`, `private static let installedVoiceLanguages` becomes

```swift
    /// Asked for once. The list only changes when someone downloads a voice in System Settings,
    /// and a relaunch picking that up is a fair price for not enumerating voices every sentence.
    public static let installedVoiceLanguages = AVSpeechSynthesisVoice.speechVoices().map(\.language)
```

and `SpeechSettings` gains, after `voiceLanguage`:

```swift
    /// Whether this Mac can read a language aloud at all, rather than falling back to English.
    public static func hasVoice(for language: String, available: [String]) -> Bool {
        let code = language.split(separator: "-").first.map { $0.lowercased() } ?? language.lowercased()
        return available.contains { $0.lowercased() == code || $0.lowercased().hasPrefix(code + "-") }
    }
```

Create `Sources/SaathiKit/SarvamSpeaker.swift`:

```swift
//
//  SarvamSpeaker.swift
//  SaathiKit
//
//  Sarvam's mouth: a line is sent to Bulbul and what comes back is played.
//
//  It exists for the same reason as `SarvamEars`. The system has no voice at all for Marathi,
//  Malayalam, Gujarati, Punjabi or Odia, and reads their script with an English one; Bulbul speaks
//  all ten of the Indian languages Saathi can be set to, and English in the same voice.
//
//  What is sent is the text of what Saathi is about to say. That already went to the provider that
//  wrote it, so this adds nothing to what leaves the machine — the ears are the half that does.
//

@preconcurrency import AVFoundation
import Foundation
import os
import SaathiContract

/// Plays one clip and returns when it has been heard — or when it is stopped. A protocol so that
/// no test ever makes a sound.
public protocol AudioOutput: Sendable {
    func play(_ wav: Data) async throws
    func stop()
}

/// `AVAudioPlayer`, one clip at a time.
public final class PlayerAudioOutput: NSObject, AudioOutput, AVAudioPlayerDelegate, @unchecked Sendable {

    private struct State {
        var player: AVAudioPlayer?
        var waiting: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public override init() {
        super.init()
    }

    public func play(_ wav: Data) async throws {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: wav)
        } catch {
            throw VoiceError.audio("what Sarvam sent could not be played (\(error.localizedDescription))")
        }
        player.delegate = self

        await withTaskCancellationHandler {
            guard !Task.isCancelled else { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Started under the lock, so a `stop()` from another thread finds either nothing
                // to stop or a player that is already playing — never one about to start.
                let started = state.withLock { box -> Bool in
                    box.player = player
                    box.waiting = continuation
                    return player.play()
                }
                guard started else { return finish(player) }
                // The delegate is the signal. This is only the backstop: a callback that never
                // comes must not leave Saathi waiting to speak for ever.
                let longest = player.duration + 1
                DispatchQueue.global().asyncAfter(deadline: .now() + longest) { [weak self] in
                    self?.finish(player)
                }
            }
        } onCancel: {
            self.stop()
        }
    }

    public func stop() {
        guard let player = state.withLock({ $0.player }) else { return }
        player.stop()
        finish(player)
    }

    /// Ends the wait for `player`, once. A late call about a clip that has already been replaced
    /// does nothing.
    private func finish(_ player: AVAudioPlayer) {
        let continuation = state.withLock { box -> CheckedContinuation<Void, Never>? in
            guard box.player === player else { return nil }
            defer {
                box.player = nil
                box.waiting = nil
            }
            return box.waiting
        }
        continuation?.resume()
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(player)
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        finish(player)
    }
}

public final class SarvamSpeaker: Speaker, StoppableSpeaker, @unchecked Sendable {

    /// How Sarvam is asked to speak.
    public struct Voice: Equatable, Sendable {
        /// The language in Settings, as Saathi keeps it: "ml", "hi-IN". A line is spoken in this
        /// or in English, whichever it is written in.
        public var language: String
        /// One of Bulbul's speakers.
        public var speaker: String
        public var pace: Pace?

        public init(language: String, speaker: String = SarvamClient.defaultSpeaker, pace: Pace? = nil) {
            self.language = language
            self.speaker = speaker
            self.pace = pace
        }
    }

    /// What is done with a line Bulbul could not say: the rest of the line, its tone, and why.
    public typealias Fallback = @Sendable (_ text: String, _ tone: Tone, _ reason: String) async -> Void

    private let client: SarvamClient
    private let voice: Voice
    private let output: any AudioOutput
    private let fallback: Fallback
    /// Bumped by `stop()`. A line that finds it changed has been cut off and says no more.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    public init(
        client: SarvamClient,
        voice: Voice,
        output: any AudioOutput = PlayerAudioOutput(),
        fallback: @escaping Fallback = { _, _, _ in }
    ) {
        self.client = client
        self.voice = voice
        self.output = output
        self.fallback = fallback
    }

    public func speak(_ text: String, tone: Tone) async {
        let mine = generation.withLock { $0 }
        let pieces = Self.pieces(of: text)
        for (index, piece) in pieces.enumerated() {
            guard isCurrent(mine) else { return }
            do {
                let clips = try await client.synthesize(
                    piece,
                    language: Self.code(for: piece, in: voice.language),
                    speaker: voice.speaker,
                    pace: Double(SpeechSettings.rateMultiplier(tone: tone, pace: voice.pace)))
                for clip in clips {
                    guard isCurrent(mine) else { return }
                    try await output.play(clip)
                }
            } catch {
                // Cut off on purpose is not a failure to speak.
                guard isCurrent(mine), !(error is CancellationError) else { return }
                await fallback(pieces[index...].joined(separator: " "), tone, error.localizedDescription)
                return
            }
        }
    }

    public func stop() {
        generation.withLock { $0 += 1 }
        output.stop()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation.withLock { $0 == generation }
    }

    /// Sarvam's code for the language a line is written in: the one in Settings, or English for
    /// one of Saathi's own English sentences. The same choice the system voice makes, for the same
    /// reason — a Malayalam voice asked to normalise "I did not catch that" is as wrong as the
    /// reverse.
    static func code(for text: String, in language: String) -> String {
        let written = SpeechSettings.spokenLanguage(of: text, wanted: language) ?? language
        return SarvamLanguage.code(for: written) ?? SarvamLanguage.code(for: language) ?? "en-IN"
    }

    /// A long reply cut where a listener would breathe: at the ends of sentences, into pieces
    /// Bulbul will take. A reply is a sentence or two and is nearly always one piece.
    static func pieces(of text: String, limit: Int = SarvamClient.longestUtterance - 100) -> [String] {
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard whole.count > limit else { return whole.isEmpty ? [] : [whole] }

        var pieces: [String] = []
        var current = ""
        func close() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
        }
        whole.enumerateSubstrings(in: whole.startIndex..., options: .bySentences) { sentence, _, _, _ in
            for part in hardSplit(sentence ?? "", limit: limit) {
                if current.count + part.count > limit { close() }
                current += part
            }
        }
        close()
        return pieces
    }

    /// A sentence too long for one request, cut at spaces — and, for a run with no spaces in it,
    /// wherever the limit falls. There is nowhere better.
    private static func hardSplit(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var parts: [String] = []
        var current = ""
        for word in sentence.split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(word) + " "
            while word.count > limit {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                parts.append(String(word.prefix(limit)))
                word = String(word.dropFirst(limit))
            }
            if current.count + word.count > limit {
                parts.append(current)
                current = ""
            }
            current += word
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
```

Create `Sources/SaathiKit/CompanionVoice.swift`:

```swift
//
//  CompanionVoice.swift
//  SaathiKit
//
//  The one voice Saathi speaks with: this Mac's, or Sarvam's when the configuration asks for it.
//
//  Everything that says something out loud — a reply on the chain lane, a `say`, a step's
//  narration, the (i) on the island, first run — goes through one `Speaker`. It used to be the
//  system voice and nothing else. Now it is whichever voice the configuration calls for, chosen in
//  one place, so a Malayalam reply and the "I did not catch that" after it are the same speaker
//  rather than two.
//

import Foundation
import os
import SaathiContract

/// The voice this Mac has: it can be cut off, and told which language to read in and how fast.
public protocol DeviceVoice: Speaker, StoppableSpeaker {
    func apply(_ settings: SpeechSettings)
}

extension SystemSpeaker: DeviceVoice {}

/// What a configuration says about Sarvam's ears and mouth. The one place that reads it.
public enum SarvamSpeech {

    /// Whether a turn is heard and spoken by Sarvam. Only ever on the chain lane: the realtime
    /// lane carries its own speech over its own connection and does not read `speech` at all.
    public static func isOn(_ configuration: SaathiConfiguration) -> Bool {
        configuration.providerRow.voice == .chain && configuration.resolvedSpeech == .sarvam
    }

    public struct Settings: Equatable, Sendable {
        public let key: String
        /// Sarvam's code for the language in Settings: "ml-IN".
        public let language: String
        public let speaker: String
    }

    /// What Sarvam's speech needs from this configuration, or why it cannot be used.
    ///
    /// A reason, never a way round. A language Sarvam does not speak is not quietly listened to on
    /// this Mac instead: that would be the voice going somewhere other than where the report says.
    public static func settings(for configuration: SaathiConfiguration) throws -> Settings {
        guard let key = configuration.credential(for: .sarvam) else {
            throw VoiceError.notConfigured("Sarvam's speech needs a Sarvam key. Add one in Setup.")
        }
        let tag = configuration.resolvedLanguage
        guard let language = SarvamLanguage.code(for: tag) else {
            throw VoiceError.notConfigured(
                "Sarvam hears and speaks ten Indian languages and English, and \(SarvamLanguage.name(of: tag)) "
                + "is not one of them. Choose another language in Setup, or another place for Saathi to think.")
        }
        return Settings(key: key, language: language, speaker: speaker(named: configuration.voice))
    }

    /// The Bulbul voice to ask for: the one named in `shell.json` when Bulbul has it, and its
    /// default otherwise. A name it does not have — a realtime voice left behind by another
    /// provider, a typo — is not sent, because it would fail every sentence.
    public static func speaker(named name: String?) -> String {
        let wanted = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return SarvamClient.speakers.contains(wanted) ? wanted : SarvamClient.defaultSpeaker
    }
}

public final class CompanionVoice: Speaker, StoppableSpeaker, @unchecked Sendable {

    private let device: any DeviceVoice
    private let makeOutput: @Sendable () -> any AudioOutput
    private let urlSession: URLSession
    private let installedVoices: [String]

    private struct State {
        var sarvam: SarvamSpeaker?
        /// Bumped by `stop()`: a line asked for before it is not said after it.
        var generation = 0
        var onFailure: (@Sendable (String) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = SerialTaskQueue()

    public init(
        configuration: SaathiConfiguration,
        device: any DeviceVoice = SystemSpeaker(),
        output: @escaping @Sendable () -> any AudioOutput = { PlayerAudioOutput() },
        urlSession: URLSession = SarvamClient.session,
        installedVoices: [String] = SystemSpeaker.installedVoiceLanguages
    ) {
        self.device = device
        self.makeOutput = output
        self.urlSession = urlSession
        self.installedVoices = installedVoices
        apply(configuration)
    }

    /// Where a failure to speak through Sarvam is reported, in a sentence. Set after the fact
    /// rather than in `init`, because whoever wants to hear about it is usually still being built.
    public func reportFailures(to handler: @escaping @Sendable (String) -> Void) {
        state.withLock { $0.onFailure = handler }
    }

    /// Takes effect from the next line. `scripted` is first run: its lines are written in English
    /// and are read by this Mac's English voice, whatever has been configured.
    public func apply(_ configuration: SaathiConfiguration, scripted: Bool = false) {
        device.apply(Self.deviceSettings(for: configuration, scripted: scripted))
        let sarvam = scripted ? nil : makeSarvam(for: configuration)
        state.withLock { $0.sarvam = sarvam }
    }

    /// What this Mac's voice is told. `scripted` lines are English, so they are read by an English
    /// voice whatever language was just chosen — a Tamil synthesiser reading English sentences is
    /// the same noise as the reverse. The pace still follows at once.
    public static func deviceSettings(for configuration: SaathiConfiguration, scripted: Bool) -> SpeechSettings {
        var settings = SpeechSettings(configuration)
        if scripted { settings.language = "en-US" }
        return settings
    }

    /// Whether the next line would be Sarvam's.
    public var speaksThroughSarvam: Bool {
        state.withLock { $0.sarvam != nil }
    }

    // One line after another, whichever voice says them, and a line asked for before a stop is
    // dropped rather than said after it: holding the keys to talk over Saathi must not be answered
    // by the next thing it had queued up.
    public func speak(_ text: String, tone: Tone) async {
        let asked = state.withLock { $0.generation }
        await queue.run { [self] in
            let (sarvam, current) = state.withLock { ($0.sarvam, $0.generation) }
            guard current == asked else { return }
            if let sarvam {
                await sarvam.speak(text, tone: tone)
            } else {
                await device.speak(text, tone: tone)
            }
        }
    }

    public func stop() {
        let sarvam = state.withLock { state -> SarvamSpeaker? in
            state.generation += 1
            return state.sarvam
        }
        sarvam?.stop()
        device.stop()
    }

    private func makeSarvam(for configuration: SaathiConfiguration) -> SarvamSpeaker? {
        // A configuration Sarvam cannot speak for has already been refused where the session is
        // made, with the reason. This Mac's voice is what is left to say so with.
        guard SarvamSpeech.isOn(configuration),
              let settings = try? SarvamSpeech.settings(for: configuration) else { return nil }

        let language = configuration.resolvedLanguage
        let device = self.device
        let canRead = SpeechSettings.hasVoice(for: language, available: installedVoices)
        return SarvamSpeaker(
            client: SarvamClient(key: settings.key, urlSession: urlSession),
            voice: SarvamSpeaker.Voice(language: language, speaker: settings.speaker, pace: configuration.pace),
            output: makeOutput(),
            fallback: { [weak self] text, tone, reason in
                self?.state.withLock { $0.onFailure }?("Sarvam could not speak: \(reason)")
                // Going silent is the worse failure for someone who cannot see why. The line
                // itself, when this Mac has a voice for the language; one English sentence when it
                // does not, because an English voice reading Malayalam script is noise.
                if canRead {
                    await device.speak(text, tone: tone)
                } else {
                    await device.speak("I could not reach Sarvam to speak.", tone: .calm)
                }
            })
    }
}
```

- [ ] **Step 4: Run to see them pass.** `swift test --filter "SarvamSpeakerTests|SarvamSpeechTests|CompanionVoiceTests"`.

- [ ] **Step 5: Commit** — "Sarvam's mouth, and one voice that is this Mac's until Sarvam's is asked for".

---

### Task 8: The factory chooses the ears, and the reports say where the voice goes

**Files:**
- Modify: `Sources/SaathiKit/VoiceSession.swift` (factory), `Sources/SaathiKit/VoiceLaneReport.swift`, `Sources/SaathiKit/ProviderReport.swift`
- Test: `Tests/SaathiKitTests/VoiceTests.swift`

**Interfaces:**
- Consumes: `SarvamSpeech.isOn`, `.settings(for:)` (Task 7); `SarvamEars`, `SarvamClient` (Tasks 4, 6); `ChainVoiceSession.ears` (Task 5).
- Produces: `VoiceSessionFactory.make` returns a chain session with `SarvamEars` when `speech` is `sarvam`, and throws `VoiceError.notConfigured` when that cannot be honoured. Report wording, verbatim: speech in/out `sarvam, over the network`; your voice `leaves this machine as audio, to Sarvam`.

- [ ] **Step 1: Write the failing tests.** In `VoiceTests.swift`, add to `VoiceLaneTests`:

```swift
    /// With Sarvam's speech the voice does leave, and the report says so and says to whom.
    func testSarvamsSpeechSaysTheVoiceLeavesAndWhereTo() {
        let heardAndSpoken = SaathiConfiguration(provider: .sarvam, sarvamKey: "x", speech: .sarvam)
        let report = VoiceLaneReport.describe(heardAndSpoken)
        XCTAssertTrue(report.contains("lane       chain"))
        XCTAssertTrue(report.contains("speech in  sarvam, over the network"))
        XCTAssertTrue(report.contains("speech out sarvam, over the network"))
        XCTAssertTrue(report.contains("your voice leaves this machine as audio, to Sarvam"))
        XCTAssertFalse(report.contains("stays on this machine"))
    }

    /// A local model with Sarvam's ears: the thinking stays, the voice does not, and neither
    /// report may say otherwise.
    func testALocalModelWithSarvamsEarsIsNotReportedAsStayingOnTheMachine() {
        let mixed = SaathiConfiguration(sarvamKey: "x", speech: .sarvam)
        XCTAssertTrue(VoiceLaneReport.describe(mixed).contains("your voice leaves this machine as audio, to Sarvam"))
        XCTAssertTrue(ProviderReport.describe(mixed).contains("privacy    leaves this machine"))
        XCTAssertTrue(ProviderReport.describe(SaathiConfiguration()).contains("privacy    stays on this machine"))
    }

    /// The realtime lane carries its own speech; `speech` is not read there and changes nothing.
    func testSpeechIsNotReadOnTheRealtimeLane() {
        let plain = VoiceLaneReport.describe(SaathiConfiguration(provider: .openai, openaiKey: "x"))
        let withSpeech = VoiceLaneReport.describe(SaathiConfiguration(provider: .openai, openaiKey: "x", speech: .sarvam))
        XCTAssertEqual(plain, withSpeech)
    }
```

and to `VoiceSessionFactoryTests`:

```swift
    func testSarvamsSpeechGetsSarvamsEarsAndNothingElseDoes() throws {
        let sarvam = try VoiceSessionFactory.make(
            configuration: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "ml"),
            speaker: PrintingSpeaker())
        XCTAssertTrue((sarvam as? ChainVoiceSession)?.ears is SarvamEars)

        let onDevice = try VoiceSessionFactory.make(
            configuration: SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), speaker: PrintingSpeaker())
        XCTAssertTrue((onDevice as? ChainVoiceSession)?.ears is DeviceEars, "asked for, not assumed")
    }

    /// No silent fallback, for speech as for everything else: what was asked for cannot be had, so
    /// the session says why instead of quietly listening on this Mac.
    func testSarvamsSpeechThatCannotBeHadIsRefusedNotWorkedAround() {
        let noKey = SaathiConfiguration(speech: .sarvam)
        XCTAssertThrowsError(try VoiceSessionFactory.make(configuration: noKey, speaker: PrintingSpeaker())) { error in
            XCTAssertTrue(error.localizedDescription.contains("needs a Sarvam key"), error.localizedDescription)
        }
        let french = SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam, language: "fr")
        XCTAssertThrowsError(try VoiceSessionFactory.make(configuration: french, speaker: PrintingSpeaker())) { error in
            XCTAssertTrue(error.localizedDescription.contains("French is not one of them"), error.localizedDescription)
        }
    }
```

- [ ] **Step 2: Run to see them fail.** `swift test --filter "VoiceLaneTests|VoiceSessionFactoryTests"` → the five new ones fail on wording and on `ears is SarvamEars`.

- [ ] **Step 3: Implement.** `VoiceSession.swift`, the `.chain` case of the factory:

```swift
        case .chain:
            guard SarvamSpeech.isOn(configuration) else {
                return ChainVoiceSession(configuration: configuration, speaker: speaker)
            }
            // Asked for, and had — or refused with the reason. Never on-device ears in their
            // place: that would be the voice going somewhere other than where the report says.
            let sarvam = try SarvamSpeech.settings(for: configuration)
            return ChainVoiceSession(
                configuration: configuration, speaker: speaker,
                ears: SarvamEars(client: SarvamClient(key: sarvam.key), language: sarvam.language))
```

`VoiceLaneReport.swift` — `describe` passes the configuration to the three helpers, which become:

```swift
        lines.append("  speech in  \(speechEnd(configuration))")
        lines.append("  thinking   \(model) @ \(configuration.resolvedProviderBaseURL)")
        lines.append("  speech out \(speechEnd(configuration))")
        lines.append("  your voice \(voicePrivacy(configuration))")
```

```swift
    /// In the chain lane both ends are on-device unless Sarvam's were asked for. That is not a
    /// fallback — it is the reason the chain lane is worth having at all — and when it is not so,
    /// this is the line that says it.
    private static func speechEnd(_ configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        if row.voice == .realtime { return "\(row.kind.rawValue), over the open connection" }
        return SarvamSpeech.isOn(configuration) ? "sarvam, over the network" : "on this machine"
    }

    private static func voicePrivacy(_ configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        if row.voice == .realtime { return "leaves this machine as audio" }
        if SarvamSpeech.isOn(configuration) { return "leaves this machine as audio, to Sarvam" }
        if row.sendsDataOffMachine { return "stays on this machine — only the transcript is sent" }
        return "stays on this machine"
    }
```

(`speechIn` and `speechOut` were the same function twice; they are one now.)

`ProviderReport.swift` — the privacy line:

```swift
        lines.append("  privacy    \(leavesMachine(configuration) ? "leaves this machine" : "stays on this machine")")
```

```swift
    /// Whether anything said leaves: the thinking does for every provider but local, and the voice
    /// itself does whenever Sarvam is its ears — even in front of a model on this machine.
    private static func leavesMachine(_ configuration: SaathiConfiguration) -> Bool {
        configuration.providerRow.sendsDataOffMachine || SarvamSpeech.isOn(configuration)
    }
```

- [ ] **Step 4: Run to see them pass.** `swift test --filter "VoiceLaneTests|VoiceSessionFactoryTests|ProviderTests"`.

- [ ] **Step 5: Commit** — "Asked for Sarvam's speech, a session gets Sarvam's ears, and both reports say where the voice goes" (with Task 9: the two clients must change together).

---

### Task 9: The Windows client says the same

**Files:**
- Modify: `windows/src/Saathi.Core/VoiceLaneReport.cs`, `windows/src/Saathi.Core/ProviderReport.cs`, `scripts/check-parity.sh`
- Test: `windows/tests/Saathi.Core.Tests/VoiceLaneTests.cs`, `windows/tests/Saathi.Core.Tests/ProviderTests.cs`

**Interfaces:**
- Consumes: `SaathiConfiguration.ResolvedSpeech` (Task 1).
- Produces: byte-identical reports to Task 8's.

- [ ] **Step 1: Write the failing tests.** `VoiceLaneTests.cs`:

```csharp
    /// <summary>With Sarvam's speech the voice does leave, and the report says so and to whom.</summary>
    [Fact]
    public void SarvamsSpeechSaysTheVoiceLeavesAndWhereTo()
    {
        var report = VoiceLaneReport.Describe(new SaathiConfiguration
        {
            Provider = ProviderKind.Sarvam, SarvamKey = "x", Speech = SpeechEngine.Sarvam,
        });
        Assert.Contains("lane       chain", report);
        Assert.Contains("speech in  sarvam, over the network", report);
        Assert.Contains("speech out sarvam, over the network", report);
        Assert.Contains("your voice leaves this machine as audio, to Sarvam", report);
        Assert.DoesNotContain("stays on this machine", report);
    }

    /// <summary>The realtime lane carries its own speech; Speech is not read there.</summary>
    [Fact]
    public void SpeechIsNotReadOnTheRealtimeLane()
    {
        var plain = VoiceLaneReport.Describe(new SaathiConfiguration { Provider = ProviderKind.Openai, OpenaiKey = "x" });
        var withSpeech = VoiceLaneReport.Describe(new SaathiConfiguration
        {
            Provider = ProviderKind.Openai, OpenaiKey = "x", Speech = SpeechEngine.Sarvam,
        });
        Assert.Equal(plain, withSpeech);
    }
```

`ProviderTests.cs`:

```csharp
    /// <summary>A local model with Sarvam's ears: the thinking stays, the voice does not.</summary>
    [Fact]
    public void ALocalModelWithSarvamsEarsIsNotReportedAsStayingOnTheMachine()
    {
        var mixed = new SaathiConfiguration { SarvamKey = "x", Speech = SpeechEngine.Sarvam };
        Assert.Contains("privacy    leaves this machine", ProviderReport.Describe(mixed), StringComparison.Ordinal);
        Assert.Contains("your voice leaves this machine as audio, to Sarvam", VoiceLaneReport.Describe(mixed), StringComparison.Ordinal);
    }
```

- [ ] **Step 2: Run to see them fail.** `dotnet test windows/Saathi.sln` → 3 failed.

- [ ] **Step 3: Implement.** `VoiceLaneReport.cs` — `Describe` passes `configuration` to the helpers:

```csharp
            $"  speech in  {SpeechEnd(configuration)}",
            $"  thinking   {model} @ {configuration.ResolvedProviderBaseUrl}",
            $"  speech out {SpeechEnd(configuration)}",
            $"  your voice {VoicePrivacy(configuration)}",
```

```csharp
    /// <summary>Whether a turn is heard and spoken by Sarvam. Only ever on the chain lane: the
    /// realtime lane carries its own speech and does not read Speech at all.</summary>
    internal static bool SarvamSpeechIsOn(SaathiConfiguration configuration) =>
        configuration.ProviderRow.Voice == VoiceLane.Chain && configuration.ResolvedSpeech == SpeechEngine.Sarvam;

    /// <summary>In the chain lane both ends are on-device unless Sarvam's were asked for. That is
    /// not a fallback — it is the reason the chain lane is worth having at all — and when it is
    /// not so, this is the line that says it.</summary>
    private static string SpeechEnd(SaathiConfiguration configuration)
    {
        var row = configuration.ProviderRow;
        if (row.Voice == VoiceLane.Realtime) return $"{row.Kind.ToString().ToLowerInvariant()}, over the open connection";
        return SarvamSpeechIsOn(configuration) ? "sarvam, over the network" : "on this machine";
    }

    private static string VoicePrivacy(SaathiConfiguration configuration)
    {
        var row = configuration.ProviderRow;
        if (row.Voice == VoiceLane.Realtime) return "leaves this machine as audio";
        if (SarvamSpeechIsOn(configuration)) return "leaves this machine as audio, to Sarvam";
        if (row.SendsDataOffMachine) return "stays on this machine — only the transcript is sent";
        return "stays on this machine";
    }
```

`ProviderReport.cs` — the privacy line:

```csharp
            $"  privacy    {(LeavesMachine(configuration) ? "leaves this machine" : "stays on this machine")}",
```

```csharp
    /// <summary>Whether anything said leaves: the thinking does for every provider but local, and
    /// the voice itself does whenever Sarvam is its ears — even in front of a model on this machine.</summary>
    private static bool LeavesMachine(SaathiConfiguration configuration) =>
        configuration.ProviderRow.SendsDataOffMachine || VoiceLaneReport.SarvamSpeechIsOn(configuration);
```

`scripts/check-parity.sh` — after the `hosted-signed-out` line, four more configurations:

```bash
printf '%s\n' '{ "provider": "sarvam", "sarvamKey": "not-a-real-key", "speech": "sarvam", "language": "ml" }' > "$CONFIGS/sarvam-heard-and-spoken.json"
printf '%s\n' '{ "provider": "sarvam", "sarvamKey": "not-a-real-key" }' > "$CONFIGS/sarvam-thinking-only.json"
printf '%s\n' '{ "speech": "sarvam", "sarvamKey": "not-a-real-key" }' > "$CONFIGS/this-mac-with-sarvams-ears.json"
printf '%s\n' '{ "provider": "openai", "openaiKey": "not-a-real-key", "speech": "sarvam" }' > "$CONFIGS/realtime-does-not-read-speech.json"
```

- [ ] **Step 4: Run to see them pass, and the two clients agree.** `bash <scratchpad>/ci-local.sh win parity` → `✓ win`, `✓ parity — 24 agree, 0 disagree`.

- [ ] **Step 5: Commit** (Tasks 8 and 9 together).

---

### Task 10: Setup — a Sarvam row, a plan over three vendors, a picker and a switch

**Files:**
- Rewrite: `Sources/SaathiKit/SetupPlan.swift`
- Create: `Sources/SaathiShell/AppController+Setup.swift`
- Modify: `Sources/SaathiShell/AppController+Wording.swift`, `Sources/SaathiShell/IslandModel.swift`, `Sources/SaathiShell/IslandSetupView.swift`, `Sources/SaathiShell/AppController.swift`
- Test: `Tests/SaathiKitTests/SetupPlanTests.swift` (rewritten), `Tests/SaathiShellTests/IslandModelTests.swift`, `Tests/SaathiShellTests/IslandSetupSnapshotTests.swift` (new, opt-in)

**Interfaces:**
- Consumes: `SpeechEngine`, `sarvamKey`, `resolvedSpeech` (Task 1); `SarvamSpeech`, `SarvamLanguage` (Tasks 3, 7); `KeyValidator` (Task 2).
- Produces:
  - `struct VendorKeys { var openAI, sarvam, anthropic: String; subscript(ProviderKind) -> String }`
  - `SetupPlan.vendors = [.openai, .sarvam, .anthropic]`; fields `provider, model, voiceModel, lane, speech, explanation, stored, eye, storedButUnused`; `static func make(valid: Set<ProviderKind>, typed: Set<ProviderKind> = [], current: ProviderKind? = nil, speech: SpeechEngine = .device)`; `static func choosing(_:valid:)`; `func applied(to:keys: VendorKeys)`
  - `struct KeyStates { var openAI, sarvam, anthropic: KeyFieldState; subscript(ProviderKind) }`; `IslandModel.keyStates` (replacing `openAIKeyState` / `anthropicKeyState`), `.provider`, `.providerChoices`, `.sarvamSpeechOn`, `.sarvamSpeechAvailable`, `.keysNote` (was `unusedKeyNote`)
  - `struct IslandProviderChoice { kind, title }`
  - `IslandActions.onKeyFields: (VendorKeys, ProviderKind?) -> Void` (replacing `onCheckKey`, which nothing called, and `onKeyFieldsEmpty`), `.onSaveKeys: (VendorKeys) -> Void`, `.onChooseProvider: (ProviderKind) -> Void`, `.onSarvamSpeech: (Bool) -> Void`
  - `AppController.setupPlan(typed:states:configuration:) -> SetupPlan`, `.setupDecision(fields:states:configuration:) -> SetupDecision { plan, keys }`, `.typed(in:)`, `.keysNeedingCheck(fields:states:)`, `.verdict(_:isTyped:seeded:)`, `.seededKeyStates(for:) -> KeyStates`, `.storedVendors(in:)`, `.providerInUse(_:)`, `.providerChoices(for:)`, `.sarvamSpeechAvailable(for:)`, `.keysNote(for:language:)`, `.voiceTitle(for:)`, `.vendorName(_:)`, `.describe(_:on:)`; instance `typedKeyFields`, `refreshPlanExplanation()`

- [ ] **Step 1: Write the failing tests (the plan).** Replace `Tests/SaathiKitTests/SetupPlanTests.swift` with:

```swift
//
//  SetupPlanTests.swift
//  SaathiKitTests
//
//  "It figures it out for me" is a promise that has to be checkable without a network, a window or
//  a key. That is the entire reason SetupPlan is a value type rather than a method on the panel.
//

import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class SetupPlanTests: XCTestCase {

    /// The plan for whichever keys work, with nothing pasted just now and nothing in use — the
    /// question a fresh install asks.
    private func fresh(openAI: Bool = false, sarvam: Bool = false, anthropic: Bool = false) -> SetupPlan {
        var valid: Set<ProviderKind> = []
        if openAI { valid.insert(.openai) }
        if sarvam { valid.insert(.sarvam) }
        if anthropic { valid.insert(.anthropic) }
        return SetupPlan.make(valid: valid)
    }

    // MARK: which provider

    func testAnOpenAIKeyBuysTheRealtimeLane() {
        let plan = fresh(openAI: true)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.lane, .realtime)
        XCTAssertEqual(plan.voiceModel, "gpt-realtime")
        XCTAssertEqual(plan.model, "gpt-4o-mini")
        XCTAssertEqual(plan.speech, .device, "the realtime lane carries its own speech")
        XCTAssertTrue(plan.storedButUnused.isEmpty)
    }

    func testAnthropicAloneGetsTheChainLaneOnThisMac() {
        let plan = fresh(anthropic: true)
        XCTAssertEqual(plan.provider, .anthropic)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.model, "claude-sonnet-5")
        XCTAssertTrue(plan.voiceModel.isEmpty, "the chain lane opens no socket")
        XCTAssertEqual(plan.speech, .device)
        XCTAssertTrue(plan.storedButUnused.isEmpty, "the key it has is the key it uses")
    }

    /// A Sarvam key buys Sarvam whole: its ears and its mouth as well as its thinking, because
    /// without them it cannot be spoken to in the languages it is chosen for.
    func testASarvamKeyBuysSarvamHeardAndSpoken() {
        let plan = fresh(sarvam: true)
        XCTAssertEqual(plan.provider, .sarvam)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.model, "sarvam-105b")
        XCTAssertTrue(plan.voiceModel.isEmpty)
        XCTAssertEqual(plan.speech, .sarvam)
    }

    func testNoKeysFallsBackToWhateverIsOnThisMachine() {
        let plan = fresh()
        XCTAssertEqual(plan.provider, .local)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.speech, .device)
        XCTAssertTrue(plan.stored.isEmpty)
    }

    /// With nothing pasted and nothing in use: OpenAI for its socket, then Sarvam, then Claude.
    func testWithNothingToGoOnTheMostCapableKeyWins() {
        XCTAssertEqual(fresh(openAI: true, sarvam: true, anthropic: true).provider, .openai)
        XCTAssertEqual(fresh(sarvam: true, anthropic: true).provider, .sarvam)
    }

    /// A key that has just been pasted is a statement of what its owner wants. Otherwise the key
    /// they just added would do nothing they could see.
    func testAKeyJustPastedMovesSaathiToIt() {
        let both: Set<ProviderKind> = [.openai, .sarvam]
        XCTAssertEqual(SetupPlan.make(valid: both, typed: [.sarvam], current: .openai).provider, .sarvam)
        XCTAssertEqual(SetupPlan.make(valid: both, typed: [.openai], current: .sarvam).provider, .openai)
        XCTAssertEqual(
            SetupPlan.make(valid: both, typed: [.openai, .sarvam], current: .sarvam).provider, .openai,
            "both at once is OpenAI, for the reason it always was: the realtime socket")
        XCTAssertEqual(
            SetupPlan.make(valid: [.openai, .anthropic], typed: [.openai], current: .anthropic).provider, .openai,
            "OpenAI arriving still takes over from Claude")
    }

    /// An Anthropic key is there to look at the screen. Pasting one never moves anyone off the
    /// provider they are using.
    func testAnAnthropicKeyOnItsOwnNeverTakesTheConversation() {
        for current in [ProviderKind.openai, .sarvam] {
            let plan = SetupPlan.make(valid: [current, .anthropic], typed: [.anthropic], current: current)
            XCTAssertEqual(plan.provider, current)
        }
        XCTAssertEqual(SetupPlan.make(valid: [.anthropic], typed: [.anthropic], current: .local).provider, .local)
        XCTAssertEqual(SetupPlan.make(valid: [.anthropic], typed: [.anthropic], current: .hosted).provider, .hosted)
        XCTAssertEqual(
            SetupPlan.make(valid: [.anthropic], typed: [.anthropic], current: nil).provider, .anthropic,
            "with nothing chosen, the one key there is does the thinking")
    }

    /// With nothing new pasted, what is in use stays in use — so choosing Sarvam in the picker is
    /// not undone by the next Save.
    func testWhatIsInUseStaysInUseWhileItsKeyWorks() {
        let all: Set<ProviderKind> = [.openai, .sarvam, .anthropic]
        for current in [ProviderKind.openai, .sarvam, .anthropic, .local, .hosted] {
            XCTAssertEqual(SetupPlan.make(valid: all, current: current).provider, current)
        }
        XCTAssertEqual(
            SetupPlan.make(valid: [.openai], current: .sarvam).provider, .openai,
            "a provider whose key is gone is not stayed on")
        XCTAssertEqual(SetupPlan.make(valid: [], current: .sarvam).provider, .local)
    }

    func testAKeyThatWasTypedButRefusedDecidesNothing() {
        XCTAssertEqual(SetupPlan.make(valid: [.openai], typed: [.sarvam], current: .openai).provider, .openai)
    }

    func testChoosingByHandIsTakenAtItsWord() {
        let valid: Set<ProviderKind> = [.openai, .sarvam, .anthropic]
        XCTAssertEqual(SetupPlan.choosing(.sarvam, valid: valid).provider, .sarvam)
        XCTAssertEqual(SetupPlan.choosing(.sarvam, valid: valid).speech, .sarvam)
        XCTAssertEqual(SetupPlan.choosing(.anthropic, valid: valid).speech, .device)
        let local = SetupPlan.choosing(.local, valid: valid)
        XCTAssertEqual(local.provider, .local)
        XCTAssertEqual(local.model, "llama3.2")
        XCTAssertEqual(local.stored, [.openai, .sarvam, .anthropic], "the keys are kept for when they are wanted again")
    }

    // MARK: whose ears and mouth

    /// `provider: sarvam` has always listened on this Mac and sent only the words. A Save that
    /// has nothing to do with Sarvam must not turn that into sending audio.
    func testSarvamsSpeechIsAskedForNotAssumed() {
        let thinkingOnly = SetupPlan.make(valid: [.sarvam], current: .sarvam)
        XCTAssertEqual(thinkingOnly.provider, .sarvam)
        XCTAssertEqual(thinkingOnly.speech, .device)
        XCTAssertTrue(thinkingOnly.explanation.contains("Your voice stays here"), thinkingOnly.explanation)

        let unrelated = SetupPlan.make(valid: [.sarvam, .anthropic], typed: [.anthropic], current: .sarvam)
        XCTAssertEqual(unrelated.speech, .device, "an Anthropic key being pasted asks Sarvam for nothing")

        XCTAssertEqual(
            SetupPlan.make(valid: [.sarvam], typed: [.sarvam], current: .sarvam).speech, .sarvam,
            "pasting the Sarvam key is asking for it")
        XCTAssertEqual(
            SetupPlan.make(valid: [.sarvam], current: .sarvam, speech: .sarvam).speech, .sarvam,
            "and once asked for it stays")
    }

    /// Claude, or a model on this Mac, with Sarvam's ears in front of it: a configuration written
    /// by hand or made with the switch in Setup, and one a Save must describe rather than undo.
    func testSarvamsSpeechCanSitInFrontOfAnotherThinker() {
        let claude = SetupPlan.make(valid: [.sarvam, .anthropic], current: .anthropic, speech: .sarvam)
        XCTAssertEqual(claude.provider, .anthropic)
        XCTAssertEqual(claude.speech, .sarvam)
        XCTAssertTrue(claude.explanation.contains("think with Claude"), claude.explanation)
        XCTAssertTrue(claude.explanation.contains("straight to Sarvam"), claude.explanation)
        XCTAssertTrue(claude.storedButUnused.isEmpty, "the Sarvam key is in use: it hears and speaks")

        let local = SetupPlan.make(valid: [.sarvam], current: .local, speech: .sarvam)
        XCTAssertEqual(local.provider, .local)
        XCTAssertEqual(local.speech, .sarvam)
        XCTAssertTrue(local.explanation.contains("straight to Sarvam"), local.explanation)
        XCTAssertFalse(local.explanation.contains("Nothing you say leaves it"), local.explanation)
    }

    func testSarvamsSpeechNeedsASarvamKeyAndTheChainLane() {
        let noKey = SetupPlan.make(valid: [.anthropic], current: .anthropic, speech: .sarvam)
        XCTAssertEqual(noKey.speech, .device, "asked for with no key to do it with")
        XCTAssertTrue(noKey.explanation.contains("Your voice stays here"), noKey.explanation)

        let realtime = SetupPlan.make(valid: [.openai, .sarvam], current: .openai, speech: .sarvam)
        XCTAssertEqual(realtime.speech, .device, "the realtime lane carries its own speech")
    }

    /// Someone who picks This Mac is picking somewhere their voice stays.
    func testLeavingSarvamPutsSpeechBackOnThisMac() {
        XCTAssertEqual(SetupPlan.choosing(.local, valid: [.sarvam]).speech, .device)
        XCTAssertEqual(SetupPlan.choosing(.anthropic, valid: [.sarvam, .anthropic]).speech, .device)
        XCTAssertEqual(
            SetupPlan.make(valid: [.openai, .sarvam], typed: [.openai], current: .sarvam, speech: .sarvam).speech,
            .device)
        XCTAssertEqual(
            SetupPlan.make(valid: [.anthropic], current: .sarvam, speech: .sarvam).provider, .anthropic,
            "a Sarvam key that stopped working takes its speech with it")
        XCTAssertEqual(SetupPlan.make(valid: [.anthropic], current: .sarvam, speech: .sarvam).speech, .device)
    }

    // MARK: which keys do what

    /// The Anthropic key was reported as "saved, nothing uses it" long after `ScreenSight` began
    /// preferring it. It looks at the screen, and the plan says so.
    func testTheOtherKeysAreSavedAndTheOneThatLooksAtTheScreenIsNamed() {
        let plan = fresh(openAI: true, anthropic: true)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.stored, [.openai, .anthropic])
        XCTAssertEqual(plan.eye, .anthropic)
        XCTAssertTrue(plan.storedButUnused.isEmpty, "it is used: it looks")
    }

    func testTheEyeIsClaudeWhenItIsThereAndOpenAIOtherwise() {
        XCTAssertEqual(fresh(openAI: true).eye, .openai)
        XCTAssertEqual(fresh(openAI: true, sarvam: true, anthropic: true).eye, .anthropic)
        XCTAssertNil(fresh(sarvam: true).eye, "Sarvam does not look at screens; one of the other two has to")
        XCTAssertNil(fresh().eye)
    }

    func testAKeyThatNeitherTalksNorLooksIsNamedAsUnused() {
        let all = SetupPlan.make(valid: [.openai, .sarvam, .anthropic], current: .sarvam)
        XCTAssertEqual(all.storedButUnused, [.openai], "Sarvam talks, Claude looks, and OpenAI waits")
        XCTAssertEqual(fresh(openAI: true, sarvam: true).storedButUnused, [.sarvam])
    }

    // MARK: the sentence

    /// Every branch has to produce a sentence. An empty explanation would render as a blank line in
    /// the panel, which reads as a bug rather than as a default.
    func testEveryPlanExplainsItself() {
        for provider in ProviderKind.allCases {
            for valid in [Set<ProviderKind>(), [.openai, .sarvam, .anthropic]] {
                for speech in SpeechEngine.allCases {
                    for plan in [
                        SetupPlan.choosing(provider, valid: valid),
                        SetupPlan.make(valid: valid, current: provider, speech: speech),
                    ] {
                        XCTAssertFalse(
                            plan.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                            "no explanation for \(provider)")
                    }
                }
            }
        }
    }

    /// The sentence and the plan, for every plan there is: it says the voice leaves as audio
    /// exactly when it will, and names Sarvam exactly when Sarvam is where it goes.
    func testTheSentenceAndThePlanNeverDisagreeAboutTheVoice() {
        let vendors = SetupPlan.vendors
        var subsets: [Set<ProviderKind>] = [[]]
        for vendor in vendors { subsets += subsets.map { $0.union([vendor]) } }
        var plans: [SetupPlan] = []
        for valid in subsets {
            for provider in ProviderKind.allCases { plans.append(SetupPlan.choosing(provider, valid: valid)) }
            for typed in subsets {
                for current in ProviderKind.allCases.map(Optional.some) + [nil] {
                    for speech in SpeechEngine.allCases {
                        plans.append(SetupPlan.make(valid: valid, typed: typed, current: current, speech: speech))
                    }
                }
            }
        }
        XCTAssertGreaterThan(plans.count, 700)
        for plan in plans {
            let leaves = plan.lane == .realtime || plan.speech == .sarvam
            XCTAssertEqual(plan.explanation.contains("leaves this machine as audio"), leaves, plan.explanation)
            XCTAssertEqual(
                plan.explanation.contains("straight to Sarvam"), plan.speech == .sarvam, plan.explanation)
            if plan.speech == .sarvam {
                XCTAssertEqual(plan.lane, .chain)
                XCTAssertTrue(plan.stored.contains(.sarvam), "Sarvam's speech with no Sarvam key: \(plan)")
            }
        }
    }

    /// The local explanation is the one a stuck person reads most, so it has to name the thing they
    /// are missing rather than say "not configured".
    func testTheLocalExplanationNamesWhatToInstall() {
        XCTAssertTrue(fresh().explanation.contains("Ollama"))
        XCTAssertTrue(fresh().explanation.contains("No key yet"))
        let chosen = SetupPlan.choosing(.local, valid: [.openai])
        XCTAssertTrue(chosen.explanation.contains("Ollama"))
        XCTAssertFalse(chosen.explanation.contains("No key yet"), "there is a key; this Mac was chosen anyway")
    }

    /// The most consequential sentences in the app. Whenever the voice will leave as audio the
    /// sentence says so, and says to whom; whenever it will not, it does not.
    func testTheSentenceSaysWhereTheVoiceGoes() {
        let openAI = fresh(openAI: true).explanation
        XCTAssertTrue(openAI.contains("leaves this machine as audio, straight to OpenAI"), openAI)

        let sarvam = fresh(sarvam: true).explanation
        XCTAssertTrue(sarvam.contains("leaves this machine as audio, straight to Sarvam"), sarvam)
        XCTAssertTrue(sarvam.contains("language"), "and that the language is the one chosen in Setup")

        for stays in [fresh(anthropic: true), fresh(), SetupPlan.choosing(.local, valid: [.sarvam])] {
            XCTAssertFalse(stays.explanation.contains("leaves this machine"), stays.explanation)
        }
        XCTAssertTrue(fresh(anthropic: true).explanation.contains("Your voice stays here"))
    }

    // MARK: applying a plan

    func testApplyingAPlanWritesTheKeysAndTheChosenProvider() {
        let plan = fresh(openAI: true, anthropic: true)
        let config = plan.applied(to: SaathiConfiguration(), keys: VendorKeys(openAI: "sk-o", anthropic: "sk-a"))

        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.openaiKey, "sk-o")
        XCTAssertEqual(config.anthropicKey, "sk-a", "a key that is not doing the talking is still stored")
        XCTAssertEqual(config.model, "gpt-4o-mini")
        XCTAssertEqual(config.voiceModel, "gpt-realtime")
        XCTAssertNil(config.speech)
        XCTAssertEqual(config.credential(for: .openai), "sk-o")
    }

    func testApplyingASarvamPlanAsksForSarvamsSpeechAndOnlyThen() {
        let existing = SaathiConfiguration(provider: .openai, model: "gpt-4o-mini", openaiKey: "sk-o", voiceModel: "gpt-realtime")
        let plan = SetupPlan.make(valid: [.openai, .sarvam], typed: [.sarvam], current: .openai)
        let sarvam = plan.applied(to: existing, keys: VendorKeys(openAI: "sk-o", sarvam: "sk-s"))

        XCTAssertEqual(sarvam.provider, .sarvam)
        XCTAssertEqual(sarvam.speech, .sarvam)
        XCTAssertEqual(sarvam.sarvamKey, "sk-s")
        XCTAssertEqual(sarvam.openaiKey, "sk-o", "kept: it looks at the screen, and it is a click away in the picker")
        XCTAssertEqual(sarvam.model, "sarvam-105b")
        XCTAssertNil(sarvam.voiceModel, "no socket, no voice model")
        XCTAssertTrue(SarvamSpeech.isOn(sarvam))

        // And back again: the voice no longer goes to Sarvam once the sentence stops saying it does.
        let back = SetupPlan.choosing(.openai, valid: [.openai, .sarvam]).applied(to: sarvam, keys: VendorKeys())
        XCTAssertEqual(back.provider, .openai)
        XCTAssertNil(back.speech)
        XCTAssertEqual(back.model, "gpt-4o-mini")
        XCTAssertEqual(back.voiceModel, "gpt-realtime")
        XCTAssertEqual(back.sarvamKey, "sk-s")
        XCTAssertEqual(back.openaiKey, "sk-o", "a blank for a key that is already there keeps it")
    }

    /// `"model": "sarvam-105b-conversations"` is one line in shell.json. Replacing a key must not
    /// quietly put the default back.
    func testAModelChosenByHandSurvivesAKeyBeingReplaced() {
        let existing = SaathiConfiguration(
            provider: .sarvam, model: "sarvam-105b-conversations", sarvamKey: "sk-old", voice: "ishita", speech: .sarvam)
        let plan = SetupPlan.make(valid: [.sarvam], typed: [.sarvam], current: .sarvam)
        let config = plan.applied(to: existing, keys: VendorKeys(sarvam: "sk-new"))
        XCTAssertEqual(config.model, "sarvam-105b-conversations")
        XCTAssertEqual(config.voice, "ishita")
        XCTAssertEqual(config.sarvamKey, "sk-new")
    }

    /// A voice chosen for one provider is never sent to another that does not have it.
    func testAVoiceDoesNotFollowAChangeOfProvider() {
        let existing = SaathiConfiguration(provider: .openai, openaiKey: "sk-o", sarvamKey: "sk-s", voice: "marin")
        let config = SetupPlan.choosing(.sarvam, valid: [.openai, .sarvam]).applied(to: existing, keys: VendorKeys())
        XCTAssertNil(config.voice)
    }

    /// Settings a person chose by hand are not ours to throw away because they pasted a key.
    func testApplyingAPlanKeepsUnrelatedSettings() {
        let existing = SaathiConfiguration(language: "ml", backendUrl: "https://example.test", token: "tok", name: "Asha")
        let config = fresh(openAI: true).applied(to: existing, keys: VendorKeys(openAI: "sk-o"))

        XCTAssertEqual(config.backendUrl, "https://example.test")
        XCTAssertEqual(config.token, "tok")
        XCTAssertEqual(config.language, "ml")
        XCTAssertEqual(config.name, "Asha")
    }

    /// A key that did not validate is not saved. Storing a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working.
    func testAKeyThatDidNotValidateIsNotStored() {
        let config = fresh(openAI: true).applied(
            to: SaathiConfiguration(), keys: VendorKeys(openAI: "sk-o", sarvam: "sk-bad", anthropic: "sk-bad"))
        XCTAssertNil(config.anthropicKey)
        XCTAssertNil(config.sarvamKey)
    }

    /// Keys pasted from many sources arrive with trailing whitespace or newlines. Trimming is
    /// non-negotiable; if skipped, the key is refused as malformed on the next launch, which looks
    /// like the key suddenly stopped working.
    func testAKeyWithLeadingTrailingWhitespaceIsTrimmedBeforeStorage() {
        let config = fresh(openAI: true, sarvam: true, anthropic: true).applied(
            to: SaathiConfiguration(),
            keys: VendorKeys(openAI: "  sk-o  \n", sarvam: "\tsk-s ", anthropic: "  sk-a  \n"))

        XCTAssertEqual(config.openaiKey, "sk-o", "leading and trailing whitespace must be trimmed")
        XCTAssertEqual(config.sarvamKey, "sk-s")
        XCTAssertEqual(config.anthropicKey, "sk-a", "a key that is not doing the talking is trimmed too")
    }

    /// A key that is only whitespace is not stored as an empty string — it is not stored at all.
    /// Empty strings would be indistinguishable from "not present" and would clutter config.
    func testAWhitespaceOnlyKeyIsStoredAsNilNotEmptyString() {
        let config = fresh(openAI: true, anthropic: true).applied(
            to: SaathiConfiguration(), keys: VendorKeys(openAI: "sk-o", anthropic: "   \n\t   "))

        XCTAssertEqual(config.openaiKey, "sk-o")
        XCTAssertNil(config.anthropicKey, "whitespace-only key becomes nil, not empty string")
    }

    /// When a key did not validate, an existing stored key for that provider is kept — it was
    /// good once. Clearing it would erase a working credential just because this attempt failed,
    /// which is worse than keeping a stale one that the user can see and update.
    func testAnExistingKeyIsPreservedWhenNewAttemptDidNotValidate() {
        let existing = SaathiConfiguration(anthropicKey: "sk-a-old")
        let config = fresh().applied(to: existing, keys: VendorKeys(anthropic: "sk-a-bad"))

        XCTAssertEqual(config.anthropicKey, "sk-a-old", "existing valid key preserved when new attempt fails")
    }

    func testKeysAreReadAndWrittenByVendorAndNothingElseHasOne() {
        var keys = VendorKeys(openAI: "o", sarvam: "s", anthropic: "a")
        XCTAssertEqual(SetupPlan.vendors.map { keys[$0] }, ["o", "s", "a"])
        keys[.sarvam] = "new"
        keys[.local] = "ignored"
        XCTAssertEqual(keys, VendorKeys(openAI: "o", sarvam: "new", anthropic: "a"))
        XCTAssertEqual(keys[.hosted], "")
    }
}
```

- [ ] **Step 2: Write the failing tests (the panel).** `Tests/SaathiShellTests/IslandModelTests.swift`, in place:

```diff
--- a/macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift
+++ b/macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift
@@ -49,10 +49,13 @@
 
     func testTheIslandStartsOnHome() {
         XCTAssertEqual(IslandModel().tab, .home)
-        XCTAssertEqual(IslandModel().openAIKeyState, .empty)
-        XCTAssertEqual(IslandModel().anthropicKeyState, .empty)
+        XCTAssertEqual(IslandModel().keyStates, KeyStates())
         XCTAssertEqual(IslandModel().planExplanation, "")
-        XCTAssertEqual(IslandModel().unusedKeyNote, "")
+        XCTAssertEqual(IslandModel().keysNote, "")
+        XCTAssertEqual(IslandModel().provider, .local)
+        XCTAssertTrue(IslandModel().providerChoices.isEmpty, "nothing to pick until the shell says what there is")
+        XCTAssertFalse(IslandModel().sarvamSpeechOn)
+        XCTAssertFalse(IslandModel().sarvamSpeechAvailable)
     }
 
     func testTheTabSwitches() {
@@ -76,12 +79,36 @@
 
     func testAFieldCanBeCheckingAndThenChecked() {
         let model = IslandModel()
-        model.openAIKeyState = .checking
-        XCTAssertEqual(model.openAIKeyState, .checking)
-        model.openAIKeyState = .checked(.rejected("OpenAI did not accept that key."))
-        XCTAssertEqual(model.openAIKeyState, .checked(.rejected("OpenAI did not accept that key.")))
+        model.keyStates[.openai] = .checking
+        XCTAssertEqual(model.keyStates.openAI, .checking)
+        model.keyStates[.openai] = .checked(.rejected("OpenAI did not accept that key."))
+        XCTAssertEqual(model.keyStates[.openai], .checked(.rejected("OpenAI did not accept that key.")))
     }
 
+    /// Three fields, reached by vendor so that nothing has to be written out three times. A
+    /// provider that takes no key has no field to be in any state.
+    func testEachVendorHasItsOwnFieldAndNothingElseHasOne() {
+        var states = KeyStates()
+        states[.sarvam] = .checking
+        states[.anthropic] = .saved(masked: "sk-…abcd")
+        states[.local] = .checking
+        states[.hosted] = .checking
+        XCTAssertEqual(states, KeyStates(sarvam: .checking, anthropic: .saved(masked: "sk-…abcd")))
+        XCTAssertEqual(SetupPlan.vendors.map { states[$0] }, [.empty, .checking, .saved(masked: "sk-…abcd")])
+        XCTAssertEqual(states[.local], .empty)
+    }
+
+    /// Sarvam speaks Gujarati and Punjabi, so they can be chosen. The tags are the ones Sarvam's
+    /// own codes are made from.
+    func testTheLanguagesOnOfferIncludeEveryOneSarvamSpeaksButOdia() {
+        let tags = Set(IslandLanguage.all.map(\.tag))
+        for tag in ["en", "hi", "ta", "te", "bn", "mr", "kn", "ml", "gu", "pa"] {
+            XCTAssertTrue(tags.contains(tag), tag)
+            XCTAssertNotNil(SarvamLanguage.code(for: tag), tag)
+        }
+        XCTAssertEqual(IslandLanguage.all.count, tags.count, "a tag offered twice")
+    }
+
     /// The button must be inert while a check is in flight, or a double-click fires two round trips
     /// and the second answer overwrites the first.
     func testAFieldIsBusyOnlyWhileChecking() {
@@ -105,8 +132,12 @@
 
     func testTheActionsDefaultToDoingNothing() {
         let actions = IslandActions()
-        actions.onCheckKey(.openai, "sk-o", "sk-a")
-        actions.onSaveKeys("sk-o", "sk-a")
+        actions.onKeyFields(VendorKeys(openAI: "sk-o"), .openai)
+        actions.onKeyFields(VendorKeys(), nil)
+        actions.onSaveKeys(VendorKeys(openAI: "sk-o", sarvam: "sk-s", anthropic: "sk-a"))
+        actions.onChooseProvider(.sarvam)
+        actions.onSarvamSpeech(true)
+        actions.onLanguage("ml")
     }
 }
 
@@ -119,18 +150,11 @@
 final class SetupDecisionTests: XCTestCase {
 
     private func decide(
-        openAIField: String = "",
-        anthropicField: String = "",
-        openAI: KeyFieldState = .empty,
-        anthropic: KeyFieldState = .empty,
+        fields: VendorKeys = VendorKeys(),
+        states: KeyStates = KeyStates(),
         configuration: SaathiConfiguration = SaathiConfiguration()
     ) -> AppController.SetupDecision {
-        AppController.setupDecision(
-            openAIField: openAIField,
-            anthropicField: anthropicField,
-            openAIState: openAI,
-            anthropicState: anthropic,
-            configuration: configuration)
+        AppController.setupDecision(fields: fields, states: states, configuration: configuration)
     }
 
     /// The regression, exactly as it happened: a fresh install, an OpenAI key checked, then an
@@ -139,21 +163,22 @@
     /// to OpenAI. Both keys are live in the panel, so both must count in the preview.
     func testTwoCheckedKeysOnAFreshInstallStillChooseOpenAI() {
         let decision = decide(
-            openAIField: "sk-o", anthropicField: "sk-a",
-            openAI: .checked(.valid), anthropic: .checked(.valid))
+            fields: VendorKeys(openAI: "sk-o", anthropic: "sk-a"),
+            states: KeyStates(openAI: .checked(.valid), anthropic: .checked(.valid)))
         XCTAssertEqual(decision.plan.provider, .openai)
         XCTAssertTrue(
             decision.plan.explanation.contains("leaves this machine"),
             "the sentence must not promise the voice stays here: \(decision.plan.explanation)")
-        XCTAssertEqual(decision.plan.storedButUnused, [.anthropic])
-        XCTAssertEqual(decision.openAIKey, "sk-o")
-        XCTAssertEqual(decision.anthropicKey, "sk-a")
+        XCTAssertEqual(decision.plan.eye, .anthropic)
+        XCTAssertTrue(decision.plan.storedButUnused.isEmpty, "the Anthropic key looks at the screen")
+        XCTAssertEqual(decision.keys, VendorKeys(openAI: "sk-o", anthropic: "sk-a"))
     }
 
     /// The sentence and the file, checked against each other across every combination of verdicts
-    /// and fields: whenever the explanation says the voice leaves as audio, the configuration Save
-    /// would write must actually name OpenAI, and whenever it says the voice stays here, it must
-    /// not. This is the invariant itself, not the code path that happens to implement it.
+    /// and fields, for three vendors and for configurations that already ask for Sarvam's speech:
+    /// the sentence says the voice leaves as audio exactly when the configuration Save would write
+    /// sends it, names Sarvam exactly when Sarvam is where it goes, and never names a vendor there
+    /// is no key for. This is the invariant itself, not the code path that happens to implement it.
     func testTheSentenceAlwaysDescribesTheConfigurationSaveWouldWrite() {
         let states: [KeyFieldState] = [
             .empty, .editing, .checking, .checked(.valid), .checked(.rejected("no")),
@@ -162,62 +187,158 @@
         let fields = ["", "   ", "sk-typed"]
         let configurations = [
             SaathiConfiguration(),
+            SaathiConfiguration(provider: .local),
             SaathiConfiguration(provider: .openai, apiKey: "sk-legacy"),
             SaathiConfiguration(provider: .anthropic, apiKey: "sk-legacy"),
+            SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy"),
             SaathiConfiguration(provider: .openai, openaiKey: "sk-stored-o"),
             SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-stored-a"),
             SaathiConfiguration(provider: .openai, openaiKey: "sk-stored-o", anthropicKey: "sk-stored-a"),
+            SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-stored-s"),
+            SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-stored-s", speech: .sarvam),
+            SaathiConfiguration(
+                provider: .sarvam, openaiKey: "sk-stored-o", anthropicKey: "sk-stored-a", sarvamKey: "sk-stored-s",
+                speech: .sarvam),
+            SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-stored-a", sarvamKey: "sk-stored-s", speech: .sarvam),
+            SaathiConfiguration(sarvamKey: "sk-stored-s", speech: .sarvam),
+            SaathiConfiguration(provider: .local, speech: .sarvam),
+            SaathiConfiguration(provider: .hosted, sarvamKey: "sk-stored-s", token: "tok"),
         ]
+        var checked = 0
         for configuration in configurations {
             for openAI in states {
-                for anthropic in states {
-                    for openAIField in fields {
-                        for anthropicField in fields {
-                            let decision = decide(
-                                openAIField: openAIField, anthropicField: anthropicField,
-                                openAI: openAI, anthropic: anthropic, configuration: configuration)
-                            let written = decision.plan.applied(
-                                to: configuration,
-                                openAIKey: decision.openAIKey,
-                                anthropicKey: decision.anthropicKey)
-                            let sentence = decision.plan.explanation
-                            let context = "\(sentence) → \(String(describing: written.provider))"
-                            if sentence.contains("leaves this machine") {
-                                XCTAssertEqual(written.provider, .openai, context)
-                                XCTAssertFalse((written.openaiKey ?? "").isEmpty, context)
-                            }
-                            if sentence.contains("Your voice stays here") {
-                                XCTAssertNotEqual(written.provider, .openai, context)
+                for sarvam in states {
+                    for anthropic in states {
+                        for openAIField in fields {
+                            for sarvamField in fields {
+                                for anthropicField in fields {
+                                    let decision = decide(
+                                        fields: VendorKeys(openAI: openAIField, sarvam: sarvamField, anthropic: anthropicField),
+                                        states: KeyStates(openAI: openAI, sarvam: sarvam, anthropic: anthropic),
+                                        configuration: configuration)
+                                    let written = decision.plan.applied(to: configuration, keys: decision.keys)
+                                    let sentence = decision.plan.explanation
+                                    let toSarvam = SarvamSpeech.isOn(written)
+                                    let leaves = written.providerRow.voice == .realtime || toSarvam
+                                    checked += 1
+                                    // One comparison a case and one failure at most: a hundred
+                                    // thousand passing assertions are slower than the code under test.
+                                    let holds = written.provider == decision.plan.provider
+                                        && sentence.contains("leaves this machine as audio") == leaves
+                                        && sentence.contains("straight to Sarvam") == toSarvam
+                                        && sentence.contains("straight to OpenAI") == (written.provider == .openai)
+                                        && (!toSarvam || written.credential(for: .sarvam) != nil)
+                                        && (written.provider != .openai || written.credential(for: .openai) != nil)
+                                    guard holds else {
+                                        return XCTFail("""
+                                            the sentence and the save disagree.
+                                            sentence: \(sentence)
+                                            written:  provider \(String(describing: written.provider)), \
+                                            speech \(String(describing: written.speech)), leaves \(leaves)
+                                            from:     \(configuration)
+                                            fields:   \([openAIField, sarvamField, anthropicField])
+                                            states:   \([openAI, sarvam, anthropic])
+                                            """)
+                                    }
+                                }
                             }
-                            XCTAssertEqual(written.provider, decision.plan.provider, context)
                         }
                     }
                 }
             }
         }
+        XCTAssertEqual(checked, configurations.count * 343 * 27)
     }
 
+    /// A Sarvam key pasted into a working OpenAI install moves Saathi to Sarvam — otherwise the key
+    /// just added would do nothing anyone could see — and the sentence says where the voice will go
+    /// before it is saved.
+    func testPastingASarvamKeyMovesToSarvamAndSaysWhereTheVoiceGoes() {
+        let existing = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
+        let decision = decide(
+            fields: VendorKeys(sarvam: " sk-s \n"),
+            states: KeyStates(openAI: .saved(masked: "sk-…sk-o"), sarvam: .checked(.valid)),
+            configuration: existing)
+        XCTAssertEqual(decision.plan.provider, .sarvam)
+        XCTAssertEqual(decision.plan.speech, .sarvam)
+        XCTAssertTrue(decision.plan.explanation.contains("straight to Sarvam"), decision.plan.explanation)
+
+        let written = decision.plan.applied(to: existing, keys: decision.keys)
+        XCTAssertTrue(SarvamSpeech.isOn(written))
+        XCTAssertEqual(written.sarvamKey, "sk-s")
+        XCTAssertEqual(written.openaiKey, "sk-o", "kept: it looks at the screen, and the picker goes back to it")
+        XCTAssertEqual(written.model, "sarvam-105b")
+    }
+
+    /// Until the vendor has accepted it, a key in a field decides nothing.
+    func testASarvamKeyStillBeingTypedChangesNothing() {
+        let existing = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
+        for state in [KeyFieldState.editing, .checking, .checked(.rejected("Sarvam did not accept that key."))] {
+            let decision = decide(
+                fields: VendorKeys(sarvam: "sk-s"),
+                states: KeyStates(openAI: .saved(masked: "sk-…sk-o"), sarvam: state),
+                configuration: existing)
+            XCTAssertEqual(decision.plan.provider, .openai, "\(state)")
+            XCTAssertFalse(decision.plan.explanation.contains("Sarvam"), "\(state)")
+        }
+    }
+
+    /// `provider: sarvam` with the legacy key has always listened on this Mac and sent only the
+    /// words. Pasting an Anthropic key is not asking for that to change, and it does not.
+    func testAnUnrelatedSaveDoesNotStartSendingTheVoiceToSarvam() {
+        let thinkingOnly = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy")
+        var states = AppController.seededKeyStates(for: thinkingOnly)
+        states.anthropic = .checked(.valid)
+        let decision = decide(fields: VendorKeys(anthropic: "sk-a"), states: states, configuration: thinkingOnly)
+        XCTAssertEqual(decision.plan.provider, .sarvam)
+        XCTAssertEqual(decision.plan.speech, .device)
+        XCTAssertTrue(decision.plan.explanation.contains("Your voice stays here"), decision.plan.explanation)
+
+        let written = decision.plan.applied(to: thinkingOnly, keys: decision.keys)
+        XCTAssertFalse(SarvamSpeech.isOn(written))
+        XCTAssertEqual(written.anthropicKey, "sk-a")
+        XCTAssertEqual(written.sarvamKey, "sk-legacy", "the shared key is filed under the vendor it was used for")
+        XCTAssertNil(written.openaiKey)
+    }
+
+    /// Claude thinking with Sarvam's ears, made with the switch: a Save about something else
+    /// describes it and leaves it as it is.
+    func testSarvamsEarsInFrontOfClaudeSurviveASave() {
+        let mixed = SaathiConfiguration(
+            provider: .anthropic, anthropicKey: "sk-a", sarvamKey: "sk-s", speech: .sarvam)
+        var states = AppController.seededKeyStates(for: mixed)
+        states.anthropic = .checked(.valid)
+        let decision = decide(fields: VendorKeys(anthropic: "sk-a-new"), states: states, configuration: mixed)
+        XCTAssertEqual(decision.plan.provider, .anthropic)
+        XCTAssertEqual(decision.plan.speech, .sarvam)
+        XCTAssertTrue(decision.plan.explanation.contains("straight to Sarvam"), decision.plan.explanation)
+        let written = decision.plan.applied(to: mixed, keys: decision.keys)
+        XCTAssertTrue(SarvamSpeech.isOn(written))
+        XCTAssertEqual(written.anthropicKey, "sk-a-new")
+    }
+
     /// A legacy config holds one shared `apiKey` and no vendor key. Reading the vendor fields
     /// directly made both effective keys empty, so Save produced the local plan and demoted a
     /// working install to "look for Ollama". `credential(for:)` is what everything else asks.
     func testALegacyApiKeyCountsAsTheKeyItIs() {
         let legacy = SaathiConfiguration(provider: .openai, apiKey: "sk-legacy-key")
-        let decision = decide(openAI: .saved(masked: "sk-…y"), configuration: legacy)
-        XCTAssertEqual(decision.openAIKey, "sk-legacy-key")
+        let decision = decide(states: KeyStates(openAI: .saved(masked: "sk-…y")), configuration: legacy)
+        XCTAssertEqual(decision.keys.openAI, "sk-legacy-key")
         XCTAssertEqual(decision.plan.provider, .openai, "a legacy key must not be demoted to local")
     }
 
     /// Nothing typed and nothing stored is genuinely no key, however confident the verdict is.
     func testAValidVerdictWithNoKeyBehindItCountsForNothing() {
-        let decision = decide(openAI: .checked(.valid), anthropic: .checked(.valid))
+        let decision = decide(
+            states: KeyStates(openAI: .checked(.valid), sarvam: .checked(.valid), anthropic: .checked(.valid)))
         XCTAssertEqual(decision.plan.provider, .local)
     }
 
     /// Typing invalidates the verdict, and an invalidated verdict must not keep its key in play.
     func testAnEditedFieldDropsOutOfThePlan() {
         let decision = decide(
-            openAIField: "sk-o-half-typed", anthropicField: "sk-a",
-            openAI: .editing, anthropic: .checked(.valid))
+            fields: VendorKeys(openAI: "sk-o-half-typed", anthropic: "sk-a"),
+            states: KeyStates(openAI: .editing, anthropic: .checked(.valid)))
         XCTAssertEqual(decision.plan.provider, .anthropic)
     }
 }
@@ -232,8 +353,20 @@
             for: SaathiConfiguration(provider: .openai, openaiKey: "sk-openai-1234"))
         XCTAssertEqual(seeded.openAI, .saved(masked: "sk-…1234"))
         XCTAssertEqual(seeded.anthropic, .empty, "no Anthropic key is stored, so none may be shown")
+        XCTAssertEqual(seeded.sarvam, .empty)
     }
 
+    func testASarvamKeySeedsTheSarvamField() {
+        let seeded = AppController.seededKeyStates(
+            for: SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-sarvam-4321"))
+        XCTAssertEqual(seeded, KeyStates(sarvam: .saved(masked: "sk-…4321")))
+
+        // And the key Sarvam was given before it had a field of its own.
+        let legacy = AppController.seededKeyStates(
+            for: SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy-1234"))
+        XCTAssertEqual(legacy, KeyStates(sarvam: .saved(masked: "sk-…1234")))
+    }
+
     func testBothVendorKeysSeedBothFields() {
         let seeded = AppController.seededKeyStates(
             for: SaathiConfiguration(provider: .openai, openaiKey: "sk-openai-1234", anthropicKey: "sk-ant-5678"))
@@ -247,8 +380,7 @@
     func testALegacyKeySeedsOnlyTheProviderTheConfigNames() {
         let seeded = AppController.seededKeyStates(
             for: SaathiConfiguration(provider: .openai, apiKey: "sk-legacy-1234"))
-        XCTAssertEqual(seeded.openAI, .saved(masked: "sk-…1234"))
-        XCTAssertEqual(seeded.anthropic, .empty)
+        XCTAssertEqual(seeded, KeyStates(openAI: .saved(masked: "sk-…1234")))
 
         let anthropic = AppController.seededKeyStates(
             for: SaathiConfiguration(provider: .anthropic, apiKey: "sk-legacy-1234"))
@@ -260,14 +392,11 @@
     /// either vendor would be the panel inventing a fact the file does not hold.
     func testALegacyKeyWithNoProviderNamedSeedsNothing() {
         let seeded = AppController.seededKeyStates(for: SaathiConfiguration(apiKey: "sk-legacy-1234"))
-        XCTAssertEqual(seeded.openAI, .empty)
-        XCTAssertEqual(seeded.anthropic, .empty)
+        XCTAssertEqual(seeded, KeyStates())
     }
 
     func testAnEmptyConfigSeedsNothing() {
-        let seeded = AppController.seededKeyStates(for: SaathiConfiguration())
-        XCTAssertEqual(seeded.openAI, .empty)
-        XCTAssertEqual(seeded.anthropic, .empty)
+        XCTAssertEqual(AppController.seededKeyStates(for: SaathiConfiguration()), KeyStates())
     }
 
     /// Seeding and deciding must read the same config the same way, or Setup opens showing a key
@@ -275,18 +404,15 @@
     func testWhatIsSeededIsWhatSaveWouldUse() {
         let legacy = SaathiConfiguration(provider: .openai, apiKey: "sk-legacy-1234")
         let seeded = AppController.seededKeyStates(for: legacy)
-        let decision = AppController.setupDecision(
-            openAIField: "", anthropicField: "",
-            openAIState: seeded.openAI, anthropicState: seeded.anthropic,
-            configuration: legacy)
+        let decision = AppController.setupDecision(fields: VendorKeys(), states: seeded, configuration: legacy)
         XCTAssertEqual(decision.plan.provider, .openai)
-        XCTAssertEqual(decision.openAIKey, "sk-legacy-1234")
-        // `credential(for:)` still hands the legacy key to Anthropic too, but with no verdict
-        // behind it nothing counts it, and the config Save would write gains no Anthropic key.
-        let written = decision.plan.applied(
-            to: legacy, openAIKey: decision.openAIKey, anthropicKey: decision.anthropicKey)
+        XCTAssertEqual(decision.keys.openAI, "sk-legacy-1234")
+        // `credential(for:)` still hands the legacy key to the other two vendors, but with no
+        // verdict behind it nothing counts it, and the config Save would write gains no key of theirs.
+        let written = decision.plan.applied(to: legacy, keys: decision.keys)
         XCTAssertEqual(written.openaiKey, "sk-legacy-1234")
         XCTAssertNil(written.anthropicKey, "the legacy key must not be re-filed as an Anthropic key")
+        XCTAssertNil(written.sarvamKey, "nor as a Sarvam one")
     }
 }
 
@@ -295,19 +421,52 @@
 @MainActor
 final class SetupPresentationTests: XCTestCase {
 
-    func testAnUnusedStoredKeyIsNamedOutLoud() {
-        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
-        let note = AppController.unusedKeyNote(for: plan)
-        XCTAssertTrue(note.contains("Anthropic"), "got: \(note)")
-        XCTAssertTrue(note.lowercased().contains("nothing uses it") || note.lowercased().contains("not used"),
-                      "the note must say it is unused, not merely mention it: \(note)")
+    /// It said "Anthropic key saved. Nothing uses it yet." about the key `ScreenSight` prefers.
+    func testTheNoteSaysWhatTheAnthropicKeyIsFor() {
+        let plan = SetupPlan.make(valid: [.openai, .anthropic])
+        XCTAssertEqual(
+            AppController.keysNote(for: plan, language: "en"),
+            "The Anthropic key looks at the screen when you ask about something on it.")
     }
 
-    func testThereIsNoNoteWhenEveryStoredKeyIsInUse() {
-        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
-        XCTAssertEqual(AppController.unusedKeyNote(for: plan), "")
+    /// A key that really is doing nothing is named, with the way to put it to use.
+    func testAKeyNothingUsesIsNamedAndSoIsTheWayToUseIt() {
+        let plan = SetupPlan.make(valid: [.openai, .sarvam])
+        XCTAssertEqual(plan.provider, .openai)
+        XCTAssertEqual(
+            AppController.keysNote(for: plan, language: "en"),
+            "The Sarvam key is saved and not in use. Choose Sarvam under Where it thinks to use it.")
     }
 
+    func testThereIsNoNoteWhenThereIsNothingToAdd() {
+        XCTAssertEqual(AppController.keysNote(for: SetupPlan.make(valid: [.openai]), language: "en"), "")
+        XCTAssertEqual(AppController.keysNote(for: SetupPlan.make(valid: []), language: "en"), "")
+        XCTAssertEqual(AppController.keysNote(for: SetupPlan.make(valid: [.anthropic]), language: "en"), "")
+    }
+
+    /// Sarvam does not look at screens. Someone with only its key is told what would.
+    func testSarvamAloneSaysNothingHereCanLook() {
+        XCTAssertEqual(
+            AppController.keysNote(for: SetupPlan.make(valid: [.sarvam]), language: "ml"),
+            "Nothing here can look at the screen: that takes an OpenAI or an Anthropic key.")
+    }
+
+    /// The session would refuse to start, and the sentence above promises Sarvam will listen "in
+    /// the language chosen below" — so what is wrong with that language is said before the save.
+    func testALanguageSarvamDoesNotSpeakIsSaidBeforeItIsSaved() {
+        let plan = SetupPlan.make(valid: [.sarvam, .anthropic], typed: [.sarvam])
+        XCTAssertEqual(
+            AppController.keysNote(for: plan, language: "fr"),
+            "Sarvam does not hear or speak French. Choose another language under Voice first. "
+                + "The Anthropic key looks at the screen when you ask about something on it.")
+        XCTAssertFalse(AppController.keysNote(for: plan, language: "ml").contains("does not hear"))
+        XCTAssertFalse(AppController.keysNote(for: plan, language: "or").contains("does not hear"), "Odia is od-IN to Sarvam")
+
+        // Sarvam only thinking listens on this Mac, so Sarvam's languages are not the limit.
+        let thinkingOnly = SetupPlan.make(valid: [.sarvam], current: .sarvam)
+        XCTAssertFalse(AppController.keysNote(for: thinkingOnly, language: "fr").contains("does not hear"))
+    }
+
     // MARK: what was said
 
     func testTheLastExchangeStartsEmptyAndActionsReadAsOneLine() {
@@ -408,6 +567,40 @@
             "stays on this machine")
     }
 
+    /// With Sarvam's ears the audio goes whoever does the thinking. Home and the Voice rows say so.
+    func testThePrivacyLineSaysWhenSarvamHearsTheVoice() {
+        XCTAssertEqual(
+            AppController.privacyLine(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam)),
+            "your voice leaves as audio, to Sarvam")
+        XCTAssertEqual(
+            AppController.privacyLine(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k")),
+            "only the transcript is sent", "asked for, not assumed")
+        XCTAssertEqual(
+            AppController.privacyLine(for: SaathiConfiguration(sarvamKey: "k", speech: .sarvam)),
+            "your voice leaves as audio, to Sarvam", "a model on this Mac, with Sarvam's ears in front of it")
+        XCTAssertEqual(
+            AppController.privacyLine(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o", speech: .sarvam)),
+            "your voice leaves as audio", "the realtime lane does not read `speech`")
+    }
+
+    func testTheVoiceRowSaysWhoseVoiceItIs() {
+        XCTAssertEqual(
+            AppController.voiceTitle(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")),
+            SaathiProvider.of(.openai).defaultVoice)
+        XCTAssertEqual(
+            AppController.voiceTitle(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o", voice: "marin")),
+            "marin")
+        XCTAssertEqual(
+            AppController.voiceTitle(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", speech: .sarvam)),
+            "Sarvam · shubh")
+        XCTAssertEqual(
+            AppController.voiceTitle(for: SaathiConfiguration(provider: .sarvam, sarvamKey: "k", voice: "Ishita", speech: .sarvam)),
+            "Sarvam · ishita")
+        XCTAssertEqual(
+            AppController.voiceTitle(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-a")),
+            "this Mac's")
+    }
+
     /// First run opens on Setup, and only first run. "First run" is "no provider has a credential",
     /// which is a fact about the config rather than a flag that can get out of step with it.
     func testTheIslandOpensOnSetupOnlyWhileNothingIsConfigured() {
@@ -436,42 +629,46 @@
     /// rejected key on disk, and the voice failing with "not connected". Save now checks it itself.
     func testATypedKeyWithoutAnAcceptedVerdictNeedsACheckBeforeSave() {
         XCTAssertEqual(AppController.keysNeedingCheck(
-            openAIField: "sk-new", anthropicField: "",
-            openAIState: .editing, anthropicState: .empty), [.openai])
+            fields: VendorKeys(openAI: "sk-new"), states: KeyStates(openAI: .editing)), [.openai])
         XCTAssertEqual(AppController.keysNeedingCheck(
-            openAIField: "sk-new", anthropicField: "",
-            openAIState: .saved(masked: "…old1"), anthropicState: .empty), [.openai],
+            fields: VendorKeys(openAI: "sk-new"), states: KeyStates(openAI: .saved(masked: "…old1"))), [.openai],
             "a reopened row still carries the old key's verdict; it says nothing about the new text")
         XCTAssertEqual(AppController.keysNeedingCheck(
-            openAIField: "sk-new", anthropicField: "sk-ant",
-            openAIState: .checked(.rejected("no")), anthropicState: .editing), [.openai, .anthropic])
+            fields: VendorKeys(openAI: "sk-new", sarvam: "sk-s", anthropic: "sk-ant"),
+            states: KeyStates(openAI: .checked(.rejected("no")), sarvam: .empty, anthropic: .editing)),
+            [.openai, .sarvam, .anthropic], "in the order Setup lists them")
     }
 
     /// Regression: a new key was checked ("works"), the island collapsed and took the text with it,
     /// and Save wrote the old, rejected key from disk back under the new key's green tick.
     func testAWorksVerdictIsOnlyAboutTheTextItChecked() {
         let saved = KeyFieldState.saved(masked: "…old1")
-        XCTAssertEqual(AppController.verdict(.checked(.valid), forField: "", seeded: saved), saved)
-        XCTAssertEqual(AppController.verdict(.checked(.valid), forField: "", seeded: .empty), .empty)
-        XCTAssertEqual(AppController.verdict(.editing, forField: " ", seeded: saved), saved)
-        XCTAssertEqual(AppController.verdict(.checked(.valid), forField: "sk-new", seeded: saved), .checked(.valid))
+        XCTAssertEqual(AppController.verdict(.checked(.valid), isTyped: false, seeded: saved), saved)
+        XCTAssertEqual(AppController.verdict(.checked(.valid), isTyped: false, seeded: .empty), .empty)
+        XCTAssertEqual(AppController.verdict(.editing, isTyped: false, seeded: saved), saved)
+        XCTAssertEqual(AppController.verdict(.checked(.valid), isTyped: true, seeded: saved), .checked(.valid))
 
         // With no key on disk, a leftover "works" over an empty field must not promise a plan.
         let decision = AppController.setupDecision(
-            openAIField: "", anthropicField: "",
-            openAIState: .checked(.valid), anthropicState: .empty,
+            fields: VendorKeys(), states: KeyStates(openAI: .checked(.valid)),
             configuration: SaathiConfiguration())
-        XCTAssertEqual(decision.openAIKey, "")
+        XCTAssertEqual(decision.keys.openAI, "")
         XCTAssertNotEqual(decision.plan.provider, .openai)
     }
 
+    /// A field with only a stray space in it is an empty field: nothing was typed, so nothing is
+    /// checked and nothing counts as pasted.
+    func testAFieldOfWhitespaceIsNotATypedKey() {
+        XCTAssertEqual(AppController.typed(in: VendorKeys(openAI: "  ", sarvam: "sk-s", anthropic: "\n")), [.sarvam])
+        XCTAssertEqual(AppController.typed(in: VendorKeys()), [])
+    }
+
     func testAcceptedCheckingAndEmptyFieldsNeedNoCheck() {
         XCTAssertEqual(AppController.keysNeedingCheck(
-            openAIField: "sk-new", anthropicField: "sk-ant",
-            openAIState: .checked(.valid), anthropicState: .checking), [])
+            fields: VendorKeys(openAI: "sk-new", anthropic: "sk-ant"),
+            states: KeyStates(openAI: .checked(.valid), anthropic: .checking)), [])
         XCTAssertEqual(AppController.keysNeedingCheck(
-            openAIField: "  ", anthropicField: "",
-            openAIState: .saved(masked: "…old1"), anthropicState: .empty), [])
+            fields: VendorKeys(openAI: "  "), states: KeyStates(openAI: .saved(masked: "…old1"))), [])
     }
 
     func testANonEmptyFieldWinsOverAnyStoredKey() {
@@ -486,6 +683,84 @@
     }
 }
 
+// MARK: - Where it could think
+
+@MainActor
+final class ProviderChoiceTests: XCTestCase {
+
+    func testThePickerOffersEachVendorWithAKeyAndThisMac() {
+        let all = SaathiConfiguration(provider: .sarvam, openaiKey: "o", anthropicKey: "a", sarvamKey: "s")
+        let choices = AppController.providerChoices(for: all)
+        XCTAssertEqual(choices.map(\.kind), [.openai, .sarvam, .anthropic, .local])
+        XCTAssertEqual(choices.map(\.title), ["OpenAI", "Sarvam", "Anthropic", "This Mac"])
+    }
+
+    /// One place to think is nothing to pick from, and the row stays a line of text.
+    func testWithNoKeysThereIsOnlyThisMac() {
+        XCTAssertEqual(AppController.providerChoices(for: SaathiConfiguration()).map(\.kind), [.local])
+    }
+
+    func testTheHostedServiceIsOfferedOnlyWithATokenForIt() {
+        let trial = SaathiConfiguration(provider: .hosted, openaiKey: "o", token: "tok")
+        XCTAssertEqual(AppController.providerChoices(for: trial).map(\.kind), [.openai, .local, .hosted])
+        XCTAssertEqual(
+            AppController.providerChoices(for: SaathiConfiguration(openaiKey: "o")).map(\.kind), [.openai, .local])
+    }
+
+    /// Whatever is in use is always on the list, or the picker would show nothing selected.
+    func testWhatIsInUseIsAlwaysOffered() {
+        XCTAssertEqual(
+            AppController.providerChoices(for: SaathiConfiguration(provider: .openai)).map(\.kind), [.local, .openai])
+        XCTAssertEqual(
+            AppController.providerChoices(for: SaathiConfiguration(provider: .hosted)).map(\.kind), [.local, .hosted])
+    }
+
+    /// A legacy shared key belongs to the provider the file names, here as everywhere in Setup.
+    func testALegacyKeyCountsForTheProviderItWasWrittenFor() {
+        let legacy = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy")
+        XCTAssertEqual(AppController.storedVendors(in: legacy), [.sarvam])
+        XCTAssertEqual(AppController.providerChoices(for: legacy).map(\.kind), [.sarvam, .local])
+    }
+
+    func testTheProviderInUseIsTheOneTheFileNames() {
+        XCTAssertNil(AppController.providerInUse(SaathiConfiguration()), "none named is none chosen")
+        XCTAssertEqual(AppController.providerInUse(SaathiConfiguration(provider: .local)), .local)
+        XCTAssertEqual(AppController.providerInUse(SaathiConfiguration(provider: .hosted, token: "tok")), .hosted)
+        XCTAssertNil(
+            AppController.providerInUse(SaathiConfiguration(provider: .hosted, token: "  ")),
+            "the hosted service with no token is not somewhere to stay")
+    }
+
+    /// Picking This Mac files the shared key under the vendor it was used for, so it is still
+    /// there — and still Sarvam's — when Sarvam is picked again.
+    func testPickingAnotherProviderKeepsALegacyKeyWithItsVendor() {
+        let legacy = SaathiConfiguration(provider: .sarvam, apiKey: "sk-legacy")
+        let plan = SetupPlan.choosing(.local, valid: AppController.storedVendors(in: legacy))
+        var keys = VendorKeys()
+        for vendor in plan.stored { keys[vendor] = legacy.credential(for: vendor) ?? "" }
+        let local = plan.applied(to: legacy, keys: keys)
+        XCTAssertEqual(local.provider, .local)
+        XCTAssertEqual(local.sarvamKey, "sk-legacy")
+        XCTAssertEqual(AppController.storedVendors(in: local), [.sarvam])
+        XCTAssertEqual(AppController.providerChoices(for: local).map(\.kind), [.sarvam, .local])
+    }
+
+    func testTheSarvamSwitchIsOnlyThereWhenItCouldBeSwitched() {
+        XCTAssertTrue(AppController.sarvamSpeechAvailable(
+            for: SaathiConfiguration(provider: .anthropic, anthropicKey: "a", sarvamKey: "s")))
+        XCTAssertTrue(
+            AppController.sarvamSpeechAvailable(for: SaathiConfiguration(sarvamKey: "s")),
+            "a model on this Mac can have Sarvam's ears")
+        XCTAssertFalse(
+            AppController.sarvamSpeechAvailable(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "a")),
+            "no Sarvam key")
+        XCTAssertFalse(
+            AppController.sarvamSpeechAvailable(
+                for: SaathiConfiguration(provider: .openai, openaiKey: "o", sarvamKey: "s")),
+            "the realtime lane carries its own speech")
+    }
+}
+
 // MARK: - Relaunching ourselves
 
 @MainActor
```

- [ ] **Step 3: Run to see them fail.** `swift build --build-tests` → `extra arguments at positions …`, `cannot find 'VendorKeys' in scope`, `value of type 'IslandModel' has no member 'keyStates'`.

- [ ] **Step 4: The plan.** Replace `Sources/SaathiKit/SetupPlan.swift` with:

```swift
//
//  SetupPlan.swift
//  SaathiKit
//
//  What "give me your keys and I will set myself up" actually decides.
//
//  This is a value type with no network, no file system and no clock, so the whole of that promise
//  is covered by unit tests rather than by pasting a key and listening. The panel asks it what to
//  do and then does exactly that; it holds no policy of its own.
//

import Foundation
import SaathiContract

/// One string for each vendor a key can be pasted for: the text in Setup's three fields, and the
/// keys a plan is applied with.
public struct VendorKeys: Equatable, Sendable {
    public var openAI: String
    public var sarvam: String
    public var anthropic: String

    public init(openAI: String = "", sarvam: String = "", anthropic: String = "") {
        self.openAI = openAI
        self.sarvam = sarvam
        self.anthropic = anthropic
    }

    /// By vendor. A provider that takes no key of its own has none here: it reads as empty, and
    /// writing to it does nothing.
    public subscript(kind: ProviderKind) -> String {
        get {
            switch kind {
            case .openai: return openAI
            case .sarvam: return sarvam
            case .anthropic: return anthropic
            case .local, .hosted: return ""
            }
        }
        set {
            switch kind {
            case .openai: openAI = newValue
            case .sarvam: sarvam = newValue
            case .anthropic: anthropic = newValue
            case .local, .hosted: break
            }
        }
    }
}

public struct SetupPlan: Equatable, Sendable {

    /// The vendors a key can be pasted for, in the order Setup lists them.
    public static let vendors: [ProviderKind] = [.openai, .sarvam, .anthropic]

    public let provider: ProviderKind
    public let model: String
    /// Empty on the chain lane, which opens no socket.
    public let voiceModel: String
    public let lane: VoiceLane
    /// Whose ears and mouth a chain-lane turn uses. Sarvam's only when the sentence says so: Setup
    /// never sends a voice anywhere `explanation` has not named.
    public let speech: SpeechEngine
    /// One line, Saathi's voice, saying what it chose and what that means for the learner.
    public let explanation: String
    /// Every vendor whose key was accepted, in Setup's order. All of them are saved.
    public let stored: [ProviderKind]
    /// The vendor whose key looks at the screen when a turn asks about something on it, if there
    /// is one: Anthropic's when it is there, OpenAI's otherwise — the choice `ScreenSight` makes.
    public let eye: ProviderKind?
    /// Keys that were accepted and saved and that nothing will call. Named rather than hidden: a
    /// panel that quietly banks a key lets someone believe it is doing something.
    public let storedButUnused: [ProviderKind]

    /// The decision, from four facts: which keys work, which of them were pasted just now, what is
    /// in use, and whose ears and mouth the file asks for.
    ///
    /// - A key that has just been pasted is a statement of what its owner wants — for the two
    ///   vendors that can carry a conversation end to end. Paste an OpenAI key and Saathi moves to
    ///   OpenAI; paste a Sarvam key and it moves to Sarvam, whatever was there before. Both at
    ///   once is OpenAI, because it is the only one with a duplex realtime socket — the difference
    ///   between a companion that feels instant and one that feels operated.
    /// - With nothing new pasted, what is in use stays in use for as long as it can be used. An
    ///   Anthropic key on its own never moves anyone off a provider they chose: it looks at the
    ///   screen.
    /// - Otherwise the most capable key there is, and this machine when there is none.
    ///
    /// Sarvam's ears and mouth are asked for, not assumed. Arriving at Sarvam asks for them, and
    /// so does pasting its key; arriving anywhere else puts speech back on this Mac. While the
    /// provider stays where it is, what the file says stands — so a configuration that thinks
    /// with Sarvam and listens on this Mac is not quietly turned into one that sends audio, and
    /// one that thinks with Claude and listens through Sarvam is not quietly turned back.
    ///
    /// `current` is the provider written in the file, and nil when none is, or when it is one that
    /// can no longer be used for a reason this type cannot see — hosted with no token.
    public static func make(
        valid: Set<ProviderKind>,
        typed: Set<ProviderKind> = [],
        current: ProviderKind? = nil,
        speech: SpeechEngine = .device
    ) -> SetupPlan {
        let provider = chosen(valid: valid, typed: typed, current: current)
        let arrivedAtSarvam = provider == .sarvam && (provider != current || typed.contains(.sarvam))
        let stayed = provider == current
        return plan(
            for: provider, valid: valid,
            wantsSarvamSpeech: arrivedAtSarvam || (stayed && speech == .sarvam))
    }

    /// The plan for a provider someone picked by hand, with whatever keys there are. Picking
    /// Sarvam is picking it whole; picking anything else puts speech back on this Mac.
    public static func choosing(_ provider: ProviderKind, valid: Set<ProviderKind>) -> SetupPlan {
        plan(for: provider, valid: valid, wantsSarvamSpeech: provider == .sarvam)
    }

    static func chosen(valid: Set<ProviderKind>, typed: Set<ProviderKind>, current: ProviderKind?) -> ProviderKind {
        for talker in [ProviderKind.openai, .sarvam] where typed.contains(talker) && valid.contains(talker) {
            return talker
        }
        // A vendor stays only while its key works. This machine and the hosted service take no
        // key of their own, so there is nothing here to have stopped working.
        if let current, !vendors.contains(current) || valid.contains(current) { return current }
        return vendors.first(where: valid.contains) ?? .local
    }

    private static func plan(for provider: ProviderKind, valid: Set<ProviderKind>, wantsSarvamSpeech: Bool) -> SetupPlan {
        let row = SaathiProvider.of(provider)
        let stored = vendors.filter(valid.contains)
        let eye: ProviderKind? = valid.contains(.anthropic) ? .anthropic : valid.contains(.openai) ? .openai : nil
        // Only on the chain lane — the realtime lane carries its own speech — and only with a key
        // to do it with. Asked for without one, it is this Mac's, and the sentence says so.
        let speech: SpeechEngine = row.voice == .chain && wantsSarvamSpeech && valid.contains(.sarvam) ? .sarvam : .device
        return SetupPlan(
            provider: provider,
            model: row.defaultModel,
            voiceModel: row.defaultVoiceModel,
            lane: row.voice,
            speech: speech,
            explanation: explanation(for: provider, speech: speech, hasKeys: !valid.isEmpty),
            stored: stored,
            eye: eye,
            storedButUnused: stored.filter { key in
                key != provider && key != eye && !(key == .sarvam && speech == .sarvam)
            })
    }

    /// The most consequential sentences in the app: each says where the learner's voice goes.
    private static func explanation(for provider: ProviderKind, speech: SpeechEngine, hasKeys: Bool) -> String {
        let toSarvam = "Your voice leaves this machine as audio, straight to Sarvam — Saathi's servers "
            + "are not in the conversation."
        switch (provider, speech) {
        case (.openai, _):
            return "I will talk with you through OpenAI's realtime voice. Your voice "
                + "leaves this machine as audio, straight to OpenAI — Saathi's servers are not "
                + "in the conversation."
        case (.hosted, _):
            return "I will talk with you through Saathi's hosted service. Your voice leaves this "
                + "machine as audio, to the provider Saathi uses."
        case (.sarvam, .sarvam):
            return "I will listen, think and speak through Sarvam, in the language chosen below. " + toSarvam
        case (.sarvam, .device):
            return "I will listen on this Mac and think with Sarvam. Your voice stays "
                + "here — only the words you said are sent."
        case (.anthropic, .sarvam):
            return "I will listen and speak through Sarvam, in the language chosen below, and think "
                + "with Claude. " + toSarvam
        case (.anthropic, .device):
            return "I will listen on this Mac and think with Claude. Your voice stays "
                + "here — only the words you said are sent."
        case (.local, .sarvam):
            return "I will listen and speak through Sarvam, in the language chosen below, and think "
                + "with a model on this Mac. " + toSarvam
        case (.local, .device):
            return hasKeys
                ? "I will listen and think on this Mac, with a model already running on it — "
                    + "Ollama or LM Studio. Nothing you say leaves it."
                : "No key yet, so I will look for a model already running on this machine. "
                    + "Start Ollama or LM Studio, or add a key above."
        }
    }

    /// Folds this plan and the keys that earned it into a configuration, leaving everything the
    /// person set by hand — a backend URL, an account token — exactly as it was.
    ///
    /// A key is stored only when it validated. Banking a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working, which is a much worse bug to be
    /// handed than "that key was refused". A blank for a vendor that did validate keeps the key
    /// already on disk: blank means nothing was typed, not "forget it".
    ///
    /// The model, the voice model and the voice are the new provider's when the provider changes,
    /// and left alone when it does not — so a model chosen by hand survives a key being replaced,
    /// and a voice chosen for one provider is never sent to another that does not have it.
    public func applied(to existing: SaathiConfiguration, keys: VendorKeys) -> SaathiConfiguration {
        var updated = existing
        if existing.resolvedProvider != provider {
            updated.model = model.isEmpty ? nil : model
            updated.voiceModel = voiceModel.isEmpty ? nil : voiceModel
            updated.voice = nil
        }
        updated.provider = provider
        updated.speech = speech == .device ? nil : speech

        for vendor in stored {
            let key = Self.cleaned(keys[vendor])
            switch vendor {
            case .openai: updated.openaiKey = key ?? existing.openaiKey
            case .sarvam: updated.sarvamKey = key ?? existing.sarvamKey
            case .anthropic: updated.anthropicKey = key ?? existing.anthropicKey
            case .local, .hosted: break
            }
        }
        return updated
    }

    /// A pasted key routinely arrives with a trailing newline, and an untrimmed one is refused in a
    /// way indistinguishable from a wrong key.
    private static func cleaned(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
```

Run: `swift test --filter SetupPlanTests` → passes (the Shell target does not build yet).

- [ ] **Step 5: The model.** `Sources/SaathiShell/IslandModel.swift`:

```diff
--- a/macos/Saathi/Sources/SaathiShell/IslandModel.swift
+++ b/macos/Saathi/Sources/SaathiShell/IslandModel.swift
@@ -34,6 +34,8 @@
         IslandLanguage(tag: "mr", title: "मराठी"),
         IslandLanguage(tag: "kn", title: "ಕನ್ನಡ"),
         IslandLanguage(tag: "ml", title: "മലയാളം"),
+        IslandLanguage(tag: "gu", title: "ગુજરાતી"),
+        IslandLanguage(tag: "pa", title: "ਪੰਜਾਬੀ"),
         IslandLanguage(tag: "es", title: "Español"),
         IslandLanguage(tag: "fr", title: "Français"),
         IslandLanguage(tag: "de", title: "Deutsch"),
@@ -98,6 +100,54 @@
     }
 }
 
+/// Where each of Setup's three key fields has got to.
+public struct KeyStates: Equatable, Sendable {
+    public var openAI: KeyFieldState
+    public var sarvam: KeyFieldState
+    public var anthropic: KeyFieldState
+
+    public init(
+        openAI: KeyFieldState = .empty, sarvam: KeyFieldState = .empty, anthropic: KeyFieldState = .empty
+    ) {
+        self.openAI = openAI
+        self.sarvam = sarvam
+        self.anthropic = anthropic
+    }
+
+    /// By vendor. A provider that takes no key of its own has no field: it reads as empty, and
+    /// writing to it does nothing.
+    public subscript(kind: ProviderKind) -> KeyFieldState {
+        get {
+            switch kind {
+            case .openai: return openAI
+            case .sarvam: return sarvam
+            case .anthropic: return anthropic
+            case .local, .hosted: return .empty
+            }
+        }
+        set {
+            switch kind {
+            case .openai: openAI = newValue
+            case .sarvam: sarvam = newValue
+            case .anthropic: anthropic = newValue
+            case .local, .hosted: break
+            }
+        }
+    }
+}
+
+/// One place Saathi could think, as the picker on the Setup tab offers it.
+public struct IslandProviderChoice: Identifiable, Equatable, Sendable {
+    public let kind: ProviderKind
+    public let title: String
+    public var id: String { kind.rawValue }
+
+    public init(kind: ProviderKind, title: String) {
+        self.kind = kind
+        self.title = title
+    }
+}
+
 /// Everything the Home panel says about Saathi right now.
 @MainActor
 public final class IslandModel: ObservableObject {
@@ -113,14 +163,23 @@
     @Published public var companionVisible = true
     /// Which face of the island is showing.
     @Published public var tab: IslandTab = .home
-    @Published public var openAIKeyState: KeyFieldState = .empty
-    @Published public var anthropicKeyState: KeyFieldState = .empty
+    /// Where the three key fields have got to: OpenAI's, Sarvam's and Anthropic's.
+    @Published public var keyStates = KeyStates()
     /// The plan's one-line explanation of what it chose and what that means.
     @Published public var planExplanation: String = ""
-    /// Says out loud that a stored key is not being used. Empty when every stored key is in play.
-    @Published public var unusedKeyNote: String = ""
+    /// What the stored keys are for, and anything in the way of the plan. Empty when there is
+    /// nothing to add to the sentence above it.
+    @Published public var keysNote: String = ""
     /// The language Saathi speaks, as a BCP-47 tag. Empty means follow this Mac.
     @Published public var language: String = ""
+    /// Where Saathi thinks, and the places it could: each vendor with a key, and this Mac. With
+    /// fewer than two there is nothing to pick, and the row is a line of text.
+    @Published public var provider: ProviderKind = .local
+    @Published public var providerChoices: [IslandProviderChoice] = []
+    /// Whether Sarvam is the ears and the mouth, and whether it could be: a Sarvam key is stored
+    /// and a turn is three steps. The switch is only on show when it could.
+    @Published public var sarvamSpeechOn = false
+    @Published public var sarvamSpeechAvailable = false
     /// The realtime voice's name, and whether a turn is one connection or three steps. Shown on
     /// Home because they are otherwise invisible until you have already started talking.
     @Published public var voiceTitle: String = ""
@@ -186,17 +245,17 @@
     public var onFixPermission: (Permission) -> Void = { _ in }
     public var onToggleCompanion: () -> Void = {}
     public var onQuit: () -> Void = {}
-    /// Ask the vendor whether one key works: which vendor to check, then the live text of *both*
-    /// fields. The other field comes along because a verdict changes the plan, and the plan is
-    /// decided by both keys at once — judging the field that did not change against an empty string
-    /// is how the panel came to promise one thing and Save do another. The panel never validates
-    /// anything itself.
-    public var onCheckKey: (ProviderKind, String, String) -> Void = { _, _, _ in }
-    /// Check any typed key, then save both and reconfigure if every typed key was accepted.
-    public var onSaveKeys: (String, String) -> Void = { _, _ in }
-    /// The Setup tab was built afresh, or a key field was emptied. Any verdict about text that has
-    /// since gone must go with it, and the key on disk earns its own back.
-    public var onKeyFieldsEmpty: (_ openAIField: String, _ anthropicField: String) -> Void = { _, _ in }
+    /// The text in a key field changed — the one named — or the Setup tab was built afresh, which
+    /// names none. Always the live text of *every* field: the plan is decided by all the keys at
+    /// once, and judging the fields that did not change against an empty string is how the panel
+    /// came to promise one thing and Save do another. The panel never validates anything itself.
+    public var onKeyFields: (VendorKeys, _ edited: ProviderKind?) -> Void = { _, _ in }
+    /// Check any typed key, then save them all and reconfigure if every typed key was accepted.
+    public var onSaveKeys: (VendorKeys) -> Void = { _ in }
+    /// Think somewhere else, with the keys that are already saved.
+    public var onChooseProvider: (ProviderKind) -> Void = { _ in }
+    /// Hear and speak through Sarvam, or on this Mac.
+    public var onSarvamSpeech: (Bool) -> Void = { _ in }
     /// Change the language Saathi answers in. Empty means follow this Mac.
     public var onLanguage: (String) -> Void = { _ in }
     /// Relaunch Saathi so a permission grant this process could not pick up takes effect.
```

- [ ] **Step 6: The wording.** `Sources/SaathiShell/AppController+Wording.swift`:

```diff
--- a/macos/Saathi/Sources/SaathiShell/AppController+Wording.swift
+++ b/macos/Saathi/Sources/SaathiShell/AppController+Wording.swift
@@ -2,7 +2,7 @@
 //  AppController+Wording.swift
 //  SaathiShell
 //
-//  What the island and the log say about a configuration, an action or a pair of key fields.
+//  What the island and the log say about a configuration, an action or the three key fields.
 //
 //  Static and pure so the wording can be tested without a window, a session or a key. These are
 //  the sentences that tell someone where their voice goes, which makes them worth pinning down —
@@ -42,6 +42,37 @@
         "\(configuration.resolvedProvider.rawValue) · \(configuration.resolvedModel)"
     }
 
+    /// Everything the island says about a configuration, written onto its model: where it thinks,
+    /// whose voice answers, what leaves the machine, and what the picker and the switch can offer.
+    /// Static, so the Setup tab can be drawn for a configuration with no app behind it.
+    static func describe(_ configuration: SaathiConfiguration, on model: IslandModel) {
+        model.providerTitle = providerTitle(for: configuration)
+        model.privacyLine = privacyLine(for: configuration)
+        model.voiceTitle = voiceTitle(for: configuration)
+        model.laneTitle = configuration.providerRow.voice == .realtime
+            ? "one connection"
+            : "three steps"
+        model.language = configuration.resolvedLanguage
+
+        // The picker and the switch under Voice: where it thinks and where it could, and whether
+        // Sarvam is — or could be — its ears and mouth.
+        model.provider = configuration.resolvedProvider
+        model.providerChoices = providerChoices(for: configuration)
+        model.sarvamSpeechOn = SarvamSpeech.isOn(configuration)
+        model.sarvamSpeechAvailable = sarvamSpeechAvailable(for: configuration)
+
+        // The status pill in the menu-bar band, and the Backend rows on Setup. Two different
+        // questions: the pill says where Saathi is connected on the lane in use, the rows say
+        // whether the hosted backend is set up — which off the hosted lane it need not be.
+        let pill = connectionPill(for: configuration)
+        model.connectionTitle = pill.title
+        model.isConnectionConfigured = pill.isConfigured
+        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
+        model.usesBackend = configuration.providerRow.requiresToken
+        model.isBackendConfigured = !token.isEmpty
+        model.backendTitle = backendTitle(for: configuration)
+    }
+
     /// What the status pill in the band says, and whether it reads as connected.
     struct ConnectionPill: Equatable {
         let title: String
@@ -88,18 +119,57 @@
     static func privacyLine(for configuration: SaathiConfiguration) -> String {
         let row = configuration.providerRow
         if row.voice == .realtime { return "your voice leaves as audio" }
+        // Before the provider's own line: with Sarvam's ears the audio goes whoever does the
+        // thinking, a model on this Mac included.
+        if SarvamSpeech.isOn(configuration) { return "your voice leaves as audio, to Sarvam" }
         return row.sendsDataOffMachine ? "only the transcript is sent" : "stays on this machine"
     }
 
-    /// Says out loud that a key was saved and is not being used. Empty when there is nothing to
-    /// confess — a panel that quietly banks an Anthropic key lets someone believe Claude is
-    /// answering them.
-    static func unusedKeyNote(for plan: SetupPlan) -> String {
-        guard !plan.storedButUnused.isEmpty else { return "" }
-        let names = plan.storedButUnused.map { $0.rawValue.capitalized }.joined(separator: " and ")
-        return "\(names) key saved. Nothing uses it yet."
+    /// Whose voice answers: the realtime voice by name, Sarvam's speaker by name, or this Mac's.
+    static func voiceTitle(for configuration: SaathiConfiguration) -> String {
+        if configuration.providerRow.voice == .realtime {
+            return configuration.resolvedVoice.isEmpty ? "—" : configuration.resolvedVoice
+        }
+        if SarvamSpeech.isOn(configuration) { return "Sarvam · \(SarvamSpeech.speaker(named: configuration.voice))" }
+        return "this Mac's"
     }
 
+    /// A provider as a person would name it.
+    static func vendorName(_ kind: ProviderKind) -> String {
+        switch kind {
+        case .openai: return "OpenAI"
+        case .sarvam: return "Sarvam"
+        case .anthropic: return "Anthropic"
+        case .local: return "This Mac"
+        case .hosted: return "Saathi's service"
+        }
+    }
+
+    /// What the stored keys are for, and what is in the way of the plan — under the sentence, in a
+    /// smaller voice. Empty when there is nothing to add.
+    ///
+    /// It used to say "Anthropic key saved. Nothing uses it yet." about a key `ScreenSight` has
+    /// preferred since the day it was written.
+    static func keysNote(for plan: SetupPlan, language: String) -> String {
+        var sentences: [String] = []
+        if plan.speech == .sarvam, SarvamLanguage.code(for: language) == nil {
+            // Said before it is saved: the session would refuse to start, and this is why.
+            sentences.append(
+                "Sarvam does not hear or speak \(SarvamLanguage.name(of: language)). "
+                + "Choose another language under Voice first.")
+        }
+        if let eye = plan.eye, eye != plan.provider {
+            sentences.append("The \(vendorName(eye)) key looks at the screen when you ask about something on it.")
+        } else if plan.eye == nil, !plan.stored.isEmpty {
+            sentences.append("Nothing here can look at the screen: that takes an OpenAI or an Anthropic key.")
+        }
+        for unused in plan.storedButUnused {
+            let name = vendorName(unused)
+            sentences.append("The \(name) key is saved and not in use. Choose \(name) under Where it thinks to use it.")
+        }
+        return sentences.joined(separator: " ")
+    }
+
     /// Which face the island opens on. Derived from the configuration rather than from a
     /// "has onboarded" flag, so it cannot get out of step with what is actually configured.
     static func openingTab(for configuration: SaathiConfiguration) -> IslandTab {
@@ -123,45 +193,44 @@
     /// is about nothing, and the key that stands in is the one on disk, with the verdict the disk
     /// earns. Without this a new key checked, then lost to a collapse, left "works" beside an empty
     /// field, and Save wrote the old, dead key back under it.
-    static func verdict(_ state: KeyFieldState, forField field: String, seeded: KeyFieldState) -> KeyFieldState {
-        guard field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return state }
+    static func verdict(_ state: KeyFieldState, isTyped: Bool, seeded: KeyFieldState) -> KeyFieldState {
+        guard !isTyped else { return state }
         switch state {
         case .saved, .empty: return state
         case .editing, .checking, .checked: return seeded
         }
     }
 
+    /// The vendors whose field has something in it. Which, not what: a key being typed stays in
+    /// the view, and the plan only ever needs to know that one is there.
+    static func typed(in fields: VendorKeys) -> Set<ProviderKind> {
+        Set(SetupPlan.vendors.filter { !fields[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
+    }
+
     /// The typed keys Save has to check before it can save them: text in the field and no verdict
     /// of "accepted" behind it. A check already in flight is left to land on its own.
-    static func keysNeedingCheck(
-        openAIField: String, anthropicField: String,
-        openAIState: KeyFieldState, anthropicState: KeyFieldState
-    ) -> [ProviderKind] {
-        func needs(_ field: String, _ state: KeyFieldState) -> Bool {
-            guard !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
-            switch state {
+    static func keysNeedingCheck(fields: VendorKeys, states: KeyStates) -> [ProviderKind] {
+        let withText = typed(in: fields)
+        return SetupPlan.vendors.filter { kind in
+            guard withText.contains(kind) else { return false }
+            switch states[kind] {
             case .checked(.valid), .checking: return false
             default: return true
             }
         }
-        var kinds: [ProviderKind] = []
-        if needs(openAIField, openAIState) { kinds.append(.openai) }
-        if needs(anthropicField, anthropicState) { kinds.append(.anthropic) }
-        return kinds
     }
 
-    /// Whether a key counts as usable for `SetupPlan`: a verdict that says so, *and* an effective
-    /// key actually behind it. A `.saved` or `.checked(.valid)` verdict with no effective key
-    /// (nothing on disk, an empty field) must not count.
-    static func isUsable(_ state: KeyFieldState, effectiveKey: String) -> Bool {
-        state.isValid && !effectiveKey.isEmpty
+    /// Whether a key counts as usable for `SetupPlan`: a verdict that says so, *and* a key actually
+    /// behind it. A `.saved` or `.checked(.valid)` verdict with no key (nothing on disk, an empty
+    /// field) must not count.
+    static func isUsable(_ state: KeyFieldState, hasKey: Bool) -> Bool {
+        state.isValid && hasKey
     }
 
-    /// What a Save would do: the plan, and the two keys it would be applied with.
+    /// What a Save would do: the plan, and the keys it would be applied with.
     struct SetupDecision: Equatable {
         let plan: SetupPlan
-        let openAIKey: String
-        let anthropicKey: String
+        let keys: VendorKeys
     }
 
     /// The one place the Setup tab decides anything.
@@ -175,45 +244,59 @@
     /// not just changed to `""` and fall back to `configuration.openaiKey`/`anthropicKey`, so on a
     /// fresh install checking a second key judged the first one against an empty string, flipped the
     /// plan to Anthropic and promised "your voice stays here" — and then Save, which saw both real
-    /// fields, streamed audio to OpenAI. So both callers pass *both* live field values through here
-    /// and read the same answer. The stored fallback is `credential(for:)`, not the vendor field, so
-    /// a legacy shared `apiKey` counts here exactly as it counts everywhere else that asks for a
-    /// key; reading the vendor fields directly made Save see no key at all on a legacy config and
-    /// demote a working install to `.local`.
+    /// fields, streamed audio to OpenAI. So the sentence and Save both come through here, with the
+    /// same three inputs: which fields have text, every verdict, and the file. The stored fallback
+    /// is `credential(for:)`, not the vendor field, so a legacy shared `apiKey` counts here exactly
+    /// as it counts everywhere else that asks for a key; reading the vendor fields directly made
+    /// Save see no key at all on a legacy config and demote a working install to `.local`.
+    static func setupPlan(
+        typed: Set<ProviderKind>, states: KeyStates, configuration: SaathiConfiguration
+    ) -> SetupPlan {
+        let seeded = seededKeyStates(for: configuration)
+        let valid = SetupPlan.vendors.filter { kind in
+            isUsable(
+                verdict(states[kind], isTyped: typed.contains(kind), seeded: seeded[kind]),
+                hasKey: typed.contains(kind) || configuration.credential(for: kind) != nil)
+        }
+        return SetupPlan.make(
+            valid: Set(valid), typed: typed,
+            current: providerInUse(configuration), speech: configuration.resolvedSpeech)
+    }
+
+    /// `setupPlan`, and the keys a Save would write with it: the field's text where there is any,
+    /// the key on disk otherwise.
     static func setupDecision(
-        openAIField: String,
-        anthropicField: String,
-        openAIState: KeyFieldState,
-        anthropicState: KeyFieldState,
-        configuration: SaathiConfiguration
+        fields: VendorKeys, states: KeyStates, configuration: SaathiConfiguration
     ) -> SetupDecision {
-        let openAI = effectiveKey(field: openAIField, stored: configuration.credential(for: .openai))
-        let anthropic = effectiveKey(
-            field: anthropicField, stored: configuration.credential(for: .anthropic))
-        let seeded = seededKeyStates(for: configuration)
+        var keys = VendorKeys()
+        for kind in SetupPlan.vendors {
+            keys[kind] = effectiveKey(field: fields[kind], stored: configuration.credential(for: kind))
+        }
         return SetupDecision(
-            plan: SetupPlan.make(
-                openAIKeyValid: isUsable(
-                    verdict(openAIState, forField: openAIField, seeded: seeded.openAI), effectiveKey: openAI),
-                anthropicKeyValid: isUsable(
-                    verdict(anthropicState, forField: anthropicField, seeded: seeded.anthropic),
-                    effectiveKey: anthropic)),
-            openAIKey: openAI,
-            anthropicKey: anthropic)
+            plan: setupPlan(typed: typed(in: fields), states: states, configuration: configuration),
+            keys: keys)
     }
 
+    /// The provider the file names, for `SetupPlan` to stay on — nil when it names none, or names
+    /// the hosted service with no token to use it with.
+    static func providerInUse(_ configuration: SaathiConfiguration) -> ProviderKind? {
+        guard let provider = configuration.provider else { return nil }
+        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
+        if provider == .hosted, token.isEmpty { return nil }
+        return provider
+    }
+
     /// The verdicts Setup opens with, read from what is on disk so a stored key counts before
     /// anything has been checked this launch.
     ///
     /// A vendor field seeds its own vendor and nothing else. The legacy shared `apiKey` seeds only
     /// the vendor the config actually names as its provider: it is one key that could belong to
-    /// either vendor, and `credential(for:)` hands it to both, so seeding both would have the panel
-    /// assert an Anthropic key exists on a config that never mentioned Anthropic — showing that key
-    /// masked under Anthropic, and lighting up Save with two empty fields. A config with a legacy
-    /// key and no provider named says nothing about whose key it is, so it seeds neither.
-    static func seededKeyStates(
-        for configuration: SaathiConfiguration
-    ) -> (openAI: KeyFieldState, anthropic: KeyFieldState) {
+    /// any vendor, and `credential(for:)` hands it to all of them, so seeding them all would have
+    /// the panel assert an Anthropic key exists on a config that never mentioned Anthropic —
+    /// showing that key masked under Anthropic, and lighting up Save with every field empty. A
+    /// config with a legacy key and no provider named says nothing about whose key it is, so it
+    /// seeds nothing.
+    static func seededKeyStates(for configuration: SaathiConfiguration) -> KeyStates {
         func seed(_ kind: ProviderKind, vendorKey: String?) -> KeyFieldState {
             let vendor = vendorKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
             if !vendor.isEmpty { return .saved(masked: IslandModel.masked(vendor)) }
@@ -221,8 +304,34 @@
                   let legacy = configuration.credential(for: kind) else { return .empty }
             return .saved(masked: IslandModel.masked(legacy))
         }
-        return (
+        return KeyStates(
             openAI: seed(.openai, vendorKey: configuration.openaiKey),
+            sarvam: seed(.sarvam, vendorKey: configuration.sarvamKey),
             anthropic: seed(.anthropic, vendorKey: configuration.anthropicKey))
     }
+
+    // MARK: where it could think
+
+    /// The vendors with a key on disk, as Setup counts them: what `seededKeyStates` shows as saved.
+    static func storedVendors(in configuration: SaathiConfiguration) -> Set<ProviderKind> {
+        let seeded = seededKeyStates(for: configuration)
+        return Set(SetupPlan.vendors.filter { seeded[$0].isValid })
+    }
+
+    /// What the picker under Voice offers: each vendor with a key, this Mac, the hosted service
+    /// when there is a token for it — and whatever is in use now, so the picker can always show it.
+    static func providerChoices(for configuration: SaathiConfiguration) -> [IslandProviderChoice] {
+        let stored = storedVendors(in: configuration)
+        var kinds = SetupPlan.vendors.filter(stored.contains) + [.local]
+        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
+        if !token.isEmpty { kinds.append(.hosted) }
+        if !kinds.contains(configuration.resolvedProvider) { kinds.append(configuration.resolvedProvider) }
+        return kinds.map { IslandProviderChoice(kind: $0, title: vendorName($0)) }
+    }
+
+    /// Whether the switch for Sarvam's ears and mouth has anything to switch: a Sarvam key on
+    /// disk, and a lane that reads `speech` at all.
+    static func sarvamSpeechAvailable(for configuration: SaathiConfiguration) -> Bool {
+        configuration.providerRow.voice == .chain && storedVendors(in: configuration).contains(.sarvam)
+    }
 }
```

- [ ] **Step 7: The panel's actions.** Create `Sources/SaathiShell/AppController+Setup.swift`:

```swift
//
//  AppController+Setup.swift
//  SaathiShell
//
//  What the Setup tab does: saving the keys that were typed, and choosing where Saathi thinks,
//  whose ears it uses and which language it speaks.
//
//  These were closures inside `wireNotch`, written out once for OpenAI and once for Anthropic. A
//  third vendor would have made each a third longer. They are methods here, written once over
//  `SetupPlan.vendors`, and `wireNotch` points the island at them.
//
//  Nothing here decides anything. `setupPlan` — in the wording file, pure and tested — says what a
//  Save would do, and the sentence under the fields is drawn from the same call.
//

import AppKit
import SaathiContract
import SaathiKit

extension AppController {

    /// Points the island's Setup actions at the methods below.
    func wireSetup(into actions: inout IslandActions) {
        actions.onKeyFields = { [weak self] fields, edited in self?.keyFieldsChanged(fields, edited: edited) }
        actions.onSaveKeys = { [weak self] fields in self?.saveKeys(fields) }
        actions.onChooseProvider = { [weak self] kind in self?.chooseProvider(kind) }
        actions.onSarvamSpeech = { [weak self] on in self?.chooseSarvamSpeech(on) }
        actions.onLanguage = { [weak self] tag in self?.chooseLanguage(tag) }
    }

    /// The text in a field changed, or the Setup tab was built afresh with every field empty.
    ///
    /// Which fields have text is remembered — not the text — so that the sentence can be redrawn
    /// when something other than a field changes what a Save would do: the language, the picker,
    /// the switch. Each of those used to be able to redraw it as though every field were empty.
    private func keyFieldsChanged(_ fields: VendorKeys, edited: ProviderKind?) {
        guard let notch else { return }
        typedKeyFields = Self.typed(in: fields)
        var states = notch.model.keyStates
        // Typing invalidates an earlier verdict: a green tick next to a key that has since been
        // edited is the panel lying about what it checked.
        if let edited, typedKeyFields.contains(edited) { states[edited] = .editing }
        // A verdict about text that has gone goes with it — the island collapsing takes every
        // field's text — and the key on disk earns its own back.
        let seeded = Self.seededKeyStates(for: configuration)
        for kind in SetupPlan.vendors {
            states[kind] = Self.verdict(states[kind], isTyped: typedKeyFields.contains(kind), seeded: seeded[kind])
        }
        notch.model.keyStates = states
        refreshPlanExplanation()
    }

    /// Checks whatever was typed and saves it — and switches over — if every typed key was
    /// accepted.
    private func saveKeys(_ fields: VendorKeys) {
        guard let notch else { return }
        // Refused coherently rather than half-applied: without this a second Save during an
        // in-flight reconfigure could still write the file, flip the fields to `.saved` and
        // switch to Home, only to have the reconfigure it raced drop on the floor — leaving
        // disk naming one provider and the island showing another until relaunch.
        guard !voice.isReconfiguring else {
            voice.reportReconfiguring()
            return
        }
        typedKeyFields = Self.typed(in: fields)

        // A key typed but never checked is checked here, and saved only if the vendor accepts
        // it. Save used to stay disabled until Check had been pressed, and a disabled Save
        // looks like a Save that worked — the old key stayed on disk and the voice kept
        // failing with nothing on screen saying why.
        let unchecked = Self.keysNeedingCheck(fields: fields, states: notch.model.keyStates)
        if !unchecked.isEmpty {
            for kind in unchecked { notch.model.keyStates[kind] = .checking }
            Task {
                var allValid = true
                for kind in unchecked {
                    let result = await validator.check(kind, key: fields[kind])
                    if result != .valid { allValid = false }
                    notch.model.keyStates[kind] = .checked(result)
                }
                refreshPlanExplanation()
                // Every typed key now carries a verdict, so this second pass saves or, with a
                // rejection on show under its row, does nothing.
                if allValid { saveKeys(fields) }
            }
            return
        }

        // The same call the sentence under the fields is drawn from, with the same inputs, so
        // what was promised there is what is written here.
        let decision = Self.setupDecision(
            fields: fields, states: notch.model.keyStates, configuration: configuration)
        let updated = decision.plan.applied(to: configuration, keys: decision.keys)
        guard write(updated, orSay: "could not save your keys") else { return }

        // Saved keys come back only as their last four characters; the full key is never put
        // back into a field. Masked from the effective key, not the field, so a retained
        // stored key still shows its real suffix instead of the empty field's generic mask.
        for kind in decision.plan.stored {
            notch.model.keyStates[kind] = .saved(masked: IslandModel.masked(decision.keys[kind]))
        }
        // Going to Home takes the Setup view, and the text in its fields, out of the tree.
        typedKeyFields = []
        notch.model.tab = .home

        Task { await reconfigure(updated) }
    }

    /// The picker under Voice: think somewhere else, with the keys that are already here.
    private func chooseProvider(_ kind: ProviderKind) {
        guard kind != configuration.resolvedProvider, canChangeSetup() else { return }

        let plan = SetupPlan.choosing(kind, valid: Self.storedVendors(in: configuration))
        // The keys as they stand, so a legacy shared key is filed under the vendor it belongs to
        // before the provider that said whose it was changes.
        var keys = VendorKeys()
        for vendor in plan.stored { keys[vendor] = configuration.credential(for: vendor) ?? "" }
        let updated = plan.applied(to: configuration, keys: keys)
        guard write(updated, orSay: "could not save that choice") else { return }

        // Shown at once rather than when the new session is up, so the picker does not sit on the
        // old answer for a second and then jump.
        notch?.model.provider = kind
        Task { await reconfigure(updated) }
    }

    /// The switch under Voice: Sarvam's ears and mouth, or this Mac's.
    private func chooseSarvamSpeech(_ on: Bool) {
        guard on != SarvamSpeech.isOn(configuration), canChangeSetup() else { return }
        var updated = configuration
        updated.speech = on ? .sarvam : nil
        guard write(updated, orSay: "could not save that choice") else { return }
        notch?.model.sarvamSpeechOn = on
        Task { await reconfigure(updated) }
    }

    /// The language Saathi answers in — and, with Sarvam's speech, the one it listens and speaks in.
    private func chooseLanguage(_ tag: String) {
        guard canChangeSetup() else { return }
        var updated = configuration
        updated.language = tag.isEmpty ? nil : tag
        guard write(updated, orSay: "could not save the language") else { return }
        notch?.model.language = tag
        // The language is baked into the session's instructions — and into Sarvam's ears — so it
        // only takes effect on a fresh session: the same reconfigure a saved key goes through.
        Task { await reconfigure(updated) }
    }

    /// False, and said out loud, while a reconfigure is under way. The model is left alone, so a
    /// picker or a switch goes back to what is true rather than showing a choice that was not made.
    private func canChangeSetup() -> Bool {
        guard voice.isReconfiguring else { return true }
        voice.reportReconfiguring()
        return false
    }

    /// The plan changes as each check lands, so the sentence under the fields follows it rather
    /// than appearing only after a save. Someone should be able to see what they are about to get.
    ///
    /// Drawn from `typedKeyFields` — which fields have text right now — the verdicts, and the
    /// file: the three things Save decides from.
    func refreshPlanExplanation() {
        guard let notch else { return }
        let plan = Self.setupPlan(
            typed: typedKeyFields, states: notch.model.keyStates, configuration: configuration)
        notch.model.planExplanation = plan.explanation
        notch.model.keysNote = Self.keysNote(for: plan, language: configuration.resolvedLanguage)
    }

    private func write(_ updated: SaathiConfiguration, orSay failure: String) -> Bool {
        do {
            try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
            return true
        } catch {
            handle(.failure("\(failure): \(error.localizedDescription)"))
            return false
        }
    }
}
```

and take the closures it replaces out of `Sources/SaathiShell/AppController.swift`:

```diff
--- a/macos/Saathi/Sources/SaathiShell/AppController.swift
+++ b/macos/Saathi/Sources/SaathiShell/AppController.swift
@@ -19,7 +19,10 @@
     var configuration: SaathiConfiguration
     let data: MascotData
     private let color: MascotColor
-    private let validator = KeyValidator()
+    let validator = KeyValidator()
+    /// Which of Setup's key fields have text in them right now. Which, not what: a key being typed
+    /// stays in the view. See `AppController+Setup.swift`.
+    var typedKeyFields: Set<ProviderKind> = []
     private var machine: CompanionStateMachine
     private var shown: CompanionState = .idle
 
@@ -240,23 +243,7 @@
     /// every reconfigure, so the Home tab can never describe a provider that is no longer in use.
     func applyConfigurationToIsland() {
         guard let notch else { return }
-        notch.model.providerTitle = Self.providerTitle(for: configuration)
-        notch.model.privacyLine = Self.privacyLine(for: configuration)
-        notch.model.voiceTitle = configuration.resolvedVoice.isEmpty ? "—" : configuration.resolvedVoice
-        notch.model.laneTitle = configuration.providerRow.voice == .realtime
-            ? "one connection"
-            : "three steps"
-
-        // The status pill in the menu-bar band, and the Backend rows on Setup. Two different
-        // questions: the pill says where Saathi is connected on the lane in use, the rows say
-        // whether the hosted backend is set up — which off the hosted lane it need not be.
-        let pill = Self.connectionPill(for: configuration)
-        notch.model.connectionTitle = pill.title
-        notch.model.isConnectionConfigured = pill.isConfigured
-        let token = (configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
-        notch.model.usesBackend = configuration.providerRow.requiresToken
-        notch.model.isBackendConfigured = !token.isEmpty
-        notch.model.backendTitle = Self.backendTitle(for: configuration)
+        Self.describe(configuration, on: notch.model)
 
         // Neither integration exists in Saathi yet, so both draw in their real "not configured"
         // state. They are a list rather than two hand-written tiles so that wiring one up later is
@@ -269,6 +256,10 @@
             let launched = configuration
             notch.model.skills = SkillLibraryStore(configuration: { [weak self] in self?.configuration ?? launched })
         }
+
+        // Last, and every time: what a Save would do depends on the file, and the file is what
+        // has just changed.
+        refreshPlanExplanation()
     }
 
     // MARK: hold to talk
@@ -468,19 +459,14 @@
     /// one place that opens the provider alert.
     private func wireNotch() {
         guard let notch else { return }
-        applyConfigurationToIsland()
         notch.model.companionVisible = true
         notch.model.tab = Self.openingTab(for: configuration)
-        notch.model.language = configuration.resolvedLanguage
-        // Seed both verdicts from what is already on disk — otherwise every launch shows `.empty`
-        // regardless of what is stored, and the `isValid && !effectiveKey.isEmpty` gate never sees
-        // a stored key as valid. Only for a vendor the config actually names; see `seededKeyStates`.
-        let seeded = Self.seededKeyStates(for: configuration)
-        notch.model.openAIKeyState = seeded.openAI
-        notch.model.anthropicKeyState = seeded.anthropic
-        if notch.model.tab == .setup {
-            refreshPlanExplanation()
-        }
+        // The verdicts are seeded from what is already on disk — otherwise every launch shows
+        // `.empty` regardless of what is stored, and a stored key never counts as one. Only for a
+        // vendor the config actually names; see `seededKeyStates`. Before the island is filled in,
+        // because the sentence under the fields is drawn from them.
+        notch.model.keyStates = Self.seededKeyStates(for: configuration)
+        applyConfigurationToIsland()
 
         var actions = IslandActions()
         actions.onTalk = menu.onTalk
@@ -540,156 +526,10 @@
             // so this literal is nonisolated and `Task {}` is a cross-actor hop — safe only because
             // `AppRelauncher.relaunch` is itself `@MainActor`.
             Task { await AppRelauncher.relaunch(bundleURL: Bundle.main.bundleURL) }
-        }
-        // Both fields arrive, not just the one being checked: the verdict that lands changes the
-        // plan, and the plan is decided by both keys at once. See `setupDecision`.
-        actions.onCheckKey = { [weak self] kind, openAIField, anthropicField in
-            guard let self, let notch = self.notch else { return }
-            let key: String
-            switch kind {
-            case .openai:
-                key = openAIField
-                notch.model.openAIKeyState = .checking
-            case .anthropic:
-                key = anthropicField
-                notch.model.anthropicKeyState = .checking
-            default: return
-            }
-            Task {
-                let result = await self.validator.check(kind, key: key)
-                await MainActor.run {
-                    switch kind {
-                    case .openai: notch.model.openAIKeyState = .checked(result)
-                    case .anthropic: notch.model.anthropicKeyState = .checked(result)
-                    default: return
-                    }
-                    self.refreshPlanExplanation(
-                        openAIField: openAIField, anthropicField: anthropicField)
-                }
-            }
-        }
-
-        actions.onKeyFieldsEmpty = { [weak self] openAIField, anthropicField in
-            guard let self, let notch = self.notch else { return }
-            let seeded = Self.seededKeyStates(for: self.configuration)
-            notch.model.openAIKeyState = Self.verdict(
-                notch.model.openAIKeyState, forField: openAIField, seeded: seeded.openAI)
-            notch.model.anthropicKeyState = Self.verdict(
-                notch.model.anthropicKeyState, forField: anthropicField, seeded: seeded.anthropic)
-            self.refreshPlanExplanation(openAIField: openAIField, anthropicField: anthropicField)
-        }
-
-        actions.onLanguage = { [weak self] tag in
-            guard let self, let notch = self.notch else { return }
-            notch.model.language = tag
-            var updated = self.configuration
-            updated.language = tag.isEmpty ? nil : tag
-            do {
-                try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
-            } catch {
-                self.handle(.failure("could not save the language: \(error.localizedDescription)"))
-                return
-            }
-            // The language is baked into the session's instructions, so it only takes effect on a
-            // fresh session — the same reconfigure a saved key goes through.
-            Task { await self.reconfigure(updated) }
         }
+        // Keys, the picker, the switch and the language: `AppController+Setup.swift`.
+        wireSetup(into: &actions)
 
-        actions.onSaveKeys = { [weak self] openAIKey, anthropicKey in
-            guard let self, let notch = self.notch else { return }
-            // Refused coherently rather than half-applied: without this a second Save during an
-            // in-flight reconfigure could still write the file, flip the fields to `.saved` and
-            // switch to Home, only to have the reconfigure it raced drop on the floor — leaving
-            // disk naming one provider and the island showing another until relaunch.
-            guard !self.voice.isReconfiguring else {
-                self.voice.reportReconfiguring()
-                return
-            }
-
-            // A key typed but never Checked is checked here, and saved only if the vendor accepts
-            // it. Save used to stay disabled until Check had been pressed, and a disabled Save
-            // looks like a Save that worked — the old key stayed on disk and the voice kept
-            // failing with nothing on screen saying why.
-            let unchecked = Self.keysNeedingCheck(
-                openAIField: openAIKey, anthropicField: anthropicKey,
-                openAIState: notch.model.openAIKeyState, anthropicState: notch.model.anthropicKeyState)
-            if !unchecked.isEmpty {
-                for kind in unchecked {
-                    if kind == .openai { notch.model.openAIKeyState = .checking }
-                    else { notch.model.anthropicKeyState = .checking }
-                }
-                Task {
-                    var allValid = true
-                    for kind in unchecked {
-                        let result = await self.validator.check(kind, key: kind == .openai ? openAIKey : anthropicKey)
-                        if result != .valid { allValid = false }
-                        if kind == .openai { notch.model.openAIKeyState = .checked(result) }
-                        else { notch.model.anthropicKeyState = .checked(result) }
-                    }
-                    self.refreshPlanExplanation(openAIField: openAIKey, anthropicField: anthropicKey)
-                    // Every typed key now carries a verdict, so this second pass saves or, with a
-                    // rejection on show under its row, does nothing.
-                    if allValid { notch.actions.onSaveKeys(openAIKey, anthropicKey) }
-                }
-                return
-            }
-
-            // The same call the sentence under the fields is drawn from, with the same inputs, so
-            // what was promised there is what is written here.
-            let decision = Self.setupDecision(
-                openAIField: openAIKey,
-                anthropicField: anthropicKey,
-                openAIState: notch.model.openAIKeyState,
-                anthropicState: notch.model.anthropicKeyState,
-                configuration: self.configuration)
-            let plan = decision.plan
-            let updated = plan.applied(
-                to: self.configuration,
-                openAIKey: decision.openAIKey,
-                anthropicKey: decision.anthropicKey)
-
-            do {
-                try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
-            } catch {
-                self.handle(.failure("could not save your keys: \(error.localizedDescription)"))
-                return
-            }
-
-            // Saved keys come back only as their last four characters; the full key is never put
-            // back into a field. Masked from the effective key, not the field, so a retained
-            // stored key still shows its real suffix instead of the empty field's generic mask.
-            if plan.provider == .openai || plan.storedButUnused.contains(.openai) {
-                notch.model.openAIKeyState = .saved(masked: IslandModel.masked(decision.openAIKey))
-            }
-            if plan.provider == .anthropic || plan.storedButUnused.contains(.anthropic) {
-                notch.model.anthropicKeyState = .saved(masked: IslandModel.masked(decision.anthropicKey))
-            }
-            notch.model.planExplanation = plan.explanation
-            notch.model.unusedKeyNote = Self.unusedKeyNote(for: plan)
-            notch.model.tab = .home
-
-            Task { await self.reconfigure(updated) }
-        }
-
         notch.actions = actions
     }
-
-    /// The plan changes as each check lands, so the sentence under the fields follows it rather than
-    /// appearing only after a save. Someone should be able to see what they are about to get.
-    ///
-    /// `openAIField`/`anthropicField` are the live text of *both* fields, as the panel holds them
-    /// right now — not just the one that changed. Empty means the field really is empty, and then
-    /// the key on disk stands in. Both default to empty for the one call that has no panel behind it
-    /// yet: the seed from `wireNotch`, before the Setup view has been built.
-    private func refreshPlanExplanation(openAIField: String = "", anthropicField: String = "") {
-        guard let notch else { return }
-        let decision = Self.setupDecision(
-            openAIField: openAIField,
-            anthropicField: anthropicField,
-            openAIState: notch.model.openAIKeyState,
-            anthropicState: notch.model.anthropicKeyState,
-            configuration: configuration)
-        notch.model.planExplanation = decision.plan.explanation
-        notch.model.unusedKeyNote = Self.unusedKeyNote(for: decision.plan)
-    }
 }
```

- [ ] **Step 8: The view.** `Sources/SaathiShell/IslandSetupView.swift`:

```diff
--- a/macos/Saathi/Sources/SaathiShell/IslandSetupView.swift
+++ b/macos/Saathi/Sources/SaathiShell/IslandSetupView.swift
@@ -6,7 +6,7 @@
 //  of titled sections, each a rounded card of rows, with one row idiom (icon, title, value) and
 //  three variants of it (a switch, a tappable row with a chevron, a key field).
 //
-//  The two keys are rows here rather than a screen of their own. They were a panel with two big
+//  The keys are rows here rather than a screen of their own. They were a panel with two big
 //  fields and a Save button, which is a different kind of surface from everything else Saathi shows
 //  about itself — and it meant the one place that says where your voice goes was somewhere you had
 //  to leave the settings to find.
@@ -28,13 +28,11 @@
 
     /// Held here rather than in the model: a key being typed is not application state, and keeping
     /// it out of the observable object means it is never published to anything else.
-    @State private var openAIKey = ""
-    @State private var anthropicKey = ""
+    @State private var keys = VendorKeys()
     /// Save is the only button: it checks whatever was typed and saves it if the vendor accepts it.
     /// Not while a check is in flight — its verdict is about to decide.
     private func canSave(_ kind: ProviderKind) -> Bool {
-        let field = kind == .openai ? openAIKey : anthropicKey
-        return !state(of: kind).isBusy && !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
+        !model.keyStates[kind].isBusy && !keys[kind].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
     }
 
     private var home: String { NSHomeDirectory() }
@@ -56,7 +54,7 @@
         // The fields are view-local and start empty every time this is built — the island
         // collapsing tears it down — so a "works" left over from before is about a key no longer
         // in any field.
-        .onAppear { actions.onKeyFieldsEmpty(openAIKey, anthropicKey) }
+        .onAppear { actions.onKeyFields(keys, nil) }
     }
 
     // MARK: - Keys
@@ -69,15 +67,19 @@
                 systemImage: "key.fill",
                 title: "OpenAI",
                 detail: "voice and thinking",
-                text: $openAIKey,
-                state: model.openAIKeyState,
+                text: $keys.openAI,
                 kind: .openai)
             keyRow(
+                systemImage: "globe.asia.australia",
+                title: "Sarvam",
+                detail: "Indian languages, heard and spoken",
+                text: $keys.sarvam,
+                kind: .sarvam)
+            keyRow(
                 systemImage: "key",
                 title: "Anthropic",
                 detail: "looking at the screen",
-                text: $anthropicKey,
-                state: model.anthropicKeyState,
+                text: $keys.anthropic,
                 kind: .anthropic)
 
             // The sentence under the fields is the save it promises: what Saathi will become if
@@ -85,8 +87,8 @@
             if !model.planExplanation.isEmpty {
                 noteRow(model.planExplanation, emphasised: true)
             }
-            if !model.unusedKeyNote.isEmpty {
-                noteRow(model.unusedKeyNote, emphasised: false)
+            if !model.keysNote.isEmpty {
+                noteRow(model.keysNote, emphasised: false)
             }
 
         }
@@ -131,10 +133,34 @@
         section("VOICE") {
             // The language row is a setting in the same sense the rest are: something Saathi would
             // otherwise guess, and guessed wrong loudly enough to be reported.
-            pickerRow(systemImage: "character.bubble", title: "Language", detail: "what it answers in")
+            pickerRow(
+                systemImage: "character.bubble",
+                title: "Language",
+                detail: model.sarvamSpeechOn ? "what it hears and answers in" : "what it answers in",
+                selection: Binding(get: { model.language }, set: { actions.onLanguage($0) }),
+                options: IslandLanguage.all.map { ($0.tag, $0.title) })
+            // Only where it could be switched: a Sarvam key is saved, and a turn is three steps.
+            // The detail is the whole of what turning it on means.
+            if model.sarvamSpeechAvailable {
+                toggleRow(
+                    systemImage: "ear",
+                    title: "Hear and speak through Sarvam",
+                    detail: "Your voice leaves this Mac as audio, to Sarvam",
+                    isOn: Binding(get: { model.sarvamSpeechOn }, set: { actions.onSarvamSpeech($0) }))
+            }
             settingRow(systemImage: "waveform", title: "Voice", value: model.voiceTitle.isEmpty ? "—" : model.voiceTitle)
             settingRow(systemImage: "arrow.left.arrow.right", title: "A turn", value: model.laneTitle)
-            settingRow(systemImage: "brain", title: "Where it thinks", value: model.providerTitle)
+            // A picker once there is more than one place it could think; a line of text until then.
+            if model.providerChoices.count > 1 {
+                pickerRow(
+                    systemImage: "brain",
+                    title: "Where it thinks",
+                    detail: model.providerTitle,
+                    selection: Binding(get: { model.provider }, set: { actions.onChooseProvider($0) }),
+                    options: model.providerChoices.map { ($0.kind, $0.title) })
+            } else {
+                settingRow(systemImage: "brain", title: "Where it thinks", value: model.providerTitle)
+            }
             settingRow(systemImage: "lock.shield", title: "Your voice", value: model.privacyLine)
             settingRow(systemImage: "keyboard", title: "Talk shortcut", value: "hold ⌃ control + ⌥ option")
         }
@@ -279,8 +305,14 @@
         .pointerCursor()
     }
 
-    /// The language picker, wearing the row idiom so it does not read as a stray control.
-    private func pickerRow(systemImage: String, title: String, detail: String) -> some View {
+    /// A picker, wearing the row idiom so it does not read as a stray control.
+    private func pickerRow<Tag: Hashable>(
+        systemImage: String,
+        title: String,
+        detail: String,
+        selection: Binding<Tag>,
+        options: [(tag: Tag, title: String)]
+    ) -> some View {
         HStack {
             Image(systemName: systemImage).font(.system(size: 12)).foregroundColor(Color.white.opacity(0.6)).frame(width: 18)
             VStack(alignment: .leading, spacing: 1) {
@@ -288,9 +320,9 @@
                 Text(detail).font(.system(size: 10)).foregroundColor(Color.white.opacity(0.5))
             }
             Spacer()
-            Picker("", selection: Binding(get: { model.language }, set: { actions.onLanguage($0) })) {
-                ForEach(IslandLanguage.all) { language in
-                    Text(language.title).tag(language.tag)
+            Picker("", selection: selection) {
+                ForEach(options.indices, id: \.self) { index in
+                    Text(options[index].title).tag(options[index].tag)
                 }
             }
             .labelsHidden()
@@ -312,12 +344,12 @@
         title: String,
         detail: String,
         text: Binding<String>,
-        state: KeyFieldState,
         kind: ProviderKind
     ) -> some View {
+        let state = model.keyStates[kind]
         let save = {
             guard canSave(kind) else { return }
-            actions.onSaveKeys(openAIKey, anthropicKey)
+            actions.onSaveKeys(keys)
         }
         return VStack(alignment: .leading, spacing: 4) {
             HStack {
@@ -334,15 +366,11 @@
                     .padding(.vertical, 5)
                     .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                     .onSubmit(save)
-                    .onChange(of: text.wrappedValue) { value in
-                        // Typing invalidates an earlier verdict: a green tick next to a key that has
-                        // since been edited is the panel lying about what it checked. Emptying the
-                        // field puts back the verdict the key on disk earns.
-                        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
-                            actions.onKeyFieldsEmpty(openAIKey, anthropicKey)
-                        } else {
-                            setState(kind, .editing)
-                        }
+                    .onChange(of: text.wrappedValue) { _ in
+                        // Every change is reported, with every field: typing invalidates an earlier
+                        // verdict, emptying a field puts back the one the key on disk earns, and
+                        // either changes what the sentence below has to say.
+                        actions.onKeyFields(keys, kind)
                     }
 
                 Button(action: save) {
@@ -379,14 +407,6 @@
         }
     }
 
-    private func state(of kind: ProviderKind) -> KeyFieldState {
-        switch kind {
-        case .openai: return model.openAIKeyState
-        case .anthropic: return model.anthropicKeyState
-        default: return .empty
-        }
-    }
-
     private func noteRow(_ text: String, emphasised: Bool) -> some View {
         HStack(alignment: .top) {
             Image(systemName: emphasised ? "arrow.turn.down.right" : "info.circle")
@@ -407,14 +427,6 @@
         .padding(.vertical, 10)
     }
 
-    private func setState(_ kind: ProviderKind, _ state: KeyFieldState) {
-        switch kind {
-        case .openai: model.openAIKeyState = state
-        case .anthropic: model.anthropicKeyState = state
-        default: break
-        }
-    }
-
     @ViewBuilder
     private func verdict(for state: KeyFieldState) -> some View {
         switch state {
```

- [ ] **Step 9: Run to see them pass.** `swift test` → every suite passes.

- [ ] **Step 10: Look at it.** Create `Tests/SaathiShellTests/IslandSetupSnapshotTests.swift`:

```swift
//
//  IslandSetupSnapshotTests.swift
//  SaathiShellTests
//
//  The Setup tab, drawn to a PNG, for eyes rather than assertions: the three key rows, the
//  sentence under them, the note, the picker and the switch. Opt-in, like the first-run cards:
//
//      SAATHI_SNAPSHOTS=/some/dir swift test --filter IslandSetupSnapshotTests
//
//  Nothing is put on screen. The view is laid out in an offscreen hosting view, tall enough that
//  nothing has to be scrolled to, over the island's own black. The model is filled by the same
//  static wording the app uses, so what is drawn is what would be said.
//

import AppKit
import SwiftUI
import XCTest
import SaathiContract
import SaathiKit
@testable import SaathiShell

@MainActor
final class IslandSetupSnapshotTests: XCTestCase {

    private struct Shot {
        let name: String
        let configuration: SaathiConfiguration
    }

    func testDrawTheSetupTab() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SAATHI_SNAPSHOTS"], !directory.isEmpty else {
            throw XCTSkip("set SAATHI_SNAPSHOTS=<dir> to draw the Setup tab")
        }
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // None of these is a key: they are shapes with four characters on the end to mask.
        let openAI = "sk-openai-not-a-key-u6MA"
        let anthropic = "sk-ant-not-a-key-9xQ2"
        let sarvam = "sk_sarvam_not_a_key_Lm4t"
        let shots = [
            Shot(name: "setup-1-fresh", configuration: SaathiConfiguration()),
            Shot(name: "setup-2-openai", configuration: SaathiConfiguration(provider: .openai, openaiKey: openAI)),
            Shot(name: "setup-3-sarvam-heard-and-spoken", configuration: SaathiConfiguration(
                provider: .sarvam, openaiKey: openAI, anthropicKey: anthropic, sarvamKey: sarvam,
                speech: .sarvam, language: "ml")),
            Shot(name: "setup-4-claude-with-sarvams-ears", configuration: SaathiConfiguration(
                provider: .anthropic, anthropicKey: anthropic, sarvamKey: sarvam, speech: .sarvam, language: "hi")),
            Shot(name: "setup-5-sarvam-thinking-only", configuration: SaathiConfiguration(
                provider: .sarvam, apiKey: sarvam, language: "hi")),
            Shot(name: "setup-6-sarvam-in-french", configuration: SaathiConfiguration(
                provider: .sarvam, sarvamKey: sarvam, speech: .sarvam, language: "fr")),
        ]

        let size = CGSize(width: NotchPanel.openWidth, height: 1240)
        for shot in shots {
            let model = IslandModel()
            model.tab = .setup
            model.keyStates = AppController.seededKeyStates(for: shot.configuration)
            AppController.describe(shot.configuration, on: model)
            let plan = AppController.setupPlan(typed: [], states: model.keyStates, configuration: shot.configuration)
            model.planExplanation = plan.explanation
            model.keysNote = AppController.keysNote(for: plan, language: shot.configuration.resolvedLanguage)
            model.permissions = Dictionary(uniqueKeysWithValues: Permission.allCases.map { ($0, PermissionStatus.granted) })
            model.lastYouSaid = "ഇത് എന്താണ്?"
            model.lastSaathiSaid = "ഇത് ഒരു സ്പ്രെഡ്ഷീറ്റ് ആണ്."

            let staged = IslandSetupView(display: IslandDisplay(), model: model, actions: IslandActions())
                .padding(.top, 16)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color.black)
                .preferredColorScheme(.dark)

            let hosting = NSHostingView(rootView: staged)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 60_000_000)
            hosting.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("\(shot.name).png"))
        }
    }
}
```

Run: `SAATHI_SNAPSHOTS=<scratchpad>/setup swift test --filter IslandSetupSnapshotTests`, then open the PNGs: three key rows, the sentence, the note, the picker and the switch. Nothing is asserted; this step is a person's — or a model's — eyes.

- [ ] **Step 11: Commit** — "Setup takes a Sarvam key, moves to the key you just pasted, and lets you choose where Saathi thinks".

---

### Task 11: The app speaks with the companion's voice

**Files:**
- Modify: `Sources/SaathiShell/AppController.swift`, `Tests/SaathiShellTests/OnboardingCoordinatorTests.swift`

**Interfaces:**
- Consumes: `CompanionVoice(configuration:)`, `.apply(_:scripted:)`, `.reportFailures(to:)`, `CompanionVoice.deviceSettings(for:scripted:)` (Task 7).
- Produces: `AppController.speaker` wraps a `CompanionVoice`; `applySpeechSettings(scripted:)` and `reconfigure` apply the configuration to it; a line Sarvam could not speak becomes `.failure(message)` on the island and in the log. `AppController.speechSettings(for:scripted:)` is gone: it is `CompanionVoice.deviceSettings(for:scripted:)`.

- [ ] **Step 1: Point the one test that named the old function at the new one.** In `OnboardingCoordinatorTests.swift`, the two assertions on `AppController.speechSettings(for: chosen, scripted:)` become:

```swift
        XCTAssertEqual(CompanionVoice.deviceSettings(for: chosen, scripted: true), SpeechSettings(language: "en-US", pace: .slow))
        XCTAssertEqual(CompanionVoice.deviceSettings(for: chosen, scripted: false), SpeechSettings(language: "ta-IN", pace: .slow))
```

(The behaviour itself — which voice says a line, and that a scripted line is never Sarvam's — is pinned in Task 7's `CompanionVoiceTests`, against fakes.)

- [ ] **Step 2: Implement.** `Sources/SaathiShell/AppController.swift`:

```diff
--- a/macos/Saathi/Sources/SaathiShell/AppController.swift
+++ b/macos/Saathi/Sources/SaathiShell/AppController.swift
@@ -30,8 +30,9 @@
     let notch: NotchPanel?
     let menu: MenuBarController
 
-    /// The voice underneath `speaker`, kept so its language and pace can follow the configuration.
-    private let systemSpeaker: SystemSpeaker
+    /// The voice underneath `speaker` — this Mac's, or Sarvam's when the configuration asks for
+    /// it — kept so it can follow the configuration as that changes.
+    private let companionVoice: CompanionVoice
     var speaker: ObservedSpeaker!
     private var performer: ActionPerformer!
     /// The voice session's whole life — start, turns, reconfigure, quit. See `VoiceConductor`.
@@ -73,10 +74,15 @@
         }
         menu = MenuBarController(icon: MenuBarIcon.image(data: data), installStatusItem: true)
 
-        systemSpeaker = SystemSpeaker(settings: SpeechSettings(configuration))
-        speaker = ObservedSpeaker(systemSpeaker) { [weak self] speaking in
+        companionVoice = CompanionVoice(configuration: configuration)
+        speaker = ObservedSpeaker(companionVoice) { [weak self] speaking in
             Task { @MainActor in self?.handle(.speakingChanged(speaking)) }
         }
+        // When Sarvam cannot speak a line this Mac's voice has already taken it; this is the
+        // island and the log being told why the voice changed.
+        companionVoice.reportFailures { [weak self] message in
+            Task { @MainActor in self?.handle(.failure(message)) }
+        }
         performer = ActionPerformer(speaker: speaker, urlOpener: SystemUrlOpener())
         let speaker = self.speaker!
         let performer = self.performer!
@@ -212,17 +218,11 @@
         ticker = timer
     }
 
-    /// `scripted` is first run: its lines are written in English, so they are read by an English
-    /// voice whatever language was just chosen — a Tamil synthesiser reading English sentences is
-    /// the same noise as the reverse. The pace still follows at once.
+    /// `scripted` is first run: its lines are written in English, so they are read by this Mac's
+    /// English voice whatever language — and whoever's voice — was just chosen. The pace still
+    /// follows at once. See `CompanionVoice.deviceSettings`.
     func applySpeechSettings(scripted: Bool = false) {
-        systemSpeaker.apply(Self.speechSettings(for: configuration, scripted: scripted))
-    }
-
-    static func speechSettings(for configuration: SaathiConfiguration, scripted: Bool) -> SpeechSettings {
-        var settings = SpeechSettings(configuration)
-        if scripted { settings.language = "en-US" }
-        return settings
+        companionVoice.apply(configuration, scripted: scripted)
     }
 
     // MARK: voice
@@ -235,7 +235,7 @@
         handsFree = false
         notch?.model.isAlwaysListening = false
         configuration = updated
-        systemSpeaker.apply(SpeechSettings(updated))
+        companionVoice.apply(updated)
         applyConfigurationToIsland()
     }
```

- [ ] **Step 3: Run.** `swift test` → all pass.

- [ ] **Step 4: Commit** — "The app's one voice is Sarvam's when Sarvam's was asked for".

---

### Task 12: `saathi sarvam`

**Files:**
- Create: `Sources/SaathiKit/SarvamSelfTest.swift`
- Modify: `Sources/saathi/main.swift`
- Test: `Tests/SaathiKitTests/SarvamSelfTestTests.swift`

**Interfaces:**
- Consumes: `KeyValidator` (Task 2), `SarvamClient` (Task 4), `ChainVoiceSession.completionRequest`, `.message(in:)`, `.toolCalls(in:)` (Task 5), `SarvamSpeech.speaker(named:)`, `CompanionVoice`, `PlayerAudioOutput` (Task 7), `WaveFile.seconds` (Task 3).
- Produces: `struct SarvamSelfTest { init(configuration:urlSession:); func run(onClip:) async -> [Line]; static func render(_:) -> String; struct Line { step, passed, detail } }`; CLI command `saathi sarvam [--play]`; the CLI's speaker is a `CompanionVoice`.

- [ ] **Step 1: Write the failing tests.** Create `Tests/SaathiKitTests/SarvamSelfTestTests.swift`:

```swift
//
//  SarvamSelfTestTests.swift
//  SaathiKitTests
//
//  `saathi sarvam`, against a script: the four requests it makes, in order, and that each line says
//  what came back or exactly what refused. The command itself is for a real key; this is so that
//  the day someone runs it, a failure is Sarvam's and not the command's.
//

import Foundation
import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class SarvamSelfTestTests: XCTestCase {

    private let clip = WaveFile.wrap(pcm16: Data(count: 48_000), sampleRate: 24_000)   // one second

    private var keyAccepted: StubHTTP.Reply {
        .json(["error": ["message": "model is required", "code": "invalid_request_error"]], status: 400)
    }
    private var audio: StubHTTP.Reply { .json(["audios": [clip.base64EncodedString()]]) }
    private func heard(_ text: String) -> StubHTTP.Reply { .json(["transcript": text]) }
    private func said(_ text: String) -> StubHTTP.Reply {
        .json(["choices": [["message": ["role": "assistant", "content": text]]]])
    }

    private func run(_ configuration: SaathiConfiguration, _ replies: StubHTTP.Reply...) async -> [SarvamSelfTest.Line] {
        await SarvamSelfTest(configuration: configuration, urlSession: StubHTTP.session(replies)).run()
    }

    func testWithEverythingWorkingItSaysSoInFourLines() async throws {
        let malayalam = SaathiConfiguration(provider: .sarvam, sarvamKey: "sk-sarvam", voice: "ishita", language: "ml")
        let lines = await run(malayalam, keyAccepted, audio, heard("നമസ്കാരം, ഞാൻ Saathi."), said("നമസ്കാരം!"))

        XCTAssertEqual(lines.map(\.step), ["key", "speech out", "speech in", "thinking"])
        XCTAssertTrue(lines.allSatisfy(\.passed), "\(lines)")
        XCTAssertEqual(lines[0].detail, "accepted")
        XCTAssertEqual(lines[1].detail, "1.0 s of audio for \"നമസ്കാരം, ഞാൻ Saathi.\" (ml-IN, ishita)")
        XCTAssertEqual(lines[2].detail, "heard \"നമസ്കാരം, ഞാൻ Saathi.\"")
        XCTAssertEqual(lines[3].detail, "sarvam-105b said \"നമസ്കാരം!\"")

        let paths = StubHTTP.seen.map { $0.request.url?.path ?? "" }
        XCTAssertEqual(paths, ["/v1/chat/completions", "/text-to-speech", "/speech-to-text", "/v1/chat/completions"])
        XCTAssertNotNil(StubHTTP.seen[2].body.range(of: clip), "Saaras is handed the audio Bulbul made: no microphone")
    }

    /// The thinking step sends exactly what a turn sends — the tools, and the request not to think
    /// aloud — because a refusal of either is what would otherwise look like a companion that
    /// never answers.
    func testTheThinkingStepIsExactlyWhatATurnSends() async throws {
        _ = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, audio, heard("x"), said("hello"))
        let asked = try XCTUnwrap(StubHTTP.seen.last?.json)
        XCTAssertEqual((asked["tools"] as? [[String: Any]])?.count, SaathiAction.allWireNames.count)
        XCTAssertTrue(asked["reasoning_effort"] is NSNull)
        XCTAssertEqual(asked["model"] as? String, "sarvam-105b")
        XCTAssertEqual(StubHTTP.seen.last?.request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    /// Sarvam is what is being tested, whatever this configuration thinks with.
    func testItAsksSarvamItselfEvenWhenSaathiThinksSomewhereElse() async throws {
        let elsewhere = SaathiConfiguration(
            provider: .openai, providerBaseUrl: "http://192.168.1.9:11434", model: "gpt-4o",
            openaiKey: "sk-openai", sarvamKey: "sk-sarvam")
        let lines = await run(elsewhere, keyAccepted, audio, heard("Hello, I am Saathi."), said("Hello!"))
        XCTAssertTrue(lines.allSatisfy(\.passed), "\(lines)")
        let thinking = try XCTUnwrap(StubHTTP.seen.last)
        XCTAssertEqual(thinking.request.url?.absoluteString, "https://api.sarvam.ai/v1/chat/completions")
        XCTAssertEqual(thinking.request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-sarvam")
        XCTAssertEqual(thinking.json["model"] as? String, "sarvam-105b")
        XCTAssertEqual(StubHTTP.seen[1].json["language_code"] as? String, "en-IN", "English until a language is chosen")
    }

    func testWithNoKeyItSaysWhereToPutOneAndAsksNothing() async {
        let lines = await run(SaathiConfiguration(provider: .openai, openaiKey: "sk-openai"), keyAccepted)
        XCTAssertEqual(lines.count, 1)
        XCTAssertFalse(lines[0].passed)
        XCTAssertTrue(lines[0].detail.contains("sarvamKey"), lines[0].detail)
        XCTAssertTrue(StubHTTP.seen.isEmpty, "another vendor's key is not tried on Sarvam")
    }

    /// Nothing after a refused key can work, and three more lines saying so would bury the one
    /// that matters.
    func testARefusedKeyIsTheOnlyLine() async {
        let refused = StubHTTP.Reply.json(["error": ["message": "no", "code": "invalid_api_key_error"]], status: 403)
        let lines = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "nope"), refused)
        XCTAssertEqual(lines, [SarvamSelfTest.Line(step: "key", passed: false, detail: "Sarvam did not accept that key.")])
        XCTAssertEqual(StubHTTP.seen.count, 1)
    }

    func testEachStepThatFailsSaysWhyAndTheOthersAreStillTried() async {
        let spent = StubHTTP.Reply.json(["error": ["message": "no", "code": "insufficient_quota_error"]], status: 429)
        let lines = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, spent, said("Hello!"))
        XCTAssertEqual(lines.map(\.passed), [true, false, false, true])
        XCTAssertEqual(lines[1].detail, SarvamError.outOfCredits.localizedDescription)
        XCTAssertEqual(lines[2].detail, "not tried: there was no audio to hear")
        XCTAssertEqual(StubHTTP.seen.count, 3, "the thinking step does not depend on the speech")
    }

    func testHearingNothingBackIsAFailureAndSoIsAnAnswerWithNothingInIt() async {
        let lines = await run(
            SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, audio, heard("  "), said("  "))
        XCTAssertEqual(lines.map(\.passed), [true, true, false, false])
        XCTAssertEqual(lines[2].detail, "Saaras heard nothing in the audio Bulbul had just made")
        XCTAssertEqual(lines[3].detail, "sarvam-105b answered with nothing at all")
    }

    /// A model that answers "say hello" by calling the `say` tool has answered.
    func testAnAnswerThatIsAToolCallCounts() async {
        let called = StubHTTP.Reply.json(["choices": [["message": [
            "role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "c", "type": "function", "function": ["name": "say", "arguments": "{\"text\":\"Hello!\"}"]]],
        ]]]])
        let lines = await run(SaathiConfiguration(provider: .sarvam, sarvamKey: "k"), keyAccepted, audio, heard("x"), called)
        XCTAssertTrue(lines[3].passed)
        XCTAssertEqual(lines[3].detail, "sarvam-105b answered with a tool call (say)")
    }

    func testTheClipIsHandedOverForAnyoneWhoWantsToHearIt() async {
        let clips = Collected<Data>()
        _ = await SarvamSelfTest(
            configuration: SaathiConfiguration(provider: .sarvam, sarvamKey: "k"),
            urlSession: StubHTTP.session(keyAccepted, audio, heard("x"), said("hello"))
        ).run(onClip: { clips.add($0) })
        XCTAssertEqual(clips.all, [clip])
    }

    func testTheLinesAreSetOutInAColumnAndAFailureSaysItIsOne() {
        let text = SarvamSelfTest.render([
            SarvamSelfTest.Line(step: "key", passed: true, detail: "accepted"),
            SarvamSelfTest.Line(step: "speech out", passed: false, detail: "Sarvam is busy."),
        ])
        XCTAssertEqual(text, "  key         accepted\n  speech out  FAILED — Sarvam is busy.")
    }

    func testThereIsAGreetingForEveryLanguageBulbulSpeaksAndTheNameStaysInLatin() {
        for language in SarvamLanguage.spoken {
            let greeting = SarvamSelfTest.greetings["\(language)-IN"]
            XCTAssertNotNil(greeting, language)
            XCTAssertTrue(greeting?.contains("Saathi") ?? false, language)
        }
        XCTAssertEqual(SarvamSelfTest.greetings.count, SarvamLanguage.spoken.count)
    }
}
```

- [ ] **Step 2: Run to see them fail.** `cannot find 'SarvamSelfTest' in scope`.

- [ ] **Step 3: Implement.** Create `Sources/SaathiKit/SarvamSelfTest.swift`:

```swift
//
//  SarvamSelfTest.swift
//  SaathiKit
//
//  `saathi sarvam`: one request to each thing Saathi asks of Sarvam, and what came back.
//
//  Everything Sarvam does for Saathi was written from its reference with no key to try it on. This
//  is the answer to "does it actually work", in four lines: is the key accepted, can Bulbul say a
//  sentence, can Saaras hear that sentence back, and does Sarvam-105B answer exactly what a turn
//  would send it — the tools and the request not to think aloud included, since a refusal of
//  either would otherwise show up as a companion that never replies.
//
//  It needs no microphone and no permission: the audio Saaras is asked to hear is the audio Bulbul
//  just made.
//

import Foundation
import SaathiContract

public struct SarvamSelfTest: Sendable {

    public struct Line: Equatable, Sendable {
        public let step: String
        public let passed: Bool
        public let detail: String

        public init(step: String, passed: Bool, detail: String) {
            self.step = step
            self.passed = passed
            self.detail = detail
        }
    }

    /// One short line in each language Bulbul speaks, to say and then to hear back. The name stays
    /// in Latin script, as Sarvam's own guidance for text-to-speech asks of brand names.
    static let greetings: [String: String] = [
        "en-IN": "Hello, I am Saathi.",
        "hi-IN": "नमस्ते, मैं Saathi हूँ।",
        "bn-IN": "নমস্কার, আমি Saathi।",
        "ta-IN": "வணக்கம், நான் Saathi.",
        "te-IN": "నమస్కారం, నేను Saathi.",
        "kn-IN": "ನಮಸ್ಕಾರ, ನಾನು Saathi.",
        "ml-IN": "നമസ്കാരം, ഞാൻ Saathi.",
        "mr-IN": "नमस्कार, मी Saathi आहे.",
        "gu-IN": "નમસ્તે, હું Saathi છું.",
        "pa-IN": "ਸਤ ਸ੍ਰੀ ਅਕਾਲ, ਮੈਂ Saathi ਹਾਂ।",
        "od-IN": "ନମସ୍କାର, ମୁଁ Saathi।",
    ]

    private let configuration: SaathiConfiguration
    private let urlSession: URLSession

    public init(configuration: SaathiConfiguration, urlSession: URLSession = SarvamClient.session) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    /// Runs the four steps. `onClip` is handed what Bulbul made, for anyone who wants to hear it.
    public func run(onClip: (@Sendable (Data) async -> Void)? = nil) async -> [Line] {
        guard let key = configuration.credential(for: .sarvam) else {
            return [Line(
                step: "key", passed: false,
                detail: "there is none. Paste one in Setup, or put \"sarvamKey\" in ~/.saathi/shell.json")]
        }
        switch await KeyValidator(urlSession: urlSession).check(.sarvam, key: key) {
        case .valid:
            break
        case let .rejected(why), let .unreachable(why):
            // Nothing after this can work, and three more lines saying so would bury the one that matters.
            return [Line(step: "key", passed: false, detail: why)]
        }
        var lines = [Line(step: "key", passed: true, detail: "accepted")]

        let client = SarvamClient(key: key, urlSession: urlSession)
        let language = SarvamLanguage.code(for: configuration.resolvedLanguage) ?? "en-IN"
        let speaker = SarvamSpeech.speaker(named: configuration.voice)
        let sentence = Self.greetings[language] ?? "Hello, I am Saathi."

        var spoken: Data?
        do {
            let clips = try await client.synthesize(sentence, language: language, speaker: speaker)
            spoken = clips.first
            let seconds = clips.compactMap { WaveFile.seconds(of: $0) }.reduce(0, +)
            lines.append(Line(
                step: "speech out", passed: true,
                detail: String(format: "%.1f s of audio for \"%@\" (%@, %@)", seconds, sentence, language, speaker)))
            if let onClip {
                for clip in clips { await onClip(clip) }
            }
        } catch {
            lines.append(Line(step: "speech out", passed: false, detail: error.localizedDescription))
        }

        if let spoken {
            do {
                let heard = try await client.transcribe(wav: spoken, language: language)
                lines.append(Line(
                    step: "speech in", passed: !heard.isEmpty,
                    detail: heard.isEmpty ? "Saaras heard nothing in the audio Bulbul had just made" : "heard \"\(heard)\""))
            } catch {
                lines.append(Line(step: "speech in", passed: false, detail: error.localizedDescription))
            }
        } else {
            lines.append(Line(step: "speech in", passed: false, detail: "not tried: there was no audio to hear"))
        }

        lines.append(await thinking())
        return lines
    }

    /// Exactly what a turn sends — the same request builder, so the same tools and the same
    /// `reasoning_effort` — to Sarvam itself, whatever this configuration thinks with.
    private func thinking() async -> Line {
        var asked = configuration
        if configuration.resolvedProvider != .sarvam {
            asked.provider = .sarvam
            asked.model = nil
            asked.providerBaseUrl = nil
        }
        do {
            let request = try ChainVoiceSession.completionRequest(
                configuration: asked,
                history: [["role": "user", "content": "Say hello in one short sentence."]])
            let (data, response) = try await urlSession.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { throw SarvamError.refusal(status: status, body: data) }
            guard let message = ChainVoiceSession.message(in: data) else {
                throw SarvamError.unreadable("there was no message in it")
            }
            let said = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let calls = ChainVoiceSession.toolCalls(in: message).map(\.name)
            let what: String
            if !said.isEmpty {
                what = "said \"\(said)\""
            } else if !calls.isEmpty {
                what = "answered with a tool call (\(calls.joined(separator: ", ")))"
            } else {
                what = "answered with nothing at all"
            }
            return Line(step: "thinking", passed: !said.isEmpty || !calls.isEmpty, detail: "\(asked.resolvedModel) \(what)")
        } catch let error as SarvamError {
            return Line(step: "thinking", passed: false, detail: error.localizedDescription)
        } catch {
            return Line(step: "thinking", passed: false, detail: SarvamError.unreachable(error.localizedDescription).localizedDescription)
        }
    }

    /// The lines as the command prints them.
    public static func render(_ lines: [Line]) -> String {
        lines.map { line in
            let step = line.step.padding(toLength: 11, withPad: " ", startingAt: 0)
            return "  \(step) \(line.passed ? line.detail : "FAILED — \(line.detail)")"
        }.joined(separator: "\n")
    }
}
```

`Sources/saathi/main.swift`:

```diff
--- a/macos/Saathi/Sources/saathi/main.swift
+++ b/macos/Saathi/Sources/saathi/main.swift
@@ -7,6 +7,7 @@
 //
 //    saathi provider           which mode this is in, and whether anything leaves the machine
 //    saathi voice              which voice lane that gives you, and where your voice goes
+//    saathi sarvam             whether Sarvam works with your key: one line for each thing asked of it
 //    saathi actions            what this build can be asked to do
 //    saathi health             is the backend up
 //    saathi say "..."          say one line out loud
@@ -24,7 +25,18 @@
 let positional = arguments.filter { !$0.hasPrefix("--") }
 let command = positional.first ?? "help"
 
-let speaker: any Speaker = quiet ? PrintingSpeaker() : SystemSpeaker()
+/// The voice the app would use: this Mac's, or Sarvam's when `shell.json` asks for it — so
+/// `saathi say` is also the quickest way to hear what a reply will sound like. A configuration
+/// that cannot be read is each command's to complain about; the voice is then this Mac's.
+func makeSpeaker() -> any Speaker {
+    if quiet { return PrintingSpeaker() }
+    let configuration = (try? ConfigurationStore.load(from: ConfigurationStore.defaultPath())) ?? SaathiConfiguration()
+    let voice = CompanionVoice(configuration: configuration)
+    voice.reportFailures { FileHandle.standardError.write(Data("  [\($0)]\n".utf8)) }
+    return voice
+}
+
+let speaker = makeSpeaker()
 let performer = ActionPerformer(speaker: speaker, urlOpener: SystemUrlOpener())
 
 func toneOption() -> Tone {
@@ -81,6 +93,18 @@
         }
     }
 
+case "sarvam":
+    // Everything Saathi asks of Sarvam, asked once: the key, a sentence from Bulbul, that sentence
+    // back through Saaras, and one question to the model. No microphone and no permission — and
+    // no `check-parity.sh`, since there is nothing of this on the Windows client to compare with.
+    let sarvamConfiguration = try ConfigurationStore.load(from: ConfigurationStore.defaultPath())
+    let output: PlayerAudioOutput? = arguments.contains("--play") ? PlayerAudioOutput() : nil
+    let lines = await SarvamSelfTest(configuration: sarvamConfiguration).run(onClip: { clip in
+        try? await output?.play(clip)
+    })
+    print(SarvamSelfTest.render(lines))
+    if lines.contains(where: { !$0.passed }) { exit(1) }
+
 case "actions":
     print("contract \(SaathiBackend.contractVersion) — \(SaathiAction.allWireNames.count) actions")
     for wireName in SaathiAction.allWireNames { print("  \(wireName)") }
@@ -125,6 +149,7 @@
 
       saathi provider             which mode this is in  (--probe to check it is reachable)
       saathi voice                which voice lane, and where your voice goes  (--listen to talk)
+      saathi sarvam               check your Sarvam key, its speech and its model  (--play to hear it)
       saathi actions              list what this build can be asked to do
       saathi health               check the backend
       saathi say "..."            say one line  (--tone=calm|encouraging|neutral)
```

- [ ] **Step 4: Run.** `swift test --filter SarvamSelfTestTests`; then, with no key configured, `SAATHI_CONFIG=/nonexistent .build/debug/saathi sarvam` prints the one line that says where to put a key and exits 1; and `bash scripts/check-parity.sh` still agrees (the bare `voice` and `provider` commands print nothing new).

- [ ] **Step 5: Commit** — "`saathi sarvam` says in four lines whether Sarvam works".

---

### Task 13: What the README and the hand test say

**Files:**
- Modify: `README.md`, `docs/HAND-TEST.md`, `docs/superpowers/specs/2026-09-30-sarvam-heard-and-spoken-design.md` (anything the build changed)

- [ ] **Step 1:** README — the provider table, the voice table, the Sarvam paragraph, the `shell.json` example, "Where it stands", "Still to do", the test counts.

*(Written once what it describes is built; this plan carries the diff of `README.md` from then on.)*

- [ ] **Step 2:** HAND-TEST — a section for Sarvam: `saathi sarvam` first, then the key row, the picker, the switch, a turn in an Indian language, talking over a reply, a look, and the switch from OpenAI without a relaunch.

*(Written once what it describes is built; this plan carries the diff of `docs/HAND-TEST.md` from then on.)*

- [ ] **Step 3: Commit** — "The README and the hand test say what Sarvam now does, and what nobody has yet heard".

---

### Task 14: Verify, build, review

- [ ] **Step 1:** `bash <scratchpad>/ci-local.sh` — every job ✓.
- [ ] **Step 2:** Regenerate this plan's code blocks from the tree and commit it.
- [ ] **Step 3:** `cd macos/Saathi && scripts/release.sh --no-notarize` (sandbox off) — `dist/Saathi.app` is 0.9.0, Developer ID signed.
- [ ] **Step 4:** A fresh reviewer reads the branch against the spec.
