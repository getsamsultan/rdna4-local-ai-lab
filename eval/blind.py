#!/usr/bin/env python3
"""Shuffle answers from several runs into one blind sheet.

Usage: python3 blind.py [--round2] answers-80b.jsonl answers-qwen38-think.jsonl ...
Writes blind-sheet.md (answers labelled X/Y/Z per prompt, order shuffled), scores.csv (fill in),
key.json (don't open until scored).

--round2 also:
  - style-strips every answer before it goes on the sheet (see prep.py),
  - writes blind-sheet-short.md: the same answers with the same labels, each trimmed to the
    shortest stripped answer for that prompt (length-matched),
  - writes lengths.csv: words per answer label (raw, stripped, length-matched). Labels only, no configs.
"""
import argparse, csv, json, pathlib, random
from prep import strip, trim, words

here = pathlib.Path(__file__).parent
ap = argparse.ArgumentParser()
ap.add_argument("files", nargs="+")
ap.add_argument("--round2", action="store_true")
a = ap.parse_args()

runs = {}
for f in a.files:
    for l in open(f):
        r = json.loads(l); runs.setdefault(r["n"], []).append(r)
letters = "XYZWVU"; key = {}; rng = random.SystemRandom()
prompts = {json.loads(l)["n"]: json.loads(l) for l in open(here / "prompts.jsonl")}

sheets = {"blind-sheet.md": open(here / "blind-sheet.md", "w")}
if a.round2:
    sheets["blind-sheet-short.md"] = open(here / "blind-sheet-short.md", "w")
    lens = csv.writer(open(here / "lengths.csv", "w", newline=""))
    lens.writerow(["n", "answer", "words_raw", "words_stripped", "words_short", "budget"])

with open(here / "scores.csv", "w", newline="") as sc:
    w = csv.writer(sc); w.writerow(["n", "prompt_id", "answer", "score_0_2", "notes"])
    for n in sorted(runs):
        rs = runs[n][:]; rng.shuffle(rs)
        for md in sheets.values():
            md.write(f"# {n}. {prompts[n]['id']}\n\n> {prompts[n]['prompt']}\n\n")
        texts = [strip(r["answer"]) if a.round2 else r["answer"] for r in rs]
        # empty answers (a crash or timeout) stay empty and don't set the budget for the others
        budget = min([words(t) for t in texts if words(t)] or [0]) if a.round2 else None
        for L, r, t in zip(letters, rs, texts):
            lab = f"{n}{L}"; key[lab] = r["label"]
            sheets["blind-sheet.md"].write(f"## Answer {lab}\n\n{t}\n\n")
            if a.round2:
                short = trim(t, budget)
                sheets["blind-sheet-short.md"].write(f"## Answer {lab}\n\n{short}\n\n")
                lens.writerow([n, lab, words(r["answer"]), words(t), words(short), budget])
            w.writerow([n, r["id"], lab, "", ""])
for md in sheets.values():
    md.close()
json.dump(key, open(here / "key.json", "w"), indent=1)
print(f"wrote {', '.join(sheets)}, scores.csv{', lengths.csv' if a.round2 else ''} and key.json "
      "(don't open key.json until you've scored)")
