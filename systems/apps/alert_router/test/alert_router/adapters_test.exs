defmodule AlertRouter.AdaptersTest do
  use ExUnit.Case, async: true

  import AlertRouter.TestFixtures

  alias AlertRouter.Adapters.{GCPMonitoring, GitHubActions, Grafana}
  alias AlertRouter.CanonicalEvent

  test "GCP Pub/Sub message identity is stable across redelivery" do
    assert {:ok, first} =
             GCPMonitoring.normalize(gcp_payload(),
               message_id: "pubsub-42",
               observed_at: ~U[2026-04-25 14:13:20Z]
             )

    assert {:ok, redelivery} =
             GCPMonitoring.normalize(gcp_payload(),
               message_id: "different-pubsub-delivery",
               observed_at: ~U[2026-04-25 15:13:20Z]
             )

    assert first.event_id =~ ~r/^are1_[A-Za-z0-9_-]{43}$/
    assert first.incident_key == "ar1_mZLVSgVDW_JBeJI_r0UJX3NvPfOJSmCkEkZyR7Y2KfM"
    assert CanonicalEvent.digest(first) == CanonicalEvent.digest(redelivery)

    assert first.source_identity == [
             "alert-router.v1",
             "gcp_monitoring",
             "example-prod-project",
             "incident-123"
           ]

    assert first.policy_identity == ["gcp_monitoring", "comma_alerting", "im_ingress_5xx"]
    assert first.recovery_status == "not_applicable"
    assert first.latest =~ "持续高于"
    assert first.priority == "P2"
    assert first.service == "im_ingress"
    assert first.evidence_values["duration"] == "15 分钟"
  end

  test "GCP Agent recovery exhaustion normalizes as the intervention P0 in both projects" do
    for {environment, project} <- [
          {"staging", "example-staging-project"},
          {"production", "example-prod-project"}
        ] do
      labels = %{
        "comma_policy_id" => "external_session_runtime_failed",
        "comma_priority" => "p0",
        "comma_domain" => "availability",
        "managed_by" => "comma_alerting",
        "policy_version" => "v1",
        "environment" => environment,
        "service" => "salix_agent"
      }

      payload =
        gcp_payload("open", project: project)
        |> put_in(["incident", "policy_user_labels"], labels)
        |> put_in(["incident", "observed_value"], "1")

      assert {:ok, event} = GCPMonitoring.normalize(payload)
      assert event.priority == "P0"
      assert event.environment == environment
      assert event.service == "salix_agent"

      assert event.policy_identity == [
               "gcp_monitoring",
               "comma_alerting",
               "external_session_runtime_failed"
             ]

      assert event.evidence_values["cluster"] == "example-cluster"
      assert event.evidence_values["trigger_error"] == "recovery_exhausted"
      assert event.evidence_values["threshold"] == ">= 1 个自动恢复耗尽事件"
      assert event.summary == "Agent session 自动恢复耗尽，需要人工介入"
      assert event.latest =~ "recovery_exhausted"
      assert event.impact =~ "需要人工处理"
    end
  end

  test "GCP Agent runtime failure normalizes as P1 in both projects" do
    for {environment, project} <- [
          {"staging", "example-staging-project"},
          {"production", "example-prod-project"}
        ] do
      labels = %{
        "comma_policy_id" => "external_session_runtime_interrupted",
        "comma_priority" => "p1",
        "comma_domain" => "availability",
        "managed_by" => "comma_alerting",
        "policy_version" => "v1",
        "environment" => environment,
        "service" => "salix_agent"
      }

      payload =
        gcp_payload("open", project: project)
        |> put_in(["incident", "policy_user_labels"], labels)
        |> put_in(["incident", "observed_value"], "1")

      assert {:ok, event} = GCPMonitoring.normalize(payload)
      assert event.priority == "P1"
      assert event.environment == environment
      assert event.service == "salix_agent"

      assert event.policy_identity == [
               "gcp_monitoring",
               "comma_alerting",
               "external_session_runtime_interrupted"
             ]

      assert event.evidence_values["cluster"] == "example-cluster"
      # This aggregate policy also accepts internal dependency failures;
      # without an exact log fact, the card must not invent the trigger.
      refute Map.has_key?(event.evidence_values, "trigger_error")

      assert event.evidence_values["threshold"] ==
               "external 中断 1 次；internal 同一 Task activation 依赖失败 3 次"

      assert event.state == "firing"
      assert event.recovery_status == "not_applicable"
    end
  end

  test "GitHub deployment failure routes as one reviewed staging P2 generation" do
    assert {:ok, event} = GitHubActions.normalize(github_actions_payload())

    assert event.source_identity == [
             "alert-router.v1",
             "github_actions",
             "AFK-surf/Comma",
             "Comma Deployment",
             "33753005884",
             "2"
           ]

    assert event.policy_identity == [
             "github_actions",
             "AFK-surf/Comma",
             "staging_deployment_failure"
           ]

    assert event.source_state == "failure"
    assert event.state == "firing"
    assert event.priority == "P2"
    assert event.environment == "staging"
    assert event.service == "comma_release"
    assert event.family == "deployment"
    assert event.started_at == ~U[2026-09-03 09:56:00Z]
    assert event.observed_at == ~U[2026-09-03 10:03:00Z]

    assert event.evidence_values == %{
             "observed" => "failure",
             "threshold" => ">= 1 次失败终态",
             "duration" => "单次 workflow run"
           }

    assert event.links["incident"] ==
             "https://github.com/AFK-surf/Comma/actions/runs/33753005884"

    assert event.links["dashboard"] ==
             "https://github.com/AFK-surf/Comma/actions/workflows/comma-deployment.yml"
  end

  test "GitHub redelivery is stable and each run attempt stays independent" do
    assert {:ok, first} = GitHubActions.normalize(github_actions_payload())
    assert {:ok, redelivery} = GitHubActions.normalize(github_actions_payload())

    next_attempt = put_in(github_actions_payload(), ["workflow_run", "run_attempt"], 3)
    assert {:ok, retried} = GitHubActions.normalize(next_attempt)

    assert first.event_id == redelivery.event_id
    assert CanonicalEvent.digest(first) == CanonicalEvent.digest(redelivery)
    refute first.incident_key == retried.incident_key
  end

  test "GitHub success, production, and unrelated workflows are acknowledged as ignored" do
    assert {:ok, :ignored} = GitHubActions.normalize(github_actions_payload("success"))

    assert {:ok, :ignored} =
             github_actions_payload()
             |> Map.put("action", "requested")
             |> GitHubActions.normalize()

    assert {:ok, :ignored} =
             github_actions_payload()
             |> Map.put("action", "in_progress")
             |> GitHubActions.normalize()

    assert {:ok, :ignored} =
             github_actions_payload()
             |> put_in(["workflow_run", "head_branch"], "prod")
             |> GitHubActions.normalize()

    assert {:ok, :ignored} =
             github_actions_payload()
             |> put_in(["workflow_run", "name"], "Systems CI")
             |> GitHubActions.normalize()
  end

  test "GitHub repository and run links fail closed" do
    wrong_repository =
      put_in(github_actions_payload(), ["repository", "full_name"], "attacker/Comma")

    assert {:error, {:unapproved_github_repository, "attacker/Comma"}} =
             GitHubActions.normalize(wrong_repository)

    wrong_link =
      put_in(
        github_actions_payload(),
        ["workflow_run", "html_url"],
        "https://github.com/AFK-surf/Comma/actions/runs/999"
      )

    assert {:error, :invalid_github_run_link} = GitHubActions.normalize(wrong_link)
  end

  test "Grafana exact redelivery does not depend on local receive time" do
    assert {:ok, [first]} = Grafana.normalize(grafana_payload(), ~U[2026-04-25 14:13:20Z])
    assert {:ok, [later]} = Grafana.normalize(grafana_payload(), ~U[2026-04-25 15:13:20Z])

    assert first.event_id == later.event_id
    assert first.observed_at == later.observed_at
    assert CanonicalEvent.digest(first) == CanonicalEvent.digest(later)
    assert first.source_account == "https://afksurf.grafana.net"

    assert first.source_identity == [
             "alert-router.v1",
             "grafana",
             "https://afksurf.grafana.net",
             "1",
             "grafana-fingerprint-123",
             "2026-04-25T14:00:00Z"
           ]

    assert first.policy_identity == ["grafana", "comma_grafana:stg_llm_logical_error"]
    assert first.service == "llm"
    assert first.evidence_values["observed"] == "13%"
  end

  test "every managed Grafana rule policy is registered in the catalog" do
    # A rule that Terraform activates but the catalog does not know is
    # rejected at ingestion as unknown_policy: the alert fires in Grafana and
    # silently never reaches Slack. Keep the two sides in lockstep.
    for policy <- [
          "comma_grafana:stg_meeting_runtime_lost",
          "comma_grafana:stg_meeting_stuck_nonterminal",
          "comma_grafana:stg_meeting_delivery_error"
        ] do
      payload =
        put_in(
          grafana_payload(),
          ["alerts", Access.at(0), "annotations", "policy_id"],
          policy
        )

      assert {:ok, [event]} = Grafana.normalize(payload, ~U[2026-04-25 14:13:20Z]),
             "#{policy} is not registered in the Alert Router catalog"

      assert event.policy_identity == ["grafana", policy]
      assert event.service == "meetings"
      assert event.priority == "P2"
      assert event.team == "comma"
    end
  end

  test "provider-authored copy and unknown policy labels cannot enter the event" do
    payload =
      gcp_payload()
      |> put_in(["incident", "summary"], "<!channel> trust this provider text")
      |> put_in(["incident", "policy_user_labels", "unknown"], "secret")

    assert {:ok, event} = GCPMonitoring.normalize(payload, message_id: "pubsub-redaction")
    refute event.summary =~ "provider"
    refute Map.has_key?(event.evidence_values, "unknown")
  end

  test "catalog identity and same-origin links fail closed on provider drift" do
    wrong_owner =
      put_in(gcp_payload(), ["incident", "policy_user_labels", "managed_by"], "other")

    assert {:error, {:unknown_policy, ["gcp_monitoring", "other", "im_ingress_5xx"]}} =
             GCPMonitoring.normalize(wrong_owner)

    wrong_priority =
      put_in(gcp_payload(), ["incident", "policy_user_labels", "comma_priority"], "p1")

    assert {:error, {:catalog_conflict, :priority, "P2", "P1"}} =
             GCPMonitoring.normalize(wrong_priority)

    p0_priority =
      put_in(gcp_payload(), ["incident", "policy_user_labels", "comma_priority"], "p0")

    assert {:error, {:catalog_conflict, :priority, "P2", "P0"}} =
             GCPMonitoring.normalize(p0_priority)

    evil_dashboard =
      put_in(
        grafana_payload(),
        ["alerts", Access.at(0), "dashboardURL"],
        "https://evil.example/d/1"
      )

    assert {:error, :invalid_grafana_link} =
             Grafana.normalize(evil_dashboard, ~U[2026-04-25 14:13:20Z])
  end

  test "Grafana reviewed threshold and duration must match the catalog exactly" do
    matching =
      grafana_payload()
      |> put_in(["alerts", Access.at(0), "labels", "threshold"], "> 10%")
      |> put_in(["alerts", Access.at(0), "labels", "duration"], "15 分钟")

    assert {:ok, [event]} = Grafana.normalize(matching, ~U[2026-04-25 14:13:20Z])
    assert event.evidence_values["threshold"] == "> 10%"
    assert event.evidence_values["duration"] == "15 分钟"
    assert event.evidence_values["observed"] == "13%"

    conflict =
      matching
      |> put_in(["alerts", Access.at(0), "labels", "threshold"], "> 99%")

    assert {:error, {:catalog_conflict, {:evidence, "threshold"}, "> 10%", "> 99%"}} =
             Grafana.normalize(conflict, ~U[2026-04-25 14:13:20Z])
  end

  test "Grafana catalog projects observed values into threshold-comparable units" do
    assert {:ok, [resolved_ratio]} =
             grafana_payload("resolved")
             |> put_in(["alerts", Access.at(0), "values", "reducer"], 0.01)
             |> Grafana.normalize(~U[2026-04-25 14:16:00Z])

    assert resolved_ratio.evidence_values["observed"] == "1%"
    assert resolved_ratio.evidence_values["threshold"] == "> 10%"

    assert {:ok, [ttft]} =
             grafana_payload()
             |> put_in(
               ["alerts", Access.at(0), "annotations", "policy_id"],
               "comma_grafana:stg_llm_ttft"
             )
             |> put_in(["alerts", Access.at(0), "values", "reducer"], 31.25)
             |> Grafana.normalize(~U[2026-04-25 14:13:20Z])

    assert ttft.evidence_values["observed"] == "31.25 秒"
    assert ttft.evidence_values["threshold"] == "> 30 秒"

    assert {:error,
            {:invalid_observed_value, ["grafana", "comma_grafana:stg_llm_logical_error"],
             "not-a-number"}} =
             grafana_payload()
             |> put_in(["alerts", Access.at(0), "values", "reducer"], "not-a-number")
             |> Grafana.normalize(~U[2026-04-25 14:13:20Z])
  end

  test "reviewed provider links discard source query and fragment data" do
    gcp =
      put_in(
        gcp_payload(),
        ["incident", "url"],
        "https://console.cloud.google.com/monitoring/alerting/incidents/incident-123?token=secret#raw"
      )

    assert {:ok, gcp_event} = GCPMonitoring.normalize(gcp, message_id: "sanitized-gcp-link")

    assert gcp_event.links["incident"] ==
             "https://console.cloud.google.com/monitoring/alerting/incidents/incident-123?project=example-prod-project"

    generated_alert_link =
      put_in(
        gcp_payload(),
        ["incident", "url"],
        "https://console.cloud.google.com/monitoring/alerting/alerts/0.abcd?project=other#raw"
      )

    assert {:ok, generated_alert_event} =
             GCPMonitoring.normalize(generated_alert_link,
               message_id: "generated-gcp-alert-link"
             )

    assert generated_alert_event.links["incident"] ==
             "https://console.cloud.google.com/monitoring/alerting/alerts/0.abcd?project=example-prod-project"

    external_gcp_link =
      put_in(
        gcp_payload(),
        ["incident", "url"],
        "https://evil.example/monitoring/alerting/alerts/0.abcd"
      )

    assert {:error, :invalid_gcp_incident_link} = GCPMonitoring.normalize(external_gcp_link)

    grafana =
      put_in(
        grafana_payload(),
        ["alerts", Access.at(0), "dashboardURL"],
        "https://afksurf.grafana.net/d/comma-staging-salix-runtime/salix-runtime?var-tenant=secret#raw"
      )

    assert {:ok, [grafana_event]} =
             Grafana.normalize(grafana, ~U[2026-04-25 14:13:20Z])

    assert grafana_event.links["dashboard"] ==
             "https://afksurf.grafana.net/d/comma-staging-salix-runtime/salix-runtime"
  end

  test "Grafana notification groups are bounded before canonicalization" do
    alert = grafana_payload()["alerts"] |> hd()
    payload = grafana_payload() |> Map.put("alerts", List.duplicate(alert, 51))

    assert {:error, {:too_many_grafana_alerts, 50}} =
             Grafana.normalize(payload, ~U[2026-04-25 14:13:20Z])
  end

  test "structured identities normalize origin/org and do not inherit delimiter ambiguity" do
    canonical = grafana_payload()

    normalized =
      canonical
      |> Map.put("orgId", "1")
      |> Map.put("externalURL", "https://AFKSURF.GRAFANA.NET:443/")

    assert {:ok, [first]} = Grafana.normalize(canonical, ~U[2026-04-25 14:13:20Z])
    assert {:ok, [same]} = Grafana.normalize(normalized, ~U[2026-04-25 15:13:20Z])
    assert first.incident_key == same.incident_key
    assert first.event_id == same.event_id

    next_generation =
      put_in(canonical, ["alerts", Access.at(0), "startsAt"], "2026-04-25T15:00:00Z")

    assert {:ok, [next]} = Grafana.normalize(next_generation, ~U[2026-04-25 15:13:20Z])
    refute first.incident_key == next.incident_key

    assert {:error, :invalid_grafana_org_id} =
             canonical
             |> Map.put("orgId", "01")
             |> Grafana.normalize(~U[2026-04-25 14:13:20Z])

    refute CanonicalEvent.incident_key(["alert-router.v1", "gcp_monitoring", "a:b", "c"]) ==
             CanonicalEvent.incident_key(["alert-router.v1", "gcp_monitoring", "a", "b:c"])
  end

  test "source terminal is distinct from verified service recovery" do
    assert {:ok, gcp} = GCPMonitoring.normalize(gcp_payload("closed"))
    assert gcp.state == "resolved"
    assert gcp.recovery_status == "unknown"

    assert {:ok, [grafana]} =
             Grafana.normalize(grafana_payload("resolved"), ~U[2026-04-25 14:15:00Z])

    assert grafana.state == "resolved"
    assert grafana.recovery_status == "unknown"
  end

  test "canonical strings stay inside Postgres and Slack presentation bounds" do
    attrs = gcp_event() |> Map.from_struct()

    assert {:error, {:string_too_long, :summary, 100}} =
             attrs
             |> Map.put(:summary, String.duplicate("x", 101))
             |> CanonicalEvent.new()

    assert {:error, {:string_too_long, :event_id, 255}} =
             attrs
             |> Map.put(:event_id, String.duplicate("e", 256))
             |> CanonicalEvent.new()

    assert {:error, {:invalid_string, :region}} =
             attrs
             |> Map.put(:region, 42)
             |> CanonicalEvent.new()

    assert {:error, {:identity_hash_mismatch, :incident_key}} =
             attrs
             |> Map.put(:incident_key, "ar1_tampered")
             |> CanonicalEvent.new()
  end

  test "canonical events accept P0 priority" do
    attrs = gcp_event() |> Map.from_struct() |> Map.put(:priority, "P0")

    assert {:ok, event} = CanonicalEvent.build(attrs)
    assert event.priority == "P0"
  end

  test "canonical events admit only bounded reviewed runtime references" do
    runtime_evidence = %{
      "cluster" => "example-cluster",
      "tenant" => "tenant-demo",
      "agent_group" => "support-agents",
      "agent" => "agent-01",
      "session" => "session-01",
      "trigger_error" => "runtime_failed"
    }

    attrs =
      gcp_event()
      |> Map.from_struct()
      |> Map.update!(:evidence_values, &Map.merge(&1, runtime_evidence))

    assert {:ok, event} = CanonicalEvent.build(attrs)
    assert Map.take(event.evidence_values, Map.keys(runtime_evidence)) == runtime_evidence

    assert {:error, {:unknown_fields, :evidence_values, ["raw_error"]}} =
             attrs
             |> put_in([:evidence_values, "raw_error"], "Authorization: Bearer secret")
             |> CanonicalEvent.build()

    assert {:error, {:invalid_evidence_value, "trigger_error"}} =
             attrs
             |> put_in(
               [:evidence_values, "trigger_error"],
               "Authorization: Bearer secret"
             )
             |> CanonicalEvent.build()

    for {key, value} <- [
          {"tenant", "tenant-demo\n<!channel>"},
          {"agent_group", "support`agents"},
          {"session", " session-01"}
        ] do
      assert {:error, {:invalid_evidence_value, ^key}} =
               attrs
               |> put_in([:evidence_values, key], value)
               |> CanonicalEvent.build()
    end
  end
end
