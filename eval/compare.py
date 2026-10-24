#!/usr/bin/env python3
"""Compare two judges' score files, list disagreements, then (only then) reveal per-config totals.
Usage: python3 compare.py scores-claude.csv scores-qwen35.csv [answers-*.jsonl ...]"""
import csv, json, sys, pathlib
here = pathlib.Path(__file__).parent
f1, f2, runs = sys.argv[1], sys.argv[2], sys.argv[3:]
s1 = {r["answer"]: r for r in csv.DictReader(open(f1))}
s2 = {r["answer"]: r for r in csv.DictReader(open(f2))}
labs = sorted(s1, key=lambda x: (int(x[:-1]), x[-1]))
agree = sum(s1[l]["score_0_2"] == s2[l]["score_0_2"] for l in labs)
print(f"Exact agreement: {agree}/{len(labs)} ({100*agree/len(labs):.0f}%)\n\nDisagreements (look at these):")
for l in labs:
    if s1[l]["score_0_2"] != s2[l]["score_0_2"]:
        print(f"  {l:>4}  {pathlib.Path(f1).stem}={s1[l]['score_0_2']}  {pathlib.Path(f2).stem}={s2[l]['score_0_2']}  | {s1[l]['notes'][:60]} | {s2[l]['notes'][:60]}")
key = json.load(open(here / "key.json")); tot = {}
for name, s in ((pathlib.Path(f1).stem, s1), (pathlib.Path(f2).stem, s2)):
    for l in labs:
        if s[l]["score_0_2"] != "": tot.setdefault(key[l], {}).setdefault(name, 0); tot[key[l]][name] += int(s[l]["score_0_2"])
n = len(labs) // len(tot)
print(f"\n| Config | {pathlib.Path(f1).stem} | {pathlib.Path(f2).stem} | out of |\n|---|---|---|---|")
for cfg, d in sorted(tot.items(), key=lambda x: -sum(x[1].values())):
    print(f"| {cfg} | {d.get(pathlib.Path(f1).stem,'')} | {d.get(pathlib.Path(f2).stem,'')} | {2*n} |")
