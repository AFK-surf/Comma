defmodule SalixStore.AgentVMMInstallMaterialTest do
  use ExUnit.Case, async: false

  alias SalixStore.{AgentVMMInstallMaterial, Compute, Repo}
  alias SalixStore.AgentVMMInstallMaterialFixtures

  setup do
    Repo.query!("TRUNCATE compute_environments, compute_pools CASCADE")
    {:ok, pool} = Compute.ensure_managed_default_pool("tenant", "agent_vmm")

    {:ok, _environment} =
      Compute.ensure_environment(%{
        id: "environment",
        tenant_id: "tenant",
        owner_type: "project",
        owner_id: "project",
        pool_id: pool.id
      })

    previous = Application.get_env(:salix_store, :agent_vmm_install_material)
    catalog = AgentVMMInstallMaterialFixtures.catalog()
    Application.put_env(:salix_store, :agent_vmm_install_material, catalog)

    on_exit(fn -> put_or_delete(previous) end)
    {:ok, catalog: catalog}
  end

  test "issues bounded remote enrollment without standalone appliance material" do
    assert {:ok, first} = AgentVMMInstallMaterial.issue(operation(), enrollment())

    assert first.operation_id == "operation"
    assert first.registration_id == "registration"
    refute Map.has_key?(first, :appliance)
    assert first.remote_enrollment.gateway_endpoint == "vmm.example.test:7443"
    assert first.remote_enrollment.policy_revision == 1
    refute Map.has_key?(first.remote_enrollment.pool_policy, "max_environments")
    assert byte_size(Base.url_decode64!(first.scope_digest, padding: false)) == 32
  end

  test "requires a DNS gateway with explicit port and a certificate-only trust bundle", ctx do
    invalid_endpoint =
      put_in(ctx.catalog, ["remote_enrollment", "gateway_endpoint"], "34.1.2.3:7443")

    Application.put_env(:salix_store, :agent_vmm_install_material, invalid_endpoint)
    assert {:error, :install_material_unavailable} = issue()

    invalid_bundle =
      put_in(ctx.catalog, ["remote_enrollment", "trust_bundle"], Base.encode64("not a CA"))

    Application.put_env(:salix_store, :agent_vmm_install_material, invalid_bundle)
    assert {:error, :install_material_unavailable} = issue()
  end

  test "fails closed when the Pool admission policy is malformed" do
    Repo.query!("""
    UPDATE compute_pools
    SET capacity = jsonb_set(
      capacity,
      '{agent_vmm_remote_policy,per_environment_limits,pids}',
      '0'::jsonb
    )
    WHERE tenant_id = 'tenant'
    """)

    assert {:error, :install_material_unavailable} = issue()
  end

  defp issue, do: AgentVMMInstallMaterial.issue(operation(), enrollment())

  defp operation do
    %{
      id: "operation",
      tenant_id: "tenant",
      group_id: "group",
      scope_key: "project",
      environment_id: "environment"
    }
  end

  defp enrollment do
    %{
      registration_id: "registration",
      enrollment_token: Base.encode64(:binary.copy(<<7>>, 32))
    }
  end

  defp put_or_delete(nil), do: Application.delete_env(:salix_store, :agent_vmm_install_material)

  defp put_or_delete(value),
    do: Application.put_env(:salix_store, :agent_vmm_install_material, value)
end
