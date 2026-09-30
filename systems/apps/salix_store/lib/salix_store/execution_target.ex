defmodule SalixStore.ExecutionTarget do
  @moduledoc """
  Stable execution references. These values contain existing IDs, never routes
  or authority. The Device or Workload owner authorizes each reference before
  resolving its current connection.
  """

  @type t ::
          {:device_environment, String.t(), String.t()}
          | {:device_runtime, String.t()}
          | {:compute_workload, String.t()}

  @spec environment(term()) :: {:ok, t()} | {:error, :invalid_execution_target}
  def environment(%{device_id: device_id, environment_id: environment_id})
      when is_binary(device_id) and device_id != "" and
             is_binary(environment_id) and environment_id != "",
      do: {:ok, {:device_environment, device_id, environment_id}}

  def environment(_), do: {:error, :invalid_execution_target}

  @spec binding(term()) :: {:ok, t()} | {:error, :invalid_execution_target}
  def binding(%{"kind" => kind, "device_runtime_id" => id})
      when kind in ["connected_runtime", "external"] and is_binary(id) and id != "",
      do: {:ok, {:device_runtime, id}}

  def binding(%{"kind" => "compute_workload", "workload_id" => id})
      when is_binary(id) and id != "",
      do: {:ok, {:compute_workload, id}}

  def binding(_), do: {:error, :invalid_execution_target}
end
