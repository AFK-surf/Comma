# Evalens Design

This document records the current design decisions so future changes do not
accidentally reintroduce old Evalens assumptions.

## Core Boundary

v2 is a breaking redesign. It does not need to preserve the original Evalens
result package format, dashboard reader contract, module loading API, or CLI
override behavior while the new shape is still being developed.

An `Experiment` is the author-facing entry point. It composes a run definition
and an evaluation definition:

- `name`
- optional human-readable `description`
- `metadata.tags`
- `datasetLoader`
- `runItem`
- `evaluators`
- `aggregator`

Run-time choices belong in command options, not in the definition:

- `outputDir`
- run `filter`
- run and eval `params`
- `concurrency`

`runId` and `evalId` are not user-specified. After preflight, Store creation
methods generate UUIDv7 identities and expose them through the returned writer.
Commands never construct or pass identities into create APIs; read/open APIs
accept existing identities.

The experiment name is its lowercase ASCII identity slug. It is non-empty, at
most 128 characters, starts with an ASCII letter or digit, and otherwise uses
only letters, digits, `.`, `_`, or `-`; `.` and `..` are reserved. Description
is human-readable metadata, does not participate in identity, and is snapshotted
into each run manifest.

Evaluator names and versions, aggregator versions, score keys, and tags are
non-empty and at most 128 bytes when UTF-8 encoded. Run and eval param keys are
non-empty and at most 256 UTF-8 bytes. These identifiers are case-sensitive and
the framework does not trim or otherwise normalize them. The experiment name
remains the separately constrained lowercase slug described above.
Run and eval params are flat dictionaries. Each value is a string, finite
number, boolean, null, or a one-dimensional array of those scalar values;
objects and nested arrays are rejected by both the TypeScript contract and the
persisted runtime schema. CLI array values use comma-separated syntax such as
`--run.models=gpt-5,gpt-5-mini`.
Experiment tags are treated as a set: run preflight removes duplicates in
first-seen order, and the run manifest snapshots only those deduplicated tags.

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

Concurrency defaults to one. Local output paths resolve relative to the config
file, not the caller's working directory. Config values cannot be overridden by
CLI flags or environment variables. Experiment path, run id, filter, and the
namespaced run/eval params remain invocation inputs. Real config files are
ignored; CI decodes the complete config from `EVALENS_CONFIG_BASE64` into a
mode-600 temporary file. The checked-in workflow delegates dispatch validation,
secret decoding, request preparation, and CLI invocation to the Bun/TypeScript
entrypoint in `scripts/run-experiment-workflow.ts`; the workflow YAML only sets
up its runtime and passes inputs. Codex CI authentication is stored as the
structured `adapters.codex.authJson` value in that config. The script
materializes it as a mode-600 `CODEX_HOME/auth.json`, removes `authJson` and the
encoded config secret before invoking Codex or the CLI, and preserves only the
sanitized config for the run. A generated `evalens.config.schema.json` provides
editor validation.

The machine-first query surface is `list runs`, `get run <run-id>`, `list
evals`, and `get eval <eval-id>`. Successful commands write only JSON to
stdout. Lists return `{items,total,limit}`; `limit` defaults to 20, is restricted
to 1..100, and maps to one bounded query page. Gets return the resource DTO
directly. There is no `--all`, offset-page, search, wait, watch, or cancellation
surface in the initial version.

Run lists filter by experiment, lifecycle status, one exact tag, run params,
and an inclusive creation-time range. Eval lists additionally filter by run id
and eval params. Params are inline JSON objects under `--run-params` and
`--eval-params`; there is no ambiguous `--params` alias. Time bounds must be
ISO 8601 timestamps with explicit timezone offsets, and the lower bound may not
exceed the upper bound.

Query failures leave stdout empty and write structured JSON to stderr. Usage
errors exit 2. Runtime, authentication, not-found, and reindexing errors exit 1
and are distinguished by stable `error.code` and `retryable` fields. An empty
list is successful. Local queries call SQLite QueryService directly after
synchronous scoped repair. Remote queries reuse the `remote.access` Cloudflare
Access service token against the typed query API; `202 reindexing` is retryable.

Official datasets are content-addressed tar archives rather than Git-tracked
payloads. `evalens dataset pack <name> --config <path>` packs the config-adjacent
`datasets/<name>/` authoring directory, excluding its `sha256/` output directory,
and writes `datasets/<name>/sha256/<sha256>.tar`. The digest is computed from the
exact outer tar bytes. Packing does not import an experiment or validate its item
schema. `evalens dataset publish <name> --digest <sha256> --config <path>` uploads
that exact file to `datasets/<name>/sha256/<sha256>.tar` in the configured R2
bucket and never overwrites an existing key.

