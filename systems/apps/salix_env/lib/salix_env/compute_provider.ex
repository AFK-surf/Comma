defmodule SalixEnv.ComputeProvider do
  @moduledoc """
  Narrow execution contract implemented by every Salix Compute provider.

  The control plane owns Project intent, placement, generations, leases,
  Workloads, and authority. Providers receive one exact generation and return
  an explicit operation outcome; they never manufacture product identity.
  """

  @type capability :: :runtime_exec | :runtime_process | :service_private | :service_public_http
  @type outcome :: :pending | :succeeded | :failed | :unknown_outcome
  @type operation_result :: %{required(:outcome) => outcome(), optional(atom()) => term()}
  @type allocation :: map()
  @type workload :: map()
  @type provider_result :: {:ok, operation_result()} | {:error, term()}

  @callback capabilities() :: [capability()]
  @callback allocate(allocation(), workload(), keyword()) :: provider_result()
  @callback observe(allocation(), keyword()) :: provider_result()
  @callback release(allocation(), keyword()) :: provider_result()
  @callback bootstrap(allocation(), workload(), map(), keyword()) :: provider_result()
  @callback checkpoint(allocation(), keyword()) :: provider_result()
  @callback restore(allocation(), term(), keyword()) :: provider_result()

  def validate_result({:ok, %{outcome: outcome}} = result)
      when outcome in [:pending, :succeeded, :failed, :unknown_outcome],
      do: result

  def validate_result({:error, _} = error), do: error
  def validate_result(_), do: {:error, :invalid_provider_result}
end
