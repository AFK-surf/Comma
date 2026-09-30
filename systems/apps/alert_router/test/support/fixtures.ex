defmodule AlertRouter.TestFixtures do
  @moduledoc false

  alias AlertRouter.Adapters.{GCPMonitoring, GitHubActions, Grafana}

  def gcp_payload(state \\ "open", opts \\ []) do
    resolved? = state == "closed"
    project = Keyword.get(opts, :project, "example-prod-project")

    %{
      "version" => "1.2",
      "incident" => %{
        "incident_id" => "incident-123",
        "scoping_project_id" => project,
        "state" => state,
        "started_at" => 1_777_000_000,
        "ended_at" => if(resolved?, do: 1_777_000_900, else: nil),
        "observed_value" => "8.7%",
        "url" =>
          "https://console.cloud.google.com/monitoring/alerting/alerts/0.incident-123?project=#{project}",
        "policy_user_labels" => %{
          "comma_policy_id" => "im_ingress_5xx",
          "comma_priority" => "p2",
          "comma_domain" => "availability",
          "managed_by" => "comma_alerting",
          "policy_version" => "v1"
        }
      }
    }
  end

  def gcp_event(state \\ "open", opts \\ []) do
    default_message = if state == "closed", do: "gcp-message-resolved", else: "gcp-message-firing"

    {:ok, event} =
      GCPMonitoring.normalize(gcp_payload(state, opts),
        message_id: Keyword.get(opts, :message_id, default_message),
        observed_at: Keyword.get(opts, :observed_at, ~U[2026-04-24 03:13:20.000000Z])
      )

    event
  end

  def grafana_payload(state \\ "firing") do
    resolved? = state == "resolved"

    %{
      "orgId" => 1,
      "externalURL" => "https://afksurf.grafana.net",
      "alerts" => [
        %{
          "status" => state,
          "fingerprint" => "grafana-fingerprint-123",
          "startsAt" => "2026-04-25T14:00:00Z",
          "endsAt" => if(resolved?, do: "2026-04-25T14:15:00Z", else: "0001-01-01T00:00:00Z"),
          "generatorURL" => "https://afksurf.grafana.net/alerting/grafana/comma-stg-llm-error/view",
          "dashboardURL" =>
            "https://afksurf.grafana.net/d/comma-staging-salix-runtime/salix-runtime",
          "values" => %{"reducer" => 0.13, "C" => 1},
          "labels" => %{
            "environment" => "staging",
            "priority" => "P2",
            "team" => "comma",
            "source" => "grafana"
          },
          "annotations" => %{
            "policy_id" => "comma_grafana:stg_llm_logical_error"
          }
        }
      ]
    }
  end

  def grafana_events(state \\ "firing", received_at \\ ~U[2026-04-25 14:13:20Z]) do
    {:ok, events} = Grafana.normalize(grafana_payload(state), received_at)
    events
  end

  def github_actions_payload(conclusion \\ "failure") do
    %{
      "action" => "completed",
      "repository" => %{"full_name" => "AFK-surf/Comma"},
      "workflow_run" => %{
        "id" => 33_753_005_884,
        "run_attempt" => 2,
        "name" => "Comma Deployment",
        "event" => "workflow_dispatch",
        "head_branch" => "main",
        "conclusion" => conclusion,
        "created_at" => "2026-09-03T09:55:00Z",
        "run_started_at" => "2026-09-03T09:56:00Z",
        "updated_at" => "2026-09-03T10:03:00Z",
        "html_url" => "https://github.com/AFK-surf/Comma/actions/runs/33753005884"
      }
    }
  end

  def github_actions_event(conclusion \\ "failure") do
    {:ok, event} = GitHubActions.normalize(github_actions_payload(conclusion))
    event
  end
end
