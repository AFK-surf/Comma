defmodule SalixEnv.ComputeRuntimeControl do
  @moduledoc """
  Exact-target control operations for one Compute Runtime.

  Control is independent from provider authentication. Durable target facts are
  checked before and after the live carrier call.
  """

  alias SalixStore.ComputeRuntimeTarget

  def quiet(attrs) when is_map(attrs) do
    case ComputeRuntimeTarget.rpc(attrs, :exact, fn target ->
           {:ok,
            %{
              "method" => "agent_runtime_quiet",
              "params" => %{"target" => ComputeRuntimeTarget.wire_target(target)}
            }}
         end) do
      {:ok, %{"quiet" => true} = result, _target} -> {:ok, result}
      {:ok, _invalid_result, _target} -> {:error, :invalid_runtime_control_response}
      {:error, :runtime_rpc_target_changed} -> {:error, :runtime_control_target_changed}
      {:error, _} = error -> error
    end
  end

  def quiet(_attrs), do: {:error, :invalid_runtime_control_request}
end
