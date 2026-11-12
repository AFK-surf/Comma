# Observability

## Data planes and failure isolation

Each BEAM VM starts `systems_observability` before selected subsystems. It serves cluster-only `/metrics` on port 9568 and runs one OTel SDK.
Managed Prometheus scrapes application and collector metrics. Applications send OTLP traces to the Comma collector. JSON stdout goes to Cloud Logging.
ClickHouse stays the business, usage, and billing fact store.
Telemetry outages must not affect readiness or business results.

Metric definitions and checked-in dashboards and rules are the catalog. Do not copy it into docs.
`workload`, `component`, and `surface` are independent dimensions.
Application labels must be finite and normalized.
Never use tenant, Session, Conversation, or user IDs, message content, tokens, or secrets as metric labels.
Managed Prometheus takes the first sample of a counter series on a Pod as its zero point, so `increase()` does not see the first event after a restart.
A counter or histogram that an alert reads with `increase()` lists its label values in `zero_series` (`SystemsObservability.Metrics`). Each listed series reads 0 from process start.

Application PodMonitoring uses a 30-second interval, a ten-second timeout, 12,000 samples and 19 labels.
The 19 labels are fixed target labels, at most five application labels, and histogram `le`. Collector self-monitoring allows 16 labels.
A change to these bounds requires cardinality evidence and consumer and config review.

## Comma product analytics

[Comma.Analytics](../systems/apps/comma_core/lib/comma/analytics.ex) exports Users and activity by client User ID.
Profiles contain email, creation time, kind, status, locale and `is_internal`. Guests and content are not exported.

Before erasure:

1. Set `comma.analytics.excluded_user_ids` (an ID or a list, non-strings ignored) on all pods.
2. Let in-flight attempts finish.
3. Delete the PostHog data.

Request DNT suppresses route observations, including Tasks, but not account imports.

First touch and pageviews record UTM source, medium and campaign (64-character slugs), referrer host, page and `locale`.
They record no raw URLs, query fields, content or click IDs. Respect DNT. Downloads do not prove installs.
Website pageviews copy the referrer host to `$referring_domain` (`$direct` if none) for web analytics.
Only the web app sets a User's first touch. Registrations name a reported sign-in `client_kind` and `client_platform`.
A contact form send records its page and an attempt to open the email app, not its answers or a sent email.

Marketing reports use full UTC+8 days from production. Use `build_sha`. Activation joins Message IDs to `source_message_id`. D7 needs seven cohort days.

Desktop events count new and existing profiles, version changes and repeats, not installs.
Reloads deduplicate locally. Reinstalls keep state. Cleared profiles count as new. DNT and errors lose events.

## Diagnosis order

### Service diagnostics

Helm owns monitoring resources. Never raw-apply or delete them as an improvised rollback.
See [Release operations](release-operations.md).

### Mention to first reply

`salix_agent_message_*` measures a person's Slack, Feishu or Lark @mention from the provider's source time to the first provider-confirmed message in its thread or sent for that source ([SalixIM.MentionReplyLatency](../systems/apps/salix_im/lib/salix_im/mention_reply_latency.ex)).
Every pod keeps the same bounded in-memory table of pending mentions. Sum the counters and the histogram, and read the pending age from pods whose coverage is 1 and whose `observed_at` is fresh.
Coverage is 0 on a pod until it copied the table from a complete peer or its window has run for the one-hour retention. An incomplete peer hands on its table and window, so a rolling restart usually keeps both.
This transfer is best effort. A peer of an older release has no window to give, and a timeout or a lost peer can miss it. Then the mentions that peer held are lost with no signal and a new window starts.
Missing telemetry never shows that a mention was answered.
A provider's coverage is also 0 for an hour after a lost measurement, which `salix_agent_message_latency_invalid_total` counts by `reason`: no usable source time, a reply with no usable time or place, no room in the table, or no reply within the hour (`expired`), when the mention leaves the gauge.
Per pod, `observed_at` moves only while that provider's coverage is 1, so join them on the pod. A failover can lose or repeat a sample.

### QQ delivery timing

Filter JSON stdout by `msg="qq_delivery_timing"` and group by `correlation_id` or the existing trace context.
Each QQ callback and each `qq.send_message` writes one log when it ends.
It names its `direction` (`ingress` or `send`), `started_at_ms`, total `duration_ms`, `outcome`, and `phases`.
Each phase entry has `phase`, `offset_ms` from the start, `duration_ms`, and `outcome`, in completion order.
A log keeps at most 64 phases and counts the rest in `phases_dropped`.
Durations use the local monotonic clock. Nested phases are inclusive: `router_enqueue` contains the admission phases after it, and `access_token` contains `token_http`.
The log runs in a correlation context. When the caller has none, it starts one, which later Conversation and Session work inherits.

