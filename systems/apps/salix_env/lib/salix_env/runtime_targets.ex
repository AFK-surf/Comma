defmodule SalixEnv.RuntimeTargets do
  @moduledoc """
  Derived exact locators for opaque device-runtime IDs. A locator grants nothing:
  Control always rereads the named device's authoritative current inventory.
  Connection/inventory observation and bounded discovery can rebuild the locator;
  a missing locator returns discovery_required rather than scanning the Group.

  The same rows project readiness expiry for Session wake notifications. A
  device advertises at most 32 runtimes. Publication only touches that device's
  active hints and advertised locators, with a 500 ms database operation budget.
  Inventory refresh repairs a failed publication. Dispatch rereads authority;
  these expiring hints cannot grant execution or refresh a runtime probe.
  """
  require Logger
  import Ecto.Query
  alias SalixStore.{Repo, RuntimeIds, SessionWorkNotifications}

  @publication_timeout_ms 500

  defmodule Locator do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    schema "device_runtime_locators" do
      field(:tenant_id, :string, primary_key: true)
      field(:group_id, :string, primary_key: true)
      field(:device_runtime_id, :string, primary_key: true)
      field(:device_id, :string)
      field(:ready_until_ms, :integer)
    end
  end

  def device(tenant_id, group_id, runtime_id) do
    case Repo.get_by(Locator,
           tenant_id: tenant_id,
           group_id: group_id,
           device_runtime_id: runtime_id
         ) do
      nil -> {:error, :target_discovery_required}
      locator -> SalixEnv.Registry.get_device(tenant_id, group_id, locator.device_id)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Materialize runtime locators and durable readiness hints for Session notifications."
  def observe(device) do
    meta = device["meta"] || %{}
    runtimes = List.wrap(meta["agent_runtimes"])
    ready = SalixEnv.Control.ready_runtime_deadlines(device)

    rows =
      Enum.flat_map(runtimes, fn runtime ->
        if is_map(runtime) and RuntimeIds.external_runtime_provider?(runtime["provider"]) and
             is_binary(runtime["device_runtime_id"]) and is_binary(device["device_id"]) do
          [
            %{
              tenant_id: device["tenant_id"],
              group_id: device["group_id"],
              device_runtime_id: runtime["device_runtime_id"],
              device_id: device["device_id"],
              ready_until_ms: ready[runtime["device_runtime_id"]]
            }
          ]
        else
          []
        end
      end)

    # Replace this device's hints atomically. Removed/offline runtimes must not
    # keep waking Sessions. A stale hint never authorizes a dispatch.
    Repo.transaction(
      fn ->
        now_ms = System.system_time(:millisecond)

        previous =
          from(d in Locator,
            where:
              d.tenant_id == ^device["tenant_id"] and d.group_id == ^device["group_id"] and
                d.device_id == ^device["device_id"] and d.ready_until_ms > ^now_ms,
            select: d.device_runtime_id
          )
          |> Repo.all(timeout: @publication_timeout_ms)
          |> MapSet.new()

        from(d in Locator,
          where:
            d.tenant_id == ^device["tenant_id"] and d.group_id == ^device["group_id"] and
              d.device_id == ^device["device_id"] and not is_nil(d.ready_until_ms)
        )
        |> Repo.update_all([set: [ready_until_ms: nil]], timeout: @publication_timeout_ms)

        if rows != [],
          do:
            Repo.insert_all(Locator, Enum.uniq(rows),
              on_conflict: {:replace, [:ready_until_ms]},
              conflict_target: [:tenant_id, :group_id, :device_runtime_id],
              timeout: @publication_timeout_ms
            )

        if Enum.any?(Map.keys(ready), &(not MapSet.member?(previous, &1))) do
          Repo.query!(
            "SELECT pg_notify($1, $2)",
            [
              SessionWorkNotifications.channel(),
              SessionWorkNotifications.runtime_ready_payload()
            ],
            timeout: @publication_timeout_ms
          )
        end
      end,
      timeout: @publication_timeout_ms
    )
    |> case do
      {:ok, _} -> :ok
      {:error, _} -> notification_unavailable()
    end
  rescue
    _ -> notification_unavailable()
  catch
    _, _ -> notification_unavailable()
  end

  defp notification_unavailable do
    Logger.warning(
      "runtime-ready notification projection unavailable; inventory publication will retry"
    )

    {:error, :runtime_notification_unavailable}
  end
end
