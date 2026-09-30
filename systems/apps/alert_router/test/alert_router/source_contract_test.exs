defmodule AlertRouter.SourceContractTest do
  use ExUnit.Case, async: true

  import AlertRouter.TestFixtures

  alias AlertRouter.Adapters.{GCPMonitoring, Grafana}

  @repo_root Path.expand("../../../../../", __DIR__)
  @gcp_root Path.join(@repo_root, "k8s/comma/cloud-monitoring/policies")
  @grafana_projection Path.join(
                        @repo_root,
                        "observability/grafana/terraform/alerting-rules.json"
                      )

  test "every currently rolled-out GCP policy normalizes from its owned userLabels" do
    rollout = read_json(Path.join(@gcp_root, "rollout.v1.json"))

    templates =
      @gcp_root
      |> Path.join("*.json.tmpl")
      |> Path.wildcard()
      |> Map.new(fn path ->
        template = read_json(path)
        labels = template["userLabels"]
        identity = "#{labels["managed_by"]}:#{labels["comma_policy_id"]}"
        {identity, labels}
      end)

    for {environment, rollout_spec} <- rollout["environments"],
        identity <-
          rollout_spec["policyIdentities"] ++ rollout_spec["pendingPolicyIdentities"] do
      labels =
        templates
        |> Map.fetch!(identity)
        |> replace_environment(environment)

      project =
        if environment == "production", do: "example-prod-project", else: "example-staging-project"

      payload =
        gcp_payload()
        |> put_in(["incident", "scoping_project_id"], project)
        |> put_in(["incident", "policy_user_labels"], labels)

      assert {:ok, event} =
               GCPMonitoring.normalize(payload,
                 message_id: "contract-#{environment}-#{identity}",
                 observed_at: ~U[2026-04-25 14:13:20Z]
               )

      [managed_by, policy_id] = String.split(identity, ":", parts: 2)
      assert event.policy_identity == ["gcp_monitoring", managed_by, policy_id]
      assert event.environment == environment
    end
  end

  test "every owned Grafana rule normalizes with a catalog-authored service label" do
    projection = read_json(@grafana_projection)

    # Every activated rule must be registered in the catalog, and its service
    # must come from there rather than from provider-authored labels. A new
    # rule that skips catalog registration fails here instead of silently
    # being rejected as unknown_policy at ingestion time.
    expected_services = %{
      "comma_grafana:stg_llm_logical_error" => "llm",
      "comma_grafana:stg_llm_ttft" => "llm",
      "comma_grafana:stg_meeting_runtime_lost" => "meetings",
      "comma_grafana:stg_meeting_stuck_nonterminal" => "meetings",
      "comma_grafana:stg_meeting_delivery_error" => "meetings"
    }

    assert length(projection["rules"]) == map_size(expected_services)

    for rule <- projection["rules"] do
      alert =
        grafana_payload()["alerts"]
        |> hd()
        |> Map.put("labels", rule["labels"])
        |> Map.put("annotations", rule["annotations"])
        |> Map.put(
          "dashboardURL",
          "https://afksurf.grafana.net/d/#{rule["annotations"]["__dashboardUid__"]}/owned"
        )
        |> Map.put(
          "generatorURL",
          "https://afksurf.grafana.net/alerting/grafana/#{rule["uid"]}/view"
        )

      payload = grafana_payload() |> Map.put("alerts", [alert])

      policy = rule["annotations"]["policy_id"]

      assert {:ok, [event]} = Grafana.normalize(payload, ~U[2026-04-25 14:13:20Z])
      assert event.policy_identity == ["grafana", policy]
      assert event.service == Map.fetch!(expected_services, policy)
      assert event.environment == "staging"
    end
  end

  test "pending Telegram policy is staging-only and uses reviewed copy" do
    template = read_json(Path.join(@gcp_root, "telegram-delivery-failure.v1.json.tmpl"))

    payload =
      gcp_payload()
      |> put_in(["incident", "scoping_project_id"], "example-staging-project")
      |> put_in(["incident", "policy_user_labels"], template["userLabels"])

    assert {:ok, event} = GCPMonitoring.normalize(payload)
    assert event.service == "telegram"
    assert event.priority == "P2"
    assert event.evidence_values["duration"] == "5 分钟"

    production =
      put_in(payload, ["incident", "scoping_project_id"], "example-prod-project")

    assert {:error, _reason} = GCPMonitoring.normalize(production)
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()

  defp replace_environment(labels, environment) do
    Map.new(labels, fn {key, value} ->
      {key, if(value == "${COMMA_ENVIRONMENT}", do: environment, else: value)}
    end)
  end
end
