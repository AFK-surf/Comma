defmodule SalixWeb.ControlTest do
  use ExUnit.Case, async: false

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev_store = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_store)
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

  test "create_agent generates distinct group-bound canonical ids" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Agents"}, tenant_id())

    {:ok, first} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "First"},
        tenant_id()
      )

    {:ok, second} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Second"},
        tenant_id()
      )

    assert first["agent_id"] != second["agent_id"]
    assert SalixStore.Ids.valid_agent_id_for_group?(first["agent_id"], group["group_id"])
    assert SalixStore.Ids.valid_agent_id_for_group?(second["agent_id"], group["group_id"])
  end

  test "a group's information-flow mode is writable, validated, and off by default" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Flow"}, tenant_id())

    # Off is the absence of a setting, not a stored "off": nothing changes for
    # a workspace that never opts in.
    refute Map.has_key?(group, "ifc")

    {:ok, audited} =
      Salix.Control.Groups.update(
        group["group_id"],
        %{"ifc" => %{"mode" => "audit"}},
        tenant_id()
      )

    assert audited["ifc"] == %{"mode" => "audit"}

    {:ok, enforced} =
      Salix.Control.Groups.update(
        group["group_id"],
        %{"ifc" => %{"mode" => "enforce"}},
        tenant_id()
      )

    assert enforced["ifc"] == %{"mode" => "enforce"}

    # A mode that does not exist would read as `off` at the seam and silently
    # do nothing, so it is refused here instead.
    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"ifc" => %{"mode" => "strict"}},
               tenant_id()
             )

    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"ifc" => %{"mode" => "audit", "sealed" => true}},
               tenant_id()
             )

    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(group["group_id"], %{"ifc" => "enforce"}, tenant_id())

    # The refused writes changed nothing.
    {:ok, current} = Salix.Control.Groups.get(group["group_id"], tenant_id())
    assert current["ifc"] == %{"mode" => "enforce"}
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

  test "group owner_emails are normalized on create and update and reject bad shapes" do
    {:ok, group} =
      Salix.Control.Groups.create(
        %{"name" => "Owners", "owner_emails" => [" a@x.com ", "a@x.com", ""]},
        tenant_id()
      )

    assert group["owner_emails"] == ["a@x.com"]

    {:ok, updated} =
      Salix.Control.Groups.update(
        group["group_id"],
        %{"owner_emails" => ["b@y.com", "c@z.com"]},
        tenant_id()
      )

    assert updated["owner_emails"] == ["b@y.com", "c@z.com"]

    {:ok, cleared} =
      Salix.Control.Groups.update(group["group_id"], %{"owner_emails" => []}, tenant_id())

    assert cleared["owner_emails"] == []

    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"owner_emails" => "a@x.com"},
               tenant_id()
             )

    assert {:error, {:bad_request, _}} =
             Salix.Control.Groups.create(%{"owner_emails" => ["not-an-email"]}, tenant_id())

    # A group created without owner_emails simply has none.
    {:ok, plain} = Salix.Control.Groups.create(%{"name" => "Plain"}, tenant_id())
    refute Map.has_key?(plain, "owner_emails")
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

  test "VFS control commands require an explicit per-group boolean" do
    assert {:ok, group} = Salix.Control.Groups.create(%{"name" => "VFS"}, tenant_id())
    assert group["control_command_vfs_enabled"] == false
    assert {:ok, other} = Salix.Control.Groups.create(%{"name" => "Other"}, tenant_id())

    assert {:ok, enabled} =
             Salix.Control.Groups.update(
               group["group_id"],
               %{"control_command_vfs_enabled" => true},
               tenant_id()
             )

    assert enabled["control_command_vfs_enabled"] == true
    assert {:ok, unchanged} = Salix.Control.Groups.get(other["group_id"], tenant_id())
    assert unchanged["control_command_vfs_enabled"] == false

    for invalid <- ["true", nil, 1, %{}] do
      assert {:error, {:bad_request, "control_command_vfs_enabled must be a boolean"}} =
               Salix.Control.Groups.update(
                 group["group_id"],
                 %{"control_command_vfs_enabled" => invalid},
                 tenant_id()
               )

      assert {:error, {:bad_request, "control_command_vfs_enabled must be a boolean"}} =
               Salix.Control.Groups.create(
                 %{"control_command_vfs_enabled" => invalid},
                 tenant_id()
               )
    end
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

  test "list_sessions reads internal runtime sessions without root session state" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Sessions"}, tenant_id())

    {:ok, agent} =
      SalixAgent.Control.create(
        %{"group_id" => group["group_id"], "name" => "Sessions"},
        tenant_id()
      )

    agent_id = agent["agent_id"]
    session_id = SalixStore.Ids.new_session_id()

    {:ok, _session} =
      SalixAgent.InternalSessionStore.prepare_commit(agent_id, session_id, [
        %{"type" => "session_created", "session_id" => session_id}
      ])

    {:ok, root} = SalixAgent.get_state(agent_id)
    refute Map.has_key?(root, :sessions)

    assert {:ok, [session]} = SalixAgent.Runtime.list_sessions(agent_id)
    assert session["session_id"] == session_id
    refute Map.has_key?(session, "events")

    assert {:ok, detail} = SalixAgent.Runtime.get_session(agent_id, session_id)
    refute Map.has_key?(detail, "events")
    refute Map.has_key?(detail, "messages")
  end

  test "wake returns queued acknowledgement without persisting queued control status" do
    {:ok, group} = Salix.Control.Groups.create(%{"name" => "Wake"}, tenant_id())

    {:ok, agent} =
      SalixAgent.Control.create(%{"group_id" => group["group_id"], "name" => "Wake"}, tenant_id())

    agent_id = agent["agent_id"]
    assert {:ok, %{"status" => "idle"}} = SalixAgent.Control.get_record(agent_id)

    assert {:ok, %{"status" => "queued"}} = SalixAgent.Control.wake(agent_id)
    assert {:ok, %{"status" => "idle"}} = SalixAgent.Control.get_record(agent_id)
  end
end
