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

## Round 2 design (planned, from community feedback on round 1)

Round 1 ([Finding 04](../findings/04-qwen38-vs-80b-blind-eval.md)) used two AI judges and only one prompt with runnable code. Questions from readers on X pointed at the weak spots, so round 2 adds:

1. **More executable checks.** SQL run against a real PostgreSQL with test data, PromQL rules checked with `promtool`, shell fixes run in a throwaway container, maths compared to a computed answer. Score those mechanically, not by a judge.
2. **Style stripping before judging.** Remove emoji, headings, sign-offs and "let me know if…" lines, so formatting doesn't reveal which model wrote an answer.
3. **Length-matched scoring.** Report answer length next to every score, and check whether the ranking holds when long answers are trimmed to a common budget, since LLM judges tend to favour longer answers.
4. **A human blind pass.** At least one person scores the stripped sheet without the key; report human–AI agreement alongside judge–judge agreement.
5. **Split reporting.** Executed / checkable / judgment prompts reported separately, not only as one total.
6. **Every judge on every set.** Both AI judges (and the human pass) score both the original and the length-matched sheets. Report each judge's totals and judge-vs-judge agreement per set. In round 1 the judges differed by 2 points on a 3–5 point prose gap, so the judge is a variable to measure, not a constant. A result that appears with only one judge gets reported as exactly that.

### Round 2: how to run it

```bash
cd eval
# 1. one shuffle, two sheets: style-stripped (blind-sheet.md) and length-matched (blind-sheet-short.md), same labels
python3 blind.py --round2 answers-a.jsonl answers-b.jsonl answers-c.jsonl

# 2. human blind pass on the stripped sheet (saves as you go, Ctrl+C to pause). Don't open key.json.
python3 score_cli.py --scores scores-<you>.csv

# 3. AI judges, each on both sheets (judge model must not be a contestant)
python3 judge.py --url http://127.0.0.1:8098/v1 --name qwen35
python3 judge.py --url http://127.0.0.1:8098/v1 --name qwen35-short --sheet blind-sheet-short.md

# 4. mechanical checks (AFTER the human pass: the output names configs). Needs a scratch PostgreSQL and promtool.
python3 execcheck.py --pg "host=/tmp port=5432 user=postgres" --promtool /path/to/promtool answers-*.jsonl

# 5. report: split totals, machine vs judges on executed prompts, agreement, length effect
python3 report.py --exec exec-results.csv --truth <you> scores-<you>.csv scores-qwen35.csv scores-qwen35-short.csv
```

What each part does:

- **`prep.py`** strips emoji, markdown headings and bold, horizontal rules, and chatty opening/closing lines. Code blocks are untouched. Ticks and crosses become "yes"/"no" because they often carry the answer ("Fits? ❌"). Arrows and maths symbols are kept.
- **Length matching** trims every answer to the shortest non-empty stripped answer for that prompt (word count). An empty answer stays empty and doesn't set the budget.
- **`execcheck.py`**
  - Prompt 12: imports the answer's `parse_mbap` and runs 7 hidden tests, plus the answer's own pytest tests.
  - Prompt 13: runs the answer's SQL on PostgreSQL against 3 meters × 2 days of 15-minute data, with a rollover mid-morning, a rollover exactly at midnight and a 2-hour gap. It compares the result with computed daily totals. Attributing an interval to the later reading's day, dropping cross-midnight intervals and dropping intervals across the gap all count as correct. Attributing to the earlier reading's day scores 1.
  - Prompt 14: `promtool check rules`, then promtool unit tests check that the rule fires for the card above 300 W only and that query (a) returns one 5-minute average per card. A rule that only fails on an annotation template scores 1 (Prometheus won't load it, but the logic is right).
  - These three replace the judges' scores for those prompts. A key-number search for prompts 1–4, 7 and 8 is in the output as a weak cross-check only. LaTeX and tables hide numbers from it, so it isn't used in any total.
- **`report.py`** prints totals split into executed / computed / judgment, the machine result next to each scorer's score on the executed prompts, scorer-vs-scorer agreement, median length per config, and full vs length-matched totals for each scorer that did both. With `--truth <you>` it also shows how often each judge agrees with the human on passes (2) and on fails (0/1), the judge check Hamel Husain recommends, on a sample too small to be a full validation.
