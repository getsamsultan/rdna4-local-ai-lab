#!/usr/bin/env python3
"""Round 2 report: split totals, mechanical vs judged, judge agreement, length effect.

Usage: python3 report.py --exec exec-results.csv [--truth sam] scores-sam.csv scores-qwen35.csv scores-qwen35-short.csv ...
  A score file whose name ends in "-short" is treated as a score of blind-sheet-short.md (length-matched).
Needs key.json (and lengths.csv for the length table) next to this script. Prints markdown.

Groups (from the round 2 design):
  executed  12 13 14       scored by execcheck.py, the same for every scorer; judges' own scores shown separately
  computed  1 2 3 4 7 8    maths/fields with one right answer, scored by the judges against RUBRIC.md
  judgment  5 6 9 10 11 15 explanations, advice, honesty, scored by the judges
"""
import argparse, csv, json, pathlib, statistics as st
from itertools import combinations

here = pathlib.Path(__file__).parent
GROUPS = {"executed": {12, 13, 14}, "computed": {1, 2, 3, 4, 7, 8}, "judgment": {5, 6, 9, 10, 11, 15}}
ap = argparse.ArgumentParser()
ap.add_argument("scores", nargs="+")
ap.add_argument("--exec", dest="execf")
ap.add_argument("--key", default=str(here / "key.json"))
ap.add_argument("--lengths", default=str(here / "lengths.csv"))
ap.add_argument("--truth", help="scorer treated as ground truth (the human pass) for the judge check")
a = ap.parse_args()

key = json.load(open(a.key))
configs = sorted(set(key.values()))
S = {}
for f in a.scores:
    name = pathlib.Path(f).stem.removeprefix("scores-")
    S[name] = {r["answer"]: r["score_0_2"].strip() for r in csv.DictReader(open(f))}
mech = {}
if a.execf:
    for r in csv.DictReader(open(a.execf)):
        if r["check"] == "executed": mech[(r["config"], int(r["n"]))] = int(r["score_0_2"])

def n_of(lab): return int(lab[:-1])
def group_total(name, cfg, grp, use_mech=True):
    tot = cnt = 0
    for lab, c in key.items():
        n = n_of(lab)
        if c != cfg or n not in GROUPS[grp]: continue
        if grp == "executed" and use_mech:
            if (cfg, n) in mech: tot += mech[(cfg, n)]; cnt += 1
        elif S[name].get(lab, "") != "":
            tot += int(S[name][lab]); cnt += 1
    return tot, cnt

print("## Totals (executed prompts scored mechanically, the rest by each scorer)\n")
print("| Scorer | Config | Executed | Computed | Judgment | **Total** |\n|---|---|---|---|---|---|")
for name in S:
    for cfg in configs:
        cells = [group_total(name, cfg, g) for g in GROUPS]
        tot = sum(t for t, _ in cells); out = sum(2 * c for _, c in cells)
        print(f"| {name} | {cfg} | " + " | ".join(f"{t}/{2*c}" for t, c in cells) + f" | **{tot}/{out}** |")

if mech:
    print("\n## Executed prompts: machine result vs what each scorer gave\n")
    names = list(S)
    print("| Prompt | Config | Machine | " + " | ".join(names) + " |\n|---|---|---|" + "---|" * len(names))
    for lab in sorted(key, key=lambda x: (n_of(x), key[x])):
        n, cfg = n_of(lab), key[lab]
        if n in GROUPS["executed"]:
            print(f"| {n} | {cfg} | {mech.get((cfg, n), '')} | " + " | ".join(S[nm].get(lab, "") for nm in names) + " |")

print("\n## Agreement between scorers (exact 0/1/2 match, non-executed prompts)\n")
print("| A | B | Agree | Out of |\n|---|---|---|---|")
for x, y in combinations(S, 2):
    labs = [l for l in key if n_of(l) not in GROUPS["executed"] and S[x].get(l, "") != "" and S[y].get(l, "") != ""]
    if labs:
        ag = sum(S[x][l] == S[y][l] for l in labs)
        print(f"| {x} | {y} | {ag} ({100*ag/len(labs):.0f}%) | {len(labs)} |")

if a.truth and a.truth in S:
    print(f"\n## Judges checked against {a.truth} (pass = 2, fail = 0 or 1; non-executed prompts)\n")
    print("Small sample: a sanity check of each judge, not a proper validation.\n")
    print(f"| Judge | Agrees on {a.truth}'s passes | Agrees on {a.truth}'s fails |\n|---|---|---|")
    T = S[a.truth]
    for name in S:
        if name == a.truth or name.endswith("-short"): continue
        labs = [l for l in key if n_of(l) not in GROUPS["executed"] and T.get(l, "") != "" and S[name].get(l, "") != ""]
        p = [l for l in labs if T[l] == "2"]; f = [l for l in labs if T[l] != "2"]
        tp = sum(S[name][l] == "2" for l in p); tn = sum(S[name][l] != "2" for l in f)
        pct = lambda x, y: f"{x}/{y} ({100*x/y:.0f}%)" if y else "n/a"
        print(f"| {name} | {pct(tp, len(p))} | {pct(tn, len(f))} |")

lp = pathlib.Path(a.lengths)
if lp.exists():
    L = {r["answer"]: r for r in csv.DictReader(open(lp))}
    print("\n## Length\n")
    print("| Config | Median words (raw) | Median words (stripped) | Median words (length-matched) |\n|---|---|---|---|")
    for cfg in configs:
        labs = [l for l in key if key[l] == cfg and l in L]
        med = lambda k: st.median(int(L[l][k]) for l in labs)
        print(f"| {cfg} | {med('words_raw'):.0f} | {med('words_stripped'):.0f} | {med('words_short'):.0f} |")
    pairs = [(n, n + "-short") for n in S if n + "-short" in S]
    if pairs:
        print("\n## Full vs length-matched sheet (same scorer, non-executed prompts)\n")
        print("| Scorer | Config | Full | Length-matched | Change |\n|---|---|---|---|---|")
        for full, short in pairs:
            for cfg in configs:
                f = sum(group_total(full, cfg, g)[0] for g in ("computed", "judgment"))
                s = sum(group_total(short, cfg, g)[0] for g in ("computed", "judgment"))
                print(f"| {full} | {cfg} | {f} | {s} | {s - f:+d} |")
