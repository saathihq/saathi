# Pointer grounding: what Accessibility knows that the pixels do not

Date: 2026-09-21. Status: written while the user was away; built on their "go ahead", unverified
on a real screen until they are back.

## Why

`look_at_screen` answers "what is this?" from two pictures: the pointer's display and a close-up
around the pointer. That fixed the worst of "how do I play this song" over a Spotify list, but it
is still a vision model guessing which row a 20-pixel arrow is on. OpenClicky's
`AccessibleElementLocator` header says why that fails: identical captions look identical in pixels,
and the model's own error decides between them.

macOS already knows the answer. The Accessibility tree has the element under the pointer, its role,
its caption, and the titled groups it sits in (the list row, the section, the window). Saathi was a
rewrite and never carried that over.

## What is ported, and what is not

OpenClicky's grounding serves a `point_at` tool: the model guesses a pixel, and the locator snaps
the guess to the right control. Saathi has no `point_at`. Its question runs the other way: the
pointer is already on the thing, and the model needs to be told what the thing is. So:

| OpenClicky | Saathi |
|---|---|
| Walk the focused window breadth-first, collect every captioned control | Hit-test one point (`AXUIElementCopyElementAtPosition`) and walk *up* the parents |
| Caption = AXTitle, else AXDescription, else AXValue | Same order |
| `containerTitles`: captioned non-actionable ancestors, nearest first, three at most | Same rule |
| `actionableRoles` | Same set, used to say "button" rather than "text" |
| `bestMatch` scoring against the model's guess | Not ported: nothing to disambiguate, the pointer is the answer |
| `ScreenTextLocator` (OCR snap), `ScreenElementGrounder` (Claude pass), `BrowserTabLocator` | Not ported: all three exist to correct a pixel guess Saathi never makes |

When the element under the pointer has no caption of its own (a list row, a cell, an image), the
captions of its nearest descendants are read instead, a handful at most, because a Spotify row is a
group whose children carry the song and the artist.

## Shape

`SaathiKit/PointerGrounding.swift`:

- `PointerContext` — `appName`, `windowTitle`, `role`, `caption`, `containerTitles`, `nearbyCaptions`.
  A value; everything below the AX boundary is pure and tested.
- `PointerContext.sentence` — the one paragraph handed to the vision model: *"macOS Accessibility
  reports the pointer is over a button captioned "Play" in the row "Tum Hi Ho, Arijit Singh", in
  the Spotify window "Liked Songs"."*
- `PointerGrounding.context(at:)` — the AX read. Nil without the Accessibility grant, when the app
  exposes no tree, or when nothing captioned is found. 0.25 s messaging timeout, parent walk capped
  at 12, descendants capped at 40 visited and 6 kept, captions clipped to 120 characters.

`ScreenSight.look(question:)` reads the pointer once, captures, reads the context for the same
point, and adds the sentence to the system prompt with one instruction: trust it over the pictures
for *which* thing is meant, and use the pictures for everything else. No grant, no sentence, and
sight works exactly as it does today.

`Permission.accessibility` joins the other four: `AXIsProcessTrusted()` to check,
`AXIsProcessTrustedWithOptions` with the prompt option to ask, `Privacy_Accessibility` for the pane.
It is optional in the sense that matters: nothing is disabled without it.

## Privacy

The sentence goes where the screenshot already goes, to the same provider, in the same request, and
only when a turn asks to look. It is strictly less than the picture contains. Secure text fields
report no value through AX, and `AXSecureTextField` is skipped outright so a caption is never read
from one. `ProviderReport` wording is unchanged: it already says an image of the screen is sent.

## Known limits, said now rather than found later

- Electron and Chromium apps (Spotify among them) expose a thin tree until something sets
  `AXManualAccessibility` on the app element. This build does not set it: it changes another
  process's behaviour and costs that process CPU, and whether it is needed is a thing to measure
  with the user present. If Spotify rows come back empty, that is the next change.
  *Tried on the night of 2026-09-22 and not answered:* the screen was locked, and with a locked
  screen every app's windows — Chrome's included — read as a three-node stub, so nothing measured
  then says anything about Spotify. `macos/Saathi/scripts/ax-probe.swift` makes it one command with
  the screen unlocked: run it plain, then with `on`, and compare the element counts. (Setting the
  attribute was refused outright under the lock — `-25205`, attribute unsupported — which may or may
  not survive unlocking; CEF, which Spotify uses, is not Electron.)
- The grant is per code signature, like Input Monitoring: a Developer ID build keeps it, an ad-hoc
  build loses it on every rebuild.

## Testing

Pure: sentence wording for a captioned control, an uncaptioned row with descendants, no containers,
clipping, role words. AX boundary: not unit-testable; verified by hand over Finder, Safari and
Spotify when the user is back.
