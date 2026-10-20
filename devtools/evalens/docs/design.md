# Evalens Design

This document records the current design decisions.

## Core Boundary

An `Experiment` is the author-facing entry point. It composes a run definition
and an evaluation definition: `name`, optional `description`, `metadata.tags`,
`datasetLoader`, `runItem`, `evaluators`, `aggregator`, and optional `params`
and `adapters`.

The config file supplies `outputDir` and `concurrency`. The command supplies
the run `filter` and run and eval `params`. They do not belong in the
definition.

`runId` and `evalId` are not user-specified. After preflight, Store creation
methods generate UUIDv7 identities and expose them through the returned writer.
Read and open APIs accept existing identities.

The experiment name is its lowercase ASCII identity slug and its storage
partition. Description does not participate in identity. Each run manifest
snapshots it. Identifier, param key, tag, and item id limits are the schemas in
`packages/core/src/schemas.ts`. The framework does not trim or normalize these
identifiers.

Run and eval params are flat dictionaries. Each value is a string, finite
number, boolean, null, or a one-dimensional array of those scalars. CLI array
values use comma-separated syntax such as `--run.models=gpt-5,gpt-5-mini`.
Experiment tags are a set. Run preflight removes duplicates in first-seen order.

### CLI Configuration

All execution and query commands require `--config <path>`. `EvalensConfigSchema` is a
strict union with exactly one target:

```json
{ "concurrency": 1, "local": { "outputDir": "./runs" } }
```

```json
{
  "concurrency": 4,
  "remote": {
    "url": "https://evalens.example.com",
    "access": { "clientId": "...", "clientSecret": "..." },
    "r2": {
      "accountId": "...",
      "bucket": "evalens-results",
      "accessKeyId": "...",
      "secretAccessKey": "..."
    }
  }
}
```

Local output paths resolve relative to the config file. CLI flags and
environment variables cannot override config values. Real config files are
ignored by Git. A generated `evalens.config.schema.json` provides editor
validation.

CI decodes the complete config from `EVALENS_CONFIG_BASE64` into a mode-600
temporary file. `scripts/run-experiment-workflow.ts` does dispatch validation,
secret decoding, request preparation, and CLI invocation. Codex CI
authentication is the `adapters.codex.authJson` config value. The script writes
it to a mode-600 `CODEX_HOME/auth.json`. It removes `authJson` and the encoded
config secret before it starts Codex or the CLI.

The machine-first query surface is `list runs`, `get run <run-id>`,
`list evals`, and `get eval <eval-id>`. Successful commands write only JSON to
stdout. Lists return `{items,total,limit}`. Gets return the resource DTO. There
is no `--all`, offset-page, search, wait, watch, or cancellation surface.

Run lists filter by experiment, lifecycle status, one exact tag, run params,
and an inclusive creation-time range. Eval lists also filter by run id and eval
params. Params are inline JSON objects under `--run-params` and
`--eval-params`. Time bounds are ISO 8601 timestamps with explicit timezone
offsets.

Query failures leave stdout empty and write structured JSON to stderr. Usage
errors exit 2. Runtime, authentication, not-found, and reindexing errors exit 1
with stable `error.code` and `retryable` fields. An empty list is successful.
Local queries repair the affected index scope before they query SQLite. Remote
queries use the `remote.access` Cloudflare Access service token. `202
reindexing` is retryable.

### Datasets

Official datasets are content-addressed tar archives, not Git-tracked payloads.
`evalens dataset pack <name> --config <path>` packs the config-adjacent
`datasets/<name>/` authoring directory, excluding its `sha256/` output directory,
and writes `datasets/<name>/sha256/<sha256>.tar`. The digest is the SHA-256 of
the exact outer tar bytes. Packing does not validate the item schema.
`evalens dataset publish <name> --digest <sha256> --config <path>` uploads that
file to the same key in the configured R2 bucket. It never overwrites an
existing key.

