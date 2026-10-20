defmodule SalixStore.AgentVMMInstallMaterialTest do
  use SystemsClock.Case, async: false

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

    previous = SystemsRuntime.get_env(:salix_store, :agent_vmm_install_material)
    catalog = AgentVMMInstallMaterialFixtures.catalog()
    SystemsRuntime.put_env(:salix_store, :agent_vmm_install_material, catalog)

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

  defp put_or_delete(nil),
    do: SystemsRuntime.delete_env(:salix_store, :agent_vmm_install_material)

  defp put_or_delete(value),
    do: SystemsRuntime.put_env(:salix_store, :agent_vmm_install_material, value)
end
