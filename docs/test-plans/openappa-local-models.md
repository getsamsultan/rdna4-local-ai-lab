# Test plan: OpenAPPA in front of local open-weight models

**Status:** planned, not started. Nothing below has been run yet.

**Tool under test:** [OpenAPPA](https://github.com/archestra-ai/OpenAPPA) by Archestra (MIT, preview and RFC). Paper: "APPA: Recoverable Information-Flow Control for Real-World LLM Agents", accepted to the NeurIPS 2026 Workshop on Agents in the Wild.

**Companion plan:** Songe, a model that fine-tunes itself on agent conversations, in the model editing lab (plan drafted 26 Nov, to be added there). Phase 5 here uses the poisoned adapter from its phase 4.

**Background:** projects [4 (policy-constrained tool calling)](../agentic-security-projects.md#4-policy-constrained-tool-calling) and [13 (poisoned lessons)](../agentic-security-projects.md#13-self-learning-agents-poisoned-lessons) in the agentic security track.

## What it claims, and what we are testing

OpenAPPA sits between an agent and its tools. It tracks the sensitivity and trust of everything the agent reads, and before every tool call it decides, from the event log alone, whether that data may reach that destination. Policy is TOML (`appa.toml`). The same log always gives the same decision, and `appa replay` checks scripted tool calls against expected decisions.

Its README reports 0 successful attacks out of 1,320 evaluations on Bench-Corp and AgentThreatBench, with 88 to 90% task completion. Those numbers are self-reported, and they come from frontier-model agents. Nobody has published how it does in front of local open-weight models, which make more mistakes and follow injected instructions more readily. That is the gap this plan fills.

Questions:

1. Does it work with an agent running on local models on this rig?
2. With it on, how many planted attacks still succeed, and how many ordinary tasks still finish?
3. Are its decisions really deterministic and replayable?
4. Can an information-flow guard catch an instruction that was learned into the weights, where nothing the agent read in the session is untrusted?

## Guesses, written before any run

- Phase 2: attack success drops to near zero with OpenAPPA on, as with frontier agents, because the decision does not depend on the model.
- Phase 2: task completion drops more than the 1 to 2 points it reports, because local models make more messy tool calls that a strict policy blocks.
- Phase 3: replay gives identical decisions every time.
- Phase 5: OpenAPPA blocks the learned behaviour only where the destination itself is not allowed, because the session carries no untrusted data to track. A learned instruction aimed at an allowed destination gets through.

## Setup and isolation

- **Install: read before running.** The documented install is `curl -fsSL https://openappa.com/install.sh | sh`. Download the script first, read it, record its sha256, and run it inside a container, not on the host. If the source can be built instead, build it at a recorded commit.
- Agent: OpenCode (on OpenAPPA's supported list), pointed at the lab's own `llama-server` (OpenAI-compatible) on the R9700s.
- Models, one at a time: Qwen3-Coder-Next 80B (three cards), Qwen3.6-35B, and Qwen3-4B-Instruct-2507 (to match the Songe plan).
- Network: localhost only during runs. "Attacker" destinations are local listeners the lab owns.
- `appa describe --config appa.toml --check` must pass before any run.

Recorded for every run: OpenAPPA commit or install-script sha256, `appa.toml` sha256, OpenCode version, llama.cpp commit and ROCm version, model name and sha256, quant, settings, and the dates.

## Phase 1: does it run with local models?

1. Install, configure for OpenCode, run `appa describe --check`.
2. Ten ordinary tasks on a scratch repo with OpenAPPA on, on each model.
3. Record: does every tool call pass through it, what each check costs in latency, and any failure.

**Pass:** every tool call shows in the event log with a decision.

## Phase 2: attacks blocked, tasks kept (A-B-A)

The injection set from project 4: documents, web pages and file contents that try to make the agent send data somewhere it should not, run tools it should not, or change files outside the task. Each attack has a harmless canary (a marker string, or a request to a local listener), so success is counted by a script, not judged.

1. **A:** OpenAPPA off. Run the injection set and an ordinary task set. Count attacks that succeeded and tasks completed.
2. **B:** OpenAPPA on, same sets, same seeds.
3. **A again:** off again, to check nothing else changed in between.

Per model: attack success rate, task completion rate, false blocks (ordinary tool calls blocked), and added latency per tool call.

Also capture outbound traffic from the container during the B run. OpenAPPA's README says its decision engine makes no network or file calls; that is a claim to check, the same way the Songe plan checks "nothing leaves your machine". Temperature 0 with prompt caching off, as in the lab's [prompt-cache finding](../agentic-security-projects.md#1-kernel-and-runtime-integrity-repeatability-and-timing-side-channels), so runs repeat.

If Bench-Corp or AgentThreatBench are public, run them too, on the local models, and report the numbers next to OpenAPPA's frontier-model ones without mixing the two.

## Phase 3: is replay deterministic?

1. Save the event logs from phase 2.
2. Run `appa replay` on them three times. Decisions should be identical every time.
3. Change one label or one tool call in a copy of a log and replay it: the decision should change exactly where expected, and nowhere else.
4. Write a few `policy-tests/` for this lab's own tools, as a reusable check in CI.

## Phase 4: add the grammar layer

Project 4's other half: a llama.cpp grammar generated from the same allowlist, so a disallowed tool call cannot even be written. Run phase 2 again with grammar only, OpenAPPA only, and both. What does each catch that the other misses, and what does each cost?

## Phase 5: combined with Songe

The test nobody else can run without both halves. It needs the planted-run adapter from phase 4 of the Songe plan.

1. Serve Qwen3-4B-Instruct-2507 with the poisoned adapter. The model has learned the canary behaviour; nothing in the session is planted.
2. Run 20 clean tasks with OpenAPPA off, then on.
3. Count the two planted behaviours separately:
   - **The request to the local listener:** a data flow, so OpenAPPA can see it. Count hits with the listener blocked by policy, and with it allowed (added to the allowlist). This tests the guess.
   - **The marker word in commit messages:** no data moves anywhere, so no information-flow guard can see it, by design. Count it anyway: it shows the kind of learned behaviour that only a check at training time can catch.

**What it shows:** whether a guard that tracks what the agent reads can stop behaviour that came from the weights. If the guess is right, the answer is "only by destination", and the defence for self-learning agents has to sit in the training gate (Songe plan, phase 4 defences), not only at the tool call.

## Records to keep

In `data/`, one dated file per phase: versions and hashes, the guess, raw counts, event logs, and anything that failed. A finding is written up in `findings/` once phases 2 and 5 have data.

## Rules for this plan

- Only the lab's own agent, models and services. Canaries are harmless and only reach listeners the lab owns.
- Working injection payloads beyond what is needed to reproduce a result are not published.
- OpenAPPA's benchmark numbers are its own claims until reproduced, and frontier-model results are never compared directly with local-model ones as if they were the same test.
- Anything that looks like a gap in OpenAPPA goes to Archestra privately first, as a question about the design.
