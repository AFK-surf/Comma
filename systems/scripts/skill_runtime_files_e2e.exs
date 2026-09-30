# End-to-end validation for agent-visible VFS and skill runtime files.
#
# Run through Deno:
#   deno test --allow-all e2e/tests/skill_runtime_files_test.ts
#
# The script uses the same tool execution and side-effect commit boundary that a
# real internal LLM round uses: the LLM-facing `call` envelope expands to the
# canonical tool, and `WorkspaceEvents.commit_result/5` commits workspace/skill
# events returned by the tool result.

defmodule SkillRuntimeFilesE2E do
  alias Salix.Control.{Groups, Plugins, Tenants}

  alias SalixAgent.{
    AgentWorkspace,
    SkillProjection,
    SkillStore,
    ToolDisclosure,
    Tools,
    WorkspaceEvents
  }

  alias SalixStore.{Blob, Codec, Keys, S3}

  def run do
    configure_s3_from_env!()
    tenant_id = create_tenant!()
    Process.put(:skill_runtime_tenant_id, tenant_id)

    run_id = System.unique_integer([:positive])
    skill_id = "e2e-skill-#{run_id}"
    copied_skill_id = "e2e-copied-global-#{run_id}"
    session_id = SalixStore.Ids.new_session_id()

    {:ok, group} = Groups.create(%{"name" => "Skill Runtime E2E"}, tenant_id)
    group_id = group["group_id"]

    {:ok, other_group} = Groups.create(%{"name" => "Skill Runtime E2E Other"}, tenant_id)
    other_group_id = other_group["group_id"]

    {:ok, creator} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "skill-creator"}, tenant_id)

    {:ok, peer} =
      SalixAgent.Control.create(%{"group_id" => group_id, "name" => "skill-peer"}, tenant_id)

    {:ok, other} =
      SalixAgent.Control.create(
        %{"group_id" => other_group_id, "name" => "skill-other"},
        tenant_id
      )

    creator_ctx = ctx(creator["agent_id"], group_id, session_id)
    peer_ctx = ctx(peer["agent_id"], group_id, session_id)
    other_ctx = ctx(other["agent_id"], other_group_id, session_id)

    run_legacy_workspace_migration!(creator["agent_id"], creator_ctx, run_id)

    index_before = call!(creator_ctx, "fs.read_file", %{"path" => "/.runtime/skills/index.md"})
    global_skill_id = "connect-device"
    global_skill_doc = "/.runtime/skills/#{global_skill_id}/SKILL.md"

    require_contains!(
      index_before,
      "location: #{global_skill_doc}",
      "built-in skill index"
    )

    global_skill = call!(creator_ctx, "fs.read_file", %{"path" => global_skill_doc})
    {:ok, builtin} = SkillProjection.get_skill(creator_ctx, global_skill_id)
    entry = builtin["files"]["SKILL.md"]
    {:ok, expected_body} = SkillStore.read_entry(creator["agent_id"], entry)
    require_contains!(global_skill, expected_body, "built-in skill body")

    source = "/handtests/#{run_id}/source.md"
    copied = "/handtests/#{run_id}/copied.md"
    moved = "/handtests/#{run_id}/moved.md"
    skill_doc = "/.runtime/skills/#{skill_id}/SKILL.md"
    skill_resource = "/.runtime/skills/#{skill_id}/references/guide.md"
    from_vfs = "/.runtime/skills/#{skill_id}/references/from-vfs.md"
    from_skill = "/handtests/#{run_id}/from-skill.md"
    readonly_probe = "/.runtime/skills/#{global_skill_id}/references/blocked.md"
    readonly_skill_doc = global_skill_doc
    copied_skill_resource = "/.runtime/skills/#{copied_skill_id}/references/editable.md"

    numbered =
      1..24
      |> Enum.map_join("\n", &"line #{&1} VFS_MARKER_#{run_id}")

    call!(creator_ctx, "fs.write_file", %{"path" => source, "content" => numbered})

    full_read = call!(creator_ctx, "fs.read_file", %{"path" => source})
    require_contains!(full_read, "VFS_MARKER_#{run_id}", "full VFS read")

    paged_read =
      call!(creator_ctx, "fs.read_file", %{"path" => source, "start_line" => 5, "num_lines" => 4})

    require_contains!(paged_read, "line 5", "paged VFS read")
    require_contains!(paged_read, "line 8", "paged VFS read")

    tail_read = call!(creator_ctx, "fs.read_file", %{"path" => source, "tail_lines" => 3})
    require_contains!(tail_read, "line 22", "tail VFS read")
    require_contains!(tail_read, "line 24", "tail VFS read")

    call!(creator_ctx, "fs.edit_file", %{
      "path" => source,
      "old" => "VFS_MARKER_#{run_id}",
      "new" => "VFS_MARKER_EDITED_#{run_id}"
    })

    call!(creator_ctx, "fs.copy_file", %{"from" => source, "to" => copied})
    call!(creator_ctx, "fs.move_file", %{"from" => copied, "to" => moved})
    moved_read = call!(creator_ctx, "fs.read_file", %{"path" => moved})
    require_contains!(moved_read, "VFS_MARKER_EDITED_#{run_id}", "moved VFS read")

    missing_copy = call_error!(creator_ctx, "fs.read_file", %{"path" => copied})
    require_contains!(missing_copy, "no such file", "moved source removal")

    call!(creator_ctx, "skill.create", %{
      "skill_id" => skill_id,
      "name" => "E2E Skill #{run_id}",
      "description" => "Skill runtime files E2E #{run_id}",
      "content" => """
      ---
      name: E2E Skill #{run_id}
      description: Skill runtime files E2E #{run_id}
      ---
      SKILL_DOC_MARKER_#{run_id}
      """
    })

    index_after_create =
      call!(creator_ctx, "fs.read_file", %{"path" => "/.runtime/skills/index.md"})

    require_contains!(index_after_create, skill_id, "skill index after create")
    require_contains!(index_after_create, "editable: true", "skill index after create")

    skill_doc_read = call!(creator_ctx, "fs.read_file", %{"path" => skill_doc})
    require_contains!(skill_doc_read, "SKILL_DOC_MARKER_#{run_id}", "skill doc read")

    legacy_group_id = "proj_skill_runtime_e2e_#{run_id}"
    put_stale_catalog_scope!(group_id, legacy_group_id)

    streamed_copy_source = "/handtests/#{run_id}/streamed-skill-copy.md"

    streamed_copy_body =
      "---\nname: E2E Stream Copy #{run_id}\ndescription: copied into SKILL.md\n---\n\nSTREAM_COPY_#{run_id}"

    call!(creator_ctx, "fs.write_file", %{
      "path" => streamed_copy_source,
      "content" => streamed_copy_body
    })

    call!(creator_ctx, "fs.copy_file", %{"from" => streamed_copy_source, "to" => skill_doc})

    require_equal!(
      call!(creator_ctx, "fs.read_file", %{"path" => skill_doc}),
      streamed_copy_body,
      "streamed copy into SKILL.md"
    )

    require_persisted_catalog_scope!(group_id, legacy_group_id)

    streamed_move_source = "/handtests/#{run_id}/streamed-skill-move.md"

    streamed_move_body =
      "---\nname: E2E Stream Move #{run_id}\ndescription: moved into SKILL.md\n---\n\nSTREAM_MOVE_#{run_id}"

    call!(creator_ctx, "fs.write_file", %{
      "path" => streamed_move_source,
      "content" => streamed_move_body
    })

    call!(creator_ctx, "fs.move_file", %{"from" => streamed_move_source, "to" => skill_doc})

    require_equal!(
      call!(creator_ctx, "fs.read_file", %{"path" => skill_doc}),
      streamed_move_body,
      "streamed move into SKILL.md"
    )

    moved_skill_source =
      call_error!(creator_ctx, "fs.read_file", %{"path" => streamed_move_source})

    require_contains!(moved_skill_source, "no such file", "streamed SKILL.md move source removal")

    rewritten_skill_doc =
      "---\nname: E2E Rewritten #{run_id}\ndescription: rewritten metadata #{run_id}\n---\n\nSKILL_REWRITE_ONE_#{run_id}"

    call!(creator_ctx, "fs.write_file", %{
      "path" => skill_doc,
      "content" => rewritten_skill_doc
    })

    require_equal!(
      call!(creator_ctx, "fs.read_file", %{"path" => skill_doc}),
      rewritten_skill_doc,
      "exact SKILL.md overwrite readback"
    )

    call!(creator_ctx, "fs.edit_file", %{
      "path" => skill_doc,
      "old" => "SKILL_REWRITE_ONE_#{run_id}",
      "new" => "SKILL_REWRITE_TWO_#{run_id}"
    })

    edited_skill_doc =
      String.replace(
        rewritten_skill_doc,
        "SKILL_REWRITE_ONE_#{run_id}",
        "SKILL_REWRITE_TWO_#{run_id}"
      )

    require_equal!(
      call!(creator_ctx, "fs.read_file", %{"path" => skill_doc}),
      edited_skill_doc,
      "exact SKILL.md edit readback"
    )

    SkillProjection.invalidate_cache()
    {:ok, fresh_projection} = SkillProjection.materialize(creator_ctx)

    fresh_skill =
      Enum.find(fresh_projection.skills, &(&1["skill_id"] == skill_id)) ||
        raise "rewritten skill missing from fresh projection"

    unless fresh_skill["name"] == "E2E Rewritten #{run_id}" and
             fresh_skill["description"] == "rewritten metadata #{run_id}" do
      raise "fresh projection has stale SKILL.md metadata: #{inspect(fresh_skill)}"
    end

    {:ok, group_catalog} = SkillStore.read_scope(:group, group_id)
    catalog_skill = Map.fetch!(group_catalog.skills, skill_id)

    unless catalog_skill["name"] == "E2E Rewritten #{run_id}" and
             catalog_skill["description"] == "rewritten metadata #{run_id}" and
             catalog_skill["normalized_name"] == "e2e rewritten #{run_id}" do
      raise "catalog has stale SKILL.md metadata: #{inspect(catalog_skill)}"
    end

    call!(creator_ctx, "fs.write_file", %{
      "path" => skill_resource,
      "content" => "SKILL_RESOURCE_MARKER_#{run_id}"
    })

    call!(creator_ctx, "fs.edit_file", %{
      "path" => skill_resource,
      "old" => "SKILL_RESOURCE_MARKER_#{run_id}",
      "new" => "SKILL_RESOURCE_EDITED_#{run_id}"
    })

    skill_resource_read = call!(creator_ctx, "fs.read_file", %{"path" => skill_resource})

    require_contains!(
      skill_resource_read,
      "SKILL_RESOURCE_EDITED_#{run_id}",
      "skill resource read"
    )

    skill_list =
      call!(creator_ctx, "fs.list_files", %{"prefix" => "/.runtime/skills/#{skill_id}"})

    require_contains!(skill_list, skill_doc, "skill file list")
    require_contains!(skill_list, skill_resource, "skill file list")

    skill_grep =
      call!(creator_ctx, "fs.grep", %{
        "prefix" => "/.runtime/skills/#{skill_id}",
        "pattern" => "SKILL_RESOURCE_EDITED_#{run_id}"
      })

    require_contains!(skill_grep, skill_resource, "skill grep")

    call!(creator_ctx, "fs.copy_file", %{"from" => moved, "to" => from_vfs})
    from_vfs_read = call!(creator_ctx, "fs.read_file", %{"path" => from_vfs})
    require_contains!(from_vfs_read, "VFS_MARKER_EDITED_#{run_id}", "VFS to skill copy")

    call!(creator_ctx, "fs.copy_file", %{"from" => skill_resource, "to" => from_skill})
    from_skill_read = call!(creator_ctx, "fs.read_file", %{"path" => from_skill})
    require_contains!(from_skill_read, "SKILL_RESOURCE_EDITED_#{run_id}", "skill to VFS copy")

    readonly_error =
      call_error!(creator_ctx, "fs.write_file", %{
        "path" => readonly_probe,
        "content" => "must not write"
      })

    require_contains!(readonly_error, "skill is read-only", "read-only global skill write")

    readonly_doc_error =
      call_error!(creator_ctx, "fs.write_file", %{
        "path" => readonly_skill_doc,
        "content" => "---\nname: Must Not Rewrite\n---\n\nblocked"
      })

    require_contains!(readonly_doc_error, "skill is read-only", "read-only global SKILL.md write")

    call!(creator_ctx, "skill.copy", %{
      "source_skill_id" => global_skill_id,
      "skill_id" => copied_skill_id,
      "name" => "Copied Global #{run_id}"
    })

    call!(creator_ctx, "fs.write_file", %{
      "path" => copied_skill_resource,
      "content" => "COPIED_GLOBAL_EDITABLE_#{run_id}"
    })

    copied_read = call!(creator_ctx, "fs.read_file", %{"path" => copied_skill_resource})

    require_contains!(
      copied_read,
      "COPIED_GLOBAL_EDITABLE_#{run_id}",
      "copied global skill write"
    )

    duplicate_name_error =
      call_commit_error!(creator_ctx, "fs.write_file", %{
        "path" => skill_doc,
        "content" =>
          "---\nname: Copied Global #{run_id}\ndescription: duplicate metadata\n---\n\nMUST_NOT_COMMIT"
      })

    require_contains!(
      duplicate_name_error,
      "skill name already exists in this scope",
      "duplicate SKILL.md metadata name"
    )

    require_equal!(
      call!(creator_ctx, "fs.read_file", %{"path" => skill_doc}),
      edited_skill_doc,
      "SKILL.md body after duplicate metadata rejection"
    )

    duplicate_id_error =
      call_error!(creator_ctx, "skill.create", %{
        "skill_id" => skill_id,
        "name" => "Another Name #{run_id}"
      })

    require_contains!(duplicate_id_error, "skill already exists", "duplicate skill id")

    peer_index = call!(peer_ctx, "fs.read_file", %{"path" => "/.runtime/skills/index.md"})
    require_contains!(peer_index, skill_id, "same group skill projection")

    peer_write_error =
      call_error!(peer_ctx, "fs.write_file", %{
        "path" => "/.runtime/skills/#{skill_id}/references/peer.md",
        "content" => "PEER_WRITE_#{run_id}"
      })

    require_contains!(
      peer_write_error,
      "only the creating agent can modify this skill",
      "same group non-creator write"
    )

    peer_doc_write_error =
      call_error!(peer_ctx, "fs.write_file", %{
        "path" => skill_doc,
        "content" => "---\nname: Peer Rewrite #{run_id}\n---\n\nblocked"
      })

    require_contains!(
      peer_doc_write_error,
      "only the creating agent can modify this skill",
      "same group non-creator SKILL.md write"
    )

    other_index = call!(other_ctx, "fs.read_file", %{"path" => "/.runtime/skills/index.md"})

    if String.contains?(other_index, skill_id) do
      raise "other group unexpectedly sees group skill #{skill_id}"
    end

    call!(creator_ctx, "skill.delete", %{"skill_id" => skill_id})

    index_after_delete =
      call!(creator_ctx, "fs.read_file", %{"path" => "/.runtime/skills/index.md"})

    if String.contains?(index_after_delete, skill_id) do
      raise "deleted skill still appears in skill index"
    end

    missing_skill = call_error!(creator_ctx, "fs.read_file", %{"path" => skill_doc})
    require_contains!(missing_skill, "no such file", "deleted skill doc")

    IO.puts("SKILL_RUNTIME_FILES_E2E: PASS run_id=#{run_id}")
  rescue
    e ->
      IO.puts("SKILL_RUNTIME_FILES_E2E: FAIL #{Exception.message(e)}")
      System.halt(1)
  end

  defp run_legacy_workspace_migration!(agent_id, ctx, run_id) do
    legacy_skill_id = "legacy-e2e-#{run_id}"
    legacy_root = "/.salix/skills/#{legacy_skill_id}"

    skill_md = """
    ---
    name: Legacy E2E #{run_id}
    description: Migrated legacy workspace skill #{run_id}
    ---

    LEGACY_SKILL_MARKER_#{run_id}
    """

    legacy_resource = "LEGACY_RESOURCE_MARKER_#{run_id}"
    keep_note = "KEEP_WORKSPACE_NOTE_#{run_id}"

    :ok =
      AgentWorkspace.prepare_seed(agent_id, %{
        "#{legacy_root}/SKILL.md" => workspace_entry!(agent_id, skill_md),
        "#{legacy_root}/references/guide.md" => workspace_entry!(agent_id, legacy_resource),
        "/notes/keep.md" => workspace_entry!(agent_id, keep_note)
      })

    case SalixAgent.Migrations.SkillWorkspace.migrate_agent(agent_id) do
      :migrated -> :ok
      other -> raise "legacy workspace skill migration failed: #{inspect(other)}"
    end

    {:ok, projection} = SkillProjection.materialize(ctx)

    legacy_skill =
      Enum.find(projection.skills, &(&1["skill_id"] == legacy_skill_id)) ||
        raise "legacy workspace skill was not imported into projection"

    unless legacy_skill["origin"] == "legacy_workspace" and legacy_skill["editable"] == true do
      raise "legacy workspace skill imported with wrong metadata: #{inspect(legacy_skill)}"
    end

    migrated_doc =
      call!(ctx, "fs.read_file", %{"path" => "/.runtime/skills/#{legacy_skill_id}/SKILL.md"})

    require_contains!(migrated_doc, "LEGACY_SKILL_MARKER_#{run_id}", "migrated skill doc")

    migrated_resource =
      call!(ctx, "fs.read_file", %{
        "path" => "/.runtime/skills/#{legacy_skill_id}/references/guide.md"
      })

    require_contains!(
      migrated_resource,
      "LEGACY_RESOURCE_MARKER_#{run_id}",
      "migrated skill resource"
    )

    {:ok, manifest} = AgentWorkspace.manifest(agent_id)

    for legacy_path <- ["#{legacy_root}/SKILL.md", "#{legacy_root}/references/guide.md"] do
      if Map.has_key?(manifest, legacy_path) do
        raise "legacy workspace path was not removed after migration: #{legacy_path}"
      end
    end

    unless Map.has_key?(manifest, "/notes/keep.md") do
      raise "migration removed unrelated workspace file"
    end

    case SalixAgent.Migrations.SkillWorkspace.migrate_agent(agent_id) do
      :skipped -> :ok
      other -> raise "legacy workspace skill migration was not idempotent: #{inspect(other)}"
    end
  end

  defp workspace_entry!(agent_id, content) do
    {:ok, ref} = Blob.put(agent_id, content)

    %{
      "ref" => %{"kind" => ref.kind, "uuid" => ref.uuid, "size" => ref.size, "hash" => ref.hash},
      "size" => ref.size,
      "hash" => ref.hash,
      "modified_at" => System.os_time(:second)
    }
  end

  defp put_stale_catalog_scope!(group_id, legacy_group_id) do
    key = Keys.ctl_skill_scope_group(group_id)
    {:ok, %{body: body, etag: etag}} = S3.get(key)

    stale_state = %{
      Codec.decode_snapshot(body)
      | scope: %{"layer" => "group", "id" => legacy_group_id}
    }

    case S3.put(key, Codec.encode_snapshot(stale_state), if_match: etag) do
      {:ok, _} -> SkillProjection.invalidate_cache()
      {:error, reason} -> raise "stale skill catalog fixture failed: #{inspect(reason)}"
    end
  end

  defp require_persisted_catalog_scope!(group_id, legacy_group_id) do
    canonical_scope = %{"layer" => "group", "id" => group_id}
    {:ok, %{body: body}} = S3.get(Keys.ctl_skill_scope_group(group_id))

    case Codec.decode_snapshot(body) do
      %{scope: ^canonical_scope} -> :ok
      state -> raise "skill catalog scope did not self-repair: #{inspect(state.scope)}"
    end

    case S3.get(Keys.ctl_skill_scope_group(legacy_group_id)) do
      {:error, :not_found} -> :ok
      other -> raise "skill mutation created a legacy catalog key: #{inspect(other)}"
    end
  end

  defp ctx(agent_id, group_id, session_id) do
    base = %{
      tenant_id: tenant_id!(),
      group_id: group_id,
      agent_id: agent_id,
      session_id: session_id,
      role: "worker",
      runtime_kind: :internal,
      llm_tool_envelope: true,
      plugin_projection: runtime_plugin_projection!(group_id)
    }

    Map.put(base, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, base))
  end

  defp runtime_plugin_projection!(group_id) do
    case Plugins.runtime_projection(%{
           "tenant_id" => tenant_id!(),
           "group_id" => group_id
         }) do
      {:ok, projection} -> projection
      {:error, reason} -> raise "plugin runtime projection failed: #{inspect(reason)}"
    end
  end

  defp call!(ctx, tool, params) do
    result = execute(ctx, tool, params)

    if result[:error] || result["error"] do
      raise "#{tool} failed: #{result[:content] || result["content"]}"
    end

    commit_result!(ctx, result, tool)
    result[:content] || result["content"] || ""
  end

  defp call_error!(ctx, tool, params) do
    result = execute(ctx, tool, params)

    unless result[:error] || result["error"] do
      raise "#{tool} unexpectedly succeeded: #{inspect(result[:content] || result["content"])}"
    end

    commit_result!(ctx, result, tool)
    result[:content] || result["content"] || ""
  end

  defp call_commit_error!(ctx, tool, params) do
    result = execute(ctx, tool, params)

    if result[:error] || result["error"] do
      raise "#{tool} failed before the expected commit rejection: #{result[:content] || result["content"]}"
    end

    case WorkspaceEvents.commit_result(ctx.agent_id, ctx.session_id, result, "skill-runtime-e2e") do
      {:error, reason} -> inspect(reason)
      {:ok, _result} -> raise "#{tool} commit unexpectedly succeeded"
    end
  end

  defp execute(ctx, tool, params) do
    [result] =
      Tools.execute(
        [
          %{
            "id" => "e2e-#{System.unique_integer([:positive])}",
            "name" => "call",
            "args" => %{"tool" => tool, "params" => params}
          }
        ],
        ctx
      )

    result
  end

  defp commit_result!(ctx, result, tool) do
    case WorkspaceEvents.commit_result(ctx.agent_id, ctx.session_id, result, "skill-runtime-e2e") do
      {:ok, _result} -> :ok
      {:error, reason} -> raise "#{tool} commit failed: #{inspect(reason)}"
    end
  end

  defp require_contains!(text, needle, label) do
    unless String.contains?(to_string(text), needle) do
      raise "#{label} did not contain #{inspect(needle)}: #{String.slice(to_string(text), 0, 500)}"
    end
  end

  defp require_equal!(actual, expected, label) do
    unless actual == expected do
      raise "#{label} mismatch: expected #{inspect(expected)}, got #{inspect(actual)}"
    end
  end

  defp create_tenant! do
    case Tenants.create(%{"name" => "Skill Runtime E2E"}) do
      {:ok, %{"tenant_id" => tenant_id}} -> tenant_id
      {:error, reason} -> raise("tenant create failed: #{inspect(reason)}")
    end
  end

  defp tenant_id! do
    Process.get(:skill_runtime_tenant_id) ||
      raise("skill runtime tenant identity is unavailable")
  end

  defp configure_s3_from_env! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
    put_env(:s3_endpoint, "SALIX_S3_ENDPOINT")
    put_env(:s3_region, "SALIX_S3_REGION")
    put_env(:s3_bucket, "SALIX_S3_BUCKET", "salix-test")
    put_env(:s3_access_key_id, "SALIX_S3_ACCESS_KEY_ID", System.get_env("AWS_ACCESS_KEY_ID"))

    put_env(
      :s3_secret_access_key,
      "SALIX_S3_SECRET_ACCESS_KEY",
      System.get_env("AWS_SECRET_ACCESS_KEY")
    )
  end

  defp put_env(key, name, fallback \\ nil) do
    case System.get_env(name) || fallback do
      value when is_binary(value) and value != "" -> Application.put_env(:salix_store, key, value)
      _ -> :ok
    end
  end
end

SkillRuntimeFilesE2E.run()
