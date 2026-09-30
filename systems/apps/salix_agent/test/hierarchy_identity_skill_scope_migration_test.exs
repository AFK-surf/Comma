defmodule SalixAgent.HierarchyIdentitySkillScopeMigrationTest do
  use ExUnit.Case, async: false

  alias SalixAgent.SkillStore
  alias SalixStore.{Codec, HierarchyIdMigration, Ids, Keys, S3}
  alias SalixStore.Migrations.HierarchyIdentity

  setup do
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    :ok
  end

  test "migration rewrites skill catalog payload scopes to their canonical owner keys" do
    legacy_tenant_id = "org_legacy"
    legacy_group_id = "proj_legacy"
    legacy_agent_id = "agent_legacy"
    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    agent_id = Ids.new_agent_id(group_id)

    identity = %{
      tenants: %{legacy_tenant_id => tenant_id},
      groups: %{legacy_group_id => group_id},
      agents: %{legacy_agent_id => agent_id}
    }

    fixtures = [
      {:tenant, legacy_tenant_id, tenant_id, [:source]},
      # Interrupted after destination write but before source delete.
      {:group, legacy_group_id, group_id, [:source, :target]},
      # Interrupted after source delete but before the migration completed.
      {:agent, legacy_agent_id, agent_id, [:target]}
    ]

    Enum.each(fixtures, fn {layer, source, target, locations} ->
      state = %SkillStore.State{scope: %{"layer" => Atom.to_string(layer), "id" => source}}

      Enum.each(locations, fn location ->
        owner_id = if location == :source, do: source, else: target

        assert {:ok, _} =
                 S3.put(scope_key(layer, owner_id), Codec.encode_snapshot(state),
                   if_none_match: "*"
                 )
      end)
    end)

    assert {:ok, _stats} = HierarchyIdentity.run(identity_seed: identity)
    assert {:ok, true} = HierarchyIdMigration.phase_complete?(:s3, identity)

    Enum.each(fixtures, fn {layer, source, target, _locations} ->
      assert {:error, :not_found} = S3.get(scope_key(layer, source))
      assert {:ok, %{body: body}} = S3.get(scope_key(layer, target))

      assert %SkillStore.State{
               scope: %{"layer" => expected_layer, "id" => ^target}
             } = Codec.decode_snapshot(body)

      assert expected_layer == Atom.to_string(layer)
    end)
  end

  defp scope_key(:tenant, id), do: Keys.ctl_skill_scope_tenant(id)
  defp scope_key(:group, id), do: Keys.ctl_skill_scope_group(id)
  defp scope_key(:agent, id), do: Keys.ctl_skill_scope_agent(id)
end
