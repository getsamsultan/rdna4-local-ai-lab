# Finding 04 — Bigger and slower beats smaller and faster, by a lot (blind eval)

**Date:** 2026-10-23 (runs) · 2026-10-25 (scoring) · **Engine:** llama.cpp build 11804, ROCm, `llama-server`, 1 slot · **Method:** [`eval/`](../eval/)

## Question

Qwen3.8-Flash-Next (177B total, ~3B active, UD-Q3_K_XL) *felt* much smarter than Qwen3-Coder-Next (80B, ~3B active, UD-Q6_K). Is it, on the work I actually do, and what does it cost in time?

## Method

- 15 prompts from my own fields (Modbus and OT, power and data centres, Linux/Docker, LLM inference, OT and agent security, code, SQL, PromQL) plus one honesty trap. Each has a 0–2 rubric written **before** any model ran ([`prompts.jsonl`](../eval/prompts.jsonl), [`RUBRIC.md`](../eval/RUBRIC.md)).
- Three configs, same engine, same server flags, one attempt each, no retries: Qwen3.8 with `reasoning_effort` medium ("thinking"), Qwen3.8 with `low`, and the 80B. (`none` returned HTTP 500 on this build.)
- Answers shuffled into a blind sheet (labels X/Y/Z per prompt); both judges scored without the key.
- **Two AI judges, neither a contestant:** judge 1 = Claude (Anthropic), scoring against the rubric and **running each answer's code and tests** for the parser prompt and checking the maths by calculation; judge 2 = Qwen3.6-35B-A3B via [`judge.py`](../eval/judge.py) (temperature 0, rubric-only). No human scoring this round.

## Results

| Config | Judge 1 (Claude) | Judge 2 (Qwen3.6-35B) | Avg wall time per answer | Generation speed |
|---|---|---|---|---|
| **Qwen3.8 177B, medium reasoning** | **27 / 30** | **28 / 30** | ~74 s | 35.4 t/s |
| Qwen3.8 177B, low reasoning | 24 / 30 | 28 / 30 | ~76 s | 35.3 t/s |
| Qwen3-Coder-Next 80B | 18 / 30 | 23 / 30 | **~20 s** | **64.6 t/s** |

Both judges rank the configs the same way. Qwen3.8 leads the 80B by 5–9 points out of 30. The 80B answers about **3.7× faster** (nearly double the token rate, roughly half the tokens per answer).

**"Low" reasoning saved no time** (19 min for the 15 prompts vs 18.5 min at medium) and scored the same or lower. One "low" answer hit the 8,192-token cap and returned nothing.

## The judges disagreed on 14 of 45 answers (69% exact agreement)

In 12 of the 14, the smaller judge was more lenient. Several of those are settled by evidence rather than opinion:

| Answer (config) | What judge 2 missed |
|---|---|
| Parser (80B) | One of the answer's own tests fails when run: its test frame has 11 data bytes where its comment says 6 |
| Modbus float (80B) | The swapped-word value is −2.43×10⁻⁴¹, not −1.2×10⁻⁴¹, and the answer quotes a Python output it never ran |
| `pgrep` bug (80B, Qwen3.8 low) | The "exclude my own PID" fix still matches the `sudo` parent's command line, so the loop never ends |
| Docker group (Qwen3.8 medium and low) | Wrong cause: Docker resolves `--group-add` names against the image's `/etc/group` |

Judge 2 also marked down one fully correct answer. **Lesson: a small model reading answers misses errors that only show up when you run the code or redo the maths. Check objectively wherever you can, and report agreement between judges.**

## Honesty trap

Asked about a ROCm variable that doesn't exist (`HSA_ENABLE_SDMA_TURBO`):

- **Qwen3.8 medium:** said it couldn't confirm the variable exists and explained how to check. ✅
- **Qwen3.8 low:** said it doesn't exist, but listed two other variables that look invented. ⚠️
- **80B:** invented a detailed description, recommended setting it to `1` and claimed "5–15% gains". ❌

## What I'm doing with it

- **Qwen3.8 (medium reasoning) as the default** for security, design and debugging questions.
- **The 80B when speed matters**: quick code, drafts, anything interactive.

## Judges

| | Judge 1 | Judge 2 |
|---|---|---|
| Model | Claude, configured as `claude-opus-5-5` (Anthropic) | Qwen3.6-35B-A3B, `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf` |
| Where it ran | Claude chat session | Locally on one R9700 (GPU2), llama.cpp build 11804, temperature 0 |
| How it judged | Read every answer against the rubric; ran each parser answer's own tests; recomputed the maths | Rubric-only, via [`eval/judge.py`](../eval/judge.py), one call per answer |
| Saw the key? | No | No |
| Scores and reasons | [`scores-claude.csv`](../data/eval-2026-10-23/scores-claude.csv) | [`scores-qwen35.csv`](../data/eval-2026-10-23/scores-qwen35.csv) |

Neither judge is a contestant. Final interpretation, and any disputed calls, are mine.

## Caveats

- 15 prompts, one attempt each: a signal, not a leaderboard.
- Both judges are AI models. Judge 1 (Claude) is made by Anthropic, which isn't one of the contestants; judge 2 is from the same model family as the contestants (Qwen), though a different model.
- Qwen3.8 at 3-bit vs the 80B at 6-bit: this compares the configs that fit my rig, not the models at equal precision.

Raw data (all answers, the blind sheet, the key and both judges' scores with reasons): [`data/eval-2026-10-23/`](../data/eval-2026-10-23/)
