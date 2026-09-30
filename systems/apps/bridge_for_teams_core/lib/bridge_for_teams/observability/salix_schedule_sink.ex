defmodule BridgeForTeams.Observability.SalixScheduleSink do
  @moduledoc """
  Adapter-level bridge from Salix schedule diagnostics into BFT Operations.

  SalixCluster emits a sanitized diagnostic map through
  `:salix_cluster, :schedule_diagnostic_sink`. This module resolves an Agent
  Schedule through its Salix agent id and a Task Schedule through its Salix
  group id, then persists the project-scoped schedule-domain event.
  """
  use BridgeForTeams.Observability.Producer,
    producer: :salix_schedule_diagnostics,
    records: [:event],
    domains: ["schedule"],
    sources: ["salix.schedule"],
    resource_types: ["project_schedule"],
    evidence_allowlist: [
      "bft_agent_id",
      "client_request_id",
      "conversation_id",
      "invocation_id",
      "node",
      "project_id",
      "reason_class",
      "request_id",
      "salix_agent_id",
      "salix_group_id",
      "schedule_id",
      "scheduled_for",
      "scheduled_for_ms",
      "session_id_configured",
      "stage"
    ],
    permissions: :org_member

  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Observability.AdapterDiagnostic
  alias BridgeForTeams.Schema.{Agent, Project}

  @schedule_evidence_keys [
    :request_id,
    :client_request_id,
    :conversation_id,
    :invocation_id,
    :scheduled_for,
    :scheduled_for_ms,
    :stage,
    :reason_class,
    :session_id_configured,
    :node
  ]

  @doc "Record a Salix schedule diagnostic when its target belongs to a BFT project."
  @spec record(map()) :: :ok
  def record(diagnostic) when is_map(diagnostic) do
    AdapterDiagnostic.safe_record("BFT schedule diagnostic", fn ->
      with {:ok, %Project{} = project, agent} <- diagnostic_target(diagnostic) do
        diagnostic
        |> schedule_event_attrs(project, agent)
        |> AdapterDiagnostic.persist_event("BFT schedule diagnostic")
      else
        _ -> :ok
      end
    end)
  end

  def record(_diagnostic), do: :ok

  defp get_agent_by_salix_id(agent_id) do
    Repo.one(from a in Agent, where: a.salix_agent_id == ^agent_id, limit: 1)
  end

  defp diagnostic_target(diagnostic) do
    agent_id =
      diagnostic |> AdapterDiagnostic.value(:agent_id) |> AdapterDiagnostic.blank_to_nil()

    group_id =
      diagnostic
      |> AdapterDiagnostic.value(:agent_group_id)
      |> AdapterDiagnostic.blank_to_nil()

    cond do
      is_binary(agent_id) ->
        case get_agent_by_salix_id(agent_id) do
          %Agent{} = agent ->
            case Repo.get(Project, agent.project_id) do
              %Project{} = project -> {:ok, project, agent}
              nil -> :error
            end

          nil ->
            :error
        end

      is_binary(group_id) ->
        case Repo.get_by(Project, salix_group_id: group_id) do
          %Project{} = project -> {:ok, project, nil}
          nil -> :error
        end

      true ->
        :error
    end
  end

  defp schedule_event_attrs(diagnostic, project, agent) do
    schedule_id =
      diagnostic
      |> AdapterDiagnostic.value(:schedule_id)
      |> AdapterDiagnostic.string_value("schedule")

    scheduled_for_ms = AdapterDiagnostic.value(diagnostic, :scheduled_for_ms)

    %{
      org_id: project.org_id,
      project_id: project.id,
      domain: "schedule",
      source: "salix.schedule",
      event_type:
        diagnostic
        |> AdapterDiagnostic.value(:event_type)
        |> AdapterDiagnostic.string_value("schedule.fire.failed"),
      severity:
        diagnostic
        |> AdapterDiagnostic.value(:severity)
        |> AdapterDiagnostic.string_value("error"),
      status:
        diagnostic |> AdapterDiagnostic.value(:status) |> AdapterDiagnostic.string_value("failed"),
      reason_class:
        diagnostic |> AdapterDiagnostic.value(:reason_class) |> AdapterDiagnostic.blank_to_nil(),
      summary:
        diagnostic
        |> AdapterDiagnostic.value(:summary)
        |> AdapterDiagnostic.string_value("Schedule fire diagnostic"),
      resource_type: "project_schedule",
      resource_id: schedule_id,
      correlation_id:
        AdapterDiagnostic.correlation_id(
          diagnostic,
          schedule_correlation_id(schedule_id, scheduled_for_ms)
        ),
      evidence: schedule_evidence(project, agent, diagnostic, schedule_id)
    }
  end

  defp schedule_evidence(project, agent, diagnostic, schedule_id) do
    diagnostic
    |> AdapterDiagnostic.take_evidence(@schedule_evidence_keys)
    |> Map.merge(%{
      "schedule_id" => schedule_id,
      "project_id" => project.id,
      "salix_group_id" => project.salix_group_id
    })
    |> maybe_put_agent_evidence(agent)
    |> AdapterDiagnostic.drop_blank_values()
  end

  defp maybe_put_agent_evidence(evidence, %Agent{} = agent) do
    Map.merge(evidence, %{
      "bft_agent_id" => agent.id,
      "salix_agent_id" => agent.salix_agent_id
    })
  end

  defp maybe_put_agent_evidence(evidence, nil), do: evidence

  defp schedule_correlation_id(schedule_id, scheduled_for_ms)
       when is_binary(schedule_id) and is_integer(scheduled_for_ms),
       do: "schedule:#{schedule_id}:#{scheduled_for_ms}"

  defp schedule_correlation_id(schedule_id, scheduled_for_ms)
       when is_binary(schedule_id) and is_binary(scheduled_for_ms) and scheduled_for_ms != "",
       do: "schedule:#{schedule_id}:#{scheduled_for_ms}"

  defp schedule_correlation_id(schedule_id, _scheduled_for_ms) when is_binary(schedule_id),
    do: "schedule:#{schedule_id}"
end
