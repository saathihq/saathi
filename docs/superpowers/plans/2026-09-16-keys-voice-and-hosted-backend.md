# Your keys, a working voice, and the hosted backend — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let someone paste an OpenAI key and an Anthropic key into Saathi's island and have it configure itself into a working spoken companion, fix the two bugs that stop bring-your-own-key voice from ever connecting, make the Input Monitoring grant take effect without a relaunch, and turn on the hosted backend that is deployed but unconfigured.

**Architecture:** The contract schema (`contract/schema/saathi.json`) is the single source for config shape and provider rows; `contract/generate.mjs` emits Swift, C# and TypeScript from it, so every config change starts there and never in a client. Two new pure types in `SaathiKit` — `SetupPlan` (decides provider/model/lane from what validated) and `KeyValidator` (asks a vendor whether a key works) — carry all the decision-making, so the "it sets itself up" behaviour is unit-tested rather than demonstrated. The island gains a Setup tab that calls them and hands the result to `AppController.reconfigure`, which swaps a live voice session without a relaunch.

**Tech Stack:** Swift 5.9 / SwiftPM (macOS 13+), AppKit + SwiftUI, XCTest. Node 22 for the contract generator. Hono on Vercel's edge runtime, Supabase Postgres for accounts.

**Spec:** `docs/superpowers/specs/2026-09-16-keys-voice-and-hosted-backend-design.md`

## Global Constraints

- **Never hand-edit generated files.** `macos/Saathi/Sources/SaathiContract/SaathiContract.swift`, `windows/src/Saathi.Contract/SaathiContract.cs` and the TypeScript contract are all output. Change `contract/schema/saathi.json` and/or `contract/generate.mjs`, then run `npm run generate`. CI fails on a stale checked-in file.
- **Contract version becomes `0.6.0`** (from `0.5.0`), set in `contract/schema/saathi.json`'s `version` field. It appears in `/health` output and in `SaathiBackend.contractVersion`.
- **`~/.saathi/shell.json` is written 0600, created with that mode** — never chmod after. `ConfigurationStore.save` already does this; do not weaken it.
- **A provider key is never sent to Saathi's servers.** Own-key modes talk to the vendor directly. Any code that would route a user key through `api.saathi.dev` is wrong.
- **Secrets never enter a tracked file.** `.env.local` is gitignored and holds them. This repository is public and Apache-2.0.
- **Swift concurrency is strict.** `SaathiShell` and `AppController` are `@MainActor`; session callbacks arrive off-main and are hopped with `Task { @MainActor in … }`. Follow the existing pattern rather than adding `@unchecked Sendable`.
- **Run the full macOS suite before every commit:** `cd macos/Saathi && swift test`. It must be green, not just the new filter.
- **Realtime voice default is `cedar`**, realtime model default is `gpt-realtime`.
- **Commit messages** describe what the change means for the user, in the style of the existing log (`git log --oneline`), and end with:
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

### Task 1: The contract learns about two keys and a voice

