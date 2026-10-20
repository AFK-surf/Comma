defmodule SalixWeb.ControlTest do
  use SystemsClock.Case, async: false

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev_store)
    end)

    {:ok, tenant} = Salix.Control.Tenants.create(%{"name" => "Default"})
    Process.put(:test_tenant_id, tenant["tenant_id"])

    :ok
  end

  defp tenant_id, do: Process.get(:test_tenant_id) || raise("test tenant is not configured")

  test "group deletion retires provider routes before removing the group" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Retired"}, tenant_id())
    group_id = group["group_id"]
    connect_id = SalixStore.Ids.new_connect_id()
    app_id = "deleted-group-feishu"
    key = SalixStore.Keys.ctl_im_connect(group_id, connect_id)

    assert {:ok, _} =
             SalixStore.CasRecord.create(key, %{
               "tenant_id" => tenant_id(),
               "group_id" => group_id,
               "connect_id" => connect_id,
               "provider" => "feishu",
               "app_id" => app_id
             })

    assert :ok =
             SalixIM.ProviderIdentity.reserve_provider(
               "feishu",
               app_id,
               tenant_id(),
               group_id,
               connect_id
             )

    identity_key = SalixStore.Keys.ctl_im_provider_identity("feishu", app_id)
    SalixStore.S3.Fake.set_fault({:fail, 503, :delete, identity_key})
    assert {:error, _} = Salix.Control.Groups.delete(group_id, tenant_id())
    assert {:ok, _} = Salix.Control.Groups.get(group_id, tenant_id())

    assert :ok = Salix.Control.Groups.delete(group_id, tenant_id())
    assert {:error, :not_found} = Salix.Control.Groups.get(group_id, tenant_id())
    assert {:ok, %{"deleted_at" => deleted_at}} = SalixStore.CasRecord.get(key)
    assert is_integer(deleted_at)
    assert {:error, :not_found} = SalixStore.CasRecord.get(identity_key)
    assert :ok = SalixIM.ProviderIdentity.ensure_available("feishu", app_id)
  end

  test "group deletion removes the group's saved device secrets" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Lamps"}, tenant_id())
    group_id = group["group_id"]

    assert {:ok, _, :created} =
             SalixAgent.DeviceSecrets.save(group_id, %{
               "kind" => "miio_token",
               "name" => "bedside-lamp",
               "value" => "00112233445566778899aabbccddeeff"
             })

    assert :ok = Salix.Control.Groups.delete(group_id, tenant_id())

    assert {:error, :not_found} =
             SalixStore.CasRecord.get(SalixStore.Keys.ctl_group_device_secrets(group_id))
  end

  test "a group's information-flow settings merge, so one write never drops another" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Flow"}, tenant_id())
    group_id = group["group_id"]

    {:ok, _} =
      Salix.Control.Groups.update(group_id, %{"ifc" => %{"mode" => "audit"}}, tenant_id())

    {:ok, localized} =
      Salix.Control.Groups.update(group_id, %{"ifc" => %{"language" => "en"}}, tenant_id())

    assert localized["ifc"] == %{"mode" => "audit", "language" => "en"}

    # The mode form does not show the language, so changing the mode must not
    # silently reset it — and vice versa.
    {:ok, enforced} =
      Salix.Control.Groups.update(group_id, %{"ifc" => %{"mode" => "enforce"}}, tenant_id())

    assert enforced["ifc"] == %{"mode" => "enforce", "language" => "en"}

    # A language nobody composes sentences in would read as the default and
    # silently do nothing, so it is refused here instead.
    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(group_id, %{"ifc" => %{"language" => "de"}}, tenant_id())

    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(group_id, %{"ifc" => %{}}, tenant_id())

    {:ok, current} = Salix.Control.Groups.get(group_id, tenant_id())
    assert current["ifc"] == %{"mode" => "enforce", "language" => "en"}
  end

  test "Worker memory consultation is disabled by default and accepts only booleans" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Memory policy"}, tenant_id())
    assert group["memory_ask_worker_enabled"] == false

    {:ok, router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Memory Router", "role" => "router"},
        tenant_id()
      )

    assert {:ok, disabled_config} =
             SalixAgent.RoundConfig.build_runtime_session_config(
               router["agent_id"],
               "router",
               %{}
             )

    refute "memory.ask_worker" in Enum.map(disabled_config.tool_disclosure["tools"], & &1["name"])

    assert {:ok, enabled} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"memory_ask_worker_enabled" => true},
               tenant_id()
             )

    assert enabled["memory_ask_worker_enabled"] == true

    assert {:ok, enabled_config} =
             SalixAgent.RoundConfig.build_runtime_session_config(
               router["agent_id"],
               "router",
               %{}
             )

    assert "memory.ask_worker" in Enum.map(enabled_config.tool_disclosure["tools"], & &1["name"])

    assert {:error, {:bad_request, "memory_ask_worker_enabled must be a boolean"}} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"memory_ask_worker_enabled" => "true"},
               tenant_id()
             )
  end

  test "the Condensed Workspace is opt-in per Group and reaches the round configuration" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Workspace facts"}, tenant_id())
    assert group["condensed_workspace_enabled"] == false

    {:ok, worker} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Facts Worker", "role" => "worker"},
        tenant_id()
      )

    tools = fn ->
      {:ok, config} =
        SalixAgent.RoundConfig.build_runtime_session_config(worker["agent_id"], "worker", %{})

      {config.condensed_workspace_enabled,
       Enum.map(config.tool_disclosure["tools"], & &1["name"])}
    end

    assert {false, names} = tools.()
    refute "condensed_workspace.update" in names

    assert {:ok, %{"condensed_workspace_enabled" => true}} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"condensed_workspace_enabled" => true},
               tenant_id()
             )

    assert {true, names} = tools.()
    assert "condensed_workspace.update" in names

    assert {:error, {:bad_request, "condensed_workspace_enabled must be a boolean"}} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"condensed_workspace_enabled" => "yes"},
               tenant_id()
             )
  end

  test "Slack channel cutover preparation freezes router authority updates" do
    SalixStore.Repo.query!("""
    DELETE FROM salix_cutover_markers
    WHERE name IN ('slack_triage_channels_v1', 'slack_triage_channels_v1_preparing')
    """)

    on_exit(fn ->
      SalixStore.Repo.query!(
        "DELETE FROM salix_cutover_markers WHERE name = 'slack_triage_channels_v1_preparing'"
      )

      SalixStore.Repo.query!("""
      INSERT INTO salix_cutover_markers (name, completed_at, evidence)
      VALUES ('slack_triage_channels_v1', now(), '{"mode":"test-baseline"}'::jsonb)
      ON CONFLICT (name) DO NOTHING
      """)
    end)

    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Router freeze"}, tenant_id())

    {:ok, first_router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "First", "role" => "router"},
        tenant_id()
      )

    {:ok, second_router} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Second", "role" => "router"},
        tenant_id()
      )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"router_agent_id" => first_router["agent_id"]},
               tenant_id()
             )

    assert {:ok, "router-freeze"} =
             SalixStore.SlackTriageChannelCutover.begin_preparing(%{
               "schema_version" => 1,
               "preparation_id" => "router-freeze",
               "all_readers_current" => true,
               "old_control_writers_retired" => true
             })

    assert {:error, :slack_triage_channel_cutover_pending} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"router_agent_id" => second_router["agent_id"]},
               tenant_id()
             )

    # Even an apparently idempotent router write must take the shared lock.
    # Its caller may have read this value before another writer changed it, so
    # classifying it as a no-op outside the lock reopens a stale CAS retry after
    # preparation has frozen authority.
    assert {:error, :slack_triage_channel_cutover_pending} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"router_agent_id" => first_router["agent_id"]},
               tenant_id()
             )

    assert {:ok, unchanged} = Salix.Control.Groups.get(group["group_id"], tenant_id())
    assert unchanged["router_agent_id"] == first_router["agent_id"]

    assert {:ok, renamed} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"name" => "Still writable"},
               tenant_id()
             )

    assert renamed["name"] == "Still writable"
  end

  test "list scopes persisted agent control records by tenant and group" do
    {:ok, first_group} = Salix.Control.Groups.create(%{"name" => "First"}, tenant_id())
    {:ok, second_group} = Salix.Control.Groups.create(%{"name" => "Second"}, tenant_id())

    {:ok, mine} =
      SalixAgent.Control.create(
        %{"group_id" => first_group["group_id"], "name" => "Mine"},
        tenant_id()
      )

    {:ok, _other_group} =
      SalixAgent.Control.create(
        %{"group_id" => second_group["group_id"], "name" => "Elsewhere"},
        tenant_id()
      )

    {:ok, other_tenant} = Salix.Control.Tenants.create(%{"name" => "Other"})
    other_tenant_id = other_tenant["tenant_id"]
    {:ok, foreign_group} = Salix.Control.Groups.create(%{"name" => "Foreign"}, other_tenant_id)

    {:ok, _foreign} =
      SalixAgent.Control.create(
        %{"group_id" => foreign_group["group_id"], "name" => "Foreign"},
        other_tenant_id
      )

    assert [listed] = SalixAgent.Control.list(tenant_id(), group_id: first_group["group_id"])
    assert listed["agent_id"] == mine["agent_id"]
    assert listed["group_id"] == first_group["group_id"]
    assert listed["status"] == "idle"
    refute Map.has_key?(listed, "activity_status")

    # Tenant scoping holds even when the caller names another tenant's group.
    assert [] = SalixAgent.Control.list(other_tenant_id, group_id: first_group["group_id"])
    assert [] = SalixAgent.Control.list(tenant_id(), group_id: foreign_group["group_id"])
  end
end
