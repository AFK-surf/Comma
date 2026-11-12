defmodule SalixAgent.SessionHistory.ArchiveEviction do
  @moduledoc """
  One-time PG body eviction through the ordinary Session archive owner.

  Revision one admits imported Sessions. Existing targets resume authorized
  archive work, including work published by an earlier run. Each visit captures
  one finite target and skips a business change after that capture.
  """

  require Logger
  alias SalixAgent.InternalSessionStore
  alias SalixAgent.InternalSessionStore.PG
  alias SalixStore.PGAuthorityImport

  @concurrency 4
  @failure_samples 16

  def run(opts \\ []) do
    PGAuthorityImport.with_dependencies(fn ->
      scan(nil, Keyword.get(opts, :agent_id), %{
        sessions: 0,
        archive_visits: 0,
        residue_deleted: 0,
        changed: 0,
        failed: 0,
        failures: []
      })
    end)
  end

  defp scan(cursor, agent_id, totals) do
    with {:ok, ids, next} <- PG.archive_maintenance_page(cursor, agent_id) do
      totals =
        ids
        |> SystemsClock.async_stream(&visit/1,
          max_concurrency: @concurrency,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce(totals, &record/2)

      Logger.info(
        "session_archive_eviction_page sessions=#{totals.sessions} archive_visits=#{totals.archive_visits} residue_deleted=#{totals.residue_deleted} changed=#{totals.changed} failed=#{totals.failed}"
      )

      if next,
        do: scan(next, agent_id, totals),
        else: {if(totals.failed == 0, do: :ok, else: :error), totals}
    else
      {:error, _} -> {:error, Map.put(totals, :error, :database_unavailable)}
    end
  end

  defp visit([agent, session]) do
    report = %{agent: agent, session: session, archive_visits: 0, residue_deleted: 0, changed: 0}

    with {:ok, deleted} <- clear_residue(agent, session, 0),
         {:ok, head} <- PG.admit_archive_maintenance(agent, session),
         {:ok, progress} <- drain(head, 0) do
      {:ok, Map.merge(report, Map.put(progress, :residue_deleted, deleted))}
    else
      {:error, reason}
      when reason in [:session_changed, :not_found, :session_read_only, :agent_not_found] ->
        {:ok, %{report | changed: 1}}

      {:error, reason} ->
        {:error, report, failure_code(reason)}
    end
  rescue
    _ -> {:error, %{agent: agent, session: session}, :archive_failed}
  catch
    :exit, _ -> {:error, %{agent: agent, session: session}, :archive_failed}
  end

  defp clear_residue(agent, session, deleted) do
    with {:ok, result} <- PG.cleanup_archived(agent, session) do
      total = deleted + result.deleted
      if result.remaining, do: clear_residue(agent, session, total), else: {:ok, total}
    end
  end

  defp drain(nil, visits), do: {:ok, %{archive_visits: visits, changed: 0}}

  defp drain(head, visits) do
    case InternalSessionStore.archive_captured(head) do
      {:ok, status} when status in [:archived, :nothing_to_archive] ->
        with {:ok, current} <- PG.archive_head(head.agent_id, head.session_id) do
          count = visits + if(status == :archived, do: 1, else: 0)

          cond do
            current.expected_through >= head.target ->
              {:ok, %{archive_visits: count, changed: 0}}

            current.expected_through > head.expected_through ->
              drain(%{head | expected_through: current.expected_through}, count)

            true ->
              {:error, :archive_target_missing}
          end
        end

      {:error, reason}
      when reason in [:session_changed, :not_found, :session_read_only, :agent_not_found] ->
        {:ok, %{archive_visits: visits, changed: 1}}

      {:error, _} = error ->
        error
    end
  end

  defp record({:ok, {:ok, report}}, totals), do: add_report(totals, report)

  defp record({:ok, {:error, report, code}}, totals) do
    totals = add_report(totals, report)
    sample = %{agent: report.agent, session: report.session, error: code}

    %{
      totals
      | failed: totals.failed + 1,
        failures: Enum.take(totals.failures ++ [sample], @failure_samples)
    }
  end

  defp record({:exit, _}, totals),
    do: %{totals | sessions: totals.sessions + 1, failed: totals.failed + 1}

  defp add_report(totals, report) do
    totals
    |> Map.update!(:sessions, &(&1 + 1))
    |> Map.update!(:archive_visits, &(&1 + Map.get(report, :archive_visits, 0)))
    |> Map.update!(:residue_deleted, &(&1 + Map.get(report, :residue_deleted, 0)))
    |> Map.update!(:changed, &(&1 + Map.get(report, :changed, 0)))
  end

  defp failure_code({:rolled_back, _}), do: :database_rejected
  defp failure_code({:archive_unreadable, _, _}), do: :archive_unreadable
  defp failure_code({:segment_divergence, _}), do: :segment_divergence
  defp failure_code(:source_gap), do: :source_gap
  defp failure_code(:archive_target_missing), do: :archive_target_missing
  defp failure_code(_), do: :archive_failed
end
