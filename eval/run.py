#!/usr/bin/env python3
"""Send every prompt in prompts.jsonl to an OpenAI-compatible llama-server and save the answers.

Usage: python3 run.py --url http://127.0.0.1:8099/v1 --label qwen38-think [--extra '{"chat_template_kwargs":{"reasoning_effort":"medium"}}']
Writes answers-<label>.jsonl next to this script. Only the final answer is scored; reasoning text is kept separately.
"""
import argparse, json, time, urllib.request, pathlib

ap = argparse.ArgumentParser()
ap.add_argument("--url", required=True, help="base URL ending in /v1")
ap.add_argument("--label", required=True, help="short name for this model/config, e.g. 80b or qwen38-think")
ap.add_argument("--model", default="local", help="model name to send (llama-server ignores it)")
ap.add_argument("--max-tokens", type=int, default=8192)
ap.add_argument("--extra", default="{}", help="JSON merged into each request, e.g. sampling or chat_template_kwargs")
a = ap.parse_args()

here = pathlib.Path(__file__).parent
prompts = [json.loads(l) for l in open(here / "prompts.jsonl")]
out = open(here / f"answers-{a.label}.jsonl", "w")
for p in prompts:
    body = {"model": a.model, "messages": [{"role": "user", "content": p["prompt"]}], "max_tokens": a.max_tokens}
    body.update(json.loads(a.extra))
    req = urllib.request.Request(a.url.rstrip("/") + "/chat/completions", json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=3600))
    msg = r["choices"][0]["message"]
    tim = r.get("timings", {})
    rec = {"n": p["n"], "id": p["id"], "label": a.label, "answer": msg.get("content", ""),
           "reasoning": msg.get("reasoning_content", ""), "wall_s": round(time.time() - t0, 1),
           "completion_tokens": r.get("usage", {}).get("completion_tokens"),
           "gen_tps": tim.get("predicted_per_second"), "request_extra": json.loads(a.extra)}
    out.write(json.dumps(rec) + "\n"); out.flush()
    print(f"{p['n']:>2} {p['id']:<16} {rec['completion_tokens']} tokens, {rec['wall_s']} s, {rec['gen_tps'] and round(rec['gen_tps'],1)} t/s")
print(f"saved {out.name}")
