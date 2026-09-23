# Laya on this Mac — 2026-09-23

Apple M2 Pro, 16 GB, macOS 26.6.2, Python 3.12.13, laya 0.3.7, torch 2.14.0. Zero-shot: no fine-tuning, no temperature fitting. Cases in `cases.json`; regenerate with `bench.py`.

## Accuracy (zero-shot)

| checkpoint | device | needs_screen (yes/no) | manner (3-way, en+ta+hi) | language (6-way) |
|---|---|---|---|---|
| english | cpu | 22/40 | 16/30 | 14/18 |
| multilingual | cpu | 26/40 | 19/30 | 15/18 |
| english | mps | 22/40 | 16/30 | 14/18 |
| multilingual | mps | 26/40 | 19/30 | 15/18 |

## Latency (median of 15, warm)

| checkpoint | device | load | RSS | one short question | three questions | ~250-token state |
|---|---|---|---|---|---|---|
| english | cpu | 125.3 s | 2043 MB | 116 ms | 235 ms | 217 ms |
| multilingual | cpu | 2.3 s | 317 MB | 54 ms | 99 ms | 99 ms |
| english | mps | 2.7 s | 355 MB | 40 ms | 90 ms | 78 ms |
| multilingual | mps | 3.5 s | 0 MB | 20 ms | 37 ms | 35 ms |

For comparison the README's own number is 33 ms for one question on a Tesla T4.

## The screen decision as a described two-way choice

The yes/no (`noul`) question type takes no criteria text, so the model has only the instruction to
go on. Asked instead as a `choice` between "screen" (…'this', 'that', a window, a button, a file, an
email, a song in a list…) and "general" (…facts, jokes, timers, opening an app…), on MPS:

| checkpoint | needs_screen as choice | per question |
|---|---|---|
| english | 29/40 | 48 ms |
| multilingual | 27/40 | 21 ms |

Better than yes/no, still not usable: "what is this", "what does this button do" and "read this to
me" all go to "general" with high confidence. The model has no notion that a bare "this" from
someone at a computer means the thing in front of them.

## What each checkpoint got wrong (yes/no form)

### english

- needs_screen: “how do I play this song” → 0.12 (should be yes)
- needs_screen: “what is this” → 0.23 (should be yes)
- needs_screen: “what does this button do” → 0.34 (should be yes)
- needs_screen: “why is that red” → 0.31 (should be yes)
- needs_screen: “what's this folder” → 0.21 (should be yes)
- needs_screen: “read this to me” → 0.1 (should be yes)
- needs_screen: “what does this error mean” → 0.19 (should be yes)
- needs_screen: “which one of these is the settings” → 0.21 (should be yes)
- needs_screen: “what is this file” → 0.25 (should be yes)
- needs_screen: “um what's that thing in the corner” → 0.32 (should be yes)
- needs_screen: “how do I close this” → 0.12 (should be yes)
- needs_screen: “what's this page about” → 0.35 (should be yes)
- needs_screen: “is this the right form” → 0.19 (should be yes)
- needs_screen: “what does it say here” → 0.4 (should be yes)
- needs_screen: “who sent this email” → 0.11 (should be yes)
- needs_screen: “what's the name of this song” → 0.17 (should be yes)
- needs_screen: “what's wrong with this” → 0.34 (should be yes)
- needs_screen: “how do I fill in this box” → 0.1 (should be yes)
- manner: “the first one” → plain (0.14) (should be calm_and_slow)
- manner: “normal is fine” → plain (0.28) (should be warm_and_normal)
- manner: “second” → plain (0.11) (should be warm_and_normal)
- manner: “அமைதியாகவும் மெதுவாகவும்” → plain (0.05) (should be calm_and_slow)
- manner: “மெதுவா பேசுங்க” → plain (0.03) (should be calm_and_slow)
- manner: “முதல் ஆப்ஷன்” → plain (0.04) (should be calm_and_slow)
- manner: “சாதாரணமா, நட்பா” → plain (0.12) (should be warm_and_normal)
- manner: “ரெண்டாவது” → plain (0.02) (should be warm_and_normal)
- manner: “कदैसे ही आराम से और धीरे” → plain (0.09) (should be calm_and_slow)
- manner: “धीरे बोलो” → plain (0.08) (should be calm_and_slow)
- manner: “पहला वाला” → plain (0.13) (should be calm_and_slow)
- manner: “गर्मजोशी से, नॉर्मल” → calm_and_slow (0.12) (should be warm_and_normal)
- manner: “दूसरा” → plain (0.11) (should be warm_and_normal)
- manner: “सीधा सीधा बोलो, बस” → calm_and_slow (0.07) (should be plain)
- language: “தமிழ்ல பேசலாம்” → none (0.38) (should be tamil)
- language: “മലയാളം മതി” → none (0.27) (should be malayalam)
- language: “whatever you like” → english (0.53) (should be none)
- language: “klingon” → korean (0.62) (should be none)

### multilingual

- needs_screen: “why is that red” → 0.22 (should be yes)
- needs_screen: “which one of these is the settings” → 0.36 (should be yes)
- needs_screen: “how do I close this” → 0.38 (should be yes)
- needs_screen: “who sent this email” → 0.08 (should be yes)
- needs_screen: “what's the name of this song” → 0.49 (should be yes)
- needs_screen: “what's wrong with this” → 0.47 (should be yes)
- needs_screen: “tell me a joke” → 0.69 (should be no)
- needs_screen: “how do I learn the tabla” → 0.63 (should be no)
- needs_screen: “what's your name” → 0.74 (should be no)
- needs_screen: “what should I cook tonight” → 0.61 (should be no)
- needs_screen: “how do I say thank you in tamil” → 0.7 (should be no)
- needs_screen: “can you hear me” → 0.87 (should be no)
- needs_screen: “play some music” → 0.92 (should be no)
- needs_screen: “I want to learn how to edit video” → 0.56 (should be no)
- manner: “the first one” → plain (0.45) (should be calm_and_slow)
- manner: “second” → plain (0.82) (should be warm_and_normal)
- manner: “keep it matter of fact” → calm_and_slow (0.42) (should be plain)
- manner: “மெதுவா பேசுங்க” → plain (0.26) (should be calm_and_slow)
- manner: “முதல் ஆப்ஷன்” → plain (0.26) (should be calm_and_slow)
- manner: “சாதாரணமா, நட்பா” → plain (0.28) (should be warm_and_normal)
- manner: “ரெண்டாவது” → plain (0.26) (should be warm_and_normal)
- manner: “धीरे बोलो” → plain (0.82) (should be calm_and_slow)
- manner: “पहला वाला” → plain (0.97) (should be calm_and_slow)
- manner: “गर्मजोशी से, नॉर्मल” → calm_and_slow (0.66) (should be warm_and_normal)
- manner: “दूसरा” → plain (0.39) (should be warm_and_normal)
- language: “മലയാളം മതി” → none (0.14) (should be malayalam)
- language: “whatever you like” → english (0.22) (should be none)
- language: “klingon” → korean (1.0) (should be none)