Experiments declare a dataset name, digest, and item Zod schema through
`defineDatasetLoader`. Local configs load the tar from the config-adjacent
dataset directory. Remote configs reuse `remote.r2`, download the same object,
verify its SHA-256, and cache it in that local directory. R2 credentials remain
inside the CLI dataset capability and are not exposed to experiment code.

## Execution Phases

Run and evaluation are separate phases. The run command first executes and
persists every dataset item, then marks the run finished. Evaluation starts
afterward and loads persisted run results from the store in bounded concurrent
batches. Run results must not all remain resident in memory.

Run and evaluation writers are single-owner lifecycle objects. Item and
aggregate writes are accepted only while their writer is `running`; after a
writer reaches `finished` or `error`, those source facts are immutable and late
writes are rejected. Scoped reindex relies on that lifecycle boundary and does
not support mutating a completed run or evaluation in place.

Run preflight parses both run and eval params, loads and schema-validates the
dataset, and completes
the empty-dataset, filter, item-id, JSON/digest, and dataset-digest validations.
Only after every preflight step succeeds does the command ask Store to create
the run. Preflight passes the exact post-filter item count as the required
positive `targetItemCount`; Store then generates `runId` and writes the
running manifest. A
preflight failure therefore leaves no
error run or running manifest. After the manifest exists, an unhandled framework
or storage failure marks the run lifecycle error. A caught `runItem` exception
remains an item error and does not prevent a fully traversed run from finishing.

The same evaluation phase is used for initial evaluation and re-evaluation.
Evaluation and re-evaluation do not accept an item filter: an eval covers every
committed item in its finished run. Re-evaluation creates a new eval id,
resolves the dataset version recorded by the run manifest through the
experiment's dataset loader, and reads the persisted run results without
invoking `runItem` again. It rejects a run whose lifecycle status is still
running or is error.

`evalens rerun <experiment> --from-run <runId>` derives a new immutable run
from an existing non-running run. The source run remains unchanged. Preflight
loads the current dataset and requires the dataset name, full dataset digest,
selected item set, parsed run params, and run adapter identities to match the
source manifest. Run manifest v2 persists `selectedItemIds`, and the derived
manifest records both the same selection and `sourceRunId`.

Every source item with a `completed` run result is committed into the derived
run with its immutable item reference, result, trajectories, artifacts, and
execution timing. The derived item log records that inheritance occurred.
Source items with an `error` result, plus selected items with no source commit
marker, execute through the normal runner. The derived run therefore persists
the complete source selection and receives a new evaluation over both inherited
and newly executed items. A running source is rejected to avoid racing its
writer.

`evalens run migrate <experiment> --from-run <runId> --source-config <path>
--target-config <path>` is the explicit local-to-remote publication path for
completed run data. The source can use either Store configuration, but the
target configuration must be remote. `--eval <evalId>` is repeatable and copies
only the selected finished evaluations; omitting it migrates the run without an
evaluation. Item copies use the target config's bounded concurrency by default;
`--concurrency <n>` can override it for an explicit migration operation.

Migration is a semantic Store-to-Store copy, not an R2 key copy. Before creating
the destination run it requires a finished source manifest, a complete set of
successful item commit markers, matching params and selection digests, and, for
each selected evaluation, complete evaluator results plus aggregate scores.
The command then streams each item reference, run result, trajectory, artifact,
execution timing, evaluation result, and evaluator timing through the
destination Store writers. This rebuilds both object storage and metadata
indexes under newly generated run and eval ids. The destination run's
`sourceRunId` records the immediate source; no existing destination identity is
overwritten. Transient destination write failures use a bounded internal
exponential-backoff retry so publication can tolerate short R2 or network
interruptions without exposing another migration setting. Large remote object
PUTs use abortable presigned requests; small object writes retain the native S3
path. Both have a 60-second caller deadline so a stalled transport becomes a
retryable failure instead of blocking the migration indefinitely.

The command does not reconstruct or publish the original content-addressed
dataset tar. A migrated run is sufficient for dashboard inspection and copied
evaluation data, but a later remote `rerun` still requires the exact dataset
archive to have been published separately with `evalens dataset publish`.

