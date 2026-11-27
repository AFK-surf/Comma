defmodule SalixAgent.BuiltinSkillsTest do
  use SystemsClock.Case, async: false

  alias SalixAgent.{FileBackend, SkillProjection, SkillStore}
  alias SalixStore.S3.Fake

  setup do
    Fake.reset()
    previous = SystemsRuntime.get_env(:salix_agent, :builtin_skills_path)

    root =
      Path.join(
        System.tmp_dir!(),
        "local-skills-#{SystemsRuntime.Proc.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "proof-skill/references"))
    body = "---\nname: Proof Skill\ndescription: A local skill.\n---\n\nLocal instructions\n"
    File.write!(Path.join(root, "proof-skill/SKILL.md"), body)
    File.write!(Path.join(root, "proof-skill/references/proof.bin"), <<0, 255, 1, 2>>)
    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, root)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = SalixStore.Ids.new_group_id(tenant)

    ctx =
      %{
        tenant_id: tenant,
        group_id: group,
        agent_id: SalixStore.Ids.new_agent_id(group),
        session_id: "local-skill-test"
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    on_exit(fn ->
      if previous,
        do: SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, previous),
        else: SystemsRuntime.delete_env(:salix_agent, :builtin_skills_path)

      File.rm_rf!(root)
    end)

    %{root: root, body: body, ctx: ctx}
  end

  test "projected prompt exposes only selected built-in catalogs", %{ctx: ctx} do
    persist(ctx, :group, "private-skill", "builtin", "PRIVATE_SKILL_BODY")
    {:ok, projection} = SkillProjection.materialize(ctx)
    disclosure = SalixAgent.ToolDisclosure.materialize_static("router", :internal, ctx)

    private_tool = %{
      "name" => "tenant.private_operation",
      "summary" => "PRIVATE_PLUGIN",
      "prompt_visibility" => "manual",
      "manual" => "PRIVATE_CONNECTION"
    }

    disclosure =
      Map.update!(disclosure, "tools", fn entries ->
        [
          private_tool
          | Enum.map(entries, fn entry ->
              if entry["name"] == "fs.read_file",
                do: Map.put(entry, "manual", "PRIVATE_ANNOTATION"),
                else: entry
            end)
        ]
      end)

    prompt =
      SalixAgent.ToolPolicy.compose_session_prompt(
        "router",
        %{},
        ctx.agent_id,
        :internal,
        disclosure,
        projection,
        true
      )

    assert prompt =~ "fs.read_file"
    assert prompt =~ "A local skill."
    refute prompt =~ "private-skill"
    refute prompt =~ "PRIVATE_PLUGIN"
    refute prompt =~ "PRIVATE_CONNECTION"
    refute prompt =~ "PRIVATE_ANNOTATION"

    persist(ctx, :group, "proof-skill", "builtin", "PRIVATE_OVERRIDE")
    {:ok, overridden} = SkillProjection.materialize(ctx)

    prompt =
      SalixAgent.ToolPolicy.compose_session_prompt(
        "router",
        %{},
        ctx.agent_id,
        :internal,
        disclosure,
        overridden,
        true
      )

    refute prompt =~ "A local skill."
    refute prompt =~ "PRIVATE_OVERRIDE"
  end

  test "local built-ins support runtime reads, streams and stat without catalog writes", %{
    ctx: ctx,
    body: body
  } do
    path = SkillProjection.skill_path("proof-skill", "SKILL.md")
    assert {:ok, ^body} = SkillProjection.read(ctx, path)
    assert {:ok, stream, size} = SkillProjection.stream(ctx, path)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == body
    assert size == byte_size(body)
    assert {:ok, %{size: ^size, editable: false}} = SkillProjection.stat(ctx, path)

    assert {:ok, <<0, 255, 1, 2>>} =
             SkillProjection.read(ctx, "/.runtime/skills/proof-skill/references/proof.bin")

    assert SkillProjection.prompt_section(ctx) =~ "A local skill."
    assert {:error, "skill is read-only"} = FileBackend.prepare_write(ctx, path, "overwrite")
    assert {:error, :not_found} = SalixStore.S3.get(SalixStore.Keys.ctl_skill_scope_global())
  end

  test "user skills overlay local files and stored built-ins never become a fallback", %{
    ctx: ctx,
    root: root
  } do
    persist(ctx, :global, "proof-skill", "builtin", "old built-in")
    persist(ctx, :global, "retired-skill", "builtin", "retired built-in")
    persist(ctx, :global, "imported-skill", "imported", "imported instructions")
    assert {:ok, stored_before} = SkillStore.read_scope(:global)

    assert {:ok, local} = SkillProjection.read(ctx, "/.runtime/skills/proof-skill/SKILL.md")
    assert local =~ "Local instructions"

    assert {:error, :not_found} =
             SkillProjection.read(ctx, "/.runtime/skills/retired-skill/SKILL.md")

    persist(ctx, :group, "proof-skill", "agent_created", "user override")

    assert {:ok, "user override"} =
             SkillProjection.read(ctx, "/.runtime/skills/proof-skill/SKILL.md")

    assert {:ok, visible} = SkillProjection.materialize(ctx)
    cached_ctx = Map.put(ctx, :skill_projection_revision, visible.revision)
    assert {:ok, prepared} = SkillProjection.prepare_materialization(cached_ctx)

    empty_root = Path.join(root, "empty-release")
    File.mkdir_p!(empty_root)
    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, empty_root)
    assert {:ok, next} = SkillProjection.finish_materialization(prepared, cached_ctx)
    assert next.revision != visible.revision
    assert Enum.sort(Enum.map(next.skills, & &1["skill_id"])) == ["imported-skill", "proof-skill"]

    assert {:ok, "user override"} =
             SkillProjection.read(cached_ctx, "/.runtime/skills/proof-skill/SKILL.md")

    assert {:ok, "imported instructions"} =
             SkillProjection.read(ctx, "/.runtime/skills/imported-skill/SKILL.md")

    assert {:ok, ^stored_before} = SkillStore.read_scope(:global)
  end

  test "copying a local built-in persists all files and survives source removal", %{
    ctx: ctx,
    root: root,
    body: body
  } do
    assert {:ok, skill} = SkillProjection.get_skill(ctx, "proof-skill")

    assert {:ok, event} =
             SkillStore.prepare_group_copy(ctx, skill, %{
               "skill_id" => "my-copy",
               "name" => "My Copy"
             })

    assert {:ok, :created} = SkillStore.commit_operation("copy-local-skill", :created, [event])
    assert {:ok, copied_before} = SkillStore.read_scope(:group, ctx.group_id)

    File.rm_rf!(Path.join(root, "proof-skill"))
    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, Path.join(root, "next-release"))

    assert {:error, :not_found} =
             SkillProjection.read(ctx, "/.runtime/skills/proof-skill/SKILL.md")

    assert {:ok, ^body} = SkillProjection.read(ctx, "/.runtime/skills/my-copy/SKILL.md")

    assert {:ok, stream, 4} =
             SkillProjection.stream(ctx, "/.runtime/skills/my-copy/references/proof.bin")

    assert IO.iodata_to_binary(Enum.to_list(stream)) == <<0, 255, 1, 2>>
    assert {:ok, ^copied_before} = SkillStore.read_scope(:group, ctx.group_id)

    assert {:ok, %{editable: true}} =
             SkillProjection.stat(ctx, "/.runtime/skills/my-copy/SKILL.md")
  end

  test "role-scoped skills filter prompt listing by role while staying readable in runtime files",
       %{ctx: ctx, root: root} do
    File.mkdir_p!(Path.join(root, "router-only"))
    File.mkdir_p!(Path.join(root, "worker-only"))

    File.write!(
      Path.join(root, "router-only/SKILL.md"),
      "---\nname: router-only\nroles: router\ndescription: Router-only workflow.\n---\n\nRouter body\n"
    )

    File.write!(
      Path.join(root, "worker-only/SKILL.md"),
      "---\nname: worker-only\nroles: worker\ndescription: Worker-only workflow.\n---\n\nWorker body\n"
    )

    # Refresh cache against updated temp root
    SystemsRuntime.put_env(:salix_agent, :builtin_skills_path, root <> "/.")

    router_prompt = SkillProjection.prompt_section(Map.put(ctx, :role, "router"))
    worker_prompt = SkillProjection.prompt_section(Map.put(ctx, :role, "worker"))

    assert router_prompt =~ "router-only"
    assert router_prompt =~ "proof-skill"
    refute router_prompt =~ "worker-only"

    assert worker_prompt =~ "worker-only"
    assert worker_prompt =~ "proof-skill"
    refute worker_prompt =~ "router-only"

    # Runtime file reads remain available regardless of prompt role filtering.
    assert {:ok, content} =
             SkillProjection.read(
               Map.put(ctx, :role, "router"),
               "/.runtime/skills/worker-only/SKILL.md"
             )

    assert content =~ "Worker body"
  end

  test "custom skills with unknown frontmatter roles remain accepted by SkillFrontmatter" do
    custom =
      "---\nname: Custom Review\nroles: reviewer\ndescription: Custom team review.\n---\n\nBody\n"

    assert {:ok, meta} = SalixAgent.SkillFrontmatter.metadata(custom)
    assert meta["name"] == "Custom Review"
    assert meta["description"] == "Custom team review."

    assert {:error, _} = SalixAgent.SkillFrontmatter.parse_builtin_roles(meta["roles"])
  end

  test "shipped regular builtin skills have valid roles and concise prompt summaries" do
    SystemsRuntime.delete_env(:salix_agent, :builtin_skills_path)
    assert {:ok, %{skills: skills}} = SalixAgent.BuiltinSkills.snapshot()
    assert map_size(skills) > 0

    regular =
      skills
      |> Map.values()
      |> Enum.reject(&(&1["activation"] == "per-message"))

    assert length(regular) >= 30

    for skill <- regular do
      desc = String.trim(skill["description"] || "")
      assert desc != "", "Expected non-empty description for #{skill["skill_id"]}"

      prompt_text =
        case skill["prompt_summary"] do
          s when is_binary(s) and s != "" -> String.trim(s)
          _ -> desc
        end

      assert String.length(prompt_text) <= 160,
             "Regular builtin skill #{skill["skill_id"]} prompt summary is #{String.length(prompt_text)} chars (> 160): #{inspect(prompt_text)}"

      if not is_nil(skill["roles"]) do
        assert is_list(skill["roles"]) and skill["roles"] != []
        assert Enum.all?(skill["roles"], &(&1 in ["router", "worker"]))
      end
    end

    router_section = SkillProjection.render_prompt_section(regular, role: "router")
    worker_section = SkillProjection.render_prompt_section(regular, role: "worker")

    # Router-only skills stay out of Worker prompt
    assert router_section =~ "mini-app-builder"
    assert router_section =~ "inbound-api"
    refute worker_section =~ "mini-app-builder"
    refute worker_section =~ "inbound-api"

    # Worker-only skills stay out of Router prompt
    assert worker_section =~ "format-converter"
    assert worker_section =~ "pdfs"
    refute router_section =~ "format-converter"
    refute router_section =~ "pdfs"

    # Cross-role skills stay visible to both Router and Worker
    shared_skills =
      ~w(slack-thread-follow website-manager comma-settings github google linear notion ui-designer)

    for shared <- shared_skills do
      assert router_section =~ shared, "Expected #{shared} in router prompt"
      assert worker_section =~ shared, "Expected #{shared} in worker prompt"
    end
  end

  defp persist(ctx, layer, id, origin, body) do
    {:ok, event} =
      SkillStore.prepare_group_create(ctx, %{"skill_id" => id, "name" => id, "content" => body})

    scope = if layer == :global, do: %{"layer" => "global", "id" => nil}, else: event["scope"]
    skill = event["skill"] |> Map.put("origin", origin) |> Map.put("editable", layer != :global)
    event = event |> Map.put("scope", scope) |> Map.put("skill", skill)

    assert {:ok, :created} =
             SkillStore.commit_operation("fixture-#{layer}-#{id}", :created, [event])
  end
end
