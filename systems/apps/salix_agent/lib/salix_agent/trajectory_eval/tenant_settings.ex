defmodule SalixAgent.TrajectoryEval.TenantSettings do
  @moduledoc """
  Read seam for per-tenant trajectory-eval overrides (currently the LLM judge
  on/off switch).

  The judge spends the tenant's own LLM credit, so whether it runs is a
  per-tenant decision made in the dashboard, not a deployment-wide constant.
  The setting lives in the control plane (`Salix.Control.Tenants` config,
  section `"trajectory_eval"`); this seam lets the `salix_agent` runtime read
  it without depending on `salix_web` — same pattern as `:composio_store_mod`
  and `:oauth_store_mod`, wired via

      config :salix_agent,
        trajectory_eval_tenant_mod: Salix.Bindings.AgentTrajectoryEvalSettings

  ## Unset vs unavailable (fail-closed contract)

  `resolve/1` deliberately keeps three cases distinct, because the caller gates
  *paid* work on the result and must not treat an outage as an opt-in:

    * `:no_impl` — no per-tenant seam configured. There is no per-tenant
      opt-out to honor, so the caller keeps its global-only behavior.
    * `{:ok, overrides}` — the seam answered. `overrides` may be `%{}`, meaning
      the tenant simply hasn't set anything → the caller uses the global default.
    * `{:error, reason}` — the seam is configured but the lookup failed, or the
      tenant could not be resolved. The caller cannot tell an explicit opt-out
      from a transient control-plane failure, so it must FAIL CLOSED and skip
      the paid work (while still doing the free, non-paid parts).
  """

  @type resolution :: {:ok, map()} | :no_impl | {:error, term()}

  @doc """
  The tenant's trajectory-eval override map (string keys, e.g.
  `%{"judge_enabled" => true}`), or `{:error, term()}`.
  """
  @callback get(tenant_id :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "The configured implementation module, or nil."
  @spec impl() :: module() | nil
  def impl, do: Application.get_env(:salix_agent, :trajectory_eval_tenant_mod)

  @doc """
  Resolve a tenant's overrides as a three-way result (see the moduledoc). Never
  raises: an adapter raise/exit is surfaced as `{:error, _}`, not swallowed to
  an empty map, so a paid gate can fail closed rather than fail open.
  """
  @spec resolve(String.t() | nil) :: resolution()
  def resolve(tenant_id) do
    case impl() do
      nil -> :no_impl
      mod -> resolve_with(mod, tenant_id)
    end
  end

  # A configured seam with no resolvable tenant is an *unavailable* lookup, not
  # an "unset" one: we know a per-tenant choice may exist but cannot read it.
  defp resolve_with(_mod, tenant_id) when not is_binary(tenant_id) or tenant_id == "",
    do: {:error, :tenant_unresolved}

  defp resolve_with(mod, tenant_id) do
    case mod.get(tenant_id) do
      {:ok, %{} = overrides} -> {:ok, overrides}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_return, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
