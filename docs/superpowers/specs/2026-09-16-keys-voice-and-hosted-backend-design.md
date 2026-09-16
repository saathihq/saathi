# Your keys, a working voice, and the hosted backend turned on

Date: 2026-09-16. Status: approved in conversation, awaiting written review.

## Why

Saathi has a shell, a face, an island and a push-to-talk key combination, and no brain behind any
of it. With no `~/.saathi/shell.json` the config resolves to `provider: local`, which means an
OpenAI-compatible server on `localhost:11434` — and there is no Ollama running on this machine. So
every turn reaches a dead end. There is also no way to *fix* that from inside the app: the only
path to a configured provider is hand-writing a JSON file that nothing in the UI mentions.

This spec does three things:

1. **Part A** — lets you hand Saathi an OpenAI key and an Anthropic key in the island, validates
   them, and configures itself from what validated. No file editing, no relaunch.
2. **Part B** — turns on the hosted backend that is already deployed but answering
   `auth: closed, voice: off`, so `provider: hosted` becomes a real option for people who will
   never have their own keys.
3. **Part C** — fixes the Input Monitoring grant that asks you to quit and reopen and never comes
   back.

## Decisions already made

| Question | Decision |
|---|---|
| Where the keys live | On the Mac, in `~/.saathi/shell.json` at 0600. A server is optional, not required. |
| What Claude does | **Nothing yet.** The Anthropic key is accepted, validated and stored; no code path calls it. The setup panel says so rather than implying otherwise. |
| Where you type the keys | A Setup tab in the existing island, not a new window and not a menu sheet. |
| Key storage mechanism | The JSON file, not Keychain. The CLI and the Windows client read the same file; forking that is its own slice. |
| Permissions fix | Both halves: sign with Developer ID *and* relaunch ourselves rather than trusting macOS. |
| Hosted backend | Yes, as Part B. Separate build order, separate verification. |

## What is true today (measured, not assumed)

- `curl https://api.saathi.dev/health` → `{"ok":true,"version":"0.5.0","auth":"closed","voice":"off","limits":"none …"}`.
  The Vercel Function is deployed and serving; it simply has no environment. Every authenticated
  route 401s and `/realtime/session` would 501.
- `.env.local` has `SAATHI_SUPABASE_SECRET_KEY` and `SAATHI_REALTIME_KEY` **present but empty**.
  `SAATHI_SUPABASE_URL`, `SAATHI_DATABASE_URL` and `SAATHI_ACCOUNT_TOKEN` are set.
- Whether `backend/migrations/0001_accounts_and_voice_ledger.sql` has been applied is **unknown** —
  probing `/rest/v1/rpc/saathi_resolve_token` returns 401 because the secret key is empty, which
  says nothing about whether the function exists.
- TCC holds `kTCCServiceMicrophone` and `kTCCServiceSpeechRecognition` granted for
  `dev.saathi.Saathi`, and **no row at all** for `kTCCServiceListenEvent`.
- Two copies of the app exist — `macos/Saathi/dist/Saathi.app` (running) and
  `/Applications/Saathi.app` — both `Signature=adhoc`, same bundle id.
- A valid `Developer ID Application: FLOWXR PTE. LTD. (3U4384584Z)` identity is in the keychain,
  and `scripts/release.sh` already knows how to use it.

---

# Part A — keys in the app

## Contract additions

`contract/schema/saathi.json`, `config.fields`. Flat optional strings rather than a nested object,
because `contract/generate.mjs` emits flat structs and a nested map is a generator rewrite that buys
the reader nothing:

| Field | Doc |
|---|---|
| `openaiKey` | Your own OpenAI key. Used for the realtime voice lane and for thinking. Never sent to Saathi's servers. |
| `anthropicKey` | Your own Anthropic key. Stored for a future lane; nothing calls it yet. |
| `voiceModel` | Overrides the realtime voice model. Distinct from `model`, which is the thinking model. |
| `voice` | The realtime voice's name. Defaults to the provider row's. |

