defmodule CommaWeb.IMessageRuntime do
  @moduledoc """
  One cluster-wide receiver for the shared product relay.
  PostgreSQL session ownership serializes receiver passes.
  Each pass handles and checkpoints events in relay order.
  The canonical Session deduplicates stable source ids after a lost checkpoint.
  No progress is promised while the relay, database or Router is unavailable.
  """
  use GenServer
  require Logger
  alias Comma.Repo
  alias SalixIM.IMessageRelay

  @retry_ms 5_000
  @max_failures 3

  def child_specs, do: if(IMessageRelay.configured?(), do: [__MODULE__], else: [])
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    send(self(), :poll)
    {:ok, %{task: nil, failures: 0}}
  end

  @impl true
  def handle_info(:poll, %{task: nil, failures: failures} = state)
      when failures < @max_failures do
    task = Task.async(fn -> run_once() end)
    {:noreply, %{state | task: task}}
  end

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    failures =
      case result do
        :ok -> 0
        :standby -> state.failures
        {:error, _} -> state.failures + 1
      end

    if failures >= @max_failures do
      Logger.error(
        "iMessage receiver paused after three failed passes; restore the relay or database, then restart the receiver"
      )
    else
      Process.send_after(self(), :poll, @retry_ms)
    end

    {:noreply, %{state | task: nil, failures: failures}}
  end

  def run_once do
    Repo.checkout(
      fn ->
        case Repo.query!("SELECT pg_try_advisory_lock(4412741, 21577)").rows do
          [[true]] ->
            try do
              receive_pass()
            after
              Repo.query!("SELECT pg_advisory_unlock(4412741, 21577)")
            end

          [[false]] ->
            :standby
        end
      end,
      timeout: 120_000
    )
  rescue
    _ -> {:error, :imessage_receive_unavailable}
  catch
    :exit, _ -> {:error, :imessage_receive_unavailable}
  end

  defp receive_pass do
    Comma.IMessageLinks.prune_expired_claims()

    with {:ok, cursor} <- cursor(),
         :ok <- IMessageRelay.stream(cursor, &handle_and_checkpoint/1) do
      Repo.query!(
        "UPDATE comma_imessage_relay_cursors SET updated_at = timezone('utc', now()) WHERE relay_id = $1",
        [IMessageRelay.relay_id()]
      )

      :ok
    end
  end

  defp cursor do
    case Repo.query!("SELECT event_id FROM comma_imessage_relay_cursors WHERE relay_id = $1", [
           IMessageRelay.relay_id()
         ]).rows do
      [[event_id]] ->
        {:ok, event_id}

      [] ->
        with {:ok, tail} <- IMessageRelay.tail() do
          Repo.query!(
            "INSERT INTO comma_imessage_relay_cursors (relay_id, event_id, inserted_at, updated_at) VALUES ($1, $2, timezone('utc', now()), timestamp '1970-01-01 00:00:00')",
            [IMessageRelay.relay_id(), tail]
          )

          {:ok, tail}
        end
    end
  end

  @doc false
  def handle_and_checkpoint(event) do
    with :ok <- CommaWeb.IMessageIntegration.handle_event(event) do
      Repo.query!(
        "UPDATE comma_imessage_relay_cursors SET event_id = $2, updated_at = timezone('utc', now()) WHERE relay_id = $1",
        [IMessageRelay.relay_id(), event["event_id"]]
      )

      :ok
    end
  end

  def online? do
    IMessageRelay.configured?() and
      case Repo.query(
             "SELECT updated_at > timezone('utc', now()) - interval '90 seconds' FROM comma_imessage_relay_cursors WHERE relay_id = $1",
             [IMessageRelay.relay_id()]
           ) do
        {:ok, %{rows: [[true]]}} -> true
        _ -> false
      end
  end
end
