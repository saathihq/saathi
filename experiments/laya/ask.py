#!/usr/bin/env python
"""
Type a sentence, see what Laya decides about it.

    .venv/bin/python ask.py

Laya does not generate text: it cannot answer a question, only *classify* one. So each line you
type is treated as something a person said to Saathi, and Laya answers three typed questions
about it — does it need the screen, which manner of speaking is it choosing, which language is
it naming — with a probability for each. Type `q` to quit.

    /choice name: option one, option two, option three     define your own choice question
    /yesno name: instruction text                          define your own yes/no question
    /reset                                                 back to Saathi's three
"""

import json
import sys
import time
from pathlib import Path

import laya

CASES = json.loads((Path(__file__).parent / "cases.json").read_text())


def saathi_questions() -> dict:
    out = {}
    for name in ("needs_screen", "manner", "language"):
        spec = CASES[name]
        q = {"type": spec["type"], "instructions": spec["instructions"]}
        if "criteria" in spec:
            q["criteria"] = spec["criteria"]
        out[name] = q
    return out


def show(answers: dict, ms: float):
    for name, a in answers.items():
        if a["type"] == "noul":
            p = a["noul"]
            print(f"  {name:>14}: {'yes' if p >= 0.5 else 'no':<4} {p:.2f}")
        elif a["type"] == "choice":
            ranked = sorted(a["probabilities"].items(), key=lambda kv: -kv[1])
            rest = ", ".join(f"{k} {v:.2f}" for k, v in ranked[1:3])
            print(f"  {name:>14}: {a['choice']} {a['confidence']:.2f}   ({rest})")
        else:
            print(f"  {name:>14}: {a}")
    print(f"  {'':>14}  {ms:.0f} ms")


def main():
    device = sys.argv[1] if len(sys.argv) > 1 else "mps"
    print(f"loading multilingual checkpoint on {device}…", flush=True)
    repo, sub = laya.DEFAULT_MODELS["multilingual"]
    agent = laya.load(repo, subfolder=sub, device=device)
    questions = saathi_questions()
    print("ready. Type something someone might say to Saathi. `q` quits, `/help` for custom questions.\n")

    while True:
        try:
            line = input("> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line:
            continue
        if line == "q":
            break
        if line == "/help":
            print(__doc__)
            continue
        if line == "/reset":
            questions = saathi_questions()
            print("  back to Saathi's three questions")
            continue
        if line.startswith("/choice ") or line.startswith("/yesno "):
            kind, _, rest = line.partition(" ")
            name, _, body = rest.partition(":")
            name = name.strip() or "custom"
            if kind == "/choice":
                options = [o.strip() for o in body.split(",") if o.strip()]
                if len(options) < 2:
                    print("  need at least two options: /choice name: a, b, c")
                    continue
                questions = {name: {"type": "choice", "instructions": f"Which of these is it: {name}?",
                                    "criteria": {o: o for o in options}}}
            else:
                questions = {name: {"type": "noul", "instructions": body.strip() or name}}
            print(f"  asking only `{name}` from now on (/reset to go back)")
            continue

        started = time.perf_counter()
        result = agent.predict({"transcript": line}, questions)
        show(result["answers"], (time.perf_counter() - started) * 1000)


if __name__ == "__main__":
    main()
