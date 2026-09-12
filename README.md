# Saathi

A companion for learning and playing with new things, approached from the accessibility side.

*Saathi* (साथी) means companion. The accessibility framing is the way in, not something bolted on
afterwards: the same qualities that make software usable for someone who needs it — patience, saying
what is happening out loud, never requiring a precise click, being driveable entirely by voice — are
what make a good companion for anyone learning something new.

**Status: the skeleton is built; the product is not.** There is a contract, a backend, and a macOS
and a Windows client that both run — enough to prove the structure holds and to have something to
put a real idea into. The product shape itself is deliberately still open — see below.

## Layout

```
saathi/
├─ contract/      the single source of truth — Swift, C# and TypeScript are GENERATED from it
├─ backend/       the key-holding side (Hono/Node). Clients hold a token for this and nothing else
├─ macos/Saathi/  the macOS client — Swift package (SaathiKit + a `saathi` CLI)
└─ windows/       the Windows client — .NET 8 (Saathi.Contract, Saathi.Core, a `saathi` CLI)
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
npm run test:mac        # swift test          (22 tests)
npm run test:win        # dotnet test         (34 tests)
bash scripts/check-parity.sh   # run both clients and diff them
```

### Try it

```bash
npm run dev -w backend                                    # http://localhost:8787

cd macos/Saathi && swift build && ./.build/debug/saathi demo
cd windows && dotnet run --project src/Saathi.Cli -- demo
```

Both print the same four lines. The macOS one speaks them unless you add `--quiet`.

### The one rule worth knowing before changing anything

`contract/schema/saathi.json` is the only hand-edited contract file. Everything under
`macos/Saathi/Sources/SaathiContract/`, `windows/src/Saathi.Contract/` and `backend/src/contract.ts`
is generated from it and will be overwritten. Change the schema, run `npm run generate`, and let the
two builds tell you what needs updating — see [contract/README.md](contract/README.md).

## What is decided

- The name, and `saathi.dev`.
- The premise: a companion that helps people *learn* and *play*, not a tool that does work for them.
- Accessibility is the starting lens, not a later compliance pass.

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
- **`api.saathi.dev` does not resolve yet.** `saathi health` fails against the default until the DNS
  record exists; point it at a local backend with `~/.saathi/shell.json` in the meantime.
