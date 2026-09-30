# Sarvam, heard and spoken

Date: 2026-09-30. Status: written and built while the user was away, on "make sure the Sarvam AI
integration is done". Nobody approved any of it. The decisions are in their own section, each with
its reason, for them to be argued with. **Nothing here has run against a real Sarvam key**: there
is none on this Mac. `saathi sarvam` is the one command that says whether it works.

## What "the Sarvam integration" was

A row in the provider table. `provider: sarvam` sent the transcript of a turn to
`https://api.sarvam.ai/v1/chat/completions` and nothing else about it was Sarvam's. Measured on
2026-09-30, on this Mac (macOS 26.6.2) and against Sarvam's live API:

1. **Any string passed as a Sarvam key.** `KeyValidator` asked `GET /v1/models`, which answers 200
   with no key, with a wrong key, and with `Authorization: Bearer not-a-real-key`. A real refusal
   is `403 invalid_api_key_error`, from every endpoint that does authenticate.
2. **There was nowhere to put the key.** Setup has an OpenAI row and an Anthropic row. A Sarvam key
   went in by hand as the legacy shared `apiKey`.
3. **The ears could not hear a single Indian language.** The chain lane listens with
   `SFSpeechRecognizer`, on-device only. On this Mac:

   | | recogniser exists | on-device |
   |---|---|---|
   | English (en-US) | yes | yes |
   | Hindi | yes | no |
   | Tamil, Telugu, Bengali, Marathi, Kannada, Malayalam, Gujarati, Punjabi, Odia | **no** | — |

   And it never asked for the language in Settings at all: `SFSpeechRecognizer()` is the Mac's own
   locale. A Hindi speaker on `sarvam` was transcribed as English words and the model was told to
   answer in Hindi.
4. **Five of the ten had no mouth either.** The system has no voice for Marathi, Malayalam,
   Gujarati, Punjabi or Odia; the speaker falls back to an English voice reading their script.
5. **The chain lane was half a lane**, for every provider on it:
   - asked "what is this?", the model called `look_at_screen`, the lane did not know the tool, and
     Saathi said "I am not sure what to do with that";
   - a tool call's result was never handed back, so the next turn sent a history no
     OpenAI-compatible server is obliged to accept (an assistant message with `tool_calls` and no
     `tool` message answering it);
   - the tools went out wrapped as `{"type":"function","function":{"type":"function",…}}`;
   - holding the keys while Saathi was talking opened the microphone under its own voice;
   - the request went to `{base}/chat/completions`. For `local` — the default mode — that is
     `http://localhost:11434/chat/completions`, which Ollama does not serve: its OpenAI-compatible
     endpoint is under `/v1`. Anthropic's is too (`/chat/completions` is a 404 there, measured).
     Sarvam and OpenAI only worked because their base URLs already end in `/v1`.
6. **Sarvam-105B thinks before it answers unless told not to.** Reasoning is on by default, its
   tokens are billed, and they arrive before the first word of a reply that is meant to be one or
   two sentences.

The row said why the option exists — "Indian-built models with real Indic-language coverage" — and
none of that coverage reached the person talking.

## What Sarvam offers (docs.sarvam.ai, read on the day)

| | Endpoint | Notes |
|---|---|---|
| Chat | `POST /v1/chat/completions` | OpenAI-shaped, tools, `sarvam-105b` and `sarvam-105b-conversations` |
| Speech to text | `POST /speech-to-text` | Saaras, multipart, a WAV of up to 30 s, 23 languages |
| Text to speech | `POST /text-to-speech` | Bulbul v3, JSON in, base64 WAV out, 11 languages, 2500 characters |

One key for all three: `api-subscription-key`, or `Authorization: Bearer` anywhere. Both have
streaming sockets as well. Neither is a duplex conversation socket, which is what the contract's
`realtime` lane means, so Sarvam stays on the chain lane: three steps, each of them Sarvam's.

## What is built

### Contract 0.9.0

- `sarvamKey` — a vendor field like the other two. `credential(for: .sarvam)` reads it first and
  the legacy `apiKey` after.
- The legacy `apiKey` is the key of the provider the file names, and of no other. It used to be
  handed to every vendor that asked. The review of this branch found what that meant once the
  chain lane could look at the screen: a config with `provider: sarvam` and a shared key posted
  the screenshot, and the Sarvam key, to Anthropic.
