defmodule SalixAgent.Placement do
  @moduledoc """
  Decoupling seam for agent placement. By default an agent Server is
  started locally; in a cluster the `salix_cluster` layer installs an
  implementation that routes `ensure_started` to the ring-owner node via
  `:erpc`, so any node can accept a delivery and the owning Server still runs in
  one place.

  Default is `LocalFleet` (single-node) so `salix_agent` carries no cluster
  dependency.
  """

  @callback ensure_started(agent_id :: String.t(), opts :: keyword()) ::
              {:ok, pid()} | {:error, term()}

  @callback stop_existing(agent_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @doc """
  Run `{module, function, args}` on the node that currently owns
  `agent_id`. Node-local state that must be read or changed where the Agent
  runs (a background Loop's spinfoam object) goes through this seam.
  """
  @callback run_on_owner(agent_id :: String.t(), mfa :: mfa(), timeout :: pos_integer()) ::
              term() | {:error, term()}

  # Single-node implementations (and test doubles) need no routing: without
  # the callback the seam applies the function locally.
  @optional_callbacks run_on_owner: 3

  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(agent_id, opts \\ []), do: impl().ensure_started(agent_id, opts)

  @spec stop_existing(String.t(), keyword()) :: :ok | {:error, term()}
  def stop_existing(agent_id, opts \\ []), do: impl().stop_existing(agent_id, opts)

  @spec run_on_owner(String.t(), mfa(), pos_integer()) :: term() | {:error, term()}
  def run_on_owner(agent_id, {module, function, args} = mfa, timeout \\ 5_000) do
    impl = impl()

    if function_exported?(impl, :run_on_owner, 3),
      do: impl.run_on_owner(agent_id, mfa, timeout),
      else: apply(module, function, args)
  end

  defp impl, do: Application.get_env(:salix_agent, :placement, __MODULE__.LocalFleet)

  defmodule LocalFleet do
    @moduledoc false
    @behaviour SalixAgent.Placement
    @impl true
    def ensure_started(agent_id, opts), do: SalixAgent.Fleet.ensure_started(agent_id, opts)

    @impl true
    def stop_existing(agent_id, opts), do: SalixAgent.Fleet.stop_existing(agent_id, opts)

    @impl true
    def run_on_owner(_agent_id, {module, function, args}, _timeout),
      do: apply(module, function, args)
  end
end
