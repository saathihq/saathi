# Saathi

A companion for learning and playing with new things, approached from the accessibility side.

*Saathi* (साथी) means companion. The accessibility framing is the way in, not something bolted on
afterwards: the same qualities that make software usable for someone who needs it — patience, saying
what is happening out loud, never requiring a precise click, being driveable entirely by voice — are
what make a good companion for anyone learning something new.

**Status: the skeleton is built; the product is not.** There is a contract, a backend, and a macOS
and a Windows client that both run — enough to prove the structure holds and to have something to
put a real idea into. The product shape itself is deliberately still open — see below.

## Install

```bash
brew trust saathihq/tap
brew tap saathihq/tap
brew install --cask saathi
```

`Saathi.app` goes to `/Applications` and `saathi` onto your PATH — one signed, notarized binary,
symlinked, not copied twice.

`brew trust` is required, not optional: Homebrew 6 refuses to load a cask from a third-party tap
until you say you trust it, and without it `brew tap` fails outright. A cask is Ruby that runs on
your machine, so it is a fair question to be asked. It applies to every third-party cask tap, not
just this one.

It is a tap rather than homebrew-cask because homebrew-cask wants a project to be about a month old
with a few dozen stars first. Moving it there later will not change the command anyone types.

Then:

```bash
saathi provider     # which mode you are in, and whether anything leaves your machine
saathi voice        # which voice lane that gives you, and where your voice goes
saathi demo         # a three-step lesson, narrated
```

With nothing configured you are in `local` mode — an OpenAI-compatible server on your own machine,
no key, no account, nothing leaving the device.

## Run it yourself

Saathi is open source (Apache-2.0) and **running it yourself is the point**, not a
consolation prize. There are three modes, and the default is the one that needs
nothing from anybody:

| Mode | Keys | Account | Does anything leave your machine? |
|---|---|---|---|
| **`local`** *(default)* | none | none | **no** |
| `openai` / `anthropic` / `sarvam` | your own, on your machine | none | yes, straight to that provider |
| `hosted` | none — we hold them | yes | yes, to Saathi's backend |

