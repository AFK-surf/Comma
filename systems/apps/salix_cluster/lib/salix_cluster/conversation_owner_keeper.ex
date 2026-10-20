defmodule SalixCluster.ConversationOwnerKeeper do
  @moduledoc """
  Releases local conversation owners that the ring places on another node.

  Group collection, conversation, and participant owners start on demand on
  the ring owner, and nothing else stops them when the ring changes. After a
  rolling restart a copy can stay on the previous owner. Durable writes stay
  CAS-fenced, but its subscribers never see an exit: mutation wakeups route
  to the current owner, so their streams receive neither updates nor
  `resync_required`. Releasing the copy closes those streams; they reconnect
  through current placement.

  Reconciles after each ring change (the ring calls `ring_changed/0` once the
  new node set is stored) and every `:interval_ms`. The periodic pass also
  covers a copy started through a peer whose ring had not caught up. Each
  pass reads the node-local registry and asks each non-owned owner to exit
  (`SalixIM.ConversationFleet.release/1`); it does no storage or remote I/O.
  """

  use SystemsRuntime.Server

  require Logger

  alias SalixCluster.{ConversationPlacement, Ring}

  @name __MODULE__
  @interval_ms :timer.seconds(60)

  def start_link(opts \\ []), do: SystemsRuntime.Server.start_link(__MODULE__, opts, name: @name)

  @doc "Ring-change hook. Runs inside the ring process, so it only sends."
  @spec ring_changed() :: :ok
  def ring_changed do
    case SystemsRuntime.Proc.whereis(@name) do
      nil -> :ok
      pid -> SystemsRuntime.Proc.send(pid, :reconcile)
    end

    :ok
  end

  @doc "Releases each local owner that the current ring places elsewhere."
  @spec reconcile() :: [tuple()]
  def reconcile do
    self_node = Node.self()

    released =
      for {key, pid} <- SalixIM.ConversationFleet.local_owners(),
          Ring.owner(ConversationPlacement.placement_key(key)) != self_node do
        :ok = SalixIM.ConversationFleet.release(pid)
        key
      end

    if released != [] do
      counts = Enum.frequencies_by(released, &elem(&1, 0))
      Logger.info("conversation owner keeper released non-owned owners #{inspect(counts)}")
    end

    released
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    schedule_tick(interval_ms)
    {:ok, %{interval_ms: interval_ms}}
  end

  @impl true
  # Only a tick schedules the next tick, so there is exactly one periodic timer.
  def handle_info(:tick, state) do
    safe_reconcile()
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    safe_reconcile()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Without an interval there is no periodic pass: only ring changes reconcile.
  defp schedule_tick(nil), do: :ok

  defp schedule_tick(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :tick, interval_ms)

  defp safe_reconcile do
    reconcile()
  rescue
    error -> Logger.warning("conversation owner keeper: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("conversation owner keeper: #{inspect(reason)}")
  end
end
