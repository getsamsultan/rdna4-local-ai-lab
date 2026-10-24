# Blind model comparison

15 hard prompts from my own fields (Modbus and OT, power and data centres, Linux/Docker, LLM inference, OT and agent security, code, data, monitoring) plus one honesty trap. Each is scored 0–2 against a written rubric, without knowing which model wrote the answer.

## Run

1. Serve one model at a time with `llama-server` (same engine build for every model), e.g. on `127.0.0.1:8099`.
2. Collect answers for each config:

   ```bash
   python3 run.py --url http://127.0.0.1:8099/v1 --label 80b
   python3 run.py --url http://127.0.0.1:8099/v1 --label qwen38-think  --extra '{"chat_template_kwargs":{"reasoning_effort":"medium"}}'
   python3 run.py --url http://127.0.0.1:8099/v1 --label qwen38-nothink --extra '{"chat_template_kwargs":{"reasoning_effort":"none"}}'
   ```

3. Shuffle and score blind:

   ```bash
   python3 blind.py answers-*.jsonl     # writes blind-sheet.md, scores.csv, key.json
   python3 score_cli.py                 # one answer at a time: prompt, rubric, answer, then 0/1/2 (saves as you go)
   # (or read blind-sheet.md with RUBRIC.md open and fill in scores.csv by hand) — don't open key.json
   python3 score.py answers-*.jsonl     # summary table
   ```

## Rules

- Same prompts, same engine build, one attempt each, no retries. Record the engine build and model hashes with the results.
- Score the final answer only. Reasoning text is saved but not scored.
- The rubric was written before any model was run.
- Working files (`answers-*.jsonl`, `blind-sheet.md`, `scores.csv`, `key.json`) are git-ignored so the key can't leak before scoring. Once scored, copy them all into `data/eval-<date>/` and commit them together, so anyone can re-check them.

The `reasoning_effort` values follow the Qwen3.8 model card; check what the template accepts if a value is rejected.

## AI judges (when no human scores, or as a cross-check)

```bash
python3 judge.py --url http://127.0.0.1:8098/v1 --name qwen35    # a model that is NOT a contestant
python3 compare.py scores-claude.csv scores-qwen35.csv           # agreement, disagreements, then totals per config
```

A contestant model must never judge its own test. Report which judges were used and how often they agreed.
