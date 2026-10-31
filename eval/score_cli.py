#!/usr/bin/env python3
"""Score the blind sheet one answer at a time in the terminal.

Usage: python3 score_cli.py [--sheet blind-sheet.md] [--scores scores.csv]
  e.g. round 2 human pass: python3 score_cli.py --scores scores-sam.csv
Shows the prompt, its rubric and one answer (in a pager: arrow keys / space to scroll, q to close),
then asks for 0, 1 or 2 and an optional note. Saves to scores.csv after every answer, so you can
stop (Ctrl+C) and carry on later: already-scored answers are skipped.
"""
import argparse, csv, json, pathlib, pydoc, re, shutil, sys
here = pathlib.Path(__file__).parent
from blindlib import prompts as _p, rubric as _r, answers as _a
ap = argparse.ArgumentParser()
ap.add_argument("--sheet", default="blind-sheet.md")
ap.add_argument("--scores", default="scores.csv", help="your score file; created from scores.csv if missing")
a = ap.parse_args()
out = here / a.scores
if not out.exists():
    shutil.copy(here / "scores.csv", out)
prompts, rub, answers = _p(), _r(), _a(a.sheet)
rows = list(csv.DictReader(open(out)))
fields = list(rows[0].keys())
todo = [r for r in rows if not r["score_0_2"].strip()]
print(f"{len(rows) - len(todo)} of {len(rows)} already scored. {len(todo)} to go. Ctrl+C to stop any time.\n")
def save():
    with open(out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows)
try:
    for i, r in enumerate(todo, 1):
        n, lab = r["n"], r["answer"]
        text = (f"[{i}/{len(todo)}]  PROMPT {n} ({prompts[n]['id']})\n\n{prompts[n]['prompt']}\n\n"
                f"{'=' * 70}\nRUBRIC\n\n{rub.get(n, '(not found)')}\n\n{'=' * 70}\n"
                f"ANSWER {lab}\n\n{answers.get(lab, '(empty answer: score 0)') or '(empty answer: score 0)'}\n")
        pydoc.pager(text)
        while True:
            s = input(f"Score for {lab} (0/1/2, or r to reread): ").strip().lower()
            if s == "r": pydoc.pager(text); continue
            if s in ("0", "1", "2"): break
        r["score_0_2"] = s
        r["notes"] = input("Note (optional, Enter to skip): ").strip()
        save(); print("saved.\n")
except KeyboardInterrupt:
    save(); print("\nStopped. Progress saved; run again to continue.")
    sys.exit(0)
print("All scored. Now run: python3 score.py answers-*.jsonl")
