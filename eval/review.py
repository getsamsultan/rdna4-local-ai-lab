#!/usr/bin/env python3
"""Design review: send one document plus one fixed review brief to a model, save the review.

Usage: python3 review.py --url http://127.0.0.1:8098/v1 --label ds41-iq1m --doc design-doc.md [--out-dir DIR]
Writes review-<label>.json (review text, reasoning, tokens, timings) and review-<label>.md (review text only).
The brief fixes the output format and tells the model not to deny things newer than its training data.
Send the SAME doc and brief to every model you compare, then read the .md files without looking at which is which
(e.g. rename them A/B first). This is not part of the scored eval: there is no rubric, only your judgement.
"""
import argparse, json, pathlib, time, urllib.request

BRIEF = """You are reviewing an architecture document for a local AI system that will run on one person's workstation.

Find the most important problems: things that are wrong, missing, contradictory or risky in the design. Give at most 12, ranked by severity, high first.

Write each problem in exactly this format, with a blank line between problems:

**<number>. <short title>**
Where: <section name>
Problem: <what is wrong, missing or risky, one or two sentences>
Why it matters: <the practical consequence, one sentence>
Fix: <a concrete change to the design>
Severity: **High** | **Medium** | **Low**

Then a section titled **Claims I could not verify**, one bullet each: the claim, and why you can't confirm it.

Rules:
- Be specific to this document. No generic advice, no praise, no summary, no preamble.
- Versions, products, models and standards may be newer than your training data. If you don't recognise one, list it under "Claims I could not verify" as possibly newer than your knowledge. Never state that it does not exist.
- Only call something wrong when you can show why from the document itself or from well-established facts.
- Stay under 1,200 words.

DOCUMENT:
"""

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True); ap.add_argument("--label", required=True)
ap.add_argument("--doc", required=True); ap.add_argument("--out-dir", default=".")
ap.add_argument("--max-tokens", type=int, default=12288)
a = ap.parse_args()
out = pathlib.Path(a.out_dir); out.mkdir(parents=True, exist_ok=True)
doc = pathlib.Path(a.doc).read_text()
body = {"model": "local", "messages": [{"role": "user", "content": BRIEF + doc}], "max_tokens": a.max_tokens}
req = urllib.request.Request(a.url.rstrip("/") + "/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
t0 = time.time()
r = json.load(urllib.request.urlopen(req, timeout=7200))
msg = r["choices"][0]["message"]; tim = r.get("timings", {})
rec = {"label": a.label, "doc": pathlib.Path(a.doc).name, "review": msg.get("content", ""),
       "reasoning": msg.get("reasoning_content", ""), "wall_s": round(time.time() - t0, 1),
       "prompt_tokens": r.get("usage", {}).get("prompt_tokens"), "completion_tokens": r.get("usage", {}).get("completion_tokens"),
       "gen_tps": tim.get("predicted_per_second"), "finish_reason": r["choices"][0].get("finish_reason")}
(out / f"review-{a.label}.json").write_text(json.dumps(rec, indent=1))
(out / f"review-{a.label}.md").write_text(rec["review"] + "\n")
print(f"{a.label}: {rec['prompt_tokens']} prompt tokens, {rec['completion_tokens']} out, {rec['wall_s']} s, "
      f"finish={rec['finish_reason']} -> review-{a.label}.md")
