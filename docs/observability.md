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
Website pageviews also send the referrer host as `$referring_domain` (`$direct` without one), which PostHog web analytics reads.
A website contact form submission records only its page, not its answers. It records an attempt to open the email app. It does not confirm that the app opened or the email was sent.

Marketing reports use full UTC+8 days from production. Use `build_sha`. Activation joins Message IDs to `source_message_id`. D7 needs seven cohort days.

Desktop events count new and existing profiles, version changes and repeats, not installs.
Reloads deduplicate locally. Reinstalls keep state. Cleared profiles count as new. DNT and errors lose events.

## Diagnosis order

### Service diagnostics

Helm owns monitoring resources. Never raw-apply or delete them as an improvised rollback.
See [Release operations](release-operations.md).

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
Alert status changes update the same incident-generation presentation and keep useful lifecycle events.
Do not repeat notifications for unchanged state.

### Slack cards and investigation progress

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
A Container that stops by itself loses its disk: Salix logs one `cloud_vm_container_lost` event (`reason` is `rollout`, `exit_code` or `unknown`, never the provider's message) and counts it in `salix_vm_container_loss_total`; the staging policy `comma_alerting:cloud_vm_container_lost` pages on the event, because a rare counter's first sample on a pod is invisible to `increase()`.
`salix_vm_wake_duration_seconds` times every wake attempt by outcome; `comma_alerting:cloud_vm_wake_slow` pages in staging when the p95 of `ok` wakes over an hour passes 120 seconds (a normal wake is about 10 seconds) or one failed outcome counts three attempts in 30 minutes.
`salix_vm_transitional_oldest_age_seconds` is the age of the oldest record in `creating`, `waking`, `archiving` or `failed`, by provider and state; `comma_alerting:cloud_vm_stuck_state` pages in staging when it passes an hour for 10 minutes in a state other than `failed`, because the reconciler retries such a record and tells no one. A `failed` record is not retried: it changes only when its Group next uses the Cloud VM, so the alert leaves it out.

## Cloud VM canary

The canary proves every 30 minutes that staging can give a Task to a Group's Cloud VM and get an answer back.
It is one scheduled Task in a Workspace made for it. Nothing else is new.
`SalixCluster.Schedules` appends the command to the Task when the schedule fires.
`SalixWeb.StationTasks` gives the Message to the VM's station (`task.put`) and wakes an archived VM.
`SalixIM.StationTaskWatch` times the station's first reply ([Station Tasks](salix/tasks-background-execution.md#station-tasks)).

A Task of a Group named in `station_task_watch.canary_group_ids` carries `canary: true` in its `station_task_stalled`, `station_task_recovered` and `station_task_stale` events.
Its samples carry `canary="true"` in `salix.station_tasks.stalled.total` and `salix.station_tasks.first_reply.seconds`. Every other station Task carries `false`.

The canary does not prove that a Router hands a result to a person. It does not prove production: production has no canary Workspace, so the two canary policies are staging-only.

### Set up

Do these steps in this order. `station_task_canary_silent` fires from its release until the canary has answered twice.

1. In staging, create a Workspace for the canary only. Turn its Cloud VM on in Settings > Models. Bind no Runner. Choose a cheap Router model.
2. The Cloud VM need not be running: a Task made while it sleeps wakes it and is given to it once it is up.
3. Create a Worker bound to the Cloud VM and its scheduled Task. Ask the Workspace's Router in its chat, for example: "Create a Worker named Canary that runs on the Cloud VM. Give it a Task that repeats every 30 minutes with this command: This is the Cloud VM canary. Reply with chat_post and all_done. Write only the current UTC time and the host name. Do nothing else."
   The Router calls `agent.create_worker` with `runtime {"kind": "cloud_vm"}` and `im_api.internal.task.create` with `schedule {"interval_minutes": 30}`. A bound Worker runs every Task on the VM, so the Task names no `runs_on`.
   Or create the Task over `bin/comma rpc` on a `comma-*` pod, after the Worker exists. This path skips the Router's checks of the place and the model:

   ```elixir
   group = "grp1_..."

   Salix.Bindings.AgentConversations.create_task_conversation(group, router_agent_id, worker_agent_id, %{
     "content" => "This is the Cloud VM canary. Reply with chat_post and all_done. Write only the current UTC time and the host name. Do nothing else.",
     "client_request_id" => "cloud-vm-canary",
     "schedule" => %{"interval_minutes" => 30},
     "runs_on" => %{"kind" => "station", "device_id" => SalixStore.RuntimeIds.cloud_vm_device_id(group)},
     "session_model" => %{"kind" => "runtime", "provider" => "codex"}
   })
   ```

4. Check the Task and the station over rpc:

   ```elixir
   {:ok, task} = SalixIM.Conversations.get_group_conversation(group, conversation_id)
   Map.take(task, ~w(status schedule task_worker_agent_id))
   SalixStore.StationTaskSessions.of_task(group, conversation_id)
   ```

   `status` is `active` and `schedule` has a `schedule_id`. `of_task` has one row whose `device_id` is `SalixStore.RuntimeIds.cloud_vm_device_id(group)`; its `sent` and `answered` grow with each firing.
5. Add the Group to the config secret and roll it out: `"station_task_watch": {"canary_group_ids": ["grp1_..."]}` in `/etc/salix/config.json` (`SalixStore.ConfigJson`). The section also takes the stage thresholds in milliseconds.
6. Release the two policies from `k8s/comma/cloud-monitoring`.

### Alerts

| Policy | Fires when | Delay after a break |
| --- | --- | --- |
| `comma_alerting:station_task_canary_stalled` (P2, log) | A canary delegation reaches a stage threshold without a reply: `vm_not_ready`, `station_offline` or `not_given` after 10 minutes; `idle_no_reply` once the station's Session sat idle 10 minutes, was reminded, and sat idle 10 minutes more; `cannot_start` after 10 minutes; `given_no_reply` (a station that cannot say) after 30 minutes. The stage names the broken segment. | About 40 minutes for the first three stages, about 50 for `idle_no_reply` and about 60 for `given_no_reply`: the next firing plus the threshold. |
| `comma_alerting:station_task_canary_silent` (P2, PromQL) | `salix_station_tasks_first_reply_seconds_count{canary="true"}` grew by less than one in two hours, or does not exist. | About two hours. |

`station_task_canary_silent` also fires when the schedule does not fire (the Task's schedule cleared, the Task closed or archived), when every firing stalls (then `station_task_canary_stalled` fires too and names the stage), and when `canary_group_ids` is empty or names the wrong Group.
A counter born at its first answer shows no increase, so the alert closes after the second answer.

### Cost and pause

Each firing wakes the archived Cloud VM, runs one short turn, and the VM archives again after 5 idle minutes (`idle_archive_ms`): 48 wakes a day of about 6 to 8 minutes of container time each.
The Router runs one round on the reply. The station's Worker spends a few hundred tokens of the platform model each time.

To pause the canary, clear the Task's schedule (`SalixCluster.TaskSchedules.update_task_schedule(group, conversation_id, nil)`) or archive the Task. `station_task_canary_silent` fires two hours later.
To end it, archive the Task and remove the Group from `canary_group_ids`.

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
{:ok, _task} = SalixCluster.TaskSchedules.update_task_schedule(group, conversation_id, %{"interval_minutes" => 30})
{:ok, definition} = SalixCluster.Schedules.get(schedule_id)
SalixCluster.Schedules.next_fire_ms(definition)
```

The first window is one interval after the rebuild.

### Acceptance

After the config is live and the Task has fired twice, `salix_station_tasks_first_reply_seconds_count{canary="true"}` has samples in Metrics Explorer and `station_task_canary_silent` is closed.
Pause the schedule for more than two hours: `station_task_canary_silent` opens. Restore it: the alert closes after the second answer.