Experiments declare a dataset name, digest, and item Zod schema through
`defineDatasetLoader`. Local configs load the tar from the config-adjacent
dataset directory. Remote configs download the same object through `remote.r2`,
verify its SHA-256, and cache it locally. R2 credentials stay inside the CLI
dataset capability. Experiment code does not get them.

The outer tar contains `dataset.json` plus optional per-item archives at
`items/<item-id>.tar`. A loaded item exposes its nested tar as runtime-only
`item.archive`. The archive does not participate in the item digest. If the
cache lock directory already exists, the CLI fails with its path. Make sure no
dataset load is running, then remove the lock directory manually.

## Execution Phases

Run and evaluation are separate phases. The run command executes and persists
every dataset item, then marks the run finished. Evaluation then loads persisted
run results from the store in bounded batches.

Run and evaluation writers are single-owner lifecycle objects. They accept item
and aggregate writes only while `running`. After `finished` or `error`, the
source facts are immutable and late writes are rejected. A completed run or
evaluation is never changed in place.

Run preflight parses run and eval params, loads and validates the dataset, and
applies the filter and item-id checks. Only then does Store create the run with
the post-filter `targetItemCount`. A preflight failure leaves no run manifest.
After the manifest exists, an unhandled framework or storage failure marks the
run `error`. A `runItem` exception is an item error and does not stop the run
from finishing.

Evaluation and re-evaluation use the same phase. They do not accept an item
filter: an eval covers every committed item in its finished run. Re-evaluation
creates a new eval id, resolves the dataset recorded by the run manifest, and
reads persisted run results without calling `runItem`. It rejects a run that is
`running` or `error`.

`evalens rerun <experiment> --from-run <runId>` derives a new immutable run
from a non-running source run. The source run stays unchanged. The dataset name,
full digest, selected item set, parsed run params, and run adapter identities
must match the source manifest. The derived manifest records `sourceRunId`.
Completed source items are copied with their result, trajectories, artifacts,
and timing. Error and missing items run again. The derived run gets a new
evaluation over all items.

`evalens run migrate <experiment> --from-run <runId> --source-config <path>
--target-config <path>` publishes completed run data to a remote target. The
target config must be remote. `--eval <evalId>` is repeatable and copies the
selected finished evaluations. Without it, only the run is migrated.
`--concurrency <n>` overrides the target config concurrency.

Migration is a Store-to-Store copy, not an R2 key copy. Before it creates the
destination run, it requires a finished source manifest, a commit marker for
every selected item with no item errors, matching params and selection digests,
and complete evaluator results plus aggregate scores for each selected eval. It
writes everything through the destination Store writers under new run and eval
ids. The destination `sourceRunId` records the source. No existing destination
identity is overwritten. Transient write failures are retried.

Migration does not publish the dataset tar. A later remote `rerun` needs the
dataset published separately with `evalens dataset publish`.

Run and evaluator timing covers only the author-provided `runItem` or
`evaluate` function. Skipped evaluator results have no timing.

## Run Result Semantics

`runItem` implements only the successful path. It returns a status-free
`RunOutput<T>` with `result`, required `trajectories` (use `[]` when there are
none), and optional artifacts. Agent-level task outcomes belong in `result`.

The runner owns the persisted `RunResult` envelope. A normal return becomes
`completed`. A thrown error becomes an `error` result with the error string.

## Run Dataset Filtering

The run filter is deduplicated. An empty filter is invalid. Every filter id must
exist in the dataset, or the run fails before any item executes. Without a
filter, an empty dataset is invalid.

`datasetItem.id` is the item identity. Item ids must be unique and match
`^[a-z0-9][a-z0-9._-]*$` within the `ItemId` byte limit. Dataset items are
JSON-safe objects. `expected` is required but may be `null`.

The CLI parses run params before it loads the dataset and passes them to
`datasetLoader`. An experiment can therefore select a dataset version from a run
param. The run manifest records both. A rerun recovers the source run params
first and uses them to load the dataset.

