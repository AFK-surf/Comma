defmodule SalixAgent.SkillStoreWriteTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{
    AsyncToolResults,
    FileBackend,
    SkillCatalog,
    SkillProjection,
    SkillStore,
    ToolDisclosure,
    Tools,
    WorkspaceEvents
  }

  alias SalixAgent.LLM.Mock
  alias SalixStore.{Blob, Codec, Keys, S3}

  @session_id "ses1_0000000000000000819"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, previous_backend)
      Application.put_env(:salix_agent, :llm, previous_llm)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    creator =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        name: "Skill creator",
        role: "worker",
        system_prompt: ""
      })

    peer =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        name: "Skill peer",
        role: "worker",
        system_prompt: ""
      })

    creator_id = creator["agent_id"]
    peer_id = peer["agent_id"]

    previous_root = Application.get_env(:salix_agent, :builtin_skills_path)
    root = Path.join(System.tmp_dir!(), "skill-write-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "read-only-proof"))

    File.write!(
      Path.join(root, "read-only-proof/SKILL.md"),
      "---\nname: Read Only Proof\n---\n\nREAD_ONLY"
    )

    Application.put_env(:salix_agent, :builtin_skills_path, root)

    on_exit(fn ->
      if previous_root,
        do: Application.put_env(:salix_agent, :builtin_skills_path, previous_root),
        else: Application.delete_env(:salix_agent, :builtin_skills_path)

      File.rm_rf!(root)
    end)

    %{
      creator_id: creator_id,
      creator_ctx: tool_ctx(creator_id, tenant_id, group_id),
      group_id: group_id,
      peer_id: peer_id,
      tenant_id: tenant_id,
      peer_ctx: tool_ctx(peer_id, tenant_id, group_id)
    }
  end

  test "projection reads independent scope catalogs in one object-store wave", %{
    creator_ctx: ctx,
    creator_id: agent_id,
    group_id: group_id,
    tenant_id: tenant_id
  } do
    global_key = Keys.ctl_skill_scope_global()

    sibling_keys = [
      Keys.ctl_skill_scope_tenant(tenant_id),
      Keys.ctl_skill_scope_group(group_id),
      Keys.ctl_skill_scope_agent(agent_id)
    ]

    SkillProjection.invalidate_cache()
    :ok = S3.Fake.reset_read_log()
    :ok = S3.Fake.set_fault({:pause, :get, global_key})

    on_exit(fn ->
      if Process.whereis(S3.Fake) && S3.Fake.paused?(), do: S3.Fake.release_pause()
    end)

    projection = Task.async(fn -> SkillProjection.materialize(ctx) end)
    await_fake_pause!()

    assert eventually(fn ->
             reads = S3.Fake.read_log()
             Enum.all?(sibling_keys, &({:get, &1} in reads))
           end)

    assert Task.yield(projection, 0) == nil
    assert :ok = S3.Fake.release_pause()
    assert {:ok, _projection} = Task.await(projection)
  end

  test "prepared materialization rejects a cache entry from an older plugin revision", %{
    creator_ctx: ctx
  } do
    SkillProjection.invalidate_cache()

    assert {:ok, visible} = SkillProjection.materialize(ctx)
    assert Enum.any?(visible.skills, &(&1["skill_id"] == "read-only-proof"))

    cached_ctx = Map.put(ctx, :skill_projection_revision, visible.revision)

    assert {:ok, {:cached, ^visible} = prepared} =
             SkillProjection.prepare_materialization(cached_ctx)

    restricted_plugin =
      ctx.plugin_projection
      |> Map.put("revision", "restricted-plugin-projection")
      |> Map.put("visible_skill_ids", [])
      |> Map.put("visible_skill_prefixes", [])

    current_ctx =
      cached_ctx
      |> Map.put(:plugin_projection, restricted_plugin)
      |> Map.put(:plugin_projection_revision, restricted_plugin["revision"])

    assert {:ok, restricted} = SkillProjection.finish_materialization(prepared, current_ctx)
    refute Enum.any?(restricted.skills, &(&1["skill_id"] == "read-only-proof"))
  end

  test "control plane deletes an editable group skill across agent ownership", %{
    creator_ctx: creator_ctx,
    creator_id: creator_id,
    group_id: group_id,
    peer_ctx: peer_ctx,
    peer_id: peer_id,
    tenant_id: tenant_id
  } do
    create_skill!(creator_ctx, "old-router-proof", "Old Router Proof")

    assert {:ok, read_only_event} =
             SkillStore.prepare_group_create(creator_ctx, %{
               "skill_id" => "group-read-only-proof",
               "name" => "Group Read Only Proof"
             })

    read_only_event = put_in(read_only_event, ["skill", "editable"], false)

    assert {:ok, _result} =
             SkillStore.commit_operation(
               "seed-group-read-only-proof",
               %{"skill_id" => "group-read-only-proof"},
               [read_only_event]
             )

    peer_delete = execute(peer_ctx, "skill.delete", %{"skill_id" => "old-router-proof"})
    assert peer_delete.error
    assert peer_delete.content =~ "only the creating agent can delete this skill"

    assert {:ok, %{"skills" => skills}} = SkillCatalog.list(peer_id, tenant_id)
    old_router_skill = Enum.find(skills, &(&1["skill_id"] == "old-router-proof"))
    read_only_skill = Enum.find(skills, &(&1["skill_id"] == "read-only-proof"))

    assert old_router_skill["deletable"] == true
    assert old_router_skill["delete_reason"] == nil
    assert read_only_skill["deletable"] == false
    assert read_only_skill["delete_reason"] == "read_only"

    actor = %{
      "type" => "user",
      "user_id" => "usr_dashboard_owner",
      "label" => "Dashboard Owner",
      "request_id" => "req_old_router_delete"
    }

    assert {:ok,
            %{
              "deleted" => true,
              "skill_id" => "old-router-proof",
              "created_by_agent_id" => ^creator_id
            }} = SkillCatalog.delete(peer_id, tenant_id, "old-router-proof", actor)

    assert {:error, :read_only} =
             SkillCatalog.delete(peer_id, tenant_id, "group-read-only-proof", actor)

    assert {:ok, catalog} = SkillStore.read_scope(:group, group_id)
    refute Map.has_key?(catalog.skills, "old-router-proof")
    assert Map.has_key?(catalog.skills, "group-read-only-proof")
  end

  test "SKILL.md write and edit commit without re-reading the prepared blob", %{
    creator_id: creator_id,
    creator_ctx: ctx,
    group_id: group_id
  } do
    create_skill!(ctx, "primary-proof", "Primary Proof")
    create_skill!(ctx, "duplicate-proof", "Duplicate Proof")

    path = SkillProjection.skill_path("primary-proof", "SKILL.md")
    assert {:ok, _cached} = SkillProjection.materialize(ctx)

    written =
      "---\nname: Renamed Proof\ndescription: Metadata from the prepared body.\n---\n\nBODY_ONE\n"

    write_result = execute!(ctx, "fs.write_file", %{"path" => path, "content" => written})
    [write_event] = write_result.events
    prepared_blob_key = blob_key(write_event)

    # The production internal async completion path stores the tool result after
    # skill side effects. A freshly uploaded immutable blob is deliberately
    # unavailable here: commit must use preparation-carried metadata, not GET it.
    :ok = S3.Fake.blackhole({:fail, 503, :get, prepared_blob_key})

    commit_result =
      WorkspaceEvents.commit_result(
        creator_id,
        @session_id,
        write_result,
        AsyncToolResults.operation_source(:internal),
        store_result: true
      )

    :ok = S3.Fake.clear_blackhole()
    assert {:ok, %{events: []}} = commit_result

    assert exact_tool_read(ctx, path) == written

    SkillProjection.invalidate_cache()
    assert {:ok, fresh_projection} = SkillProjection.materialize(ctx)
    projected = Enum.find(fresh_projection.skills, &(&1["skill_id"] == "primary-proof"))
    assert projected["name"] == "Renamed Proof"
    assert projected["description"] == "Metadata from the prepared body."

    assert {:ok, catalog} = SkillStore.read_scope(:group, group_id)

    assert %{
             "name" => "Renamed Proof",
             "description" => "Metadata from the prepared body.",
             "normalized_name" => "renamed proof",
             "version" => 2
           } = catalog.skills["primary-proof"]

    edit_result =
      execute!(ctx, "fs.edit_file", %{
        "path" => path,
        "old" => "BODY_ONE",
        "new" => "BODY_TWO"
      })

    [edit_event] = edit_result.events
    :ok = S3.Fake.blackhole({:fail, 503, :get, blob_key(edit_event)})

    edit_commit =
      WorkspaceEvents.commit_result(
        creator_id,
        @session_id,
        edit_result,
        "tool-result"
      )

    :ok = S3.Fake.clear_blackhole()
    assert {:ok, %{events: []}} = edit_commit
    assert exact_tool_read(ctx, path) == String.replace(written, "BODY_ONE", "BODY_TWO")

    assert {:ok, after_edit} = SkillStore.read_scope(:group, group_id)
    assert after_edit.skills["primary-proof"]["version"] == 3
  end

  test "SKILL.md metadata rename preserves CAS duplicate and permission checks", %{
    creator_id: creator_id,
    creator_ctx: creator_ctx,
    group_id: group_id,
    peer_ctx: peer_ctx
  } do
    create_skill!(creator_ctx, "owned-proof", "Owned Proof")
    create_skill!(creator_ctx, "reserved-proof", "Reserved Proof")
    path = SkillProjection.skill_path("owned-proof", "SKILL.md")
    original = exact_tool_read(creator_ctx, path)

    duplicate_result =
      execute!(creator_ctx, "fs.write_file", %{
        "path" => path,
        "content" => "---\nname: Reserved Proof\n---\n\nMUST_NOT_COMMIT"
      })

    assert {:error, "skill name already exists in this scope"} =
             WorkspaceEvents.commit_result(
               creator_id,
               @session_id,
               duplicate_result,
               "tool-result"
             )

    assert exact_tool_read(creator_ctx, path) == original
    assert {:ok, catalog} = SkillStore.read_scope(:group, group_id)
    assert catalog.skills["owned-proof"]["name"] == "Owned Proof"
    assert catalog.name_index["reserved proof"] == "reserved-proof"

    peer_result =
      execute(peer_ctx, "fs.write_file", %{
        "path" => path,
        "content" => "---\nname: Peer Rewrite\n---\n\nBLOCKED"
      })

    assert peer_result.error
    assert peer_result.content =~ "only the creating agent can modify this skill"

    read_only_result =
      execute(creator_ctx, "fs.write_file", %{
        "path" => SkillProjection.skill_path("read-only-proof", "SKILL.md"),
        "content" => "---\nname: Read Only Rewrite\n---\n\nBLOCKED"
      })

    assert read_only_result.error
    assert read_only_result.content =~ "skill is read-only"
  end

  test "migrated catalog payload scope cannot route edits to a legacy key", %{
    creator_id: creator_id,
    creator_ctx: ctx,
    group_id: group_id
  } do
    create_skill!(ctx, "migrated-proof", "Migrated Proof")
    legacy_group_id = "proj_5cbe75b0-af00-435c-8c5a-5430a99986ea"
    canonical_scope = %{"layer" => "group", "id" => group_id}
    canonical_key = Keys.ctl_skill_scope_group(group_id)
    legacy_key = Keys.ctl_skill_scope_group(legacy_group_id)

    assert {:ok, %{body: body, etag: etag}} = S3.get(canonical_key)

    stale_state = %{
      Codec.decode_snapshot(body)
      | scope: %{"layer" => "group", "id" => legacy_group_id}
    }

    assert {:ok, _} = S3.put(canonical_key, Codec.encode_snapshot(stale_state), if_match: etag)
    SkillProjection.invalidate_cache()

    path = SkillProjection.skill_path("migrated-proof", "SKILL.md")

    edit_result =
      execute!(ctx, "fs.edit_file", %{
        "path" => path,
        "old" => "# Migrated Proof",
        "new" => "# Migrated Proof Repaired"
      })

    [edit_event] = edit_result.events
    assert edit_event["scope"] == canonical_scope

    assert {:ok, %{events: []}} =
             WorkspaceEvents.commit_result(
               creator_id,
               @session_id,
               edit_result,
               AsyncToolResults.operation_source(:internal),
               store_result: true
             )

    assert exact_tool_read(ctx, path) =~ "# Migrated Proof Repaired"
    assert {:ok, repaired_catalog} = SkillStore.read_scope(:group, group_id)
    assert repaired_catalog.scope == canonical_scope
    assert repaired_catalog.skills["migrated-proof"]["version"] == 2

    assert Enum.any?(
             Map.keys(repaired_catalog.operations),
             &String.ends_with?(&1, ":group:" <> group_id)
           )

    assert {:ok, %{body: repaired_body}} = S3.get(canonical_key)
    assert %SkillStore.State{scope: ^canonical_scope} = Codec.decode_snapshot(repaired_body)
    assert {:error, :not_found} = S3.get(legacy_key)
  end

  test "read_scope normalizes stale payload scope for every owned catalog layer", %{
    creator_id: agent_id,
    creator_ctx: ctx,
    group_id: group_id
  } do
    fixtures = [
      {:tenant, ctx.tenant_id, "org_legacy", Keys.ctl_skill_scope_tenant(ctx.tenant_id)},
      {:group, group_id, "proj_legacy", Keys.ctl_skill_scope_group(group_id)},
      {:agent, agent_id, "agent_legacy", Keys.ctl_skill_scope_agent(agent_id)}
    ]

    Enum.each(fixtures, fn {layer, owner_id, legacy_id, key} ->
      stale_state = %SkillStore.State{
        scope: %{"layer" => Atom.to_string(layer), "id" => legacy_id}
      }

      assert {:ok, _} = S3.put(key, Codec.encode_snapshot(stale_state))
      assert {:ok, state} = SkillStore.read_scope(layer, owner_id)

      assert state.scope == %{
               "layer" => Atom.to_string(layer),
               "id" => owner_id
             }
    end)
  end

  test "CAS retry revalidates a prepared SKILL.md name against the winning rename", %{
    creator_ctx: ctx,
    group_id: group_id
  } do
    create_skill!(ctx, "cas-first", "CAS First")
    create_skill!(ctx, "cas-second", "CAS Second")

    first =
      execute!(ctx, "fs.write_file", %{
        "path" => SkillProjection.skill_path("cas-first", "SKILL.md"),
        "content" => "---\nname: CAS Winner\n---\n\nFIRST"
      })

    second =
      execute!(ctx, "fs.write_file", %{
        "path" => SkillProjection.skill_path("cas-second", "SKILL.md"),
        "content" => "---\nname: CAS Winner\n---\n\nSECOND"
      })

    [first_event] = first.events
    [second_event] = second.events
    scope_key = Keys.ctl_skill_scope_group(group_id)
    :ok = S3.Fake.set_fault({:pause, :put, scope_key})

    stale_commit =
      Task.async(fn ->
        SkillStore.commit_operation("cas-stale-rename", %{}, [first_event])
      end)

    await_fake_pause!()
    assert {:ok, %{}} = SkillStore.commit_operation("cas-winning-rename", %{}, [second_event])
    :ok = S3.Fake.release_pause()

    assert {:error, "skill name already exists in this scope"} = Task.await(stale_commit)
    assert {:ok, catalog} = SkillStore.read_scope(:group, group_id)
    assert catalog.skills["cas-first"]["name"] == "CAS First"
    assert catalog.skills["cas-second"]["name"] == "CAS Winner"
    assert catalog.name_index["cas winner"] == "cas-second"
  end

  test "streamed copy and move into SKILL.md refresh catalog metadata and enforce size limits", %{
    creator_id: creator_id,
    creator_ctx: ctx
  } do
    create_skill!(ctx, "stream-proof", "Stream Proof")
    path = SkillProjection.skill_path("stream-proof", "SKILL.md")
    copy_source = "/stream-proof-copy.md"
    move_source = "/stream-proof-move.md"

    copy_body = "---\nname: Stream Copied\ndescription: copied metadata\n---\n\nCOPIED"
    move_body = "---\nname: Stream Moved\ndescription: moved metadata\n---\n\nMOVED"
    seed_workspace_stream!(creator_id, copy_source, [copy_body])
    seed_workspace_stream!(creator_id, move_source, [move_body])

    assert {:ok, [copy_event], _size} = FileBackend.prepare_copy(ctx, copy_source, path)

    assert {:ok, _} =
             SkillStore.commit_operation("stream-copy", %{}, [copy_event])

    assert exact_tool_read(ctx, path) == copy_body
    assert {:ok, %{"skills" => catalog}} = SkillCatalog.list(ctx.agent_id, ctx.tenant_id)

    assert Enum.any?(
             catalog,
             &(&1["name"] == "Stream Copied" and &1["description"] == "copied metadata")
           )

    assert {:ok, [move_event, %{"type" => "vfs_delete"} = delete_event], _size} =
             FileBackend.prepare_move(ctx, move_source, path)

    move_result = %{
      id: "stream-move-result",
      name: "fs.move_file",
      status: "completed",
      content: "moved",
      error: false,
      events: [move_event, delete_event]
    }

    assert {:ok, %{events: []}} =
             WorkspaceEvents.commit_result(creator_id, @session_id, move_result, "tool-result")

    assert exact_tool_read(ctx, path) == move_body
    assert {:error, :not_found} = SalixAgent.AgentWorkspace.read(creator_id, move_source)

    oversized_source = "/stream-proof-oversized.md"
    oversized = String.duplicate("x", Blob.max_bytes() + 1)
    seed_workspace_stream!(creator_id, oversized_source, [oversized])

    assert {:error, :too_large} = FileBackend.prepare_copy(ctx, oversized_source, path)
    assert exact_tool_read(ctx, path) == move_body
  end

  defp create_skill!(ctx, skill_id, name) do
    result =
      execute!(ctx, "skill.create", %{
        "skill_id" => skill_id,
        "name" => name,
        "description" => "Initial description for #{name}"
      })

    assert {:ok, %{events: []}} =
             WorkspaceEvents.commit_result(
               ctx.agent_id,
               @session_id,
               result,
               "tool-result"
             )
  end

  defp exact_tool_read(ctx, path) do
    execute!(ctx, "fs.read_file", %{"path" => path}).content
  end

  defp execute!(ctx, name, args) do
    result = execute(ctx, name, args)
    refute result.error, "#{name} failed: #{result.content}"
    result
  end

  defp execute(ctx, name, args) do
    [result] =
      Tools.execute(
        [
          %{
            "id" => "skill-write-#{System.unique_integer([:positive])}",
            "name" => name,
            "args" => args
          }
        ],
        ctx
      )

    result
  end

  defp seed_workspace_stream!(agent_id, path, stream) do
    assert {:ok, event} = SalixAgent.AgentWorkspace.prepare_write_stream(agent_id, path, stream)

    assert {:ok, _} =
             SalixAgent.AgentWorkspace.seed_operation(
               agent_id,
               "seed-stream-#{System.unique_integer([:positive])}",
               %{},
               [event]
             )
  end

  defp blob_key(%{"entry" => %{"ref" => %{"uuid" => uuid}}}), do: Keys.blob(uuid)

  defp await_fake_pause!(attempts \\ 100)
  defp await_fake_pause!(0), do: flunk("timed out waiting for paused skill scope CAS")

  defp await_fake_pause!(attempts) do
    if S3.Fake.paused?() do
      :ok
    else
      Process.sleep(5)
      await_fake_pause!(attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp tool_ctx(agent_id, tenant_id, group_id) do
    ctx =
      %{
        agent_id: agent_id,
        tenant_id: tenant_id,
        group_id: group_id,
        session_id: @session_id,
        role: "worker",
        runtime_kind: :internal
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
  end
end
