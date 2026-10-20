defmodule SalixAgent.MigrationToolsTest do
  @moduledoc """
  Importing another agent platform's export (`SalixAgent.Tools.Migration`):
  the archive keeps every file but credentials and transcripts, code places
  logs and skills, the Agent places the rest, and the import cannot finish
  while any file has no outcome. Driven through `Tools.execute/2` and
  committed like a round's tool results.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{
    AgentControl,
    AgentWorkspace,
    SkillProjection,
    ToolDisclosure,
    Tools,
    WorkspaceEvents
  }

  alias SalixStore.S3

  @session_id "ses1_0000000000000000944"

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)
    start_supervised!(S3.Fake)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      SystemsRuntime.put_env(:salix_store, :s3_backend, previous_backend)
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        name: "Router",
        role: "router",
        system_prompt: "Base prompt."
      })

    {:ok, ctx: tool_ctx(router["agent_id"], tenant_id, group_id)}
  end

  @openclaw [
    {".openclaw/workspace/SOUL.md", "You are Pip, dry and brief."},
    {".openclaw/workspace/USER.md", "Sam lives in Lisbon."},
    {".openclaw/workspace/AGENTS.md", "Always answer in Portuguese.\nUse the heartbeat tool."},
    {".openclaw/workspace/HEARTBEAT.md", "check mail"},
    {".openclaw/workspace/memory/2026-09-30.md", "Booked the dentist."},
    {".openclaw/workspace/skills/notion-sync/SKILL.md",
     "---\nname: notion-sync\ndescription: Sync notes to Notion\n---\n\nSteps."},
    {".openclaw/workspace/skills/notion-sync/references/api.md", "API notes"},
    {".openclaw/openclaw.json", ~s({"token":"secret"})},
    {".openclaw/agents/main/sessions/one.jsonl", ~s({"role":"user"})}
  ]

  test "an OpenClaw export is archived, placed and reported", %{ctx: ctx} do
    seed!(ctx, "/memory/episodes/2026-09-30.md", "Earlier note.")
    seed!(ctx, "/uploads/openclaw.zip", zip(@openclaw))

    out = run!(ctx, "migration.import", %{"path" => "/uploads/openclaw.zip"})
    base = out["import"]
    assert out["platform"] == "openclaw"
    assert "/imports/openclaw/" <> _ = base

    # Every file but the credentials and the transcript is kept unchanged.
    assert read!(ctx, base <> "/files/workspace/SOUL.md") == "You are Pip, dry and brief."

    assert read!(ctx, base <> "/files/workspace/skills/notion-sync/references/api.md") ==
             "API notes"

    refute Enum.any?(AgentWorkspace.list(ctx.agent_id, "/"), &String.ends_with?(&1, ".jsonl"))

    refute Enum.any?(
             AgentWorkspace.list(ctx.agent_id, "/"),
             &String.ends_with?(&1, "openclaw.json")
           )

    # The dated log joins the existing episode; the skill is in the catalog.
    episode = read!(ctx, "/memory/episodes/2026-09-30.md")
    assert episode =~ "Earlier note."
    assert episode =~ "Booked the dentist."
    assert {:ok, skill} = SkillProjection.get_skill(ctx, "notion-sync")
    assert skill["description"] == "Sync notes to Notion"
    assert Map.has_key?(skill["files"], "references/api.md")
    assert out["skills"] == ["skill:notion-sync"]

    assert Enum.sort(Enum.map(out["open"], & &1["path"])) ==
             ["workspace/AGENTS.md", "workspace/SOUL.md", "workspace/USER.md"]

    # Not complete while files are open.
    assert finish(ctx, base) =~ "3 files have no outcome yet"

    # A mapped target must exist.
    error =
      run_error(ctx, "migration.resolve", %{
        "import" => base,
        "entries" => [
          %{
            "path" => "workspace/USER.md",
            "status" => "mapped",
            "to" => ["/memory/semantic/user.md"]
          }
        ]
      })

    assert error =~ "does not exist"

    run!(ctx, "memory.write", %{
      "path" => "/memory/semantic/user.md",
      "content" => "Sam lives in Lisbon. Prefers Portuguese."
    })

    run!(ctx, "migration.resolve", %{
      "import" => base,
      "entries" => [
        %{
          "path" => "workspace/USER.md",
          "status" => "mapped",
          "to" => ["/memory/semantic/user.md"]
        },
        %{
          "path" => "workspace/AGENTS.md",
          "status" => "mapped",
          "to" => ["/memory/semantic/user.md"]
        }
      ]
    })

    append = %{
      "import" => base,
      "content" => "You are Pip. Be dry and brief.",
      "sources" => ["workspace/SOUL.md"]
    }

    run!(ctx, "migration.append_instructions", append)
    # A retry replaces its own section instead of appending twice.
    run!(ctx, "migration.append_instructions", append)

    {:ok, agent} = AgentControl.get(ctx.agent_id, ctx.tenant_id)
    prompt = agent["router_system_prompt"]
    assert String.starts_with?(prompt, "Base prompt.")
    assert length(String.split(prompt, "You are Pip. Be dry and brief.")) == 2

    assert finish(ctx, base) =~ "update /memory/index.md"
    run!(ctx, "memory.write", %{"path" => "/memory/index.md", "content" => "- user.md: Sam"})

    done = run!(ctx, "migration.finish", %{"import" => base})
    report = read!(ctx, base <> "/REPORT.md")
    assert done["markdown"] == report
    assert report =~ "`workspace/SOUL.md` → `instructions`"
    assert report =~ "`workspace/HEARTBEAT.md`: OpenClaw setup or heartbeat routine"
    assert report =~ "`openclaw.json`: credentials or keys are never imported"
  end

  test "Hermes bundled skills stay in the archive; the user's own become skills", %{ctx: ctx} do
    files = [
      {"memories/MEMORY.md", "Prefers tea\n§\nWorks nights"},
      {"skills/.bundled_manifest", "arxiv:abc123\n"},
      {"skills/research/arxiv/SKILL.md", "---\nname: arxiv\ndescription: Papers\n---\n"},
      {"skills/home/plant-care/SKILL.md",
       "---\nname: plant-care\ndescription: Water plants\n---\n"},
      {"config.yaml", "api_key: x"}
    ]

    seed!(ctx, "/uploads/hermes.zip", zip(files))
    out = run!(ctx, "migration.import", %{"path" => "/uploads/hermes.zip"})

    assert out["platform"] == "hermes"
    assert out["skills"] == ["skill:plant-care"]
    assert {:error, _} = SkillProjection.get_skill(ctx, "arxiv")
    assert Enum.map(out["open"], & &1["path"]) == ["memories/MEMORY.md"]
  end

  test "an oversized or unrecognised export is refused before anything is written",
       %{ctx: ctx} do
    seed!(ctx, "/uploads/big.zip", zip([{"SOUL.md", :binary.copy("a", 10_000_001)}]))
    assert run_error(ctx, "migration.import", %{"path" => "/uploads/big.zip"}) =~ "larger than"

    seed!(ctx, "/uploads/notes.zip", zip([{"notes/todo.md", "milk"}]))

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/notes.zip"}) =~
             "could not tell which platform"

    assert AgentWorkspace.list(ctx.agent_id, "/imports/") == []
  end

  test "a second instructions call reopens files only the first one held", %{ctx: ctx} do
    files = [
      {"workspace/SOUL.md", "Be warm."},
      {"workspace/IDENTITY.md", "Name: Pip"},
      {"openclaw.json", "{}"}
    ]

    seed!(ctx, "/uploads/o.zip", zip(files))
    %{"import" => base} = run!(ctx, "migration.import", %{"path" => "/uploads/o.zip"})

    run!(ctx, "migration.append_instructions", %{
      "import" => base,
      "content" => "Be warm.",
      "sources" => ["workspace/SOUL.md"]
    })

    out =
      run!(ctx, "migration.append_instructions", %{
        "import" => base,
        "content" => "Your name is Pip.",
        "sources" => ["workspace/IDENTITY.md"]
      })

    assert out["reopened"] == 1
    assert finish(ctx, base) =~ "workspace/SOUL.md"

    # Instructions change only at a person's request in Comma.
    from_channel = Map.put(ctx, :trusted_origin, %{"provider" => "schedule"})

    assert run_error(from_channel, "migration.append_instructions", %{
             "import" => base,
             "content" => "x",
             "sources" => ["workspace/SOUL.md"]
           }) =~ "only a person"
  end

  test "a zip whose headers understate its size is refused while inflating", %{ctx: ctx} do
    seed!(ctx, "/uploads/lie.zip", lying_zip("SOUL.md", :binary.copy("a", 10_000_001)))
    assert run_error(ctx, "migration.import", %{"path" => "/uploads/lie.zip"}) =~ "larger than"
    assert AgentWorkspace.list(ctx.agent_id, "/imports/") == []
  end

  test "where IFC labels files, the import keeps the zip's audience and creates no skill",
       %{ctx: ctx} do
    ctx =
      ctx |> Map.put(:ifc, %{"items" => []}) |> Map.put(:ifc_evidence, %{"sources_label" => []})

    seed!(ctx, "/uploads/o.zip", zip(@openclaw))
    out = run!(ctx, "migration.import", %{"path" => "/uploads/o.zip"})

    assert out["skills"] == []
    assert {:error, _} = SkillProjection.get_skill(ctx, "notion-sync")

    # The upload carried no audience, so what came out of it is private to the Agent.
    assert AgentWorkspace.label(ctx.agent_id, out["import"] <> "/files/workspace/SOUL.md") ==
             AgentWorkspace.label(ctx.agent_id, "/memory/episodes/2026-09-30.md")

    assert AgentWorkspace.label(ctx.agent_id, out["import"] <> "/files/workspace/SOUL.md") ==
             SalixAgent.IFC.FileLabels.join_private([])
  end

  # A stored zip with the declared sizes in both headers patched to 1 byte.
  defp lying_zip(name, body) do
    bin = zip([{name, body}])
    real = <<byte_size(body)::little-32>>
    :binary.replace(bin, real, <<1::little-32>>, [:global])
  end

  defp finish(ctx, base), do: run_error(ctx, "migration.finish", %{"import" => base})

  defp zip(files) do
    entries = Enum.map(files, fn {path, body} -> {String.to_charlist(path), body} end)
    {:ok, {_name, bin}} = :zip.create(~c"export.zip", entries, [:memory])
    bin
  end

  defp seed!(ctx, path, body) do
    {:ok, event} = AgentWorkspace.prepare_write(ctx.agent_id, path, body)

    {:ok, _} =
      AgentWorkspace.seed_operation(
        ctx.agent_id,
        "seed-#{SystemsRuntime.Proc.unique_integer([:positive])}",
        %{},
        [event]
      )
  end

  defp read!(ctx, path) do
    {:ok, body} = AgentWorkspace.read(ctx.agent_id, path)
    body
  end

  defp run!(ctx, name, args) do
    result = execute(ctx, name, args)
    refute result.error, "#{name} failed: #{result.content}"

    assert {:ok, _} =
             WorkspaceEvents.commit_result(ctx.agent_id, @session_id, result, "tool-result")

    Jason.decode!(result.content)
  end

  defp run_error(ctx, name, args) do
    result = execute(ctx, name, args)
    assert result.error, "#{name} unexpectedly succeeded: #{result.content}"
    result.content
  end

  defp execute(ctx, name, args) do
    [result] =
      Tools.execute(
        [
          %{
            "id" => "mig-#{SystemsRuntime.Proc.unique_integer([:positive])}",
            "name" => name,
            "args" => args
          }
        ],
        ctx
      )

    result
  end

  defp tool_ctx(agent_id, tenant_id, group_id) do
    ctx =
      %{
        agent_id: agent_id,
        tenant_id: tenant_id,
        group_id: group_id,
        session_id: @session_id,
        role: "router",
        runtime_kind: :internal,
        trusted_origin: %{
          "principal_ref" => %{"subject_id" => "usr_owner"},
          "source_actor_type" => "user"
        }
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("router", :internal, ctx))
  end
end