The run manifest records the dataset name, `datasetDigest` (SHA-256 of the
source tar), `datasetSelectionDigest` (source digest plus selected item-id set),
and `selectedItemIds` in dataset order. Each executed item persists only an
`item.json` reference with `itemId` and `itemDigest`. The item digest covers the
canonical item JSON without its archive.

Automatic item comparison requires the same item id and item digest. Aggregate
comparison requires the same dataset name and selection digest.

Evaluation receives the selected dataset explicitly. Re-evaluation resolves it
again through the current experiment. Dataset name, digests, item ids, and
per-item digests must match the run. A missing or changed dataset fails the
evaluation.

## Trajectories

`Trajectory` is a process log: an id plus ordered steps. It has no top-level
`final` field. Final answers belong in `RunOutput.result`. Record usage on the
step that produced it.

## Artifacts

The runner saves what `runItem` returns. Read artifacts from an explicit
source: the returned `Archive`, a structured artifact list, or file paths the
runner wrote. There is no artifact index or `readArtifact` helper.

## Evaluation

Evaluators run only for completed run results. They receive the item, the
completed `RunOutput`, and the eval context. They return only `score` and an
optional explanation. An experiment defines at least one evaluator.

The framework owns the persisted `EvalResult` envelope. A valid return becomes
`completed`. A thrown or invalid return becomes `error`. A run error produces one
`skipped` result per evaluator without calling evaluator code. Evaluator errors
and skips do not fail the eval.

After per-item results are persisted, the aggregator receives a map keyed by
every evaluator name. Each value is an array of completed outputs with `itemId`,
score, and optional explanation. Error and skipped results are omitted, so an
evaluator with no completed outputs has an empty array. Coverage accounting is
not part of the aggregator input.

Persisted aggregator scores are the only source for evaluation-level totals,
trends, and comparison charts. The dashboard does not compute them from
per-item scores. If the aggregator omits a score key, no evaluation-level chart
appears for it.

Evaluator and aggregator versions are author-supplied semantic identifiers, not
necessarily SemVer. A change to evaluator code, prompt, rubric, or thresholds
requires a new version. A change to eval params such as the judge model does
not. Automatic item-score comparison requires the same evaluator name, version,
and score key. Aggregate comparison requires the same aggregator version and
aggregate score key.

The eval manifest snapshots every evaluator name and version. An aggregator
exception or invalid aggregate output sets the eval manifest to `error` with the
error string, then rethrows.

Every completed evaluator score map is non-empty. The aggregate map may be
empty. Every score value is a finite number. The metadata index stores a
bounded summary of each error or explanation. Complete result objects stay in
object storage.

## Output Format

The minimum output shape is:

- run-level `manifest.json`
- per-item `item.json` containing `itemId` and `itemDigest`
- per-item `run_result.json`
- per-item `trajectories.json` (an empty array when no trajectories were produced)
- optional per-item artifact archive
- per-item `run.log.jsonl`
- per-eval `manifest.json`
- per-item `eval_results.json`
- per-item `eval.log.jsonl`
- top-level `aggregated_eval_results.json`

The runner writes only through Store-scoped writers. It does not write result
files or build storage keys directly.

Run and eval loggers are scoped per item. The item log is flushed before the
commit marker is written. `item.json` is the run item commit marker, and
`eval_results.json` is the eval item commit marker. Evaluation and reindex
enumerate committed items through the store.

Manifests are small lifecycle records. They hold no per-item state, score
summaries, artifact indexes, or output paths.

Run manifests use `formatVersion: 2`. Eval manifests use `formatVersion: 1`.
Readers accept only the current format.

There is no separate publish step for normal results. The `--config` target
decides where results go. Local execution writes files. Remote execution writes
facts directly to R2 and calls the protected metadata API to update D1.

## Persistence And Query Architecture

Experiments always run in a Bun process (local CLI, CI, or an agent runtime),
never inside a Cloudflare Worker. Local and remote targets share the Store,
reader, and writer contracts. Local uses filesystem and SQLite adapters. Remote
uses an S3 object namespace and a Treaty metadata writer.

