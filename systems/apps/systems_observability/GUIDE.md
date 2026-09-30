# Systems observability guide

`systems_observability` is the single VM-local reporter, `/metrics` endpoint,
OTel SDK, and trace propagation kernel. Metric semantics remain in
`SystemsObservability.Telemetry`, `BridgeForTeams.Telemetry`,
`CommaProduct.Telemetry`, `Salix.Telemetry`, and `BillingTelemetry`.

## Metrics

- Define metrics directly with `Telemetry.Metrics` in the owning module's
  `metrics/0`; the composition root only combines the static enabled domains.
- Counters with a finite `outcome` expose one total; error series are selected
  from that label instead of duplicated as a second counter. Gauges expose
  bounded current facts. Histograms use seconds or bytes, explicitly declare
  buckets, and never use Summary for cross-Pod percentiles.
- Every metric must answer a current operational question recorded beside its definition or dashboard/rule consumer.
  Keep PromQL with that consumer. Use `docs/observability.md` for shared bounds, not a duplicate metric inventory.
- Normalize every label through a finite classifier. Unknown values become
  `other`; unknown HTTP routes become `unmatched`.
- Never label tenant/org/group/user/agent/session/request/trace/VM IDs, raw URL,
  query, path, command, prompt/completion, tool arguments/results, dynamic
  model names, secrets, or exception text.

Default duration buckets (seconds): HTTP/DB/domain `0.005, 0.01, 0.025, 0.05,
0.1, 0.25, 0.5, 1, 2.5, 5`; LLM `0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60,
120`; VM `0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600`.

Useful shapes:

```promql
sum by (surface) (rate(salix_operations_total[5m]))
sum by (surface) (rate(salix_operations_total{outcome!="ok"}[5m]))
  / clamp_min(sum by (surface) (rate(salix_operations_total[5m])), 1e-9)
histogram_quantile(0.95, sum by (le, surface) (rate(salix_operations_duration_seconds_bucket[5m])))
sum by (queue) (rate(comma_product_backlog_retries_total[5m]))
```

`workload` is the Kubernetes runtime, `component` the executing subsystem, and
`surface` the initiating product (`bft`, `comma`, `salix`) — or, for the internal
delivery writers that name themselves, the writer: `schedule` (the schedules
sweeper), `timer` (the timers sweeper), `auto_title`. `system` is only the
fallback for a caller that set no surface; it is not a label for scheduled or
internal work, so a sweeper's volume is one `surface` query away instead of a
catch-all to trace through. The set is closed (`Salix.Telemetry` for metrics,
`Classifier` for logs and traces); anything else classifies as `other`. Never
infer one label from another. HTTP labels use
the matched Plug/Phoenix route mapped by `RouteCatalog` to a small operational
family; method and status are independent finite classifiers.

Compute control-plane transitions use the existing finite
`salix_operations_total` / `salix_operations_duration_seconds` family. Use
`component="salix_store"` with `operation="compute_mutation"`,
`"compute_migration"`, or `"service_route"`; never label pool, environment,
workload, runtime instance, migration run, Provider object, route, tenant, or
credential identifiers. Migration dry-run and write execution share the same
business checks and metric family. A missing reporter or failing telemetry
handler must not change CAS, generation fencing, cursor persistence, cutover,
rollback, or delete-gate results.

## Context, traces, and logs

Entrypoints set `surface`; the timers sweeper, the schedules sweeper and
auto-title name their own on every delivery (`timer`, `schedule`, `auto_title`);
work that sets none falls back to `system`. Task and GenServer work
uses `Context.capture/0` plus `Context.run/2`. ERPC carries only `traceparent`,
`tracestate`, `surface`, and a safe correlation ID through
`Context.inject/1`/`extract/1`. Persisted asynchronous work uses `Trace.link_from/2`.

Span names and attributes are finite. IDs, URLs, queries, commands, prompts,
tool arguments, response content, and exception text never enter spans. The
Bandit adapter strips dynamic path/query/header/error content before delegating
to the official OTel integration. Production Phoenix parameter logging remains
keep-none.

Telemetry is not a business control plane. Event handling, reporter scraping,
queue pressure, Collector outage, and export failure must not change request
results, retry, pagination, scheduling, state, persistence, return contracts,
or readiness. Do not add synchronous telemetry-owned coordination to a request
path.

## Tests and review

Prefer tests that fail when a real risk regresses:

1. Start the reporter, emit a real event, and inspect the scrape.
2. Pass hostile identifiers/content and prove they converge or are rejected.
3. Exercise Task, GenServer, ERPC, and persisted-link propagation.
4. Stop or omit handlers/reporters and prove the business result is unchanged.
5. Keep provider retry, bounded queue work, freshness, SSE disconnect, and similar behavior
   tests at their owning business boundary.

Do not test a metric struct against itself, a mock against its declared return,
or Kubernetes YAML with string assertions. Validate manifests directly with
`kubectl --dry-run`.
