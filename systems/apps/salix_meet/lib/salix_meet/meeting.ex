defmodule SalixMeet.Meeting do
  @moduledoc """
  One GenServer per live meeting. It holds
  leadership by CAS-renewing the `meet/{id}/state.json` object on an interval —
  the lease is folded into that object, so the same ETag fences both renewal and
  any state mutation. On a lost CAS the process **surrenders** (drops to
  standby): a zombie leader's writes are inert because its ETag is dead.

  Join is at-most-once through the durable `SalixMeet.JoinDispatch` outbox.
  The Meeting process gates calls on live leadership, while the winning caller
  owns the bounded external runtime call. Replays and re-elections are
  resumable from S3, never from process memory.
  """
  use GenServer
  require Logger

  alias SalixMeet.Store

  @renew_interval 10_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Is this node currently the meeting leader?"
  @spec leader?(String.t()) :: boolean()
  def leader?(id) do
    case Registry.lookup(SalixMeet.Registry, id) do
      [{pid, _}] -> GenServer.call(pid, :leader?)
      [] -> false
    end
  end

  @doc "Request to join (at most once). Returns the `join_requested_at` timestamp."
  @spec join(String.t()) :: {:ok, integer()} | {:error, term()}
  def join(id) do
    case Registry.lookup(SalixMeet.Registry, id) do
      [{pid, _}] ->
        if GenServer.call(pid, :leader?),
          do: SalixMeet.JoinDispatch.run(id),
          else: {:error, :not_leader}

      [] ->
        {:error, :not_running}
    end
  end

  defp via(id), do: {:via, Registry, {SalixMeet.Registry, id}}

  @impl true
  def init(opts) do
    state = %{
      id: Keyword.fetch!(opts, :id),
      node: Keyword.get(opts, :node, to_string(node())),
      interval: Keyword.get(opts, :interval_ms, @renew_interval),
      etag: nil,
      doc: nil,
      copilot_running: false
    }

    {:ok, state, {:continue, :acquire}}
  end

  @impl true
  def handle_continue(:acquire, state), do: {:noreply, tick(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(state)}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state),
    do: {:noreply, %{state | copilot_running: false}}

  @impl true
  def handle_call(:leader?, _from, state), do: {:reply, leader_held?(state), state}

  defp leader_held?(state), do: state.etag != nil and state.doc["leader_node"] == state.node

  defp tick(state) do
    state = acquire_or_renew(state)
    state = maybe_run_copilot(state)
    Process.send_after(self(), :tick, state.interval)
    state
  end

  defp maybe_run_copilot(%{copilot_running: true} = state), do: state

  defp maybe_run_copilot(state) do
    if copilot_enabled?() and leader_held?(state) and active?(state.doc) do
      id = state.id
      spawn_monitor(fn -> SalixMeet.Ports.Copilot.maybe_speak(id) end)
      %{state | copilot_running: true}
    else
      state
    end
  end

  defp active?(doc), do: get_in(doc || %{}, ["state", "status"]) == "active"

  defp copilot_enabled?, do: Application.get_env(:salix_meet, :copilot_enabled, true)

  # Standby: (re)load the state object — resumable across restarts/elections —
  # then try to claim leadership by CAS.
  defp acquire_or_renew(%{etag: nil} = state) do
    case load(state.id) do
      {:ok, _doc, etag} -> claim(%{state | etag: etag})
      {:error, _} -> state
    end
  end

  # Leader: CAS-renew; a lost CAS surrenders (fail-closed).
  defp acquire_or_renew(state) do
    case Store.claim_leader(state.id, state.node, state.etag) do
      {:ok, doc, etag} ->
        %{state | doc: doc, etag: etag}

      {:error, :lost} ->
        Logger.info("meeting #{state.id}: surrendered leadership (CAS lost)")
        %{state | doc: nil, etag: nil}

      {:error, {:held_by, _, _}} ->
        %{state | doc: nil, etag: nil}

      _ ->
        %{state | doc: nil, etag: nil}
    end
  end

  defp claim(state) do
    case Store.claim_leader(state.id, state.node, state.etag) do
      {:ok, doc, etag} ->
        Logger.info("meeting #{state.id}: leader on #{state.node}")
        %{state | doc: doc, etag: etag}

      _ ->
        %{state | doc: nil, etag: nil}
    end
  end

  # Resumable load: create-once on first sight, otherwise read the existing doc.
  defp load(id) do
    case Store.create_once(id) do
      {:ok, doc, etag} -> {:ok, doc, etag}
      {:error, :exists} -> Store.get(id)
      other -> other
    end
  end
end
