defmodule SalixAgent.CloudVM do
  @moduledoc """
  Agent-facing Cloud VM capability port.

  VM lifecycle is group/env/web infrastructure. Whether the Group's Agents may
  use its Cloud VM is the Group's switch (`cloud_vm_enabled` on the Group
  record), not a setting of any Agent: `allowed?/1` reads it.
  """

  alias SalixStore.{CasRecord, Keys}

  @doc "Whether the Group's Cloud VM switch may be turned on, wherever the Group's VM goes."
  @callback validate_group_enabled(tenant_id :: String.t(), group_id :: String.t()) ::
              :ok | {:error, term()}
  @callback ensure_provisioning(agent :: map()) :: {:ok, map()} | {:error, term()}
  @callback mark_agent_settled(agent_id :: String.t()) :: :ok
  @doc """
  Starts the agent's Group Cloud VM and follows it until its station is
  connected, within `budget_ms`: the states it went through either way. The
  agent starts it for itself, or names a live Worker `worker_id` of its Group;
  the Group's Cloud VM switch must be on (`allowed?/1`).
  """
  @callback start(
              agent_id :: String.t(),
              worker_id :: String.t() | nil,
              budget_ms :: non_neg_integer()
            ) ::
              {:ok, map()} | {:error, term(), [map()]}

  def validate_group_enabled(tenant_id, group_id),
    do: impl().validate_group_enabled(tenant_id, group_id)

  def ensure_provisioning(agent),
    do: observe(:provision, agent, fn -> impl().ensure_provisioning(agent) end)

  def mark_agent_settled(agent_id), do: impl().mark_agent_settled(agent_id)
  def start(agent_id, worker_id, budget_ms), do: impl().start(agent_id, worker_id, budget_ms)

  @doc """
  Whether a live Agent may start its Group's Cloud VM or place a Task there:
  the Group's Cloud VM switch (`cloud_vm_enabled` on the Group record) is on.
  """
  def allowed?(%{"group_id" => group_id} = agent) when is_binary(group_id) do
    not Map.has_key?(agent, "archived_at") and agent["permanent_archive"] != true and
      group_enabled?(group_id)
  end

  def allowed?(_agent), do: false

  @doc "Whether the Group's Cloud VM switch is on."
  def group_enabled?(group_id) when is_binary(group_id),
    do: match?({:ok, %{"cloud_vm_enabled" => true}}, CasRecord.get(Keys.ctl_group(group_id)))

  # Telemetry labels name the provider of the Group's Cloud VM: the one its
  # Workload record has, once the provisioning answers it.
  defp observe(operation, agent, fun) do
    provider = group_provider(agent)
    billing = agent["billing_context"] || agent[:billing_context] || %{}
    surface = billing["surface"] || billing[:surface] || "system"

    SystemsObservability.Context.with_surface(surface, fn ->
      SystemsObservability.Trace.with_span(
        :salix_vm,
        %{
          component: "salix_agent",
          surface: surface,
          provider: provider,
          operation: operation
        },
        fn -> observe_result(operation, surface, provider, fun) end,
        kind: :client
      )
    end)
  end

  defp observe_result(operation, surface, provider, fun) do
    started = SystemsClock.monotonic_time()
    result = fun.()

    provider =
      case result do
        {:ok, %{"provider" => provider}} when is_binary(provider) -> provider
        _ -> provider
      end

    Salix.Telemetry.emit_vm_operation(
      %{
        surface: surface,
        provider: provider,
        operation: operation,
        outcome: if(match?({:error, _}, result), do: :error, else: :ok)
      },
      SystemsClock.monotonic_time() - started
    )

    result
  end

  defp group_provider(agent) do
    with group_id when is_binary(group_id) <- agent["group_id"] || agent[:group_id],
         {:ok, %{"provider" => provider}} when is_binary(provider) <-
           SalixStore.Compute.group_workload(group_id) do
      provider
    else
      _ -> "other"
    end
  end

  defp impl, do: SystemsRuntime.get_env(:salix_agent, :cloud_vm_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixAgent.CloudVM

    @impl true
    def validate_group_enabled(_tenant_id, _group_id),
      do: {:error, {:bad_request, "vm provider is not configured"}}

    @impl true
    def ensure_provisioning(_agent), do: {:error, :not_configured}

    @impl true
    def mark_agent_settled(_agent_id), do: :ok

    @impl true
    def start(_agent_id, _worker_id, _budget_ms), do: {:error, :not_configured, []}
  end
end
