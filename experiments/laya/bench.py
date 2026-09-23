#!/usr/bin/env python
"""
Does Laya (https://github.com/NandhaKishorM/laya) make Saathi's decisions, and how fast, on this Mac?

Three decisions Saathi actually has to make, labelled by hand in cases.json, run zero-shot against
each checkpoint on CPU and on Apple Silicon (MPS). Accuracy per decision, latency for one question
and for a batch, load time and memory. Writes results.md next to this file.

    .venv/bin/python bench.py                 # everything
    .venv/bin/python bench.py --device mps    # one device
    .venv/bin/python bench.py --model english --device cpu --quick
"""

import argparse
import json
import os
import platform
import resource
import statistics
import subprocess
import sys
import time
from pathlib import Path

import laya

HERE = Path(__file__).parent
CASES = json.loads((HERE / "cases.json").read_text())


def rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def load(model: str, device: str):
    repo, subfolder = laya.DEFAULT_MODELS[model]
    started = time.perf_counter()
    agent = laya.load(repo, subfolder=subfolder, device=device)
    return agent, time.perf_counter() - started


def timed(fn, warmup=3, runs=15):
    for _ in range(warmup):
        fn()
    samples = []
    for _ in range(runs):
        t = time.perf_counter()
        fn()
        samples.append((time.perf_counter() - t) * 1000)
    return statistics.median(samples), min(samples), max(samples)


def question(name: str, spec: dict) -> dict:
    q = {"type": spec["type"], "instructions": spec["instructions"]}
    if "criteria" in spec:
        q["criteria"] = spec["criteria"]
    return {name: q}


def accuracy(agent) -> dict:
    out = {}

    # needs_screen: yes/no, threshold 0.5 on the noul probability.
    spec = CASES["needs_screen"]
    q = question("needs_screen", spec)
    rows, hits = [], 0
    for text, label in [(t, True) for t in spec["positive"]] + [(t, False) for t in spec["negative"]]:
        p = agent.predict({"transcript": text}, q)["answers"]["needs_screen"]["noul"]
        ok = (p >= 0.5) == label
        hits += ok
        rows.append((text, label, round(p, 2), ok))
    out["needs_screen"] = {"correct": hits, "total": len(rows), "rows": rows}

    for name in ("manner", "language"):
        spec = CASES[name]
        q = question(name, spec)
        rows, hits = [], 0
        for text, label in spec["cases"]:
            a = agent.predict({"answer": text}, q)["answers"][name]
            ok = a["choice"] == label
            hits += ok
            rows.append((text, label, a["choice"], round(a["confidence"], 2), ok))
        out[name] = {"correct": hits, "total": len(rows), "rows": rows}
    return out


def latency(agent) -> dict:
    single_state = {"transcript": "how do I play this song"}
    single_q = question("needs_screen", CASES["needs_screen"])
    three_q = {**single_q, **question("manner", CASES["manner"]), **question("language", CASES["language"])}
    long_state = {"transcript": " ".join(CASES["needs_screen"]["positive"] + CASES["needs_screen"]["negative"])}

    return {
        "one short question": timed(lambda: agent.predict(single_state, single_q)),
        "three questions, one state": timed(lambda: agent.predict(single_state, three_q)),
        "one question, ~250-token state": timed(lambda: agent.predict(long_state, single_q), runs=8),
    }


def run(model: str, device: str, quick: bool) -> dict:
    print(f"\n== {model} on {device}", flush=True)
    before = rss_mb()
    agent, load_s = load(model, device)
    print(f"   loaded in {load_s:.1f}s, +{rss_mb() - before:.0f} MB RSS", flush=True)
    acc = accuracy(agent)
    for name, r in acc.items():
        print(f"   {name}: {r['correct']}/{r['total']}", flush=True)
    lat = {} if quick else latency(agent)
    for name, (med, lo, hi) in lat.items():
        print(f"   {name}: median {med:.0f} ms (min {lo:.0f}, max {hi:.0f})", flush=True)
    return {"model": model, "device": device, "load_s": load_s, "rss_mb": rss_mb() - before, "accuracy": acc, "latency": lat}


def write_results(results: list, path: Path):
    chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    mem = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout) // (1024**3)
    lines = [
        f"# Laya on this Mac — {time.strftime('%Y-%m-%d')}",
        "",
        f"{chip}, {mem} GB, macOS {platform.mac_ver()[0]}, Python {platform.python_version()}, "
        f"laya {getattr(laya, '__version__', '?')}, torch {__import__('torch').__version__}. "
        "Zero-shot: no fine-tuning, no temperature fitting. Cases in `cases.json`; regenerate with `bench.py`.",
        "",
        "## Accuracy (zero-shot)",
        "",
        "| checkpoint | device | needs_screen (yes/no) | manner (3-way, en+ta+hi) | language (6-way) |",
        "|---|---|---|---|---|",
    ]
    for r in results:
        a = r["accuracy"]
        cell = lambda n: f"{a[n]['correct']}/{a[n]['total']}"
        lines.append(f"| {r['model']} | {r['device']} | {cell('needs_screen')} | {cell('manner')} | {cell('language')} |")
    lines += ["", "## Latency (median of 15, warm)", "",
              "| checkpoint | device | load | RSS | one short question | three questions | ~250-token state |",
              "|---|---|---|---|---|---|---|"]
    for r in results:
        l = r["latency"]
        ms = lambda n: f"{l[n][0]:.0f} ms" if n in l else "—"
        lines.append(f"| {r['model']} | {r['device']} | {r['load_s']:.1f} s | {r['rss_mb']:.0f} MB | "
                     f"{ms('one short question')} | {ms('three questions, one state')} | {ms('one question, ~250-token state')} |")
    lines += ["", "For comparison the README's own number is 33 ms for one question on a Tesla T4.", ""]

    # The misses, so the numbers can be argued with.
    lines += ["## What each checkpoint got wrong", ""]
    for r in results:
        if r["device"] != results[0]["device"]:
            continue  # same answers on either device; list once
        lines.append(f"### {r['model']}")
        lines.append("")
        a = r["accuracy"]
        for text, label, p, ok in a["needs_screen"]["rows"]:
            if not ok:
                lines.append(f"- needs_screen: “{text}” → {p} (should be {'yes' if label else 'no'})")
        for name in ("manner", "language"):
            for text, label, got, conf, ok in a[name]["rows"]:
                if not ok:
                    lines.append(f"- {name}: “{text}” → {got} ({conf}) (should be {label})")
        lines.append("")
    path.write_text("\n".join(lines))
    print(f"\nwrote {path}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=["english", "multilingual", "both"], default="both")
    ap.add_argument("--device", choices=["cpu", "mps", "both"], default="both")
    ap.add_argument("--quick", action="store_true", help="accuracy only, no latency runs")
    args = ap.parse_args()
    models = ["english", "multilingual"] if args.model == "both" else [args.model]
    devices = ["cpu", "mps"] if args.device == "both" else [args.device]
    results = [run(m, d, args.quick) for d in devices for m in models]
    write_results(results, HERE / "results.md")
