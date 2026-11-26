# Agentic security across the inference stack: 13 projects

The usual "12 inference infrastructure projects" list asks how to make each layer faster and cheaper. This version asks, at the same 12 layers, **what an attacker can do there once a model is acting as an agent, and how to close the gap.** Each project is defensive, runs on this lab's own hardware against its own services, and ends in a published measurement, not a claim.

Agents change the threat model: the model's output is no longer just text, it becomes tool calls, shell commands, SQL and network requests. So every layer that touches prompts, caches, routing or outputs is part of the attack surface.

| # | Layer | Main risk for agents |
|---|---|---|
| 1 | Kernels and runtime | Non-repeatable outputs and timing side channels |
| 2 | Prefill/decode transfer | Conversation state in transit between machines |
| 3 | KV cache offload | Conversation state at rest in RAM and on SSD |
| 4 | Decoding | Tool calls with dangerous arguments |
| 5 | MoE routing | Prompts that steer around the model's safety behaviour |
| 6 | Quantisation | Safety that degrades as bits are removed; tampered files |
| 7 | Speculative decoding | A second model in the loop; timing leaks |
| 8 | Autoscaling | Runaway agents: denial of wallet |
| 9 | Semantic cache | One user receiving another user's answer; poisoned entries |
| 10 | Model router | Downgrade to a weaker model; data sent outside |
| 11 | Edge fallback | Weaker safety when the main service is down |
| 12 | Public benchmark | Security measured as seriously as speed |
| 13 | Self-learning agents | An injected instruction learned into the weights, not just followed once |

---

### 1. Kernel and runtime integrity: repeatability and timing side channels

**Risk.** Audits and evaluations assume the same input gives the same output. This lab measured that it does not always: with prompt caching on, a repeated temperature-0 request on ROCm can change from the 4th token, because the cached prompt is finished at batch size 1 by a different kernel. The same cache creates a timing signal: a cached prompt answers in about 20 ms, an uncached long one in about 140 ms.

**Build.** A test harness that (a) checks output repeatability per backend and setting (null tests, KL divergence), and (b) measures whether time-to-first-token reveals that someone else recently sent the same prompt prefix on a shared server.