`apiKey` stays, deprecated in its doc comment but still read, so existing configs and the Windows
client keep working. Credential resolution becomes one function on `SaathiConfiguration`:

```swift
/// The credential for a provider: its own field first, then the legacy shared one.
/// Vendor-specific wins, so a config holding both an OpenAI and an Anthropic key is unambiguous —
/// which is the whole point of the two fields existing.
public func credential(for kind: ProviderKind) -> String?
```

`SaathiProvider` gains two row fields: `defaultVoiceModel` (`"gpt-realtime"` for `openai` and
`hosted`, `""` elsewhere) and `defaultVoice` (`"cedar"` for both, `""` elsewhere).
`SaathiConfiguration` gains `resolvedVoiceModel` and `resolvedVoice` alongside `resolvedModel`.

The contract version goes to `0.6.0`. `scripts/check-parity.sh` and the backend's
`routesMatchContract` test both have to stay green, and the Windows `Configuration.cs` is
regenerated in the same commit — a schema change that only regenerates one client is how the two
drift.

## `SetupPlan` — what "figure it out for me" actually is

A pure value type in `SaathiKit`. It takes what validated and returns what to write, plus one
sentence a person can read. No network, no file system, no clock — so the whole of the "it sets
itself up" behaviour is covered by unit tests rather than by listening to the app.

```swift
public struct SetupPlan: Equatable, Sendable {
    public let provider: ProviderKind
    public let model: String
    public let voiceModel: String
    public let lane: VoiceLane
    /// One line, Saathi's voice, saying what it chose and what that means for the learner.
    public let explanation: String
    /// Keys that were accepted but that nothing will call. Named so the panel can say so.
    public let storedButUnused: [ProviderKind]

    public static func make(openAIKeyValid: Bool, anthropicKeyValid: Bool) -> SetupPlan
}
```

The three cases:

| Validated | Plan | Explanation |
|---|---|---|
| OpenAI (with or without Anthropic) | `openai`, `gpt-4o-mini`, `gpt-realtime`, realtime lane | "I will talk to you through OpenAI's realtime voice. Your voice leaves this machine as audio, straight to OpenAI — Saathi's servers are not involved." Anthropic listed in `storedButUnused`. |
| Anthropic only | `anthropic`, `claude-sonnet-5`, no voice model, chain lane | "I will listen on this Mac and think with Claude. Only the transcript is sent." |
| Neither | `local`, `llama3.2`, chain lane | "No key yet, so I will look for a model on this machine. Start Ollama or LM Studio, or add a key above." |

`storedButUnused` is the honest bit. When you give both keys, the panel says *"Anthropic key saved.
Nothing uses it yet."* — it does not let you believe Claude is in the loop when it is not.

## Validating a key

A small `KeyValidator` in `SaathiKit`, injected with a `URLSession` so tests never open a socket.

- OpenAI: `GET https://api.openai.com/v1/models`, `Authorization: Bearer …`
- Anthropic: `GET https://api.anthropic.com/v1/models`, `x-api-key: …`, `anthropic-version: 2023-06-01`

Both are free, instant, and definitive. Three outcomes, three different sentences — a wrong key and
an aeroplane-mode laptop must never produce the same message:

```swift
public enum KeyCheck: Equatable, Sendable {
    case valid
    case rejected(String)      // 401/403 — "OpenAI did not accept that key."
    case unreachable(String)   // transport — "Could not reach OpenAI. Are you online?"
}
```

The key is trimmed before use. A pasted key routinely arrives with a trailing newline, and an
untrimmed one fails authentication in a way that looks exactly like a wrong key.

## The Setup tab

`IslandHomeView` grows a two-item tab strip, Home and Setup. `IslandModel` gains:

```swift
@Published public var tab: IslandTab = .home          // .home | .setup
@Published public var openAIKeyState: KeyFieldState = .empty
@Published public var anthropicKeyState: KeyFieldState = .empty
@Published public var planExplanation: String = ""
```