Unattributed callbacks write no timing log: an unknown bot or a rejected signature. The `im_ingress` metric still counts them.
After signature verification, a message callback adds `source_sent_at_ms`, `handler_started_at_ms`, and their signed difference, `source_to_handler_ms`.
The handler starts at `ProviderHTTP.handle_qq_request`, after HTTP body parsing.
This difference includes upstream delivery and parsing. QQ timestamp precision and clock skew apply. It is not pure network latency.

Ingress phases separate connect lookup, verification, message recording, chat observation, mention context, group checks, control commands, Router resolution, attachments, payload preparation, and Conversation admission.
`conversation_append` ends when the Conversation call returns. Later asynchronous Session delivery uses the existing Session arrival timestamps.
A button callback acknowledges the tap through the QQ API, so its ingress log also has `access_token` and `api_http`.
Send phases cover Agent scope, connect authorization, upload preparation, file part uploads, quote lookup, reply reservation, access tokens, HTTP, and local send records (`sent_message_record`, `sent_reference_record`, `platform_message_record`).
`token_http` runs only when a token needs renewal. Each `api_http` entry covers one API attempt, including response decoding. A failed send records no local send record.
An API or tool success does not prove that the QQ client displayed the reply.
These logs contain no message content, provider identifiers, request bodies, credentials, or error text. Logging failures do not change operation results.

## Encrypted Agent event archive

Preserve six observation seams:

1. Inbound input.
2. Provider request.
3. Provider response.
4. Tool dispatch.
5. Tool result.
6. Visible reply.

Encrypt in the caller before data enters the archive path.
Do not put plaintext in archive mailboxes, logs, or metrics.
The archive is observational. Its failure cannot fail the Agent's task. Bound its queues and retry work.

A sequence hole proves bracketed loss when later events arrive. Tail loss or process loss can leave no live signal.
Do not claim complete capture or guaranteed loss detection from a contiguous observed prefix.
An archive record proves the observed seam, not external receipt or user consumption.

## Alert ownership

Cloud Monitoring and Grafana own evaluation and the source incident lifecycle for their rules.
A notification router formats and routes those decisions. It is not another incident engine.
It must not independently trigger, merge, recover, or close a source incident.
A source CLOSED or RESOLVED event does not verify service recovery.

Keep source-native notification fallback independent of router failure.
The router's delivery-health alert must bypass the router.
Do not remove Grafana direct Slack without an approved source-native fallback.

Runtime terminal failures, request stalls, IM ingress, OOM, and deployment failures have distinct owners and evidence.
Use the exact current rule and its source labels. Do not parse prose to recover identity.
`/health`, the login page and the replica count can stay healthy while the product API fails: `comma_alerting:comma_api_5xx` (P1) watches the 5xx ratio of each `/v1/comma/*` route.
Alert status changes update the same incident-generation presentation and keep useful lifecycle events.
Do not repeat notifications for unchanged state.

### Slack cards and investigation progress

A root card shows what happens now (the measured value, where it fires, the threshold), the impact, and the policy's reviewed first checks. Times are UTC+8.
A source closure shows `指标已回落`. It does not claim recovery.

`我来处理` lets a Slack user claim an unassigned Incident. Only the current owner can transfer it.
Callbacks check the configured workspace and app, the exact channel and root, and the card revision. Source events cannot replace the owner.
Claims, transfers, explicit reports, and quality feedback send compact channel updates with a root link and no mention.
Shadow updates stay in the thread. All updates reuse the existing delivery lease, marker, and uncertain-result reconciliation.
Attributed feedback accepts `需要行动`, `自愈`, or `误报`. Source refreshes preserve it.
Feedback changes no source status, recovery verification, priority, or reminder deadline. Review source evidence before you change rules.

Configure the Alert Router Slack app:

1. Set `SLACK_SIGNING_SECRET`, `SLACK_TEAM_ID`, and `SLACK_APP_ID` in `alert-router-slack-<environment>`.
2. Set the Events API URL to `/v1/events/slack` on that environment.
3. Subscribe to `message.channels` with `channels:history`.
4. Join the alert channel.
5. Enable Interactivity at `/v1/interactions/slack` on that environment.
6. In an approved test channel, verify reports, claims, transfers, overdue reminders, and cancellation before live use.

