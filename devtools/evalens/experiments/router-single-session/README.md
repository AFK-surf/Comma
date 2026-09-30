# Isolated triple-branch single-session evaluation

Each target/source family is one Evalens experiment:

- `agentlongbench-salix.exp.ts` (`tier=32k|256k|1m`)
- `agentlongbench-codex.exp.ts` (`tier=32k|256k|1m`)
- `longmemeval-v2-salix.exp.ts`
- `longmemeval-v2-codex.exp.ts`

AgentLongBench's run-level `tier` parameter selects the corresponding
content-addressed dataset loader before the run is created. The selected
dataset name and digest and the parsed tier remain persisted in the run
manifest. A rerun recovers the tier from its source manifest before loading and
validating the dataset.

One dataset item produces one run item containing all three causal branches:

| Branch      | Seed history    | Explicit compaction |
| ----------- | --------------- | ------------------- |
| Fresh       | current         | no                  |
| Accumulated | prior + current | no                  |
| Compacted   | prior + current | yes                 |

Accumulated and Compacted receive byte-identical, order-identical history.
Fresh, Accumulated, and Compacted never share a Salix agent group, Salix
session, Codex process, or Codex thread. The run item fails unless all three
isolation IDs are distinct, the Accumulated/Compacted seed digests match, and
only Compacted received the explicit compaction operation.

All three branches are launched concurrently within one run item. The local
experiment config runs four dataset items concurrently, so one experiment may
have up to twelve active branches. Item retries wait for every branch to finish
cleanup, then retry the whole isolated three-branch item from scratch.
LongMemEval-V2 uses the separate
`evalens.router-single-session.longmem.local.config.json` with item concurrency
one because a single unchanged raw item already consumes about 6.8 GiB in the
local Salix container; its three causal branches remain concurrent.

## Salix boundary

Every Salix branch creates an independent agent group containing one Router and
one preprovisioned worker. Evalens supplies no routing prompt, routing rule,
dispatch rule, `systemPrompt`, or `routerSystemPrompt`; Salix retains its default
Router/worker behavior. Only the Router's visible conversation reply, trace,
tool calls, and token usage are evaluation targets. Worker state and token usage
are not scored.

The experiment intentionally does not use Salix session fork. A fork inside one
agent group would not establish the required branch-level isolation boundary.

LongMemEval-V2 raw trajectories are staged as immutable batches and finalized
once through the Salix actor-owned seed path. Each original trajectory remains
one complete transcript message; no trajectory is split to fit the transport
envelope.

## Codex boundary

Every Codex branch starts an independent `codex app-server` process and thread.
History is appended through `thread/inject_items`; only Compacted receives
`thread/compact/start`; the shared probe is sent with `turn/start`. This makes
the initial state controllable without sharing a parent thread or fork snapshot.

## 256k matched history window

The 256k Salix and Codex experiments are context-budgeted variants. Fresh
retains the official current episode unchanged. Before Accumulated and
Compacted execute, each experiment uses `o200k_base` to estimate the
adapter-boundary prior + current history and retains the longest chronological
suffix of complete message/tool-call groups within a fixed 240k-token seed
budget. Accumulated and Compacted share the exact same retained source groups
and digest; only Compacted receives the system-specific explicit compaction
operation. The result records the original, retained, and truncated estimates
and group counts. These variants compare the same three causal branches under
a matched fixed history window rather than measuring full-history 256k
retention.

For LongMemEval-V2, each original trajectory JSON file becomes one model-visible
history item and is injected in official haystack order. Transport calls are
made one trajectory at a time so a large request envelope does not become a
second context limit. No trajectory is selected, shortened, summarized, or
rewritten. The Codex adapter owns trajectory conversion; for these unusually
large injected histories, the persisted trajectory records each model-visible
item's role, byte length, and SHA-256 rather than duplicating hundreds of
megabytes of source JSON in every result.

## Datasets

Both datasets use `RouterSingleSessionItem` schema version 1.

- `agentlongbench-{32k,256k,1m}-raw-v1` each contains all 800 items from the
  corresponding official AgentLongBench tier. Each item attachment contains
  its byte-verified current/prior official episode JSON; the lightweight
  manifest stores their SHA-256 references. The attachment is hydrated lazily
  and original message objects remain in source order. Tool calls and tool
  results are converted only at the adapter protocol boundary.
- `longmemeval-v2-triple-branch-raw-v1` contains all 422 text-only questions
  from the official 451-question small tier. Fresh receives the official ordered
  100-trajectory haystack. Accumulated and Compacted receive the same 50
  deterministic, disjoint, same-domain prior trajectories followed by those
  same 100 current trajectories.