Run and evaluator timing measures only execution of the author-provided
`runItem` or `evaluate` function. It uses `Date` for `startedAt` and
`finishedAt`, with `durationMs` clamped to the non-negative wall-clock
difference. Timing excludes logger disposal, object writes, metadata writes,
and commit-marker writes. Completed and error envelopes persist timing; skipped
evaluator results do not because no evaluator function ran.

`experiment.ts` only defines the author-facing composed contract. `run.ts` owns
run types and execution, `evaluation.ts` owns evaluation types and execution,
and the concrete files under `packages/cli/src/commands/` compose those phases
into user-facing commands. The CLI only parses arguments, loads an experiment,
and invokes commands.

## Run Result Semantics

`runItem` implements only the successful path. It returns a status-free
`RunOutput<T>` containing `result`, required trajectories, and optional artifacts.
Experiments without trajectory data return `trajectories: []`. Agent-level task
outcomes belong in the typed `result` payload.

The runner owns the persisted `RunResult` envelope. A normal return becomes a
`completed` result containing the `RunOutput` fields. If `runItem` throws, the
runner persists an `error` result with the error string. Item errors do not make
a fully traversed run phase fail; the run manifest still finishes normally.

## Run Dataset Filtering

When a run filter is supplied, the framework deduplicates its item ids before
selection. An explicitly empty filter is invalid. Every deduplicated filter id
must exist in the loaded dataset; any missing id fails the run before an item
executes rather than being silently ignored. Without a filter, an empty loaded
dataset is also invalid. In every case, a run that successfully enters item
execution has at least one selected item.

`datasetItem.id` is the item identity. `RunContext` does not need duplicate
`itemId` or `runItemId` fields as long as each dataset item is run at most once
per experiment run.

After filtering and before any item executes, the framework validates that
every item id is unique within the executed dataset and matches
`^[a-z0-9][a-z0-9._-]*$`, with a maximum of 240 UTF-8 bytes. This portable
lowercase ASCII logical domain rejects leading dots, Unicode normalization and
case-folding aliases, separators, and control characters. It leaves room for
the `.tar` suffix under the 255-byte filesystem component limit. Dataset items
are JSON-safe objects. `expected` is required but may be `null`;
author-specific item schemas remain the dataset loader's responsibility.
The CLI validates and normalizes run parameters before loading the dataset and
passes those parsed parameters to `datasetLoader`. An experiment may therefore
select one of several versioned dataset references from a run parameter; the
selected dataset identity and the same parsed parameters are both persisted in
the run manifest. A derived rerun recovers the source run parameters first and
uses them to load the dataset before validating its name and digest.

The outer dataset tar contains `dataset.json` plus optional per-item archives at
`items/<item-id>.tar`. A cold load extracts the complete outer dataset archive
to its content-addressed local cache. A loaded item then exposes the nested tar
as optional runtime-only `item.archive`; reading that nested archive is deferred
until `runItem` calls one of its access methods. The archive does not
participate in the item digest. If the
cache lock directory already exists, the CLI fails with its path; after
confirming that no dataset load is running, the user may remove the lock
directory manually.

The run manifest records the dataset name, the SHA-256 of the complete source
tar as `datasetDigest`, and `datasetSelectionDigest`, which identifies the source
digest plus the selected item-id set. Run manifest v2 also persists
`selectedItemIds` so evaluation, rerun, and migration use the exact selection
without reconstructing it from committed results. Each executed item persists
only an `item.json` reference containing `itemId` and `itemDigest`; dataset item
JSON and optional archives remain owned by the referenced dataset version. Item
ordering is not part of the per-item result contract; the manifest selection
preserves dataset order for deterministic scheduling.

Each committed item has a stable digest of the complete canonical JSON item,
including extension fields but excluding its runtime archive. Automatic item
comparison requires both item id and item digest to match. Aggregate comparison
requires the dataset name and dataset selection digest to match; runs with
different selections may still compare their matching item intersection when a
future explicit comparison mode permits it.

Evaluation receives the selected dataset explicitly. Initial evaluation reuses
the dataset prepared for the run; re-evaluation resolves it again through the
current experiment definition. The resolved dataset name, full digest,
selection digest, item ids, and per-item digests must match the run references.
A missing or changed referenced dataset fails explicitly instead of silently
evaluating different data.

## Trajectories

`Trajectory` is a process log: an id plus ordered steps. It should not require a
top-level `final` field.

