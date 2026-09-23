# Laya on this Mac

An experiment, not a dependency. [Laya](https://github.com/NandhaKishorM/laya) is a BERT-style
encoder that answers typed questions about a text — choose one of N, score on a rubric, yes/no —
in one forward pass, with no generation. The question was whether it could make Saathi's small
decisions faster than a language model does today: **does this turn need the screen?**, **which
manner of speaking did they pick?**, **which language?** The findings are in
[`results.md`](results.md); the short version is below.

## Run it

```bash
cd experiments/laya
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python laya
.venv/bin/python bench.py            # both checkpoints, CPU and MPS; ~5 min plus a 1.3 GB download
.venv/bin/python bench.py --quick    # accuracy only
```

To try your own sentences interactively:

```bash
.venv/bin/python ask.py              # type a sentence, see the three decisions and their confidence
```

Laya does not generate text, so this is not a chat: each line you type is treated as something said
to Saathi, and it *classifies* it. `/choice mood: happy, sad, angry` swaps in a question of your own.

`cases.json` holds the labelled transcripts — English, Tamil and Hindi, shaped the way speech
recognition hands them over. Add cases there; the labels are what Saathi's own code would need.

## What was found (2026-09-23, M2 Pro, 16 GB)

**Speed is real, on Apple Silicon too.** The multilingual checkpoint (322M params) answers one
short question in **20 ms on MPS**, 54 ms on CPU; the English one (421M) in 40 ms / 116 ms. Three
questions over one transcript cost 37 ms. The README's Tesla T4 number is 33 ms, so a Mac's GPU is
in the same class. Loading takes 2–4 s from cache and 300–350 MB of memory.

**Zero-shot accuracy is not usable for any of the three decisions.**

| decision | best checkpoint, zero-shot | what it gets wrong |
|---|---|---|
| needs the screen (yes/no) | 26/40 | "what is this", "read this to me" → no; "play some music" → yes |
| needs the screen (2-way choice with descriptions) | 29/40 | same shape: a bare "this" is not read as the thing in front of them |
| manner (3-way, en + ta + hi) | 19/30 | every Tamil and most Hindi answers → "plain"; "the first one" / "second" → "plain" |
| language (6-way) | 15/18 | "klingon" → Korean at 1.0; "whatever you like" → English |

The repo's own README says the base checkpoints are near-random zero-shot on its benchmark and
that the published numbers come from fine-tuning. That is what this shows too. The English
checkpoint answers "no" to nearly everything on the screen question (22/40 = the negatives); the
multilingual one is better balanced but wrong on both sides.

## So: an option for the future, on these terms

- **Not zero-shot.** For any of these decisions it needs fine-tuning on a few hundred labelled
  transcripts of Saathi's own. The repo ships a Kaggle notebook for that. Until we have that data —
  which `~/.saathi/conversation.log` will accumulate — there is nothing to fine-tune on.
- **The place it would earn its keep** is the screen decision on the chain lane: decided the
  instant STT finishes, so the capture and the vision call start in parallel with the model instead
  of after its tool round trip. 20 ms is nothing against the seconds that would save. The other two
  decisions are onboarding one-offs where a hand-written parser is already fine and speed is
  irrelevant.
- **Packaging is the real cost.** Python + PyTorch + a 650 MB checkpoint beside a 3 MB signed Swift
  app: either a sidecar process, or converting mmBERT-base to Core ML and reimplementing the head
  in Swift. Neither has been tried. Nothing about this is worth doing before the fine-tuned model
  exists and beats the current behaviour on Saathi's own transcripts.
- **Not on the backend.** Sending every transcript to a classifier breaks the `local` promise.
- **Volatile.** The project was five days old when this was measured; the API and the checkpoints
  will move.
