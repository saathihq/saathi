# First-run cards: what was built, and where it leaves the spec

Date: 2026-09-22. Status: built overnight on `onboarding/slice-4b` for the user to react to. Not
merged, never launched, looked at only as offscreen drawings (`docs/onboarding-cards/`).

This is slice 4b of `2026-09-15-app-shell-and-onboarding-design.md`. 4a (the model, the answers,
the script) is on `main`; this is everything with a window in it. It was deliberately not planned
in advance — the look of this app was rejected twice in use — so this note records the decisions
that were made while building, for them to be argued with.

## What exists

| Piece | File | What it is |
|---|---|---|
| `OnboardingCoordinator` | `SaathiShell/OnboardingCoordinator.swift` | Model ↔ world, through injected `OnboardingEffects`. 17 tests on order. |
| `OnboardingCardView` | `SaathiShell/OnboardingCardView.swift` | One SwiftUI card for every step. Decides nothing. Numbers in `OnboardingStyle`. |
| `OnboardingWindowController` | `SaathiShell/OnboardingWindow.swift` | Borderless, blurred, key-capable window; keeps the card's mascot in step with the model. |
| Wiring | `SaathiShell/AppController+Onboarding.swift` | The real effects, and the voice session's behaviour during first run. |
| Listen-only lane | `ChainVoiceSession(thinks: false)` | A turn ends with the transcript; nothing is sent to a model. |
| Languages | `SaathiKit/OnboardingLanguages.swift` | One chip per language, the machine's own first. |
| Drawings | `OnboardingSnapshotTests`, `docs/onboarding-cards/` | Sixteen states, offscreen, opt-in. |

## Decisions

**Who sees first run.** An install with `onboarded` unset *and* nothing configured (no key, no
token). `onboarded` did not exist before contract 0.8.0, so every working install has it unset, and
greeting someone who has used Saathi for weeks with "Namaste, I'm Saathi" is not first run. Anyone
can ask for it: the menu's "Run onboarding again", which was already there and wired to nothing.
An interrupted first run (a name and a colour on disk, `onboarded` not) comes back.

**One window, for every step.** The spec puts the three permission asks in the notch panel and has
the welcome card shrink into the notch. Here all of it is the card. Reasons: the island closes when
the pointer leaves it, which is wrong for someone who has just been sent to System Settings and has
to come back; and wiring a wizard into `NotchPanel` blind, with no way to look at the result, was
the likeliest way to produce a third rejected look. The "I live up here now" sentence is still
said. **If the notch wizard is wanted, it is an addition, not a rewrite:** the coordinator does not
know what draws it.

**No voice session until the permission cards are done.** Starting a session asks macOS for speech
recognition on the spot. First run asks for that itself, one permission at a time, with the reason
said first — so the session starts on reaching "All set".

**Listen-only until the trial chat.** The mic check and the four questions are answered by what was
heard, before any model exists to answer anything. The trial chat is the one real conversation: the
hosted realtime lane, on a copy of the configuration with `provider = hosted` that is never
written to disk, for exactly as long as that card is up.

**The mic check opens its own turn.** The chain session only recognises between a begin and an
end, and the keys that do that are taught on the *next* card. So on entering the mic check — once
Saathi has finished its sentence, or the first thing it hears is itself — the coordinator opens a
turn, closes it five seconds later, and shows what came back; "Listen again" repeats it. It is not
a toll: without the microphone or the recogniser, or after two listens that heard nothing, Continue
unlocks anyway. The alternative was Skip demo, which skips the questions and the provider choice
with it.

**Input Monitoring waits on the card.** No dialog can grant it; "Allow" opens System Settings and
the card changes to "I've turned it on" / "Skip for now", both of which read what macOS says at
that moment. A refused dialog (microphone, speech) is an answer and moves on at once.

**The login item.** On a true first run Saathi registers itself and the welcome card says so beside
the switch that undoes it, as the spec asks. Once, ever (a `UserDefaults` flag): launch counts as
"first run" until first run is finished, and someone who turned the switch off and then closed the
card must not be registered again next launch. "Run onboarding again" does not re-register.

**A title is printed once.** Saathi says "Can I hear you? Say anything…" as one breath; the card
shows "Can I hear you?" and then "Say anything…". A question that *is* its title shows "Say it, or
type it." underneath.

## Not built, on purpose

- **The input device picker** on the mic check. The level bars *are* there: the chain session
  reports an input level (in decibels, so ordinary speech actually moves them) and what it has made
  out so far, and the listening cards show both live.
- **Back.** `OnboardingModel` has no backwards event. HeyClicky has one; nothing in the spec does.
- **The one-line model reaction** to each answer (spec step 6.3, two-second budget). The scripted
  acknowledgement is always spoken; the reaction would be a second voice arriving late.
- **The floating "turn me on in the list" helper** beside System Settings. Its sentence is on the
  waiting card instead.
- **The card-shrinks-into-the-notch animation.**

## What a code review of it found (2026-09-22, fixed the same night)

Closing the card during a slow trial request left Saathi on the hosted lane with the island still
describing the old provider; the mic check could not hear anyone; the login item re-registered
every launch; the closing sentence was cut off by the session swap it announces; leaving the trial
card rebuilt an identical session; the final reconfigure could be silently dropped behind that
swap; Escape in "Or type here" ended first run. Each has a test now, except the two that are
ordering inside `AppController` (the closing line, the dropped reconfigure), which are fixed by
waiting and can only be seen in a running app. `TrialEnrollment` also wrote back a stale copy of
`shell.json`; it now writes the token onto what is on disk when the answer arrives.

A second review, of the fixes and of what was added after them, found seven more, also fixed: the
mic check still locked on a Mac whose turn cannot open at all (no microphone, no recogniser); the
final reconfigure applied a copy of the configuration taken before a several-second wait, which
could erase a key saved in Setup meanwhile; the device id was wiped after a refused trial, so every
"Try again" asked as a new device; a bare "en" resolved to whichever English voice sorted first,
which is Australian; Saathi's own English sentences were handed to the learner's-language
synthesiser once first run was over; the level bars could freeze standing over a closed
microphone; and the mic check's timer could close a turn the keys had opened.

Onboarding answers — the name included — pass through `handle` like any other transcript and so
land in `~/.saathi/conversation.log`. That is the log doing its job, on the user's own disk, but
it is worth knowing.

## Known rough edges

- Nothing here has been seen on a real screen, spoken aloud, or run against real permissions. The
  first ten minutes with it will find things.

## How to look at it

```bash
cd macos/Saathi
SAATHI_SNAPSHOTS=/tmp/saathi-cards swift test --filter OnboardingSnapshotTests   # draw the cards
scripts/release.sh --no-notarize && open dist/Saathi.app                          # then: menu → Run onboarding again
```

On this Mac first run will not open by itself — there is a key in `shell.json` — so use the menu.
