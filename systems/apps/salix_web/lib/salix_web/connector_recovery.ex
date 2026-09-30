defmodule SalixWeb.ConnectorRecovery do
  @moduledoc """
  Retries one ordinary connector RPC across WebSocket replacement.

  The caller subscribes before its first dispatch, so a replacement cannot be
  missed between the old socket going down and the recovery wait. The existing
  request envelope — including its id — is reused verbatim. `ConnectorSocket`
  broadcasts readiness only after the new bridge owner is registered. An
  ephemeral process instance id fences recovery to another WebSocket owned by
  the same connector process; process replacement returns `:disconnected`.

  This is deliberately not used for frame streams. Their offsets and ACK state
  belong to one connection generation.
  """

  alias SalixEnv.{Connector, Protocol, Registry}

  @default_reconnect_grace_ms 10_000

  @type target :: %{
          required(:connector_run_id) => String.t(),
          required(:tenant_id) => String.t(),
          required(:group_id) => String.t(),
          required(:device_id) => String.t(),
          required(:process_instance_id) => String.t() | nil
        }

  @spec request(target(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def request(target, method, params, opts \\ []) do
    timeout = opts[:timeout] || Protocol.timeout(method, params)
    message = Protocol.request(method, params)
    topic = topic(target)
    deadline = monotonic_ms() + timeout

    :ok = Phoenix.PubSub.subscribe(SalixWeb.PubSub, topic)

    try do
      dispatch(target, message, deadline)
    after
      :ok = Phoenix.PubSub.unsubscribe(SalixWeb.PubSub, topic)
      flush_ready(topic)
    end
  end

  @doc "Broadcast that a replacement socket is routable for its stable device."
  @spec notify_ready(map()) :: :ok
  def notify_ready(target) do
    topic = topic(target)
    Phoenix.PubSub.broadcast(SalixWeb.PubSub, topic, {:connector_ready, topic, target})
  end

  defp dispatch(target, message, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      timeout ->
        case Connector.Live.dispatch(target.connector_run_id, message, timeout) do
          {:error, :disconnected} -> recover(target, message, deadline)
          result -> result
        end
    end
  end

  defp recover(target, message, deadline) do
    case refreshed_target(target) do
      {:ok, refreshed} ->
        dispatch(refreshed, message, deadline)

      :process_replaced ->
        {:error, :disconnected}

      :unchanged ->
        await_ready(target, message, deadline)
    end
  end

  defp refreshed_target(target) do
    case Registry.get_device(target.tenant_id, target.group_id, target.device_id) do
      {:ok, %{"status" => "connected", "connector_run_id" => run_id} = record}
      when is_binary(run_id) and run_id != "" and run_id != target.connector_run_id ->
        refreshed = from_record(record)

        if same_process?(target, refreshed),
          do: {:ok, refreshed},
          else: :process_replaced

      _ ->
        :unchanged
    end
  end

  defp await_ready(target, message, deadline) do
    wait_ms = min(remaining(deadline), reconnect_grace_ms())
    topic = topic(target)

    if wait_ms == 0 do
      {:error, :disconnected}
    else
      receive do
        {:connector_ready, ^topic, ready} ->
          if same_process?(target, ready),
            do: dispatch(ready, message, deadline),
            else: {:error, :disconnected}
      after
        wait_ms -> {:error, :disconnected}
      end
    end
  end

  defp from_record(record) do
    %{
      connector_run_id: record["connector_run_id"],
      tenant_id: record["tenant_id"],
      group_id: record["group_id"],
      device_id: record["device_id"],
      process_instance_id: record["process_instance_id"]
    }
  end

  defp same_process?(%{process_instance_id: id}, %{process_instance_id: id})
       when is_binary(id) and id != "",
       do: true

  defp same_process?(_left, _right), do: false

  defp topic(target) do
    "connector-ready:#{target.tenant_id}:#{target.group_id}:#{target.device_id}"
  end

  defp reconnect_grace_ms do
    Application.get_env(
      :salix_web,
      :connector_reconnect_grace_ms,
      @default_reconnect_grace_ms
    )
  end

  defp remaining(deadline), do: max(deadline - monotonic_ms(), 0)
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp flush_ready(topic) do
    receive do
      {:connector_ready, ^topic, _target} -> flush_ready(topic)
    after
      0 -> :ok
    end
  end
end
