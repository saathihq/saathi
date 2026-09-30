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

## 5. Sarvam (branch `sarvam/heard-and-spoken`, 0.9.0)

Written 2026-09-30, again with nobody at the machine, and with one thing more missing than usual:
**there is no Sarvam key on this Mac**, so nothing in this section has run against the real service
— not the key check, not a transcript, not a syllable. Get a key at
[dashboard.sarvam.ai](https://dashboard.sarvam.ai) (it comes with free credits) and start at the top;
each step only makes sense once the one before it works.

**Before the app, the command.** It needs no microphone and no permission.

```bash
cd macos/Saathi
# With the key on the clipboard, so it is never typed into the shell's history, and in a file
# only you can read:
(umask 077; printf '{ "sarvamKey": "%s", "language": "ml" }\n' "$(pbpaste)" > ~/.saathi/sarvam-try.json)
SAATHI_CONFIG=~/.saathi/sarvam-try.json swift run saathi sarvam --play
rm ~/.saathi/sarvam-try.json
```

- [ ] `key         accepted`. *If it says "Sarvam answered NNN. That is not about your key", tell
      Claude the number: the check treats 400 and 422 as "let in", from the documentation, and a real
      key may answer something else.*
- [ ] `speech out  … s of audio for "നമസ്കാരം, ഞാൻ Saathi."` and, with `--play`, you hear it, in a
      voice that sounds like a person. Change `"language"` to `hi`, `ta`, `en`: it follows.
- [ ] `speech in   heard "…"` with the same sentence, or near it.
- [ ] `thinking    sarvam-105b said "…"`. *If this one is FAILED with a 400 or 422, the likeliest
      causes are `reasoning_effort: null` or the tool list; the message will say which field.*
- [ ] Any FAILED line reads as a sentence, not as JSON.

**Then the app.** `macos/Saathi/dist/Saathi.app` must be the 0.9.0 build from this branch: if
Setup has no Sarvam row, it is an older one. To build it again:
`cd macos/Saathi && scripts/release.sh --no-notarize`. Quit any running Saathi, then
`open macos/Saathi/dist/Saathi.app`.

- [ ] Setup shows three key rows: OpenAI, **Sarvam — Indian languages, heard and spoken**, Anthropic.
- [ ] Type nonsense into the Sarvam row and press Save: "Sarvam did not accept that key." *(This
      half is measured: a wrong key gets a 403.)*
- [ ] Paste the real key. **Before you press Save** the sentence under the keys already reads "If
      Sarvam accepts this key: I will listen, think and speak through Sarvam, in the language chosen
      below. Your voice leaves this machine as audio, straight to Sarvam…". *(The same is now true of
      an OpenAI key: it used to describe the old plan until the instant it was saved.)*
- [ ] Press Save. The island goes to Home. Back in Setup the sentence has lost its "If", and the
      Voice rows say `Sarvam · shubh` and `your voice leaves as audio, to Sarvam`.
- [ ] Under Voice: **Where it thinks** is now a picker (OpenAI, Sarvam, Anthropic, This Mac — whichever
      have keys), and **Hear and speak through Sarvam** is a switch that is on.
- [ ] Language → മലയാളം (or whichever you speak). Hold control + option, say something in it, let
      go. It answers in it, in Bulbul's voice. **There is a pause** of a few seconds: three requests.
      *The microphone here is a second engine opened after the realtime one was torn down. If the
      island says "the microphone gave no sound… quit and reopen it", do that once and try again, and
      tell Claude it happened.*
- [ ] While it is answering, hold the keys again: it **stops talking at once** and listens.
- [ ] Hold the keys and say nothing for two seconds: "I did not catch that", in the same voice, in
      English — and **not** "the microphone gave no sound", which is for an input that is closed.
- [ ] Pointer on something, "what is this?" (in Malayalam or English): it says "looking" on the
      island and then names the thing. *Needs an OpenAI or Anthropic key as well; with only a Sarvam
      key it should say that seeing the screen needs one.*
- [ ] Language → Français. The note under the keys says Sarvam does not hear or speak French, and
      holding the keys says why rather than listening.
- [ ] Turn the switch **off**: the sentence becomes "I will listen on this Mac and think with
      Sarvam. Your voice stays here…" and the voice is the Mac's again. Turn it back on.
- [ ] Where it thinks → OpenAI: back to the realtime voice, no relaunch. → Sarvam: back again, and
      the switch is on again. → This Mac: the switch is **off** — picking This Mac is picking
      somewhere your voice stays.
- [ ] Paste an Anthropic key while on Sarvam: it stays on Sarvam, and the note says the Anthropic key
      looks at the screen.
- [ ] `~/.saathi/shell.json` has `"sarvamKey"`, `"speech": "sarvam"` when the switch is on, and no
      `"speech"` when it is off.

**Two checks that make no sound but open the audio output** — run them when nothing else is playing:

```bash
SAATHI_AUDIO_TESTS=1 swift test --filter PlayerAudioOutputTests
```

**And one that needs Ollama**, because the default mode changed underneath it: with Ollama running
and no provider configured, hold the keys and ask something. It should answer. *The chain lane now
posts to `/v1/chat/completions`; it used to post to a path Ollama does not serve.*

## What to tell Claude

Which boxes failed, and for the look: what is wrong with it in your own words — "too big", "the
bubble colour", "should be in the notch". The numbers are all in `OnboardingStyle` at the top of
`OnboardingCardView.swift`, and the decisions that were made without you are listed, with their
reasons, in `docs/superpowers/specs/2026-09-22-first-run-cards.md`.
