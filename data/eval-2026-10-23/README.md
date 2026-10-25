# Raw data — blind eval, 2026-10-23 (scored 2026-10-25)

| File | What it is |
|---|---|
| `answers-qwen38-think.jsonl` | Qwen3.8-Flash-Next, `reasoning_effort: medium` |
| `answers-qwen38-low.jsonl` | Qwen3.8-Flash-Next, `reasoning_effort: low` |
| `answers-qwen38-nothink.jsonl` | Empty: `reasoning_effort: none` returned HTTP 500 on the first prompt |
| `answers-80b.jsonl` | Qwen3-Coder-Next 80B |
| `blind-sheet.md` | The shuffled sheet both judges scored |
| `key.json` | Label → config (sha256 `87c98342c2c1b8d48b0524858e9ebe3f6b2507290326a77f694f8f37a263bb0f`) |
| `scores-claude.csv` | Judge 1, with a reason per answer |
| `scores-qwen35.csv` | Judge 2 (Qwen3.6-35B-A3B via `eval/judge.py`), with its reasons |

Re-check: copy these next to the scripts in [`eval/`](../../eval/) and run `python3 compare.py scores-claude.csv scores-qwen35.csv`. Prompts and rubric are in `eval/`.
