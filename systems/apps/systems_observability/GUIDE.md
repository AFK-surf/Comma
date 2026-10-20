# Systems observability guide

`systems_observability` is the single VM-local reporter, `/metrics` endpoint,
OTel SDK, and trace propagation kernel. Metric semantics stay in
`SystemsObservability.Telemetry`, `BridgeForTeams.Telemetry`,
`CommaProduct.Telemetry`, `Salix.Telemetry`, and `BillingTelemetry`.

## Metrics

- Define metrics with `Telemetry.Metrics` in the owning module's `metrics/0`.
  The composition root only combines the static enabled domains.
- Counters with a finite `outcome` expose one total. Select error series from
  that label. Do not add a second error counter. Gauges expose bounded current
  facts. Histograms use seconds or bytes and declare buckets explicitly. Never
  use Summary for cross-Pod percentiles.
- Every metric must answer a current operational question. Record that question
  beside its definition or its dashboard or rule consumer. Keep PromQL with that
  consumer. Use [`docs/observability.md`](../../../docs/observability.md) for
  shared bounds, not a duplicate metric inventory.
- Normalize every label through a finite classifier. Unknown values become
  `other`. Unknown HTTP routes become `unmatched`.
- Never label tenant, org, group, user, agent, session, request, trace, or VM IDs,
  raw URL, query, path, command, prompt or completion, tool arguments or results,
  dynamic model names, secrets, or exception text.

Useful shapes:

```promql
sum by (surface) (rate(salix_operations_total[5m]))
sum by (surface) (rate(salix_operations_total{outcome!="ok"}[5m]))
  / clamp_min(sum by (surface) (rate(salix_operations_total[5m])), 1e-9)
histogram_quantile(0.95, sum by (le, surface) (rate(salix_operations_duration_seconds_bucket[5m])))
sum by (queue) (rate(comma_product_backlog_retries_total[5m]))
```

`workload` is the Kubernetes runtime. `component` is the executing subsystem.
`surface` is the initiating product (`bft`, `comma`, `salix`), or the internal
delivery writer that names itself: `schedule`, `timer`, or `auto_title`.
`system` is only the fallback for a caller that set no surface. Do not use it for
scheduled or internal work. The set is closed (`Salix.Telemetry` for metrics,
`Classifier` for logs and traces). Anything else becomes `other`. Never infer one
label from another. HTTP labels use the matched Plug or Phoenix route, which
`RouteCatalog` maps to a small operational family. Method and status are
independent finite classifiers.

Compute control-plane transitions use the `salix_operations_total` and
`salix_operations_duration_seconds` family with `component="salix_store"` and
`operation="compute_mutation"`, `"compute_migration"`, or `"service_route"`.
Never label pool, environment, workload, runtime instance, migration run,
Provider object, route, tenant, or credential identifiers. A missing reporter or
a failing telemetry handler must not change CAS, generation fencing, cursor
persistence, cutover, rollback, or delete-gate results.

## Context, traces, and logs

Entrypoints set `surface`. Work that sets none falls back to `system`. Task and
GenServer work uses `Context.capture/0` plus `Context.run/2`. ERPC carries only
`traceparent`, `tracestate`, `surface`, and a safe correlation ID through
`Context.inject/1` and `extract/1`. Persisted asynchronous work uses
`Trace.link_from/2`.

Span names and attributes are finite. IDs, URLs, queries, commands, prompts,
tool arguments, response content, and exception text never enter spans.
Production Phoenix parameter logging stays keep-none.

Telemetry is not a business control plane. Event handling, reporter scraping,
queue pressure, Collector outage, and export failure must not change request
results, retry, pagination, scheduling, state, persistence, return contracts,
or readiness. Do not add synchronous telemetry-owned coordination to a request
path.

## Tests and review

Prefer tests that fail when a real risk regresses:

1. Start the reporter, emit a real event, and inspect the scrape.
2. Pass hostile identifiers and content, and prove they converge or are rejected.
3. Exercise Task, GenServer, ERPC, and persisted-link propagation.
4. Stop or omit handlers and reporters, and prove the business result does not change.
5. Keep provider retry, bounded queue work, freshness, SSE disconnect, and similar
   behavior tests at their owning business boundary.

Do not test a metric struct against itself, a mock against its declared return,
or Kubernetes YAML with string assertions. Validate manifests directly with
`kubectl --dry-run`.