Agent final answers or task outcomes should live in `RunOutput.result`. A
trajectory-level final/outcome field is only useful if one run item can produce
multiple independent trajectories that each need their own conclusion.

Usage is preferably recorded on the step that produced it, such as an assistant
or model response step. A trajectory-level usage value, if added later, should
be treated as a derived summary rather than the source of truth.

## Artifacts

v2 intentionally does not use the old context helpers:

- `ctx.artifact`
- `ctx.writeArtifactFile`
- `ctx.writeTrace`
- `ctx.addEvent`

The runner saves what `runItem` returns. Artifact reading is still possible in
v2, but the source of truth must be explicit: either the returned `Archive`, a
structured artifact list, or file paths written by the runner. Do not assume the
old artifact index and `readArtifact` helper exist.

## Evaluation

Evaluators run only for completed run results. They receive the item, the
status-free completed `RunOutput`, and the eval context. Returned artifacts and
trajectories remain available through that `RunOutput`. Evaluators return only
`score` and an optional explanation; they do not produce status or skip values.
An experiment defines at least one evaluator.

The framework owns the persisted `EvalResult` envelope. A valid evaluator
return becomes `completed`, a thrown or invalid return becomes `error`, and an
upstream run error produces one framework-owned `skipped` result per configured
evaluator without invoking evaluator code. Evaluator errors and skips do not
make a fully traversed evaluation phase fail; the eval manifest still finishes
normally.

Aggregation is part of the v2 evaluation contract. After per-item results are
persisted, the aggregator receives a map grouped by evaluator name. Every
configured evaluator key is present and maps to an array of completed,
status-free outputs containing `itemId`, the evaluator's inferred score shape,
and its optional explanation. Error and skipped results are omitted, so an
evaluator with no completed outputs has an empty array rather than a missing
key. Consumers can explicitly join arrays by `itemId` for cross-evaluator
calculations. Framework-owned target, completed, skipped, error, and coverage
accounting stays outside the aggregator input.

Persisted aggregator scores are the only source for evaluation-level totals,
trends, and comparison charts. The dashboard does not synthesize means, box
plots, or histograms from per-item evaluator scores. Per-item scores remain
available in item detail tables; when the aggregator omits a score key, no
evaluation-level visualization is shown for that key.

Evaluator and aggregator versions are explicit author-supplied semantic
identifiers; they are not required to use SemVer syntax. An evaluator version
identifies its scoring semantics. Changing evaluator code, prompt, rubric, or
thresholds requires a new version, while changing run-time eval params such as
the judge model does not. Automatic item-score comparison requires the same
evaluator name, evaluator version, and score key. The aggregator version follows
the same rule for aggregation logic, and automatic aggregate comparison
requires the same aggregator version and aggregate score key.

The eval manifest snapshots every configured evaluator's name and version, even
when no item result is committed, so metadata can be rebuilt without loading the
experiment definition. It is the source of truth for evaluation lifecycle
errors: an aggregator exception or invalid aggregate output sets the manifest to
`error` with the original error string before the error is rethrown. Per-item
evaluator errors do not set this field and do not change a fully traversed eval
from `finished`.

Every completed evaluator score map is non-empty. The aggregator may return an
empty map. In evaluator and aggregate score maps, every present score value is a
finite number; `NaN` and infinities are invalid. The metadata index stores at
most 2,048 UTF-8 bytes for each error or explanation as a display summary.
Complete result objects remain the source of truth in object storage.

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

The runner writes through Store-scoped writers, which own serialization,
lifecycle manifests, and commit ordering. The runner should not directly write
result files or construct storage keys.

Run and eval loggers are scoped per dataset item. A run item log is flushed
before `item.json` is written last as the run item commit marker. An
eval item log is flushed before `eval_results.json` is written last as the eval
item commit marker. Logger handles are async-disposable resources and run/eval
phases scope them with `await using` so flush happens automatically before the
commit marker. Evaluation and re-indexing enumerate committed run items through
the store rather than relying on a separate dataset snapshot or item ordering.
Dashboard APIs expose logs and trajectories separately; the UI may render
either independently or combine them.

The manifests are small lifecycle records. They do not contain per-item
state, score summaries, artifact indexes, or output paths. The original Evalens
summary, run item JSONL, event stream, artifact index, evaluation package, and
dashboard-compatible schema are not required.

Run manifests declare `formatVersion: 2`; eval manifests remain at
`formatVersion: 1`. Child JSON files inherit the containing manifest version and
do not duplicate it. Readers accept only the current format and do not contain
a legacy dispatcher or fallback.