- `speech` — whose ears and mouth a chain-lane turn uses: `device` or `sarvam` (`SpeechEngine`).
  Unset is `device`. The realtime lane carries its own speech and does not read it.
- `resolvedSpeech`, generated for both clients, so the reports agree on what unset means.

### The key is really checked

`KeyValidator` takes a probe per vendor: a method, a body, and the statuses that mean "you were let
in". For Sarvam it posts `{}` to `/v1/chat/completions`. A wrong key is refused before the body is
read (403, verified); a right one gets as far as "missing `model`" (400, documented). Nothing runs
and nothing is billed. `insufficient_quota_error` says the account is out of credits, in those
words, instead of "try again shortly".

### Sarvam's ears and mouth (`SaathiKit`)

| Piece | What it is |
|---|---|
| `SarvamLanguage` | `"ml"` → `"ml-IN"`, `"or"` → `"od-IN"`; nil for a language Sarvam cannot both hear and speak |
| `WaveFile` | PCM16 into a WAV, and back out of one |
| `SarvamClient` | The two requests and one way of reading a refusal. No state, injected `URLSession` |
| `Ears` | One held turn of speech into text. `DeviceEars` is the code the chain lane had; `SarvamEars` records the turn and sends it to Saaras |
| `TurnRecorder` | The microphone for one turn, as PCM16 mono at 16 kHz. It touches hardware, so the real one has no test; the conversion it does is tested with buffers made by hand |
| `SarvamSpeaker` | A `Speaker`: Bulbul's WAV through an `AudioOutput`. The real output, `AVAudioPlayer`, has two tests that play silence; they are opt-in and have not been run |
| `CompanionVoice` | The app's one voice: the system's, or Sarvam's when the configuration says so |

`ChainVoiceSession` takes its ears as a value. `VoiceSessionFactory` chooses them, and refuses —
out loud, as it does for a missing key — when `speech` is `sarvam` and there is no Sarvam key, or
the language in Settings is not one Sarvam speaks.

### The chain lane, finished

- Tool calls are answered: every call gets a `tool` message, `look_at_screen` gets the answer
  `ScreenSight` found (or the reason it could not look), and the model is asked again so it can say
  what it saw. At most three requests a turn.
- Tools go out as `{"type":"function","function":{name, description, parameters}}`.
- A held turn stops whatever Saathi was saying.
- `reasoning_content` is not kept in the history, and Sarvam is asked for `reasoning_effort: null`.
- A refusal from Sarvam is a sentence: the key was not accepted, the account is out of credits,
  slow down.
- A base URL that names no path gets `/v1` before `/chat/completions`, so the local row and a
  hand-written Ollama host reach the endpoint that exists. A base that names a path is taken at
  its word.

### Setup

- A third key row: **Sarvam — Indian languages, heard and spoken.**
- `SetupPlan` knows three vendors, what is in use, and whose ears the file asks for. See decisions
  1 and 3.
- "Where it thinks" is a picker whenever there is more than one place it could: each vendor with a
  key, and this Mac.
- A switch under Voice, **Hear and speak through Sarvam**, wherever it could be switched: a Sarvam
  key is saved and a turn is three steps. Its second line is the whole of what it means: "Your
  voice, and what is said back, go to Sarvam". It is how Claude, or a model on this Mac, gets
  Sarvam's ears — and how Sarvam goes back to only thinking.
- Gujarati and Punjabi join the language list.
- The note under the keys says what each stored key is for. It said "Anthropic key saved. Nothing
  uses it yet." about a key `ScreenSight` has preferred since it was written.
- The sentence under the keys describes what Save is about to do while a key is still being typed,
  as an "if": "If Sarvam accepts this key: I will listen, think and speak through Sarvam…". Save
  checks a key and saves it in one go, so the sentence used to change in the instant the key was
  saved — after the fact, for the one sentence that says where a voice is about to go. That was
  true of an OpenAI key before this, and is fixed for it too.

### Both clients say where the voice goes

`saathi voice`, on a config with `speech: sarvam`:

```
  lane       chain
  speech in  sarvam, over the network
  thinking   sarvam-105b @ https://api.sarvam.ai/v1
  speech out sarvam, over the network
  your voice leaves this machine as audio, to Sarvam
```

`saathi provider` says "leaves this machine" for it, and for a model on this machine with Sarvam's
ears in front of it: "the thinking stays on this machine; your voice leaves it, to Sarvam" — a bare
"leaves this machine" there sat two lines under the local row's own "nothing leaves the device".
Swift and C# both, the shared fixture carries the two new fields, and `check-parity.sh` compares the
pair over four configurations with `speech` in them.

