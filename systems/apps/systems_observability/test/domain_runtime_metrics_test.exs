defmodule SystemsObservability.DomainRuntimeMetricsTest do
  use ExUnit.Case, async: false

  @reporter Module.concat(__MODULE__, Reporter)

  setup do
    metrics =
      SystemsObservability.Metrics.enabled_metrics([
        :alert_router,
        :bridge_for_teams,
        :comma_product,
        :salix
      ])

    start_supervised!(
      {TelemetryMetricsPrometheus.Core, name: @reporter, metrics: metrics, start_async: false}
    )

    :ok
  end

  test "miniskill metrics expose counts without instruction content or source identities" do
    for outcome <- ["selected", "private-error"] do
      Salix.Telemetry.emit_miniskill(
        %{
          "inputs" => [
            %{
              "outcome" => outcome,
              "source_message_id" => "private-source",
              "skills" => [%{"skill_id" => "private-skill", "content" => "private-body"}]
            }
          ]
        },
        System.convert_time_unit(20, :millisecond, :native),
        System.convert_time_unit(2, :millisecond, :native)
      )
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)
    assert scrape =~ ~s(salix_miniskill_total{outcome="selected"} 1)
    assert scrape =~ ~s(salix_miniskill_total{outcome="error"} 1)
    refute scrape =~ "private-"
  end

  test "semantic queue ages reach the shared scrape with finite labels" do
    :telemetry.execute([:salix, :semantic_queue, :backlog], %{age_seconds: 12}, %{lane: "live"})

    :telemetry.execute([:salix, :semantic_queue, :complete], %{age_seconds: 2.5}, %{
      lane: "live",
      kind: "text"
    })

    :telemetry.execute([:salix, :semantic_queue, :backlog], %{age_seconds: 5}, %{
      lane: "tenant-secret"
    })

    :telemetry.execute([:salix, :semantic_queue, :complete], %{age_seconds: 3}, %{
      lane: "tenant-secret",
      kind: "private-file"
    })

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)
    assert scrape =~ ~s(salix_semantic_queue_oldest_age_seconds{lane="live"} 12)
    assert scrape =~ ~s(salix_semantic_queue_oldest_age_seconds{lane="other"} 5)
    assert scrape =~ "salix_semantic_queue_completion_age_seconds_bucket"
    assert scrape =~ ~s(kind="text",lane="live")
    refute scrape =~ "tenant-secret"
    refute scrape =~ "private-file"
  end

  test "profile avatar metrics classify the local S3 adapter" do
    previous = Application.get_env(:comma_core, :profile_avatar)
    Application.put_env(:comma_core, :profile_avatar, adapter: Comma.ProfileAvatar.Storage.S3)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:comma_core, :profile_avatar)
      else
        Application.put_env(:comma_core, :profile_avatar, previous)
      end
    end)

    CommaProduct.Telemetry.emit_operation(
      :profile_avatar_put_finish,
      :ok,
      System.convert_time_unit(10, :millisecond, :native)
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(comma_product_operations_total{operation="profile_avatar_put_finish",outcome="ok",provider="s3"} 1)
  end

  test "native Triage phase and recovery signals reach the shared scrape" do
    SalixIM.Triage.Telemetry.emit(
      :evaluation,
      :timeout,
      :callback,
      :bft,
      System.monotonic_time() - System.convert_time_unit(25, :millisecond, :native)
    )

    SalixIM.Triage.Telemetry.emit_recovery_status(:buckets, :error, 1, 2)

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(salix_triage_phases_total{outcome="timeout",phase="evaluation",source_mode="callback",surface="bft"} 1)

    assert scrape =~ "salix_triage_phase_duration_seconds_bucket"
    assert scrape =~ ~s(salix_triage_recovery_backlog{lane="buckets"} 1)

    assert scrape =~
             ~s(salix_triage_recovery_record_errors_total{lane="buckets",outcome="error"} 2)
  end

  test "Router post_message API admission and limiter outcomes are finite" do
    for outcome <- [:queued, :unauthorized, :rate_limited, "group-123?token=secret"] do
      :telemetry.execute(
        [:salix, :router_inbox, :post_message, :stop],
        %{duration: 1, count: 1},
        %{outcome: outcome}
      )
    end

    :telemetry.execute(
      [:salix, :router_inbox, :rate_limit, :decision],
      %{count: 1},
      %{outcome: :unavailable}
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~ ~s(salix_router_inbox_post_message_total{outcome="queued"} 1)
    assert scrape =~ ~s(salix_router_inbox_post_message_total{outcome="unauthorized"} 1)
    assert scrape =~ ~s(salix_router_inbox_post_message_total{outcome="rate_limited"} 1)
    assert scrape =~ ~s(salix_router_inbox_post_message_total{outcome="other"} 1)
    assert scrape =~ ~s(salix_router_inbox_rate_limit_decision_total{outcome="unavailable"} 1)
    refute scrape =~ "group-123"
  end

  test "cloud VM record actor cache, batch, queue, and persistence metrics are finite" do
    duration = System.convert_time_unit(3, :millisecond, :native)
    hostile = "group-123?token=secret"

    :telemetry.execute(
      [:salix, :vm, :record_actor, :cache],
      %{count: 1},
      %{outcome: :hit}
    )

    :telemetry.execute(
      [:salix, :vm, :record_actor, :persist],
      %{count: 1},
      %{outcome: :conflict}
    )

    :telemetry.execute(
      [:salix, :vm, :record_actor, :batch],
      %{count: 1, size: 9},
      %{outcome: :ok}
    )

    :telemetry.execute(
      [:salix, :vm, :record_actor, :queue],
      %{duration: duration},
      %{outcome: :ok}
    )

    for event <- [:cache, :persist, :batch] do
      :telemetry.execute(
        [:salix, :vm, :record_actor, event],
        %{count: 1, size: 1},
        %{outcome: hostile}
      )
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~ ~s(salix_vm_record_actor_cache_total{outcome="hit"} 1)

    assert scrape =~
             ~s(salix_vm_record_actor_persist_total{outcome="conflict"} 1)

    assert scrape =~
             ~s(salix_vm_record_actor_batch_size_bucket{outcome="ok",le="+Inf"} 1)

    assert scrape =~
             ~s(salix_vm_record_actor_queue_wait_duration_seconds_bucket{outcome="ok",le="+Inf"} 1)

    assert scrape =~ ~s(salix_vm_record_actor_cache_total{outcome="other"} 1)
    assert scrape =~ ~s(salix_vm_record_actor_persist_total{outcome="other"} 1)

    assert scrape =~
             ~s(salix_vm_record_actor_batch_size_bucket{outcome="other",le="+Inf"} 1)

    refute scrape =~ "group-123"
    refute scrape =~ "token=secret"
  end

  test "alert router outcomes reach the shared scrape with finite labels" do
    AlertRouter.Telemetry.emit(
      :root_reconcile,
      :slack,
      :incomplete,
      System.convert_time_unit(10, :millisecond, :native)
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(alert_router_operations_total{operation="root_reconcile",outcome="incomplete",provider="slack"} 1)
  end

  test "raw success/error, latency, retries, and transitions are scrapeable" do
    duration = System.convert_time_unit(25, :millisecond, :native)

    BridgeForTeams.Telemetry.emit_operation(:reconcile, "ok", duration)
    BridgeForTeams.Telemetry.emit_operation(:reconcile, "error", duration)

    CommaProduct.Telemetry.emit_backlog_retry(:comma_external)
    CommaProduct.Telemetry.emit_backlog_terminal_failure(:comma_external)
    CommaProduct.Telemetry.emit_backlog_sample(:comma_external, 3, 12.5)

    CommaProduct.Telemetry.emit_admin_command("create_user", :ok, duration)
    CommaProduct.Telemetry.emit_operation(:profile_avatar_put_start, :ok, duration)
    CommaProduct.Telemetry.emit_operation(:profile_avatar_put_finish, :timeout, duration)
    CommaProduct.Telemetry.emit_operation(:profile_avatar_put_cancel, :ok, duration)
    CommaProduct.Telemetry.emit_operation(:profile_avatar_get, :not_found, duration)
    CommaProduct.Telemetry.emit_operation(:synchronicity_provision, :ok, duration)
    CommaProduct.Telemetry.emit_operation(:synchronicity_enroll, :conflict, duration)
    CommaProduct.Telemetry.emit_operation(:google_desktop_exchange, :unavailable, duration)

    Salix.Telemetry.emit_vm_transition(
      %{surface: "comma", provider: "cloudflare"},
      "pending",
      "ready"
    )

    Salix.Telemetry.emit_operation(
      "salix_meet",
      "calendar_enrollment",
      "system",
      "ok",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_artifact",
      "system",
      "rejected",
      duration
    )

    Salix.Telemetry.emit_operation("salix_meet", "meeting_asr", "system", "ok", duration)

    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_delivery",
      "system",
      "unavailable",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_runtime_late_event",
      "system",
      "rejected",
      duration
    )

    Salix.Telemetry.emit_operation("salix_meet", "meeting_watchdog", "system", "ok", duration)

    Salix.Telemetry.emit_operation(
      "salix_meet",
      "meeting_stuck_nonterminal",
      "system",
      "retained",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_calendar",
      "source_sync",
      "system",
      "conflict",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_calendar",
      "watch",
      "system",
      "ok",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_recovery",
      "system",
      "retained",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_cluster",
      "session_work_notification_dispatch",
      "system",
      "ignored",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "session_work_notification_admission",
      "system",
      "over_budget",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "session_work_notification_wake",
      "system",
      "ok",
      duration
    )

    Salix.Telemetry.emit_operation(
      "salix_im",
      "slack_api_retry",
      "salix",
      "over_budget",
      duration
    )

    for outcome <- ~w(cleaned retained scan_error) do
      Salix.Telemetry.emit_operation(
        "salix_agent",
        "prepared_blob_cleanup",
        "system",
        outcome,
        duration
      )
    end

    Enum.each([:ok, :failed], &Salix.Telemetry.emit_external_status_projection/1)

    Salix.Telemetry.emit_dependency_job(:llm, :timeout)
    Salix.Telemetry.emit_dependency_job_active(:llm, 2)
    Salix.Telemetry.emit_connector_external_event(:completed)
    Salix.Telemetry.emit_connector_external_event_queue_depth(3)
    Salix.Telemetry.emit_connector_pending_rpc(:caller_down)
    Salix.Telemetry.emit_connector_read_stream(:cancelled, :sprites)
    Salix.Telemetry.emit_connector_write_stream(:timeout, :cloudflare)

    Salix.Telemetry.emit_runtime_probe(%{
      "provider" => "codex",
      "probe_trigger" => "operator",
      "probe_duration_ms" => 25,
      "ready" => true
    })

    BillingTelemetry.emit_operation(:charge, "bridge", "ok", duration)

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~ "bft_operations_total"
    assert scrape =~ ~s(operation="reconcile",outcome="ok",provider="other")
    assert scrape =~ ~s(operation="reconcile",outcome="error",provider="other")
    assert scrape =~ "bft_operations_duration_seconds_bucket"

    assert scrape =~
             ~s(comma_product_backlog_retries_total{queue="comma_external"} 1)

    assert scrape =~
             ~s(comma_product_backlog_terminal_failures_total{queue="comma_external"} 1)

    assert scrape =~
             ~s(comma_product_backlog_depth{queue="comma_external"} 3)

    assert scrape =~
             ~s(comma_product_backlog_oldest_age_seconds{queue="comma_external"} 12.5)

    assert scrape =~
             ~s(comma_product_operations_total{operation="admin_create_user",outcome="ok",provider="other"} 1)

    assert scrape =~
             ~s(comma_product_operations_duration_seconds_bucket{operation="admin_create_user",outcome="ok",provider="other",le="+Inf"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="profile_avatar_put_start",outcome="ok",provider="gcs"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="profile_avatar_put_finish",outcome="timeout",provider="gcs"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="profile_avatar_put_cancel",outcome="ok",provider="gcs"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="profile_avatar_get",outcome="not_found",provider="gcs"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="google_desktop_exchange",outcome="unavailable",provider="google"} 1)

    assert scrape =~
             ~s(comma_product_operations_duration_seconds_bucket{operation="profile_avatar_put_finish",outcome="timeout",provider="gcs",le="+Inf"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="synchronicity_provision",outcome="ok",provider="synchronicity"} 1)

    assert scrape =~
             ~s(comma_product_operations_total{operation="synchronicity_enroll",outcome="conflict",provider="synchronicity"} 1)

    assert scrape =~
             ~s(salix_vm_transitions_total{provider="cloudflare",state="ready",surface="comma"} 1)

    assert scrape =~
             ~s(salix_external_status_projections_total{outcome="ok"} 1)

    assert scrape =~ ~s(salix_external_status_projections_total{outcome="failed"} 1)

    assert scrape =~
             ~s(salix_dependency_jobs_total{kind="llm",outcome="timeout"} 1)

    assert scrape =~ ~s(salix_dependency_jobs_active{kind="llm"} 2)

    assert scrape =~
             ~s(salix_connector_external_events_total{outcome="completed"} 1)

    assert scrape =~ ~s(salix_connector_external_event_queue_depth 3)

    assert scrape =~
             ~s(salix_connector_pending_rpcs_total{outcome="caller_down",transport="websocket"} 1)

    assert scrape =~
             ~s(salix_connector_read_streams_total{outcome="cancelled",transport="sprites"} 1)

    assert scrape =~
             ~s(salix_connector_write_streams_total{outcome="timeout",transport="cloudflare"} 1)

    assert scrape =~
             ~s(salix_runtime_probes_total{outcome="ok",provider="codex",trigger="operator"} 1)

    assert scrape =~ "salix_runtime_probe_duration_seconds_bucket"

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="calendar_enrollment",outcome="ok",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="meeting_artifact",outcome="rejected",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="meeting_asr",outcome="ok",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="meeting_delivery",outcome="unavailable",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="meeting_runtime_late_event",outcome="rejected",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="meeting_watchdog",outcome="ok",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="meeting_stuck_nonterminal",outcome="retained",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_calendar",operation="source_sync",outcome="conflict",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_calendar",operation="watch",outcome="ok",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_cluster",operation="session_work_recovery",outcome="retained",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_cluster",operation="session_work_notification_dispatch",outcome="ignored",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_agent",operation="session_work_notification_admission",outcome="over_budget",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_agent",operation="session_work_notification_wake",outcome="ok",surface="system"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="salix_im",operation="slack_api_retry",outcome="over_budget",surface="salix"} 1)

    assert scrape =~
             ~s(salix_operations_duration_seconds_bucket{component="salix_meet",operation="meeting_artifact",outcome="rejected",surface="system",le="+Inf"} 1)

    assert scrape =~
             ~s(salix_operations_duration_seconds_bucket{component="salix_meet",operation="meeting_artifact",outcome="rejected",surface="system",le="600"} 1)

    for outcome <- ~w(cleaned retained scan_error) do
      assert scrape =~
               ~s(salix_operations_total{component="salix_agent",operation="prepared_blob_cleanup",outcome="#{outcome}",surface="system"} 1)
    end

    assert scrape =~ ~s(surface="bft")
    assert scrape =~ ~s(operation="charge")
  end

  test "hostile IDs, URLs, tool/model names, and error text converge to finite other tuples" do
    hostile = "tenant-123?token=secret/model/error boom"
    duration = System.convert_time_unit(1, :millisecond, :native)

    :telemetry.execute(
      [:bridge_for_teams, :operation, :stop],
      %{duration: duration},
      %{operation: hostile, provider: hostile, outcome: hostile}
    )

    Salix.Telemetry.emit_operation(hostile, hostile, hostile, hostile, duration)
    Salix.Telemetry.emit_external_status_projection(hostile)
    Salix.Telemetry.emit_dependency_job(hostile, hostile)
    Salix.Telemetry.emit_dependency_job_active(hostile, 1)
    Salix.Telemetry.emit_connector_external_event(hostile)
    Salix.Telemetry.emit_connector_pending_rpc(hostile, hostile)
    Salix.Telemetry.emit_connector_read_stream(hostile, hostile)
    Salix.Telemetry.emit_connector_write_stream(hostile, hostile)

    :telemetry.execute(
      [:salix, :runtime_probe, :stop],
      %{duration: duration},
      %{provider: hostile, trigger: hostile, outcome: hostile}
    )

    Salix.Telemetry.emit_llm_attempt(%{
      surface: hostile,
      provider: hostile,
      model_key: hostile,
      outcome: hostile,
      attempt: 2,
      error: hostile,
      tool: hostile,
      url: hostile
    })

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(bft_operations_total{operation="other",outcome="other",provider="other"} 1)

    assert scrape =~
             ~s(salix_operations_total{component="other",operation="other",outcome="other",surface="other"} 1)

    assert scrape =~
             ~s(salix_external_status_projections_total{outcome="other"} 1)

    assert scrape =~
             ~s(salix_dependency_jobs_total{kind="other",outcome="other"} 1)

    assert scrape =~ ~s(salix_dependency_jobs_active{kind="other"} 1)

    assert scrape =~
             ~s(salix_connector_external_events_total{outcome="other"} 1)

    assert scrape =~
             ~s(salix_connector_pending_rpcs_total{outcome="other",transport="other"} 1)

    assert scrape =~
             ~s(salix_connector_read_streams_total{outcome="other",transport="other"} 1)

    assert scrape =~
             ~s(salix_connector_write_streams_total{outcome="other",transport="other"} 1)

    assert scrape =~
             ~s(salix_runtime_probes_total{outcome="other",provider="other",trigger="other"} 1)

    refute scrape =~ "tenant-123"
    refute scrape =~ "token=secret"
    refute scrape =~ "error boom"
  end

  test "store convergence passes reach the scrape with finite name/outcome tuples" do
    # Shapes the engine actually emits: a clean pass carries converged with
    # zero failed; a failed pass carries failed under outcome="error" (the
    # engine never emits failed>0 with outcome="ok"). The implementation-
    # name label is a REGISTERED whitelist (empty until a convergence user
    # PR lands), so any unregistered or hostile name normalizes to "other"
    # and can never mint a new series.
    :telemetry.execute(
      [:salix, :store, :convergence],
      %{converged: 3, unchanged: 0, skipped: 0, failed: 0},
      %{name: "some_unregistered_impl", outcome: "ok"}
    )

    :telemetry.execute(
      [:salix, :store, :convergence],
      %{converged: 0, unchanged: 0, skipped: 0, failed: 2},
      %{name: "some_unregistered_impl", outcome: "error"}
    )

    :telemetry.execute(
      [:salix, :store, :convergence],
      %{converged: 0, unchanged: 0, skipped: 0, failed: 0},
      %{name: "tenant-123?token=secret", outcome: "exploded badly"}
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(salix_store_convergence_passes_total{operation="other",outcome="ok"} 1)

    assert scrape =~
             ~s(salix_store_convergence_converged_total{operation="other",outcome="ok"} 3)

    assert scrape =~
             ~s(salix_store_convergence_failed_total{operation="other",outcome="error"} 2)

    assert scrape =~
             ~s(salix_store_convergence_passes_total{operation="other",outcome="other"} 1)

    refute scrape =~ "token=secret"
  end

  test "S3 settlement outcomes reach the shared scrape without blanking existing metrics" do
    previous = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, previous) end)

    key = "telemetry/settlement-metric.json"
    body = Jason.encode!(%{"ok" => true})
    settle = SalixStore.S3.Settle.byte_settle(body)

    assert :created = SalixStore.S3.Settle.create_once(key, body, settle)
    assert :landed = SalixStore.S3.Settle.create_once(key, body, settle)

    :telemetry.execute(
      [:salix, :storage, :settlement],
      %{count: 1},
      %{mode: "tenant-42?token=secret", outcome: "exploded badly"}
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~ "salix_operations_duration_seconds_bucket"

    assert scrape =~
             ~s(salix_storage_settlement_total{mode="create_once",outcome="created"} 1)

    assert scrape =~
             ~s(salix_storage_settlement_total{mode="create_once",outcome="landed"} 1)

    assert scrape =~ ~s(salix_storage_settlement_total{mode="other",outcome="other"} 1)
    refute scrape =~ "tenant-42"
    refute scrape =~ "token=secret"
  end

  test "identity resolution events reach the scrape with finite provider/result tuples" do
    :telemetry.execute(
      [:salix, :im, :identity_resolution],
      %{count: 1},
      %{provider: "slack", result: "fast_hit"}
    )

    :telemetry.execute(
      [:salix, :im, :identity_resolution],
      %{count: 1},
      %{provider: "slack", result: "fallback_miss"}
    )

    :telemetry.execute(
      [:salix, :im, :identity_resolution],
      %{count: 1},
      %{provider: "slack", result: "rejected"}
    )

    # Hostile/unregistered label values normalize to "other" — no new
    # series can be minted from caller-controlled data.
    :telemetry.execute(
      [:salix, :im, :identity_resolution],
      %{count: 1},
      %{provider: "tenant-42?x=y", result: "weird value"}
    )

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(salix_im_identity_resolution_total{provider="slack",result="fast_hit"} 1)

    assert scrape =~
             ~s(salix_im_identity_resolution_total{provider="slack",result="fallback_miss"} 1)

    assert scrape =~
             ~s(salix_im_identity_resolution_total{provider="slack",result="rejected"} 1)

    assert scrape =~
             ~s(salix_im_identity_resolution_total{provider="other",result="other"} 1)

    refute scrape =~ "tenant-42"
  end

  test "a clean verification pass exports zero healing volume (real engine to scrape)" do
    # The operational semantics the catalog promises: sustained nonzero
    # converged volume proves drift keeps appearing (likely — though not
    # necessarily — inline write failures). Drive the REAL engine twice
    # over unchanged canonical state and assert at the scrape boundary
    # that the second (verification) pass added nothing.
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.Convergence.reset_converged_cache(SalixStore.ConvergenceWorkerFastImpl)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)

    prefix = SalixStore.ConvergenceWorkerFastImpl.source_prefix()
    {:ok, _} = SalixStore.S3.put(prefix <> "a.json", Jason.encode!(%{"id" => "a"}))

    assert {:ok, :complete} = SalixStore.Convergence.ensure(SalixStore.ConvergenceWorkerFastImpl)

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(salix_store_convergence_converged_total{operation="other",outcome="ok"} 1)

    # Second pass past the interval: everything verifies already-correct.
    future = System.system_time(:millisecond) + :timer.hours(2)

    assert {:ok, :complete} =
             SalixStore.Convergence.ensure(SalixStore.ConvergenceWorkerFastImpl, now: future)

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    assert scrape =~
             ~s(salix_store_convergence_passes_total{operation="other",outcome="ok"} 2)

    # Still 1 — the verification pass contributed no healing volume.
    assert scrape =~
             ~s(salix_store_convergence_converged_total{operation="other",outcome="ok"} 1)
  end

  test "meeting observability floor operations and outcomes survive the finite-label scrape" do
    duration = System.convert_time_unit(5, :millisecond, :native)

    for {operation, outcome} <- [
          {"calendar_scan_group", "ok"},
          {"calendar_scan_group", "partial"},
          {"calendar_scan_group", "error"},
          {"calendar_scan_group", "timeout"},
          {"calendar_join_group", "ok"},
          {"calendar_join_group", "error"},
          {"calendar_join_group", "timeout"},
          {"calendar_join_dispatch", "dispatched"},
          {"calendar_join_dispatch", "already"},
          {"calendar_join_dispatch", "skipped"},
          {"calendar_join_dispatch", "error"},
          {"calendar_join_dispatch_skip", "failed"},
          {"calendar_join_dispatch_skip", "in_doubt"},
          {"calendar_join_dispatch_skip", "unavailable"},
          {"calendar_enrollment_group", "dropped"},
          {"meeting_delivery_claim", "error"}
        ] do
      Salix.Telemetry.emit_operation("salix_meet", operation, "system", outcome, duration)
    end

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)

    for {operation, outcome} <- [
          {"calendar_scan_group", "ok"},
          {"calendar_scan_group", "partial"},
          {"calendar_scan_group", "error"},
          {"calendar_scan_group", "timeout"},
          {"calendar_join_group", "ok"},
          {"calendar_join_group", "error"},
          {"calendar_join_group", "timeout"},
          {"calendar_join_dispatch", "dispatched"},
          {"calendar_join_dispatch", "already"},
          {"calendar_join_dispatch", "skipped"},
          {"calendar_join_dispatch", "error"},
          {"calendar_join_dispatch_skip", "failed"},
          {"calendar_join_dispatch_skip", "in_doubt"},
          {"calendar_join_dispatch_skip", "unavailable"},
          {"calendar_enrollment_group", "dropped"},
          {"meeting_delivery_claim", "error"}
        ] do
      assert scrape =~
               ~s(salix_operations_total{component="salix_meet",operation="#{operation}",outcome="#{outcome}",surface="system"} 1)
    end

    refute scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="other")

    refute scrape =~
             ~s(salix_operations_total{component="salix_meet",operation="calendar_join_dispatch",outcome="other")
  end

  test "voice call ends, delegation latency and profile waits reach the scrape with finite labels" do
    second = System.convert_time_unit(1, :second, :native)

    :telemetry.execute([:salix, :voice, :call, :stop], %{duration: 90 * second}, %{
      transport: "twilio",
      reason: "agent_hangup"
    })

    :telemetry.execute([:salix, :voice, :call, :stop], %{duration: second}, %{
      transport: "+15551234567",
      reason: "vc_01SECRETCALLID"
    })

    :telemetry.execute([:salix, :voice, :delegation, :stop], %{duration: 3 * second}, %{
      outcome: "answered"
    })

    :telemetry.execute([:salix, :voice, :delegation, :stop], %{duration: second}, %{
      outcome: "caller said: my PIN is 1234"
    })

    :telemetry.execute([:salix, :voice, :profile, :stop], %{duration: second}, %{
      outcome: "timeout"
    })

    :telemetry.execute([:salix, :voice, :profile, :stop], %{duration: second}, %{
      outcome: "Speak Spanish"
    })

    scrape = TelemetryMetricsPrometheus.Core.scrape(@reporter)
    assert scrape =~ ~s(salix_voice_profile_duration_seconds_count{outcome="timeout"} 1)
    assert scrape =~ ~s(salix_voice_profile_duration_seconds_count{outcome="other"} 1)
    refute scrape =~ "Spanish"
    assert scrape =~ ~s(salix_voice_calls_total{reason="agent_hangup",transport="twilio"} 1)
    assert scrape =~ ~s(salix_voice_calls_total{reason="other",transport="other"} 1)
    assert scrape =~ "salix_voice_call_duration_seconds_bucket"
    assert scrape =~ ~s(salix_voice_delegation_duration_seconds_count{outcome="answered"} 1)
    assert scrape =~ ~s(salix_voice_delegation_duration_seconds_count{outcome="other"} 1)
    refute scrape =~ "15551234567"
    refute scrape =~ "SECRETCALLID"
    refute scrape =~ "PIN"
  end
end