v2 should not add a separate publish step for normal result delivery. A required
`--config` file selects exactly one local or remote target. Local execution
writes through Bun file APIs; remote execution writes facts directly to R2 and
calls the protected metadata API to update D1.

## Persistence And Query Architecture

Experiments always execute in a Bun process such as the local CLI, CI, or an
agent runtime. They do not execute inside a Cloudflare Worker. Local and remote
persistence share Store, reader, and writer contracts, while their persistence
implementations share the same Store. Local composition uses filesystem and
SQLite adapters; remote composition uses an S3 object namespace and a Treaty
metadata writer.

### Store Composition And Scopes

The root `Store` owns long-lived persistence dependencies rather than one run
or eval identity:

```text
EvalensStore
  createRun() -> RunWriterContract
  openRun() -> RunReaderContract
  createEvaluation() -> EvalWriterContract

Local Store
  ObjectNamespace
  MetadataWriter
  LoggerCreator

Remote Store
  S3ObjectNamespace
  Treaty MetadataWriter
  R2 LoggerCreator
```

`MetadataWriter` is a required narrow write capability inside a persistence
owner. A normal local factory uses SQLite, and the Cloudflare result service
uses D1. An explicitly unindexed local configuration uses
`NoopMetadataWriter`. Persistence owners catch metadata failures after object
commits and write reindex markers; object writes remain required. Remote Bun
processes use bucket-scoped R2 credentials and a Cloudflare Access service token.

The root creates capability-scoped handles:

```text
createRun()       -> RunWriter
openRun()         -> RunReader
createEvaluation  -> EvalWriter
RunReader.openEval() -> EvalReader
```

`RunWriter` and `EvalWriter` own new lifecycle manifests. `finish()` marks the
owned phase finished; async disposal marks it error only when it is still
running. `RunReader` and `EvalReader` are read-only and never mutate historical
state. Re-evaluation opens an existing `RunReader` and creates a new
`EvalWriter`, so it cannot accidentally change the original run lifecycle.

A thin root `ResultReader` holds the read backend and creates `RunReader`
instances. `EvalReader` is opened from a run. Store may expose `openRun()` as a
convenience over the same reader, while QueryService depends directly on the
read-only `ResultReader`, never on Store.

### Local Object Namespace And Keys

Bun presents `BunFile` as a Blob-like object with native write, existence, and
deletion support, and `Bun.write` accepts `Bun.Archive`. The local persistence
boundary does not re-wrap these operations. A small `ObjectNamespace` maps
domain keys to native files and owns prefix listing:

```ts
interface ObjectNamespace {
  file(key: string): BunFile;
  list(prefix: string): AsyncIterable<string>;
}
```

The local target resolves safe paths under a configured root and lists with
`Bun.Glob`. Store uses the native file APIs directly. The remote target maps the
same keys to `Bun.S3Client`, including paginated prefix listing. Bun owns
streaming and multipart behavior for large objects.

Experiment name is the stable storage partition and run ids are framework-owned
UUIDv7 values. The canonical layout is:

```text
experiments/<experimentName>/runs/<runId>/manifest.json
experiments/<experimentName>/runs/<runId>/items/<itemId>/...
experiments/<experimentName>/runs/<runId>/evals/<evalId>/...
```

The validated item id is used directly as its local directory and R2 key
component. There is no `id=` prefix, percent encoding, case normalization, or
legacy lookup fallback. The `ItemId` schema prevents aliases, path traversal,
and filesystem component overflow. Key construction is a fixed persisted
contract shared by Store, dataset packing, readers, listing, and reindex rather
than a pluggable strategy.

### Commit And Index Ordering

A run item writes artifacts, trajectories, the persisted run result, and its
fully disposed log before writing `item.json` last as the commit marker.
An eval item fully disposes its log before writing `eval_results.json` last as
its commit marker. A remote logger writes Pino JSONL to a local temporary file,
then flushes, closes, and uploads it directly to R2 during async disposal. R2
append and live log chunks are not part of the initial design. A logger upload
failure prevents the item commit marker.

The framework validates item id uniqueness before scheduling. One writer owns a
run or eval and schedules each item once, so Store does not perform a per-item
existence request, conditional write, or a second in-memory duplicate set.
Derived rerun enumerates the source run's commit markers before scheduling.
Completed items are re-committed under the derived run id, while error and
missing items are scheduled normally. Uncommitted partial source objects are
not inherited.

