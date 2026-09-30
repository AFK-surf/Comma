defmodule BridgeForTeams.ObservabilityTest do
  use BridgeForTeams.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias BridgeForTeams.{Accounts, Environments, Observability, Orgs, Projects, RunChecks}
  alias BridgeForTeams.Observability.{Pruner, SalixIMSink}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{AuditLog, CheckResult, ObservabilityEvent, OperationRun}

  setup do
    {:ok, org} = Orgs.create_org(%{name: "Acme", slug: "acme"})
    {:ok, other_org} = Orgs.create_org(%{name: "Other", slug: "other"})
    {:ok, project} = Projects.create_project(org.id, %{name: "Launch", slug: "launch"})
    {:ok, other_project} = Projects.create_project(other_org.id, %{name: "Other", slug: "other"})
    {:ok, user} = Accounts.create_user(%{email: "operator@example.com", name: "Operator"})

    %{
      org: org,
      other_org: other_org,
      project: project,
      other_project: other_project,
      user: user
    }
  end

  test "org health summary is unknown when no operations facts exist" do
    assert Observability.org_health_summary(0, [], [], [], []) == %{
             health: "unknown",
             reason_codes: [:no_operations_facts]
           }
  end

  test "org health summary promotes critical facts above action required" do
    summary =
      Observability.org_health_summary(
        1,
        [%{effective_status: "online"}],
        [%ObservabilityEvent{severity: "critical"}],
        [%OperationRun{status: "failed"}],
        []
      )

    assert summary.health == "critical"
    assert :critical_events in summary.reason_codes
    assert :failed_or_canceled_runs in summary.reason_codes
  end

  test "org health summary never treats skipped checks or stale runners as healthy" do
    skipped =
      Observability.org_health_summary(
        1,
        [%{effective_status: "online"}],
        [],
        [],
        [%CheckResult{status: "skipped"}]
      )

    assert skipped.health == "degraded"
    assert skipped.reason_codes == [:manual_or_skipped_checks]

    stale =
      Observability.org_health_summary(
        1,
        [%{effective_status: "stale"}],
        [],
        [],
        [%CheckResult{status: "ok"}]
      )

    assert stale.health == "degraded"
    assert stale.reason_codes == [:runner_stale_or_unknown]
  end

  test "org health summary marks projects without runners as action required" do
    assert Observability.org_health_summary(1, [], [], [], []).health == "action_required"
  end

  test "health_class centralizes fact status severity mapping" do
    assert Observability.health_class(:runner_status, "critical") == :critical
    assert Observability.health_class(:runner_status, "offline") == :action_required
    assert Observability.health_class(:runner_status, "stale") == :degraded
    assert Observability.health_class(:runner_status, "online") == :healthy

    assert Observability.health_class(:event_severity, "critical") == :critical
    assert Observability.health_class(:event_severity, "error") == :action_required
    assert Observability.health_class(:event_severity, "warning") == :healthy

    assert Observability.health_class(:run_status, "failed") == :action_required
    assert Observability.health_class(:run_status, "needs_manual") == :degraded
    assert Observability.health_class(:check_status, "fail") == :action_required
    assert Observability.health_class(:check_status, :skipped) == :degraded

    assert Observability.health_class(:unknown_fact, "failed") == :unknown
    assert Observability.health_class(:run_status, "running") == :unknown
    assert Observability.health_class(:check_status, nil) == :unknown
  end

  test "org health summary for org uses unpaginated recent facts", %{org: org} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _critical_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "critical",
               summary: "Hidden critical runner event",
               occurred_at: now
             })

    for index <- 1..26 do
      assert {:ok, _event} =
               Observability.create_event(%{
                 org_id: org.id,
                 domain: "runner",
                 resource_type: "mac_mini_provisioner",
                 source: "mac_mini.provisioner",
                 event_type: "runner.status_changed",
                 severity: "info",
                 summary: "Newer informational runner event #{index}",
                 occurred_at: DateTime.add(now, index, :second)
               })
    end

    summary =
      Observability.org_health_summary_for_org(org.id, 0, [], now: DateTime.add(now, 30, :second))

    assert summary.health == "critical"
    assert :critical_events in summary.reason_codes
  end

  test "org health summary for org ignores facts outside freshness windows", %{org: org} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "critical",
               summary: "Expired critical runner event",
               occurred_at: DateTime.add(now, -120, :second)
             })

    summary =
      Observability.org_health_summary_for_org(org.id, 0, [],
        now: now,
        freshness_policy: %{
          event_history_seconds: 60,
          operation_run_history_seconds: 60,
          check_result_history_seconds: 60
        }
      )

    assert summary == %{health: "unknown", reason_codes: [:no_operations_facts]}
  end

  test "redaction corpus covers secrets tokens provider payloads prompts messages and pii" do
    payload = %{
      app_secret: "secret-value",
      access_token: "xoxb-12345678901234567890",
      nested: %{
        provider_payload: %{"raw" => "provider response"},
        system_prompt: "You are a private agent",
        message_body: "customer private message",
        email: "admin@example.com",
        mobile: "+15551234567",
        value: "sk-testabcdefghijklmnopqrstuvwxyz",
        local_evidence_path: "/Users/operator/.comma/fin/evidence.json",
        raw_path: "/tmp/customer/raw.log",
        file_path: "/var/tmp/customer-secrets.txt",
        evidence_path: "s3://private-bucket/customer/evidence.json",
        path: "/home/operator/.ssh/id_rsa",
        cleanup_paths: ["/tmp/raw-a", "/tmp/raw-b"],
        path_label: "/tmp/raw-label",
        evidence_path_label: "configured",
        settings_path: "settings/oauth"
      },
      metrics: %{
        response_time_ms: 231,
        content_length: 42,
        message_count: 3,
        total_tokens: 99,
        stdout_bytes: 120,
        stderr_bytes: 12
      },
      stdout: "plain command output must not persist",
      stderr: "plain error output must not persist"
    }

    redacted = Observability.redact_payload(payload)

    assert redacted["app_secret"] == "[REDACTED]"
    assert redacted["access_token"] == "[REDACTED]"
    assert redacted["nested"]["provider_payload"] == "[REDACTED]"
    assert redacted["nested"]["system_prompt"] == "[REDACTED]"
    assert redacted["nested"]["message_body"] == "[REDACTED]"
    assert redacted["nested"]["email"] == "[REDACTED]"
    assert redacted["nested"]["mobile"] == "[REDACTED]"
    assert redacted["nested"]["value"] == "[REDACTED]"
    assert redacted["nested"]["local_evidence_path"] == "[REDACTED]"
    assert redacted["nested"]["raw_path"] == "[REDACTED]"
    assert redacted["nested"]["file_path"] == "[REDACTED]"
    assert redacted["nested"]["evidence_path"] == "[REDACTED]"
    assert redacted["nested"]["path"] == "[REDACTED]"
    assert redacted["nested"]["cleanup_paths"] == "[REDACTED]"
    assert redacted["nested"]["path_label"] == "[REDACTED]"
    assert redacted["nested"]["evidence_path_label"] == "configured"
    assert redacted["nested"]["settings_path"] == "settings/oauth"
    assert redacted["metrics"]["response_time_ms"] == 231
    assert redacted["metrics"]["content_length"] == 42
    assert redacted["metrics"]["message_count"] == 3
    assert redacted["metrics"]["total_tokens"] == 99
    assert redacted["metrics"]["stdout_bytes"] == 120
    assert redacted["metrics"]["stderr_bytes"] == 12
    assert redacted["stdout"] == "[REDACTED]"
    assert redacted["stderr"] == "[REDACTED]"

    redacted_text = inspect(redacted)
    refute redacted_text =~ "secret-value"
    refute redacted_text =~ "xoxb-"
    refute redacted_text =~ "provider response"
    refute redacted_text =~ "private agent"
    refute redacted_text =~ "private message"
    refute redacted_text =~ "admin@example.com"
    refute redacted_text =~ "sk-test"
    refute redacted_text =~ "/Users/operator/.comma"
    refute redacted_text =~ "/tmp/customer"
    refute redacted_text =~ "/var/tmp/customer"
    refute redacted_text =~ "private-bucket"
    refute redacted_text =~ "/home/operator"
    refute redacted_text =~ "/tmp/raw"
    refute redacted_text =~ "plain command output"
    refute redacted_text =~ "plain error output"
  end

  test "quarantine_record removes persisted payloads after a redaction miss", %{
    org: org,
    project: project,
    user: user
  } do
    now = ~U[2026-06-22 00:00:00Z]

    event =
      %ObservabilityEvent{}
      |> ObservabilityEvent.changeset(%{
        org_id: org.id,
        project_id: project.id,
        domain: "integration",
        resource_type: "unsafe_event",
        source: "bft.dashboard",
        event_type: "unsafe.event",
        severity: "error",
        summary: "Unsafe event",
        evidence: %{"missed" => "missed-secret-value"},
        evidence_size_bytes: 12,
        occurred_at: now
      })
      |> Repo.insert!()

    run =
      %OperationRun{}
      |> OperationRun.changeset(%{
        org_id: org.id,
        project_id: project.id,
        run_type: "fin_exec",
        status: "failed",
        evidence: %{"missed" => "run-secret-value"},
        evidence_size_bytes: 12,
        stderr_tail_redacted: "stderr still has secret"
      })
      |> Repo.insert!()

    check =
      %CheckResult{}
      |> CheckResult.changeset(%{
        org_id: org.id,
        project_id: project.id,
        check_family: "feishu_setup",
        surface: "feishu",
        subject_type: "binding",
        subject_id: "unsafe-check",
        status: "fail",
        result: %{"missed" => "check-secret-value"},
        result_size_bytes: 12,
        ran_at: now
      })
      |> Repo.insert!()

    audit =
      %AuditLog{}
      |> AuditLog.changeset(%{
        org_id: org.id,
        actor_user_id: user.id,
        action: "unsafe.write",
        resource_type: "unsafe",
        resource_id: "unsafe-audit",
        result: "failed",
        metadata: %{"missed" => "audit-secret-value"},
        redacted_diff: %{"missed" => "diff-secret-value"},
        metadata_size_bytes: 12
      })
      |> Repo.insert!()

    opts = [
      reason_class: "redaction_miss",
      now: now,
      operator_note: "secret=still-hidden"
    ]

    assert {:ok, quarantined_event} = Observability.quarantine_record(:event, event.id, opts)
    assert quarantined_event.status == "quarantined"
    assert quarantined_event.summary == "Quarantined observability event"
    assert quarantined_event.evidence["quarantined"] == "true"
    assert quarantined_event.evidence["record_type"] == "observability_event"
    assert quarantined_event.evidence["payload_field"] == "evidence"
    assert quarantined_event.evidence["reason_class"] == "redaction_miss"
    assert quarantined_event.evidence["operator_note"] == "[REDACTED]"

    assert {:ok, quarantined_run} = Observability.quarantine_record("operation_run", run.id, opts)
    assert quarantined_run.status == "unknown"
    assert quarantined_run.stderr_tail_redacted == nil
    assert quarantined_run.evidence["record_type"] == "operation_run"

    assert {:ok, quarantined_check} =
             Observability.quarantine_record(:check_result, check.id, opts)

    assert quarantined_check.status == "unknown"
    assert quarantined_check.result["record_type"] == "check_result"
    assert quarantined_check.result["payload_field"] == "result"

    assert {:ok, quarantined_audit} = Observability.quarantine_record("audit_log", audit.id, opts)
    assert quarantined_audit.result == "unknown"
    assert quarantined_audit.metadata["record_type"] == "audit_log"
    assert quarantined_audit.metadata["payload_field"] == "metadata"
    assert quarantined_audit.redacted_diff["payload_field"] == "redacted_diff"

    assert {:error, :not_found} = Observability.quarantine_record(:event, Ecto.UUID.generate())

    assert {:error, :unsupported_record_type} =
             Observability.quarantine_record(:unknown, event.id)

    refute inspect([quarantined_event, quarantined_run, quarantined_check, quarantined_audit]) =~
             "missed-secret"

    refute inspect([quarantined_event, quarantined_run, quarantined_check, quarantined_audit]) =~
             "still-hidden"
  end

  test "observability event summary is redacted before persistence", %{org: org} do
    assert {:ok, event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "integration",
               resource_type: "provider_check",
               source: "bft.dashboard",
               event_type: "provider.failed",
               severity: "error",
               summary:
                 "provider returned token sk-testabcdefghijklmnopqrstuvwxyz for admin@example.com",
               evidence: %{status_code: 401}
             })

    assert event.summary == "[REDACTED]"
  end

  test "salix im sink records Feishu callback diagnostics as project scoped events", %{
    org: org,
    project: project
  } do
    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               source: "salix.im",
               group_id: project.salix_group_id,
               connect_id: "feishu-connect-1",
               app_id: "cli_app",
               event_type: "feishu.callback.ignored",
               severity: "warning",
               status: "ignored",
               reason_class: "bot_mention_mismatch",
               summary: "Feishu callback ignored",
               provider_event_type: "im.message.receive_v1",
               provider_event_id: "evt-feishu-1",
               message_id: "om-feishu-1",
               chat_id: "oc-feishu-1",
               chat_type: "group",
               callback_mode: "message",
               delivery_state: "ignored",
               message_body: "must not persist"
             })

    assert [event] = Observability.list_events(org.id, source: "salix.im")
    assert event.project_id == project.id
    assert event.domain == "integration"
    assert event.resource_type == "feishu_connect"
    assert event.resource_id == "feishu-connect-1"
    assert event.event_type == "feishu.callback.ignored"
    assert event.severity == "warning"
    assert event.status == "ignored"
    assert event.reason_class == "bot_mention_mismatch"
    assert event.correlation_id == "evt-feishu-1"
    assert event.evidence["provider"] == "feishu"
    assert event.evidence["message_id"] == "om-feishu-1"
    assert event.evidence["chat_id"] == "oc-feishu-1"
    assert event.evidence["delivery_state"] == "ignored"
    refute inspect(event.evidence) =~ "must not persist"

    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               source: "salix.im",
               group_id: project.salix_group_id,
               connect_id: "feishu-connect-1",
               event_type: "feishu.callback.ignored",
               severity: "warning",
               status: "ignored",
               reason_class: "bot_mention_mismatch",
               summary: "Feishu callback ignored again",
               provider_event_id: "evt-feishu-1",
               message_id: "om-feishu-1",
               chat_id: "oc-feishu-updated",
               delivery_state: "ignored"
             })

    assert [updated] = Observability.list_events(org.id, source: "salix.im")
    assert updated.id == event.id
    assert updated.summary == "Feishu callback ignored again"
    assert updated.evidence["chat_id"] == "oc-feishu-updated"

    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               group_id: "not-a-bft-project",
               event_type: "feishu.callback.queued"
             })

    assert [_event] = Observability.list_events(org.id, source: "salix.im")
  end

  test "upserts observability events by source event type and correlation id", %{
    org: org,
    project: project
  } do
    attrs = %{
      org_id: org.id,
      project_id: project.id,
      domain: "integration",
      resource_type: "feishu_connect",
      resource_id: "feishu-connect-repeat",
      source: "salix.im",
      event_type: "feishu.callback.duplicate",
      severity: "info",
      status: "duplicate",
      reason_class: "duplicate_event",
      summary: "Feishu callback duplicate ignored",
      evidence: %{message_id: "om-repeat-1", delivery_state: "duplicate"},
      correlation_id: "evt-repeat-1"
    }

    assert {:ok, %ObservabilityEvent{} = first} = Observability.create_event(attrs)

    assert {:ok, %ObservabilityEvent{} = updated} =
             Observability.create_event(
               Map.merge(attrs, %{
                 severity: "warning",
                 summary: "Feishu callback duplicate refreshed",
                 evidence: %{
                   message_id: "om-repeat-1",
                   delivery_state: "duplicate",
                   app_secret: "do-not-keep"
                 }
               })
             )

    assert updated.id == first.id
    assert updated.severity == "warning"
    assert updated.summary == "Feishu callback duplicate refreshed"
    assert updated.evidence["app_secret"] == "[REDACTED]"

    assert Repo.aggregate(
             from(e in ObservabilityEvent,
               where:
                 e.org_id == ^org.id and e.source == "salix.im" and
                   e.correlation_id == "evt-repeat-1"
             ),
             :count
           ) == 1

    assert {:ok, %ObservabilityEvent{} = distinct} =
             Observability.create_event(%{
               attrs
               | event_type: "feishu.callback.queued",
                 status: "queued",
                 reason_class: nil,
                 summary: "Feishu callback queued"
             })

    refute distinct.id == first.id

    assert Repo.aggregate(
             from(e in ObservabilityEvent,
               where:
                 e.org_id == ^org.id and e.source == "salix.im" and
                   e.correlation_id == "evt-repeat-1"
             ),
             :count
           ) == 2
  end

  test "rate limits high-volume event sources while allowing idempotent updates", %{
    org: org,
    project: project
  } do
    previous = Application.get_env(:bridge_for_teams_core, :observability_event_rate_limit)

    Application.put_env(:bridge_for_teams_core, :observability_event_rate_limit,
      enabled: true,
      window_seconds: 60,
      max_events_per_source: 1
    )

    on_exit(fn -> restore_event_rate_limit(previous) end)

    attrs = %{
      org_id: org.id,
      project_id: project.id,
      domain: "integration",
      resource_type: "feishu_connect",
      resource_id: "feishu-connect-rate",
      source: "salix.im",
      event_type: "feishu.callback.queued",
      severity: "info",
      status: "queued",
      summary: "Feishu callback queued",
      evidence: %{delivery_state: "queued"},
      correlation_id: "evt-rate-1"
    }

    assert {:ok, %ObservabilityEvent{} = first} = Observability.create_event(attrs)

    assert {:ok, %ObservabilityEvent{} = updated} =
             Observability.create_event(%{attrs | severity: "warning"})

    assert updated.id == first.id
    assert updated.severity == "warning"

    {{:error, {:backpressure, detail}}, log} =
      with_log(fn ->
        Observability.create_event(%{
          attrs
          | resource_id: "feishu-connect-rate-limited",
            event_type: "feishu.callback.ignored",
            correlation_id: "evt-rate-2",
            status: "ignored",
            summary: "Feishu callback ignored"
        })
      end)

    assert log =~ "bridge_for_teams.observability.ingest.dropped"
    assert log =~ "record_type=event"
    assert log =~ "reason=backpressure"
    assert log =~ "limit=1"
    assert log =~ "retry_after_ms=60000"
    assert log =~ "window_seconds=60"
    assert log =~ "source=salix.im"
    assert log =~ "event_type=feishu.callback.ignored"
    refute log =~ "feishu-connect-rate-limited"
    assert detail == %{limit: 1, retry_after_ms: 60_000, window_seconds: 60}

    assert Repo.aggregate(
             from(e in ObservabilityEvent,
               where: e.org_id == ^org.id and e.source == "salix.im"
             ),
             :count
           ) == 1
  end

  test "salix im sink records Feishu reply diagnostics as conversation events", %{
    org: org,
    project: project
  } do
    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               source: "salix.im",
               domain: "conversation",
               group_id: project.salix_group_id,
               connect_id: "feishu-connect-reply",
               app_id: "cli_app",
               event_type: "feishu.reply.sent",
               severity: "info",
               status: "reply_sent",
               summary: "Feishu reply sent",
               operation_api: "feishu.reply_text",
               request_id: "req-reply-sink-1",
               correlation_id: "req-reply-sink-1",
               source_message_id: "om-inbound-1",
               reply_message_id: "om-reply-1",
               delivery_state: "reply_sent",
               message_body: "must not persist"
             })

    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               source: "salix.im",
               domain: "conversation",
               group_id: project.salix_group_id,
               connect_id: "feishu-connect-reply",
               app_id: "cli_app",
               event_type: "feishu.reply.failed",
               severity: "error",
               status: "reply_failed",
               reason_class: "provider_api_error",
               summary: "Feishu reply failed",
               operation_api: "feishu.reply_text",
               source_message_id: "om-inbound-1",
               delivery_state: "reply_failed",
               content: "must not persist either"
             })

    events = Observability.list_events(org.id, domain: "conversation")

    assert Enum.map(events, & &1.event_type) |> Enum.sort() == [
             "feishu.reply.failed",
             "feishu.reply.sent"
           ]

    sent = Enum.find(events, &(&1.event_type == "feishu.reply.sent"))
    failed = Enum.find(events, &(&1.event_type == "feishu.reply.failed"))

    assert sent.project_id == project.id
    assert sent.resource_type == "feishu_message"
    assert sent.resource_id == "om-inbound-1"
    assert sent.correlation_id == "req-reply-sink-1"
    assert sent.evidence["operation_api"] == "feishu.reply_text"
    assert sent.evidence["request_id"] == "req-reply-sink-1"
    assert sent.evidence["source_message_id"] == "om-inbound-1"
    assert sent.evidence["reply_message_id"] == "om-reply-1"
    assert sent.evidence["delivery_state"] == "reply_sent"

    assert failed.status == "reply_failed"
    assert failed.severity == "error"
    assert failed.reason_class == "provider_api_error"
    assert failed.correlation_id == "om-inbound-1"
    assert failed.evidence["source_message_id"] == "om-inbound-1"

    refute inspect(events) =~ "must not persist"
  end

  test "salix im sink records Slack reply diagnostics as conversation events", %{
    org: org,
    project: project
  } do
    assert :ok =
             SalixIMSink.record(%{
               provider: "slack",
               source: "salix.im",
               domain: "conversation",
               group_id: project.salix_group_id,
               connect_id: "slack-connect-reply",
               app_id: "A-slack",
               workspace_id: "T-slack",
               event_type: "slack.reply.sent",
               severity: "info",
               status: "reply_sent",
               summary: "Slack reply sent",
               operation_api: "slack.post_message",
               request_id: "req-slack-reply-sink-1",
               correlation_id: "req-slack-reply-sink-1",
               channel_id: "C9",
               thread_ts: "1.0",
               message_ts: "1.2",
               source_message_id: "im_provider:slack:slack-connect-reply:C9:1.0",
               reply_message_id: "im_provider:slack:slack-connect-reply:C9:1.2",
               delivery_state: "reply_sent",
               text: "must not persist"
             })

    assert :ok =
             SalixIMSink.record(%{
               provider: "slack",
               source: "salix.im",
               domain: "conversation",
               group_id: project.salix_group_id,
               connect_id: "slack-connect-reply",
               app_id: "A-slack",
               workspace_id: "T-slack",
               event_type: "slack.message.failed",
               severity: "error",
               status: "send_failed",
               reason_class: "missing_scope",
               summary: "Slack message failed",
               operation_api: "slack.post_message",
               channel_id: "C9",
               source_message_id: "im_provider:slack:slack-connect-reply:C9:1.0",
               delivery_state: "send_failed",
               blocks: [%{"text" => "must not persist either"}]
             })

    events = Observability.list_events(org.id, domain: "conversation")

    assert Enum.map(events, & &1.event_type) |> Enum.sort() == [
             "slack.message.failed",
             "slack.reply.sent"
           ]

    sent = Enum.find(events, &(&1.event_type == "slack.reply.sent"))
    failed = Enum.find(events, &(&1.event_type == "slack.message.failed"))

    assert sent.project_id == project.id
    assert sent.resource_type == "slack_message"
    assert sent.resource_id == "im_provider:slack:slack-connect-reply:C9:1.0"
    assert sent.correlation_id == "req-slack-reply-sink-1"
    assert sent.evidence["provider"] == "slack"
    assert sent.evidence["operation_api"] == "slack.post_message"
    assert sent.evidence["workspace_id"] == "T-slack"
    assert sent.evidence["channel_id"] == "C9"
    assert sent.evidence["thread_ts"] == "1.0"
    assert sent.evidence["message_ts"] == "1.2"
    assert sent.evidence["reply_message_id"] == "im_provider:slack:slack-connect-reply:C9:1.2"

    assert failed.status == "send_failed"
    assert failed.severity == "error"
    assert failed.reason_class == "missing_scope"
    assert failed.correlation_id == "im_provider:slack:slack-connect-reply:C9:1.0"
    assert failed.evidence["source_message_id"] == "im_provider:slack:slack-connect-reply:C9:1.0"

    refute inspect(events) =~ "must not persist"
  end

  test "salix im sink records Feishu inbound lifecycle diagnostics as conversation events", %{
    org: org,
    project: project
  } do
    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               source: "salix.im",
               domain: "conversation",
               group_id: project.salix_group_id,
               connect_id: "feishu-connect-inbound",
               event_type: "feishu.message.received",
               severity: "info",
               status: "received",
               summary: "Feishu message received",
               provider_event_id: "evt-feishu-inbound-1",
               request_id: "req-feishu-inbound-1",
               message_id: "om-inbound-1",
               source_message_id: "im_provider:feishu:feishu-connect-inbound:om-inbound-1",
               chat_id: "oc-inbound-1",
               delivery_state: "received",
               content: "must not persist"
             })

    assert :ok =
             SalixIMSink.record(%{
               provider: "feishu",
               source: "salix.im",
               domain: "conversation",
               group_id: project.salix_group_id,
               connect_id: "feishu-connect-inbound",
               event_type: "feishu.message.delivered",
               severity: "info",
               status: "delivered",
               summary: "Feishu message delivered",
               provider_event_id: "evt-feishu-inbound-1",
               request_id: "req-feishu-inbound-1",
               message_id: "om-inbound-1",
               source_message_id: "im_provider:feishu:feishu-connect-inbound:om-inbound-1",
               delivery_state: "delivered",
               text: "must not persist either"
             })

    events = Observability.list_events(org.id, event_type: "feishu.message.received")
    assert [received] = events
    assert received.project_id == project.id
    assert received.domain == "conversation"
    assert received.resource_type == "feishu_message"
    assert received.resource_id == "im_provider:feishu:feishu-connect-inbound:om-inbound-1"
    assert received.correlation_id == "req-feishu-inbound-1"
    assert received.evidence["request_id"] == "req-feishu-inbound-1"
    assert received.evidence["source_message_id"] == received.resource_id
    assert received.evidence["delivery_state"] == "received"

    assert [delivered] = Observability.list_events(org.id, event_type: "feishu.message.delivered")
    assert delivered.status == "delivered"
    assert delivered.evidence["delivery_state"] == "delivered"

    refute inspect([received, delivered]) =~ "must not persist"
  end

  test "creates and lists redacted observability events by org", %{
    org: org,
    other_org: other_org,
    project: project,
    user: user
  } do
    assert {:ok, %ObservabilityEvent{} = event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               actor_user_id: user.id,
               domain: "integration",
               resource_type: "feishu_connect",
               resource_id: "conn_1",
               source: "bft.run_checks",
               event_type: "run_checks.completed",
               severity: "warning",
               status: "needs_manual",
               reason_class: "feishu_console_steps_required",
               summary: "Feishu checks require manual console steps",
               evidence: %{
                 app_id: "cli_app",
                 app_secret: "super-secret",
                 customer_email: "admin@example.com",
                 local_evidence_path: "/Users/operator/.comma/fin/evidence.json",
                 raw_path: "/tmp/customer/raw.log",
                 file_path: "/var/tmp/customer-secrets.txt",
                 evidence_path: "s3://private-bucket/customer/evidence.json",
                 evidence_path_label: "configured",
                 settings_path: "settings/oauth",
                 nested: %{verification_token: "token-value", http_status: 200}
               },
               correlation_id: "req_1"
             })

    assert event.evidence["app_id"] == "cli_app"
    assert event.evidence["app_secret"] == "[REDACTED]"
    assert event.evidence["customer_email"] == "[REDACTED]"
    assert event.evidence["local_evidence_path"] == "[REDACTED]"
    assert event.evidence["raw_path"] == "[REDACTED]"
    assert event.evidence["file_path"] == "[REDACTED]"
    assert event.evidence["evidence_path"] == "[REDACTED]"
    assert event.evidence["evidence_path_label"] == "configured"
    assert event.evidence["settings_path"] == "settings/oauth"
    assert event.evidence["nested"]["verification_token"] == "[REDACTED]"
    assert event.evidence["nested"]["http_status"] == 200
    assert event.evidence_size_bytes > 0

    persisted_text = inspect(event.evidence)
    refute persisted_text =~ "/Users/operator/.comma"
    refute persisted_text =~ "/tmp/customer"
    refute persisted_text =~ "/var/tmp/customer"
    refute persisted_text =~ "private-bucket"

    assert [listed] = Observability.list_events(org.id)
    assert listed.id == event.id
    assert Observability.list_events(other_org.id) == []
  end

  test "cursor paginates observability events by time", %{org: org} do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for {summary, offset} <- [{"Newest", 0}, {"Middle", -1}, {"Oldest", -2}] do
      assert {:ok, _event} =
               Observability.create_event(%{
                 org_id: org.id,
                 domain: "runner",
                 resource_type: "mac_mini_provisioner",
                 source: "mac_mini.provisioner",
                 event_type: "runner.status_changed",
                 severity: "info",
                 summary: summary,
                 occurred_at: DateTime.add(now, offset, :second)
               })
    end

    assert %{entries: [newest, middle], next_cursor: cursor} =
             Observability.page_events(org.id, limit: 2)

    assert newest.summary == "Newest"
    assert middle.summary == "Middle"
    assert is_binary(cursor)

    assert %{entries: [oldest], next_cursor: nil} =
             Observability.page_events(org.id, limit: 2, after: cursor)

    assert oldest.summary == "Oldest"
  end

  test "rejects project references outside the event org", %{
    org: org,
    other_project: other_project
  } do
    assert {:error, :project_scope_mismatch} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: other_project.id,
               domain: "project",
               resource_type: "project",
               source: "bft.dashboard",
               event_type: "project.viewed",
               severity: "info",
               summary: "Project viewed"
             })
  end

  test "cross-org filters return no linked records", %{
    org: org,
    other_org: other_org,
    other_project: other_project,
    user: user
  } do
    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: other_org.id,
               project_id: other_project.id,
               domain: "integration",
               resource_type: "feishu_connect",
               source: "bft.run_checks",
               event_type: "run_checks.completed",
               severity: "warning",
               summary: "Other org integration warning"
             })

    assert {:ok, _run} =
             Observability.create_operation_run(%{
               org_id: other_org.id,
               project_id: other_project.id,
               run_type: "fin_exec",
               external_run_id: "other-org-run",
               status: "failed"
             })

    assert {:ok, _check} =
             Observability.create_check_result(%{
               org_id: other_org.id,
               project_id: other_project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: other_project.id,
               status: "fail",
               result: %{status: "fail"},
               ran_at: DateTime.utc_now()
             })

    assert {:ok, _audit} =
             Observability.record_audit(%{
               org_id: other_org.id,
               actor_user_id: user.id,
               action: "project.updated",
               resource_type: "project",
               resource_id: other_project.id,
               result: "ok"
             })

    assert %{entries: [], next_cursor: nil} =
             Observability.page_events(org.id, project_id: other_project.id)

    assert %{entries: [], next_cursor: nil} =
             Observability.page_operation_runs(org.id, project_id: other_project.id)

    assert %{entries: [], next_cursor: nil} =
             Observability.page_check_results(org.id, project_id: other_project.id)

    assert %{entries: [], next_cursor: nil} =
             Observability.page_audit_logs(org.id, resource_id: other_project.id)
  end

  test "linked id filters isolate event run check and audit records", %{
    org: org,
    project: project,
    user: user
  } do
    assert {:ok, run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               project_id: project.id,
               run_type: "fin_exec",
               external_run_id: "finrun-linked-filter",
               request_id: "req-linked-filter",
               status: "failed"
             })

    assert {:ok, check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "fail",
               result: %{status: "fail"},
               ran_at: DateTime.utc_now()
             })

    assert {:ok, linked_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               run_record_id: run.id,
               check_result_id: check.id,
               domain: "check",
               resource_type: "run_checks",
               resource_id: check.id,
               source: "bft.dashboard",
               event_type: "run_checks.completed",
               severity: "error",
               summary: "Linked run and check failure"
             })

    assert {:ok, audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "settings.sso.updated",
               resource_type: "sso",
               resource_id: org.id,
               result: "ok"
             })

    assert %{entries: [filtered_event]} =
             Observability.page_events(org.id, run_record_id: run.id)

    assert filtered_event.id == linked_event.id

    assert %{entries: [filtered_event]} =
             Observability.page_events(org.id, check_result_id: check.id)

    assert filtered_event.id == linked_event.id

    assert %{entries: [audit_event]} =
             Observability.page_events(org.id, audit_log_id: audit.id)

    assert audit_event.audit_log_id == audit.id

    assert %{entries: [filtered_run]} =
             Observability.page_operation_runs(org.id, run_record_id: run.id)

    assert filtered_run.id == run.id

    assert %{entries: [filtered_check]} =
             Observability.page_check_results(org.id, check_result_id: check.id)

    assert filtered_check.id == check.id

    assert %{entries: [filtered_audit]} =
             Observability.page_audit_logs(org.id, audit_log_id: audit.id)

    assert filtered_audit.id == audit.id
  end

  test "check result pages filter by nested gate status", %{org: org, project: project} do
    assert {:ok, manual_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "needs_manual",
               result: %{
                 gates: [
                   %{
                     gate_id: "bot.scope_batch",
                     label: "Scope batch import",
                     status: "needs_manual"
                   }
                 ]
               },
               invocation_id: "gate-status-manual",
               ran_at: DateTime.utc_now()
             })

    assert {:ok, _failed_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "fail",
               result: %{
                 gates: [
                   %{
                     gate_id: "bot.credentials",
                     label: "Credentials",
                     status: "fail"
                   }
                 ]
               },
               invocation_id: "gate-status-fail",
               ran_at: DateTime.add(DateTime.utc_now(), 1, :second)
             })

    assert %{entries: [filtered_check], next_cursor: nil} =
             Observability.page_check_results(org.id, gate_status: "needs_manual")

    assert filtered_check.id == manual_check.id
    assert [] = Observability.list_check_results(org.id, gate_status: "skipped")
  end

  test "rejects unknown event domains, severities, and sources", %{org: org} do
    assert {:error, changeset} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "unknown_domain",
               resource_type: "project",
               source: "bft.dashboard",
               event_type: "project.viewed",
               severity: "info",
               summary: "Project viewed"
             })

    assert %{domain: ["is invalid"]} = errors_on(changeset)

    assert {:error, changeset} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "project",
               resource_type: "project",
               source: "bft.dashboard",
               event_type: "project.viewed",
               severity: "loud",
               summary: "Project viewed"
             })

    assert %{severity: ["is invalid"]} = errors_on(changeset)

    assert {:error, changeset} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "project",
               resource_type: "project",
               source: "random.source",
               event_type: "project.viewed",
               severity: "info",
               summary: "Project viewed"
             })

    assert %{source: ["is invalid"]} = errors_on(changeset)
  end

  test "creates operation runs with runner scope validation and redacted stderr", %{
    org: org,
    project: project
  } do
    assert {:ok, provisioner} =
             Environments.register_mac_mini_provisioner(org.id, %{
               "stable_id" => "mac-mini-1",
               "name" => "Lab Mac mini"
             })

    assert {:ok, %OperationRun{} = run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               project_id: project.id,
               runner_type: "mac_mini_provisioner",
               runner_id: provisioner.id,
               run_type: "fin_exec",
               external_run_id: "run_1",
               request_id: "req_1",
               status: "failed",
               reason_class: "command_failed",
               exit_code: 1,
               duration_ms: 1234,
               stderr_tail_redacted: "authorization: Bearer very-secret-token",
               evidence: %{command_hash: "sha256:abc", raw_command: "cat /secret"}
             })

    assert run.stderr_tail_redacted == "[REDACTED]"
    assert run.evidence["command_hash"] == "sha256:abc"
    assert run.evidence["raw_command"] == "[REDACTED]"
    assert [listed] = Observability.list_operation_runs(org.id, run_type: "fin_exec")
    assert listed.id == run.id
  end

  test "operation run types only include producer-backed contracts", %{org: org} do
    assert OperationRun.run_types() ==
             ~w(fin_exec device_provision run_check meeting_summary_replay)

    assert {:error, changeset} =
             Observability.create_operation_run(%{
               org_id: org.id,
               run_type: "delivery_smoke",
               status: "failed"
             })

    assert %{run_type: ["is invalid"]} = errors_on(changeset)
  end

  test "upserts operation runs by external run id", %{org: org, project: project} do
    attrs = %{
      org_id: org.id,
      project_id: project.id,
      run_type: "fin_exec",
      external_run_id: "run_repeat_1",
      request_id: "req_repeat_1",
      status: "running",
      evidence: %{component: "salix-connect"}
    }

    assert {:ok, %OperationRun{} = first} = Observability.create_operation_run(attrs)

    assert {:ok, %OperationRun{} = updated} =
             Observability.create_operation_run(
               Map.merge(attrs, %{
                 status: "failed",
                 reason_class: "command_failed",
                 exit_code: 1,
                 stderr_tail_redacted: "stderr token=secret"
               })
             )

    assert updated.id == first.id
    assert updated.status == "failed"
    assert updated.reason_class == "command_failed"
    assert updated.exit_code == 1

    assert [listed] =
             Observability.list_operation_runs(org.id, external_run_id: "run_repeat_1")

    assert listed.id == first.id
  end

  test "create_operation_run_once reports an existing external run instead of a phantom row", %{
    org: org,
    project: project
  } do
    attrs = %{
      org_id: org.id,
      project_id: project.id,
      run_type: "meeting_summary_replay",
      external_run_id: "meeting_summary_replay:once-1",
      request_id: "once-1",
      status: "running",
      evidence: %{"meeting_id" => "meeting-1", "mode" => "model_replay"}
    }

    assert {:ok, %OperationRun{} = persisted} = Observability.create_operation_run_once(attrs)
    assert {:error, :already_exists} = Observability.create_operation_run_once(attrs)

    assert [%OperationRun{id: persisted_id}] =
             Observability.list_operation_runs(org.id,
               external_run_id: "meeting_summary_replay:once-1"
             )

    assert persisted_id == persisted.id
  end

  test "rejects mac mini runner references outside the org", %{org: org, other_org: other_org} do
    assert {:ok, other_provisioner} =
             Environments.register_mac_mini_provisioner(other_org.id, %{
               "stable_id" => "other-mac-mini",
               "name" => "Other Mac mini"
             })

    assert {:error, :runner_scope_mismatch} =
             Observability.create_operation_run(%{
               org_id: org.id,
               runner_type: "mac_mini_provisioner",
               runner_id: other_provisioner.id,
               run_type: "fin_exec",
               status: "failed"
             })
  end

  test "rejects runner-linked records without a known runner type", %{org: org} do
    runner_id = Ecto.UUID.generate()

    assert {:error, :runner_type_required} =
             Observability.create_event(%{
               org_id: org.id,
               runner_id: runner_id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "warning",
               summary: "Runner status changed"
             })

    assert {:error, :unknown_runner_type} =
             Observability.create_operation_run(%{
               org_id: org.id,
               runner_type: "unknown_runner",
               runner_id: runner_id,
               run_type: "fin_exec",
               status: "failed"
             })
  end

  test "persists run checks idempotently by invocation id", %{
    org: org,
    project: project,
    user: user
  } do
    result = %{
      surface: "bot",
      org_ref: org.id,
      project_ref: project.id,
      connect_ref: "conn_1",
      ran_at: DateTime.utc_now(),
      gates: [
        %{
          gate_id: "bot.credentials",
          label: "App ID + Secret valid",
          status: :ok,
          reason_class: :validated,
          next_action: "No action",
          evidence: %{app_secret: "dont-leak-me"}
        },
        %{
          gate_id: "bot.manual",
          label: "Feishu console steps completed",
          status: :needs_manual,
          reason_class: :feishu_console_steps_required,
          next_action: "Import scopes",
          evidence: %{required_scopes: ["im:message:send_as_bot"]}
        }
      ]
    }

    assert {:ok, %CheckResult{} = first} =
             Observability.record_run_checks(result,
               ran_by_user_id: user.id,
               invocation_id: "run_checks_req_1"
             )

    assert {:ok, %CheckResult{} = second} =
             Observability.record_run_checks(result,
               ran_by_user_id: user.id,
               invocation_id: "run_checks_req_1"
             )

    assert second.id == first.id
    assert first.status == "needs_manual"
    assert first.reason_class == "feishu_console_steps_required"
    assert first.subject_type == "project"
    assert first.subject_id == project.id
    assert first.result["gates"] |> hd() |> get_in(["evidence", "app_secret"]) == "[REDACTED]"
  end

  test "records run checks activity as a check event and audit trail", %{
    org: org,
    project: project,
    user: user
  } do
    result = %{
      surface: "bot",
      org_ref: org.id,
      project_ref: project.id,
      connect_ref: "conn_1",
      ran_at: DateTime.utc_now(),
      gates: [
        %{
          gate_id: "bot.credentials",
          label: "App ID + Secret valid",
          status: :fail,
          reason_class: :secrets_not_configured,
          next_action: "Salix has not resolved the Feishu bot open_id yet.",
          evidence: %{app_secret: "secret", open_id: "ou_secret"}
        }
      ]
    }

    assert {:ok, %CheckResult{} = check} =
             Observability.record_run_checks_activity(result,
               ran_by_user_id: user.id,
               request_id: "req_run_checks_1"
             )

    assert check.status == "fail"

    assert [event] = Observability.list_events(org.id, domain: "check")
    assert event.check_result_id == check.id
    assert event.severity == "error"
    assert event.status == "fail"
    assert event.correlation_id == "req_run_checks_1"
    assert event.evidence["actionable_gate"]["reason_class"] == "secrets_not_configured"
    assert event.evidence["actionable_gate"]["next_action"] =~ "open_id"
    refute inspect(event.evidence) =~ "dont-leak-me"

    assert [audit] = Observability.list_audit_logs(org.id, action: "run_checks.ran")
    assert audit.resource_id == check.id
    assert audit.request_id == "req_run_checks_1"
    assert audit.metadata["actionable_gate"]["gate_id"] == "bot.credentials"
    assert audit.metadata["actionable_gate"]["next_action"] =~ "open_id"
    refute inspect(audit.metadata) =~ "dont-leak-me"

    [gate] = check.result["gates"]
    assert gate["next_action"] =~ "open_id"
    assert gate["evidence"]["open_id"] == "[REDACTED]"
  end

  test "optional skipped run-check gates remain raw evidence without degrading health", %{
    org: org,
    project: project,
    user: user
  } do
    result =
      RunChecks.to_json_map(%{
        surface: "bot",
        org_ref: org.id,
        project_ref: project.id,
        connect_ref: "conn_optional_calendar",
        ran_at: DateTime.utc_now(),
        gates: [
          %{
            gate_id: "bot.callback",
            label: "Callback ready",
            status: :ok,
            reason_class: :validated,
            next_action: "No action"
          },
          %{
            gate_id: "bot.calendar",
            label: "Optional Calendar notification",
            status: :skipped,
            reason_class: :calendar_notification_not_configured,
            next_action: "Configure only when start-time group notifications are wanted",
            required: false
          }
        ]
      })

    assert {:ok, %CheckResult{} = check} =
             Observability.record_run_checks_activity(result,
               ran_by_user_id: user.id,
               request_id: "req_optional_calendar"
             )

    assert check.status == "ok"
    assert is_nil(check.reason_class)

    assert [callback_gate, calendar_gate] = check.result["gates"]
    assert callback_gate["status"] == "ok"
    assert callback_gate["required"] == true
    assert callback_gate["redacted"] == true
    assert calendar_gate["status"] == "skipped"
    assert calendar_gate["required"] == false
    assert calendar_gate["redacted"] == true

    assert Enum.all?(check.result["gates"], fn gate ->
             is_boolean(gate["required"]) and is_boolean(gate["redacted"])
           end)

    assert [event] = Observability.list_events(org.id, domain: "check")
    assert event.status == "ok"
    assert event.severity == "info"
    assert is_nil(event.evidence["actionable_gate"])

    assert [audit] = Observability.list_audit_logs(org.id, action: "run_checks.ran")
    assert is_nil(audit.metadata["actionable_gate"])
  end

  test "required skipped run-check gates remain non-green and actionable", %{
    org: org,
    project: project,
    user: user
  } do
    result = %{
      surface: "bot",
      org_ref: org.id,
      project_ref: project.id,
      ran_at: DateTime.utc_now(),
      gates: [
        %{
          gate_id: "bot.required",
          label: "Required check",
          status: :skipped,
          reason_class: :runtime_probe_missing,
          next_action: "Run the required probe",
          required: true
        }
      ]
    }

    assert {:ok, %CheckResult{} = check} =
             Observability.record_run_checks_activity(result,
               ran_by_user_id: user.id,
               request_id: "req_required_skipped"
             )

    assert check.status == "skipped"
    assert check.reason_class == "runtime_probe_missing"

    assert [event] = Observability.list_events(org.id, domain: "check")
    assert event.status == "skipped"
    assert event.severity == "warning"
    assert event.evidence["actionable_gate"]["gate_id"] == "bot.required"

    assert [audit] = Observability.list_audit_logs(org.id, action: "run_checks.ran")
    assert audit.metadata["actionable_gate"]["gate_id"] == "bot.required"
  end

  test "audit changeset requires actor action resource and result contract fields" do
    changeset =
      AuditLog.changeset(%AuditLog{actor_type: nil, resource_type: nil, result: nil}, %{})

    refute changeset.valid?

    assert %{
             actor_type: ["can't be blank"],
             action: ["can't be blank"],
             resource_type: ["can't be blank"],
             result: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "record_audit expands legacy target while preserving it", %{org: org, user: user} do
    assert {:ok, %AuditLog{} = audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               actor_label: "admin@example.com",
               action: "member.role_changed",
               target: "member:123",
               result: "ok",
               metadata: %{previous_role: "member", new_role: "admin", api_key: "secret"},
               redacted_diff: %{email: "admin@example.com"}
             })

    assert audit.actor_type == "user"
    assert audit.resource_type == "member"
    assert audit.resource_id == "123"
    assert audit.resource_label == "member:123"
    assert audit.actor_label == "admin@example.com"
    assert audit.metadata["api_key"] == "[REDACTED]"
    assert audit.redacted_diff["email"] == "[REDACTED]"
    assert audit.metadata_size_bytes > 0
    assert [listed] = Observability.list_audit_logs(org.id, resource_type: "member")
    assert listed.id == audit.id

    assert [event] = Observability.list_events(org.id, domain: "audit")
    assert event.audit_log_id == audit.id
    assert event.actor_user_id == user.id
    assert event.domain == "audit"
    assert event.resource_type == "member"
    assert event.resource_id == "123"
    assert event.source == "bft.write_path"
    assert event.event_type == "audit.member.role_changed"
    assert event.severity == "info"
    assert event.status == "ok"
    assert event.evidence["audit_log_id"] == audit.id
    assert event.evidence["metadata_present"] == "true"
    assert event.evidence["redacted_diff_present"] == "true"
    refute inspect(event) =~ "secret"
    refute inspect(event) =~ "admin@example.com"
  end

  test "record_write_attempt covers failed and denied non-agent writes", %{
    org: org,
    user: user
  } do
    validation_reason =
      {%{}, %{client_secret: :string}}
      |> Ecto.Changeset.change(%{})
      |> Ecto.Changeset.add_error(:client_secret, "can't be blank")

    assert {:ok, %AuditLog{} = failed} =
             Observability.record_write_attempt(%{
               org_id: org.id,
               actor_user_id: user.id,
               actor_label: "admin@example.com",
               action: "sso_connection.updated",
               resource_type: "sso_connection",
               resource_id: org.id,
               resource_label: "SSO",
               result: "failed",
               reason: validation_reason,
               request_id: "req_non_agent_failed",
               surface: "sso",
               metadata: %{client_secret: "super-secret"},
               redacted_diff: %{client_secret: %{from: "old-secret", to: "new-secret"}}
             })

    assert failed.result == "failed"
    assert failed.reason_class == "validation_failed"
    assert failed.request_id == "req_non_agent_failed"
    assert failed.metadata["write_attempt"] == "true"
    assert failed.metadata["surface"] == "sso"
    assert failed.metadata["error_fields"] == ["client_secret"]
    assert failed.metadata["client_secret"] == "[REDACTED]"
    assert failed.redacted_diff["client_secret"] == "[REDACTED]"

    assert {:ok, %AuditLog{} = denied} =
             Observability.record_write_attempt(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "api_key.revoked",
               resource_type: "api_key",
               resource_id: "key-123",
               resource_label: "Runner API key",
               result: "denied",
               reason: :forbidden,
               request_id: "req_non_agent_denied"
             })

    assert denied.result == "denied"
    assert denied.reason_class == "forbidden"

    assert [failed_event] =
             Observability.list_events(org.id, audit_log_id: failed.id)

    assert failed_event.event_type == "audit.sso_connection.updated"
    assert failed_event.severity == "error"
    assert failed_event.status == "failed"
    assert failed_event.reason_class == "validation_failed"
    assert failed_event.correlation_id == "req_non_agent_failed"

    assert [denied_event] =
             Observability.list_events(org.id, audit_log_id: denied.id)

    assert denied_event.event_type == "audit.api_key.revoked"
    assert denied_event.severity == "warning"
    assert denied_event.status == "denied"
    assert denied_event.reason_class == "forbidden"
    assert denied_event.correlation_id == "req_non_agent_denied"

    refute inspect([failed, failed_event, denied, denied_event]) =~ "super-secret"
    refute inspect([failed, failed_event, denied, denied_event]) =~ "new-secret"
    refute inspect([failed_event, denied_event]) =~ "admin@example.com"
  end

  test "legacy audit backfill preserves target in metadata and fills resource fields", %{
    org: org,
    project: project,
    user: user
  } do
    legacy_target = "project:#{project.id}"

    legacy_audit =
      Repo.insert!(%AuditLog{
        org_id: org.id,
        actor_user_id: user.id,
        action: "legacy.project_archived",
        target: legacy_target,
        resource_type: "legacy",
        resource_id: nil,
        resource_label: nil,
        result: "unknown",
        metadata: %{"kept" => "yes"},
        redacted_diff: %{},
        metadata_size_bytes: 0
      })

    assert {:ok, 1} = Observability.backfill_legacy_audit_logs()

    backfilled = Repo.get!(AuditLog, legacy_audit.id)
    assert backfilled.target == legacy_target
    assert backfilled.resource_type == "project"
    assert backfilled.resource_id == project.id
    assert backfilled.resource_label == legacy_target
    assert backfilled.metadata["legacy_target"] == legacy_target
    assert backfilled.metadata["kept"] == "yes"
    assert backfilled.metadata_size_bytes > 0

    assert {:ok, 0} = Observability.backfill_legacy_audit_logs()
  end

  test "audit event projection links only audit logs from the same org", %{
    org: org,
    other_org: other_org
  } do
    assert {:ok, audit} =
             Observability.record_audit(%{
               org_id: org.id,
               action: "project.archived",
               resource_type: "project",
               resource_id: "project-1",
               result: "ok"
             })

    {{:error, :audit_scope_mismatch}, log} =
      with_log(fn ->
        Observability.create_event(%{
          org_id: other_org.id,
          audit_log_id: audit.id,
          domain: "audit",
          resource_type: "project",
          resource_id: "project-1",
          source: "bft.write_path",
          event_type: "audit.project.archived",
          severity: "info",
          summary: "Cross org audit event"
        })
      end)

    assert log =~ "bridge_for_teams.observability.ingest.dropped"
    assert log =~ "record_type=event"
    assert log =~ "reason=audit_scope_mismatch"
    assert log =~ "domain=audit"
    assert log =~ "source=bft.write_path"
    assert log =~ "event_type=audit.project.archived"
    refute log =~ "project-1"
  end

  test "paginated Operations queries emit latency logs without payload data", %{org: org} do
    assert {:ok, _event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "info",
               summary: "Runner status changed",
               evidence: %{component: "provisioner", next_action: "dont-log-me"}
             })

    {_events, log} =
      with_log([level: :debug], fn ->
        Observability.list_events(org.id, limit: 1)
      end)

    assert log =~ "bridge_for_teams.observability.query.completed"
    assert log =~ "record_type=observability_event"
    assert log =~ "order_field=occurred_at"
    assert log =~ "row_count=1"
    assert log =~ "limit=1"
    refute log =~ "dont-log-me"
  end

  test "oversized payloads are bounded before persistence", %{org: org} do
    previous = Application.get_env(:bridge_for_teams_core, :observability_payload_max_bytes)
    Application.put_env(:bridge_for_teams_core, :observability_payload_max_bytes, 32)
    on_exit(fn -> restore_payload_limit(previous) end)

    {{:ok, event}, log} =
      with_log(fn ->
        Observability.create_event(%{
          org_id: org.id,
          domain: "runner",
          resource_type: "mac_mini_provisioner",
          source: "mac_mini.provisioner",
          event_type: "runner.heartbeat",
          severity: "info",
          summary: "Heartbeat received",
          evidence: %{component_version: String.duplicate("x", 100)}
        })
      end)

    assert event.evidence["evidence_truncated"] == true
    assert event.evidence["original_size_bytes"] > event.evidence_size_bytes
    assert log =~ "bridge_for_teams.observability.payload.truncated"
    assert log =~ "truncated_key=evidence_truncated"
    assert log =~ "payload_max_bytes=32"
    refute log =~ String.duplicate("x", 100)
  end

  test "oversized audit redacted_diff is redacted then bounded", %{org: org, user: user} do
    previous = Application.get_env(:bridge_for_teams_core, :observability_payload_max_bytes)
    Application.put_env(:bridge_for_teams_core, :observability_payload_max_bytes, 96)
    on_exit(fn -> restore_payload_limit(previous) end)

    assert {:ok, audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "project.updated",
               resource_type: "project",
               resource_id: Ecto.UUID.generate(),
               result: "ok",
               metadata: %{},
               redacted_diff: %{
                 api_key: "sk-test-should-not-survive",
                 notes: String.duplicate("x", 512)
               }
             })

    assert audit.redacted_diff["redacted_diff_truncated"] == true
    assert audit.redacted_diff["original_size_bytes"] > 96
    refute inspect(audit.redacted_diff) =~ "sk-test"
    refute inspect(audit.redacted_diff) =~ String.duplicate("x", 128)
  end

  test "retention policy exposes explicit scheduled-retention defaults" do
    assert %{
             observability_events_days: events_days,
             operation_runs_days: runs_days,
             stderr_tail_days: stderr_days,
             check_results_days: checks_days,
             audit_logs_days: audit_days,
             pruning: :scheduled
           } = Observability.retention_policy()

    assert events_days > 0
    assert runs_days > events_days
    assert stderr_days < runs_days
    assert checks_days >= runs_days
    assert audit_days >= checks_days
  end

  test "scheduled pruner calls the shared pruning boundary on its interval" do
    parent = self()

    prune_fun = fn prune_opts ->
      send(parent, {:observability_pruned, prune_opts})

      {:ok,
       %{
         stderr_tails_cleared: 0,
         observability_events_deleted: 0,
         operation_runs_deleted: 0,
         check_results_deleted: 0,
         audit_logs_deleted: 0
       }}
    end

    {:ok, pid} =
      Pruner.start_link(
        name: nil,
        enabled: true,
        interval_ms: 10,
        prune_fun: prune_fun,
        prune_opts: [policy: :test_policy]
      )

    assert_receive {:observability_pruned, [policy: :test_policy]}, 1_000
    GenServer.stop(pid)
  end

  test "scheduled pruner logs failures and keeps the worker alive" do
    parent = self()

    log =
      capture_log(fn ->
        {:ok, pid} =
          Pruner.start_link(
            name: nil,
            enabled: true,
            run_on_start: true,
            interval_ms: 60_000,
            prune_fun: fn _opts ->
              send(parent, :observability_prune_attempted)
              raise "boom"
            end
          )

        assert_receive :observability_prune_attempted, 200
        assert Process.alive?(pid)
        GenServer.stop(pid)
      end)

    assert log =~ "bridge_for_teams.observability.pruner.failed"
  end

  test "org erasure hard-deletes org-scoped Operations records", %{
    org: org,
    other_org: other_org,
    project: project,
    other_project: other_project,
    user: user
  } do
    assert {:ok, org_event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "warning",
               summary: "Runner degraded"
             })

    assert {:ok, org_run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               project_id: project.id,
               run_type: "fin_exec",
               external_run_id: "erase-org-run",
               status: "failed"
             })

    assert {:ok, org_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "fail",
               result: %{status: "fail"}
             })

    assert {:ok, org_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "project.archived",
               resource_type: "project",
               resource_id: project.id,
               result: "ok"
             })

    assert {:ok, other_event} =
             Observability.create_event(%{
               org_id: other_org.id,
               project_id: other_project.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "info",
               summary: "Other org runner ok"
             })

    assert {:ok, other_run} =
             Observability.create_operation_run(%{
               org_id: other_org.id,
               project_id: other_project.id,
               run_type: "fin_exec",
               external_run_id: "keep-other-run",
               status: "ok"
             })

    assert {:ok, other_check} =
             Observability.create_check_result(%{
               org_id: other_org.id,
               project_id: other_project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: other_project.id,
               status: "ok",
               result: %{status: "ok"}
             })

    assert {:ok, other_audit} =
             Observability.record_audit(%{
               org_id: other_org.id,
               action: "project.updated",
               resource_type: "project",
               resource_id: other_project.id,
               result: "ok"
             })

    assert {:ok, counts} = Observability.erase_org_observability(org.id)

    assert counts.observability_events_deleted == 2
    assert counts.operation_runs_deleted == 1
    assert counts.check_results_deleted == 1
    assert counts.audit_logs_deleted == 1

    refute Repo.get(ObservabilityEvent, org_event.id)
    refute Repo.get(OperationRun, org_run.id)
    refute Repo.get(CheckResult, org_check.id)
    refute Repo.get(AuditLog, org_audit.id)

    assert Repo.get(ObservabilityEvent, other_event.id)
    assert Repo.get(OperationRun, other_run.id)
    assert Repo.get(CheckResult, other_check.id)
    assert Repo.get(AuditLog, other_audit.id)
  end

  test "user erasure clears identity references while preserving Operations facts", %{
    org: org,
    project: project,
    user: user
  } do
    {:ok, other_user} =
      Accounts.create_user(%{email: "auditor@example.com", name: "Other Operator"})

    assert {:ok, event} =
             Observability.create_event(%{
               org_id: org.id,
               project_id: project.id,
               actor_user_id: user.id,
               domain: "integration",
               resource_type: "sso_connection",
               source: "bft.write_path",
               event_type: "sso.validation.failed",
               severity: "warning",
               summary: "SSO validation failed"
             })

    assert {:ok, check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "sso",
               subject_type: "org",
               subject_id: org.id,
               status: "fail",
               result: %{status: "fail"},
               ran_by_user_id: user.id
             })

    assert {:ok, actor_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               actor_label: user.email,
               action: "settings.sso.updated",
               resource_type: "sso",
               resource_id: org.id,
               result: "ok"
             })

    assert {:ok, legacy_label_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_label: user.email,
               action: "settings.model.updated",
               resource_type: "model_settings",
               resource_id: org.id,
               result: "ok"
             })

    assert {:ok, impersonator_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: other_user.id,
               actor_label: other_user.email,
               impersonator_user_id: user.id,
               action: "project.updated",
               resource_type: "project",
               resource_id: project.id,
               result: "ok"
             })

    assert {:ok, counts} =
             Observability.erase_user_observability_references(user.id,
               actor_label: user.email
             )

    assert counts.observability_events_actor_refs_erased == 2
    assert counts.check_results_user_refs_erased == 1
    assert counts.audit_actor_refs_erased == 2
    assert counts.audit_impersonator_refs_erased == 1

    assert %ObservabilityEvent{actor_user_id: nil} = Repo.get!(ObservabilityEvent, event.id)
    assert %CheckResult{ran_by_user_id: nil} = Repo.get!(CheckResult, check.id)

    assert %AuditLog{
             actor_user_id: nil,
             actor_label: "Erased user",
             action: "settings.sso.updated"
           } = Repo.get!(AuditLog, actor_audit.id)

    assert %AuditLog{
             actor_user_id: nil,
             actor_label: "Erased user",
             action: "settings.model.updated"
           } = Repo.get!(AuditLog, legacy_label_audit.id)

    assert %AuditLog{
             actor_user_id: other_user_id,
             actor_label: "auditor@example.com",
             impersonator_user_id: nil,
             action: "project.updated"
           } = Repo.get!(AuditLog, impersonator_audit.id)

    assert other_user_id == other_user.id
    refute inspect(Repo.all(from(a in AuditLog, where: a.org_id == ^org.id))) =~ user.email
  end

  test "manual pruning removes expired rows and clears old stderr tails", %{
    org: org,
    project: project,
    user: user
  } do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, expired_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "warning",
               summary: "Expired runner event",
               occurred_at: days_ago(now, 61)
             })

    assert {:ok, fresh_event} =
             Observability.create_event(%{
               org_id: org.id,
               domain: "runner",
               resource_type: "mac_mini_provisioner",
               source: "mac_mini.provisioner",
               event_type: "runner.status_changed",
               severity: "info",
               summary: "Fresh runner event",
               occurred_at: days_ago(now, 1)
             })

    assert {:ok, stderr_run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               project_id: project.id,
               run_type: "fin_exec",
               external_run_id: "run_old_stderr",
               status: "failed",
               stderr_tail_redacted: "safe stack trace"
             })

    assert {:ok, expired_run} =
             Observability.create_operation_run(%{
               org_id: org.id,
               project_id: project.id,
               run_type: "fin_exec",
               external_run_id: "run_expired",
               status: "failed"
             })

    old_stderr_cutoff = days_ago(now, 15)
    old_run_cutoff = days_ago(now, 181)

    Repo.update_all(from(r in OperationRun, where: r.id == ^stderr_run.id),
      set: [created_at: old_stderr_cutoff]
    )

    Repo.update_all(from(r in OperationRun, where: r.id == ^expired_run.id),
      set: [created_at: old_run_cutoff]
    )

    assert {:ok, expired_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "fail",
               result: %{status: "fail"},
               ran_at: days_ago(now, 366)
             })

    assert {:ok, fresh_check} =
             Observability.create_check_result(%{
               org_id: org.id,
               project_id: project.id,
               check_family: "run_checks",
               surface: "bot",
               subject_type: "project",
               subject_id: project.id,
               status: "ok",
               result: %{status: "ok"},
               ran_at: days_ago(now, 1)
             })

    assert {:ok, expired_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "project.archived",
               resource_type: "project",
               resource_id: project.id,
               result: "ok",
               metadata: %{}
             })

    assert {:ok, fresh_audit} =
             Observability.record_audit(%{
               org_id: org.id,
               actor_user_id: user.id,
               action: "project.updated",
               resource_type: "project",
               resource_id: project.id,
               result: "ok",
               metadata: %{}
             })

    Repo.update_all(from(a in AuditLog, where: a.id == ^expired_audit.id),
      set: [created_at: days_ago(now, 2_556)]
    )

    {{:ok, counts}, log} = with_log(fn -> Observability.prune_expired(now: now) end)

    assert counts.observability_events_deleted == 1
    assert counts.operation_runs_deleted == 1
    assert counts.stderr_tails_cleared == 1
    assert counts.check_results_deleted == 1
    assert counts.audit_logs_deleted == 1

    refute Repo.get(ObservabilityEvent, expired_event.id)
    assert Repo.get(ObservabilityEvent, fresh_event.id)

    assert %OperationRun{stderr_tail_redacted: nil} = Repo.get(OperationRun, stderr_run.id)
    refute Repo.get(OperationRun, expired_run.id)

    refute Repo.get(CheckResult, expired_check.id)
    assert Repo.get(CheckResult, fresh_check.id)

    refute Repo.get(AuditLog, expired_audit.id)
    assert Repo.get(AuditLog, fresh_audit.id)

    assert log =~ "bridge_for_teams.observability.prune.completed"
    assert log =~ "observability_events_deleted: 1"
    assert log =~ "operation_runs_deleted: 1"
    assert log =~ "check_results_deleted: 1"
    assert log =~ "audit_logs_deleted: 1"
  end

  test "manual pruning logs failures before reraising" do
    log =
      capture_log(fn ->
        assert_raise FunctionClauseError, fn ->
          Observability.prune_expired(
            now: DateTime.utc_now(),
            policy: %{stderr_tail_days: "invalid"}
          )
        end
      end)

    assert log =~ "bridge_for_teams.observability.prune.failed"
  end

  defp restore_payload_limit(nil),
    do: Application.delete_env(:bridge_for_teams_core, :observability_payload_max_bytes)

  defp restore_payload_limit(value),
    do: Application.put_env(:bridge_for_teams_core, :observability_payload_max_bytes, value)

  defp restore_event_rate_limit(nil),
    do: Application.delete_env(:bridge_for_teams_core, :observability_event_rate_limit)

  defp restore_event_rate_limit(value),
    do: Application.put_env(:bridge_for_teams_core, :observability_event_rate_limit, value)

  defp days_ago(%DateTime{} = now, days), do: DateTime.add(now, -days * 86_400, :second)
end
