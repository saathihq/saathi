# First-run cards, as drawn on 2026-09-22

Sixteen states of `OnboardingCardView`, four to a sheet, drawn offscreen by
`OnboardingSnapshotTests` — nothing here was ever on a screen, and the blur behind the real window
is a flat gradient in these. Redraw them after changing the card:

```bash
cd macos/Saathi
SAATHI_SNAPSHOTS=/tmp/saathi-cards swift test --filter OnboardingSnapshotTests
```

1. `cards-1.jpg` — welcome, colour, into the notch, the microphone permission
2. `cards-2.jpg` — Input Monitoring waiting on System Settings, all set, all set with two refusals, mic check
3. `cards-3.jpg` — hold to talk (Continue disabled), and the name, manner and language questions
4. `cards-4.jpg` — the trial disclosure, a refused trial, and the provider choice with and without hosted

The numbers that make the look are in `OnboardingStyle`, at the top of `OnboardingCardView.swift`.
