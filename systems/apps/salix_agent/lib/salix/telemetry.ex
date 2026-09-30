defmodule Salix.Telemetry do
  @moduledoc "Salix-owned telemetry metrics and bounded emitters."
  import Telemetry.Metrics

  @http [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  @operation [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]
  @llm [0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]
  @vm [0.1, 0.5, 1, 2.5, 5, 10, 30, 60, 120, 300, 600]
  @voice_call [1, 5, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]
  @voice_transports ~w(twilio websocket other)
  @voice_call_reasons ~w(completed caller_hangup agent_hangup busy timeout model_error carrier_error revoked draining other)
  @voice_delegation_outcomes ~w(answered failed abandoned other)
  @voice_profile_outcomes ~w(ok empty timeout not_configured no_evidence egress_denied rate_limited error other)
  @actor_queue [0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]
  @outcomes ~w(ok partial ignored error failed timeout in_doubt dropped unavailable unroutable unattributed conflict rejected cancelled cleaned retained scan_error over_budget dispatched already skipped other)
  @component_operations %{
    # loop_*: Agent background Loops (docs/salix/tasks-background-execution.md).
    # loop_host_call answers whether guest capability calls succeed, are
    # refused (rejected), rate limited (over_budget) or time out; loop_notify
    # whether Session wakes land or dedupe (already); loop_event whether the
    # ingress admits, dedupes or drops (mailbox full); loop_build whether the
    # embedded compiler produces artifacts; loop_reconcile whether adoption
    # loads every Loop (partial, over_budget = node capacity); loop_host_restart
    # counts spinfoam child restarts (alert past 5/h).
    # round_config_refresh: how long background configuration reads take and
    # whether failures are keeping sessions on their previous snapshots.
    # external_session_migration: do bounded operator steps finish, or fail
    # while the Agent creation freeze remains in place? IDs stay out of labels.
    # decide: do runtime classifiers fail, hit budgets, or exceed expected latency?
    # web_http_request: do agent-authored API calls (`web.http_request`) get
    # answers (ok), get refused by the remote (rejected = 4xx, failed = 5xx),
    # or never complete (timeout, error = transport)? URLs stay out of labels.
    # browser_command: are browser commands completing, and how long do they take?
    # browser_storage_checkpoint: are background saves failing or exceeding their time budget?
    # ssh_connect: do Agent SSH connections open (ok), fail trust or key
    # authentication (rejected), fail to reach or negotiate with the host
    # (failed, timeout), or lack Group key or host key storage (unavailable)?
    # ssh_connect_tailcat: the same for connections through the Tailcat gateway;
    # rejected also counts refused addresses and relays, unavailable also a
    # missing gateway or a full one. Hosts, users, addresses and fingerprints
    # stay out of labels.
    "salix_agent" =>
      ~w(browser_command browser_storage_checkpoint conversation_log_consume conversation_log_admit ifc_decide external_session_migration round_config_refresh session_kernel session_history_recent session_history_index session_history_discovery activation round lease claim schedule prepared_blob_cleanup external_runtime_event_batch provider_reply_obligation_rejection router_wait_yield session_work_notification_admission session_work_notification_wake loop_host_call loop_notify loop_event loop_build loop_reconcile loop_host_restart spinfoam_build script_run web_http_request ssh_connect ssh_connect_tailcat decide other),
    "salix_env" =>
      ~w(connector_metadata connector_heartbeat runtime_auth_read runtime_auth_status runtime_auth_verify runtime_auth_login_start runtime_auth_login_cancel runtime_auth_input_begin runtime_auth_input_submit runtime_auth_input_cancel other),
    "salix_calendar" => ~w(source_sync source_transition watch other),
    "salix_meet" =>
      ~w(calendar_enrollment calendar_enrollment_group calendar_scan calendar_scan_group calendar_join calendar_join_group calendar_join_dispatch calendar_join_dispatch_skip meeting_artifact meeting_asr meeting_delivery meeting_delivery_claim meeting_runtime_late_event meeting_watchdog meeting_stuck_nonterminal other),
    "salix_mcp" => ~w(tool mcp other),
    # conversation_log_recovery: are indexed candidates completing, retained, or failing?
    # conversation_log_recovery_claim: can each Pod discover due work within its poll budget?
    # provider_log_delivery measures platform send/verification latency and failures.
    # Which internal send stage accounts for latency or failure? Queue timing is local only.
    # Placement, call and actor are nested totals; do not sum all stages.
    "salix_im" =>
      ~w(conversation_log_recovery conversation_log_recovery_claim provider_log_delivery im_send_total im_send_authorize im_send_conversation im_send_attachments im_send_participant im_send_placement im_send_call im_send_queue im_send_actor im_send_membership im_send_sender im_send_sender_fence im_send_prepare im_send_commit im_send_delivery im_send_result im_ingress provider_poll imessage_receive imessage_request telegram_send_message private_chat_status private_chat_status_start telegram_interaction_prompt telegram_interaction_response telegram_interaction_card slack_api_retry slack_task_card control_command conversation_search_delete_admission other),
    "salix_store" =>
      ~w(store_get store_put store_list compute_mutation compute_migration service_route other),
    # The agents' `/drive` mount: every list, read, write, delete and status
    # call to the Synchronicity control plane (`Salix.Drive.Files`).
    # Does automatic subscription delivery fail or exceed its execution budget?
    "salix_web" => ~w(drive_files remote_shell subscription_runtime_delivery other),
    # Analytics read families. One label per query shape, not per call site:
    # this covers Runtime Health dashboard reads and bounded background reads
    # against the same ClickHouse seam.
    "salix_analytics" => ~w(
      run_outcomes round_trends unknown_trends failed_rounds unconverged_sessions
      tool_rates tool_latency tool_error_types tool_top_sessions
      llm_overview llm_reliability llm_speed llm_trends
      error_overview deploy_rates session_costs session_trace activity_trace
      convergence_drift trajectory_eval slack_mirror_search other
      slack_mirror_tail slack_mirror_changes slack_mirror_latest_states
      slack_mirror_thread slack_mirror_thread_reactions
      slack_semantic_search slack_message_search slack_semantic_index slack_semantic_file_index
      slack_semantic_enqueue slack_semantic_reconcile
    ),
    "salix_cluster" =>
      ~w(schedule cluster_membership placement drain session_work_recovery session_work_notification_connection session_work_notification_catch_up session_work_notification_dispatch other),
    "other" => ["other"]
  }
  @vm_operations ~w(provision wake archive provider_request connector recovery other)
  @vm_providers ~w(sprites cloudflare other)
  @vm_states ~w(pending claiming running ready waking archiving archived failed stuck other)
  @vm_record_cache_outcomes ~w(hit miss error other)
  @router_inbox_outcomes ~w(queued unauthorized invalid not_found router_not_configured rate_limited unavailable other)
  @vm_record_batch_outcomes ~w(ok error other)
  @vm_record_persist_outcomes ~w(ok conflict ambiguous_settled indeterminate error other)
  @external_status_projection_outcomes ~w(ok failed other)
  # Implementation names are registered here as their PRs land (the finite
  # label contract); unregistered names normalize to "other".
  @convergence_names ~w(other)
  @convergence_outcomes ~w(ok partial error other)
  @settlement_modes ~w(cas create_once other)
  @settlement_outcomes ~w(ok created landed exists precondition_failed indeterminate error other)
  @im_identity_providers ~w(slack feishu other)
  @im_identity_resolutions ~w(fast_hit fallback_hit fallback_miss rejected error other)
  @dependency_job_kinds ~w(llm compaction external_runtime tool other)
  @dependency_job_outcomes ~w(ok error timeout saturated cancelled crashed other)
  @connector_external_event_outcomes ~w(
    accepted queued duplicate cache_hit conflict timeout completed terminal retry saturated cancelled other
  )
  @connector_transports ~w(websocket sprites cloudflare other)
  @connector_pending_rpc_outcomes ~w(
    accepted completed cancelled caller_down timeout saturated conflict socket_closed late_reply other
  )
  @connector_read_stream_outcomes ~w(
    accepted completed error cancelled caller_down timeout saturated conflict socket_closed other
  )
  @connector_write_stream_outcomes ~w(
    accepted completed error cancelled caller_down timeout saturated conflict socket_closed aborted other
  )

  def metrics do
    operation_options = [
      event_name: [:salix, :operation, :stop],
      tags: [:component, :operation, :surface, :outcome],
      tag_values: &operation_tags/1
    ]

    vm_operation_options = [
      event_name: [:salix, :vm, :operation, :stop],
      tags: [:surface, :provider, :operation, :outcome],
      tag_values: &vm_operation_tags/1
    ]

    llm_options = [
      tags: [:surface, :provider, :model_key, :outcome],
      tag_values: &llm_tags/1
    ]

    reporting_options = [tags: [:sink], tag_values: &sink_tags/1]
    recovery_options = [tags: [:surface, :provider, :state], tag_values: &vm_state_tags/1]

    [
      # How often does optional selection fail, and how much dispatch wait/context does it add?
      counter("salix.miniskill.total",
        event_name: [:salix, :miniskill, :stop],
        tags: [:outcome],
        tag_values: &miniskill_tags/1
      ),
      distribution("salix.miniskill.duration.seconds",
        event_name: [:salix, :miniskill, :stop],
        measurement: :duration,
        unit: {:native, :second},
        reporter_options: [buckets: @http]
      ),
      distribution("salix.miniskill.wait.seconds",
        event_name: [:salix, :miniskill, :stop],
        measurement: :wait,
        unit: {:native, :second},
        reporter_options: [buckets: @http]
      ),
      distribution("salix.miniskill.instructions.bytes",
        event_name: [:salix, :miniskill, :stop],
        measurement: :bytes,
        reporter_options: [buckets: [0, 2048, 4096, 8192, 10240]]
      ),
      distribution("salix.miniskill.selected.count",
        event_name: [:salix, :miniskill, :stop],
        measurement: :selected,
        reporter_options: [buckets: [0, 1, 2, 3, 4, 5, 10, 25, 100]]
      ),
      # Is pressure blocking new internal sessions, and did eviction stop
      # because the previous batch did not reduce actual container charge?
      last_value("salix.session.residency.resident",
        event_name: [:salix, :session_residency, :sample],
        measurement: :resident
      ),
      last_value("salix.session.residency.pressure",
        event_name: [:salix, :session_residency, :sample],
        measurement: :pressure
      ),
      last_value("salix.session.residency.stalled",
        event_name: [:salix, :session_residency, :sample],
        measurement: :stalled
      ),
      last_value("salix.session.residency.observed_at.seconds",
        event_name: [:salix, :session_residency, :sample],
        measurement: :observed_at
      ),
      last_value("salix.router.requests.stalled",
        event_name: [:salix, :router_requests, :sample],
        measurement: :stalled
      ),
      last_value("salix.router.requests.pending",
        event_name: [:salix, :router_requests, :sample],
        measurement: :pending
      ),
      last_value("salix.router.requests.observed_at.seconds",
        event_name: [:salix, :router_requests, :sample],
        measurement: :observed_at
      ),
      last_value("salix.router.requests.observation_drops",
        event_name: [:salix, :router_requests, :sample],
        measurement: :dropped
      ),
      # How far behind is an observed Conversation source, and how old is its first unread record?
      # These histograms sample bounded drains. They do not measure unseen sources.
      distribution("salix.conversation.log.backlog",
        event_name: [:salix, :conversation_log, :sample],
        measurement: :backlog,
        reporter_options: [buckets: [0, 1, 8, 32, 128, 512, 2048]]
      ),
      distribution("salix.conversation.log.recovery_age.seconds",
        event_name: [:salix, :conversation_log, :sample],
        measurement: :age,
        unit: {:millisecond, :second},
        reporter_options: [buckets: @operation]
      ),
      # How long did a completed display projection lag its authoritative update?
      distribution("salix.conversation.log.projection_lag.seconds",
        event_name: [:salix, :conversation_log, :projection],
        measurement: :lag,
        unit: {:millisecond, :second},
        reporter_options: [buckets: @operation]
      ),
      counter("salix.operations.total", operation_options),
      distribution(
        "salix.operations.duration.seconds",
        operation_options ++
          [
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @operation]
          ]
      ),
      # Connector observations include Cloud VM idle checks. Their errors and
      # duration identify provider hold or quiet failures that prevent sleep.
      counter("salix.vm.operations.total", vm_operation_options),
      distribution(
        "salix.vm.operations.duration.seconds",
        vm_operation_options ++
          [measurement: :duration, unit: {:native, :second}, reporter_options: [buckets: @vm]]
      ),
      distribution(
        "salix.vm.idle_archive.start_delay.seconds",
        event_name: [:salix, :vm, :idle_archive, :start],
        measurement: :delay_seconds,
        tags: [:profile],
        tag_values: &vm_profile_tags/1,
        reporter_options: [buckets: [1, 5, 15, 30, 60, 120, 300, 600]]
      ),
      counter(
        "salix.llm.requests.total",
        llm_options ++ [event_name: [:salix, :llm, :request, :stop]]
      ),
      counter(
        "salix.llm.attempts.total",
        llm_options ++ [event_name: [:salix, :llm, :attempt, :stop]]
      ),
      distribution(
        "salix.llm.attempt.duration.seconds",
        llm_options ++
          [
            event_name: [:salix, :llm, :attempt, :stop],
            measurement: :duration,
            unit: {:native, :second},
            reporter_options: [buckets: @llm]
          ]
      ),
      distribution(
        "salix.llm.ttft.seconds",
        llm_options ++
          [
            event_name: [:salix, :llm, :attempt, :stop],
            measurement: :ttft_duration,
            keep: &ttft?/1,
            unit: {:native, :second},
            reporter_options: [buckets: @llm]
          ]
      ),
      sum("salix.llm.tokens.total",
        event_name: [:salix, :llm, :usage],
        measurement: :value,
        tags: [:surface, :provider, :model_key, :kind],
        tag_values: &llm_usage_tags/1,
        reporter_options: [prometheus_type: :counter]
      ),
      last_value(
        "salix.reporting.queue.depth",
        reporting_options ++ [event_name: [:salix, :reporting, :queue], measurement: :depth]
      ),
      # Count rejected rows, including drops while the writer is blocked.
      sum(
        "salix.reporting.queue.full.total",
        reporting_options ++
          [
            event_name: [:salix, :reporting, :queue_full],
            measurement: :value,
            reporter_options: [prometheus_type: :counter]
          ]
      ),
      distribution("salix.reporting.flush.duration.seconds",
        event_name: [:salix, :reporting, :flush],
        measurement: :duration,
        tags: [:sink, :outcome],
        tag_values: &reporting_result_tags/1,
        unit: {:native, :second},
        reporter_options: [buckets: @http]
      ),
      sum(
        "salix.reporting.dropped.rows.total",
        reporting_options ++
          [
            event_name: [:salix, :reporting, :drop],
            measurement: :value,
            reporter_options: [prometheus_type: :counter]
          ]
      ),
      # The Slack message mirror's webhook path has exactly one way to lose an
      # event — the outbox insert failing — and this counter is the only signal
      # of it. It cannot share the reporting counter above: that one's `sink`
      # label is normalized against a finite set the mirror is not in, so its
      # drops would arrive as "other".
      sum(
        "salix.slack_mirror.dropped.rows.total",
        event_name: [:salix, :slack_mirror, :dropped],
        measurement: :count,
        tags: [:reason],
        tag_values: &slack_mirror_drop_tags/1,
        reporter_options: [prometheus_type: :counter]
      ),
      # Outbox drain, per batch: rows that reached ClickHouse versus rows held
      # back for a retry. A `failed` series with `drained` flat is a ClickHouse
      # outage or a row ClickHouse rejects; nothing is lost either way.
      sum(
        "salix.slack_mirror.outbox.rows.total",
        event_name: [:salix, :slack_mirror, :outbox, :batch],
        measurement: :count,
        tags: [:outcome],
        tag_values: &slack_mirror_outbox_tags/1,
        reporter_options: [prometheus_type: :counter]
      ),
      # Age of the oldest event still waiting in the outbox, sampled by each
      # Pod's drainer. This is the mirror's freshness: a reader is behind Slack
      # by at most this much.
      last_value("salix.slack_mirror.outbox.oldest.age.seconds",
        event_name: [:salix, :slack_mirror, :outbox, :lag],
        measurement: :oldest_age_seconds
      ),
      # One increment per backfill pass over one Slack installation. `more`
      # means history is left and the next pass is due at once; `idle` means
      # every reachable channel is indexed to the floor; `retry` means a
      # channel stopped on its own failure and is tried again soon; `error`
      # means the pass itself could not run.
      counter(
        "salix.slack_mirror.backfill.passes.total",
        event_name: [:salix, :slack_mirror, :backfill, :pass],
        tags: [:outcome],
        tag_values: &slack_mirror_backfill_tags/1
      ),
      last_value("salix.semantic_queue.oldest.age.seconds",
        event_name: [:salix, :semantic_queue, :backlog],
        measurement: :age_seconds,
        tags: [:lane],
        tag_values: &semantic_queue_tags/1
      ),
      distribution("salix.semantic_queue.completion.age.seconds",
        event_name: [:salix, :semantic_queue, :complete],
        measurement: :age_seconds,
        tags: [:lane, :kind],
        tag_values: &semantic_queue_tags/1,
        reporter_options: [buckets: [0.1, 0.5, 1, 2, 5, 10, 30, 60, 300, 600, 3600]]
      ),
      counter(
        "salix.vm.transitions.total",
        recovery_options ++ [event_name: [:salix, :vm, :transition]]
      ),
      sum(
        "salix.vm.recovery.scanned.total",
        recovery_options ++
          [
            event_name: [:salix, :vm, :recovery],
            measurement: :value,
            reporter_options: [prometheus_type: :counter]
          ]
      ),
      # Router post_message API (docs/tools-integrations.md):
      # admission outcome per request, and the limiter's fail-open count.
      counter("salix.router_inbox.post_message.total",
        event_name: [:salix, :router_inbox, :post_message, :stop],
        tags: [:outcome],
        tag_values: &router_inbox_tags/1
      ),
      counter("salix.router_inbox.rate_limit.decision.total",
        event_name: [:salix, :router_inbox, :rate_limit, :decision],
        tags: [:outcome],
        tag_values: &router_inbox_tags/1
      ),
      counter("salix.vm.record_actor.cache.total",
        event_name: [:salix, :vm, :record_actor, :cache],
        tags: [:outcome],
        tag_values: &vm_record_cache_tags/1
      ),
      counter("salix.vm.record_actor.persist.total",
        event_name: [:salix, :vm, :record_actor, :persist],
        tags: [:outcome],
        tag_values: &vm_record_persist_tags/1
      ),
      distribution("salix.vm.record_actor.batch.size",
        event_name: [:salix, :vm, :record_actor, :batch],
        measurement: :size,
        tags: [:outcome],
        tag_values: &vm_record_batch_tags/1,
        reporter_options: [buckets: [1, 2, 4, 8, 16, 32, 64]]
      ),
      distribution("salix.vm.record_actor.queue_wait.duration.seconds",
        event_name: [:salix, :vm, :record_actor, :queue],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:outcome],
        tag_values: &vm_record_batch_tags/1,
        reporter_options: [buckets: @actor_queue]
      ),
      counter("salix.external.status.projections.total",
        event_name: [:salix, :external_status_projection, :result],
        tags: [:outcome],
        tag_values: &external_status_projection_tags/1
      ),
      counter("salix.dependency.jobs.total",
        event_name: [:salix, :dependency_job, :stop],
        tags: [:kind, :outcome],
        tag_values: &dependency_job_tags/1
      ),
      last_value("salix.dependency.jobs.active",
        event_name: [:salix, :dependency_job, :active],
        measurement: :value,
        tags: [:kind],
        tag_values: &dependency_job_active_tags/1
      ),
      counter("salix.connector.external_events.total",
        event_name: [:salix, :connector, :external_event],
        tags: [:outcome],
        tag_values: &connector_external_event_tags/1
      ),
      last_value("salix.connector.external_event.queue.depth",
        event_name: [:salix, :connector, :external_event_queue],
        measurement: :value
      ),
      counter("salix.connector.pending_rpcs.total",
        event_name: [:salix, :connector, :pending_rpc],
        tags: [:transport, :outcome],
        tag_values: &connector_pending_rpc_tags/1
      ),
      counter("salix.connector.read_streams.total",
        event_name: [:salix, :connector, :read_stream],
        tags: [:transport, :outcome],
        tag_values: &connector_read_stream_tags/1
      ),
      counter("salix.connector.write_streams.total",
        event_name: [:salix, :connector, :write_stream],
        tags: [:transport, :outcome],
        tag_values: &connector_write_stream_tags/1
      ),
      # Poller-published gauges (SalixStore.Inflight.Poller): operations still
      # WAITING on the backend, which every terminal-state metric above is
      # blind to. A stalled store shows up here as nonzero count with rising
      # oldest age while duration/outcome series go quiet.
      last_value("salix.store.inflight.ops",
        event_name: [:salix, :store, :inflight],
        measurement: :count,
        tags: [:operation],
        tag_values: &store_inflight_tags/1
      ),
      last_value("salix.store.inflight.oldest.age.seconds",
        event_name: [:salix, :store, :inflight],
        measurement: :oldest_age_seconds,
        tags: [:operation],
        tag_values: &store_inflight_tags/1
      ),
      counter("salix.store.convergence.passes.total", convergence_options()),
      sum(
        "salix.store.convergence.converged.total",
        convergence_options() ++
          [measurement: :converged, reporter_options: [prometheus_type: :counter]]
      ),
      sum(
        "salix.store.convergence.failed.total",
        convergence_options() ++
          [measurement: :failed, reporter_options: [prometheus_type: :counter]]
      ),
      counter("salix.storage.settlement.total",
        event_name: [:salix, :storage, :settlement],
        tags: [:mode, :outcome],
        tag_values: &settlement_tags/1
      ),
      counter("salix.im.identity_resolution.total",
        event_name: [:salix, :im, :identity_resolution],
        tags: [:provider, :result],
        tag_values: &identity_resolution_tags/1
      ),
      counter("salix.runtime.probes.total",
        event_name: [:salix, :runtime_probe, :stop],
        tags: [:provider, :trigger, :outcome],
        tag_values: &runtime_probe_tags/1
      ),
      distribution("salix.runtime.probe.duration.seconds",
        event_name: [:salix, :runtime_probe, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:provider, :trigger, :outcome],
        tag_values: &runtime_probe_tags/1,
        reporter_options: [buckets: @llm]
      ),
      # Voice calls (docs/messaging-voice.md): how calls end per carrier, how
      # long they run, and how long the Router takes to answer a delegation.
      # A rise in model_error, carrier_error or timeout ends, or in abandoned
      # delegations, is the operational signal; no caller or Group labels.
      counter("salix.voice.calls.total",
        event_name: [:salix, :voice, :call, :stop],
        tags: [:transport, :reason],
        tag_values: &voice_call_tags/1
      ),
      distribution("salix.voice.call.duration.seconds",
        event_name: [:salix, :voice, :call, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:transport, :reason],
        tag_values: &voice_call_tags/1,
        reporter_options: [buckets: @voice_call]
      ),
      distribution("salix.voice.delegation.duration.seconds",
        event_name: [:salix, :voice, :delegation, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:outcome],
        tag_values: &voice_delegation_tags/1,
        reporter_options: [buckets: @llm]
      ),
      # How long a call waits for its caller profile, and why it has none.
      distribution("salix.voice.profile.duration.seconds",
        event_name: [:salix, :voice, :profile, :stop],
        measurement: :duration,
        unit: {:native, :second},
        tags: [:outcome],
        tag_values: &voice_profile_tags/1,
        reporter_options: [buckets: @llm]
      )
    ]
  end

  defp voice_call_tags(metadata) do
    %{
      transport: finite(metadata[:transport], @voice_transports),
      reason: finite(metadata[:reason], @voice_call_reasons)
    }
  end

  defp voice_delegation_tags(metadata),
    do: %{outcome: finite(metadata[:outcome], @voice_delegation_outcomes)}

  defp voice_profile_tags(metadata),
    do: %{outcome: finite(metadata[:outcome], @voice_profile_outcomes)}

  defp convergence_options do
    [
      event_name: [:salix, :store, :convergence],
      tags: [:operation, :outcome],
      tag_values: &convergence_tags/1
    ]
  end

  defp miniskill_tags(metadata),
    do: %{outcome: finite(metadata[:outcome], ~w(selected empty timeout error other))}

  def emit_miniskill(selection, duration, wait) do
    inputs = selection["inputs"] || []
    skills = Enum.flat_map(inputs, & &1["skills"])

    outcome =
      cond do
        Enum.any?(inputs, &(&1["outcome"] == "timeout")) ->
          "timeout"

        Enum.any?(inputs, &(&1["outcome"] not in ["selected", "no_match", "no_candidates"])) ->
          "error"

        skills == [] ->
          "empty"

        true ->
          "selected"
      end

    :telemetry.execute(
      [:salix, :miniskill, :stop],
      %{
        duration: duration,
        wait: wait,
        selected: length(skills),
        bytes: Enum.reduce(skills, 0, &(byte_size(&1["content"]) + &2))
      },
      %{outcome: outcome}
    )
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def emit_conversation_log_sample(backlog, age) do
    :telemetry.execute([:salix, :conversation_log, :sample], %{backlog: backlog, age: age}, %{})
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def emit_operation(component, operation, surface, outcome, duration) do
    :telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: duration},
      %{
        component: component,
        operation: operation,
        surface: normalize_surface(surface),
        outcome: outcome
      }
    )
  end

  def emit_llm_request(metadata) do
    :telemetry.execute(
      [:salix, :llm, :request, :stop],
      %{},
      normalize_metadata_surface(metadata)
    )
  end

  def emit_llm_attempt(metadata, duration \\ 0) do
    measurements =
      case metadata[:ttft_duration] do
        value when is_integer(value) and value >= 0 ->
          %{duration: duration, ttft_duration: value}

        _ ->
          %{duration: duration}
      end

    :telemetry.execute(
      [:salix, :llm, :attempt, :stop],
      measurements,
      normalize_metadata_surface(metadata)
    )
  end

  def emit_llm_usage(metadata, value) when is_number(value) do
    :telemetry.execute(
      [:salix, :llm, :usage],
      %{value: value},
      normalize_metadata_surface(metadata)
    )
  end

  def emit_vm_operation(metadata, duration) do
    :telemetry.execute(
      [:salix, :vm, :operation, :stop],
      %{duration: duration},
      normalize_metadata_surface(metadata)
    )
  end

  def emit_vm_transition(metadata, old_state, new_state) when old_state != new_state do
    metadata = normalize_metadata_surface(metadata)

    :telemetry.execute(
      [:salix, :vm, :transition],
      %{},
      Map.put(metadata, :state, normalize_vm_state(new_state))
    )
  end

  def emit_vm_transition(_metadata, _old_state, _new_state), do: :ok

  def emit_vm_recovery(metadata, scanned) when is_integer(scanned) do
    metadata = normalize_metadata_surface(metadata)

    :telemetry.execute(
      [:salix, :vm, :recovery],
      %{value: scanned},
      metadata
      |> Map.put(:provider, normalize_vm_provider(metadata[:provider]))
      |> Map.put(:state, normalize_vm_state(metadata[:state]))
    )
  end

  def emit_external_status_projection(outcome) do
    :telemetry.execute(
      [:salix, :external_status_projection, :result],
      %{},
      %{outcome: outcome}
    )
  end

  def emit_dependency_job(kind, outcome) do
    :telemetry.execute(
      [:salix, :dependency_job, :stop],
      %{},
      %{kind: kind, outcome: outcome}
    )
  end

  def emit_dependency_job_active(kind, value) when is_integer(value) and value >= 0 do
    :telemetry.execute(
      [:salix, :dependency_job, :active],
      %{value: value},
      %{kind: kind}
    )
  end

  def emit_connector_external_event(outcome) do
    :telemetry.execute(
      [:salix, :connector, :external_event],
      %{},
      %{outcome: outcome}
    )
  end

  def emit_connector_external_event_queue_depth(depth)
      when is_integer(depth) and depth >= 0 do
    :telemetry.execute(
      [:salix, :connector, :external_event_queue],
      %{value: depth},
      %{}
    )
  end

  def emit_connector_pending_rpc(outcome, transport \\ :websocket) do
    :telemetry.execute(
      [:salix, :connector, :pending_rpc],
      %{},
      %{outcome: outcome, transport: transport}
    )
  end

  def emit_connector_read_stream(outcome, transport \\ :websocket) do
    :telemetry.execute(
      [:salix, :connector, :read_stream],
      %{},
      %{outcome: outcome, transport: transport}
    )
  end

  def emit_connector_write_stream(outcome, transport \\ :websocket) do
    :telemetry.execute(
      [:salix, :connector, :write_stream],
      %{},
      %{outcome: outcome, transport: transport}
    )
  end

  def emit_runtime_probe(runtime) do
    duration = max(runtime["probe_duration_ms"] || 0, 0)

    :telemetry.execute(
      [:salix, :runtime_probe, :stop],
      %{duration: System.convert_time_unit(duration, :millisecond, :native)},
      %{
        provider: runtime["provider"],
        trigger: runtime["probe_trigger"],
        outcome: if(runtime["ready"] == true, do: "ok", else: "unavailable")
      }
    )
  end

  defp normalize_surface(value) when value in [:bridge, "bridge", :bft, "bft"], do: "bft"
  defp normalize_surface(value) when value in [:comma, "comma"], do: "comma"
  defp normalize_surface(value) when value in [:salix, "salix"], do: "salix"
  # Internal periodic writers name themselves (#928): `system` is the
  # fallback for "nobody set a surface", not a label for the timers sweeper,
  # the schedules sweeper and auto-title. Keeping them apart is what lets a
  # sweeper-driven volume be read off the counter with one query.
  defp normalize_surface(value) when value in [:schedule, "schedule"], do: "schedule"
  defp normalize_surface(value) when value in [:timer, "timer"], do: "timer"
  # Background Loops name themselves too: their wakes, host calls and events
  # are one `surface` query away from every other writer.
  defp normalize_surface(value) when value in [:loop, "loop"], do: "loop"
  # One-shot scripts (`script.run`) run in the same child but are a round's
  # own work, not a Loop's.
  defp normalize_surface(value) when value in [:script, "script"], do: "script"
  defp normalize_surface(value) when value in [:auto_title, "auto_title"], do: "auto_title"
  defp normalize_surface(value) when value in [:system, "system"], do: "system"
  defp normalize_surface(_value), do: "other"

  defp operation_tags(metadata) do
    component = finite(metadata[:component], Map.keys(@component_operations))
    operations = Map.fetch!(@component_operations, component)

    %{
      component: component,
      operation: finite(metadata[:operation], operations),
      surface: normalize_surface(metadata[:surface]),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp store_inflight_tags(metadata) do
    %{operation: finite(metadata[:operation], ~w(store_get store_put store_list other))}
  end

  defp runtime_probe_tags(metadata) do
    %{
      provider: finite(metadata[:provider], ~w(codex pi kimi claude other)),
      trigger: finite(metadata[:trigger], ~w(connect periodic operator other)),
      outcome: finite(metadata[:outcome], ~w(ok unavailable error timeout other))
    }
  end

  defp vm_operation_tags(metadata) do
    %{
      surface: normalize_surface(metadata[:surface]),
      provider: normalize_vm_provider(metadata[:provider]),
      operation: finite(metadata[:operation], @vm_operations),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp vm_profile_tags(metadata) do
    %{profile: finite(metadata[:profile], ~w(cf-standard-1 cf-standard-2 unknown))}
  end

  defp llm_tags(metadata) do
    %{
      surface: normalize_surface(metadata[:surface]),
      provider: finite(metadata[:provider], ~w(openai anthropic other)),
      model_key: finite(metadata[:model_key], model_keys()),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  defp llm_usage_tags(metadata) do
    metadata
    |> llm_tags()
    |> Map.delete(:outcome)
    |> Map.put(:kind, finite(metadata[:kind], ~w(input output cache_read cache_write other)))
  end

  defp sink_tags(metadata), do: %{sink: finite(metadata[:sink], ~w(reporting llm_usage other))}

  defp reporting_result_tags(metadata) do
    %{
      sink: finite(metadata[:sink], ~w(reporting llm_usage other)),
      outcome: finite(metadata[:outcome], @outcomes)
    }
  end

  # Every way `SalixIM.SlackMessageMirror.observe/2` can discard an event. The
  # set is closed on purpose: a new drop path has to be named here to be
  # visible, which is the point at which someone has to decide whether it
  # should exist.
  defp slack_mirror_drop_tags(metadata) do
    %{reason: finite(metadata[:reason], ~w(outbox_unavailable))}
  end

  defp slack_mirror_outbox_tags(metadata) do
    %{outcome: finite(metadata[:outcome], ~w(drained failed))}
  end

  defp slack_mirror_backfill_tags(metadata) do
    %{outcome: finite(metadata[:outcome], ~w(more retry idle error))}
  end

  defp vm_state_tags(metadata) do
    %{
      surface: normalize_surface(metadata[:surface]),
      provider: normalize_vm_provider(metadata[:provider]),
      state: normalize_vm_state(metadata[:state])
    }
  end

  defp router_inbox_tags(metadata) do
    %{outcome: finite(metadata[:outcome], @router_inbox_outcomes)}
  end

  defp vm_record_cache_tags(metadata) do
    %{outcome: finite(metadata[:outcome], @vm_record_cache_outcomes)}
  end

  defp vm_record_batch_tags(metadata) do
    %{outcome: finite(metadata[:outcome], @vm_record_batch_outcomes)}
  end

  defp vm_record_persist_tags(metadata) do
    %{outcome: finite(metadata[:outcome], @vm_record_persist_outcomes)}
  end

  defp external_status_projection_tags(metadata) do
    %{outcome: finite(metadata[:outcome], @external_status_projection_outcomes)}
  end

  defp dependency_job_tags(metadata) do
    %{
      kind: finite(metadata[:kind], @dependency_job_kinds),
      outcome: finite(metadata[:outcome], @dependency_job_outcomes)
    }
  end

  defp semantic_queue_tags(metadata) do
    %{
      lane: finite(metadata[:lane], ~w(live history)),
      kind: finite(metadata[:kind], ~w(text enumerate file))
    }
  end

  defp dependency_job_active_tags(metadata) do
    %{kind: finite(metadata[:kind], @dependency_job_kinds)}
  end

  defp connector_external_event_tags(metadata) do
    %{outcome: finite(metadata[:outcome], @connector_external_event_outcomes)}
  end

  defp connector_pending_rpc_tags(metadata) do
    %{
      transport: finite(metadata[:transport], @connector_transports),
      outcome: finite(metadata[:outcome], @connector_pending_rpc_outcomes)
    }
  end

  defp connector_read_stream_tags(metadata) do
    %{
      transport: finite(metadata[:transport], @connector_transports),
      outcome: finite(metadata[:outcome], @connector_read_stream_outcomes)
    }
  end

  defp connector_write_stream_tags(metadata) do
    %{
      transport: finite(metadata[:transport], @connector_transports),
      outcome: finite(metadata[:outcome], @connector_write_stream_outcomes)
    }
  end

  defp identity_resolution_tags(metadata) do
    %{
      provider: finite(metadata[:provider], @im_identity_providers),
      result: finite(metadata[:result], @im_identity_resolutions)
    }
  end

  defp convergence_tags(metadata) do
    %{
      operation: finite(metadata[:name], @convergence_names),
      outcome: finite(metadata[:outcome], @convergence_outcomes)
    }
  end

  defp settlement_tags(metadata) do
    %{
      mode: finite(metadata[:mode], @settlement_modes),
      outcome: finite(metadata[:outcome], @settlement_outcomes)
    }
  end

  defp normalize_metadata_surface(metadata) do
    Map.update(metadata, :surface, "other", &normalize_surface/1)
  end

  defp normalize_vm_provider(value), do: finite(value, @vm_providers)

  defp normalize_vm_state(value) when value in [:creating, "creating", :pending, "pending"],
    do: "pending"

  defp normalize_vm_state(value) when value in [:claimed, "claimed", :claiming, "claiming"],
    do: "claiming"

  defp normalize_vm_state(value) when value in [:reviving, "reviving", :waking, "waking"],
    do: "waking"

  defp normalize_vm_state(value), do: finite(value, @vm_states)

  defp model_keys do
    Application.get_env(:systems_observability, :model_keys, [])
    |> Enum.take(7)
    |> Enum.map(&to_string/1)
    |> Kernel.++(["other"])
    |> Enum.uniq()
  end

  defp ttft?(metadata), do: metadata[:ttft] == true

  defp finite(value, allowed) when is_atom(value), do: finite(Atom.to_string(value), allowed)

  defp finite(value, allowed) when is_binary(value),
    do: if(value in allowed, do: value, else: "other")

  defp finite(_value, _allowed), do: "other"
end
