defmodule SalixAgent.CloudVM do
  @moduledoc """
  Agent-facing Cloud VM capability port.

  VM lifecycle is group/env/web infrastructure. Agent control only validates
  whether an agent may enable a VM, triggers provisioning, and exposes the VM
  projection on agent responses.
  """

  @callback default_provider(tenant_id :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback validate_enabled(tenant_id :: String.t(), provider :: String.t()) ::
              :ok | {:error, term()}
  @callback validate_group_provider(group_id :: String.t(), provider :: String.t()) ::
              :ok | {:error, term()}
  @callback ensure_provisioning(agent :: map()) :: {:ok, map()} | {:error, term()}
  @callback ensure_runtime(agent :: map(), args :: map()) :: {:ok, map()} | {:error, term()}
  @callback switch_provider(agent :: map(), provider :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback attach(agent :: map()) :: map()
  @callback mark_agent_settled(agent_id :: String.t()) :: :ok

  def default_provider(tenant_id), do: impl().default_provider(tenant_id)
  def validate_enabled(tenant_id, provider), do: impl().validate_enabled(tenant_id, provider)

  def validate_group_provider(group_id, provider),
    do: impl().validate_group_provider(group_id, provider)

  def ensure_provisioning(agent),
    do: observe(:provision, agent, fn -> impl().ensure_provisioning(agent) end)

  def ensure_runtime(agent, args),
    do: observe(:provision, agent, fn -> impl().ensure_runtime(agent, args) end)

  def switch_provider(agent, provider),
    do: observe(:provider_request, agent, fn -> impl().switch_provider(agent, provider) end)

  def attach(agent), do: impl().attach(agent)
  def mark_agent_settled(agent_id), do: impl().mark_agent_settled(agent_id)

  defp observe(operation, agent, fun) do
    vm = agent["vm"] || agent[:vm] || %{}
    billing = agent["billing_context"] || agent[:billing_context] || %{}
    surface = billing["surface"] || billing[:surface] || "system"

    SystemsObservability.Context.with_surface(surface, fn ->
      SystemsObservability.Trace.with_span(
        :salix_vm,
        %{
          component: "salix_agent",
          surface: surface,
          provider: vm["provider"] || vm[:provider] || "other",
          operation: operation
        },
        fn -> observe_result(operation, agent, fun) end,
        kind: :client
      )
    end)
  end

  defp observe_result(operation, agent, fun) do
    started = System.monotonic_time()
    result = fun.()
    vm = agent["vm"] || agent[:vm] || %{}
    billing = agent["billing_context"] || agent[:billing_context] || %{}

    Salix.Telemetry.emit_vm_operation(
      %{
        surface: billing["surface"] || billing[:surface] || "system",
        provider: vm["provider"] || vm[:provider] || "other",
        operation: operation,
        outcome: if(match?({:error, _}, result), do: :error, else: :ok)
      },
      System.monotonic_time() - started
    )

    result
  end

  defp impl, do: Application.get_env(:salix_agent, :cloud_vm_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixAgent.CloudVM

    @impl true
    def default_provider(_tenant_id), do: {:ok, "cloudflare"}

    @impl true
    def validate_enabled(_tenant_id, _provider),
      do: {:error, {:bad_request, "vm provider is not configured"}}

    @impl true
    def validate_group_provider(_group_id, _provider), do: :ok

    @impl true
    def ensure_provisioning(_agent), do: {:error, :not_configured}

    @impl true
    def ensure_runtime(_agent, _args), do: {:error, :not_configured}

    @impl true
    def switch_provider(_agent, _provider), do: {:error, :not_configured}

    @impl true
    def attach(agent), do: agent

    @impl true
    def mark_agent_settled(_agent_id), do: :ok
  end
end
