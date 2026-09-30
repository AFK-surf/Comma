defmodule BridgeForTeams.Salix.EventRelay do
  @moduledoc """
  Relays live Salix agent runtime events onto BridgeForTeams's own PubSub so
  dashboard LiveViews refresh the moment an agent does something, instead of
  waiting for their polling fallback.

  The Salix runtime broadcasts `{:salix_agent_event, agent_id, event}` on the
  per-agent topic `"agent:<id>"` of `SalixWeb.PubSub`
  (`SalixWeb.PubSubNotifier`). That PubSub only exists when `:salix_web` runs
  in the same BEAM (co-resident deployments — dev, test, single-node prod).
  This relay bridges those events onto `BridgeForTeamsWeb.PubSub` as

      {:agent_event, org_id, salix_agent_id, event}

  on the per-org topic `topic(org_id)` (`"org:<org_id>:agent_events"`).

  Subscriptions are lazy and interest-scoped: a LiveView calls `watch/1` on
  mount, and only then does the relay resolve the org's provisioned agents
  (Postgres roster, projects joined by org) and subscribe to their agent
  topics; the watcher is monitored and when the last watcher for an org goes
  away the relay unsubscribes. A later `watch/1` re-resolves the roster, so
  agents provisioned since the first watcher arrived get picked up.

  Degrades gracefully in split deployments: when `SalixWeb.PubSub` is not
  running locally, `watch/1` answers `{:error, :unavailable}` and callers keep
  their polling loop — events are a liveness upgrade, never a correctness
  dependency (which is also why the roster resolution failing soft, e.g. a DB
  hiccup, only costs freshness).
  """

  use GenServer

  import Ecto.Query, only: [from: 2]

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{Agent, Project}

  @default_salix_pubsub SalixWeb.PubSub
  @default_bft_pubsub BridgeForTeamsWeb.PubSub

  # ---- client API -----------------------------------------------------------

  @doc """
  Start the relay. Options (all optional, defaults are the production wiring):

    * `:name` — registered name (default `#{inspect(__MODULE__)}`)
    * `:salix_pubsub` — the Salix-side PubSub to bridge from
    * `:bft_pubsub` — the BridgeForTeams-side PubSub to broadcast onto
    * `:agent_resolver` — `(org_id -> [salix_agent_id])`, defaults to the
      Postgres roster (active agents of the org's projects)
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The `BridgeForTeamsWeb.PubSub` topic carrying an org's agent events."
  @spec topic(String.t()) :: String.t()
  def topic(org_id), do: "org:#{org_id}:agent_events"

  @doc """
  Register the calling process's interest in `org_id`'s agent events. The
  caller is monitored; when the last watcher of an org exits (or `unwatch/2`s)
  the relay drops the org's Salix subscriptions. Returns `:ok`, or
  `{:error, :unavailable}` when the Salix PubSub isn't running locally (split
  deployment) — callers should keep polling.
  """
  @spec watch(String.t(), GenServer.server()) :: :ok | {:error, :unavailable}
  def watch(org_id, server \\ __MODULE__) do
    GenServer.call(server, {:watch, org_id, self()})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc "Drop the calling process's interest in `org_id`'s agent events."
  @spec unwatch(String.t(), GenServer.server()) :: :ok
  def unwatch(org_id, server \\ __MODULE__) do
    GenServer.call(server, {:unwatch, org_id, self()})
  catch
    :exit, _reason -> :ok
  end

  @doc "Whether the relay can bridge events (Salix PubSub running locally)."
  @spec available?(GenServer.server()) :: boolean()
  def available?(server \\ __MODULE__) do
    GenServer.call(server, :available?)
  catch
    :exit, _reason -> false
  end

  # ---- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       salix_pubsub: Keyword.get(opts, :salix_pubsub, @default_salix_pubsub),
       bft_pubsub: Keyword.get(opts, :bft_pubsub, @default_bft_pubsub),
       agent_resolver: Keyword.get(opts, :agent_resolver, &resolve_org_agents/1),
       # org_id => %{watcher_pid => monitor_ref}
       watchers: %{},
       # org_id => MapSet of subscribed salix agent ids
       org_agents: %{},
       # salix agent id => org_id (event routing)
       agent_orgs: %{}
     }}
  end

  @impl true
  def handle_call({:watch, org_id, pid}, _from, state) do
    if salix_pubsub_up?(state) do
      state =
        state
        |> add_watcher(org_id, pid)
        |> subscribe_org_agents(org_id)

      {:reply, :ok, state}
    else
      {:reply, {:error, :unavailable}, state}
    end
  end

  def handle_call({:unwatch, org_id, pid}, _from, state) do
    {:reply, :ok, drop_watcher(state, org_id, pid)}
  end

  def handle_call(:available?, _from, state) do
    {:reply, salix_pubsub_up?(state), state}
  end

  @impl true
  def handle_info({:salix_agent_event, agent_id, event}, state) do
    with org_id when is_binary(org_id) <- state.agent_orgs[agent_id],
         pid when is_pid(pid) <- Process.whereis(state.bft_pubsub) do
      Phoenix.PubSub.broadcast(
        state.bft_pubsub,
        topic(org_id),
        {:agent_event, org_id, agent_id, event}
      )
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state =
      state.watchers
      |> Enum.filter(fn {_org_id, pids} -> pids[pid] == ref end)
      |> Enum.reduce(state, fn {org_id, _pids}, acc -> drop_watcher(acc, org_id, pid) end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---- internal ----------------------------------------------------------------

  defp salix_pubsub_up?(state), do: is_pid(Process.whereis(state.salix_pubsub))

  defp add_watcher(state, org_id, pid) do
    pids = Map.get(state.watchers, org_id, %{})

    pids =
      case pids do
        %{^pid => _ref} -> pids
        _ -> Map.put(pids, pid, Process.monitor(pid))
      end

    put_in(state.watchers[org_id], pids)
  end

  # Re-resolves the roster on every watch so newly provisioned agents get a
  # subscription; already-subscribed topics are kept (never doubled).
  defp subscribe_org_agents(state, org_id) do
    subscribed = Map.get(state.org_agents, org_id, MapSet.new())
    resolved = resolve_agents(state, org_id)

    fresh = MapSet.difference(resolved, subscribed)
    Enum.each(fresh, &Phoenix.PubSub.subscribe(state.salix_pubsub, agent_topic(&1)))

    all = MapSet.union(subscribed, resolved)

    %{
      state
      | org_agents: Map.put(state.org_agents, org_id, all),
        agent_orgs: Enum.reduce(fresh, state.agent_orgs, &Map.put(&2, &1, org_id))
    }
  end

  defp drop_watcher(state, org_id, pid) do
    pids = Map.get(state.watchers, org_id, %{})

    case Map.pop(pids, pid) do
      {nil, _pids} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])

        if map_size(rest) == 0 do
          state
          |> Map.update!(:watchers, &Map.delete(&1, org_id))
          |> unsubscribe_org_agents(org_id)
        else
          put_in(state.watchers[org_id], rest)
        end
    end
  end

  defp unsubscribe_org_agents(state, org_id) do
    agents = Map.get(state.org_agents, org_id, MapSet.new())

    if salix_pubsub_up?(state) do
      Enum.each(agents, &Phoenix.PubSub.unsubscribe(state.salix_pubsub, agent_topic(&1)))
    end

    %{
      state
      | org_agents: Map.delete(state.org_agents, org_id),
        agent_orgs: Map.drop(state.agent_orgs, MapSet.to_list(agents))
    }
  end

  # `SalixWeb.PubSubNotifier.topic/1`'s wire format, spelled out here so this
  # app carries no compile-time dependency on :salix_web.
  defp agent_topic(salix_agent_id), do: "agent:" <> salix_agent_id

  # Default roster resolution: every active, provisioned agent across the
  # org's projects. Soft-fails to [] — a DB hiccup costs liveness, not the
  # relay process.
  defp resolve_agents(state, org_id) do
    state.agent_resolver.(org_id)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  rescue
    _exception -> MapSet.new()
  catch
    _kind, _reason -> MapSet.new()
  end

  defp resolve_org_agents(org_id) do
    from(a in Agent,
      join: p in Project,
      on: a.project_id == p.id,
      where: p.org_id == ^org_id and not is_nil(a.salix_agent_id),
      select: a.salix_agent_id
    )
    |> Repo.all()
  end
end
