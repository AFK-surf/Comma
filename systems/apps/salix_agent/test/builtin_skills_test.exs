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