### Store Composition And Scopes

```text
createRun()          -> RunWriter
openRun()            -> RunReader
createEvaluation()   -> EvalWriter
RunReader.openEval() -> EvalReader
```

`RunWriter` and `EvalWriter` own new lifecycle manifests. `finish()` marks the
phase finished. Async disposal marks it `error` only when it is still running.
Readers never mutate state. Re-evaluation opens a `RunReader` and creates a new
`EvalWriter`, so it cannot change the original run. QueryService depends on the
read-only `ResultReader`, never on Store.

`MetadataWriter` is SQLite locally and D1 in the Cloudflare service. An
unindexed local configuration uses `NoopMetadataWriter`. Object writes are
required. Metadata failures after an object commit produce reindex markers.
Remote Bun processes use bucket-scoped R2 credentials and a Cloudflare Access
service token.

### Object Keys

The canonical layout is:

```text
experiments/<experimentName>/runs/<runId>/manifest.json
experiments/<experimentName>/runs/<runId>/items/<itemId>/...
experiments/<experimentName>/runs/<runId>/evals/<evalId>/...
```

The validated item id is used directly as the local directory and R2 key
component, with no prefix, encoding, or fallback lookup. The key layout is a
fixed persisted contract shared by Store, dataset packing, readers, and
reindex.

### Commit And Index Ordering

A run item writes artifacts, trajectories, the run result, and its disposed log
before it writes `item.json` last. An eval item disposes its log before it
writes `eval_results.json` last. A remote logger writes JSONL to a temporary
file and uploads it to R2 on disposal. A logger upload failure prevents the
item commit marker.

One writer owns a run or eval and schedules each item once. Store does not check
for existing items. Rerun copies only committed source items. Uncommitted
partial source objects are not inherited.

After each item commit, the persistence owner sends one complete index DTO to
`MetadataWriter`. Live commits and reindex use the same DTOs and writer.

R2 is the source of truth. R2 and D1 have no shared transaction. If D1
projection fails after the R2 commit marker exists, the CLI writes the narrowest
run or eval reindex marker to R2 and keeps the result. If the marker write also
fails, the request fails with an aggregate error.

### Typed Remote Metadata And Access

`@evalens/server` owns the remote ingestion and query Elysia applications and
exports their API types. `@evalens/cli` owns the Treaty clients, Cloudflare
Access headers, and request mapping. `@evalens/store/local` owns local SQLite
query composition and scoped index repair. The CLI and the read-only local
server both use it. `@evalens/core` never depends on transport or deployment
packages:

```text
store -> core
server -> core + store
cli -> core + store + server
dashboard -> server (query App type)
```

### Built-in adapter configuration

`@evalens/adapters` exports the built-in Codex, Salix, and Slack adapters. Their
connection, credential, executable, and safety settings come from the optional
top-level `adapters` object in `evalens.config.json`. Model, prompt, template,
and other result-affecting choices stay in run/eval params or per-call adapter
inputs. Waits are bounded by per-call or adapter timeout options.

Experiments declare adapters per phase:

```ts
defineExperiment({
  adapters: { run: ["salix"], eval: ["codex"] },
  runItem(item, context) {
    return runWithSalix(item, context.adapterConfig.salix);
  },
  // ...
});
```

CLI commands require each declared phase config before they load the dataset or
create persisted state. Adapter config is never persisted. Manifests record only
the adapter name and implementation version.

The remote CLI authenticates to Cloudflare Access with a service-token client
id and secret. Browser users authenticate through the configured identity
provider. Metadata writes require the service policy. Queries and artifact/log
downloads require an authenticated browser policy. R2 S3 credentials are
available only to the trusted CLI/CI process. The Worker never proxies R2
writes. It streams artifact and log downloads from its R2 binding for the
dashboard.

Remote artifacts have no Evalens-specific size limit. The CLI writes the archive
directly to R2.

Result objects and manifests are the source of truth. SQLite and D1 are
rebuildable query indexes. Local SQLite lives at
`<outputDir>/.evalens/index.sqlite`. One Cloudflare deployment uses one D1
database and one R2 bucket.

