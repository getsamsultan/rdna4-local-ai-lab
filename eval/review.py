#!/usr/bin/env python3
"""Design review: send one document plus one fixed review brief to a model, save the review.

Usage: python3 review.py --url http://127.0.0.1:8098/v1 --label ds41-iq1m --doc design-doc.md [--out-dir DIR]
Writes review-<label>.json (review text, reasoning, tokens, timings) and review-<label>.md (review text only).
Send the SAME doc to every model you compare, then read the .md files without looking at which is which
(e.g. rename them A/B first). This is not part of the scored eval: there is no rubric, only your judgement.
"""
import argparse, json, pathlib, time, urllib.request

BRIEF = """You are reviewing an architecture document for a local AI system that will run on one person's workstation.

Find the most important problems. For each problem give:
1. Where (section name).
2. What is wrong, missing or risky, in one or two sentences.
3. Why it matters in practice.
4. A concrete fix.
5. Severity: high, medium or low.

Rank problems by severity, high first. Give at most 12. Then, separately, list any factual or technical claims in the document that you think are wrong or that you cannot verify, and say why.

Rules: be specific to this document, not generic advice. No praise, no summary of the document, no preamble. If something is fine, don't mention it. Stay under 1,200 words.

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
