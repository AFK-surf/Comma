defmodule BridgeForTeams.DailyBrief.DeliveryWorker do
  @moduledoc """
  Sends due briefs. Each tick claims at most `batch` due members and sends
  their briefs one at a time, so the per-Pod load per tick is bounded whatever
  the number of members; then it posts the team briefs that are due.
  """
  use SystemsRuntime.Server

  require Logger

  alias BridgeForTeams.DailyBrief.{Delivery, Scope, SharedSource}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.DailyBriefMember

  @default_interval_ms 60_000
  @default_batch 2

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run_once(keyword()) :: {:ok, non_neg_integer()}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    due = Delivery.claim_due(now, Keyword.get(opts, :batch, @default_batch))
    {groups, scopes} = batch_groups(due, now)

    # One member's failure must not cost the rest of the batch their brief.
    # Members in the same batch that read the same Swarms over the same window
    # share one read of the public channels.
    Enum.reduce(due, %{}, fn {settings, member}, shared_cache ->
      scope = Map.fetch!(scopes, member.id)
      key = {Scope.key(scope), Delivery.member_window(member, now)}
      batch_members = Map.get(groups, key, [])
      {shared, shared_cache} = resolve_batch_shared(scope, key, batch_members, shared_cache)

      deliver_opts =
        opts
        |> Keyword.put(:now, now)
        |> Keyword.put(:batch_members, batch_members)
        |> Keyword.put(:scope, scope)
        |> then(&if(shared, do: Keyword.put(&1, :shared, shared), else: &1))

      try do
        Delivery.deliver(settings, member, deliver_opts)
      rescue
        exception ->
          Logger.error(
            "bridge_for_teams.daily_brief.delivery.crashed #{Exception.message(exception)}"
          )

          Delivery.release_claim(settings, member, now)
      catch
        kind, reason ->
          Logger.error(
            "bridge_for_teams.daily_brief.delivery.exited #{kind} #{inspect(reason, limit: 5)}"
          )

          Delivery.release_claim(settings, member, now)
      end

      shared_cache
    end)

    # Then the team briefs whose time has come.
    try do
      Delivery.post_team_briefs(now, opts)
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.daily_brief.team_brief.crashed #{Exception.message(exception)}"
        )
    end

    {:ok, length(due)}
  end

  @impl true
  def init(opts) do
    cfg = SystemsRuntime.get_env(:bridge_for_teams_core, __MODULE__, [])

    interval =
      Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @default_interval_ms))

    schedule(interval)
    # `:run_opts` are passed to each run (an injected model in tests).
    {:ok, %{interval_ms: interval, run_opts: Keyword.get(opts, :run_opts, [])}}
  end

  @impl true
  def handle_info(:deliver, state) do
    try do
      run_once(state.run_opts)
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.daily_brief.delivery_worker.failed #{Exception.message(exception)}"
        )
    end

    schedule(state.interval_ms)
    {:noreply, state}
  end

  # Stray messages (a late reply, a test double's note) are not work.
  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :deliver, interval_ms)

  # Members by the Swarms their brief reads and its window, and each
  # member's Swarms.
  defp batch_groups(due, now) do
    Enum.reduce(due, {%{}, %{}}, fn {settings, claimed}, {groups, scopes} ->
      member = DailyBriefMember |> Repo.get!(claimed.id) |> Repo.preload(:aliases)
      scope = Scope.personal(settings, member)
      key = {Scope.key(scope), Delivery.member_window(member, now)}

      {Map.update(groups, key, [member], &(&1 ++ [member])), Map.put(scopes, member.id, scope)}
    end)
  end

  defp resolve_batch_shared(_scope, key, _members, cache) when is_map_key(cache, key),
    do: {cache[key], cache}

  defp resolve_batch_shared(scope, {scope_key, window} = key, [_, _ | _] = members, cache) do
    case SharedSource.read(scope, window, members: members) do
      {:ok, shared} ->
        shared = Map.put(shared, :scope, scope_key)
        {shared, Map.put(cache, key, shared)}

      _error ->
        {nil, cache}
    end
  end

  defp resolve_batch_shared(_settings, _key, _single, cache), do: {nil, cache}
end
