# TeamBench protocols

This directory owns TeamBench dataset materialization, experiment orchestration,
local grading, and protocol documentation. Salix and Codex adapters stay
experiment-independent.

## Protocols

### `paper` (not implemented)

The paper protocol would drive the Solo, Plan + Execute, and Plan + Execute +
Verify conditions with the paper's role-specific information and tool
restrictions.

### `native`

Native measures each system's own collaboration mechanism:

1. Evalens materializes an immutable task and pre-creates Planner, Executor, and
   Verifier roles.
2. Evalens starts only Planner/Main.
3. Salix or Codex owns delegation, messages, execution, file handoff, waiting,
   and termination.
4. Evalens freezes trajectories and files after the team settles, then runs the
   official grader locally.

Evalens never performs a worker handoff, sends a mid-run worker message, repairs
an attestation, or stops a worker. Salix uses a read-only `group_quiescent`
barrier: Router session, tool trace, Worker sessions, and Workflows must stay
settled for a quiet window, then pass a final Worker consistency poll before
artifacts are frozen. Remaining activity is a protocol violation.

Role prompts are model-neutral. `promptProfile` records either the full tool
shape guidance or the tool-semantic-only ablation. Both share the same role and
task core. Native reuses TeamBench tasks and graders but does not claim to
reproduce the paper's Full Team orchestration or permissions.

## Runtime and isolation

| Concern     | Salix                                   | Codex                                         |
| ----------- | --------------------------------------- | --------------------------------------------- |
| Topology    | Router plus two Worker agents           | Main plus `executor` and `verifier` subagents |
| Files       | Separate VFS per agent                  | Shared local workspace                        |
| Commands    | Group-scoped local Docker connector     | Local shell plus Docker runtime helper        |
| Handoff     | Native VFS copy or Workflow attachments | Shared filesystem                             |
| Observation | Router, Worker sessions, traces, VFS    | Root and descendant thread trajectories       |
| Cleanup     | Container/environment, then agent-group | App-server thread and temporary directory     |

The Verifier is part of the tested team, not the grader. It may run commands and
must create `submission/attestation.json`. Only the post-run evaluator sees
grader sources and expected outputs.

Salix VFS is authoritative but not executable. Evalens creates one local
`salix-connect` container per group under alias `teambench-runtime`. Workers copy
changed VFS files into its `/workspace` before commands. Evalens does not do
those copies.

Codex uses a fresh directory with `sandbox=danger-full-access` and
`approvalPolicy=never` so it can run the same offline toolchain through
`tools/run-in-runtime`. This is not Salix-style isolation. No grader data is
staged in the Codex directory.

Build the shared Worker/grader image first:

```sh
cd devtools/evalens
bun run experiments/teambench/build-salix-runtime.ts
```

The Worker container uses Docker's bridge network only to reach local Salix. The
grader container has no network.

## Dataset and hidden material

Each content-addressed item separates model-visible and evaluator-only files:

```text
agent/{spec.md,brief.md,workspace/**,task/**}
grader/source/tasks/<task-id>/**
grader/source/harness/grader_helpers.sh
grader/reports/expected.json
materialization.json
```

The builder uses the official GitHub repository at the revision pinned in
`contracts.ts`, leaderboard-90, seed 0. The public repository has no `v1.0` tag,
so this is not claimed to be the paper submission snapshot.
`GH120_redis-py_3863` stays in the set although it is marked
`under_re_curation`. Paired analyses must retain or exclude it consistently.

`grade.sh`, expected values, helpers, and hidden assets never enter an
agent-visible filesystem.

Create an ignored mode-600 config from `evalens.config.example.json`, then build
and pack the dataset:

```sh
cd devtools/evalens
bun run experiments/teambench/build-dataset.ts
bun run cli dataset pack teambench-native-leaderboard90-seed0-v1 \
  --config ./evalens.local.config.json
```

The loader pins the dataset digest in `dataset.ts`. Run all targets with the
same digest, params, and repeated `--filter` selection:

```sh
bun run cli run experiments/teambench/salix-native.exp.ts \
  --config ./evalens.local.config.json
bun run cli run experiments/teambench/codex-native.exp.ts \
  --config ./evalens.local.config.json
```

Set `TEAMBENCH_SOURCE_ROOT` to reuse the pinned checkout or
`EVALENS_DATASET_DOWNLOAD=false` to reject a missing checkout.

## Parameters and outputs

Defaults are in `contracts.ts`. Explicit values, prompt profile, runtime image,
connector settings, and timeouts are persisted in the run manifest. Use the same
model and reasoning values for paired targets. Salix's pre-provisioned tenant
template must match them. Evalens does not access administrator/template APIs.
Reported trajectory models are validated against the request.

Each run emits:

- `result`: topology, roles, params, answer, usage, and completion state.
- `trajectories`: Planner/Main and every discovered Worker/thread.
- `artifacts`: Executor workspace and Verifier submission.

The evaluator mounts frozen artifacts and private grading material into a fresh,
network-disabled container and runs:

```sh
bash grade.sh WORKSPACE REPORTS SUBMISSION TASK_DIR [EXPECTED_JSON]
```

Scores include raw and attestation-promoted pass, partial score, attestation and
Verifier verdict, false accept/reject, delegation/topology/settlement, and
protocol violation count. Promotion applies only when every remaining official
failure is attestation-related. Raw grader output stays observable.
