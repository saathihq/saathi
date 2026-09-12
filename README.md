# Saathi

A companion for learning and playing with new things, approached from the accessibility side.

*Saathi* (साथी) means companion. The accessibility framing is the way in, not something bolted on
afterwards: the same qualities that make software usable for someone who needs it — patience, saying
what is happening out loud, never requiring a precise click, being driveable entirely by voice — are
what make a good companion for anyone learning something new.

**Status: nothing is built yet.** This repository exists so the first conversation has somewhere to
land. The product shape is deliberately still open — see below.

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

A brainstorming conversation about the four open questions above, before any code.