`KeyFieldState` is `.empty | .editing | .checking | .checked(KeyCheck) | .saved(masked: String)`.
A saved key renders as `sk-…a4f2` and is never put back into an editable field — the file is the
store, not the view.

`IslandActions` gains `onCheckKey(ProviderKind, String)` and `onSaveKeys`. The views stay
declarative and testable the way `IslandModelTests` already tests them; no networking in a view.

The island does not change *when* it opens; it changes *what it shows* when it does. While no
provider has a credential — exactly today's state on this machine — an opened island lands on the
Setup tab rather than Home. Once a key is saved it lands on Home, and Setup is a tab away.

## Reconfiguring a live session

This is the part most likely to break, so it gets the tightest rule.

`AppController.configuration` becomes `var`, and gains:

```swift
/// Swaps in a new configuration without a relaunch: stops the old session, rebuilds the speaker,
/// performer, session and turn coordinator, and re-fills the island's provider and privacy lines.
private func reconfigure(_ configuration: SaathiConfiguration) async
```

Order matters and is not negotiable:

1. **If a turn is open, close it first and wait.** `TurnCoordinator` exists precisely because a turn
   that never opened must not be ended; tearing down a session mid-turn is the same class of bug
   from the other side. `reconfigure` is a no-op that retries once if `turns.isOpen`.
2. `speaker.stop()`, then `await session?.stop()` — the old socket is closed before a new one opens,
   so two realtime sessions never hold the microphone at once.
3. Write the file with `ConfigurationStore.save` (already 0600, already creates with the right mode).
4. Rebuild session, coordinator and callbacks exactly as `startVoice()` does — `startVoice()` is
   refactored to take the configuration rather than read the stored property, and `reconfigure`
   calls it. One code path builds a session, not two.
5. `wireNotch()`'s provider and privacy lines are re-run, so the Home tab immediately says
   `openai · gpt-4o-mini` and "your voice leaves as audio".

Failure at step 4 leaves `voiceStartFailure` set, which the existing `reportNoVoice()` already
surfaces. The saved file stays — a key that validated but whose session failed to start is a
transient problem, and throwing away the key would make it a permanent one.

## Two bugs this uncovers

**The realtime lane cannot work with your own OpenAI key today.** `SaathiProvider.openai`'s
`defaultModel` is `gpt-4o-mini`, and `resolveConnection()` reads:

```swift
let model = configuration.resolvedModel.isEmpty ? "gpt-realtime" : configuration.resolvedModel
```

`resolvedModel` falls back to the row's default and is therefore *never* empty, so the guard is
dead code and the socket would open as `wss://api.openai.com/v1/realtime?model=gpt-4o-mini`, which
OpenAI rejects. Fix: `resolveConnection()` uses `configuration.resolvedVoiceModel`, and the dead
ternary goes. A test asserts the socket URL carries the voice model and not the thinking model —
that is the regression that would otherwise come back the next time someone sets `model`.

**No voice is ever requested.** `sessionUpdate()` sets the output *format* but never a voice name,
so every session gets the provider's default. For a companion whose whole premise is sounding like
a person, that is a default worth choosing: `audio.output.voice` is set from `resolvedVoice`,
defaulting to `cedar` (`marin` is the warmer alternative; both are gpt-realtime voices).

Not changed here: the system prompt's *"Speak the language the learner speaks."* That line is the
most plausible source of an unprompted "Hola", but it is also a real accessibility promise for an
Indic-language learner. It gets tuned after the voice is audible, not before, and not by guessing.

---

# Part B — the hosted backend

The code is written, reviewed and deployed. What is missing is entirely environment and data. No
application code changes in this part; if it turns out any are needed, that is a finding, not a
licence to start editing `backend/src`.

## Prerequisites — two secrets this repository does not have

Both are empty in `.env.local` and must be supplied before Part B can run:

1. **`SAATHI_SUPABASE_SECRET_KEY`** — Supabase dashboard → project `qkrkijwdwsclpikjgvcb` →
   Project Settings → API Keys → the *secret* key. Not the publishable one; `supabaseFromEnv`
   rejects a publishable key at startup by design.
