# Saathi app shell and first run

Date: 2026-09-15. Status: approved in conversation, awaiting written review.

## Why

`Saathi.app` today is the command-line tool inside a bundle: no window, no Dock tile, and a
double-click runs `saathi` with no arguments and exits. The bundle exists for identity and
permissions. Everything a learner would meet is missing: a character, a way to talk without a
terminal, and a first run that asks for permissions one at a time and explains itself.

The bar is HeyClicky's first launch (reference screenshots on the user's Desktop, summarised in
the project memory `startup-reference-heyclicky`): one continuous spoken conversation that picks a
colour, asks for each permission with a one-line reason, teaches push-to-talk, gets to know the
learner, and then shows the live state in the notch. Saathi keeps that shape and changes three
things to fit its own promises:

- The default mode needs no account, so there is no sign-in screen. The first conversation uses
  Saathi's hosted service through a trial token minted for the device, and Saathi says out loud
  that the learner's voice leaves the machine for those minutes.
- Only what the contract needs is asked for: microphone, speech recognition, and input monitoring
  for the hold-to-talk keys. No accessibility or screen recording, because no action touches
  another app.
- When no model is reachable, Saathi says so. Nothing falls back silently.

## Decisions already made

| Question | Decision |
|---|---|
| Where Saathi lives on screen | Both: a notch panel (menu-bar drop-down on Macs without a notch) for onboarding, tips and the state word, and a pointer companion for presence |
| Push-to-talk | Hold control and option, exactly like HeyClicky, accepting the Input Monitoring permission |
| Get-to-know-you | Four scripted questions that set real settings; no model needed; a reachable model may add a one-line reaction |
| First conversation | Uses the hosted backend through a device trial token, stated plainly before it starts |
| Icon | The pointer mascot in the palette's blue, listening eyes and a smile (already in `Resources/Saathi.svg`) |

## Architecture

### Targets in `macos/Saathi/Package.swift`

| Target | Kind | Depends on | Purpose |
|---|---|---|---|
| `SaathiContract` | library | — | Generated. Gains the new config fields and the trial route. |
| `SaathiKit` | library | Contract | Unchanged in role. Gains `CompanionState`, the hold-to-talk monitor, permission checks, the trial client, and the onboarding model. All testable without a window. The state-to-expression table lives in `SaathiShell`, a new library between the kit and the character, because the kit cannot see `MascotExpression`. |
| `SaathiMascot` | library | — | Draws the character with Core Animation from `mascot.json`. Knows nothing about voice or Saathi. |
| `SaathiShell` | library | Kit, Mascot | The app's testable pieces: state-to-face table, panel geometry, the panels, the menu, the controller. |
| `SaathiApp` | executable | Shell | The shell: menu bar, notch panel, companion panel, onboarding windows. AppKit, no storyboard. Everything testable lives in `SaathiShell`; this target is the `main.swift` that starts it. |
| `saathi` | executable | Kit | The existing CLI, unchanged. Ships inside the bundle next to `SaathiApp`. |

`SaathiApp` is the bundle's `CFBundleExecutable`. `LSUIElement` stays true: no Dock tile, the app
is a menu-bar item plus panels. The Homebrew cask keeps symlinking `Contents/MacOS/saathi`.

### The mascot renderer (`SaathiMascot`)

- `mascot.json` is a resource ported from `~/pointer-mascots/build_data.json` with the effects and
  glyph markup dropped: body path (moveto, cubic, close only), 25 eye outlines, 25 mouths, gaze
  vectors, the expression table, motion presets, face and blink intervals, palette, `anchor`,
  `fit`, `eyeRefX`. A test asserts every expression the app uses exists in the file.
- `MascotView: NSView` with layers: body (`CAShapeLayer` with a gradient mask from the palette
  colour), two eyes, mouth, all inside a motion layer. Blink, face cycling within an expression,
  gaze toward a point, and the motion presets (pulse, bob, sway, tilt) are driven by a
  `CADisplayLink` on macOS 14 and a 60 Hz timer on 13.
- Public surface: `expression: MascotExpression`, `color: MascotColor`, `lookAt(point:)`,
  `blinkNow()`, `spin()`; the view scales the drawing to its frame. `MascotExpression` is an enum
  with the names the app uses; a test fails if the enum and the JSON disagree in either direction.
