defmodule BridgeForTeams.DailyBrief.RunLease do
  @moduledoc """
  One Swarm-wide run of a kind at a time. The run holds a `running` row under
  a partial unique index, so a second Pod that tries the same kind is told to
  skip. A run left `running` longer than the lease is given up, so a new one
  can start; a run given up cannot finish its row afterwards.
  """

  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{DailyBriefRun, DailyBriefSetting}

  # Room for the stream's read and a model call of up to 240 seconds.
  @lease_seconds 30 * 60
  @indexes %{"team_brief" => :daily_brief_runs_one_team_brief}

  @doc "When a `running` row older than this counts as given up."
  @spec live_since(DateTime.t()) :: DateTime.t()
  def live_since(now), do: DateTime.add(now, -@lease_seconds)

  @spec claim(DailyBriefSetting.t(), String.t(), map(), DateTime.t()) ::
          {:ok, DailyBriefRun.t()} | {:error, :running}
  def claim(%DailyBriefSetting{} = settings, kind, window, now)
      when is_map_key(@indexes, kind) do
    abandoned = DateTime.add(now, -@lease_seconds)

    Repo.update_all(
      from(r in DailyBriefRun,
        where:
          r.project_id == ^settings.project_id and r.kind == ^kind and r.status == "running" and
            r.created_at < ^abandoned
      ),
      set: [status: "failed", error: "abandoned"]
    )

    %DailyBriefRun{
      org_id: settings.org_id,
      project_id: settings.project_id,
      kind: kind,
      window_after: window.after,
      window_before: window.before,
      status: "running"
    }
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.unique_constraint(:project_id, name: Map.fetch!(@indexes, kind))
    |> Repo.insert()
    |> case do
      {:ok, run} -> {:ok, run}
      {:error, _taken} -> {:error, :running}
    end
  end

  @doc "Finishes a claimed run, unless it was given up meanwhile."
  @spec finish(DailyBriefRun.t(), String.t(), map()) ::
          {:ok, DailyBriefRun.t()} | {:error, :abandoned}
  def finish(%DailyBriefRun{id: id}, status, attrs) do
    case Repo.update_all(
           from(r in DailyBriefRun, where: r.id == ^id and r.status == "running", select: r),
           set:
             Map.to_list(Map.merge(attrs, %{status: status, updated_at: SystemsClock.utc_now()}))
         ) do
      {1, [run]} -> {:ok, run}
      {0, _} -> {:error, :abandoned}
    end
  end
end