Immediately after each item commit, the persistence owner sends one complete
backend-neutral index DTO to `MetadataWriter`. An eval item DTO includes all
evaluator results and scores for that item; it is not split into one request per
score. Local SQLite applies the DTO in one transaction. Remotely, the CLI writes
the R2 commit marker first and then sends one metadata request that applies the
D1 transaction/batch. Live commits and reindex both project facts into the same
DTOs and call the same writer.

R2 and D1 cannot participate in one cross-storage transaction. R2 is the source
of truth. If D1 projection fails after the R2 commit marker exists, the CLI
writes the narrowest run or eval reindex marker directly to R2 and still
preserves the durable result. If both D1 projection and marker writing fail, the
request fails with an aggregate error.

### Typed Remote Metadata And Access

`@evalens/server` owns the remote ingestion and query Elysia applications and
exports their API types. It contains no Eden client code. `@evalens/cli` owns
the Treaty clients, Cloudflare Access headers, request encoding, and response
mapping for both remote ingestion and queries. `@evalens/store/local` owns
local SQLite query composition and scoped synchronous index repair; both the
CLI and the read-only local server reuse that runtime. The local server queries
the CLI-created SQLite index and serves stored files.
`@evalens/core` never depends on transport or deployment packages. The package
dependency direction is:

```text
store -> core
server -> core + store
cli -> core + store + server
dashboard -> server (query App type)
```

### Built-in adapter configuration

Built-in Codex and Salix adapters are exported by `@evalens/adapters`. Their
connection, credential, executable, and safety configuration is parsed from the
optional top-level `adapters` object in `evalens.config.json`. Model, prompt,
template, and other result-affecting choices remain run/eval params or per-call
adapter inputs. Evalens does not impose execution deadlines: Codex processes,
verification commands, Salix reply polling, and trace collection wait until they
finish or fail.

Experiments declare adapters independently for run and evaluation phases:

```ts
defineExperiment({
  adapters: { run: ["salix"], eval: ["codex"] },
  runItem(item, context) {
    return runWithSalix(item, context.adapterConfig.salix);
  },
  // ...
});
```

The declaration narrows `context.adapterConfig` through the adapter registry.
CLI commands require each declared phase config before loading the dataset or
creating persisted state. Adapter config is recursively readonly at the type
level and is never persisted. Run/eval manifests record only adapter name and
implementation version; SQLite/D1 project those identities into `run_adapters`
and `eval_adapters`.

The remote CLI authenticates to Cloudflare Access with a service-token client id
and secret. Browser users authenticate through the configured identity provider.
Metadata writes require the service policy; query and streamed artifact/log
downloads require an authenticated browser policy. The custom `EVALENS_TOKEN`
is removed. R2 S3 credentials are independent and remain available only to the
trusted CLI/CI process. The Worker never proxies R2 writes, but streams artifact
and log downloads from its R2 binding for the Dashboard.

Remote artifacts have no Evalens-specific size limit. The CLI writes the
original archive directly to R2, and Bun owns multipart upload behavior. Reeval
reads the same archive directly from R2.

Result objects and manifests are the source of truth. SQLite and D1 are
rebuildable query indexes. Local SQLite lives at
`<outputDir>/.evalens/index.sqlite`; one Cloudflare deployment uses one D1
database and one R2 bucket. Happy-path Store tests use the real SQLite writer
with an in-memory database; `FailingMetadataWriter` covers the required
best-effort failure behavior.

### Metadata Schema

The metadata schema is normalized around committed object facts. It does not
contain an experiments table. Run-side metadata uses:

Drizzle's schema is the sole DDL source. `drizzle-kit generate` writes the v3
SQLite migrations, and the Bun SQLite adapter applies those generated files
with Drizzle's migrator before initializing the `index_metadata` control row.

- `runs`: one lifecycle and identity snapshot per run id, including experiment
  name and description snapshot, dataset identity, params digest, required
  target item count, and lifecycle timestamps
- `run_tags`: one row unique by run id and tag for filtering and grouping
- `run_params`: one row unique by run id and top-level param key; the complete
  parsed params remain in the manifest, while scalar values are queryable and
  flat arrays retain their JSON representation
- `run_items`: one row unique by run id and committed item id, including item
  digest, result status, author-execution timing, and the bounded error summary

Evaluation-side metadata uses:

- `evals`: one lifecycle row per eval id, linked to its run, including params
  digest, aggregator version, and lifecycle timestamps