### `saathi sarvam`

Checks the key, asks Bulbul for one sentence, hands that audio to Saaras, and asks Sarvam-105B one
question. Four lines, one per step, each saying what came back or exactly what refused. It needs no
microphone and no permission, and it is the first thing to run with a real key.

## Decisions made without you

1. **Sarvam's speech is asked for, not assumed.** `provider: sarvam` with no `speech` still listens
   and speaks on this Mac, as the README has always said, and sends only the transcript. Saving a
   Sarvam key in Setup writes `speech: sarvam` with it, and the sentence under the fields says your
   voice will leave as audio before anything is saved. *The other way round* — Sarvam speech for
   every `sarvam` config — is what makes the option work without reading anything, and would have
   turned "only the transcript is sent" into "your audio is sent" for an existing config on an
   update. That is the one thing this project says it never does quietly.

   The same rule decides what a Save does to `speech` afterwards. Arriving at Sarvam — its key
   pasted, or Sarvam picked in the picker — turns its speech on. Arriving anywhere else puts speech
   back on this Mac: someone who picks This Mac is picking somewhere their voice stays. And while
   the provider stays where it is, `speech` stays as the file has it, in both directions: pasting
   an Anthropic key does not start sending a thinking-only Sarvam user's voice away, and does not
   take Sarvam's ears off someone who put them in front of Claude.

2. **One request per step, not the streaming sockets.** REST is exactly what the docs specify and
   can be written against a stub with confidence; a socket protocol written blind is a guess. The
   cost is no words appearing while you talk, and a reply that starts after all of it is
   synthesised rather than during. Both are worth doing once there is a key to hear it with.

3. **A key you have just pasted is a statement of what you want.** Paste an OpenAI key and Saathi
   moves to OpenAI; paste a Sarvam key and it moves to Sarvam, even with an OpenAI key already
   there — otherwise the key you just added would do nothing visible. With nothing new pasted,
   whatever is in use stays in use. An Anthropic key on its own never moves you off OpenAI or
   Sarvam: it is there to look at the screen. OpenAI and Sarvam pasted together is still OpenAI,
   for the reason it always was — the realtime socket. The picker is for going back.

4. **`sarvam-105b`, with thinking off.** The conversational variant, `sarvam-105b-conversations`,
   is "post-trained for real-time dialogue and voice-agent workloads" and may well be the better
   default; the docs promise tool use for the flagship and only imply it for the variant, and
   Saathi cannot show a step or look at a screen without tools. One line in `shell.json` to try:
   `"model": "sarvam-105b-conversations"`.

5. **The voice is `shubh`**, Bulbul's own default and one of the two the docs call safe in every
   language. `"voice": "ishita"` in `shell.json` changes it; a name Bulbul does not have is ignored
   rather than sent.

6. **A language Sarvam does not speak is a refusal, not a fallback.** French with `speech: sarvam`
   does not quietly listen on this Mac instead. It says so and names the two ways out.

7. **When Bulbul cannot be reached, Saathi still makes a sound.** The reply is read by the system
   voice if the Mac has one for that language, a one-line English notice if not, and the island
   shows why. Going silent is the worse failure for someone who cannot see the island.

8. **The microphone is a plain `AVAudioEngine`**, as the on-device ears already use, not the
   realtime lane's voice-processing engine. Last week's finding — a second microphone goes silent
   once voice processing has run in the process — was with the realtime engine still alive. After
   a switch the realtime session is torn down, so it should not apply; it has not been tried. A
   turn in which the microphone gave nothing at all — not a quiet room, which has a noise floor —
   says so and asks for a relaunch. A quiet room is nobody speaking: it is not sent to Sarvam, and
   Saathi says it did not catch that, as on every other lane.

9. **On-device ears now listen in the language in Settings**, where the Mac can do that without
   sending audio to Apple. They listened in the Mac's own language whatever Settings said. Where
   the Mac cannot — every Indian language but English, here — they are still the Mac's own
   recogniser, as before, and the status line now says so and says who could hear it. Refusing to
   start instead would have broken anyone who speaks their Mac's language and asked to be
   *answered* in another, which is what the Language row says it sets.

## Not built

