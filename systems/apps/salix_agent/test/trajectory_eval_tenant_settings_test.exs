defmodule SalixAgent.TrajectoryEvalTenantSettingsTest do
  @moduledoc """
  The tenant-settings seam keeps three cases distinct so a paid gate can fail
  closed: `:no_impl` (no per-tenant seam — global-only), `{:ok, overrides}`
  (answered; may be an empty "unset" map), and `{:error, _}` (configured but
  unreadable, or the tenant can't be resolved). An adapter raise/exit/bad
  return must surface as `{:error, _}`, never a silent empty map.
  """
  use SystemsClock.Case, async: false

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
    prev = SystemsRuntime.get_env(:salix_agent, :trajectory_eval_tenant_mod)
    on_exit(fn -> restore(prev) end)
    :ok
  end

  defp restore(nil), do: SystemsRuntime.delete_env(:salix_agent, :trajectory_eval_tenant_mod)
  defp restore(v), do: SystemsRuntime.put_env(:salix_agent, :trajectory_eval_tenant_mod, v)

  test "configured impl returns overrides, empty map for an unset tenant" do
    SystemsRuntime.put_env(:salix_agent, :trajectory_eval_tenant_mod, OkStore)
    assert TenantSettings.resolve("tenant-on") == {:ok, %{"judge_enabled" => true}}
    assert TenantSettings.resolve("tenant-empty") == {:ok, %{}}
  end
end