- Face clipping to the body is done with a `CAShapeLayer` mask, which Core Animation supports even
  though AppKit's SVG loader does not.

### State (`SaathiKit`)

```swift
public enum CompanionState: Equatable {
    case asleep, idle, listening, thinking, speaking, showingStep(index: Int, total: Int),
         celebrating, alert(String), poweringDown
}
```

- `CompanionStateMachine` folds `VoiceSessionCallbacks` events, key hold events, and performed
  actions into a `CompanionState`. Pure, synchronous, unit-tested: listening on key down; thinking
  on `onStatus("thinking…")`; speaking while the speaker is speaking; showingStep on a
  `show_step` action, celebrating when `index == total`; alert on any error; idle two seconds
  after speaking ends; asleep after three quiet minutes; poweringDown on quit.
- `expression(for: CompanionState) -> MascotExpression` is a table: asleep → sleeping, idle → idle,
  listening → listening, thinking → thinking, speaking → dictating, showingStep → working,
  celebrating → celebrate, alert → alerting, poweringDown → powering-down.
- An `ObservedSpeaker` wrapper reports speech start and stop around any speaker, so the state
  machine can see it without the `Speaker` protocol changing. `SystemSpeaker` becomes
  delegate-driven (see the bug below).

### Push-to-talk (`SaathiKit`)

- `HoldToTalkMonitor` installs a listen-only `CGEventTap` on `flagsChanged`. When both control
  and option are down it emits `.began`; when either lifts it emits `.ended`. The combination is a
  value so it can change later without touching the monitor.
- `CGPreflightListenEventAccess()` reports whether Input Monitoring is granted;
  `CGRequestListenEventAccess()` prompts. The monitor never installs without the grant, and
  reports `.notPermitted` instead of failing silently.
- A `.began` calls `beginTurn()` on the current `VoiceSession`, `.ended` calls `endTurn()`. The
  menu-bar item's Talk entry does the same for people who cannot hold keys.

### Permissions (`SaathiKit`)

`Permissions` exposes three `PermissionStatus` values (`granted`, `denied`, `notDetermined`) and
one `request()` each:

| Permission | Check | Request |
|---|---|---|
| Microphone | `AVCaptureDevice.authorizationStatus(for: .audio)` | `AVCaptureDevice.requestAccess(for: .audio)` |
| Speech recognition | `SFSpeechRecognizer.authorizationStatus()` | `SFSpeechRecognizer.requestAuthorization` |
| Input monitoring | `CGPreflightListenEventAccess()` | `CGRequestListenEventAccess()`, then open `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent` |

Denied is a terminal state the UI explains, with a button to open the right System Settings pane.

### Surfaces (`SaathiApp`)

- **Menu-bar item.** The 16 px pointer icon. Menu: the state word, Talk (press to start, press to
  stop), Companion on/off, Start at login on/off, Provider…, Run onboarding again, Quit.
- **The island.** A borderless, non-activating, click-through `NSPanel` at `.popUpMenu` level, hanging
  from the top edge of the screen the pointer is on, centred on the notch. Its window is always the
  size of the open island; what changes is the black body laid out inside it, so the panel never
  resizes over the menu bar. Collapsed it shows nothing: on a display with a hardware notch the body
  is exactly the notch, black over black hardware; on a display without one the body is hidden and a
  44 × 6 pt capsule handle, inset 3 pt from the top edge, marks where to reach (no handle at all
  when there is no menu-bar band to sit in). Taking the pointer to the top of the screen opens the
  full island (320 pt wide, 96 pt of content below the notch) at once: hover is polled from
  `NSEvent.mouseLocation` every 50 ms against the island's rect grown by 6 pt collapsed and 14 pt
  open, and leaving arms a 400 ms grace before it closes. While Saathi is listening, thinking,
  speaking, showing a step, alerting or powering down, the island opens a compact strip (240 pt
  wide, 56 pt of content) by itself and collapses 400 ms after it goes idle; the pointer always wins
  and opens it fully. Open, it holds the mascot at 44 pt and the state word in white; collapsed, the
  mascot is removed from the view so it does not animate. One panel exists and it follows the
  pointer between displays while collapsed, and re-lays itself when displays change. Expanded
  onboarding content (a step, a permission ask, a tip with buttons) is slices 3 and 4 and reuses the
  open island.
