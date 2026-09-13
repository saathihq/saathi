# Saathi

A companion for learning and playing with new things, approached from the accessibility side.

*Saathi* (साथी) means companion. The accessibility framing is the way in, not something bolted on
afterwards: the same qualities that make software usable for someone who needs it — patience, saying
what is happening out loud, never requiring a precise click, being driveable entirely by voice — are
what make a good companion for anyone learning something new.

**Status: the skeleton is built; the product is not.** There is a contract, a backend, and a macOS
and a Windows client that both run — enough to prove the structure holds and to have something to
put a real idea into. The product shape itself is deliberately still open — see below.

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
Indic-language coverage, which matters given where Saathi starts. It is
OpenAI-shaped (`https://api.sarvam.ai/v1`, `Authorization: Bearer`), so it shares
the same client path as the others.

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
{ "provider": "sarvam", "apiKey": "…" }
```

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
├─ macos/Saathi/  the macOS client — Swift package (SaathiKit + a `saathi` CLI)
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
npm test                # backend
npm run test:mac        # swift test          (62 tests)
npm run test:win        # dotnet test         (66 tests)
bash scripts/check-parity.sh   # run both clients and diff them
```

### Try it

```bash
npm run dev -w backend                                    # http://localhost:8787

cd macos/Saathi && swift build && ./.build/debug/saathi demo
cd windows && dotnet run --project src/Saathi.Cli -- demo
```

Both print the same four lines. The macOS one speaks them unless you add `--quiet`.

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

### Self-hosting

Because the backend holds provider keys, running your own is a first-class
option — a hosted default only means something if the alternative actually
works. `selfhost/` has a Dockerfile, a compose file, a Caddy site block and a
script that deploys the backend to a VPS:

```bash
export SAATHI_SERVER=root@your-box      # no default target is baked into the repo
npm run deploy:selfhost -- --env
```

Neither path is live yet — see the bottom of this file.

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

## Next step

**The four open questions above, before any product code.** The skeleton deliberately does not
answer them: the three actions in the contract (`say`, `show_step`, `open_url`) are a seed chosen to
exercise the structure, not a claim about what Saathi does. Replacing them is meant to be cheap, and
is the first thing that should happen once the questions are answered.

What the skeleton does commit to, because these follow from the premise rather than from the
unanswered questions:

- **The companion says what is happening.** `say` and the narration of `show_step` are the primary
  output, and every step announces its place in the whole — someone who cannot see a progress bar
  still needs to know how much is left, and someone who can is not harmed by hearing it.
- **Closed enumerations everywhere a mishearing could land.** A misheard word can produce a wrong
  value inside a known set, never a command outside it.
- **Provider keys stay on the backend.** Clients hold a token for the backend and nothing else.
- **Refusals are explicit.** `open_url` takes http(s) only, checked in both clients, because the URL
  came from a model that got it from speech.

## Still to do on the skeleton

- **The macOS shell.** Today the client is a CLI; the menu-bar/overlay app is not written.
  `SaathiKit` is deliberately free of UI so that shell links against it rather than reimplementing.
- **The Windows shell.** Same: `Saathi.Core` is `net8.0` and holds no Windows-only API, so it builds
  and tests on Linux CI. The WPF overlay (`net8.0-windows`) is where UIA, WGC, App Actions and the
  SAPI speaker land — see the stack reasoning in OpenClicky's `docs/WINDOWS-REFERENCE.md`.
- **`ConfigurationStore` on Windows does not yet restrict the config file.** On Unix it is chmod
  0600; the Windows equivalent is an ACL and is stubbed with a comment rather than silently
  no-op'd. It must land with whatever first writes a real token.
- **Neither hostname resolves yet, and nothing has been deployed.** A Vercel project named `saathi`
  exists (created by `vercel build`) but has never been deployed, and the Porkbun DNS records do not
  exist. `saathi health` fails against the default backend until both are done.
- **The website says the product does not exist**, because it does not. When that changes, the
  `saathi-site` repository needs changing with it — it is deliberately not written as though there
  were something to sign up for.
