defmodule Mix.Tasks.Salix.SessionWork.Audit do
  @shortdoc "Report Session-work projection backfill and verification state"

  @moduledoc """
  Read-only rollout audit for the Session-work Postgres projection.

  The command reports the persisted composite cursor, current phase, candidate
  count, captured expected count, and both release verification gap counters.
  It never scans through an opaque continuation token, repairs state, advances
  progress, or reports completion unless the exclusive release verification
  wrote its zero-uncovered terminal marker.
  """

  use Mix.Task

  alias SalixStore.{
    SessionWorkBackfillExpectedCandidates,
    SessionWorkBackfillState,
    SessionWorkCandidates
  }

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    {:ok, _started} = Application.ensure_all_started(:salix_store)

    case counts() do
      {:ok, report} ->
        Mix.shell().info("phase: #{report.phase}")

        Mix.shell().info(
          "candidate address start_after: " <>
            inspect({
              report.candidate_agent_start_after,
              report.candidate_runtime_kind_start_after,
              report.candidate_session_start_after
            })
        )

        Mix.shell().info("agent start_after: #{inspect(report.agent_start_after)}")
        Mix.shell().info("current agent key: #{inspect(report.current_agent_key)}")
        Mix.shell().info("marker start_after: #{inspect(report.marker_start_after)}")
        Mix.shell().info("processed in phase: #{report.processed}")
        Mix.shell().info("postgres candidate rows: #{report.postgres_candidates}")
        Mix.shell().info("expected candidate rows: #{report.expected_candidates}")

        Mix.shell().info("uncovered_authoritative_work: #{report.uncovered_authoritative_work}")
        Mix.shell().info("projection_gaps: #{report.projection_gaps}")
        Mix.shell().info("strategy_version: #{report.strategy_version}")

        Mix.shell().info("verification complete: #{report.verification_complete}")

      {:error, reason} ->
        Mix.raise("session-work audit failed: #{inspect(reason)}")
    end
  end

  @spec counts() :: {:ok, map()} | {:error, term()}
  def counts do
    with {:ok, state} <- SessionWorkBackfillState.read(),
         {:ok, terminal?} <- SessionWorkBackfillState.terminal?(),
         {:ok, postgres_candidates} <- SessionWorkCandidates.count(),
         {:ok, expected_candidates} <- SessionWorkBackfillExpectedCandidates.count() do
      {:ok,
       Map.merge(state, %{
         postgres_candidates: postgres_candidates,
         expected_candidates: expected_candidates,
         verification_complete:
           terminal? and state.uncovered_authoritative_work == 0 and state.projection_gaps == 0
       })}
    end
  end
end
