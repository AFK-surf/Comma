defmodule SalixAgent.BuiltinSkillsTest do
  use ExUnit.Case, async: false

  alias SalixAgent.{FileBackend, SkillProjection, SkillStore}
  alias SalixStore.S3.Fake

  setup do
    Fake.reset()
    previous = Application.get_env(:salix_agent, :builtin_skills_path)
    root = Path.join(System.tmp_dir!(), "local-skills-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "proof-skill/references"))
    body = "---\nname: Proof Skill\ndescription: A local skill.\n---\n\nLocal instructions\n"
    File.write!(Path.join(root, "proof-skill/SKILL.md"), body)
    File.write!(Path.join(root, "proof-skill/references/proof.bin"), <<0, 255, 1, 2>>)
    Application.put_env(:salix_agent, :builtin_skills_path, root)

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
        do: Application.put_env(:salix_agent, :builtin_skills_path, previous),
        else: Application.delete_env(:salix_agent, :builtin_skills_path)

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

  test "local miniskills retain activation without preloading their catalog entries", %{
    ctx: ctx,
    root: root,
    body: body
  } do
    body =
      String.replace(
        body,
        "description: A local skill.",
        "description: A local skill.\nactivation: per-message"
      )

    File.write!(Path.join(root, "proof-skill/SKILL.md"), body)

    assert {:ok, skill} = SkillProjection.get_skill(ctx, "proof-skill")
    assert skill["activation"] == "per-message"
    refute SkillProjection.prompt_section(ctx) =~ "A local skill."
    assert {:ok, ^body} = SkillStore.read_entry(ctx.agent_id, skill["files"]["SKILL.md"])

    assert {:ok, event} =
             SkillStore.prepare_group_copy(ctx, skill, %{
               "skill_id" => "mini-copy",
               "name" => "Copied Miniskill"
             })

    assert {:ok, :created} = SkillStore.commit_operation("copy-local-mini", :created, [event])
    assert {:ok, copied} = SkillProjection.get_skill(ctx, "mini-copy")
    assert copied["activation"] == "per-message"
    refute SkillProjection.prompt_section(ctx) =~ "Copied Miniskill"
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
    Application.put_env(:salix_agent, :builtin_skills_path, empty_root)
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
    Application.put_env(:salix_agent, :builtin_skills_path, Path.join(root, "next-release"))

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

  test "matching release files retain the session revision on a fresh node", %{
    ctx: ctx,
    root: root,
    body: body
  } do
    assert {:ok, first} = SkillProjection.materialize(ctx)
    cached_ctx = Map.put(ctx, :skill_projection_revision, first.revision)
    assert {:ok, prepared} = SkillProjection.prepare_materialization(cached_ctx)

    next_root = Path.join(root, "next-release")
    File.mkdir_p!(next_root)
    File.cp_r!(Path.join(root, "proof-skill"), Path.join(next_root, "proof-skill"))

    for path <- Path.wildcard(Path.join(root, "proof-skill/**/*")), File.regular?(path) do
      File.touch!(Path.join(next_root, Path.relative_to(path, root)), File.stat!(path).mtime)
    end

    Application.put_env(:salix_agent, :builtin_skills_path, next_root)
    File.rm_rf!(Path.join(root, "proof-skill"))
    # A fresh node has no projections with local paths from the previous node.
    SkillProjection.invalidate_cache()
    assert {:ok, next} = SkillProjection.finish_materialization(prepared, cached_ctx)
    assert next.revision == first.revision

    assert {:ok, ^body} =
             SkillProjection.read(cached_ctx, "/.runtime/skills/proof-skill/SKILL.md")

    resource = Path.join(next_root, "proof-skill/references/proof.bin")

    for change <- [
          fn -> File.touch!(resource, File.stat!(resource, time: :posix).mtime + 1) end,
          fn -> File.write!(resource, <<0, 255, 1, 2, 3>>) end,
          fn -> File.rename!(resource, resource <> ".renamed") end
        ] do
      assert {:ok, before} = SkillProjection.materialize(cached_ctx)
      change.()
      Application.put_env(:salix_agent, :builtin_skills_path, root)
      assert {:ok, _} = SalixAgent.BuiltinSkills.snapshot()
      Application.put_env(:salix_agent, :builtin_skills_path, next_root)
      assert {:ok, after_change} = SkillProjection.materialize(cached_ctx)
      assert after_change.revision != before.revision
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