**Files:**
- Modify: `contract/schema/saathi.json` (version, `config.fields`, `providers.rows`)
- Modify: `contract/generate.mjs` (Swift emitter ~lines 131–210, C# emitter ~lines 278–348)
- Regenerate: `macos/Saathi/Sources/SaathiContract/SaathiContract.swift`, `windows/src/Saathi.Contract/SaathiContract.cs`, and the TypeScript output
- Test: `macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift` (config tests live here alongside the existing `ConfigurationStore` tests)

**Interfaces:**
- Consumes: nothing.
- Produces: `SaathiConfiguration.openaiKey/anthropicKey/voiceModel/voice: String?`; `SaathiConfiguration.credential(for: ProviderKind) -> String?`; `SaathiConfiguration.resolvedVoiceModel: String`; `SaathiConfiguration.resolvedVoice: String`; `SaathiProvider.defaultVoiceModel: String`; `SaathiProvider.defaultVoice: String`. Tasks 2, 3, 4, 5 and 6 all depend on these names.

- [ ] **Step 1: Write the failing tests**

Append to `macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift`:

```swift
// MARK: - Two keys at once

/// The reason the two vendor fields exist: a config holding both an OpenAI and an Anthropic key
/// must be unambiguous about which one a given provider gets. The old single `apiKey` could not
/// express that, and guessing from the key's prefix would be a parlour trick, not a contract.
final class CredentialResolutionTests: XCTestCase {

    func testEachVendorFieldFeedsItsOwnProvider() {
        let both = SaathiConfiguration(openaiKey: "sk-openai", anthropicKey: "sk-ant-key")
        XCTAssertEqual(both.credential(for: .openai), "sk-openai")
        XCTAssertEqual(both.credential(for: .anthropic), "sk-ant-key")
    }

    /// Existing configs in the wild have only `apiKey`. They must keep working, whichever provider
    /// they named — this is the compatibility promise of keeping the field at all.
    func testTheLegacySharedKeyIsStillReadWhenThereIsNoVendorField() {
        let legacy = SaathiConfiguration(apiKey: "sk-legacy")
        XCTAssertEqual(legacy.credential(for: .openai), "sk-legacy")
        XCTAssertEqual(legacy.credential(for: .anthropic), "sk-legacy")
    }

    func testAVendorFieldWinsOverTheLegacyOne() {
        let mixed = SaathiConfiguration(apiKey: "sk-legacy", openaiKey: "sk-vendor")
        XCTAssertEqual(mixed.credential(for: .openai), "sk-vendor")
    }

    /// Whitespace and an empty string are both "no key". A pasted key routinely arrives with a
    /// trailing newline, and an empty-but-present field must not read as a configured credential.
    func testBlankIsNotACredential() {
        XCTAssertNil(SaathiConfiguration(openaiKey: "   ").credential(for: .openai))
        XCTAssertNil(SaathiConfiguration().credential(for: .openai))
        XCTAssertEqual(SaathiConfiguration(openaiKey: " sk-padded \n").credential(for: .openai), "sk-padded")
    }

    /// Providers that need no key of their own get none, even when keys are present.
    func testLocalAndHostedTakeNoVendorKey() {
        let both = SaathiConfiguration(openaiKey: "sk-openai", anthropicKey: "sk-ant-key")
        XCTAssertNil(both.credential(for: .local))
        XCTAssertNil(both.credential(for: .hosted))
    }
}

/// The realtime socket is opened with a VOICE model, which is a different thing from the model that
/// does the thinking. Conflating them is the bug this separation exists to make impossible.
final class VoiceModelResolutionTests: XCTestCase {

    func testOpenAIHasBothAThinkingModelAndADistinctVoiceModel() {
        let openai = SaathiConfiguration(provider: .openai)
        XCTAssertEqual(openai.resolvedModel, "gpt-4o-mini")
        XCTAssertEqual(openai.resolvedVoiceModel, "gpt-realtime")
        XCTAssertNotEqual(openai.resolvedModel, openai.resolvedVoiceModel)
    }

    func testTheVoiceModelCanBeOverriddenWithoutTouchingTheThinkingModel() {
        let pinned = SaathiConfiguration(provider: .openai, model: "gpt-4o", voiceModel: "gpt-realtime-mini")
        XCTAssertEqual(pinned.resolvedModel, "gpt-4o")
        XCTAssertEqual(pinned.resolvedVoiceModel, "gpt-realtime-mini")
    }

    func testTheDefaultVoiceIsWarmAndOverridable() {
        XCTAssertEqual(SaathiConfiguration(provider: .openai).resolvedVoice, "cedar")
        XCTAssertEqual(SaathiConfiguration(provider: .openai, voice: "marin").resolvedVoice, "marin")
    }

    /// Chain-lane providers have no realtime socket, so they have no voice model. An empty string
    /// rather than a plausible-looking default: a name here would invite someone to try to use it.
    func testChainLaneProvidersDeclareNoVoiceModel() {
        XCTAssertEqual(SaathiConfiguration(provider: .anthropic).resolvedVoiceModel, "")
        XCTAssertEqual(SaathiConfiguration(provider: .local).resolvedVoiceModel, "")
    }

    func testEveryRealtimeProviderHasAVoiceModelAndEveryChainProviderDoesNot() {
        for row in SaathiProvider.all {
            if row.voice == .realtime {
                XCTAssertFalse(row.defaultVoiceModel.isEmpty, "\(row.kind) opens a socket but names no voice model")
                XCTAssertFalse(row.defaultVoice.isEmpty, "\(row.kind) opens a socket but names no voice")
            } else {
                XCTAssertTrue(row.defaultVoiceModel.isEmpty, "\(row.kind) has no socket to use a voice model on")
            }
        }
    }
}

/// The new fields have to survive the file, or the Setup tab writes keys that vanish on restart.
final class ConfigurationRoundTripTests: XCTestCase {

    func testEveryNewFieldSurvivesAWriteAndARead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let written = SaathiConfiguration(
            provider: .openai, model: "gpt-4o", openaiKey: "sk-o", anthropicKey: "sk-a",
            voiceModel: "gpt-realtime", voice: "cedar")
        try ConfigurationStore.save(written, to: url)
        let read = try ConfigurationStore.load(from: url)

        XCTAssertEqual(read.provider, .openai)
        XCTAssertEqual(read.model, "gpt-4o")
        XCTAssertEqual(read.openaiKey, "sk-o")
        XCTAssertEqual(read.anthropicKey, "sk-a")
        XCTAssertEqual(read.voiceModel, "gpt-realtime")
        XCTAssertEqual(read.voice, "cedar")
    }

    /// A file holding two provider keys is worth more to an attacker than one holding a single key.
    /// The mode was already right; this test is here so it stays right.
    func testTheSavedFileIsOwnerReadableOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("saathi-mode-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try ConfigurationStore.save(SaathiConfiguration(openaiKey: "sk-o"), to: url)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos/Saathi && swift test --filter CredentialResolutionTests`
Expected: FAIL to compile — `SaathiConfiguration` has no `openaiKey`, no `credential(for:)`, and `SaathiProvider` has no `defaultVoiceModel`.

- [ ] **Step 3: Add the four config fields to the schema**

In `contract/schema/saathi.json`, set `"version": "0.6.0"`, and append to `config.fields` (after the existing `apiKey` entry):

```json
{
  "name": "openaiKey",
  "type": "string",
  "optional": true,
  "doc": "Your own OpenAI key. Used for the realtime voice lane and for thinking. Never sent to Saathi's servers."
},
{
  "name": "anthropicKey",
  "type": "string",
  "optional": true,
  "doc": "Your own Anthropic key. Stored for a lane that does not exist yet; nothing calls it today."
},
{
  "name": "voiceModel",
  "type": "string",
  "optional": true,
  "doc": "Overrides the realtime voice model. Distinct from model, which is what does the thinking."
},
{
  "name": "voice",
  "type": "string",
  "optional": true,
  "doc": "The realtime voice's name. Defaults to the provider row's."
}
```

Also change `apiKey`'s `doc` to: `"Deprecated: use openaiKey or anthropicKey. Still read when no vendor-specific key is set, so existing configs keep working."`

**Field order matters and is load-bearing.** The generator emits a memberwise `init` whose parameter
order is the schema's field order, and Swift requires arguments in declaration order. Appending
after `apiKey` gives `provider, providerBaseUrl, model, apiKey, openaiKey, anthropicKey, voiceModel,
voice, backendUrl, token` — which is the order every test in this plan is written against. Insert
them anywhere else and those tests stop compiling.

- [ ] **Step 4: Add the two provider columns to the schema**

In `contract/schema/saathi.json`, add `defaultVoiceModel` and `defaultVoice` to every row in `providers.rows`:

| kind | defaultVoiceModel | defaultVoice |
|---|---|---|
| `local` | `""` | `""` |
| `openai` | `"gpt-realtime"` | `"cedar"` |
| `anthropic` | `""` | `""` |
| `sarvam` | `""` | `""` |
| `hosted` | `"gpt-realtime"` | `"cedar"` |

Add to the `providers.$comment` array, after the existing `voice` paragraph:

```
"",
"`defaultVoiceModel` and `defaultVoice` are separate from `defaultModel` because they are a",
"different thing: the model that carries a realtime socket is not the model that answers a",
"chat completion, and a client that opened the socket with `defaultModel` would be rejected by",
"the provider. Empty on every chain-lane row, because a plausible name there would invite",
"someone to try to use a socket that does not exist."
```

- [ ] **Step 5: Teach the generator the new provider columns**

In `contract/generate.mjs`, Swift emitter, after the `public let voice: VoiceLane` line and before `public let summary: String`:

```js
  out.push("    /// The realtime voice model, empty on every chain-lane row — see the schema's");
  out.push("    /// providers comment for why this is not `defaultModel`.");
  out.push("    public let defaultVoiceModel: String");
  out.push("    /// The realtime voice's name, empty where there is no socket to speak over.");
  out.push("    public let defaultVoice: String");
```

and extend the row constructor line so it reads:

```js
    out.push(`        SaathiProvider(kind: .${r.kind}, defaultBaseURL: "${r.defaultBaseUrl}", defaultModel: "${r.defaultModel}", requiresKey: ${r.requiresKey}, requiresToken: ${r.requiresToken}, sendsDataOffMachine: ${r.sendsDataOffMachine}, keyHeader: "${r.keyHeader}", keyPrefix: "${r.keyPrefix}", voice: .${r.voice}, defaultVoiceModel: "${r.defaultVoiceModel}", defaultVoice: "${r.defaultVoice}", summary: ${JSON.stringify(r.doc)}),`);
```

In the C# emitter, add to the `SaathiProvider` record parameter list after `VoiceLane Voice,`:

```js
  out.push("    string DefaultVoiceModel,");
  out.push("    string DefaultVoice,");
```

and extend its row line:

```js
    out.push(`        new(global::Saathi.Contract.ProviderKind.${pascal(r.kind)}, "${r.defaultBaseUrl}", "${r.defaultModel}", ${r.requiresKey}, ${r.requiresToken}, ${r.sendsDataOffMachine}, "${r.keyHeader}", "${r.keyPrefix}", global::Saathi.Contract.VoiceLane.${pascal(r.voice)}, "${r.defaultVoiceModel}", "${r.defaultVoice}", ${JSON.stringify(r.doc)}),`);
```

- [ ] **Step 6: Teach the generator the three new config members**

In `contract/generate.mjs`, Swift emitter, immediately after the `resolvedModel` block and before the `resolvedBaseURL` block:

```js
  out.push("    /// The realtime voice model. Separate from `resolvedModel` on purpose: the socket is");
  out.push("    /// opened with this one, and opening it with the thinking model is rejected by the");
  out.push("    /// provider — which is exactly the bug this property exists to prevent.");
  out.push("    public var resolvedVoiceModel: String {");
  out.push("        let trimmed = voiceModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? \"\"");
  out.push("        return trimmed.isEmpty ? providerRow.defaultVoiceModel : trimmed");
  out.push("    }\n");
  out.push("    public var resolvedVoice: String {");
  out.push("        let trimmed = voice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? \"\"");
  out.push("        return trimmed.isEmpty ? providerRow.defaultVoice : trimmed");
  out.push("    }\n");
  out.push("    /// The credential for a provider: its own vendor field first, then the legacy shared");
  out.push("    /// `apiKey`. Vendor-specific wins, so a config holding both an OpenAI and an Anthropic");
  out.push("    /// key is unambiguous — which is the whole reason the two fields exist. Providers that");
  out.push("    /// need no key of their own get nil even when keys are present.");
  out.push("    public func credential(for kind: ProviderKind) -> String? {");
  out.push("        guard SaathiProvider.of(kind).requiresKey else { return nil }");
  out.push("        let candidates: [String?]");
  out.push("        switch kind {");
  out.push("        case .openai: candidates = [openaiKey, apiKey]");
  out.push("        case .anthropic: candidates = [anthropicKey, apiKey]");
  out.push("        default: candidates = [apiKey]");
  out.push("        }");
  out.push("        for candidate in candidates {");
  out.push("            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? \"\"");
  out.push("            if !trimmed.isEmpty { return trimmed }");
  out.push("        }");
  out.push("        return nil");
  out.push("    }\n");
```

In the C# emitter, after the `ResolvedModel` block:

```js
  out.push("    /// <summary>The realtime voice model. Separate from ResolvedModel on purpose: the socket is");
  out.push("    /// opened with this one, and opening it with the thinking model is rejected by the provider.</summary>");
  out.push("    public string ResolvedVoiceModel =>");
  out.push("        string.IsNullOrWhiteSpace(VoiceModel) ? ProviderRow.DefaultVoiceModel : VoiceModel!.Trim();\n");
  out.push("    public string ResolvedVoice =>");
  out.push("        string.IsNullOrWhiteSpace(Voice) ? ProviderRow.DefaultVoice : Voice!.Trim();\n");
  out.push("    /// <summary>The credential for a provider: its own vendor field first, then the legacy");
  out.push("    /// shared ApiKey. Providers needing no key of their own get null.</summary>");
  out.push("    public string? Credential(ProviderKind kind)");
  out.push("    {");
  out.push("        if (!SaathiProvider.Of(kind).RequiresKey) return null;");
  out.push("        var candidates = kind switch");
  out.push("        {");
  out.push("            global::Saathi.Contract.ProviderKind.Openai => new[] { OpenaiKey, ApiKey },");
  out.push("            global::Saathi.Contract.ProviderKind.Anthropic => new[] { AnthropicKey, ApiKey },");
  out.push("            _ => new[] { ApiKey },");
  out.push("        };");
  out.push("        foreach (var candidate in candidates)");
  out.push("            if (!string.IsNullOrWhiteSpace(candidate)) return candidate!.Trim();");
  out.push("        return null;");
  out.push("    }\n");
```

Note: the C# config-field loop already emits the four new properties automatically — it iterates `schema.config.fields`. Only the provider record and the resolved helpers need hand-written emitter lines.

- [ ] **Step 7: Regenerate and check parity**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
npm run generate
npm run check:contract
bash scripts/check-parity.sh
git diff --stat
```

Expected: `SaathiContract.swift` and `SaathiContract.cs` both change; `check:contract` and `check-parity.sh` pass.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test`
Expected: PASS, including the whole pre-existing suite.

Then: `cd windows && dotnet test Saathi.sln` — expected PASS. If the .NET toolchain is not installed on this machine, say so explicitly in the task report rather than marking it passed; do not skip it silently.

- [ ] **Step 9: Commit**

```bash
git add contract/schema/saathi.json contract/generate.mjs \
  macos/Saathi/Sources/SaathiContract/SaathiContract.swift \
  windows/src/Saathi.Contract/SaathiContract.cs \
  macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift
git commit -m "$(cat <<'MSG'
The config holds a key per vendor, and a voice model that is not the thinking model

Two keys can now sit in shell.json at once, which is what a setup panel taking both
needs. credential(for:) makes which one a provider gets unambiguous instead of
guessing from a prefix, and the legacy apiKey is still read so existing configs keep
working.

The voice model is separate from the thinking model because they are different
things: a realtime socket opened with gpt-4o-mini is refused by the provider.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: `SetupPlan` — deciding what to be, from what worked

**Files:**
- Create: `macos/Saathi/Sources/SaathiKit/SetupPlan.swift`
- Test: `macos/Saathi/Tests/SaathiKitTests/SetupPlanTests.swift`

**Interfaces:**
- Consumes: `SaathiConfiguration`, `ProviderKind`, `VoiceLane`, `SaathiProvider` from Task 1.
- Produces: `SetupPlan` with `provider: ProviderKind`, `model: String`, `voiceModel: String`, `lane: VoiceLane`, `explanation: String`, `storedButUnused: [ProviderKind]`; `SetupPlan.make(openAIKeyValid:anthropicKeyValid:) -> SetupPlan`; `SetupPlan.applied(to:openAIKey:anthropicKey:) -> SaathiConfiguration`. Tasks 5 and 6 call both.

- [ ] **Step 1: Write the failing test**

Create `macos/Saathi/Tests/SaathiKitTests/SetupPlanTests.swift`:

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

    func testAnOpenAIKeyBuysTheRealtimeLane() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.lane, .realtime)
        XCTAssertEqual(plan.voiceModel, "gpt-realtime")
        XCTAssertEqual(plan.model, "gpt-4o-mini")
        XCTAssertTrue(plan.storedButUnused.isEmpty)
    }

    /// The honest bit. Both keys given, only one used — and the plan says which, so the panel can
    /// tell the truth instead of letting someone believe Claude is in the loop.
    func testBothKeysStillMeansOpenAIAndSaysTheOtherIsUnused() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        XCTAssertEqual(plan.provider, .openai)
        XCTAssertEqual(plan.storedButUnused, [.anthropic])
    }

    func testAnthropicAloneGetsTheChainLane() {
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: true)
        XCTAssertEqual(plan.provider, .anthropic)
        XCTAssertEqual(plan.lane, .chain)
        XCTAssertEqual(plan.model, "claude-sonnet-5")
        XCTAssertTrue(plan.voiceModel.isEmpty, "the chain lane opens no socket")
        XCTAssertTrue(plan.storedButUnused.isEmpty, "the key it has is the key it uses")
    }

    func testNoKeysFallsBackToWhateverIsOnThisMachine() {
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false)
        XCTAssertEqual(plan.provider, .local)
        XCTAssertEqual(plan.lane, .chain)
    }

    /// Every branch has to produce a sentence. An empty explanation would render as a blank line in
    /// the panel, which reads as a bug rather than as a default.
    func testEveryPlanExplainsItself() {
        for openAI in [true, false] {
            for anthropic in [true, false] {
                let plan = SetupPlan.make(openAIKeyValid: openAI, anthropicKeyValid: anthropic)
                XCTAssertFalse(
                    plan.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "no explanation for openAI=\(openAI) anthropic=\(anthropic)")
            }
        }
    }

    /// The local explanation is the one a stuck person reads most, so it has to name the thing they
    /// are missing rather than say "not configured".
    func testTheLocalExplanationNamesWhatToInstall() {
        let plan = SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false)
        XCTAssertTrue(plan.explanation.contains("Ollama"))
    }

    func testTheRealtimeExplanationSaysWhereTheVoiceGoes() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        XCTAssertTrue(plan.explanation.lowercased().contains("openai"))
        XCTAssertTrue(plan.explanation.lowercased().contains("voice"))
    }

    // MARK: applying a plan

    func testApplyingAPlanWritesBothKeysAndTheChosenProvider() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        let config = plan.applied(to: SaathiConfiguration(), openAIKey: "sk-o", anthropicKey: "sk-a")

        XCTAssertEqual(config.provider, .openai)
        XCTAssertEqual(config.openaiKey, "sk-o")
        XCTAssertEqual(config.anthropicKey, "sk-a", "an unused key is still stored")
        XCTAssertEqual(config.voiceModel, "gpt-realtime")
        XCTAssertEqual(config.credential(for: .openai), "sk-o")
    }

    /// Settings a person chose by hand are not ours to throw away because they pasted a key.
    func testApplyingAPlanKeepsUnrelatedSettings() {
        let existing = SaathiConfiguration(backendUrl: "https://example.test", token: "tok")
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        let config = plan.applied(to: existing, openAIKey: "sk-o", anthropicKey: "")

        XCTAssertEqual(config.backendUrl, "https://example.test")
        XCTAssertEqual(config.token, "tok")
    }

    /// A key that did not validate is not saved. Storing a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working.
    func testAKeyThatDidNotValidateIsNotStored() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        let config = plan.applied(to: SaathiConfiguration(), openAIKey: "sk-o", anthropicKey: "sk-bad")
        XCTAssertNil(config.anthropicKey)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter SetupPlanTests`
Expected: FAIL to compile — `cannot find 'SetupPlan' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos/Saathi/Sources/SaathiKit/SetupPlan.swift`:

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

public struct SetupPlan: Equatable, Sendable {

    public let provider: ProviderKind
    public let model: String
    /// Empty on the chain lane, which opens no socket.
    public let voiceModel: String
    public let lane: VoiceLane
    /// One line, Saathi's voice, saying what it chose and what that means for the learner.
    public let explanation: String
    /// Keys that were accepted and saved but that nothing will call. Named rather than hidden: a
    /// panel that quietly banks an Anthropic key lets someone believe Claude is answering them.
    public let storedButUnused: [ProviderKind]

    /// The decision, from the only two facts that matter: which keys actually worked.
    ///
    /// OpenAI wins whenever it is available, because it is the only provider with a duplex realtime
    /// socket — the difference between a companion that feels instant and one that feels operated.
    /// That is a capability, not a preference, which is why this is not a setting.
    public static func make(openAIKeyValid: Bool, anthropicKeyValid: Bool) -> SetupPlan {
        if openAIKeyValid {
            let row = SaathiProvider.of(.openai)
            return SetupPlan(
                provider: .openai,
                model: row.defaultModel,
                voiceModel: row.defaultVoiceModel,
                lane: row.voice,
                explanation: "I will talk with you through OpenAI's realtime voice. Your voice "
                    + "leaves this machine as audio, straight to OpenAI — Saathi's servers are not "
                    + "in the conversation.",
                storedButUnused: anthropicKeyValid ? [.anthropic] : [])
        }

        if anthropicKeyValid {
            let row = SaathiProvider.of(.anthropic)
            return SetupPlan(
                provider: .anthropic,
                model: row.defaultModel,
                voiceModel: row.defaultVoiceModel,
                lane: row.voice,
                explanation: "I will listen on this Mac and think with Claude. Your voice stays "
                    + "here — only the words you said are sent.",
                storedButUnused: [])
        }

        let row = SaathiProvider.of(.local)
        return SetupPlan(
            provider: .local,
            model: row.defaultModel,
            voiceModel: row.defaultVoiceModel,
            lane: row.voice,
            explanation: "No key yet, so I will look for a model already running on this machine. "
                + "Start Ollama or LM Studio, or add a key above.",
            storedButUnused: [])
    }

    /// Folds this plan and the keys that earned it into a configuration, leaving everything the
    /// person set by hand — a backend URL, an account token — exactly as it was.
    ///
    /// A key is stored only when it validated. Banking a known-bad key would make the next launch
    /// fail in a way that looks like the good key stopped working, which is a much worse bug to be
    /// handed than "that key was refused".
    public func applied(
        to existing: SaathiConfiguration,
        openAIKey: String,
        anthropicKey: String
    ) -> SaathiConfiguration {
        var updated = existing
        updated.provider = provider
        updated.model = model
        updated.voiceModel = voiceModel.isEmpty ? nil : voiceModel

        let usesOpenAI = provider == .openai
        let anthropicUsable = provider == .anthropic || storedButUnused.contains(.anthropic)

        updated.openaiKey = usesOpenAI ? Self.cleaned(openAIKey) : existing.openaiKey
        updated.anthropicKey = anthropicUsable ? Self.cleaned(anthropicKey) : existing.anthropicKey
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd macos/Saathi && swift test --filter SetupPlanTests`
Expected: PASS (11 tests).

Then the whole suite: `cd macos/Saathi && swift test` — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Saathi/Sources/SaathiKit/SetupPlan.swift macos/Saathi/Tests/SaathiKitTests/SetupPlanTests.swift
git commit -m "$(cat <<'MSG'
SetupPlan: what Saathi becomes, decided from which keys actually worked

A value type with no network and no file system, so "give me your keys and I will
set myself up" is covered by tests rather than by pasting a key and listening.

It also carries the honest part: when both keys are given, only OpenAI is used, and
the plan says so out loud so the panel cannot imply Claude is answering.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: `KeyValidator` — asking a vendor whether a key works

**Files:**
- Create: `macos/Saathi/Sources/SaathiKit/KeyValidator.swift`
- Test: `macos/Saathi/Tests/SaathiKitTests/KeyValidatorTests.swift`

**Interfaces:**
- Consumes: `ProviderKind`, `SaathiProvider` from Task 1.
- Produces: `KeyCheck` enum with cases `.valid`, `.rejected(String)`, `.unreachable(String)`; `KeyValidator(urlSession:)` and `func check(_ kind: ProviderKind, key: String) async -> KeyCheck`. Tasks 5 and 6 call `check`.

- [ ] **Step 1: Write the failing test**

Create `macos/Saathi/Tests/SaathiKitTests/KeyValidatorTests.swift`:

```swift
//
//  KeyValidatorTests.swift
//  SaathiKitTests
//
//  A wrong key and an aeroplane-mode laptop must never produce the same sentence. That is the whole
//  point of this type having three outcomes rather than a Bool.
//

import Foundation
import XCTest
@testable import SaathiContract
@testable import SaathiKit

final class KeyValidatorTests: XCTestCase {

    func testA200MeansTheKeyWorks() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 200))
        let result = await validator.check(.openai, key: "sk-good")
        XCTAssertEqual(result, .valid)
    }

    func testA401NamesTheVendorThatRefused() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 401))
        guard case let .rejected(message) = await validator.check(.openai, key: "sk-bad") else {
            return XCTFail("a 401 must be a rejection, not a transport problem")
        }
        XCTAssertTrue(message.contains("OpenAI"), "the person needs to know who refused: \(message)")
    }

    func testA403IsAlsoARejection() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 403))
        guard case .rejected = await validator.check(.anthropic, key: "sk-ant-bad") else {
            return XCTFail("403 is the key being refused, not the network failing")
        }
    }

    /// The distinction that matters most: someone offline must not be told their key is wrong and
    /// go and generate a new one.
    func testATransportFailureIsNotARejection() async {
        let validator = KeyValidator(urlSession: .keyStubFailing())
        guard case let .unreachable(message) = await validator.check(.openai, key: "sk-good") else {
            return XCTFail("a dead network must not read as a bad key")
        }
        XCTAssertFalse(message.contains("did not accept"), "that wording belongs to rejection only")
    }

    /// A 500 is the vendor's problem, not the key's.
    func testAServerErrorIsUnreachableRatherThanRejected() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 500))
        guard case .unreachable = await validator.check(.openai, key: "sk-good") else {
            return XCTFail("a 500 says nothing about whether the key is valid")
        }
    }

    /// Pasting from a password manager or a terminal brings a newline along more often than not.
    func testAPastedKeyWithATrailingNewlineStillValidates() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 200))
        XCTAssertEqual(await validator.check(.openai, key: "sk-good\n"), .valid)
    }

    func testAnEmptyKeyIsRejectedWithoutAskingTheVendor() async {
        let validator = KeyValidator(urlSession: .keyStubFailing())
        guard case .rejected = await validator.check(.openai, key: "   ") else {
            return XCTFail("an empty key needs no round trip to be wrong")
        }
    }

    /// Each vendor is asked in its own dialect. Anthropic refuses a Bearer header and OpenAI ignores
    /// x-api-key, so getting this wrong would make every key look invalid.
    func testEachVendorIsAskedTheWayItExpects() async {
        KeyStubProtocol.reset(status: 200)
        _ = await KeyValidator(urlSession: .keyStub(status: 200)).check(.openai, key: "sk-o")
        XCTAssertEqual(KeyStubProtocol.lastRequest?.url?.host, "api.openai.com")
        XCTAssertEqual(
            KeyStubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-o")

        KeyStubProtocol.reset(status: 200)
        _ = await KeyValidator(urlSession: .keyStub(status: 200)).check(.anthropic, key: "sk-a")
        XCTAssertEqual(KeyStubProtocol.lastRequest?.url?.host, "api.anthropic.com")
        XCTAssertEqual(KeyStubProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-a")
        XCTAssertEqual(
            KeyStubProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    /// Providers that take no key of their own cannot be checked, and saying "valid" would be a lie.
    func testAProviderThatNeedsNoKeyCannotBeChecked() async {
        let validator = KeyValidator(urlSession: .keyStub(status: 200))
        guard case .rejected = await validator.check(.local, key: "anything") else {
            return XCTFail("local takes no key; there is nothing here to validate")
        }
    }
}

// MARK: - A URLSession that answers without a network

final class KeyStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var shouldFail = false
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset(status: Int, shouldFail: Bool = false) {
        self.status = status
        self.shouldFail = shouldFail
        self.lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        // `URLProtocol` strips the body but keeps the headers, which is what these tests assert on.
        Self.lastRequest = request

        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

extension URLSession {
    static func keyStub(status: Int) -> URLSession {
        KeyStubProtocol.reset(status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func keyStubFailing() -> URLSession {
        KeyStubProtocol.reset(status: 0, shouldFail: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KeyStubProtocol.self]
        return URLSession(configuration: configuration)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter KeyValidatorTests`
Expected: FAIL to compile — `cannot find 'KeyValidator' in scope`.

- [ ] **Step 3: Write the implementation**

Create `macos/Saathi/Sources/SaathiKit/KeyValidator.swift`:

```swift
//
//  KeyValidator.swift
//  SaathiKit
//
//  Asking a vendor whether a key works, before anything is saved.
//
//  Three outcomes rather than a Bool, because "that key was refused" and "I could not reach OpenAI"
//  send a person to two completely different places. Collapsing them would send someone who is
//  simply offline off to generate a replacement key.
//
//  Both endpoints are model lists: free, instant, and unambiguous about authentication.
//

import Foundation
import SaathiContract

public enum KeyCheck: Equatable, Sendable {
    case valid
    /// The vendor said no. The message names which vendor, because a panel with two key fields in
    /// it needs to say which of them is the problem.
    case rejected(String)
    /// Nothing could be concluded — no network, DNS failure, or the vendor having a bad day.
    case unreachable(String)
}

public struct KeyValidator: Sendable {

    private let urlSession: URLSession

    public init(urlSession: URLSession = URLSession(configuration: .ephemeral)) {
        self.urlSession = urlSession
    }

    /// Where each vendor is asked, and what it is called when telling a person it said no.
    private struct Probe {
        let url: URL
        let name: String
    }

    private func probe(for kind: ProviderKind) -> Probe? {
        switch kind {
        case .openai: return Probe(url: URL(string: "https://api.openai.com/v1/models")!, name: "OpenAI")
        case .anthropic: return Probe(url: URL(string: "https://api.anthropic.com/v1/models")!, name: "Anthropic")
        case .sarvam: return Probe(url: URL(string: "https://api.sarvam.ai/v1/models")!, name: "Sarvam")
        case .local, .hosted: return nil
        }
    }

    public func check(_ kind: ProviderKind, key: String) async -> KeyCheck {
        guard let probe = probe(for: kind) else {
            return .rejected("\(kind.rawValue) mode takes no key of its own, so there is nothing to check here.")
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected("Paste a \(probe.name) key first.")
        }

        var request = URLRequest(url: probe.url)
        request.httpMethod = "GET"
        // The header and its prefix come from the contract row, so a new vendor is a row in the
        // schema rather than another branch here.
        let row = SaathiProvider.of(kind)
        if let header = row.authorizationHeader(credential: trimmed) {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        // Anthropic refuses any request without this, key or no key, and the refusal looks exactly
        // like a bad key if the header is missing.
        if kind == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("\(probe.name) gave an answer that could not be read.")
            }
            switch http.statusCode {
            case 200...299:
                return .valid
            case 401, 403:
                return .rejected("\(probe.name) did not accept that key.")
            default:
                // Anything else says nothing about the key — a 429 or a 500 is the vendor's state,
                // not the credential's, and telling someone their key is bad on a 500 is a lie.
                return .unreachable("\(probe.name) answered \(http.statusCode). That is not about your key; try again shortly.")
            }
        } catch {
            return .unreachable("Could not reach \(probe.name). Are you online?")
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd macos/Saathi && swift test --filter KeyValidatorTests`
Expected: PASS (9 tests).

Then the whole suite: `cd macos/Saathi && swift test` — expected PASS.

Note on the stub: `KeyStubProtocol` uses static mutable state, so these tests must not run in parallel with each other. XCTest runs tests within a class serially by default, which is why the stub lives in one file and is not shared with `VoiceTests`' own private stub. Do not make it `internal` and reuse it across test classes.

- [ ] **Step 5: Commit**

```bash
git add macos/Saathi/Sources/SaathiKit/KeyValidator.swift macos/Saathi/Tests/SaathiKitTests/KeyValidatorTests.swift
git commit -m "$(cat <<'MSG'
KeyValidator: ask the vendor before saving anything

Three outcomes rather than a Bool. "That key was refused" and "I could not reach
OpenAI" send a person to two different places, and collapsing them would send
someone who is merely offline away to generate a replacement key.

Each vendor is asked in its own dialect — Anthropic refuses a Bearer header, and
without anthropic-version its refusal is indistinguishable from a bad key.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: The realtime lane opens the right socket, in a chosen voice

This is the task that makes bring-your-own-key voice work at all. At the end of it, the lane is
usable by hand-writing a `shell.json` — no UI needed, and worth verifying that way before any UI
exists.

**Files:**
- Modify: `macos/Saathi/Sources/SaathiKit/RealtimeVoiceSession.swift:189` (`resolveConnection`) and its `sessionUpdate()`
- Modify: `macos/Saathi/Sources/SaathiKit/VoiceSession.swift:69` (the factory's key check)
- Modify: `macos/Saathi/Sources/SaathiKit/ChainVoiceSession.swift:193` (the credential line)
- Modify: `macos/Saathi/Sources/SaathiKit/ProviderReport.swift:40` (`keyLine`)
- Test: `macos/Saathi/Tests/SaathiKitTests/VoiceTests.swift` (append)

**Interfaces:**
- Consumes: `credential(for:)`, `resolvedVoiceModel`, `resolvedVoice` from Task 1.
- Produces: no new public API. `RealtimeVoiceSession.socketURL(baseURL:model:)` keeps its signature.

- [ ] **Step 1: Write the failing test**

Append to `macos/Saathi/Tests/SaathiKitTests/VoiceTests.swift`:

```swift
// MARK: - The socket is opened with a voice model, not the thinking model

/// The bug this guards: `resolveConnection` built its URL from `resolvedModel`, which falls back to
/// the provider row's `defaultModel` — `gpt-4o-mini` for OpenAI — and is therefore never empty, so
/// the `.isEmpty ? "gpt-realtime" : …` guard meant to catch it was dead code. Bring-your-own-key
/// voice could never connect, and the failure arrived from the provider as an opaque socket close.
final class RealtimeConnectionTests: XCTestCase {

    func testTheSocketCarriesTheVoiceModel() async throws {
        let configuration = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        let session = RealtimeVoiceSession(configuration: configuration)
        let connection = try await session.resolveConnection()

        XCTAssertEqual(connection.model, "gpt-realtime")
        XCTAssertTrue(
            connection.url.absoluteString.contains("model=gpt-realtime"),
            "opened with \(connection.url.absoluteString)")
        XCTAssertFalse(
            connection.url.absoluteString.contains("gpt-4o-mini"),
            "the thinking model must never reach the socket")
    }

    /// Someone pinning a thinking model must not silently re-break the socket.
    func testPinningTheThinkingModelDoesNotChangeTheSocket() async throws {
        let configuration = SaathiConfiguration(provider: .openai, model: "gpt-4o", openaiKey: "sk-o")
        let session = RealtimeVoiceSession(configuration: configuration)
        let connection = try await session.resolveConnection()

        XCTAssertEqual(connection.model, "gpt-realtime")
        XCTAssertFalse(connection.url.absoluteString.contains("gpt-4o&"))
    }

    func testTheVoiceModelCanBePinnedOnItsOwn() async throws {
        let configuration = SaathiConfiguration(
            provider: .openai, openaiKey: "sk-o", voiceModel: "gpt-realtime-mini")
        let session = RealtimeVoiceSession(configuration: configuration)
        let connection = try await session.resolveConnection()

        XCTAssertEqual(connection.model, "gpt-realtime-mini")
    }

    /// The vendor field must be what the socket presents, or a config holding two keys would open
    /// OpenAI's socket with an Anthropic key.
    func testTheSocketPresentsTheOpenAIKeyNotTheOtherOne() async throws {
        let configuration = SaathiConfiguration(
            provider: .openai, openaiKey: "sk-openai", anthropicKey: "sk-ant")
        let session = RealtimeVoiceSession(configuration: configuration)
        let connection = try await session.resolveConnection()

        XCTAssertEqual(connection.credential, "sk-openai")
    }

    func testAMissingKeySaysSoRatherThanOpeningAnUnauthenticatedSocket() async {
        let session = RealtimeVoiceSession(configuration: SaathiConfiguration(provider: .openai))
        do {
            _ = try await session.resolveConnection()
            XCTFail("an unauthenticated socket must never be opened")
        } catch {
            XCTAssertTrue("\(error)".contains("key"), "got: \(error)")
        }
    }
}

// MARK: - A voice is actually asked for

/// A companion whose premise is sounding like a person should not accept whatever the provider
/// happens to default to this month.
final class RealtimeVoiceNameTests: XCTestCase {

    func testTheSessionAsksForTheConfiguredVoice() throws {
        let configuration = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        let session = RealtimeVoiceSession(configuration: configuration)
        let update = session.sessionUpdateForTesting()

        let sessionObject = try XCTUnwrap(update["session"] as? [String: Any])
        let audio = try XCTUnwrap(sessionObject["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "cedar")
    }

    func testTheVoiceCanBeChanged() throws {
        let configuration = SaathiConfiguration(provider: .openai, openaiKey: "sk-o", voice: "marin")
        let session = RealtimeVoiceSession(configuration: configuration)
        let update = session.sessionUpdateForTesting()

        let sessionObject = try XCTUnwrap(update["session"] as? [String: Any])
        let audio = try XCTUnwrap(sessionObject["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        XCTAssertEqual(output["voice"] as? String, "marin")
    }

    /// The format has to survive adding the voice beside it, or every session goes silent.
    func testTheOutputFormatIsStillThere() throws {
        let session = RealtimeVoiceSession(
            configuration: SaathiConfiguration(provider: .openai, openaiKey: "sk-o"))
        let update = session.sessionUpdateForTesting()

        let sessionObject = try XCTUnwrap(update["session"] as? [String: Any])
        let audio = try XCTUnwrap(sessionObject["audio"] as? [String: Any])
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
    }
}

// MARK: - The factory and the report read the vendor field

final class VendorKeyPlumbingTests: XCTestCase {

    /// The factory's own key check is a separate code path from the session's, and a config holding
    /// only a vendor key must not be refused before the session is ever built.
    func testTheFactoryAcceptsAVendorKey() throws {
        let configuration = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        XCTAssertNoThrow(
            try VoiceSessionFactory.make(configuration: configuration, speaker: RecordingSpeaker()))
    }

    func testTheFactoryStillRefusesWhenThereIsNoKeyAtAll() {
        let configuration = SaathiConfiguration(provider: .openai)
        XCTAssertThrowsError(
            try VoiceSessionFactory.make(configuration: configuration, speaker: RecordingSpeaker()))
    }

    func testTheReportSeesAVendorKey() {
        let configuration = SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-ant")
        let report = ProviderReport.describe(configuration)
        XCTAssertTrue(report.contains("your key   set"), "got:\n\(report)")
    }
}
```

`RecordingSpeaker` already exists in `macos/Saathi/Tests/SaathiKitTests/SpeakerTests.swift`. If it is
declared `private` there, change it to `final class RecordingSpeaker` (internal) so both files see
one implementation rather than two — do not copy it.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter RealtimeConnectionTests`
Expected: FAIL — `resolveConnection` is not visible, `sessionUpdateForTesting` does not exist, and the model assertion fails because the socket carries `gpt-4o-mini`.

- [ ] **Step 3: Fix `resolveConnection`**

In `macos/Saathi/Sources/SaathiKit/RealtimeVoiceSession.swift`, replace the own-key branch of `resolveConnection()`:

```swift
        if !row.requiresToken {
            // The vendor field first, then the legacy shared one. A config holding both an OpenAI
            // and an Anthropic key must present the OpenAI one here, not whichever was written last.
            guard let key = configuration.credential(for: row.kind) else {
                throw VoiceError.notConfigured("\(row.kind.rawValue) mode needs an API key in ~/.saathi/shell.json")
            }
            // The VOICE model, never `resolvedModel`. A realtime socket opened with the thinking
            // model is refused by the provider, and the refusal arrives as an opaque socket close
            // that looks like a network problem — which is how this went unnoticed.
            let model = configuration.resolvedVoiceModel
            guard !model.isEmpty else {
                throw VoiceError.notConfigured(
                    "\(row.kind.rawValue) names no realtime voice model, so it has no socket to open")
            }
            guard let url = Self.socketURL(baseURL: configuration.resolvedProviderBaseURL, model: model) else {
                throw VoiceError.transport("cannot build a realtime URL for model \"\(model)\"")
            }
            return Connection(url: url, credential: key, model: model, host: url.host ?? "the provider")
        }
```

- [ ] **Step 4: Ask for a voice, and expose the session update to tests**

In the same file, in `sessionUpdate()`, replace the `"output"` line inside `"audio"`:

```swift
                "audio": [
                    "input": input,
                    "output": [
                        "format": ["type": "audio/pcm", "rate": Int(VoiceAudioEngine.sampleRate)],
                        // Chosen rather than defaulted. A companion whose whole premise is sounding
                        // like a person should not inherit whatever the provider picks this month.
                        "voice": configuration.resolvedVoice,
                    ],
                ],
```

And add, immediately after `sessionUpdate()`:

```swift
    /// The session update as it would be sent. Exists so the voice and the audio format can be
    /// asserted on without opening a socket — the two things that make a session silent if wrong.
    func sessionUpdateForTesting() -> [String: Any] { sessionUpdate() }
```

- [ ] **Step 5: Read the vendor key in the other three places**

`macos/Saathi/Sources/SaathiKit/VoiceSession.swift`, the factory's key check:

```swift
        if row.requiresKey, configuration.credential(for: row.kind) == nil {
            throw VoiceError.notConfigured(
                "\(row.kind.rawValue) needs your own API key in ~/.saathi/shell.json before it can be spoken to.")
        }
```

`macos/Saathi/Sources/SaathiKit/ChainVoiceSession.swift`, the credential line:

```swift
        let credential = (row.requiresToken ? configuration.token : configuration.credential(for: row.kind)) ?? ""
```

`macos/Saathi/Sources/SaathiKit/ProviderReport.swift`, `keyLine`:

```swift
        let present = configuration.credential(for: row.kind) != nil
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test`
Expected: PASS, whole suite.

- [ ] **Step 7: Verify by hand that a real key now speaks**

This is the step that proves the task. Ask the user for an OpenAI key if one is not already in
`~/.saathi/shell.json`, then:

```bash
mkdir -p ~/.saathi
cat > ~/.saathi/shell.json <<'JSON'
{ "provider": "openai", "openaiKey": "REPLACE_WITH_REAL_KEY" }
JSON
chmod 600 ~/.saathi/shell.json
cd macos/Saathi && swift run saathi provider
```

Expected: the report says `provider openai`, `your key set`, `lane realtime`. Then build and run the
app, hold control+option, and say something — expect a spoken reply in the `cedar` voice.

If the key is not available yet, stop here and report that Steps 1–6 are done and Step 7 is blocked
on a key. Do not mark the task complete.

- [ ] **Step 8: Commit**

```bash
git add macos/Saathi/Sources/SaathiKit/RealtimeVoiceSession.swift \
  macos/Saathi/Sources/SaathiKit/VoiceSession.swift \
  macos/Saathi/Sources/SaathiKit/ChainVoiceSession.swift \
  macos/Saathi/Sources/SaathiKit/ProviderReport.swift \
  macos/Saathi/Tests/SaathiKitTests/VoiceTests.swift
git commit -m "$(cat <<'MSG'
The realtime socket opens with a voice model, and asks for a voice

Bring-your-own-key voice has never been able to connect. resolveConnection built the
socket URL from resolvedModel — gpt-4o-mini for OpenAI — and the guard meant to catch
that compared against empty, which resolvedModel never is. The provider refused the
socket, and the refusal arrived as an opaque close that looked like the network.

While here: the session never asked for a voice, so a companion meant to sound like a
person took whatever the provider defaulted to. It asks for cedar now.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: The island grows a Setup tab

**Files:**
- Modify: `macos/Saathi/Sources/SaathiShell/IslandModel.swift` (new published properties, new actions, `IslandTab`, `KeyFieldState`)
- Create: `macos/Saathi/Sources/SaathiShell/IslandSetupView.swift`
- Modify: `macos/Saathi/Sources/SaathiShell/IslandHomeView.swift` (tab strip; `IslandHomeView` body switches on `model.tab`)
- Test: `macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift` (append)

**Interfaces:**
- Consumes: `KeyCheck` (Task 3), `SetupPlan` (Task 2), `ProviderKind` (Task 1).
- Produces: `IslandTab` (`.home`, `.setup`); `KeyFieldState` (`.empty`, `.editing`, `.checking`, `.checked(KeyCheck)`, `.saved(masked: String)`); `IslandModel.tab`, `.openAIKeyState`, `.anthropicKeyState`, `.planExplanation`, `.unusedKeyNote`; `IslandActions.onCheckKey: (ProviderKind, String) -> Void`, `.onSaveKeys: (String, String) -> Void`; `IslandModel.masked(_:) -> String`. Task 6 sets these and supplies the actions.

- [ ] **Step 1: Write the failing test**

Append to `macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift`:

```swift
// MARK: - The Setup tab's model

@MainActor
final class IslandSetupModelTests: XCTestCase {

    func testTheIslandStartsOnHome() {
        XCTAssertEqual(IslandModel().tab, .home)
        XCTAssertEqual(IslandModel().openAIKeyState, .empty)
        XCTAssertEqual(IslandModel().anthropicKeyState, .empty)
        XCTAssertEqual(IslandModel().planExplanation, "")
        XCTAssertEqual(IslandModel().unusedKeyNote, "")
    }

    func testTheTabSwitches() {
        let model = IslandModel()
        model.tab = .setup
        XCTAssertEqual(model.tab, .setup)
    }

    /// A key is shown, never re-shown in full. Four trailing characters is enough to tell two keys
    /// apart and not enough to be a credential.
    func testASavedKeyIsMaskedToItsLastFourCharacters() {
        XCTAssertEqual(IslandModel.masked("sk-proj-abcdefghijkl"), "sk-…ijkl")
        XCTAssertEqual(IslandModel.masked("sk-ant-api03-zzzz9999"), "sk-…9999")
    }

    /// A short or malformed key must not be echoed back in full by the masking itself.
    func testMaskingNeverEchoesAShortKey() {
        XCTAssertEqual(IslandModel.masked("abc"), "sk-…")
        XCTAssertEqual(IslandModel.masked(""), "sk-…")
    }

    func testAFieldCanBeCheckingAndThenChecked() {
        let model = IslandModel()
        model.openAIKeyState = .checking
        XCTAssertEqual(model.openAIKeyState, .checking)
        model.openAIKeyState = .checked(.rejected("OpenAI did not accept that key."))
        XCTAssertEqual(model.openAIKeyState, .checked(.rejected("OpenAI did not accept that key.")))
    }

    /// The button must be inert while a check is in flight, or a double-click fires two round trips
    /// and the second answer overwrites the first.
    func testAFieldIsBusyOnlyWhileChecking() {
        XCTAssertTrue(KeyFieldState.checking.isBusy)
        XCTAssertFalse(KeyFieldState.empty.isBusy)
        XCTAssertFalse(KeyFieldState.editing.isBusy)
        XCTAssertFalse(KeyFieldState.checked(.valid).isBusy)
        XCTAssertFalse(KeyFieldState.saved(masked: "sk-…abcd").isBusy)
    }

    /// Only a validated key may be saved. Without this the panel would happily bank a key the vendor
    /// refused a second ago.
    func testOnlyACheckedValidFieldCountsAsValid() {
        XCTAssertTrue(KeyFieldState.checked(.valid).isValid)
        XCTAssertTrue(KeyFieldState.saved(masked: "sk-…abcd").isValid)
        XCTAssertFalse(KeyFieldState.checked(.rejected("no")).isValid)
        XCTAssertFalse(KeyFieldState.checked(.unreachable("offline")).isValid)
        XCTAssertFalse(KeyFieldState.empty.isValid)
        XCTAssertFalse(KeyFieldState.editing.isValid)
    }

    func testTheActionsDefaultToDoingNothing() {
        let actions = IslandActions()
        actions.onCheckKey(.openai, "sk-o")
        actions.onSaveKeys("sk-o", "sk-a")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter IslandSetupModelTests`
Expected: FAIL to compile — no `tab`, no `KeyFieldState`, no `masked`.

- [ ] **Step 3: Extend the model**

In `macos/Saathi/Sources/SaathiShell/IslandModel.swift`, add above `IslandModel`:

```swift
/// Which face of the island is showing. Two, deliberately: a panel that grows a third tab is a
/// panel that has become a settings window, which this is not.
public enum IslandTab: Equatable, Sendable {
    case home
    case setup
}

/// Where one key field has got to. `saved` carries the masked form because the full key is never
/// put back into an editable field — the file is the store, not the view.
public enum KeyFieldState: Equatable, Sendable {
    case empty
    case editing
    case checking
    case checked(KeyCheck)
    case saved(masked: String)

    /// True only while a round trip is in flight, so the button can be made inert. A second click
    /// during a check starts a second request whose answer would land after the first and win.
    public var isBusy: Bool { self == .checking }

    /// A key may be saved only when a vendor has actually accepted it.
    public var isValid: Bool {
        switch self {
        case .checked(.valid), .saved: return true
        default: return false
        }
    }
}
```

Add to `IslandModel`'s properties:

```swift
    /// Which face of the island is showing.
    @Published public var tab: IslandTab = .home
    @Published public var openAIKeyState: KeyFieldState = .empty
    @Published public var anthropicKeyState: KeyFieldState = .empty
    /// The plan's one-line explanation of what it chose and what that means.
    @Published public var planExplanation: String = ""
    /// Says out loud that a stored key is not being used. Empty when every stored key is in play.
    @Published public var unusedKeyNote: String = ""
```

and as a static member of `IslandModel`:

```swift
    /// A saved key, shown so two keys can be told apart and no more. Never a prefix of the secret
    /// itself: a logged or shoulder-surfed prefix is still part of a credential, and the last four
    /// characters of a vendor key are not enough to do anything with.
    public static func masked(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return "sk-…" }
        return "sk-…" + String(trimmed.suffix(4))
    }
```

Add to `IslandActions`:

```swift
    /// Ask the vendor whether this key works. The panel never validates anything itself.
    public var onCheckKey: (ProviderKind, String) -> Void = { _, _ in }
    /// Save both keys and reconfigure. Called only when at least one field is valid.
    public var onSaveKeys: (String, String) -> Void = { _, _ in }
```

`IslandModel.swift` must now `import SaathiContract` for `ProviderKind` (it already imports `SaathiKit`
for `Permission`; add the contract import rather than re-exporting).

- [ ] **Step 4: Write the Setup view**

Create `macos/Saathi/Sources/SaathiShell/IslandSetupView.swift`:

```swift
//
//  IslandSetupView.swift
//  SaathiShell
//
//  The island's second face: two keys, a check each, and one sentence saying what Saathi became.
//
//  The view holds the text being typed and nothing else. Validation, the plan and the file all live
//  behind the actions, so this file can be looked at and changed without touching anything that can
//  leak a key.
//

import SaathiContract
import SaathiKit
import SwiftUI

struct IslandSetupView: View {
    @ObservedObject var display: IslandDisplay
    @ObservedObject var model: IslandModel
    let actions: IslandActions

    /// Held here rather than in the model: a key being typed is not application state, and keeping
    /// it out of the observable object means it is never published to anything else.
    @State private var openAIKey = ""
    @State private var anthropicKey = ""

    private var canSave: Bool {
        model.openAIKeyState.isValid || model.anthropicKeyState.isValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Give me a key and I will set myself up")
                .font(.system(size: 13.5, weight: .bold))
                .foregroundColor(.white)

            keyField(
                title: "OpenAI",
                note: "voice and thinking",
                text: $openAIKey,
                state: model.openAIKeyState,
                kind: .openai)

            keyField(
                title: "Anthropic",
                note: "saved for later — nothing uses it yet",
                text: $anthropicKey,
                state: model.anthropicKeyState,
                kind: .anthropic)

            if !model.planExplanation.isEmpty {
                Text(model.planExplanation)
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.unusedKeyNote.isEmpty {
                Text(model.unusedKeyNote)
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.45))
            }

            HStack(spacing: 8) {
                Button(action: { actions.onSaveKeys(openAIKey, anthropicKey) }) {
                    Text("Save and use these")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(canSave
                            ? Color(PointerBuddyView.tint)
                            : Color(red: 0x26 / 255, green: 0x26 / 255, blue: 0x26 / 255)))
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func keyField(
        title: String,
        note: String,
        text: Binding<String>,
        state: KeyFieldState,
        kind: ProviderKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundColor(Color.white.opacity(0.4))
            }
            HStack(spacing: 6) {
                // SecureField so a key is not on screen while it is typed, and not in a screenshot.
                SecureField("sk-…", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.10)))
                    .onChange(of: text.wrappedValue) { _ in
                        // Typing invalidates an earlier verdict: a green tick next to a key that has
                        // since been edited is the panel lying about what it checked.
                        setState(kind, .editing)
                    }

                Button(action: { actions.onCheckKey(kind, text.wrappedValue) }) {
                    Text(state.isBusy ? "Checking…" : "Check")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .disabled(state.isBusy)
            }
            verdict(for: state)
        }
    }

    private func setState(_ kind: ProviderKind, _ state: KeyFieldState) {
        switch kind {
        case .openai: model.openAIKeyState = state
        case .anthropic: model.anthropicKeyState = state
        default: break
        }
    }

    @ViewBuilder
    private func verdict(for state: KeyFieldState) -> some View {
        switch state {
        case .empty, .editing, .checking:
            EmptyView()
        case let .checked(check):
            switch check {
            case .valid:
                Text("✓ that key works")
                    .font(.system(size: 9.5)).foregroundColor(.green)
            case let .rejected(message):
                Text(message)
                    .font(.system(size: 9.5)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case let .unreachable(message):
                // Deliberately not red. Being offline is not the same as being wrong, and colouring
                // it like a failure sends people off to make a new key.
                Text(message)
                    .font(.system(size: 9.5)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .saved(masked):
            Text("saved · \(masked)")
                .font(.system(size: 9.5)).foregroundColor(Color.white.opacity(0.5))
        }
    }
}
```

- [ ] **Step 5: Add the tab strip**

In `macos/Saathi/Sources/SaathiShell/IslandHomeView.swift`, change `IslandHomeView.body` so the body
below the top band switches on the tab:

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBand
                .padding(.horizontal, 14)
                .frame(height: display.topBandHeight)
            VStack(alignment: .leading, spacing: 0) {
                tabStrip
                switch model.tab {
                case .home:
                    HStack(alignment: .top, spacing: 18) {
                        leftColumn
                        rightColumn
                    }
                case .setup:
                    IslandSetupView(display: display, model: model, actions: actions)
                }
                bottomRow
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: the two faces

    private var tabStrip: some View {
        HStack(spacing: 6) {
            tabButton("Home", .home)
            tabButton("Setup", .setup)
            Spacer()
        }
        .padding(.bottom, 8)
    }

    private func tabButton(_ title: String, _ tab: IslandTab) -> some View {
        Button(action: { model.tab = tab }) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(model.tab == tab ? .white : Color.white.opacity(0.45))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(model.tab == tab ? Color.white.opacity(0.16) : .clear))
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd macos/Saathi && swift test --filter IslandSetupModelTests`
Expected: PASS (8 tests).

Then the whole suite: `cd macos/Saathi && swift test` — expected PASS. `PanelTests` builds the island
views; if it fails to compile, the view signatures have drifted from what it constructs — fix the
test's construction, not by weakening the view.

- [ ] **Step 7: Commit**

```bash
git add macos/Saathi/Sources/SaathiShell/IslandModel.swift \
  macos/Saathi/Sources/SaathiShell/IslandSetupView.swift \
  macos/Saathi/Sources/SaathiShell/IslandHomeView.swift \
  macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift
git commit -m "$(cat <<'MSG'
The island's second face: paste a key, and it says what it became

Two secure fields, a Check each, and one sentence explaining the result. The key being
typed lives in the view and nowhere else, so it is never published to an observable
object; a saved key comes back only as its last four characters.

Editing a field clears an earlier verdict, because a green tick beside a key that has
since been changed is the panel lying about what it checked.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: Saving keys reconfigures a live Saathi, with no relaunch

**Files:**
- Modify: `macos/Saathi/Sources/SaathiShell/AppController.swift` (`configuration` becomes `var`; `startVoice(with:)`; `reconfigure(_:)`; the Setup wiring in `wireNotch`)
- Test: `macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift` (append the presentation tests)

**Interfaces:**
- Consumes: `SetupPlan.make`/`applied` (Task 2), `KeyValidator.check` (Task 3), `IslandModel`/`IslandActions` (Task 5), `ConfigurationStore.save` (existing).
- Produces: no new public API outside `AppController`.

- [ ] **Step 1: Write the failing test**

The controller needs a window and a voice session, so what is testable is the presentation rule it
applies. Extract it as a static function and test that. Append to
`macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift`:

```swift
// MARK: - What the panel says after a save

@MainActor
final class SetupPresentationTests: XCTestCase {

    func testAnUnusedStoredKeyIsNamedOutLoud() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: true)
        let note = AppController.unusedKeyNote(for: plan)
        XCTAssertTrue(note.contains("Anthropic"), "got: \(note)")
        XCTAssertTrue(note.lowercased().contains("nothing uses it") || note.lowercased().contains("not used"),
                      "the note must say it is unused, not merely mention it: \(note)")
    }

    func testThereIsNoNoteWhenEveryStoredKeyIsInUse() {
        let plan = SetupPlan.make(openAIKeyValid: true, anthropicKeyValid: false)
        XCTAssertEqual(AppController.unusedKeyNote(for: plan), "")
    }

    func testTheProviderTitleReadsAsAProviderAndAModel() {
        let configuration = SaathiConfiguration(provider: .openai, openaiKey: "sk-o")
        XCTAssertEqual(AppController.providerTitle(for: configuration), "openai · gpt-4o-mini")
    }

    /// The three privacy lines are the most consequential sentences in the app; they must stay
    /// pinned to the lane and not drift into marketing.
    func testThePrivacyLineFollowsTheLane() {
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")),
            "your voice leaves as audio")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .anthropic, anthropicKey: "sk-a")),
            "only the transcript is sent")
        XCTAssertEqual(
            AppController.privacyLine(for: SaathiConfiguration(provider: .local)),
            "stays on this machine")
    }

    /// First run opens on Setup, and only first run. "First run" is "no provider has a credential",
    /// which is a fact about the config rather than a flag that can get out of step with it.
    func testTheIslandOpensOnSetupOnlyWhileNothingIsConfigured() {
        XCTAssertEqual(AppController.openingTab(for: SaathiConfiguration()), .setup)
        XCTAssertEqual(
            AppController.openingTab(for: SaathiConfiguration(provider: .openai, openaiKey: "sk-o")),
            .home)
        XCTAssertEqual(
            AppController.openingTab(for: SaathiConfiguration(provider: .hosted, token: "tok")),
            .home)
        // A local setup with Ollama actually running is a legitimate configuration, but nothing on
        // disk can tell us that, so an empty config still opens on Setup.
        XCTAssertEqual(AppController.openingTab(for: SaathiConfiguration(provider: .local)), .setup)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter SetupPresentationTests`
Expected: FAIL to compile — `AppController` has no `unusedKeyNote`, `providerTitle`, `privacyLine` or `openingTab`.

- [ ] **Step 3: Extract the presentation rules**

In `macos/Saathi/Sources/SaathiShell/AppController.swift`, add these static members to `AppController`:

```swift
    // MARK: what the island says about a configuration
    //
    // Static and pure so the wording can be tested without a window, a session or a key. These are
    // the sentences that tell someone where their voice goes, which makes them worth pinning down.

    static func providerTitle(for configuration: SaathiConfiguration) -> String {
        "\(configuration.resolvedProvider.rawValue) · \(configuration.resolvedModel)"
    }

    static func privacyLine(for configuration: SaathiConfiguration) -> String {
        let row = configuration.providerRow
        if row.voice == .realtime { return "your voice leaves as audio" }
        return row.sendsDataOffMachine ? "only the transcript is sent" : "stays on this machine"
    }

    /// Says out loud that a key was saved and is not being used. Empty when there is nothing to
    /// confess — a panel that quietly banks an Anthropic key lets someone believe Claude is
    /// answering them.
    static func unusedKeyNote(for plan: SetupPlan) -> String {
        guard !plan.storedButUnused.isEmpty else { return "" }
        let names = plan.storedButUnused.map { $0.rawValue.capitalized }.joined(separator: " and ")
        return "\(names) key saved. Nothing uses it yet."
    }

    /// Which face the island opens on. Derived from the configuration rather than from a
    /// "has onboarded" flag, so it cannot get out of step with what is actually configured.
    static func openingTab(for configuration: SaathiConfiguration) -> IslandTab {
        let hasKey = ProviderKind.allCases.contains { configuration.credential(for: $0) != nil }
        let hasToken = !(configuration.token ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasKey || hasToken) ? .home : .setup
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd macos/Saathi && swift test --filter SetupPresentationTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Make the configuration swappable**

In `AppController`, change the stored property and thread it through the session builder:

```swift
    private var configuration: SaathiConfiguration
    private let validator = KeyValidator()
    /// Set while a reconfigure is waiting for an open turn to finish, so a second Save does not
    /// start a second teardown alongside the first.
    private var reconfiguring = false
```

Change `startVoice()` to take the configuration explicitly — one code path builds a session, and
`reconfigure` uses the same one rather than a near-copy:

```swift
    private func startVoice() { startVoice(with: configuration) }

    private func startVoice(with configuration: SaathiConfiguration) {
        voiceStartFailure = nil
        do {
            let session = try VoiceSessionFactory.make(configuration: configuration, speaker: speaker)
            // …body unchanged from the current implementation…
```

(The rest of `startVoice`'s body is unchanged; only the signature, the `voiceStartFailure = nil`
reset, and the `configuration` it reads are different.)

- [ ] **Step 6: Write `reconfigure`**

Add to `AppController`:

```swift
    /// Swaps in a new configuration without a relaunch.
    ///
    /// The order is not negotiable. A turn is closed before anything is torn down — `TurnCoordinator`
    /// exists because a turn that never opened must not be ended, and ripping a session out from
    /// under an open turn is the same bug approached from the other side. The old socket is closed
    /// before a new one opens, so two realtime sessions never hold the microphone at once.
    private func reconfigure(_ updated: SaathiConfiguration) async {
        guard !reconfiguring else { return }
        reconfiguring = true
        defer { reconfiguring = false }

        if let turns, turns.isOpen {
            _ = turns.close()
            handle(.keysReleased)
            // One beat for the turn to finish landing. Longer than this and a person notices;
            // shorter and the close races the teardown it exists to prevent.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        speaker.stop()
        await session?.stop()
        session = nil
        turns = nil

        configuration = updated
        startVoice(with: updated)
        applyConfigurationToIsland()
    }

    /// Re-fills everything the island says about where Saathi thinks. Called at startup and after
    /// every reconfigure, so the Home tab can never describe a provider that is no longer in use.
    private func applyConfigurationToIsland() {
        guard let notch else { return }
        notch.model.providerTitle = Self.providerTitle(for: configuration)
        notch.model.privacyLine = Self.privacyLine(for: configuration)
    }
```

- [ ] **Step 7: Wire the Setup actions**

In `wireNotch()`, replace the two hand-written `providerTitle` / `privacyLine` assignments with a call
to `applyConfigurationToIsland()`, set the opening tab, and add the two new actions:

```swift
        applyConfigurationToIsland()
        notch.model.companionVisible = true
        notch.model.tab = Self.openingTab(for: configuration)
        if notch.model.tab == .setup {
            notch.model.planExplanation =
                SetupPlan.make(openAIKeyValid: false, anthropicKeyValid: false).explanation
        }
```

and, alongside the existing action assignments:

```swift
        actions.onCheckKey = { [weak self] kind, key in
            guard let self, let notch = self.notch else { return }
            switch kind {
            case .openai: notch.model.openAIKeyState = .checking
            case .anthropic: notch.model.anthropicKeyState = .checking
            default: return
            }
            Task {
                let result = await self.validator.check(kind, key: key)
                await MainActor.run {
                    switch kind {
                    case .openai: notch.model.openAIKeyState = .checked(result)
                    case .anthropic: notch.model.anthropicKeyState = .checked(result)
                    default: break
                    }
                    self.refreshPlanExplanation()
                }
            }
        }

        actions.onSaveKeys = { [weak self] openAIKey, anthropicKey in
            guard let self, let notch = self.notch else { return }
            let plan = SetupPlan.make(
                openAIKeyValid: notch.model.openAIKeyState.isValid,
                anthropicKeyValid: notch.model.anthropicKeyState.isValid)
            let updated = plan.applied(
                to: self.configuration, openAIKey: openAIKey, anthropicKey: anthropicKey)

            do {
                try ConfigurationStore.save(updated, to: ConfigurationStore.defaultPath())
            } catch {
                self.handle(.failure("could not save your keys: \(error.localizedDescription)"))
                return
            }

            // Saved keys come back only as their last four characters; the full key is never put
            // back into a field.
            if plan.provider == .openai || plan.storedButUnused.contains(.openai) {
                notch.model.openAIKeyState = .saved(masked: IslandModel.masked(openAIKey))
            }
            if plan.provider == .anthropic || plan.storedButUnused.contains(.anthropic) {
                notch.model.anthropicKeyState = .saved(masked: IslandModel.masked(anthropicKey))
            }
            notch.model.planExplanation = plan.explanation
            notch.model.unusedKeyNote = Self.unusedKeyNote(for: plan)
            notch.model.tab = .home

            Task { await self.reconfigure(updated) }
        }
```

and the helper that keeps the sentence current while checks come back:

```swift
    /// The plan changes as each check lands, so the sentence under the fields follows it rather than
    /// appearing only after a save. Someone should be able to see what they are about to get.
    private func refreshPlanExplanation() {
        guard let notch else { return }
        let plan = SetupPlan.make(
            openAIKeyValid: notch.model.openAIKeyState.isValid,
            anthropicKeyValid: notch.model.anthropicKeyState.isValid)
        notch.model.planExplanation = plan.explanation
        notch.model.unusedKeyNote = Self.unusedKeyNote(for: plan)
    }
```

- [ ] **Step 8: Run the whole suite**

Run: `cd macos/Saathi && swift test`
Expected: PASS.

- [ ] **Step 9: Verify by hand**

```bash
rm -f ~/.saathi/shell.json
cd macos/Saathi && swift build && swift run SaathiApp
```

Check, in order:
1. Opening the island lands on **Setup** (no config exists).
2. Pasting the OpenAI key and clicking **Check** shows "✓ that key works".
3. Pasting a deliberately wrong key shows "OpenAI did not accept that key." in red.
4. Turning Wi-Fi off and clicking Check shows the orange unreachable wording, **not** the red one.
5. **Save and use these** switches to Home, which now reads `openai · gpt-4o-mini` and
   "your voice leaves as audio".
6. Holding control+option and speaking gets a spoken reply — **with no relaunch**.
7. `cat ~/.saathi/shell.json` shows both keys; `ls -l` shows `-rw-------`.

- [ ] **Step 10: Commit**

```bash
git add macos/Saathi/Sources/SaathiShell/AppController.swift \
  macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift
git commit -m "$(cat <<'MSG'
Saving a key reconfigures a running Saathi, with no relaunch

The voice session, the turn coordinator and everything the island says about where
Saathi thinks are rebuilt in place. A turn is closed before anything is torn down, and
the old socket is closed before a new one opens, so two realtime sessions never hold
the microphone at once.

Which face the island opens on is derived from whether anything is actually
configured, not from a flag that could get out of step with it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: The permission grant takes effect, whatever macOS does

**Files:**
- Create: `macos/Saathi/Sources/SaathiShell/AppRelauncher.swift`
- Modify: `macos/Saathi/Sources/SaathiShell/IslandModel.swift` (`needsRestart`, `onRestart`)
- Modify: `macos/Saathi/Sources/SaathiShell/IslandHomeView.swift` (the restart row in `rightColumn`)
- Modify: `macos/Saathi/Sources/SaathiShell/AppController.swift` (set `needsRestart` when the poll gives up; wire `onRestart`)
- Test: `macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift` (append)

**Interfaces:**
- Consumes: `IslandModel`, `IslandActions` (Task 5).
- Produces: `AppRelauncher.relaunch(bundleURL:launch:terminate:) async -> Bool` (`launch` and `terminate` both defaulted, so callers write `relaunch(bundleURL:)`); `IslandModel.needsRestart: Bool`; `IslandActions.onRestart: () -> Void`.

- [ ] **Step 1: Write the failing test**

Append to `macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift`:

```swift
// MARK: - Relaunching ourselves

@MainActor
final class RestartTests: XCTestCase {

    func testTheIslandDoesNotAskForARestartUntilSomethingNeedsOne() {
        XCTAssertFalse(IslandModel().needsRestart)
    }

    /// The bug this exists for: macOS asks an app requesting Input Monitoring to quit and reopen,
    /// then relaunches it through LaunchServices by code signature. An ad-hoc signed app has no
    /// stable identity to bring back, so it is quit and never reopened.
    func testTerminateHappensOnlyAfterTheNewInstanceIsConfirmedLaunched() async {
        var terminated = false
        let launched = await AppRelauncher.relaunch(
            bundleURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            launch: { _ in true },
            terminate: { terminated = true })

        XCTAssertTrue(launched)
        XCTAssertTrue(terminated)
    }

    /// A terminate that races the spawn is a quit with no reopen — which is the exact failure this
    /// code exists to replace, so it must not be reintroduced here.
    func testAFailedLaunchDoesNotTerminate() async {
        var terminated = false
        let launched = await AppRelauncher.relaunch(
            bundleURL: URL(fileURLWithPath: "/nonexistent/Nothing.app"),
            launch: { _ in false },
            terminate: { terminated = true })

        XCTAssertFalse(launched)
        XCTAssertFalse(terminated, "quitting after a failed relaunch leaves the person with nothing")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd macos/Saathi && swift test --filter RestartTests`
Expected: FAIL to compile — no `needsRestart`, no `AppRelauncher`.

- [ ] **Step 3: Write the relauncher**

Create `macos/Saathi/Sources/SaathiShell/AppRelauncher.swift`:

```swift
//
//  AppRelauncher.swift
//  SaathiShell
//
//  Bringing Saathi back ourselves, rather than trusting macOS to do it.
//
//  macOS asks an app that requests Input Monitoring to quit and reopen, and relaunches it through
//  LaunchServices by code signature. An ad-hoc signed build has no stable identity to come back to —
//  its cdhash changes on every build — so it is killed and never reopened. A properly signed build
//  fixes that, and this exists so the app does not depend on it: the grant takes effect either way.
//
//  The ordering is the whole point. Terminating before the new instance is confirmed launched is a
//  quit with no reopen, which is precisely the bug being replaced.
//

import AppKit
import Foundation

public enum AppRelauncher {

    /// Launches a fresh instance and, only once it is confirmed running, ends this one.
    ///
    /// `launch` and `terminate` are injected so the ordering rule can be tested without actually
    /// relaunching the test runner.
    @discardableResult
    public static func relaunch(
        bundleURL: URL,
        launch: (URL) async -> Bool = Self.launchAnother,
        terminate: () -> Void = { NSApp.terminate(nil) }
    ) async -> Bool {
        let launched = await launch(bundleURL)
        guard launched else { return false }
        terminate()
        return true
    }

    /// `createsNewApplicationInstance` is required: without it AppKit sees a running instance with
    /// this bundle id and simply activates us, so nothing is relaunched and we then quit.
    private static func launchAnother(_ bundleURL: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 4: Offer the restart in the island**

Add to `IslandModel`:

```swift
    /// True once a permission has been granted that this process still cannot pick up. The island
    /// then offers to relaunch rather than leaving someone holding keys that do nothing.
    @Published public var needsRestart = false
```

Add to `IslandActions`:

```swift
    public var onRestart: () -> Void = {}
```

In `IslandHomeView.rightColumn`, after the `ForEach(Permission.allCases …)` block:

```swift
            if model.needsRestart {
                Button(action: actions.onRestart) {
                    Text("Restart Saathi")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                Text("The grant needs a fresh start to take effect.")
                    .font(.system(size: 8.5))
                    .foregroundColor(Color.white.opacity(0.45))
            }
```

- [ ] **Step 5: Set it when the poll gives up, and wire the action**

In `AppController`, inside the `onFixPermissions` poll closure, change the termination branch so the
timeout case is distinguished from success:

```swift
                        if self.monitor != nil {
                            timer.invalidate()
                            self.permissionPoll = nil
                            self.notch?.model.needsRestart = false
                        } else if remaining <= 0 {
                            timer.invalidate()
                            self.permissionPoll = nil
                            // Two minutes of retrying and the tap still will not install. Either the
                            // grant never happened, or macOS is not going to hand it to this process
                            // without a fresh start. Offer the restart rather than saying nothing.
                            self.notch?.model.needsRestart = Permissions.status(of: .inputMonitoring) == .granted
                        }
```

And in `wireNotch()`:

```swift
        actions.onRestart = { [weak self] in
            guard self != nil else { return }
            Task { await AppRelauncher.relaunch(bundleURL: Bundle.main.bundleURL) }
        }
```

- [ ] **Step 6: Run the tests**

Run: `cd macos/Saathi && swift test`
Expected: PASS.

- [ ] **Step 7: Build signed, and install exactly one copy**

This is the half of the fix that lives outside the code. Run it, and paste the real output into the
task report:

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi/macos/Saathi
# Signed with Developer ID and notarized — NOT --adhoc, which is what caused this.
bash scripts/release.sh

# Exactly one copy, and no stale grants attached to the ad-hoc builds.
osascript -e 'quit app "Saathi"' 2>/dev/null || true
rm -rf /Applications/Saathi.app
tccutil reset All dev.saathi.Saathi
cp -R dist/Saathi.app /Applications/Saathi.app
rm -rf dist/Saathi.app

# Confirm there is now one copy and it is properly signed.
codesign -dv --verbose=2 /Applications/Saathi.app 2>&1 | grep -E "Identifier|Authority|TeamIdentifier"
mdfind -name "Saathi.app" 2>/dev/null
```

Expected: `Authority=Developer ID Application: FLOWXR PTE. LTD. (3U4384584Z)`,
`TeamIdentifier=3U4384584Z`, and exactly one path from `mdfind`.

If `release.sh` fails on notarization (it needs an App Store Connect credential), fall back to
`bash scripts/release.sh --no-notarize`, which still signs with Developer ID — that is what fixes
the relaunch. Say in the report which of the two was used.

- [ ] **Step 8: Verify the grant by hand**

1. `open /Applications/Saathi.app`
2. Open the island → **Fix** next to Input Monitoring.
3. Grant it in System Settings.
4. Expect hold-to-talk to start working **without** any relaunch (the one-second poll picks it up).
5. If macOS does kill the app, expect it to come back by itself now that it is signed.
6. If neither happens, expect the orange **Restart Saathi** button after two minutes, and expect
   clicking it to bring Saathi back with the tap installed.

Confirm with:
```bash
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select service,client,auth_value from access where client like '%aathi%'"
```
Expected: three rows, all `auth_value` 2 — including `kTCCServiceListenEvent`, which has no row today.

- [ ] **Step 9: Commit**

```bash
git add macos/Saathi/Sources/SaathiShell/AppRelauncher.swift \
  macos/Saathi/Sources/SaathiShell/IslandModel.swift \
  macos/Saathi/Sources/SaathiShell/IslandHomeView.swift \
  macos/Saathi/Sources/SaathiShell/AppController.swift \
  macos/Saathi/Tests/SaathiShellTests/IslandModelTests.swift
git commit -m "$(cat <<'MSG'
Saathi brings itself back, instead of trusting Quit & Reopen

macOS relaunches an app through LaunchServices by code signature. An ad-hoc signed
build has no stable identity to come back to, so the Input Monitoring grant killed
Saathi and nothing reopened it.

Signing properly fixes that; this makes the app not depend on it. When two minutes of
retrying the tap still gets nowhere after a grant, the island offers a restart, and the
terminate happens only once the new instance is confirmed launched — a terminate that
races the spawn is the same bug again.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 8: Turn the hosted backend on

No application code. The Vercel Function is deployed and serving; the Supabase side is already fully
provisioned. What is missing is environment.

**Verified before planning, on 2026-09-16 — do not redo this work, re-confirm it cheaply:**
- `https://api.saathi.dev/health` → 200, `{"auth":"closed","voice":"off","limits":"none …"}`
- Migration `0001` **is applied**: `saathi_resolve_token` answers, `saathi_claim_voice_session` answers.
- `saathi.accounts` is **not** reachable through PostgREST (404 `PGRST205`) — the property the
  migration was written for.
- The founder account **is seeded**: the token in `.env.local` resolves to account
  `eb864506-9a80-4f5b-8c28-0a4034d4c447`, plan `unlimited`, allowance 500.

**Blocked on:** an OpenAI key for `SAATHI_REALTIME_KEY`. Ask the user for one, and say plainly that a
key separate from their own machine's key is better, because it can be revoked without breaking
their own Saathi.

**Files:**
- Modify: `.env.local` (gitignored) — fill `SAATHI_REALTIME_KEY`
- Modify: `docs/HOSTING.md` — record the posture that is actually deployed

- [ ] **Step 1: Re-confirm the database, cheaply**

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
set -a && . ./.env.local && set +a
H=$(printf '%s' "$SAATHI_ACCOUNT_TOKEN" | shasum -a 256 | cut -d' ' -f1)
curl -s -X POST "$SAATHI_SUPABASE_URL/rest/v1/rpc/saathi_resolve_token" \
  -H "apikey: $SAATHI_SUPABASE_SECRET_KEY" -H "authorization: Bearer $SAATHI_SUPABASE_SECRET_KEY" \
  -H "content-type: application/json" -d "{\"p_token_sha256\":\"$H\"}"
```

Expected: `{"ok": true, "plan": "unlimited", "account": "eb864506-…"}`.

If it is not `ok`, the account is gone and the migration must be re-applied with
`psql "$SAATHI_DATABASE_URL" -f backend/migrations/0001_accounts_and_voice_ledger.sql`, followed by
re-seeding the founder token's SHA-256. Do not invent a seeding path — read the migration's own
comments first.

- [ ] **Step 2: Put the realtime key in `.env.local`**

Fill the empty `SAATHI_REALTIME_KEY=` line. Never write it into a tracked file; `.env.local` is
gitignored and is mode 0600. Verify both:

```bash
git check-ignore -v .env.local && ls -l .env.local | awk '{print $1}'
```
Expected: the ignore rule prints, and the mode is `-rw-------`.

- [ ] **Step 3: Set the Vercel environment**

The Vercel CLI is not installed in this repo (`npx vercel` prompts to download it). Install it into
the workspace first, then set five variables on project `saathi`
(`prj_RjYqaN7R7JpJj5oLZnb8awBpqC4n`, org `team_1cDJyduHt51R4TaLhe0hcx0q`):

```bash
cd /Users/prasanthsasikumar/Documents/GitHub/saathi
npm i -D vercel
npx vercel login          # interactive — if it needs a browser, ask the user to run it as `! npx vercel login`
set -a && . ./.env.local && set +a

for scope in production preview; do
  printf '%s' "$SAATHI_SUPABASE_URL"        | npx vercel env add SAATHI_SUPABASE_URL "$scope"
  printf '%s' "$SAATHI_SUPABASE_SECRET_KEY" | npx vercel env add SAATHI_SUPABASE_SECRET_KEY "$scope"
  printf '%s' "$SAATHI_REALTIME_KEY"        | npx vercel env add SAATHI_REALTIME_KEY "$scope"
  printf '%s' "gpt-realtime"                | npx vercel env add SAATHI_REALTIME_MODEL "$scope"
  printf '%s' "cedar"                       | npx vercel env add SAATHI_REALTIME_VOICE "$scope"
done
```

**Do not set `SAATHI_TOKENS`.** `authPosture` checks a static token list *before* the accounts
database, so setting it would silently bypass the Postgres ledger and every account limit with it.
**Do not set `SAATHI_ALLOW_ANONYMOUS`.** It would open the backend to anyone.

If `npm i -D vercel` adds a lockfile change, commit it in Step 6.

- [ ] **Step 4: Redeploy and check the posture**

```bash
npx vercel deploy --prod
sleep 5
curl -s https://api.saathi.dev/health | python3 -m json.tool
```

Expected exactly:

```json
{
    "ok": true,
    "version": "0.6.0",
    "auth": "accounts",
    "voice": "hosted",
    "limits": "per-account daily limit, counted in Postgres (shared across every instance)"
}
```

`auth` still saying `closed` means the Supabase variables did not reach the function. `voice` still
`off` means `SAATHI_REALTIME_KEY` did not. `version` still `0.5.0` means the deploy predates Task 1.

- [ ] **Step 5: Verify the refusals are right**

The successful path matters less than the two refusals, because getting them wrong tells a learner
their account is broken when it is merely busy:

```bash
set -a && . ./.env.local && set +a

# A real token mints a credential.
curl -s -o /dev/null -w "authorised: %{http_code}\n" -X POST https://api.saathi.dev/realtime/session \
  -H "authorization: Bearer $SAATHI_ACCOUNT_TOKEN"

# An unknown token is refused as unauthorised.
curl -s -o /dev/null -w "unknown token: %{http_code}\n" -X POST https://api.saathi.dev/realtime/session \
  -H "authorization: Bearer definitely-not-a-real-token"

# No token at all.
curl -s -o /dev/null -w "no token: %{http_code}\n" -X POST https://api.saathi.dev/realtime/session
```

Expected: `authorised: 200`, `unknown token: 401`, `no token: 401`.

Then confirm the minted grant is shaped as the client requires — the client rejects a non-websocket
URL on purpose, so a backend returning `https://` would fail confusingly:

```bash
curl -s -X POST https://api.saathi.dev/realtime/session \
  -H "authorization: Bearer $SAATHI_ACCOUNT_TOKEN" | python3 -c '
import json,sys
g = json.load(sys.stdin)
assert g["url"].startswith("wss://"), g["url"]
assert g["value"], "no client secret"
assert g["expiresAt"] > 0
print("grant ok:", g["model"], g["url"])
print("secret present, not printed")
'
```

Each call spends one session from the founder's allowance of 500. Say how many were spent in the
task report.

- [ ] **Step 6: Verify hosted mode end to end from the app**

```bash
cp ~/.saathi/shell.json ~/.saathi/shell.json.own-key.bak 2>/dev/null || true
set -a && . /Users/prasanthsasikumar/Documents/GitHub/saathi/.env.local && set +a
cat > ~/.saathi/shell.json <<JSON
{ "provider": "hosted", "token": "$SAATHI_ACCOUNT_TOKEN" }
JSON
chmod 600 ~/.saathi/shell.json
open /Applications/Saathi.app
```

Expect the island's Home tab to read `hosted · ` with "your voice leaves as audio", and
hold-to-talk to get a spoken reply. Then restore the own-key config:

```bash
mv ~/.saathi/shell.json.own-key.bak ~/.saathi/shell.json 2>/dev/null || true
```

- [ ] **Step 7: Record what is actually deployed**

In `docs/HOSTING.md`, under `## Environment`, replace the sample `/health` output with the real one
from Step 4, and add below it:

```markdown
As deployed on 2026-09-16: accounts in Supabase project `qkrkijwdwsclpikjgvcb`, hosted voice on
`gpt-realtime` in the `cedar` voice. `SAATHI_TOKENS` is deliberately unset — `authPosture` checks a
static token list *before* the accounts database, so setting it would silently bypass the Postgres
ledger and every per-account limit with it.
```

- [ ] **Step 8: Commit**

```bash
git add docs/HOSTING.md package.json package-lock.json
git commit -m "$(cat <<'MSG'
The hosted backend has accounts and a voice

It has been deployed and answering auth:closed, voice:off since it went up — the code
was all there, the environment was not. Accounts resolve against Supabase, hosted
voice mints a gpt-realtime credential, and the per-account ledger is the one in
Postgres rather than a per-isolate counter that is not a limit at all.

SAATHI_TOKENS stays unset on purpose: a static token list wins over the accounts
database, so setting it would quietly bypass every limit.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

## Notes for whoever executes this

- **Tasks 1–6 are Part A and deliver a working companion on their own.** Task 7 is independent of
  them. Task 8 needs only Task 1 (for the version bump) and the OpenAI key.
- **Task 4 Step 7 and Task 8 are blocked on secrets the user has to supply.** When blocked, finish
  every other step, then say exactly which step is blocked and on what. Do not mark a task complete
  with a blocked verification step, and do not substitute a passing unit test for a manual check.
- **Do not hand-edit `SaathiContract.swift` or `SaathiContract.cs`.** They are generated.
- **Report failures with their output.** A step that did not pass is reported as not passing.
