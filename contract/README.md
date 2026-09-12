# contract

The single source of truth every Saathi client and the backend agree on.

`schema/saathi.json` is the only file here anyone edits. Swift, C# and TypeScript views of it are
**generated**:

| Generated file | Consumed by |
|---|---|
| `macos/Saathi/Sources/SaathiContract/SaathiContract.swift` | the macOS client |
| `windows/src/Saathi.Contract/SaathiContract.cs` | the Windows client |
| `backend/src/contract.ts` | the backend |

```bash
npm run generate -w contract    # rewrite all three
npm run check -w contract       # exit 1 if what is checked in is stale (CI runs this)
```

## Why this exists

Saathi has two native clients that **cannot share a line of code** — one is Swift, one is C#. The
contract is therefore the only thing binding them together, and nothing about it is checked by a
compiler. Everything in it gets hand-written twice unless something stops that: the action names,
the closed enumerations, the config file shape, the backend routes.

The previous project shipped the failure this is designed to prevent. Two copies of one TypeScript
file, in adjacent directories **in the same repository**, with a comment at the top of each saying
"keep in sync" — and they had already drifted by the time anyone looked. A comment is not a
mechanism. `--check` in CI is.

This is the same reason Stripe generates a dozen SDKs in a dozen languages from one specification
rather than maintaining them: past two implementations, hand-synchronisation is a matter of when,
not whether.

## The rules the generator encodes

**Closed enumerations.** A speech pipeline mishears. When a misheard word can only produce a wrong
*value* inside a known set, never a wrong *command*, the blast radius of "it misheard me" stays
small. `Tone` and `Pace` are closed for that reason, and adding a case is a schema change that
breaks both clients' builds until they handle it — which is the point.

**Generated files are written into each consumer's source tree**, not into one `generated/`
directory that the platforms symlink. A symlink in a git checkout needs developer mode or elevation
on Windows, and Windows is a first-class target here; a contract that only resolves on macOS would
defeat the purpose of having one.

**Nothing here has dependencies.** `generate.mjs` is plain Node with no install step, so the
Windows CI job can verify the contract without an npm workspace.

## Changing the contract

1. Edit `schema/saathi.json`.
2. `npm run generate -w contract`.
3. Build both clients. Whatever no longer compiles is the list of places that needed updating —
   that list is the whole benefit.
4. Commit the schema and the generated files together.

## What is provisional

The **shape** of the schema is settled. The **contents** are a seed: the product questions in the
root README — who Saathi is for first, what "learn and play" means concretely — are still open, and
the three actions here will change once they are answered. Changing them is meant to be cheap.
