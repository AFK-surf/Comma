# Observability

## Data planes and failure isolation

Each BEAM VM starts `systems_observability` before selected subsystems.
It exposes cluster-only `/metrics` on port 9568 and uses one OTel SDK.
Managed Prometheus scrapes application and collector metrics.
Applications send OTLP traces to the dedicated Comma collector. JSON stdout goes to Cloud Logging.
ClickHouse remains the business, usage, and billing fact store.
Telemetry outages must not affect readiness or business results.
Agent phase, run, tool, and fee-check rows use a separate, bounded ETS reporting buffer.
Admission does not call a worker or execute telemetry handlers. The worker batches writes and emits buffer metrics.
Each occupied ring slot drops the new row. Failed reporting writes drop the batch.
Shutdown closes admission and attempts buffered writes within the worker's 30-second budget.
LLM usage uses a separate buffer with the loss and retry contract in [Billing and models](billing-models.md#llm-usage-delivery).
Trace queues and retries remain bounded. Metrics are pull-only.
Do not introduce runtime Grafana API or dashboard dependencies.

Use the metric definitions and checked-in dashboard/rule consumers as the catalog, not a duplicate handwritten inventory.
`workload`, `component`, and `surface` are independent dimensions.
Application labels must be finite and normalized.
Never add tenant, Session, Conversation, user IDs, message content, tokens, or secrets as metric labels.

Application PodMonitoring uses a 30-second interval and ten-second timeout.
The target limit is 12,000 samples and 19 labels: fixed target labels, at most five application labels, and histogram `le`.
Collector self-monitoring is capped at 16 labels.
Change these bounds only with cardinality evidence and the matching consumer/configuration review.

## Diagnosis order

### Desktop Google login

Electron does not automatically retry Google login. Each click starts one attempt.
After failure, the login screen explains the error and offers a manual retry.
Network errors suggest a connection check. Provider errors suggest a later retry.
Code exchange is single-use and is never replayed automatically.

The initiating renderer reports terminal infrastructure failures to PostHog as `login_unavailable`, with a bounded `login_error_code`.
These reports contain no credentials, email, raw exception text, or request bodies. Cancellation, conflicts, and rate limits do not create these issues.
Reports are best-effort and capped at 20 per renderer lifetime. They do not prove delivery when the client has no network.
The existing issue-created/reopened destinations in `observability/posthog/client-critical-issues.json` also carry this error kind.
Alert router maps these issues to `comma_client_login_unavailable`, priority P1, independently of the existing P2 rendering rule.
One issue occurrence triggers an incident. Duplicate deliveries deduplicate. Repeated failures in an open issue do not generate new incidents.
Successful login does not automatically resolve an issue or prove recovery for other clients.
Deploy the router change and the updated desktop client before treating this coverage as live.

### Service diagnostics

1. Check the PodMonitoring target.
2. Read the exact Pod's `/metrics`.
3. Inspect reporter scrape diagnostics.
4. Inspect the application trace queue.
5. Inspect collector receiver and queue state.
6. Check collector exporter/IAM and backend ingestion.

Managed Prometheus `up` owns scrape reachability.
An application cannot report its own failed scrape through that same failed scrape.
`comma_system_startup_duration_seconds` measures selected-subsystem startup.
Container uptime is not equivalent to readiness latency.
Normalize GKE native `pod_name`/`namespace_name` labels before joining metrics that use `pod`/`namespace`.

Monitoring resources follow their normal Helm owner.
Do not raw-apply or delete Helm-owned resources as an improvised rollback.
See [Release operations](release-operations.md).

### Model call killed at the deadline

A round whose model call reaches the request deadline ends as `actor_failed` in `agent_run_events_v2`.
The session actor kills the job, so the call never returns to the retry loop.
The actor writes that attempt to `llm_attempt_events` with outcome `killed` and the stream progress it read after the kill.
An attempt that had already returned keeps the retry loop's row: a job that dies during a retry backoff or after the loop gave up writes no `killed` row.
`received_bytes`, `received_chunks`, `first_body_ms`, and `last_body_ms` count every response chunk, keep-alive comments included.
`content_deltas`, `first_content_ms`, and `last_content_ms` count text, tool-argument, and reasoning deltas that reached the round.
Body without content is a provider that heartbeats over an empty stream. Recent content is an answer still being written.
NULL body columns mean no response body arrived, or the call did not stream through `SalixLlm.Http`.
Read the rows by `round_id` next to the `actor_failed` run. The pod log line `llm task failed` carries the same summary.

## Internal message send latency

Internal sends emit `salix_operations_duration_seconds` with `component="salix_im"` and fixed `im_send_*` operations.
Child spans use `salix.im.send.stage` and the same operation names.
`total` covers the internal provider, after group scope resolution.
`authorize`, `conversation`, `attachments`, and `participant` cover activation provenance, conversation reads, file binding, and sender lookup.
`placement` covers owner discovery or startup. `call` covers the owner request and response.
`actor` covers owner execution. `membership`, `sender`, and `sender_fence` cover participant loading, sender resolution, and incarnation validation.
`prepare`, `commit`, and `delivery` cover message preparation, append, and source notification hints.
`result` covers routed-recipient result reads when the conversation requires them.
These are nested measurements, not an additive partition. Uninstrumented work can remain between child spans.

`queue` measures dispatch to handler entry only when sender and owner share one VM.
Remote calls retain client and actor spans, but emit no queue duration because their monotonic clocks are independent.
Do not infer a pure remote queue duration from their timestamp difference.
The transient owner envelope carries bounded trace context and timing. It never enters message storage.
Metrics work without sampled traces. Neither signal establishes external receipt.
Timing adds no polling, extra storage reads, or participant fan-out.

## Triage decision diagnostics

Triage rejection logs name the failed contract check and a fixed reason without recording the rejected value.
The evaluator reports product, assessment, and Worker assignment failures.
The bound validator also distinguishes decision shape, schema, assignment, and projected decision failures.
These diagnostics do not change terminal error codes, retry behavior, source authority, or recipient routing.

Assessment text uses the provider schema's limit of 1,200 Unicode code points per field, with at most 4,800 UTF-8 bytes.
The evaluator includes the same output schema in the model prompt, including field types and allowed source references.
Only Responses requests send the strict response format. Chat and Anthropic requests use the prompt schema and backend validation.
The schema guides generation. Backend validation still rejects invalid types and references.
An empty terminal evaluator record does not prove that no model request ran.
Check the provider request and settlement logs before attributing the failure.

## Encrypted Agent event archive

Preserve six observation seams:

1. Inbound input.
2. Provider request.
3. Provider response.
4. Tool dispatch.
5. Tool result.
6. Visible reply.

Encrypt in the caller before handing data to the archive path.
Do not place plaintext in archive mailboxes, logs, or metrics.
The archive is observational. Its failure cannot fail the Agent's task.
Bound its queues and retry work.
Keep runtime seam guards and adapter shape tests when removing redundant tests.

Resident Session dispatch archives the final provider JSON as `request_body`, with its wire `protocol`.
List-based callers archive their provider-neutral `messages`. Both forms retain explicit dispatch identity and credential-scrubbed options.
Request bodies remain content-bearing encrypted payloads, never logs or metric labels.

A sequence hole can prove bracketed loss when later events arrive.
Tail loss or process loss can leave no live signal.
Do not claim complete capture or guaranteed loss detection from a contiguous observed prefix.
An archive record proves the observed seam, not external receipt or user consumption.

## Alert ownership

Cloud Monitoring and Grafana own evaluation and source incident lifecycle for their respective rules.
A notification router formats and routes those decisions. It is not another incident engine.
It must not independently trigger, merge, recover, or close a source incident.
A source CLOSED/RESOLVED event does not establish service recovery verification.

Keep source-native notification fallback independent of router failure.
The router's delivery-health alert must bypass the router.
Do not remove Grafana direct Slack without an approved source-native fallback.
Verify current environment routing before claiming a historical rollout choice is live.

Runtime terminal failures, request stalls, IM ingress, OOM, and deployment failures have distinct owners and evidence.
Use the exact current rule and its source labels rather than parse prose to recover identity.
Alert status changes should update the same incident-generation presentation while retaining useful lifecycle events.
Do not emit repeated noise for unchanged state.

### Slack cards and investigation progress

Live P0 and P1 firing roots notify the channel. A later priority escalation posts
a separate channel message, because a mention inside a thread does not notify the channel.
Root edits, ordinary thread events, shadow delivery, and recovery do not mention the channel.
The accepted EventRecord stores the escalation destination. Delivery and ambiguous-result
reconciliation use that same destination and existing Block Kit marker.
The first root's published revision suppresses an escalation already included in that root.
Legacy EventRecords without a channel destination remain thread deliveries, including during reconciliation.
Each separate channel escalation requests one root permalink. A failed link lookup does not suppress the notification.

The Incident owns a latest investigation report separately from its source status.
A person can submit a report in the original alert thread:

```text
告警进展
已确认：一个会话恢复后再次中断。
影响：已定位一个会话，整体范围尚未确认。
下一步：核对第二次执行结果。
```

For an explicit report, the first line must be exactly `告警进展`. The report body is limited to 1,800
characters and 4,000 UTF-8 bytes. The card shows the report, reporter ID, and Slack
message time as plain text. Ordinary discussion, edits, and deleted-message events
do not replace the report. Post a new report to correct an earlier one.
Duplicate or older message timestamps do not change it. Source events preserve it.
A report never changes source priority, owner, recovery verification, or closure.
The source thread retains the history. No background channel scans or per-incident
polling run. One signed callback performs an indexed channel/root lookup and one
Incident transaction, which also queues the existing root update worker.

The root card also provides `我来处理` and an owner transfer selector.
A Slack user can claim an unassigned Incident. Only its current owner can transfer it.
The callback checks the configured workspace/app and the exact channel/root.
It rejects stale card revisions. Source events cannot replace the owner.
Claims, transfers, explicit reports, and quality feedback add a compact channel update with a root link.
These updates do not mention the channel. Shadow updates stay in the thread.
Their EventRecords use the existing delivery lease, marker, and uncertain-result reconciliation.

The card accepts attributed feedback: `需要行动`, `自愈`, or `误报`.
Feedback survives source refreshes. It does not change source status, recovery verification, priority, or the reminder deadline.
Review these labels against the source evidence before changing an alert rule.

For active P0 and P1 incidents, an unassigned phase has one reminder after 15 minutes.
An assigned phase has one reminder after 30 minutes without a new report or transfer.
The live reminder mentions the channel when unassigned, or the current owner when assigned.
It does not repeat for the same phase. A claim, transfer, or report on an assigned Incident starts a new handling revision.
Source refreshes do not restart that revision. Source closure stops reminders, even when recovery remains unverified.
Each successful root delivery schedules at most one Oban job for its handling revision.
Old jobs and unsent notices check that revision before delivery. No incident scan or periodic polling runs.
A reminder already accepted by Slack remains a historical message if handling changes during delivery.
Oban runs at most two delivery jobs concurrently. Reminder jobs use one Incident lookup and one EventRecord lookup.

A configured investigator bot can also update the root without the prefix.
Set `SLACK_INVESTIGATOR_BOT_ID` in the same Router Slack secret.
It becomes `alert_router.slack.investigator_bot_id`, with environment variable `ALERT_ROUTER_SLACK_INVESTIGATOR_BOT_ID` as an alternative.
The signed event must identify that bot and a different app from the alert-delivery Slack app.
Unlisted bots, ordinary human discussion, edits, and deletions cannot use this path.
Bot reports retain attribution and the same recovery boundary. Long reports show an explicit truncation notice.
Identical bot reports do not reset handling. Automatic reports update the root without another channel notice, to avoid bot reply loops.
Reports received before a person claims the Incident do not postpone the unassigned reminder.

Configure the Alert Router Slack app before using this path:

1. Set `SLACK_SIGNING_SECRET`, `SLACK_TEAM_ID`, and `SLACK_APP_ID` in the existing
   `alert-router-slack-<environment>` secret. The release bundle copies only these
   values and the bot token into the dedicated Router config.
   They become `alert_router.slack.signing_secret`, `team_id`, and `app_id`.
   The equivalent variables are `ALERT_ROUTER_SLACK_SIGNING_SECRET`,
   `ALERT_ROUTER_SLACK_TEAM_ID`, and `ALERT_ROUTER_SLACK_APP_ID`.
2. Set the Events API request URL to the environment's `/v1/events/slack` endpoint.
3. Subscribe to `message.channels` with `channels:history` and join the alert channel.
4. Enable Interactivity with the environment's `/v1/interactions/slack` endpoint.
5. Post an approved test report. Verify the root update and one channel progress notice without a channel mention.
6. Claim the Incident and transfer it. Verify the owner in the original card and one notice for each change.
7. Verify overdue delivery and cancellation in an approved test channel before enabling live use.

Slack's app signing secret is the independent authority for incoming callbacks.
The HTTP adapter verifies the raw-body signature and five-minute request timestamp
before parsing. It rejects unsigned requests. Progress ingress also checks the
configured workspace/app and an existing alert root in the reported channel.
This prevents arbitrary HTTP callers or another installation from rewriting cards.
The reporter's claims remain attributed reports, not verified recovery evidence.
The optional path stays closed until configured. Existing source ingestion stays available.
See [Slack signature verification](https://docs.slack.dev/authentication/verifying-requests-from-slack/)
and [message events](https://docs.slack.dev/reference/events/message/).

The additive `alert-router-20260924000001` migration preserves existing incidents
and adds the report value, first published root revision, and channel/root index.
Migration `alert-router-20260924000002` adds the handling revision and quality feedback without changing existing owners.
Roll back the binary while retaining these fields if needed. Do not drop reports during rollback.
Automatic source investigation, Jev decisions, and human recovery verification are not implemented by these callbacks.

## Validation

Keep event-to-scrape, finite-label, queue-bound, failure-isolation, and runtime seam regressions.
A copied PromQL string or metric-name list does not prove telemetry behavior.
An encrypted archive and aggregate metrics protect different boundaries and do not replace each other.
Dashboard and alert configuration lives under `observability/` and `k8s/`.
No documentation-only metric catalog is a second runtime authority.

## Routine job queues

Generation uses the finite `comma_recommendations` queue label.
Deadlines and schedule reconciliation use `comma_recommendation_control`.
Existing Oban execution and backlog metrics expose those queues.
Generation logs include run ID, outcome, source counts, collection duration, input bytes, model duration, and usage, but no source content.
A failed generation logs its run ID, bounded failure reason, and duration.
A published or superseded run keeps the same counts in `metrics`, with per-source truncation counts and projection counts.
The profile keeps the published generation's copy in `published_metrics`. Neither field crosses the API.
The rail's `GET` of a fresh Routine emits `[:comma_product, :recommendation, :exposure]` with the finite `variant` label.
It also writes a `routine_exposure` log line with the user ID, workspace ID, generation, and variant.
Reads are not deduplicated. Count exposed generations from the log line, not from the counter.
A fresh read shows that an active rail fetched the Routine. It does not show that the member looked at it.
See [Routine generation](product-features.md#routine-generation) for deadlines and recovery limits.

## Cloud VM archive diagnostics

Connector export/import status carries optional, finite phase timing fields in milliseconds.
Salix stores eight recent operation/direction summaries in the existing Workload `archive_diagnostics` value.
`connector_outcome` describes the Connector phase. `outcome` describes the Salix result.
Parallel PUT/GET durations are sums across requests. They do not add up to wall time.
Salix duration includes its orchestration. The fields do not cover every internal stage.

Query `GET /v1/admin/vm/archive/operation?group_id=GROUP&operation=OPERATION` with existing admin authorization.
For all retained summaries, call `SalixWeb.CloudVM.ArchiveDiagnostics.list("GROUP")` through the serving release RPC.
Old summaries return `observation: true`. They grant no cancellation or recovery authority.
Queries read one Workload. No tail or separate R2 log object is required.

A dedicated Task Supervisor permits four diagnostic writes and drops observations when full.
Storage errors do not change archive/restore results or trigger business retries.
Successful imports reuse the original receipt write. Failed imports asynchronously save one optional timing sidecar without fsync.
Missing or mismatched sidecars cannot reject imports. Command content, paths, URLs, credentials and raw errors are excluded.
Loss before reporting, failed writes and retention eviction can leave no summary. These records are diagnostics, not lossless audit.
