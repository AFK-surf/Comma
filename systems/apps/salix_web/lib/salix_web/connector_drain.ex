defmodule SalixWeb.ConnectorDrain do
  @moduledoc """
  Close local connector sockets before a graceful node shutdown. A socket's
  teardown notification is not death proof: persist cleanup only after its
  local process monitor reports DOWN. Missing replies and timeouts fail closed.
  Abrupt node death still requires operator-attested recovery.
  """

  alias SalixEnv.{Bridge, Registry}

  def drain do
    task = Task.async(&drain_local/0)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :connector_drain_deadline}
    end
  end

  defp drain_local do
    Elixir.Registry.select(Bridge.registry(), [
      {{:"$1", :"$2", :connector}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Task.async_stream(&stop/1,
      max_concurrency: 16,
      timeout: 10_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(:ok, fn
      {:ok, :ok}, result -> result
      failure, _result -> {:error, {:connector_drain_incomplete, failure}}
    end)
  end

  defp stop({transport_id, owner}) do
    ref = Process.monitor(owner)
    send(owner, {:connector_drain, self(), ref})

    try do
      receive do
        {:connector_drain, ^ref, context} ->
          receive do
            {:DOWN, ^ref, :process, ^owner, _reason} -> confirm_stopped(context, transport_id)
          after
            5_000 -> {:error, :owner_stop_unconfirmed}
          end

        {:DOWN, ^ref, :process, ^owner, _reason} ->
          # No context was captured. Do not guess a device or generation from
          # a possibly replaced durable run record.
          {:error, :owner_context_missing}
      after
        5_000 -> {:error, :owner_drain_timeout}
      end
    rescue
      _ -> {:error, :connector_drain_failed}
    catch
      _, _ -> {:error, :connector_drain_failed}
    after
      Process.demonitor(ref, [:flush])
    end
  end

  defp confirm_stopped(context, transport_id) do
    target = %{
      "connector_id" => context.connector_id,
      "credential_generation" => context.credential_generation,
      "connector_run_id" => context.connector_run_id,
      "transport_id" => transport_id,
      "node" => to_string(node())
    }

    # Clear the current pointer first. A concurrent reconnect either precedes
    # this generation-fenced write (leaving a pending predecessor to confirm),
    # or follows it and cannot carry this stopped owner forward.
    case Registry.mark_disconnected(context.connector_run_id,
           connection_generation: context.connection_generation,
           owner_node: to_string(node())
         ) do
      {:ok, _} -> confirm_target(context, target)
      {:error, :not_found} -> confirm_target(context, target)
      error -> error
    end
  end

  defp confirm_target(%{credential_generation: generation} = context, target)
       when is_integer(generation) and generation > 0 do
    Registry.confirm_connector_owner_stop(
      context.tenant_id,
      context.group_id,
      context.device_id,
      generation,
      target
    )
  end

  defp confirm_target(context, target) do
    Registry.confirm_legacy_connector_owner_stop(
      context.tenant_id,
      context.group_id,
      context.device_id,
      context.connector_id,
      target
    )
  end
end