- `eligibility.json` inventories all 451 source questions. The remaining 29
  require a question screenshot and are excluded until the controlled
  session-injection boundary can deliver the image identically to Salix and
  Codex. The builder does not replace images with OCR or generated descriptions.

Except for the explicitly documented 256k context-budgeted variants, no branch
truncates, summarizes, rewrites, evidence-selects, or otherwise optimizes source
history for an adapter context limit.

## Scores

Evaluator v6 persists branch-qualified outcome metrics for Fresh, Accumulated,
and Compacted:

- `task_*`, `retention_*`, `pollution_*`

It also returns:

- `accumulation_loss = task_fresh - task_accumulated`
- `compaction_gain = task_compacted - task_accumulated`
- `residual_loss = task_fresh - task_compacted`

Operational observations such as delegation, worker creation, timeouts, model
errors, token usage, duration, seed counts, compaction status, and branch
isolation are run diagnostics. `runItem` retains them in its result and writes
them to the structured run logger; the evaluator does not present them as
quality scores.

AgentLongBench uses source-aligned deterministic scoring. LongMemEval-V2
semantic item types use the pinned Codex judge (`gpt-5.5`, medium effort);
deterministic item types use their corresponding deterministic matcher.

## Local commands

The two builders are self-contained source loaders. On first use they download
the official artifacts at pinned revisions into:

- `/tmp/comma-agentlongbench-official`
- `/tmp/comma-longmemeval-v2`

They verify pinned SHA-256 digests, reuse the local cache on later calls, and
perform the source-to-dataset conversion in this single-session suite. Set
`EVALENS_DATASET_DOWNLOAD=false` to require an already populated offline cache,
or override `AGENTLONGBENCH_DATA_ROOT` / `LONGMEMEVAL_DATA_ROOT`.

```sh
bun run experiments/router-single-session/build-agentlongbench-raw-dataset.ts
bun run experiments/router-single-session/build-longmemeval-v2-single-session-dataset.ts

bun run cli dataset pack agentlongbench-32k-raw-v1 \
  --config ./evalens.router-single-session.local.config.json
bun run cli dataset pack agentlongbench-256k-raw-v1 \
  --config ./evalens.router-single-session.local.config.json
bun run cli dataset pack agentlongbench-1m-raw-v1 \
  --config ./evalens.router-single-session.local.config.json
bun run cli dataset pack longmemeval-v2-triple-branch-raw-v1 \
  --config ./evalens.router-single-session.local.config.json

bun run cli run experiments/router-single-session/agentlongbench-salix.exp.ts \
  --config ./evalens.router-single-session.local.config.json \
  -- --run.tier=32k
bun run cli run experiments/router-single-session/agentlongbench-codex.exp.ts \
  --config ./evalens.router-single-session.local.config.json \
  -- --run.tier=32k

# Repeat either command with --run.tier=256k or --run.tier=1m.
bun run cli run experiments/router-single-session/longmemeval-v2-salix.exp.ts \
  --config ./evalens.router-single-session.longmem.local.config.json
bun run cli run experiments/router-single-session/longmemeval-v2-codex.exp.ts \
  --config ./evalens.router-single-session.longmem.local.config.json
```

Use `--filter <item-id>` to smoke-test a bounded selection without changing the
content-addressed dataset.

Use `rerun` to derive a complete replacement from a non-running run while
reusing its completed items:

```bash
bun run cli rerun experiments/router-single-session/agentlongbench-salix.exp.ts \
  --from-run <source-run-id> \
  --config ./evalens.router-single-session.local.config.json
```

The derived run records the source run id, copies every completed case, reruns
error or missing cases, and evaluates the complete derived result set. The
source run remains unchanged.

After a canonical local run and its evaluation are complete, publish that
immutable result set to the remote dashboard with:

```bash
bun run cli run migrate agentlongbench-256k-salix-router-single-session \
  --from-run <source-run-id> \
  --eval <source-eval-id> \
  --source-config ./evalens.router-single-session.local.config.json \
  --target-config <remote-evalens-config.json> \
  --concurrency 4
```

Repeat `--eval` to migrate more than one evaluation. Migration creates fresh
remote run and eval ids, preserves the source facts and timing, and prints the
new id mapping as JSON. It rejects running, incomplete, or item-error runs
before creating the remote run. Publish the matching content-addressed dataset
separately if the remote run must later be used as a `rerun` source.

The default run retry budget is three retries with exponential backoff. The
local long-run config raises this budget to twelve so an in-progress experiment
can survive a local Salix restart. Configuration only exposes `maxRetries`;
the initial delay, maximum delay, and multiplier are fixed internal defaults.
Only recoverable connection failures and Salix 502/503/504 responses are
retried; context-window, data-validation, and other deterministic experiment
failures are persisted without retry.