### Metadata Schema

The Drizzle schema in `packages/store/src/metadata/schema.ts` is the only DDL
source. `drizzle-kit generate` writes the SQLite migrations. There is no
experiments table. The schema stores no redundant completed, skipped, error,
coverage, or score statistics. Query layers derive them. The run target count is
a preflight fact that cannot be rebuilt after interruption, so manifests require
`targetItemCount`. Reindex of an older manifest fails visibly.

### Dirty Index Markers And Reindex

When a fact object commits but its metadata update fails, Store writes a
uniquely keyed `ReindexMarker` in object storage with scope `experiment`, `run`,
or `eval`. A run-item failure marks the run dirty. An eval-item or aggregate
failure marks the eval dirty. Missing or invalid experiment index state uses
experiment scope. If both the metadata update and the marker write fail, Store
throws.

A marker covers its scope and all descendants. A query is unavailable when its
scope or an ancestor has a marker. Reindex does not run on a `running` run or
eval.

SQLite and D1 use the same repair fence. `beginReindex` invalidates every
overlapping repair lease and installs a fresh lease at revision zero. Each
repair mutation checks that lease and revision in the same transaction or batch.
Each normal metadata write advances every overlapping active fence.
`finishReindex` publishes only if the lease and revision zero still hold.
Otherwise repair replays from a fresh object-storage plan. After publish, repair
deletes only the marker keys in its plan. A marker created during repair
survives for the next repair.

Normal queries never scan object storage. A missing index or relevant marker
must be repaired before results are returned. Local CLI queries reindex the
affected scope synchronously. Remote query routes schedule a background
reindex and return `202 reindexing`. Clients poll and retry.

The `index_metadata` singleton records global index state: missing, schema
compatibility, and global rebuild in progress. These states block normal
queries. Scope markers remain the source of per-scope dirtiness.

Filtered queries check only the requested scopes. A dirty marker in an unrelated
experiment does not block them. Unfiltered global lists need a clean global
marker set.

Before an eval's first manifest write, Store writes the immutable
`control/evaluation-scopes/<evalId>.json` locator. Creation aborts if that write
fails. If an eval metadata row is missing, the guard reads only that locator and
repairs the eval scope.

### Metadata And Query Boundaries

Runtime adapters stay thin:

- local: `bun:sqlite`, local object storage, and the Bun Elysia adapter
- Cloudflare: D1, R2 bindings, and the Elysia Cloudflare Worker adapter

Single-resource queries are metadata-only. `getRun(runId)` returns one
`RunSummary` without items or evaluation history. `getEvaluation(evalId)`
returns one `EvalCatalogEntry` with its run identity. Child collections use
bounded paged queries: `listEvaluations` and `listRunItems`. HTTP follows the
same split with `GET /runs/:runId`, `GET /evaluations/:evalId`, and paginated
`GET /runs/:runId/items`. Detail routes never hide a full child scan.

The runner gets bucket-scoped R2 credentials but never direct D1 access.
Dataset payloads, run results, trajectories, artifacts, complete
explanations and errors, and logs stay in object storage.

Comparison accepts only evaluations with a compatible identity. The UI disables
other candidates with the reason. Compatibility uses:

- dataset identity: `datasetName` plus `datasetSelectionDigest`
- item metric identity: evaluator name, evaluator version, and score key
- aggregate metric identity: aggregator version plus aggregate score key

Compatibility comes from the eval-level `eval_score_identities` projection, not
from the loaded item page. It is metric-schema compatibility. It does not
promise a value for every shared item. Score keys are a fixed per-evaluator
shape, not a dynamic namespace such as item ids.

## Progress And Events

Persisted `running` means only that no terminal lifecycle fact exists. It does
not prove the process is alive. There are no heartbeats. `evalens run` does not
emit an early run id or event stream. Callers use a supplied id, the newest
filtered run, or the local run directory. See [todo.md](../todo.md).
