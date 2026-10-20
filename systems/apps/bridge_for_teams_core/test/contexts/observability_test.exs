defmodule BridgeForTeams.ObservabilityTest do
  use BridgeForTeams.DataCase, async: false
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.BridgeForTeams"]

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

    assert {:error, :not_found} =
             Observability.quarantine_record(:event, SystemsRuntime.Proc.uuid())

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

  test "a Lark diagnostic of a project's Swarm becomes an Operations event", %{
    org: org,
    project: project
  } do
    diagnostic = %{
      provider: "lark",
      source: "salix.im",
      domain: "conversation",
      event_type: "lark.message.delivered",
      severity: "info",
      status: "delivered",
      summary: "Lark message delivered",
      group_id: project.salix_group_id,
      connect_id: "conn_lark",
      app_id: "cli_lark",
      provider_event_type: "im.message.receive_v1",
      message_id: "om_1",
      source_message_id: "im_provider:lark:conn_lark:om_1",
      chat_id: "oc_1",
      chat_type: "p2p",
      delivery_state: "delivered",
      # Not a field of the Lark evidence: it does not reach the event.
      text: "the message itself"
    }

    assert :ok = SalixIMSink.record(diagnostic)

    assert :ok =
             SalixIMSink.record(%{
               diagnostic
               | event_type: "lark.callback.queued",
                 domain: "integration",
                 status: "queued"
             })

    # A diagnostic of a Swarm that is no project's is not recorded.
    assert :ok = SalixIMSink.record(%{diagnostic | group_id: "group_of_nobody"})

    events =
      Repo.all(
        from(e in ObservabilityEvent,
          where: e.project_id == ^project.id and e.source == "salix.im",
          order_by: e.event_type
        )
      )

    assert [
             %{event_type: "lark.callback.queued", resource_type: "lark_connect"} = callback,
             %{event_type: "lark.message.delivered", resource_type: "lark_message"} = message
           ] = events

    assert callback.org_id == org.id
    assert callback.domain == "integration"
    assert callback.resource_id == "conn_lark"
    assert message.domain == "conversation"
    assert message.resource_id == "im_provider:lark:conn_lark:om_1"

    assert message.evidence == %{
             "provider" => "lark",
             "source" => "salix.im",
             "group_id" => project.salix_group_id,
             "connect_id" => "conn_lark",
             "app_id" => "cli_lark",
             "provider_event_type" => "im.message.receive_v1",
             "message_id" => "om_1",
             "source_message_id" => "im_provider:lark:conn_lark:om_1",
             "chat_id" => "oc_1",
             "chat_type" => "p2p",
             "delivery_state" => "delivered"
           }
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
               ran_at: SystemsClock.utc_now()
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
      ran_at: SystemsClock.utc_now(),
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
    now = SystemsClock.utc_now() |> DateTime.truncate(:second)

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

  defp days_ago(%DateTime{} = now, days), do: DateTime.add(now, -days * 86_400, :second)
end