- `eval_params`: one row unique by eval id and top-level param key under the same
  rules as `run_params`
- `eval_evaluators`: one row unique by eval id and evaluator name, including its
  semantic version even when it has no completed result
- `evaluator_results`: one row unique by eval id, committed item id, and
  evaluator name, including completed, skipped, or error status,
  author-execution timing when execution occurred, and one bounded nullable
  `message` interpreted by status as the completed explanation, error message,
  or skipped reason; complete result objects retain their original fields
- `eval_scores`: one row unique by evaluator-result identity and score key,
  containing the finite score value
- `eval_score_identities`: one bounded projection row per eval, evaluator name,
  and emitted score key, carrying the evaluator version from the manifest; item
  rewrites remove an identity only after no item in that eval emits it
- `aggregate_scores`: one row unique by eval id and aggregate score key,
  containing the finite aggregate value

Primary and unique constraints preserve those logical identities, and foreign
keys preserve the run, eval, item, evaluator, result, and score ownership
relationships. Ordinary indexes support parent traversal and the user-visible
time and duration sort paths, including newest-first run/eval ordering and
run-item/evaluator execution timing. The run target is an authoritative
preflight fact that cannot be reconstructed after interruption. The schema does
not persist redundant completed, skipped, error, coverage, or score statistics;
query and API layers derive them from normalized rows. Full-text search is not
part of the initial index.

The current manifest format requires `targetItemCount`; there is deliberately
no legacy reader fallback. Reindexing an older manifest fails visibly rather
than silently omitting source-of-truth objects or guessing from a partial run.

### Dirty Index Markers And Reindex

When a fact object commits but its metadata update fails, Store warns and writes
a versioned, uniquely keyed `ReindexMarker` in object storage. The marker is a
small control object containing `formatVersion`, detection time, a short reason,
and one of three scopes:

```text
experiment
run
eval
```

Any run-item indexing failure marks the whole run dirty. Any eval-item or
aggregate indexing failure marks the whole eval dirty. Missing or invalid
experiment index state uses experiment scope. Item-level reindex scopes are not
required because different writers do not share one run or eval. If both the
metadata update and marker write fail, Store throws because it can no longer
guarantee that an incomplete index will be detected.

Marker relevance is hierarchical: an experiment marker covers that experiment
and all descendant runs and evals, a run marker covers the run and its evals,
and an eval marker covers only that eval. A query is unavailable when its scope
or any ancestor has a relevant marker. Reindex does not operate on a running
run or eval scope because committed facts may still be changing.

SQLite and D1 use the same persistent repair-fence invariant. `beginReindex`
atomically invalidates every overlapping parent, child, or identical repair
lease, then installs a fresh scope lease at revision zero with the destructive
replacement. There is therefore at most one current lease for any overlapping
scope hierarchy. Every repair metadata mutation verifies that exact lease and
revision zero in the same SQLite transaction or D1 batch before changing index
rows; a superseded repair cannot mutate an index already published by its
replacement. Every normal metadata write advances every overlapping active
fence in the same transaction or batch as projecting its already-committed
object fact. `finishReindex` publishes only when the lease still matches and its
revision is still zero. A failed mutation assertion, changed revision, or
changed lease forces another destructive replay from a fresh object-storage
plan, so a captured stale plan cannot become observable as clean metadata.

Relevant uniquely keyed markers remain present for the complete rebuild. After
the zero-revision lease CAS succeeds, repair deletes only the exact marker keys
captured by that successful plan. A marker created during or after the repair
window has a different key and survives for the next repair. This fence plus
marker lifecycle provides logical atomicity without requiring one unbounded
database transaction.

Normal queries never scan object storage as a fallback. Object listing is
reserved for Store enumeration, reindex, repair, and integrity checking. A
missing index or relevant marker must be repaired before results are returned.
Local CLI queries use the `@evalens/store/local` query runtime, which
synchronously reindexes the affected scope before calling the read-only
QueryService.

Remote query routes do not block an ordinary GET while scanning R2 and updating
D1. They inspect index state outside the read-only QueryService; a dirty scope
is scheduled once for background reindex and the route returns `202 reindexing`.
Clients poll and retry. Queue or Workflow implementation details belong to the
remote index scheduler, not Store or QueryService.

An `index_metadata` singleton records global index availability: whether the
index is missing, whether its schema/version is compatible, and whether a global
rebuild is in progress. These global states block normal queries just as a
relevant marker does. Scope markers remain the source for experiment, run, and
eval dirtiness; the singleton does not duplicate per-scope state.

