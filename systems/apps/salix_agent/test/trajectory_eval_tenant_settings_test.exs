defmodule SalixAgent.TrajectoryEvalTenantSettingsTest do
  @moduledoc """
  The tenant-settings seam keeps three cases distinct so a paid gate can fail
  closed: `:no_impl` (no per-tenant seam — global-only), `{:ok, overrides}`
  (answered; may be an empty "unset" map), and `{:error, _}` (configured but
  unreadable, or the tenant can't be resolved). An adapter raise/exit/bad
  return must surface as `{:error, _}`, never a silent empty map.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.TrajectoryEval.TenantSettings

  defmodule OkStore do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get("tenant-on"), do: {:ok, %{"judge_enabled" => true}}
    def get("tenant-empty"), do: {:ok, %{}}
    def get(_), do: {:error, :not_found}
  end

  defmodule BoomStore do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get(_tenant), do: raise("control plane down")
  end

  defmodule BadReturnStore do
    @behaviour SalixAgent.TrajectoryEval.TenantSettings
    @impl true
    def get(_tenant), do: :surprise
  end

  setup do
    prev = Application.get_env(:salix_agent, :trajectory_eval_tenant_mod)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:salix_agent, :trajectory_eval_tenant_mod)
  defp restore(v), do: Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, v)

  test "no configured impl resolves to :no_impl (global-only, not an outage)" do
    Application.delete_env(:salix_agent, :trajectory_eval_tenant_mod)
    assert TenantSettings.resolve("tenant-on") == :no_impl
    # Even an unresolvable tenant is :no_impl — there is no per-tenant opt-out.
    assert TenantSettings.resolve(nil) == :no_impl
  end

  test "configured impl returns overrides, empty map for an unset tenant" do
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, OkStore)
    assert TenantSettings.resolve("tenant-on") == {:ok, %{"judge_enabled" => true}}
    assert TenantSettings.resolve("tenant-empty") == {:ok, %{}}
  end

  test "an adapter error is surfaced (not swallowed to unset)" do
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, OkStore)
    assert {:error, :not_found} = TenantSettings.resolve("tenant-unknown")
  end

  test "a raising adapter surfaces as an error" do
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, BoomStore)
    assert {:error, _} = TenantSettings.resolve("tenant-on")
  end

  test "an unexpected adapter return surfaces as an error" do
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, BadReturnStore)
    assert {:error, {:unexpected_return, :surprise}} = TenantSettings.resolve("tenant-on")
  end

  test "a configured seam with an unresolvable tenant is unavailable, not unset" do
    Application.put_env(:salix_agent, :trajectory_eval_tenant_mod, OkStore)
    assert {:error, :tenant_unresolved} = TenantSettings.resolve(nil)
    assert {:error, :tenant_unresolved} = TenantSettings.resolve("")
  end
end
