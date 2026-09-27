# Hand test — what has never been seen on a real screen

Written 2026-09-22, after a night of work with nobody at the machine. Everything below passes its
tests and has been code-reviewed twice; none of it has been looked at, listened to, or run against
real permissions. Expect the first ten minutes to find things. Each item says what "fine" looks
like, so a failure is recognisable as one.

The build to test is `macos/Saathi/dist/Saathi.app` (0.8.0, Developer ID signed, from
`onboarding/slice-4b`). Quit any running Saathi first.

```bash
open macos/Saathi/dist/Saathi.app
```

## 1. The basics still work (on `main` since 2026-09-21)

- [ ] Hold control + option, say something, let go. It answers. *The voice lifecycle moved out of
      `AppController` into `VoiceConductor`; this is the check that nothing was lost in the move.*
- [ ] After the reply finishes, the orange microphone light in the menu bar goes **off** within a
      second or two. During a long reply, the reply is **not** clipped or gapped mid-sentence.
- [ ] Setup → change a key or the language → Save. It switches over without a relaunch. Pressing the
      keys during the switch says "switching over — try again in a moment" rather than nothing.
- [ ] While listening, the pointer buddy's **glow** breathes and the triangle stays solid.
- [ ] Open the island, move the pointer away, and immediately hold the keys: the island stays open
      for its moment and then becomes the strip — it does not snap shut.
- [ ] Home → the **+** tile → "Create a skill…": you can type in it, and ⌘V pastes into it (not into
      the app behind). Closing it gives the keyboard back to where you were.

## 2. Pointer grounding

Needs **Accessibility** granted: Setup → Permissions → Accessibility → Fix.

- [ ] Finder, pointer on a file: "what is this?" names that file.
- [ ] Safari or Chrome, pointer on a link in a list of similar links: it names the right one.
- [ ] Spotify, pointer on a song row: "how do I play this song?" is about **that** song.
- [ ] The same three with Accessibility **off**: still answers from the pictures, as before.

If Spotify is wrong with Accessibility on, measure what it exposes — screen unlocked:

```bash
cd macos/Saathi
swift scripts/ax-probe.swift                        # as it is
swift scripts/ax-probe.swift com.spotify.client on  # ask it to publish its tree
swift scripts/ax-probe.swift com.spotify.client off # always put it back
```

A few elements plain and hundreds with `on` means Saathi should set the flag itself for Electron
and CEF apps; "refused" means CEF does not honour it and the close-up picture is all there is.

## 3. First run (branch only)

Menu-bar icon → **Run onboarding again**. (It opens by itself only on an install with no key and
no token, which this Mac is not.) The drawings in `docs/onboarding-cards/` are what it should look
like; the blur behind the real window replaces the flat gradient.

- [ ] The card is centred, dark, blurred behind, and every line on it is **spoken**, in an English
      voice, without the title being said twice.
- [ ] Colour: clicking a dot recolours the card's mascot **and** the island's.
- [ ] Permissions: already-granted ones pass straight through. *(To see the asks for real:
      `tccutil reset All dev.saathi.Saathi`, which also forgets Input Monitoring.)*
- [ ] **Mic check**: after Saathi stops speaking, "I'm listening. Say anything." shows, the bars
      move as you speak, the words appear as they are made out, and after about five seconds
      Continue lights up. Say nothing twice: Continue lights up anyway.
- [ ] **Hold to talk**: Continue stays dim until control + option have been held.
- [ ] **Questions**: answer by voice — "my name is …" keeps only the name, and the
      acknowledgement comes **before** the next question. Try "Or type here". Return on an empty
      field does nothing; Escape does **not** close first run.
- [ ] **Trial**: the disclosure is spoken before anything is asked of the backend. "Start the
      chat" → "Ready", and a held turn now gets a real spoken reply from the hosted service. *This
      spends one of this network's five trial asks for the day, and creates a real trial account
      for this Mac.*
- [ ] **Provider choice**: three choices after a trial, two without. Choosing one closes the card,
      the closing sentence is said **in full**, and the island's provider line matches the choice.
- [ ] Close the card with × halfway: it goes, the keyboard returns to the app you were in, and
      what you had answered is in `~/.saathi/shell.json` without `"onboarded": true`.
- [ ] Afterwards Saathi uses the name now and then, and speaks the way that was chosen.

## 4. If the language is not English

- [ ] Setup → language Tamil (or Hindi). On the **local** lane, a Tamil reply is read by a Tamil
      voice — and "I did not catch that", which is written in English, is read by an English one.

## What to tell Claude

Which boxes failed, and for the look: what is wrong with it in your own words — "too big", "the
bubble colour", "should be in the notch". The numbers are all in `OnboardingStyle` at the top of
`OnboardingCardView.swift`, and the decisions that were made without you are listed, with their
reasons, in `docs/superpowers/specs/2026-09-22-first-run-cards.md`.
