defmodule SalixEnv.StationConnection do
  @moduledoc """
  Admission of one operation from an existing Station connection.

  Registry owns the current connector run. Compute owns its Workload and
  generation. The callback receives one authorized owner/account snapshot;
  it must not resolve another generation while issuing a grant.
  """
  alias SalixStore.ComputeStation
  alias SalixEnv.Registry

  def authorize(
        %{tenant_id: tenant, group_id: group, device_id: device, connector_run_id: run} = context
      )
      when is_binary(run) do
    with {:ok, %{"status" => "connected", "connector_run_id" => ^run}} <-
           Registry.get_device(tenant, group, device),
         {:ok, record} <- ComputeStation.authorize(context) do
      {:ok, record}
    else
      _ -> {:error, :station_connection_changed}
    end
  end

  def authorize(_), do: {:error, :station_connection_changed}

  def with_current(context, operation, opts \\ []) when is_function(operation, 1) do
    if Keyword.get(opts, :lock, false) and is_binary(context[:workload_id]) do
      ComputeStation.with_connection(context.workload_id, context.workload_generation, fn ->
        with {:ok, record} <- authorize(context), do: operation.(record)
      end)
    else
      with {:ok, record} <- authorize(context), do: operation.(record)
    end
  end
end
