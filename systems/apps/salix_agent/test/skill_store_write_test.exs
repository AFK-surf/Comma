defmodule SalixAgent.SkillStoreWriteTest do
  use SystemsClock.Case, async: false

  use SalixAgent.TestSupport.Settle

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
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_llm = SystemsRuntime.get_env(:salix_agent, :llm)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)
    start_supervised!(Mock)
    SystemsRuntime.put_env(:salix_agent, :llm, Mock)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
      SystemsRuntime.put_env(:salix_agent, :llm, previous_llm)
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

    previous_root = SystemsRuntime.get_env(:salix_agent, :builtin_skills_path)

    root =
      Path.join(
        System.tmp_dir!(),
        "skill-write-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "read-only-proof"))

    File.write!(
      Path.join(root, "read-only-proof/SKILL.md"),
      "---\nname: Read Only Proof\n---\n\nREAD_ONLY"
    )

    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, root)

    on_exit(fn ->
      if previous_root,
        do: SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, previous_root),
        else: SystemsRuntime.delete_env(:salix_agent, :builtin_skills_path)

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
            "id" => "skill-write-#{SystemsRuntime.Proc.unique_integer([:positive])}",
            "name" => name,
            "args" => args
          }
        ],
        ctx
      )

    result
  end

  defp blob_key(%{"entry" => %{"ref" => %{"uuid" => uuid}}}), do: Keys.blob(uuid)

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
