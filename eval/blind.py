#!/usr/bin/env python3
"""Shuffle answers from several runs into one blind sheet.

Usage: python3 blind.py answers-80b.jsonl answers-qwen38-think.jsonl answers-qwen38-nothink.jsonl
Writes blind-sheet.md (answers labelled X/Y/Z per prompt, order shuffled), scores.csv (fill in), key.json (don't open until scored).
"""
import json, random, sys, csv, pathlib
here = pathlib.Path(__file__).parent
runs = {}
for f in sys.argv[1:]:
    for l in open(f):
        r = json.loads(l); runs.setdefault(r["n"], []).append(r)
letters = "XYZWVU"; key = {}; rng = random.SystemRandom()
with open(here / "blind-sheet.md", "w") as md, open(here / "scores.csv", "w", newline="") as sc:
    w = csv.writer(sc); w.writerow(["n", "prompt_id", "answer", "score_0_2", "notes"])
    prompts = {json.loads(l)["n"]: json.loads(l) for l in open(here / "prompts.jsonl")}
    for n in sorted(runs):
        rs = runs[n][:]; rng.shuffle(rs)
        md.write(f"# {n}. {prompts[n]['id']}\n\n> {prompts[n]['prompt']}\n\n")
        for L, r in zip(letters, rs):
            key[f"{n}{L}"] = r["label"]
            md.write(f"## Answer {n}{L}\n\n{r['answer']}\n\n")
            w.writerow([n, r["id"], f"{n}{L}", "", ""])
json.dump(key, open(here / "key.json", "w"), indent=1)
print("wrote blind-sheet.md, scores.csv and key.json (don't open key.json until you've scored)")
