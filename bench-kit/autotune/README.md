# autotune (draft, untested)

An overnight loop that lets a coding agent tune llama.cpp flags on this rig, one change at a time, with a scorer it can't fool. Inspired by Andrej Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) (fixed budget, one editable file, human-written program, git trail), with guards for its weak spots:

| autoresearch weakness | Guard here |
|---|---|
| Keeps any improvement, so it ratchets on noise | A–B–A–B, candidate must beat **both** best runs by more than `max(MIN_GAIN_PCT, 2 × stddev)` |
| One metric, easy to win by breaking quality | Perplexity on a fixed text must stay within `PPL_TOL_PCT` |
| Scorer protected only by an instruction | `score.sh` checks its own sha256 and refuses to run if changed |
| Runs forever | `MAX_EXPERIMENTS` / `MAX_HOURS` enforced by the scorer itself, plus stop after 10 rejects in a row |
| Failed experiments are thrown away | Every attempt logged in `results.jsonl`; lessons go to `rules.md` |
| Greedy hill-climb | Every 5th attempt must be exploratory |

## Files

| File | Who edits it |
|---|---|
| `program.md` | Human: the agent's instructions |
| `score.sh`, `autotune.env` | Nobody after the first run (hash-locked, and the scorer refuses uncommitted changes) |
| `autotune.env` | Human, before the first run: model, image, GPUs, metric, thresholds, caps |
| `best.args` | Only via the keep step |
| `candidate.args` | Agent |
| `results.jsonl` | `score.sh` appends |
| `journal.md`, `rules.md` | Agent |
| `ppl.txt` | Human: fixed text for the quality gate (a few thousand words of plain prose) |

## Run

```bash
cp autotune.env.example autotune.env   # edit
echo "-ngl 99 -sm layer -fa 1 -p 512 -n 128" > best.args
./score.sh   # first run only locks score.sh + autotune.env and records the start time
git add -A && git commit -m "autotune: lock scorer"   # the scorer refuses to run with uncommitted changes to itself
# then start the agent:
claude --permission-mode acceptEdits -p "Follow program.md in this folder until a stop condition is met." \
  --allowedTools "Read,Edit,Write,Bash(./score.sh),Bash(git add *),Bash(git commit *),Bash(cp candidate.args best.args)"
```

Honest limit: an agent with write access could still edit the scorer, re-hash it and commit. The guards make that impossible to do silently, not impossible: it would show in the git history, which is why you review the commits.

Run it on a branch (`git switch -c autotune/<date>`), and review the commits before merging anything. Status: written 5 Nov 2026, not yet run on the rig.
