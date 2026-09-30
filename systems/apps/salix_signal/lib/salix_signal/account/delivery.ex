defmodule SalixSignal.Account.Delivery do
  @moduledoc """
  Hands an account's admitted messages to the product handler
  (`SalixSignal.Account.Handler.handle_inbound/3`) outside the account's
  owner process.

  The owner (`SalixSignal.Account.Server`) commits and acknowledges each
  envelope (PLAN "Durable state"), then tells this process that the
  durable inbound feed has grown. This process reads the feed after its
  cursor (`SalixSignal.Storage.inbound_after/3`), calls the handler for
  each deliverable item in `seq` order, and moves the durable cursor past
  the items the handler accepted (`SalixSignal.Storage.advance_delivered/3`,
  fenced by the owner's epoch). A refused item, or a raise, stops the run;
  the item is offered again after `retry_ms`, on the next notification, or
  after a restart, so delivery stays at least once and in order.

  Because the handler runs here, it may block (attachment downloads, Router
  admission) and may call `SalixSignal.Account` operations on its own
  account without waiting for itself. The owner keeps receiving envelopes,
  answering sends and handling calls meanwhile.

  The process is linked to its owner. A fenced cursor write stops it with
  `{:shutdown, :fenced}`: a newer owner has the account and its own
  delivery process.
  """

  use GenServer

  require Logger

  alias SalixSignal.Messaging.Inbound
  alias SalixSignal.Storage

  @delivered_kinds [:data, :edit, :receipt, :typing]
  @batch 100

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, Map.new(opts))

  @doc "Tells the process that new items may be in the feed."
  @spec notify(pid()) :: :ok
  def notify(pid) do
    send(pid, :deliver)
    :ok
  end

  @doc "The item kinds that reach `handle_inbound/3`."
  def delivered_kinds, do: @delivered_kinds

  @impl true
  def init(%{account_id: id, epoch: epoch, handler: handler, delivered: delivered} = opts) do
    Logger.metadata(signal_account: id)

    state = %{
      id: id,
      epoch: epoch,
      handler: handler,
      delivered: delivered,
      retry_ms: Map.get(opts, :retry_ms, 30_000),
      timer: nil
    }

    {:ok, state, {:continue, :deliver}}
  end

  @impl true
  def handle_continue(:deliver, state), do: run(state)

  @impl true
  def handle_info(:deliver, state), do: run(state)
  def handle_info(:retry, state), do: run(%{state | timer: nil})
  def handle_info(_message, state), do: {:noreply, state}

  # Status and crash reports show no message content.
  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{id: id, delivered: delivered} -> %{id: id, delivered: delivered, redacted: true}
      other -> other
    end)
  end

  # A pending retry waits for its timer; notifications meanwhile would
  # offer the refused item again at once.
  defp run(%{timer: timer} = state) when timer != nil, do: {:noreply, state}

  defp run(state) do
    case Storage.inbound_after(state.id, state.delivered, @batch) do
      {:ok, items} -> deliver(state, items)
      {:error, reason} -> retry(state, {:feed, reason})
    end
  end

  defp deliver(state, items) do
    {last, outcome} =
      Enum.reduce_while(items, {state.delivered, :ok}, fn {seq, inbound}, {last, :ok} ->
        if deliverable?(inbound) do
          case call_handler(state, seq, inbound) do
            :ok -> {:cont, {seq, :ok}}
            error -> {:halt, {last, error}}
          end
        else
          {:cont, {seq, :ok}}
        end
      end)

    with {:ok, state} <- advance(state, last) do
      cond do
        outcome != :ok -> retry(state, outcome)
        length(items) == @batch -> run(state)
        true -> {:noreply, state}
      end
    end
  end

  defp advance(%{delivered: delivered} = state, last) when last <= delivered, do: {:ok, state}

  defp advance(state, last) do
    case Storage.advance_delivered(state.id, state.epoch, last) do
      :ok -> {:ok, %{state | delivered: last}}
      {:error, :fenced} -> {:stop, {:shutdown, :fenced}, state}
    end
  end

  defp retry(state, reason) do
    Logger.info("signal inbound delivery deferred: #{inspect(reason)}")
    {:noreply, %{state | timer: Process.send_after(self(), :retry, state.retry_ms)}}
  end

  defp deliverable?(%Inbound{outcome: :message, content_kind: kind}), do: kind in @delivered_kinds
  defp deliverable?(_inbound), do: false

  defp call_handler(state, seq, inbound) do
    state.handler.handle_inbound(state.id, seq, inbound)
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