- The streaming sockets, and with them words-as-you-speak and hands-free on this lane.
- Odia in the picker. Sarvam hears and speaks it (`"language": "or"` works); OpenAI's transcriber
  does not list it, and offering it on the realtime lane risks a refused session update.
- Sight through Sarvam. Looking at the screen still needs an OpenAI or Anthropic key, and the note
  under the keys says so when there is neither.
- Dictate through Saaras. Dictate promises nothing leaves the Mac.
- Anything on Windows beyond the reports.
- Claude as the thinker, beyond reaching it. With the `/v1` rule `provider: anthropic` now posts to
  Anthropic's OpenAI-compatible endpoint, which exists (401 to a wrong key, measured) — it posted
  to a 404. Whether that endpoint takes the row's `x-api-key` header, the contract's tools and the
  row's default model has not been tried: there is no Anthropic key on this Mac either.

## Not verified

Everything that needs a key: that a real key gets the 400 the validator reads as "accepted"; that
Saaras takes the WAV this writes; that Bulbul's answer is the shape the docs show and plays through
`AVAudioPlayer`; that `reasoning_effort: null` is accepted; how long a turn takes; what it sounds
like. And three things
that need a person: the microphone after switching from OpenAI without a relaunch, the new row,
picker and switch on a real island, and a local model actually answering through `/v1` (Ollama is
not installed on this Mac; the path is from its documentation).

## What the review found

One independent review read the whole branch once the plan was built. It confirmed the requests
against Sarvam's reference field by field, and found these. The fixes are the commits after
"The plan, as built"; each says what was wrong.

**Fixed**

- The shared `apiKey` was handed to every vendor. With the chain lane now able to look at the
  screen, `provider: sarvam` with a shared key posted the screenshot and the Sarvam key to
  Anthropic. The shared key is now the named provider's only, in both clients.
- First run's "A model on this Mac — everything stays on this Mac" left `speech: sarvam` on.
- `providerBaseUrl` followed a change of provider: a Sarvam key posted to an Ollama host.
- Talking over a turn cancelled only the question to the model; Saaras, a look and Bulbul kept the
  turn busy and the next turn's first words were lost. A turn is now dropped whole.
- A dropped or failed turn left its question in the conversation; the conversation was unbounded
  and could be written from two tasks at once.
- Bulbul's 2500-character limit was counted in letters, not code points, so a long Malayalam or
  Tamil reply was refused.
- A microphone that hands over no buffers read as a tap of the keys ("I did not catch that").
- `saathi provider` and the Setup sentence did not say that replies go to Sarvam to be spoken when
  someone else is doing the thinking.
- The hand test pointed at a build that did not exist yet, and put a real key in `/tmp`.

**Decided against, or left**

- `apiKey` is not deleted once Setup has filed it under its vendor: a Sarvam user going back to
  0.8.0, which has no `sarvamKey`, would be left with no key.
- Two test-quality findings are not fixed: one Shell test re-implements the picker's body instead
  of calling it, and one test orders two tasks with a 30 ms sleep.
- The plan document is as built up to "The plan, as built"; its code blocks do not include the
  fixes above.

**Minor, not done**

- The key check calls any 403 a wrong key, and trusts any 400/422 rather than Sarvam's own error.
- A 5xx gateway page is shown raw.
- `PlayerAudioOutput`: `play()` returning false is swallowed; an overlapping `play` would strand
  the first; the backstop does not check `isPlaying`.
- A revoked microphone permission reads as a hardware fault; repeated quiet turns never escalate;
  the 0.0001 "nothing at all" line is a guess.
- `CompanionVoice.apply` can orphan a Sarvam line that is mid-sentence.
- The Language row still says "what it answers in" when Sarvam's speech is off, though on-device
  ears now listen in it too.
- `saathi sarvam` with a language Sarvam does not speak passes in English without saying the app
  would refuse.
- On main too: a verdict that lands after its field was edited sticks to the new text; local mode
  with a remote `providerBaseUrl` is described as staying on this machine.

## Testing

Every request is built by a pure function and tested against the documented shape. Every response
is read from a stub. The recorder and the player sit behind protocols with fakes; no test that runs
by default opens the microphone or plays a sound. Two tests of the real player play silence through
the real output and are gated behind `SAATHI_AUDIO_TESTS`, like the others that touch hardware. The
Setup invariant — the sentence describes the save — is extended to three vendors and to `speech`,
and was checked to fail when the plan is broken on purpose. The Setup tab is drawn offscreen for
eyes, like the first-run cards, and has been looked at there.