- **The pointer buddy.** A 48 pt square, transparent, click-through (`ignoresMouseEvents`),
  non-activating `NSPanel` at `.screenSaver` level, on every Space, following the pointer 35 pt right
  and 25 pt below with an exponential ease (response 0.07 s) so it trails rather than jitters, and
  not moving its window at all while the pointer is still. It draws a 16 pt equilateral triangle in
  `#F0452B` rotated −35°, with a glow of its own colour: radius 8 at rest, 12 while thinking,
  and the glow alone breathing between 1.0 and 0.35 opacity at 1 Hz while listening (the triangle
  stays solid). It carries no face; its
  accessibility label is the state word, so VoiceOver reads what the island shows.
- **Onboarding cards.** A centred, key `NSWindow` with a dark translucent background and a step
  dot row, used for the welcome, the colour pick, and the demo. Everything on a card is also
  spoken.

*Amended 2026-09-16 after the first build: the earlier permanent notch strip with the state word and
a 72 pt mascot companion was rejected in use, in favour of OpenClicky's behaviour. The model is
unchanged: the state word and the face both derive from `CompanionState`, and the island plus
VoiceOver carry the same word.*

### First run

Tracked by `onboarded` in `shell.json`. Steps, each a case of `OnboardingStep` in a pure
`OnboardingModel` in SaathiKit that the app renders and the tests drive:

1. **Welcome card.** "Namaste. I'm Saathi, a companion for learning new things. I'll talk you
   through this." Button: Let's start. Saathi registers itself with `SMAppService.mainApp` and
   says so in one line; the same line has a switch to turn it off.
2. **Colour.** Ten palette dots. The mascot on the card wears the chosen colour and blinks.
   Saved as `colour`.
3. **Into the notch.** The card shrinks toward the notch and the notch panel expands: "I live up
   here now. I need three permissions to get started."