The release bundle copies only the signing secret, team ID, app ID, and bot token into the dedicated Router config.
The config keys are `alert_router.slack.signing_secret`, `team_id`, and `app_id`.
Environment alternatives are `ALERT_ROUTER_SLACK_SIGNING_SECRET`, `ALERT_ROUTER_SLACK_TEAM_ID`, and `ALERT_ROUTER_SLACK_APP_ID`.

The adapter verifies the Slack raw-body signature and five-minute timestamp before parsing. Unsigned callbacks fail.
Progress ingress also requires the configured workspace and app and an existing root in the reported channel.
Reporter claims stay unverified reports. The optional path stays closed until configured. Source ingestion stays available.
Binary rollback keeps report, revision and feedback fields.
These callbacks do not implement automatic source investigation, Jev decisions, or human recovery verification.

## Routine job queues

Generation uses the finite `comma_recommendations` queue label.
Deadlines and schedule reconciliation use `comma_recommendation_control`.
Existing Oban execution and backlog metrics expose those queues.
See [Routine generation](product-features.md#routine-generation) for deadlines and recovery limits.

## Cloud VM archive operations

Use the Container stderr log for archive errors. Access the exact running Container through Worker Sandbox SSH.
Connector export and import status includes optional phase timings. These are diagnostics, not retained recovery facts.
Read the current operation through `GET /v1/admin/vm/archive/operation?group_id=GROUP&operation=OPERATION` with existing admin authorization.
The response reports current progress and cancellation state, or the owner's last operation result.
Use that result for cancellation or same-operation recovery. Salix stores no second history of timing summaries.
A Container that stops by itself loses its disk: Salix logs one `cloud_vm_container_lost` event (`reason` is `rollout`, `exit_code` or `unknown`, never the provider's message) and counts it in `salix_vm_container_loss_total`.
CF retirement removes its disk-loss alert. The counter has no `zero_series`, so its first event on a Pod is invisible to `increase()`.
`salix_vm_wake_duration_seconds` times every wake attempt by outcome; `comma_alerting:cloud_vm_wake_slow` pages in staging when the p95 of `ok` wakes over an hour passes 120 seconds (a normal wake is about 10 seconds) or one failed outcome counts three attempts in 30 minutes.
`salix_vm_transitional_oldest_age_seconds` is the age of the oldest record in `creating`, `waking`, `archiving` or `failed`, by provider and state; `comma_alerting:cloud_vm_stuck_state` pages in staging when it passes an hour for 10 minutes in a state other than `failed`, because the reconciler retries such a record and tells no one. A `failed` record is not retried: it changes only when its Group next uses the Cloud VM, so the alert leaves it out.

## Sandbox operations

A sandbox Task's sandbox is one L4ES VM per Task ([coding sandboxes](compute-devices.md#coding-sandboxes)); `SalixWeb.CodingSandboxes` keeps its state on the Task's Compute Workload.
`salix_sandbox_start_duration_seconds{kind, outcome}` times each start from `starting` to the station's connection (`ok`) or to giving up (`failed`): `create` is a Task's first sandbox, `wake` one started again from its disk for a Message.
`salix_sandbox_ends_total{state}` counts runs that ended: `stopped` (idle), `lost` (L4ES no longer ran it), `failed`, `ended` (the Task did).
`salix_sandbox_records{state}` and `salix_sandbox_starting_oldest_timestamp_seconds` are the fleet, from one aggregate query (max across pods). Each node publishes them once a minute, after a check pass. The timestamp is when the oldest `starting` record started, or the publish time with none. Its age is `time()` minus the value, so the age also grows when no node publishes. The checks give up a start at 5 minutes, so an age past that means the checks do not reach a start or no node publishes.
`salix_station_tasks_lost_thread_total{kind}` counts stations invited to a Task again because they had no thread of it; for a sandbox, a disk L4ES gave up (it started empty) or a lost station state.
The start histogram, `salix_sandbox_ends_total` and the `salix_station_tasks_*` counters and histogram read 0 from process start for each label value except `other`.
The Grafana Salix Runtime dashboard has a Sandbox row. Staging pages on four sandbox policies:

- `comma_alerting:sandbox_start_failed` (P2): three failed starts in 30 minutes, summed across Pods. It catches a Task whose sandbox fails to start again and again. On 2026-10-29 a Task's own failure notice woke its sandbox again and made 802 failed starts in 40 hours.
- `comma_alerting:sandbox_lost` (P2): a run recorded `lost` in the last hour. L4ES ended the sandbox outside Comma.
- `comma_alerting:sandbox_start_slow` (P3): the p90 of successful `wake` starts over an hour passes 120 seconds, from `starting` to the station's connection.
- `comma_alerting:sandbox_checks_stalled` (P2): that age stays above 300 seconds for 10 minutes. The check loop does not end overdue starts, or every node's loop stopped. It also fires when no node published the timestamp in 5 minutes, then 10 more, while `salix_sandbox_ends_total` exists. This catches new nodes whose first pass hangs or whose pass crashes every time. An environment without the sandbox code has no such counter and stays quiet. One stuck node does not fire it while another node publishes.

`comma_alerting:station_task_stalled` pages for `place=sandbox` as for the Cloud VM, in staging and production ([station Tasks](salix/tasks-background-execution.md#station-tasks)).

L4ES (`l4es.afk.surf`) is one production cluster that serves both Comma environments. Production probes it every minute from three regions:

- `comma_alerting:l4es_ready_uptime` (P1): `/readyz` does not answer `ready`. The control-plane VM or its serving slot is down. Running sandboxes keep running, but new sandboxes, wakes, SSH and web sessions fail.
- `comma_alerting:l4es_cluster_uptime` (P2): `/cluster-ok` is absent. A timer on the control VM (`l4es-health`) computes cluster health every minute. It writes this file only while every check passes: both nodes are active, no sandbox is pending over 2 minutes, no start failed for capacity in the last hour, one node's worth of slots is free, a serving slot answers, and an off-site database backup ran in the last 26 hours. The VM keeps the reasons in `/var/lib/l4es/health/status.txt`. The timer and the `/cluster-ok` route are in `AFK-surf/l4h-sandbox` under `deployments/latitude-sh-l4es/control`. The policy was pending until `/cluster-ok` first returned 200 (2026-11-03, after the first off-site backup), because an open incident hides new failures. The [L4ES cluster runbook](https://github.com/AFK-surf/l4h-sandbox/blob/main/deployments/latitude-sh-l4es/CLUSTER.md) covers a node that fails.

## Task Schedules

`SalixCluster.Schedules` appends a scheduled Task's command when its Schedule fires. A scheduled sandbox Task stays `active` after its turn ends, so it keeps firing ([Station Tasks](salix/tasks-background-execution.md#station-tasks)).

### Task Schedule lifecycle

A Task's Schedule definition lives as long as the Task's binding (`schedule.schedule_id`). The Task's status only gates firing:

| Task status at a due window | Receiver answer | Effect |
| --- | --- | --- |
| `active` | `fired` | The command is appended; the anchor advances. |
| `escalated`, `failed`, `ready_for_review`, or any other status that is not an end | `paused` | Nothing is appended; the anchor advances; the definition stays. Logged as `task_schedule_paused` with `task_status`, once per window. Back to `active`, the Task fires at its next window. |
| `completed`, `cancelled` | `inactive` | The Task is unbound (`schedule_id` becomes `nil`, through `update_task_schedule`) and the definition is deleted. |
| Binding cleared (archive, `schedule: null`) or Task deleted | `inactive` | The definition is deleted. |
| Bound to another Schedule | `settled` | This definition is deleted; the Task keeps its binding. |

Every deletion is logged as `task_schedule_deleted` with `group_id`, `conversation_id`, `schedule_id`, `reason` (`inactive`, `settled`, `not_found`) and `unbound`. In Cloud Logging, filter `jsonPayload.event="task_schedule_deleted"`.
`failed` is not an end: the Router sets it after one failed run and `active` when the work resumes. A scheduled Task in `ready_for_review` stays paused until its Router sets `active`; review acceptance does not apply to it.

### Rebuild a lost Task Schedule

A scheduled Task that does not fire, with `status` `active` and a `schedule_id`, may point at a definition that is gone. Before this rule, a firing on a Task that was not `active` (for example `escalated` after a `task_worker_stopped` notice) deleted the definition and left the binding. Check and rebuild it over `bin/comma rpc` on a `comma-*` pod:

```elixir
{:ok, task} = SalixIM.Conversations.get_group_conversation(group, conversation_id)
%{"status" => "active", "schedule" => %{"schedule_id" => schedule_id}} = task
SalixCluster.Schedules.get(schedule_id)
```

`{:error, :not_found}` is the lost definition. Rebuild it with the Task's recurrence; the Task keeps its `schedule_id` and the command:

```elixir
{:ok, _task} = SalixCluster.TaskSchedules.update_task_schedule(group, conversation_id, %{"interval_minutes" => 180})
{:ok, definition} = SalixCluster.Schedules.get(schedule_id)
SalixCluster.Schedules.next_fire_ms(definition)
```

The first window is one interval after the rebuild.