Filtered evaluation queries check only the requested experiment scope. A
comparison checks the scopes containing its selected evaluations. A dirty
marker in an unrelated experiment does not make those scoped queries
unavailable; unfiltered global lists still require the global marker set to be
clean.

Before writing an evaluation's first manifest fact, Store establishes its exact
`control/evaluation-scopes/<evalId>.json` locator. Creation aborts if that first
locator write fails, so an eval fact never appears without a locator that was
successfully established. Later item, aggregate, and lifecycle commits do not
rewrite the immutable locator. If a selected eval metadata row is missing, the
guard reads only that bounded locator and repairs its eval scope; it never falls
back to a global object scan or lets an unrelated dirty or running experiment
block the query.

### Metadata And Query Boundaries

The shared metadata layer consists of a Drizzle SQLite schema, repository
contracts, index service, query service, and API DTOs. Runtime-specific adapters
stay thin:

- local: `bun:sqlite`, local object storage, and the Bun Elysia adapter
- Cloudflare: D1, R2 bindings, and the Elysia Cloudflare Worker adapter

File-backed local metadata connections enable SQLite WAL, a 5000 ms busy
timeout, and foreign keys so a query process can read while a run process is
committing. In-memory test databases keep foreign keys and the busy timeout but
do not request WAL.

Single-resource detail queries are metadata-only and bounded by identity.
`getRun(runId)` returns one `RunSummary`; it does not implicitly load run items
or evaluation history. `getEvaluation(evalId)` returns one hydrated
`EvalCatalogEntry`, including its owning run identity; callers do not need to
know the run id first. Child collections use explicit bounded queries:
`listEvaluations({ runId, page, pageSize })` for a run's evaluation history and
`listRunItems(runId, evalId?, page, pageSize)` for run items with optional
evaluation result cells. HTTP follows the same split through
`GET /runs/:runId`, `GET /evaluations/:evalId`, and paginated
`GET /runs/:runId/items`. A dashboard page may compose these calls, but the
query service and detail routes never hide a full child-record scan behind a
single-resource lookup.

Elysia is the metadata/query transport and validation layer, not the source of
truth or the experiment runtime. The local CLI selects the local Store query
runtime directly. The remote CLI writes R2 through the shared Store and owns
Treaty clients built against API types exported by `@evalens/server`. The
Dashboard calls the typed query API and uses
Worker-streamed download routes. The runner receives bucket-scoped R2
credentials but never receives direct D1 access.

Dataset item payloads, run results, trajectories, artifacts, complete
explanations/errors, and logs stay in object storage. The comparison selection
only accepts evaluations with a shared compatible identity; incompatible
candidates are disabled with a precise reason. Compatibility is determined
from:

- dataset identity is `datasetName` plus `datasetSelectionDigest`
- item metric identity is evaluator name, evaluator version, and score key
- aggregate metric identity is aggregator version plus aggregate score key

Catalog hydration and comparison compatibility use the persisted
evaluation-level `eval_score_identities` projection. Compatibility therefore
does not depend on which item page is loaded; page-local item metrics control
only the score columns rendered for that page. The comparison selection
provider owns the authoritative selected evaluations and retains its resolved
first-page response for the `/compare` route, so hydrating a stored selection
does not issue the same comparison request again after single-flight cleanup.

This is metric-schema compatibility, not a guarantee that every compatible
metric has a successful value for every shared item. Errors, skips, or sparse
results may leave no paired non-null cell on a particular page without changing
the evaluations' global metric identity. Score keys belong to an evaluator's
author-level inferred score shape; item ids or other child-cardinality values
are not a dynamic score-key namespace. The evaluation-level projection tracks
that score shape rather than materializing score-by-item compatibility.

## Progress And Events

`onProgress` and events are primarily useful for run-time consumers such as a
CLI progress view, live dashboard updates, long-running job monitoring, and
debug lifecycle traces.

Persisted `running` means only that no terminal lifecycle fact has been
recorded; it does not prove the originating process is alive. The initial query
CLI does not infer staleness or implement heartbeats. Execution identity
handoff is also deferred: `evalens run` does not emit an early run id or a JSONL
event stream, so callers use a supplied id, the newest filtered run, or the
local run directory.

v2 can omit them while the runner only needs finished-on-disk results. The
existing logger and trajectories cover the current debugging story.