4. **Permissions**, one at a time in the notch panel, each with the reason and one button:
   microphone ("This lets me hear you. Only while you hold the keys."), speech recognition
   ("Turns your voice into words on this Mac. Nothing is sent anywhere."), input monitoring ("Lets
   me notice when you hold control and option, in any app."). The last opens System Settings and
   shows a floating helper card: "I'm Saathi. Turn me on in the list." A denied permission shows
   why it matters and how to grant it later; onboarding continues.
5. **All set.** "Turn your sound on. Meet Saathi." Button opens the demo card.
6. **Demo card**, five steps with a Skip demo link:
   1. *Can I hear you?* Live input level bars from the audio engine, the latest on-device
      transcript in a bubble, an input device picker. Continue enables when a transcript arrives.
   2. *This is how you talk to me.* Hold control and option and say hi. The bubble shows what
      was heard; the mascot goes to listening on hold.
   3. *Four questions.* Scripted, spoken by Saathi, answered by voice or a text field: your
      name (`name`); what you want to learn or play with first (`firstGoal`); how you'd like me
      to speak, offered as calm and slow, warm and normal, or plain (`tone`, `pace`); which
      language to talk in (`language`, a BCP 47 tag chosen from what `SFSpeechRecognizer`
      supports on this Mac). Each answer gets a scripted acknowledgement. If a model is reachable
      through the trial, a one-line reaction is asked for with a two-second budget and skipped if
      it does not arrive.
   4. *Talk to me properly.* Before it starts, Saathi says: "For this chat I'll use Saathi's
      hosted service. Your voice goes to Saathi's servers and its provider for these minutes. After
      this you choose where I think." The app asks the backend for a trial token, saves it, and
      opens a realtime session. The learner holds the keys and talks; actions are performed. If the
      trial cannot be issued or the backend is unreachable, the step says so and offers to skip.
   5. *Where should I think from now on?* Three choices with the provider report in words: keep
      using hosted (trial for the remaining days), a local model, your own key. Saves `provider`.
      Sets `onboarded = true`.
7. Afterwards the notch panel collapses to the state word and the companion appears.

### Trial tokens

- Contract route `POST /trial`, `auth: false`. Body `{ "device": "<uuid v4>" }`. Response
  `{ "token": "...", "expiresAt": "<ISO 8601>", "dailyVoiceSessions": 3 }`. The same device
  asking again inside the expiry gets the same account and a fresh token, so a reinstall does not
  mint a second allowance.
- Backend: inserts a `saathi.accounts` row flagged `trial` with `daily_voice_sessions = 3` and
  `expires_at = now() + 7 days`, and a hashed token in `saathi.tokens`. A new migration adds
  `accounts.trial boolean`, `accounts.expires_at`, `accounts.device_id` with a unique index, and
  `saathi_claim_voice_session` refuses expired accounts with a message that says the trial ended.
  Rate limit: five trials per source address per day, counted in Postgres, returning 429.
- The route is always mounted, because `routes match the contract` requires every declared route
  to answer on every posture. A self-hosted anonymous or tokens backend answers 501 "this backend
  does not offer trials" — the same code, for the same reason, as hosted voice without a provider
  key — and `/health` gains `"trial": "on" | "off"`. *(Amended 2026-09-21: was 404.)*
- Client: `TrialClient` in SaathiKit calls it, `ConfigurationStore` saves the token 0600 as it
  does today. The device id is generated once and saved as `deviceId`.
- Deploy: the hosted service needs `SAATHI_SUPABASE_URL`, `SAATHI_SUPABASE_SECRET_KEY` and an
  OpenAI key set in Vercel. Configuration, not code; recorded in `docs/HOSTING.md`.

### Contract additions

Config fields, all optional: `name`, `colour` (palette name), `tone` (Tone), `pace` (Pace),
`language`, `firstGoal`, `onboarded` (bool), `deviceId`, `startAtLogin` (bool). `token` is reused
for the trial. `npm run generate` rewrites Swift, C# and TypeScript; `check-contract` and
`check-parity.sh` keep passing because the CLI output does not change.

### The silent speech bug

`SystemSpeaker` polls `isSpeaking` immediately after `speak()`, but the flag stays false for about
50 ms, so every spoken CLI command exits before audio starts. Fix: an `AVSpeechSynthesizerDelegate`
that resumes a continuation on `didFinish` or `didCancel`, with a test using a fake delegate
sequence. This ships in the first slice because onboarding is spoken.

### Bundle and release

- `release.sh` builds both executables, sets `CFBundleExecutable` to `SaathiApp`, copies `saathi`
  alongside, and keeps the icon step. `Info.plist` keeps the microphone and speech usage strings.
  Input Monitoring has no usage string in the plist; the app shows the reason itself.
- The cask's binary symlink is unchanged.

## Error handling

- Permission denied: onboarding continues, the feature that needs it is disabled and the menu
  shows a "Fix permissions" entry.
- Trial refused (429, expired, backend closed): step 6.4 says the exact reason in words and offers
  Skip; nothing else changes.
- Realtime session fails mid-turn: state goes to alert with the message; the learner can retry
  with the keys.
- No model reachable after onboarding in local mode: the state word says "no model reachable" and
  the notch tip offers the provider choice again. Never a fallback to hosted. *(As of slice 2 the
  notch tip is not implemented: the state word carries the message and nothing offers the choice
  again; the provider report is in the menu.)*
- Event tap disabled by the system (it happens after sleep): re-enable on `kCGEventTapDisabledByTimeout`.

## Testing

- SaathiKit: state machine transitions; expression table completeness; `OnboardingModel` step
  order including denied-permission and trial-refused branches; config round-trip with the new
  fields; `SystemSpeaker` waits for the delegate; `TrialClient` against a stub URL session.
- SaathiMascot: `mascot.json` loads; every expression the app uses exists; the body path parses to
  a `CGPath` with a non-empty bounding box.
- Backend: `/trial` mints, repeats for the same device, rate-limits, is absent without a ledger;
  `/health` reports trial; `routesMatchContract` covers the new route.
- Manual on this Mac: first run end to end with permissions granted, and `saathi say` audible.

## Out of scope

Windows shell, attribution survey, multiple mascot styles, accessibility or screen-recording
permissions, billing, contextual notch tips beyond the provider choice, a settings window beyond
the menu.

## Build order

1. Speaker fix and `SaathiMascot` with a preview window showing every expression.
2. `SaathiApp` shell: menu bar, companion, notch panel, hold-to-talk, driven by the existing
   voice session, no onboarding yet.
3. Contract and backend: config fields, `/trial`, migration, health.
4. Onboarding model and cards.
5. Release script, bundle layout, login item, first real run.