`sarvam` is [Sarvam AI](https://sarvam.ai) — Indian-built models with real
Indic-language coverage, which matters given where Saathi starts. Its chat
endpoint is OpenAI-shaped (`https://api.sarvam.ai/v1`, `Authorization: Bearer`),
so the thinking shares a client path with everyone else's. Its speech is the part
nobody else has: it hears and speaks ten Indian languages, nine of which this Mac
cannot hear at all. Saathi can use it for both — see
[Sarvam, heard and spoken](#sarvam-heard-and-spoken).

`local` talks to an OpenAI-compatible server on your own machine — Ollama, LM
Studio, llama.cpp. With nothing configured at all, that is what you get:

```bash
saathi provider           # what mode am I in, and does anything leave this machine?
saathi provider --probe   # ...and is it actually running?
```

```
provider: local  (default — nothing configured)
  An OpenAI-compatible server on this machine — Ollama, LM Studio, llama.cpp.
  No key, no account, nothing leaves the device.

  base url   http://localhost:11434
  model      llama3.2
  your key   not needed
  account    not needed
  privacy    stays on this machine
```

To use your own cloud key instead, put it in `~/.saathi/shell.json` — it stays on
your machine and goes straight to that provider; Saathi's servers are not in the
path:

```json
{ "provider": "sarvam", "sarvamKey": "…" }
```

Each vendor has a field of its own — `openaiKey`, `sarvamKey`, `anthropicKey` — so
one file can hold all three. Pasting a key into Setup, in the app, writes the same
thing. (The older shared `apiKey` is still read.)

How a key is presented is data, not code: each provider row carries the header
name and prefix it needs (`Authorization: Bearer …` for most, `x-api-key` for
Anthropic). Adding a provider is a row in `contract/schema/saathi.json`, not a
branch in Swift and another in C#.

**There is no silent fallback.** If a local model is not reachable, Saathi says so.
It never quietly upgrades to sending your words somewhere else, and both clients
have tests pinning that.

### Talking to it

Voice is the point — this is a companion approached from the accessibility side, and being
driveable entirely by voice is the whole premise. But only some providers can actually carry a
spoken turn over one connection, so the lane is a **column in the provider table**, not a setting:

| Mode | Lane | Speech in / out | Your voice |
|---|---|---|---|
| `local` *(default)* | `chain` | on-device | never leaves |
| `anthropic`, `sarvam` | `chain` | on-device | never leaves — only the transcript is sent |
| any of those three, with `"speech": "sarvam"` | `chain` | Sarvam | leaves as audio, to Sarvam |
| `openai`, `hosted` | `realtime` | over the connection | leaves as audio |

```bash
saathi voice            # which lane, and where your voice goes
saathi voice --listen   # actually talk to it (macOS)
```

The `realtime` lane is one open socket carrying speech in and speech out, which is what makes a
companion feel like it is listening rather than being operated — it can be interrupted
mid-sentence. Only OpenAI ships that today: Ollama has no duplex API, Anthropic has no audio API at
all, and Sarvam has excellent Indic speech models with no socket joining them.

So the `chain` lane exists, and it is not a consolation prize. It is slower — three steps per turn,
and it says so — but it is the only lane that works in the **default** mode, and a companion whose
out-of-the-box configuration cannot be spoken to would have the accessibility premise backwards. It
also makes a promise the realtime lane cannot: both ends run on-device, so with `sarvam` or
`anthropic` doing the thinking, **your voice never leaves the machine — only the transcript does.**
`saathi voice` states which of those you are getting, and both clients are tested to say the same
thing about it.

On this lane a turn can be talked over — hold the keys and whatever Saathi was saying stops, and
the answer it was waiting for is dropped — and "what is this?" is answered by looking: the model
asks to see the screen, is told what is there, and then says so.

### Sarvam, heard and spoken

The on-device promise has a cost, and it falls on exactly the people Saathi starts with. Measured on
the Mac this was written on (macOS 26): Apple's recogniser works on-device for English; it exists
for Hindi but only by sending audio to Apple, which Saathi will not do; and for Tamil, Telugu,
Bengali, Marathi, Kannada, Malayalam, Gujarati, Punjabi and Odia there is no recogniser at all. Five
of those have no system voice either. A chain lane that can only be spoken to in English is not
much of a lane for someone in Kochi.

So the chain lane's ears and mouth can be Sarvam's instead:

```json
{ "provider": "sarvam", "sarvamKey": "…", "speech": "sarvam", "language": "ml" }
```

Saaras hears the turn, Sarvam-105B thinks, Bulbul speaks the answer. `speech` is separate from
`provider` on purpose, because it changes where your voice goes: with it your audio is sent to
Sarvam, and without it — which is what `"provider": "sarvam"` alone has always meant, and still
means — only the words are. Nothing turns it on for you except asking. Pasting a Sarvam key into
Setup is asking: the sentence under the key says your voice will leave as audio while the key is
still in the field, before anything is saved, and there is a switch beside the language to turn it
off again. It works in front of any chain-lane model, so `"provider": "anthropic"` or a local model
with `"speech": "sarvam"` is Claude, or Ollama, with Sarvam's ears.

```bash
saathi sarvam          # is the key accepted, can Bulbul speak, can Saaras hear it, does the model answer
saathi sarvam --play   # ...and play what Bulbul said
```

Four lines, one for each thing Saathi asks of Sarvam, each saying what came back or exactly what
refused. It needs no microphone: what Saaras is asked to hear is what Bulbul has just said.

`saathi sarvam` has passed all four lines against the live service, in Malayalam, Hindi, Tamil and
English (2026-09-30): the key check, Bulbul, Saaras hearing Bulbul back, and Sarvam-105B answering
with the tools attached. What has not yet been tried is the app itself with Sarvam's speech — the
microphone, the player, and a held turn — which is the hand test in `docs/HAND-TEST.md`.

The languages are the eleven Bulbul speaks: Bengali, English, Gujarati, Hindi, Kannada, Malayalam,
Marathi, Odia, Punjabi, Tamil and Telugu. Any other language with `speech: sarvam` is refused out
loud rather than quietly listened to on the Mac. The voice is `shubh`; `"voice": "ishita"` changes
it. The model is `sarvam-105b`, asked to answer without reasoning first, since a reply is a sentence
or two; `"model": "sarvam-105b-conversations"` tries the conversational variant. It is one request per
step, not Sarvam's streaming sockets, so nothing appears while you talk and a reply starts once all
of it has been synthesised. Looking at the screen still needs an OpenAI or Anthropic key.

The audio engine and the realtime protocol handling were carried over from OpenClicky rather than
rewritten, because they were the parts that had already been paid for: echo cancellation configured
so the microphone can stay open while Saathi talks (without silencing the user's music), and a
fixed CoreAudio render-thread data race that aborts under the Thread Sanitizer. Re-deriving those
would have meant finding the same bug twice. `swift test --sanitize=thread --filter
VoiceAudioEngineConcurrencyTests` is the command that checks the fix still holds.

### Running the backend yourself

The backend only matters in `hosted` mode. If you run your own, it works with no
accounts at all — but you have to ask for that by name, so an unconfigured deploy
is never accidentally an open one:

```bash
SAATHI_ALLOW_ANONYMOUS=1 npm run dev -w backend
curl localhost:8787/health     # {"ok":true,"version":"0.2.0","auth":"anonymous"}
```

`/health` reports its own posture — `closed`, `anonymous` or `tokens` — so you can
see what you just deployed without reading the config.

`selfhost/` has a Dockerfile, a compose file and a Caddy block for putting that on
your own box.

## The hosted service

For people who would rather not run or configure anything, there is a hosted
backend at `api.saathi.dev` that holds the provider keys. **It runs the code in
this repository**, with accounts and metering switched on by configuration rather
than by a private fork. What it sells is not having to run anything — not access
to something withheld here.

Billing is not built. India is the first market and UPI is how India pays, so the
payment rail is an open decision rather than a Stripe integration waiting to be
switched on.

## Layout

```
saathi/
├─ contract/      the single source of truth — Swift, C# and TypeScript are GENERATED from it
├─ backend/       the key-holding side (Hono/Node), served at api.saathi.dev
├─ macos/Saathi/  the macOS client — Swift package: SaathiKit, the mascot, the app shell, a `saathi` CLI
├─ windows/       the Windows client — .NET 8 (Saathi.Contract, Saathi.Core, a `saathi` CLI)
├─ api/           the Vercel Function that serves api.saathi.dev (wraps backend/)
└─ selfhost/      Docker + Caddy, for running the backend on your own box instead
```

One repository, not two, and the reason is specific: Swift and C# **cannot share a line of code**,
so the contract is the only thing binding the two clients — and nothing about it is checked by a
compiler. A single CI run that builds both, plus a generator that fails the build when the checked-in
output no longer matches the schema, is the cheapest enforcement there is. Splitting the repos would
remove it and replace it with a published package, a version bump, and someone remembering.

```bash
npm install
npm run generate        # rewrite the generated contract for all three targets
npm run check:contract  # fail if what is checked in is stale (CI runs this on every PR)
npm test                # backend             (64 tests)
npm run test:mac        # swift test          (about 630, silent: see below)
npm run test:win        # dotnet test
bash scripts/check-parity.sh   # run both clients and diff them
```

### Try it

```bash
npm run dev -w backend                                    # http://localhost:8787

cd macos/Saathi && swift build && ./.build/debug/saathi demo
cd windows && dotnet run --project src/Saathi.Cli -- demo
```

Both print the same four lines. The macOS one speaks them unless you add `--quiet`.

`swift test` is silent and touches no audio hardware by default. The five tests that speak through
the real synthesiser, build real `AVAudioEngine`s or play through the real audio output are opt-in —
`SAATHI_AUDIO_TESTS=1 swift test` — because a test run in the background should not take the sound
out of whatever else the machine is doing, and with a Bluetooth headset connecting mid-run they
crashed inside AVFAudio.

Building the macOS client needs Xcode 26 or later: Dictate uses Apple's `SpeechAnalyzer`, which is in
the macOS 26 SDK and no earlier one. The app that comes out still runs on macOS 13. CI builds and
tests on `macos-26` for the same reason.

### Building and signing it yourself

Installing is `brew install --cask saathi` above; this is how that artifact is produced.

```bash
cd macos/Saathi && scripts/release.sh          # signed, notarized, stapled
scripts/release.sh --no-notarize               # signed only, ~30 s
scripts/release.sh --adhoc                     # this Mac only, no identity needed
```

That produces `dist/Saathi.app` and a zip beside it. Gatekeeper accepts a quarantined copy
extracted from that zip, which is the test that matters — it is what a person downloading it gets.

**Why there is an .app bundle around what is still a command-line tool.** A bare executable has no
main bundle, and macOS will not let a process ask for the microphone or for speech recognition
unless the usage-description strings are in its main bundle. Probed on the loose binary:

```
main bundle id:                       none — not a bundle
NSMicrophoneUsageDescription:         ABSENT
NSSpeechRecognitionUsageDescription:  ABSENT
```

The chain lane is the **default** lane — the one that needs no key — so shipping the loose binary
would have produced something correctly notarized that still could not listen. The bundle exists
for identity and permissions rather than for a user interface (`LSUIElement` is true, there is no
window), so you run it as:

```bash
/Applications/Saathi.app/Contents/MacOS/saathi voice --listen
```

**One limitation, stated rather than discovered later.** TCC attributes a permission prompt to the
*responsible* process. A binary started from a terminal is a child of that terminal, so the grant
can land on the terminal instead of on Saathi. The bundle fixes identity, the usage strings and
distribution; it does not by itself fix attribution for terminal-launched processes. `open -a
Saathi` goes through LaunchServices and attributes correctly. The real fix is the menu-bar shell,
which is a product decision rather than a packaging one.

Notarization uses a keychain profile, so no key file is read at build time and nothing secret lives
in this repository:

```bash
xcrun notarytool store-credentials "saathi-notary" \
  --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX --issuer <issuer-uuid>
```

### Hosting — this repository serves `api.saathi.dev`

Every path is rewritten onto the Hono function in `api/`. There is no static
content: `outputDirectory` points at an empty `public/` on purpose.

```bash
vercel            # preview deploy
vercel --prod     # production
```

Then attach `api.saathi.dev` in the Vercel dashboard. **Take the DNS records
Vercel prints** (Porkbun holds `saathi.dev`) rather than copying them from
anywhere else — they are project-specific.

**The website is a separate, private repository** (`saathi-site`) with its own
Vercel project on `saathi.dev`. Saathi is open source; the marketing page is not
part of what people are invited to read, fork or run, and keeping them apart also
means a copy change never rebuilds the API.

`vercel.json` **cannot carry comments** — Vercel's schema validation rejects unknown top-level
properties outright, including a `"//"` key, and the deploy fails rather than ignoring it. The
rationale lives in [docs/HOSTING.md](docs/HOSTING.md) instead.

Three things worth knowing about how this is wired:

- **The function runs on the `edge` runtime.** `hono/vercel` returns a
  web-standard `(Request) => Response`, which is the edge signature; on the
  `nodejs` runtime Vercel expects `(req, res)` and the function simply *hangs*
  rather than erroring. The backend uses nothing outside web standards today. If
  it ever needs a Node built-in, `api/index.ts` is the file that has to change.
- **The request path travels in a `__path` query parameter.** A rewrite replaces
  the path, and Vercel's own catch-all (`api/[...route].ts`) compiles to a
  *single* path segment outside a framework — `/api/a/b` never reaches the
  function at all. `vercel.json` carries the real path across instead.
- **`outputDirectory` must not be the repository root.** Vercel's filesystem
  handler runs *before* rewrites, so with the root as the static directory
  `GET /api/index.ts` returns the function's own source over HTTP, and so does
  every other file. It points at an empty `public/` instead.

All three were found by running `vercel dev` and `vercel build` against this
config, not by reading docs.

### Hosted voice: minted, never proxied

`hosted` mode is the only part of Saathi that needs infrastructure, and the shape of that
infrastructure comes from one decision.

A hosted realtime turn could be carried two ways. The backend could hold both sockets and relay
frames, which would give it full visibility — real token metering, the ability to cut a session off
mid-turn. Or it can mint a short-lived client secret and let the client talk to the provider
directly. **Saathi mints.**

```
client                     api.saathi.dev              provider
  |  POST /realtime/session       |                        |
  |  Authorization: <account>     |                        |
  |------------------------------>|  the real key          |
  |                               |----------------------->|
  |   { value, url, expiresAt }   |<-----------------------|
  |<------------------------------|                        |
  |                                                        |
  |   wss://…  with a ~60s secret                          |
  |=======================================================>|
             no audio ever crosses Saathi's servers
```

Two reasons, in that order:

1. **It is the same shape as everything else here.** The provider-key boundary says the real key
   lives in the backend and never reaches a client; minting honours that exactly. Proxying would
   make Saathi's servers a permanent participant in every conversation a learner has — which is
   precisely what `local` mode exists to avoid. A company that says "run it yourself, nothing has
   to reach us" should not quietly route the audio of everyone who doesn't through its own box.
2. **The arithmetic.** PCM16 mono at 24 kHz is 48 kB/s each way, so a proxied session pushes about
   346 MB per session-hour through the backend and needs a stateful always-on server. The edge
   runtime this deploys to cannot hold a websocket at all.

**What it costs, stated plainly: the backend never sees the tokens a session spends**, so
usage-based metering is impossible. What is enforceable is enforced when the credential is handed
out — sessions per window, per caller. `SessionLedger` in `backend/src/realtime.ts` is that seam,
and `/health` reports which implementation is running:

```bash
curl api.saathi.dev/health
{"ok":true,"version":"0.5.0","auth":"tokens","voice":"hosted","limits":"none — every authorised caller may start a session"}
```

That `limits` line is not decoration. An in-memory ledger on a serverless deploy is per-isolate, so
it would be one quota per warm instance rather than a limit — the field says which situation you
are actually in instead of letting you assume you are covered. A real one needs a shared store and
a `check` that is a single atomic conditional UPDATE; a read followed by a write is how the
predecessor's parallel requests both saw the same balance and both spent it.

A backend with no `SAATHI_REALTIME_KEY` answers 501 and says it offers no hosted voice — the normal
posture for a self-hosted one, and deliberately distinguishable from a broken deploy.

```bash
SAATHI_TOKENS=…          # who may call at all
SAATHI_REALTIME_KEY=…    # the provider key. The one real secret the process holds.
SAATHI_REALTIME_MODEL=gpt-realtime
```

### Self-hosting

Because the backend holds provider keys, running your own is a first-class
option — a hosted default only means something if the alternative actually
works. `selfhost/` has a Dockerfile, a compose file, a Caddy site block and a
script that deploys the backend to a VPS:

```bash
export SAATHI_SERVER=root@your-box      # no default target is baked into the repo
npm run deploy:selfhost -- --env
```

`api.saathi.dev` is live. Self-hosting is not yet exercised end to end.

### The one rule worth knowing before changing anything

`contract/schema/saathi.json` is the only hand-edited contract file. Everything under
`macos/Saathi/Sources/SaathiContract/`, `windows/src/Saathi.Contract/` and `backend/src/contract.ts`
is generated from it and will be overwritten. Change the schema, run `npm run generate`, and let the
two builds tell you what needs updating — see [contract/README.md](contract/README.md).

## What is decided

- The name, and `saathi.dev`.
- The premise: a companion that helps people *learn* and *play*, not a tool that does work for them.
- Accessibility is the starting lens, not a later compliance pass.
- **Apache-2.0**, and self-hosting against your own model is the primary objective — see
  [NOTICE](NOTICE) for why the licence is permissive rather than defensive.
- **`local` is the default mode.** Nothing configured means nothing leaves the machine.

## What is not decided

These are the questions to answer before any architecture is chosen:

1. **Who is it for first?** "Accessibility" covers vision, motor, cognitive, hearing, and situational
   needs, and they pull the design in different directions. Picking one to start is not a limit; it is
   what makes the first version good at anything.
2. **What does "learn and play" mean concretely?** Learning an app, a skill, a subject, a device?
   Playing as in exploration without consequence, or as in games?
3. **Where does it live?** A Mac app, a phone, the web, a device. This follows from (1) and (2) and
   should not be chosen before them.
4. **What is the smallest thing that would already be useful to one real person?**

## What carries over from OpenClicky, and what does not

[OpenClicky](https://github.com/prasanthsasikumar/openclicky) is the previous project — a macOS voice
assistant. It is paused, not abandoned, and it proved a few things worth reusing:

- **A realtime voice session with native typed tools is fast enough to feel instant.** Simple local
  actions ran in about two seconds performed natively, against about twelve when routed through an
  agent subprocess — and almost all of that twelve was model round-trips, not startup.
- **Typed tool arguments with closed enumerations keep a speech pipeline honest.** When a mishearing
  can only produce a wrong *name* inside a known location, never a wrong *command*, the blast radius
  of "it misheard me" stays small. A shell tool would have been faster to build and much worse.
- **Keeping provider keys server-side held up under external review.** Clients and agent subprocesses
  never saw them.
- **The escalation cascade for "where is that on screen?"** — cheap and precise first (the app's own
  structure, then OCR, then accessibility APIs), a model only as the last resort.

What should not carry over is the accumulated structure: a 1,689-line central manager, four naming
prefixes for one subsystem, around 1,500 lines of dead code, and a test suite that never type-checked
its own test files. A fresh start is worth having precisely because those are avoidable.

## Where it stands (September 2026)

The skeleton this README was first written around has been built on. What exists:

- **A macOS app, not only a CLI.** A menu-bar item, an island that hangs from the notch and opens
  under the pointer (Home, Setup and Agents tabs), an orange pointer buddy, and hold
  control + option to talk, in any app. `scripts/release.sh` builds, signs and notarizes it.
- **Keys in the app.** Paste an OpenAI, Sarvam or Anthropic key in Setup; it is validated, stored in
  `~/.saathi/shell.json` at 0600, and Saathi reconfigures itself without a relaunch. The sentence
  under the fields says where your voice will go, and is the same code that decides it. Where it
  thinks is a picker once there is more than one place it could.
- **Sarvam, end to end — on paper.** Saaras for the ears, Sarvam-105B for the thinking, Bulbul for
  the mouth, in ten Indian languages and English, with `saathi sarvam` to check all three. Written
  from Sarvam's reference and tested against it; not yet run against a real key, and not yet heard.
- **Four actions**, not three: `say`, `show_step`, `open_url`, and `look_at_screen` — one frame of
  the pointer's display plus a close-up around the pointer, sent to a vision model only when a turn
  asks about something visible, with what macOS Accessibility says is under the pointer alongside.
- **Skills.** A library of `SKILL.md` files under `~/.saathi`, tiles on Home, and "Create a skill…",
  drafted by the backend so it works without a key of your own.
- **The hosted service is live.** `api.saathi.dev` runs contract 0.8.0 with accounts in Postgres, a
  per-account daily voice allowance claimed in one atomic statement, hosted realtime voice minted
  rather than proxied, and **trials**: a first-run Mac can be given three conversations a day for
  seven days with no sign-in, one account per device. [docs/HOSTING.md](docs/HOSTING.md) has the
  posture, the migrations and what was verified in production.
- **First run, as a model.** The order of the steps, what a spoken answer means, every line Saathi
  says and what ends up in `shell.json` are pure, tested values in SaathiKit. The cards that draw
  them are being worked on.

What the project still commits to, because it follows from the premise rather than from any open
question:

- **The companion says what is happening.** `say` and the narration of `show_step` are the primary
  output, and every step announces its place in the whole — someone who cannot see a progress bar
  still needs to know how much is left, and someone who can is not harmed by hearing it.
- **Closed enumerations everywhere a mishearing could land.** A misheard word can produce a wrong
  value inside a known set, never a command outside it.
- **Provider keys stay on the backend** in hosted mode; your own keys stay on your machine.
- **Refusals are explicit.** `open_url` takes http(s) only, checked in both clients, because the URL
  came from a model that got it from speech.
- **It looks only when asked.** Nothing is captured on a timer or in the background.

## Still to do

- **The Windows shell.** `Saathi.Core` is `net8.0` and holds no Windows-only API, so it builds and
  tests on Linux CI. The WPF overlay (`net8.0-windows`) is where UIA, WGC, App Actions and the SAPI
  speaker land — see `docs/WINDOWS-REFERENCE.md`. The Windows client has the generated contract and
  the CLI; everything under "Where it stands" above is macOS only.
- **`ConfigurationStore` on Windows does not yet restrict the config file.** On Unix it is chmod
  0600; the Windows equivalent is an ACL and is stubbed with a comment rather than silently
  no-op'd. It must land with whatever first writes a real token.
- **A doing lane.** Saathi talks, shows steps, opens links and looks. It does not yet do work in
  other apps; the Agents tab says so rather than showing an empty grid.
- **Sarvam against a real key**, and then its streaming sockets: words as you say them, a reply
  that starts before all of it is synthesised, and hands-free on the chain lane. Odia is heard and
  spoken (`"language": "or"`) but is not in the language picker, because the realtime lane's
  transcriber does not list it.
- **Claude as the thinker, tried.** `provider: anthropic` now reaches Anthropic's OpenAI-compatible
  endpoint — it used to post to a path that is a 404 — but no Anthropic key has been put through it.
  The same fix is what lets the default `local` mode reach Ollama, which has not been tried on this
  branch either.
- **Billing.** Accounts have a plan label and an allowance, not a price. India is the first market
  and the payment rail is an open decision.
- **The website** (`saathi-site`, a separate repository) needs to say what now exists.
