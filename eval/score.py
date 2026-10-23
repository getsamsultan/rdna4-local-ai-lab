#!/usr/bin/env python3
"""After scoring: join scores.csv with key.json and the run files, print a summary per model/config.
Usage: python3 score.py answers-*.jsonl"""
import csv, json, sys, pathlib, statistics as st
here = pathlib.Path(__file__).parent
key = json.load(open(here / "key.json"))
tot = {}
for row in csv.DictReader(open(here / "scores.csv")):
    if row["score_0_2"].strip() == "": continue
    lab = key[row["answer"]]; tot.setdefault(lab, []).append(int(row["score_0_2"]))
speed = {}
for f in sys.argv[1:]:
    for l in open(f):
        r = json.loads(l); speed.setdefault(r["label"], []).append(r)
print(f"| Config | Score | Out of | Median t/s | Median tokens per answer |\n|---|---|---|---|---|")
for lab, s in sorted(tot.items(), key=lambda x: -sum(x[1])):
    rs = speed.get(lab, [])
    tps = st.median([r["gen_tps"] for r in rs if r["gen_tps"]]) if rs else 0
    tok = st.median([r["completion_tokens"] for r in rs if r["completion_tokens"]]) if rs else 0
    print(f"| {lab} | {sum(s)} | {2*len(s)} | {tps:.1f} | {tok:.0f} |")
