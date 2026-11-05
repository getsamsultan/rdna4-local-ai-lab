# autotune program (the agent's instructions)

You are tuning llama.cpp on this machine for one model and one target metric (`METRIC` in `autotune.env`). You try one change at a time, the scorer decides, and you keep a written record. You do not touch anything else.

## What you may change
Only `candidate.args`: one line of llama-bench flags. Allowed flags: `-ngl -sm -fa -ub -b -ncmoe -t -ts -ctk -ctv -nopo -mmp -p -n -d`. The scorer rejects anything else.

## What you must never change
`score.sh`, `score.sha256`, `autotune.env`, `.started`, `best.args`, `results.jsonl`, `ppl.txt`, anything outside this folder. The scorer checks its own hash and stops if it was edited. `best.args` only changes through the keep step below.

## The loop
1. Read `rules.md` and the last 20 lines of `results.jsonl`.
2. **Write the check first:** append one line to `journal.md` saying what you'll change, why, and what result you expect.
3. Write `candidate.args`: copy `best.args` and change **one** thing. Every 5th attempt must be exploratory: a bigger jump or a flag you haven't tried yet, not a small nudge.
4. Run `./score.sh`. Do not interpret the numbers yourself: the `verdict` field decides.
5. If `keep`: copy `candidate.args` to `best.args`, then `git add -A && git commit -m "autotune: keep <change> (+<gain_pct>%)"`.
6. If `reject`: commit only the log (`git add results.jsonl journal.md rules.md && git commit -m "autotune: reject <change>"`). If the reason is general (for example "-t above physical cores always loses"), add one line to `rules.md` so you don't try it again.
7. Repeat.

## Stop when any of these is true
- `MAX_EXPERIMENTS` attempts are done, or `MAX_HOURS` have passed (both in `autotune.env`).
- 10 rejects in a row: write a short summary in `journal.md` and stop.
- The scorer returns `"verdict":"error"`: stop immediately and report.
- Anything would need sudo, a reboot, a driver or BIOS change, deleting files, or network access: stop and ask the human. Those are irreversible or outside scope.

## Known facts about this rig (from the lab's own data; don't re-test unless exploring)
- Never use `-t` above the physical core count (16): SMT more than halves generation.
- With experts in system RAM, `-ub 2048` gave +59% prompt speed.
- Restart the monitoring agent before a session: an agent left as started at boot costs about 5% of generation.
- Run-to-run noise is about 1-3%. Gains smaller than that are not real.