2. **`SAATHI_REALTIME_KEY`** — an OpenAI key for the backend to mint realtime client secrets with.
   It may be the same key as Part A's or a separate one; a separate one is better, because it can
   be revoked without breaking your own machine.

## Steps

1. **Apply the migration.** `psql "$SAATHI_DATABASE_URL" -f backend/migrations/0001_accounts_and_voice_ledger.sql`.
   It is written with `create … if not exists`, so running it against an already-migrated database
   is safe and is also how we find out whether it was applied.
2. **Verify the RPCs exist and the tables do not.** `saathi_resolve_token` and
   `saathi_claim_voice_session` must answer over `/rest/v1/rpc/`; `saathi.accounts` must **not** be
   selectable through PostgREST with any key. The second assertion is the one that matters and the
   one nobody checks — the `saathi` schema is deliberately outside PostgREST's exposed schemas.
3. **Seed the founder account** with `SAATHI_ACCOUNT_TOKEN`'s SHA-256. The plaintext stays in
   `.env.local` and in the client's `shell.json`; the database gets only the hash.
4. **Set the Vercel environment** on project `saathi` (`prj_RjYqaN7R7JpJj5oLZnb8awBpqC4n`):
   `SAATHI_SUPABASE_URL`, `SAATHI_SUPABASE_SECRET_KEY`, `SAATHI_REALTIME_KEY`,
   `SAATHI_REALTIME_MODEL=gpt-realtime`, `SAATHI_REALTIME_VOICE=cedar`. `SAATHI_TOKENS` stays
   unset — it wins over the accounts database when both are set, which would silently bypass the
   ledger.
5. **Redeploy and verify the posture**, which `/health` reports on purpose:

   ```
   {"ok":true,"version":"0.6.0","auth":"accounts","voice":"hosted",
    "limits":"per-account daily limit, counted in Postgres (shared across every instance)"}
   ```

6. **Verify end to end from the app**: a `shell.json` with `provider: hosted` and the account token
   opens a realtime session. Then verify the refusals are right — an unknown token gets 401, and a
   caller over their allowance gets 429, not 401. A backend that answers 401 for "you have used
   your sessions today" is telling a learner their account is broken.

## Where this leaves the two paths

Both lanes then work and mean different things, which `ProviderReport` and `VoiceLaneReport`
already say out loud: with your own key the audio goes straight to OpenAI and Saathi's servers are
not in it; hosted mints a ~60-second client secret and the audio *still* goes straight to OpenAI.
Neither routes audio through `api.saathi.dev`, and that is the property worth not losing.

---

# Part C — the permissions grant that never comes back

## The diagnosis

macOS asks an app requesting Input Monitoring to quit and reopen, and relaunches it through
LaunchServices by code signature. This app is ad-hoc signed, so its identity is a bare cdhash that
changes on every build — and there are two copies with the same bundle id in two places. macOS
kills the running one and has no stable identity to bring back.

## The fix, both halves

**Build and install.** Run `scripts/release.sh` without `--adhoc`, so the app is Developer ID
signed, notarized and stapled. Then exactly one copy: `tccutil reset All dev.saathi.Saathi`,
remove `macos/Saathi/dist/Saathi.app`, install to `/Applications`, re-grant all three permissions
against the properly-signed build.

**Code.** The existing `permissionPoll` already retries installing the tap every second for two
minutes after a grant, which handles the case where macOS *doesn't* kill us. What is missing is the
case where the tap still will not install. After the poll expires with `monitor == nil`, the island
shows a **Restart Saathi** button:

```swift
/// Relaunches and exits, rather than trusting macOS's "Quit & Reopen" to bring us back.
/// `open -a` is spawned detached so it outlives this process, and terminate happens after it is
/// confirmed launched — a terminate that races the spawn is a quit with no reopen, which is the
/// exact bug this exists to fix.
private func restartSelf()
```

`NSWorkspace.openApplication(at:configuration:)` with the bundle's own URL, and `NSApp.terminate`
in its completion handler — not before it.

