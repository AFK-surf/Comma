defmodule SalixSignal.Account.Keeper do
  @moduledoc """
  Starts the owner process of every `active` Signal account whose ring owner
  is this node, and stops local owner processes that the ring moved away
  (PLAN "Rollouts": the account moves with the ring, fenced by epoch).

  It reconciles at start and then every `interval_ms` (default 60 s) on one
  periodic timer. A node joining or leaving adds one pass after
  `membership_delay_ms` (default 1 s; changes inside that delay share the
  pass) and does not start another periodic timer. Each pass reads the
  accounts in pages of 500; the `reconcile` option replaces the pass with a
  zero-arity function (tests). Without a storage key or database it logs and
  waits for the next pass. The keeper is enabled by
  `config :salix_signal, :account_keeper` (default true; tests turn it off).
  """

  use GenServer

  require Logger

  alias SalixSignal.Accounts

  @page 500

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    :net_kernel.monitor_nodes(true, node_type: :visible)
    send(self(), :tick)

    {:ok,
     %{
       interval_ms: Keyword.get(opts, :interval_ms, 60_000),
       membership_delay_ms: Keyword.get(opts, :membership_delay_ms, 1_000),
       reconcile: Keyword.get(opts, :reconcile, &reconcile/0),
       pending: nil
     }}
  end

  @impl true
  # The periodic chain: only a tick schedules the next tick, so the keeper
  # always has exactly one periodic timer.
  def handle_info(:tick, state) do
    state.reconcile.()
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  # One extra pass after membership changes; it does not touch the chain.
  def handle_info(:reconcile, state) do
    state.reconcile.()
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({event, _node, _info}, %{pending: nil} = state)
      when event in [:nodeup, :nodedown] do
    {:noreply,
     %{state | pending: Process.send_after(self(), :reconcile, state.membership_delay_ms)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def reconcile do
    case active_ids(nil, []) do
      {:ok, active} -> reconcile(active)
      {:error, reason} -> Logger.info("signal account keeper waits: #{inspect(reason)}")
    end
  rescue
    error -> Logger.warning("signal account keeper: #{Exception.message(error)}")
  catch
    :exit, reason -> Logger.warning("signal account keeper: #{inspect(reason)}")
  end

  defp reconcile(active) do
    active_set = MapSet.new(active)

    for id <- active, Accounts.owner_node(id) == node(), Accounts.whereis(id) == nil do
      case Accounts.start_local(id) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("signal account start failed: #{inspect(reason)}")
      end
    end

    running = Registry.select(SalixSignal.Account.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

    for id <- running, not MapSet.member?(active_set, id) or Accounts.owner_node(id) != node() do
      Accounts.stop_local(id)
    end

    :ok
  end

  defp active_ids(after_id, acc) do
    with {:ok, page} <-
           SalixSignal.Storage.list_accounts(state: :active, limit: @page, after: after_id) do
      acc = acc ++ Enum.map(page, & &1.id)
      if length(page) == @page, do: active_ids(List.last(page).id, acc), else: {:ok, acc}
    end
  end
end
