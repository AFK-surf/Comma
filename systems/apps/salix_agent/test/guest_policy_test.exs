defmodule SalixAgent.GuestPolicyTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{Control, GuestPolicy, ToolDisclosure}
  alias SalixStore.{Ids, TenantConfigs, TenantProfiles}

  setup do
    previous_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      TenantConfigs.delete(tenant_id, "product_profile")

      if previous_store,
        do: Application.put_env(:salix_store, :s3_backend, previous_store),
        else: Application.delete_env(:salix_store, :s3_backend)
    end)

    %{tenant_id: tenant_id, group_id: Ids.new_group_id(tenant_id)}
  end

  test "a guest Router sees and calls only allowlisted server-side tools" do
    guest = %{guest_policy: :restricted}

    assert GuestPolicy.allowed_tool?(guest, "web.search")
    assert GuestPolicy.allowed_tool?(guest, "im_api.internal.send_message")

    for denied <-
          ~w(agent.create_worker env.exec env.ensure_runtime plugin.definition_create plugin.enable mcp_manager.definition_create im_api.internal.task.create composio.connect ssh.exec) do
      refute GuestPolicy.allowed_tool?(guest, denied), denied
    end

    assert GuestPolicy.allowed_tool?(%{}, "agent.create_worker")
    refute GuestPolicy.allowed_tool?(%{guest_policy: :bogus}, "web.search")

    disclosed = %{tool_disclosure: %{"guest_policy" => "restricted"}}
    refute GuestPolicy.allowed_tool?(disclosed, "agent.create_worker")

    names =
      ToolDisclosure.materialize_static("router", :internal, guest)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "web.search" in names
    assert Enum.all?(names, &GuestPolicy.allowed_tool?(guest, &1))

    ordinary =
      ToolDisclosure.materialize_static("router", :internal, %{})
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert Enum.any?(ordinary, &String.starts_with?(&1, "agent."))
  end

  test "a router-only Tenant admits only guest Routers without a VM", ctx do
    guest_purpose = TenantProfiles.guest_router_purpose()

    # The guest purpose requires the router-only profile.
    assert {:error, {:bad_request, _}} = create(ctx, "router", guest_purpose)

    {:ok, _profile} = TenantProfiles.put_router_only(ctx.tenant_id, 16)
    assert TenantProfiles.router_only?(ctx.tenant_id)
    assert TenantProfiles.dependency_limits()[ctx.tenant_id] == 16

    assert {:error, {:bad_request, _}} = create(ctx, "worker", guest_purpose)
    assert {:error, {:bad_request, _}} = create(ctx, "router", "comma_workspace_router")

    assert {:error, {:bad_request, _}} =
             create(ctx, "router", guest_purpose, %{"enabled" => true, "provider" => "cloudflare"})

    # Comma.GuestModeTest provisions an admitted guest Router end to end.
  end

  defp create(ctx, role, purpose, vm \\ %{"enabled" => false}) do
    Control.create_preallocated(
      %{
        "group_id" => ctx.group_id,
        "role" => role,
        "purpose" => purpose,
        "name" => "Agent",
        "vm" => vm
      },
      ctx.tenant_id,
      Ids.new_agent_id(ctx.group_id)
    )
  end
end
