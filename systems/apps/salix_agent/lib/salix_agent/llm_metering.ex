defmodule SalixAgent.LLMMetering do
  @moduledoc """
  Runtime LLM metering behaviour.

  Production can configure `:salix_agent, :llm_metering_mod`; tests can install a
  process fake. The default implementation is no-op so runtime behaviour is
  unchanged until BillingCore is wired in.
  """

  @callback before_llm_call(map()) :: {:ok, map()} | :ok | {:error, term()}
  @callback after_llm_call(map()) :: {:ok, map()} | :ok | {:error, term()}

  def before_llm_call(fact), do: safe_call(:before_llm_call, fact)

  def capture_decision(fact, {:ok, %{billing_exemption: "free_router_model"}}),
    do: Map.put(fact, :billing_exemption, "free_router_model")

  def capture_decision(fact, _decision), do: Map.delete(fact, :billing_exemption)

  @doc """
  The fee check before a platform key serves a platform Router's request in
  `deduct` billing (`SalixAgent.PlatformRouter`): the request's meter fact,
  platform-funded and settled by `deduct`. Answers `:ok` or
  `{:error, decision}` for `SalixAgent.AccountPool`.
  """
  def platform_admit(fact) when is_map(fact) do
    fact =
      Map.merge(fact, %{
        credential_scope: "platform",
        tenant_account_pool: false,
        settlement: "deduct",
        source_key: "#{fact[:request_id] || fact[:source_key]}:platform"
      })

    case before_llm_call(fact) do
      :ok -> :ok
      {:ok, _decision} -> :ok
      {:error, {:billing_unavailable, decision}} -> {:error, decision}
      {:error, _reason} -> {:error, %{reason: "fee_control_error"}}
    end
  end

  @doc """
  The meter fact of a dispatch, following what served it: a platform key on
  a platform Router's route (response meta `"funding"` scope `platform`) is
  platform-funded and settled by the Router's billing (`record` or `deduct`).
  """
  def served_by(fact, %{"funding" => %{"scope" => "platform", "billing" => billing}})
      when billing in ["record", "deduct"],
      do:
        fact
        |> Map.delete(:billing_exemption)
        |> Map.merge(%{
          credential_scope: "platform",
          tenant_account_pool: false,
          settlement: billing
        })

  def served_by(fact, _meta), do: fact

  def after_llm_call(fact) do
    SystemsObservability.Trace.with_span(
      :salix_round_metering,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> safe_call(:after_llm_call, fact) end
    )
  end

  defp impl, do: SystemsRuntime.get_env(:salix_agent, :llm_metering_mod, __MODULE__.Noop)

  defp safe_call(function, fact) do
    apply(impl(), function, [fact])
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defmodule Noop do
    @moduledoc false
    @behaviour SalixAgent.LLMMetering

    @impl true
    def before_llm_call(_fact), do: :ok

    @impl true
    def after_llm_call(_fact), do: :ok
  end
end
