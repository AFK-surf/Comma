defmodule AlertRouter.Adapters.GitHubActions do
  @moduledoc """
  Typed adapter for GitHub's `workflow_run` webhook payload.

  Repository, workflow, trigger, branch, and conclusion are exact allowlists.
  Provider-authored text and arbitrary URLs never cross the adapter boundary.
  Each failed run attempt is its own incident generation; a later successful
  deployment does not rewrite the historical fact that this attempt failed.
  """

  alias AlertRouter.{CanonicalEvent, Catalog}
  alias AlertRouter.Adapters.Helpers

  @source_account "AFK-surf/Comma"
  @workflow_name "Comma Deployment"
  @workflow_event "workflow_dispatch"
  @staging_branch "main"
  @failure_conclusions ~w(failure cancelled)

  @spec normalize(map()) :: {:ok, CanonicalEvent.t() | :ignored} | {:error, term()}
  def normalize(%{
        "action" => "completed",
        "repository" => %{"full_name" => @source_account},
        "workflow_run" => run
      })
      when is_map(run) do
    normalize_run(run)
  end

  def normalize(%{
        "action" => action,
        "repository" => %{"full_name" => @source_account}
      })
      when action in ["requested", "in_progress"],
      do: {:ok, :ignored}

  def normalize(%{"action" => "completed", "repository" => %{"full_name" => account}})
      when is_binary(account),
      do: {:error, {:unapproved_github_repository, account}}

  def normalize(_payload), do: {:error, :invalid_github_workflow_run_payload}

  defp normalize_run(run) do
    with {:ok, workflow_name} <- Helpers.required_string(run, "name"),
         {:ok, workflow_event} <- Helpers.required_string(run, "event"),
         {:ok, branch} <- Helpers.required_string(run, "head_branch"),
         {:ok, conclusion} <- Helpers.required_string(run, "conclusion") do
      if workflow_name == @workflow_name and workflow_event == @workflow_event and
           branch == @staging_branch and conclusion in @failure_conclusions do
        build_event(run, conclusion)
      else
        {:ok, :ignored}
      end
    end
  end

  defp build_event(run, conclusion) do
    with {:ok, run_id} <- positive_integer(run["id"], "id"),
         {:ok, run_attempt} <- positive_integer(run["run_attempt"], "run_attempt"),
         {:ok, started_at} <- started_at(run),
         {:ok, observed_at} <- parsed_time(run, "updated_at"),
         {:ok, run_url} <- reviewed_run_link(run["html_url"], run_id),
         attrs <- %{
           schema_version: 1,
           source: "github_actions",
           source_account: @source_account,
           source_identity: [
             "alert-router.v1",
             "github_actions",
             @source_account,
             @workflow_name,
             Integer.to_string(run_id),
             Integer.to_string(run_attempt)
           ],
           policy_identity: [
             "github_actions",
             @source_account,
             "staging_deployment_failure"
           ],
           source_state: conclusion,
           state: "firing",
           recovery_status: "not_applicable",
           environment: "staging",
           priority: nil,
           team: nil,
           service: nil,
           family: nil,
           region: nil,
           started_at: started_at,
           ended_at: nil,
           observed_at: observed_at,
           evidence_values: %{"observed" => conclusion},
           links: %{"incident" => run_url}
         },
         {:ok, enriched} <- Catalog.enrich(attrs),
         {:ok, event} <- CanonicalEvent.build(enriched) do
      {:ok, event}
    end
  end

  defp started_at(run) do
    case run["run_started_at"] || run["created_at"] do
      value when is_binary(value) -> Helpers.parse_iso8601(value)
      _value -> {:error, {:missing_field, "run_started_at"}}
    end
  end

  defp parsed_time(run, field) do
    with {:ok, value} <- Helpers.required_string(run, field),
         {:ok, datetime} <- Helpers.parse_iso8601(value) do
      {:ok, datetime}
    end
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, field), do: {:error, {:invalid_github_run_field, field}}

  defp reviewed_run_link(value, run_id) when is_binary(value) do
    expected_path = "/AFK-surf/Comma/actions/runs/#{run_id}"

    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: "github.com",
        port: port,
        userinfo: nil,
        path: ^expected_path,
        query: nil,
        fragment: nil
      }
      when port in [nil, 443] ->
        {:ok, "https://github.com#{expected_path}"}

      _uri ->
        {:error, :invalid_github_run_link}
    end
  end

  defp reviewed_run_link(_value, _run_id), do: {:error, :invalid_github_run_link}
end
