# Isolated triple-branch single-session evaluation

Each target/source family is one Evalens experiment:

- `agentlongbench-salix.exp.ts` (`tier=32k|256k|1m`)
- `agentlongbench-codex.exp.ts` (`tier=32k|256k|1m`)
- `longmemeval-v2-salix.exp.ts`
- `longmemeval-v2-codex.exp.ts`

The AgentLongBench run parameter `tier` selects the content-addressed dataset
before the run is created. The run manifest records the dataset name, digest,
and tier. A rerun recovers the tier from its source manifest.

One dataset item produces one run item with three causal branches:

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

The three branches run concurrently. Item retries wait for every branch to
finish cleanup, then retry the whole three-branch item. Run AgentLongBench with
`evalens.router-single-session.local.config.json`. Run LongMemEval-V2 with
`evalens.router-single-session.longmem.local.config.json` at item concurrency
`1`, because one raw item already uses several GiB in the local Salix container.

## Salix boundary

Every Salix branch creates its own agent group with one Router and one
preprovisioned worker. Evalens supplies no routing prompt, routing rule,
dispatch rule, `systemPrompt`, or `routerSystemPrompt`. Only the Router's
visible reply, trace, tool calls, and token usage are scored. Worker state and
token usage are not scored.

Do not use Salix session fork. A fork inside one agent group does not give
branch-level isolation.

LongMemEval-V2 raw trajectories are staged as immutable batches and finalized
once through the Salix actor-owned seed path. Each original trajectory stays one
complete transcript message.

## Codex boundary

Every Codex branch starts its own `codex app-server` process and thread.
History is appended through `thread/inject_items`. Only Compacted receives
`thread/compact/start`. The shared probe is sent with `turn/start`.

## 256k matched history window

The 256k Salix and Codex experiments are context-budgeted variants. Fresh keeps
the official current episode unchanged. Accumulated and Compacted keep the
longest chronological suffix of complete message/tool-call groups that fits the
fixed seed token budget (`historyTokenBudget` in the `.exp.ts` files, `o200k_base`
estimate). Both share the same retained groups and digest. The result records
the original, retained, and truncated estimates and group counts. These variants
compare the three branches under a matched history window. They do not measure
full-history 256k retention.

For LongMemEval-V2, each original trajectory JSON file becomes one model-visible
history item in official haystack order. Transport sends one trajectory per
call. No trajectory is selected, shortened, summarized, or rewritten. The
persisted Codex trajectory records each injected item's role, byte length, and
SHA-256 instead of the source JSON.

## Datasets

Both datasets use `RouterSingleSessionItem` schema version 1.

- `agentlongbench-{32k,256k,1m}-raw-v1` each contains all 800 items from the
  official AgentLongBench tier. Each item attachment holds its byte-verified
  current/prior official episode JSON. Original message objects stay in source
  order. Tool calls and results are converted only at the adapter boundary.
- `longmemeval-v2-triple-branch-raw-v1` contains all 422 text-only questions
  from the official 451-question small tier. Fresh receives the official ordered
  100-trajectory haystack. Accumulated and Compacted receive the same 50
  deterministic, disjoint, same-domain prior trajectories followed by those
  100 current trajectories.
- `eligibility.json` lists all 451 source questions. The other 29 need a
  question screenshot and are excluded until session injection can deliver the
  image identically to Salix and Codex. The builder does not replace images with
  OCR or generated descriptions.

Except for the 256k context-budgeted variants, no branch truncates, summarizes,
rewrites, evidence-selects, or otherwise optimizes source history.

## Scores

The evaluator persists branch-qualified outcome metrics for Fresh, Accumulated,
and Compacted:

- `task_*`, `retention_*`, `pollution_*`

It also returns:

- `accumulation_loss = task_fresh - task_accumulated`
- `compaction_gain = task_compacted - task_accumulated`
- `residual_loss = task_fresh - task_compacted`

Delegation, worker creation, timeouts, model errors, token usage, duration, seed
counts, compaction status, and branch isolation are run diagnostics in the
result and run log. They are not quality scores.

AgentLongBench uses source-aligned deterministic scoring. LongMemEval-V2
semantic item types use the pinned Codex judge. Deterministic item types use
their deterministic matcher.

## Local commands

On first use, the builders download the official artifacts at pinned revisions
into:

- `/tmp/comma-agentlongbench-official`
- `/tmp/comma-longmemeval-v2`

They verify pinned SHA-256 digests and reuse the cache later. Set
`EVALENS_DATASET_DOWNLOAD=false` to require an existing offline cache, or set
`AGENTLONGBENCH_DATA_ROOT` / `LONGMEMEVAL_DATA_ROOT`.

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

Use `--filter <item-id>` to smoke-test a bounded selection.

Use `rerun` to build a complete replacement from a non-running run and reuse its
completed items:

```bash
bun run cli rerun experiments/router-single-session/agentlongbench-salix.exp.ts \
  --from-run <source-run-id> \
  --config ./evalens.router-single-session.local.config.json
```

After a local run and its evaluation are complete, publish them to the remote
dashboard:

```bash
bun run cli run migrate agentlongbench-256k-salix-router-single-session \
  --from-run <source-run-id> \
  --eval <source-eval-id> \
  --source-config ./evalens.router-single-session.local.config.json \
  --target-config <remote-evalens-config.json> \
  --concurrency 4
```

Repeat `--eval` to migrate more evaluations. The command prints the new id
mapping as JSON. Publish the matching dataset separately if the remote run must
later be a `rerun` source. Rerun and migration rules are in
[the Evalens design](../../docs/design.md#execution-phases).

Only recoverable connection failures and Salix 502/503/504 responses are
retried. Set `retry.maxRetries` in the local long-run config high enough
(for example `12`) to survive a local Salix restart.