## What is deliberately not done

Sandboxing, a launch agent, or asking for Accessibility instead of Input Monitoring. Input
Monitoring is the right and smallest permission for a global hold-to-talk chord, and the existing
`Permission.reason` text already explains it honestly.

---

## Error handling

| Situation | What happens |
|---|---|
| Key rejected by the vendor | `.rejected` with the vendor named. Nothing is saved. |
| Vendor unreachable | `.unreachable`, distinct wording. Nothing is saved, and the previous config is untouched. |
| Key valid, session fails to start | The key is **kept**; `voiceStartFailure` is set and `reportNoVoice()` says why on the next press. |
| Save while a turn is open | Deferred until the turn closes, then applied. Never applied mid-turn. |
| Anthropic key given | Saved, validated, and reported as unused in plain words. |
| No keys, no Ollama | `local` plan, and the explanation names Ollama and LM Studio instead of failing silently. |
| Migration already applied | `if not exists` makes it a no-op; the RPC probe is what confirms the state. |
| Publishable Supabase key pasted | `supabaseFromEnv` throws at startup with a clear reason. Already implemented. |

## Testing

Unit, no network and no window — matching how `SaathiKit` and `SaathiShell` are already tested:

- `SetupPlanTests` — all four combinations of the two booleans; `storedButUnused` names Anthropic
  when both keys are given; the explanation is non-empty in every case.
- `KeyValidatorTests` — a stub `URLSession` returning 200, 401 and a transport error, asserting the
  three `KeyCheck` cases are distinguishable; a key with a trailing newline validates.
- `ConfigurationTests` — round-trip with the new fields; `credential(for:)` prefers the vendor field
  over `apiKey`; a file written by `save` is mode 0600 (already covered, must stay green).
- `RealtimeVoiceSession.socketURL` — carries `resolvedVoiceModel`, **not** `resolvedModel`, when
  both are set and differ. This is the regression guard for the bug above.
- `sessionUpdate()` — contains `audio.output.voice` equal to `resolvedVoice`.
- `IslandModelTests` — the tab switches, a saved key renders masked, `.checking` disables the button.
- Backend: existing `app.test.ts` and `realtime.test.ts` stay green; `routesMatchContract` covers
  the version bump.

Manual, because they cannot be unit tested: pasting a real key and hearing a spoken reply; the
Input Monitoring grant taking effect without a relaunch on a Developer ID build; `/health`
reporting `auth: accounts, voice: hosted` after Part B.

## Out of scope

- Any Anthropic call path. The key is stored and unused, deliberately.
- Keychain storage. Later slice; the CLI and Windows client read the same file today.
- The agent/doing lane, screenshots, cursor control — never ported from OpenClicky on purpose.
- Tuning the system prompt's language instruction.
- Windows client UI. Its generated `Configuration.cs` is regenerated so the contract stays in
  parity, but no Windows UI is written.
- **A hosted-mode field in the Setup tab.** Part B makes `provider: hosted` real, but the Setup tab
  in this slice takes the two vendor keys only; a hosted account token is still hand-written into
  `shell.json`. That is defensible while the only holder of a token is the person who deployed the
  backend, and it stops being defensible the moment anyone else is invited — so a token field is
  the obvious next slice, not a thing to smuggle in here.

## Build order

1. Contract schema + regenerate both clients + version bump. (Nothing works yet; parity stays green.)
2. `SetupPlan` and `KeyValidator` with their tests. Pure, no UI.
3. The realtime voice-model and voice-name fixes, with their tests. The lane becomes usable by
   hand-writing a `shell.json` — verifiable before any UI exists.
4. The Setup tab and `reconfigure`. End of this step: paste a key, hear a reply.
5. Part C: signed build, single install, `restartSelf`.
6. Part B: migration, seed, Vercel environment, `/health` verification, hosted end-to-end.

Steps 1–4 are Part A and deliver a working companion on their own. Step 6 needs the two secrets
above and can be done at any point after step 1 (the version bump), independently of the rest.