**Close the gap.** Cache isolation per tenant or user, caching off for evaluation and audit runs, batch-invariant settings where an engine offers them (DeepSeek's DeepInfer does, on NVIDIA only), and documented limits where it does not.

**Shows:** you can turn a correctness quirk into a measured security property.

### 2. Securing prefill/decode transfer

**Risk.** Disaggregated serving ships the KV cache (a compressed record of the conversation) between machines. Unauthenticated or unencrypted, it can be read, replayed or swapped.

**Build.** A two-process setup on one host or two (prefill on one card, decode on another), with the transfer authenticated and encrypted (mutual TLS), plus an integrity check on every block. Measure the latency cost of the protection.

**Shows:** you treat model state as sensitive data, and can price the protection.

### 3. KV cache at rest: encrypted spill and guaranteed wipe

**Risk.** Spilling KV blocks from VRAM to RAM and NVMe writes conversations to places that outlive the session: swap, SSD blocks, crash dumps.

**Build.** A spill path that encrypts blocks with a per-session key, separates tenants, and destroys the key at session end (so the data on disk is unreadable). Verify by searching RAM and disk for known plaintext after a session. Measure the throughput cost.

**Shows:** you can serve long-context agents without leaving their memories on disk.

### 4. Policy-constrained tool calling

**Risk.** Grammar-constrained decoding guarantees valid JSON, not safe JSON. A valid tool call can still carry `rm -rf`, a SQL `DROP`, or a URL to an attacker's server, often planted by a prompt injection in a web page or document the agent read.

**Build.** A decoding layer where the grammar is generated from an allowlist policy: permitted tools, argument types, value ranges and patterns (for example, only read-only SQL, only paths under a sandbox, only allowlisted domains). Then an injection test set: documents that try to make the agent call tools it should not.

**Reference to test first, not rebuild:** [OpenAPPA](https://github.com/archestra-ai/OpenAPPA) (MIT, preview), which sits between an agent and its tools, labels everything the agent reads by sensitivity and trust, and blocks a tool call when that data would reach a destination the policy doesn't allow. The decision is deterministic and replayable from its event log. Its published results come from frontier-model agents; run it in front of local open-weight models on this rig, against the same injection set, and measure attacks blocked and tasks still completed. Then add the grammar-from-policy layer on top and see what each adds.

**Shows:** you can make unsafe tool calls impossible to generate, not just unlikely.

### 5. Does safety live in particular experts?

**Risk.** In a mixture-of-experts model, refusals may depend on which experts the router picks. If certain prompts reliably steer routing away from them, safety behaviour could be bypassed without touching the weights.

**Build.** Log expert routing for matched pairs of prompts (harmful request refused vs the same request wrapped in a jailbreak style) and measure whether routing shifts. Pair it with refusal rates. This connects directly to the model-editing lab's abliteration work.

**Shows:** you can investigate safety mechanisms inside the model, not just at the API.

### 6. Safety-aware quantisation and file provenance

**Risk.** Quantisation is measured for quality (perplexity, KL divergence) but rarely for safety: refusal and injection-resistance rates can shift as bits are removed. And a GGUF from an unknown uploader can be anything.

**Build.** Extend the lab's quant report (already done for Ripple-65B and Inkling 2 Mini) with refusal rate and prompt-injection success rate per quant. Publish sha256 for every file, the exact converter commit, and a reproducible recipe so anyone can rebuild and compare hashes.

**Shows:** you can prove what a smaller model costs in safety as well as in quality, and that the file is what it claims to be.

### 7. Speculative decoding: prove it changes nothing

**Risk.** A second (draft) model now sits in the generation loop. With exact verification it cannot change the output, but that should be tested rather than assumed, and acceptance rates may leak information through timing.

**Build.** Run the same prompts with and without speculative decoding (for example the multi-token-prediction variant of a 27B model) and check outputs are identical with `squeeze check`. Measure whether per-request latency varies with content in a way an observer could exploit.

**Shows:** you verify performance features for side effects before trusting them.

### 8. Agent budgets and kill switches

**Risk.** Agents loop. A runaway or hijacked agent can burn compute, API credit or cloud GPUs (denial of wallet), or flood internal services.

**Build.** A controller that gives each agent identity a token, time and tool-call budget, rate limits, and a kill switch, with alerts when an agent hits its limits. Test it with deliberately looping agents. (The lab simulates the scaling side; no cloud spend needed.)

**Shows:** you can keep autonomous systems inside a budget an operator sets.

### 9. A semantic cache that cannot leak or be poisoned

**Risk.** Returning a cached answer for a "98% similar" prompt can hand user B the answer generated for user A, including anything private in it. An attacker can also craft prompts that plant a poisoned answer which then gets served to others.

**Build.** A cache scoped per tenant (never shared by default), entries signed and tied to the model and policy version, a similarity threshold tested against crafted near-miss prompts, and sensitive content never cached. Measure leakage with planted canary strings.

**Shows:** you know when the cheapest token is also the most dangerous one.

### 10. A router that cannot be downgraded or leak

**Risk.** A complexity router can be gamed: a prompt crafted to look simple gets sent to a smaller model with weaker safety, or one crafted to look hard gets sent to an external API, carrying internal data out.

**Build.** Add the lab's planned egress audit and routing eval to the router: data classification before routing (sensitive data never leaves the building), safety parity checks between the routed models, and an adversarial test set aimed at the router itself.

**Shows:** you can cut cost with routing without opening a path for data to leave.

### 11. Fail closed at the edge

**Risk.** When the main service is down, an edge fallback model (browser or laptop) may run without the server-side guardrails, tool policy or logging. A model running in the user's browser can also be modified by that user.

**Build.** A fallback design where the safety policy travels with the request (and dangerous tools stay server-side only), with a documented fail-closed rule: if the guardrails are not available, the agent loses its tools rather than its safety. Test by cutting the main service mid-task.

**Shows:** you design for the outage, not just the happy path.

### 12. Public agentic security benchmark

**Risk.** Engines and models publish speed and price, rarely how easily an agent built on them can be hijacked.

**Build.** A published, reproducible comparison across local models, quants and engines: prompt-injection success rate, unsafe tool-call rate, data-exfiltration attempts blocked, plus the cost and latency of each defence, as Pareto curves (security vs cost vs latency). Blind scoring and executed checks, as in the lab's quality evals.

**Shows:** you measure security with the same rigour as performance, and publish it.

### 13. Self-learning agents: poisoned lessons

**Risk.** A new kind of tool learns from an agent's own conversations and fine-tunes the local model overnight (for example [Songe](https://github.com/sous-labs/songe), a proxy that turns corrections, retries and tool errors into lessons and trains a LoRA adapter). If a web page, email or document the agent read carried an injected instruction, and that conversation becomes a lesson, the model can learn the attacker's behaviour into its weights. A prompt injection then outlives the session that delivered it.

**Build.** On the lab's own agent and model: plant injected instructions in documents the agent reads during normal tasks, let the learning cycle run, then test the new version on clean tasks with no injection present. Measure how often the planted behaviour appears afterwards, against a control run without the planted documents. Then test defences: excluding turns that followed untrusted content from training, provenance labels on every lesson (from the same idea as project 4's data labels), and a safety check in the gate that decides whether a new version goes live.

**Shows:** you can see a threat that appears only when models start learning from their own work, before it ships to people's laptops.

Raise findings with the tool's authors privately first, as a question about their design, not a public claim.

---

## Ground rules

- Only the lab's own systems, models and data. No testing of other people's services without written permission.
- Defensive results are published; working attack payloads beyond what is needed to reproduce a fix are not.
- Every claim gets a measurement, a guess written down first, and raw data.

## Order (after the Lemonade entry and eval round 2)

Start with the ones that reuse existing work: **1** (from the prompt-cache finding), **6** (from the Ripple and Inkling quant reports), **10** (from the planned egress audit and routing eval) and **4** (the core of agent safety). Then 9, 8, 7, 3, 12. Projects 2, 5 and 11 are research-grade and come last. Project 13 starts after 4, since it reuses the injection set and the data labels.
