#!/usr/bin/env python3
"""LLM-as-judge: score every blind answer 0/1/2 against the rubric, via an OpenAI-compatible server.

Usage: python3 judge.py --url http://127.0.0.1:8098/v1 --name qwen35
Writes scores-<name>.csv (same layout as scores.csv). The judge never sees key.json.
"""
import argparse, csv, json, re, urllib.request, pathlib
from blindlib import here, prompts, rubric, answers
ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True); ap.add_argument("--name", required=True)
a = ap.parse_args()
P, R, A = prompts(), rubric(), answers()
rows = list(csv.DictReader(open(here / "scores.csv")))
SYS = ("You are a strict, fair grader. Score the ANSWER against the RUBRIC only. Ignore length, style and "
       "confidence; reward correctness. Reply with JSON only: {\"score\": 0|1|2, \"reason\": \"one sentence\"}.")
out = []
for r in rows:
    n, lab = r["n"], r["answer"]
    user = f"QUESTION:\n{P[n]['prompt']}\n\nRUBRIC:\n{R[n]}\n\nANSWER:\n{A.get(lab) or '(empty answer)'}"
    body = {"model": "judge", "messages": [{"role": "system", "content": SYS}, {"role": "user", "content": user}],
            "temperature": 0, "max_tokens": 2048, "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(a.url.rstrip("/") + "/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    txt = json.load(urllib.request.urlopen(req, timeout=1800))["choices"][0]["message"].get("content", "")
    m = re.search(r'"score"\s*:\s*([012])', txt); why = re.search(r'"reason"\s*:\s*"([^"]*)"', txt)
    s = m.group(1) if m else ""
    out.append({**r, "score_0_2": s, "notes": (why.group(1) if why else txt[:200]).replace("\n", " ")})
    print(f"{lab:>4}  {s or '?'}  {out[-1]['notes'][:90]}")
with open(here / f"scores-{a.name}.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(out)
print(f"saved scores-{a.name}.csv")
