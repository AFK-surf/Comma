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

  defmodule RestrictedMemoryGroupContext do
    @moduledoc false
    @behaviour SalixAgent.GroupContext

    @impl true
    def list(_tenant_id), do: []

    @impl true
    def get(group_id, tenant_id),
      do:
        {:ok,
         %{
           "group_id" => group_id,
           "tenant_id" => tenant_id,
           "memory_writers" => %{"restricted" => true, "writers" => []}
         }}
  end

  test "an export with dated logs is refused when the sender may not change memory",
       %{ctx: ctx} do
    previous = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    SystemsRuntime.put_env(:salix_agent, :group_context_mod, RestrictedMemoryGroupContext)
    on_exit(fn -> SystemsRuntime.put_env(:salix_agent, :group_context_mod, previous) end)

    seed!(ctx, "/uploads/openclaw.zip", zip(@openclaw))

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/openclaw.zip"}) =~
             "only by the people an administrator named"

    assert AgentWorkspace.list(ctx.agent_id, "/imports/") == []
    assert AgentWorkspace.list(ctx.agent_id, "/memory/") == []
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

  test "a zip larger than the 10 MiB full-read cap is imported", %{ctx: ctx} do
    part = noise(5_600_000, 1)

    archive =
      stored_zip([
        {".openclaw/workspace/SOUL.md", "You are Pip."},
        {".openclaw/workspace/a.bin", part},
        {".openclaw/workspace/b.bin", part}
      ])

    assert byte_size(archive) > 10 * 1024 * 1024
    seed_stream!(ctx, "/uploads/large.zip", archive)

    %{"import" => base} = run!(ctx, "migration.import", %{"path" => "/uploads/large.zip"})

    assert read!(ctx, base <> "/files/workspace/SOUL.md") == "You are Pip."
    assert read!(ctx, base <> "/files/workspace/a.bin") == part
  end

  test "an archive over the limit is refused from its size, before any body read",
       %{ctx: ctx} do
    limit = SalixAgent.Migration.limits().archive_bytes
    {:ok, event} = AgentWorkspace.prepare_write(ctx.agent_id, "/uploads/huge.zip", "small")

    event =
      event
      |> Map.put("size", limit + 1)
      |> put_in(["ref", "size"], limit + 1)

    seed_event!(ctx, event)

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/huge.zip"}) =~
             "larger than 50 MB"

    assert AgentWorkspace.list(ctx.agent_id, "/imports/") == []
  end

  test "a tar.gz export keeps real files and drops links, noise and unsafe names",
       %{ctx: ctx} do
    chinese = ".openclaw/workspace/" <> String.duplicate("记忆", 20) <> ".md"
    long = ".openclaw/workspace/" <> String.duplicate("long-", 25) <> ".md"

    archive =
      :zlib.gzip(
        tar([
          tar_file("./.openclaw/workspace/SOUL.md", "You are Pip."),
          tar_file("./.openclaw/workspace/._SOUL.md", <<0, 5, 22, 7>>),
          tar_file("./.openclaw/workspace/link.md", "", ?2, "/etc/passwd"),
          tar_file("../escape.md", "outside"),
          pax_file(chinese, "中文路径"),
          gnu_long_file(long, "long name")
        ])
      )

    seed!(ctx, "/uploads/export.tar.gz", archive)
    %{"import" => base} = run!(ctx, "migration.import", %{"path" => "/uploads/export.tar.gz"})

    files = base <> "/files/"
    assert read!(ctx, files <> "workspace/SOUL.md") == "You are Pip."

    assert read!(ctx, files <> String.replace_prefix(chinese, ".openclaw/", "")) == "中文路径"
    assert read!(ctx, files <> String.replace_prefix(long, ".openclaw/", "")) == "long name"

    listed = AgentWorkspace.list(ctx.agent_id, files)
    refute Enum.any?(listed, &String.ends_with?(&1, "._SOUL.md"))
    refute Enum.any?(listed, &String.ends_with?(&1, "link.md"))
    refute Enum.any?(listed, &String.ends_with?(&1, "escape.md"))

    manifest = ctx |> read!(base <> "/manifest.json") |> Jason.decode!()

    assert %{"status" => "skipped", "reason" => "unsafe file name"} =
             Enum.find(manifest["entries"], &(&1["path"] == "../escape.md"))
  end

  test "a plain tar and a tar.gz larger than the full-read cap are imported", %{ctx: ctx} do
    seed!(
      ctx,
      "/uploads/plain.tar",
      tar([tar_file("memories/MEMORY.md", "Prefers tea"), tar_file("config.yaml", "a: 1")])
    )

    assert %{"platform" => "hermes"} =
             run!(ctx, "migration.import", %{"path" => "/uploads/plain.tar"})

    part = noise(5_600_000, 2)

    archive =
      :zlib.gzip(
        tar([
          tar_file(".openclaw/workspace/SOUL.md", "You are Pip."),
          tar_file(".openclaw/workspace/a.bin", part),
          tar_file(".openclaw/workspace/b.bin", part)
        ])
      )

    assert byte_size(archive) > 10 * 1024 * 1024
    seed_stream!(ctx, "/uploads/large.tgz", archive)

    %{"import" => base} = run!(ctx, "migration.import", %{"path" => "/uploads/large.tgz"})
    assert read!(ctx, base <> "/files/workspace/b.bin") == part
  end

  test "a gzip bomb, an oversized tar member and gzip of non-tar are refused", %{ctx: ctx} do
    seed!(ctx, "/uploads/bomb.tar.gz", :zlib.gzip(:binary.copy(<<0>>, 110_000_000)))

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/bomb.tar.gz"}) =~
             "expands to more than"

    big = :zlib.gzip(tar([tar_file("workspace/big.bin", :binary.copy("a", 10_000_001))]))
    seed!(ctx, "/uploads/big.tar.gz", big)
    error = run_error(ctx, "migration.import", %{"path" => "/uploads/big.tar.gz"})
    assert error =~ "larger than"
    assert error =~ "big.bin"

    seed!(ctx, "/uploads/notes.txt.gz", :zlib.gzip("plain text, not a tar"))

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/notes.txt.gz"}) =~
             "not a readable"

    assert AgentWorkspace.list(ctx.agent_id, "/imports/") == []
  end

  test "tar sizes from a PAX record and in GNU base-256 are read", %{ctx: ctx} do
    pax = pax_record("size", "11")
    notes = "Works nights"

    archive =
      tar([
        tar_header("PaxHeaders/entry", byte_size(pax), ?x, ""),
        pax,
        tar_padding(byte_size(pax)),
        tar_header("memories/MEMORY.md", 0, ?0, ""),
        "Prefers tea",
        tar_padding(11),
        tar_header("memories/notes.md", <<0x80, byte_size(notes)::88>>, ?0, ""),
        notes,
        tar_padding(byte_size(notes)),
        tar_file("config.yaml", "a: 1")
      ])

    seed!(ctx, "/uploads/sizes.tar", archive)
    %{"import" => base} = run!(ctx, "migration.import", %{"path" => "/uploads/sizes.tar"})

    assert read!(ctx, base <> "/files/memories/MEMORY.md") == "Prefers tea"
    assert read!(ctx, base <> "/files/memories/notes.md") == notes
  end

  test "a tar with too many files and a truncated gzip are refused", %{ctx: ctx} do
    many = tar(for index <- 1..2_001, do: tar_file("memories/#{index}.md", ""))
    seed!(ctx, "/uploads/many.tar", many)

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/many.tar"}) =~
             "more than 2000 files"

    whole = :zlib.gzip(tar([tar_file("memories/MEMORY.md", "Prefers tea")]))
    seed!(ctx, "/uploads/cut.tar.gz", binary_part(whole, 0, byte_size(whole) - 6))

    assert run_error(ctx, "migration.import", %{"path" => "/uploads/cut.tar.gz"}) =~
             "the archive is corrupt"

    assert AgentWorkspace.list(ctx.agent_id, "/imports/") == []
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

  defp stored_zip(files) do
    entries = Enum.map(files, fn {path, body} -> {String.to_charlist(path), body} end)

    {:ok, {_name, bin}} =
      :zip.create(~c"export.zip", entries, [:memory, {:uncompress, :all}])

    bin
  end

  # Seeded bytes that gzip cannot shrink.
  defp noise(size, seed) do
    :crypto.crypto_one_time(
      :aes_256_ctr,
      <<seed::256>>,
      <<0::128>>,
      :binary.copy(<<0>>, size),
      true
    )
  end

  defp tar(members), do: IO.iodata_to_binary([members, :binary.copy(<<0>>, 1_024)])

  defp tar_file(name, body, type \\ ?0, link \\ "") do
    [tar_header(name, byte_size(body), type, link), body, tar_padding(byte_size(body))]
  end

  defp pax_file(path, body) do
    record = pax_record("path", path)

    [
      tar_header("PaxHeaders/entry", byte_size(record), ?x, ""),
      record,
      tar_padding(byte_size(record)),
      tar_file("short-name", body)
    ]
  end

  defp gnu_long_file(path, body) do
    name = path <> <<0>>

    [
      tar_header("././@LongLink", byte_size(name), ?L, ""),
      name,
      tar_padding(byte_size(name)),
      tar_file("short-name", body)
    ]
  end

  # The length counts the whole record, its own digits included.
  defp pax_record(key, value) do
    rest = byte_size(" #{key}=#{value}\n")
    digits = String.length(Integer.to_string(rest))

    digits =
      if String.length(Integer.to_string(rest + digits)) > digits, do: digits + 1, else: digits

    "#{rest + digits} #{key}=#{value}\n"
  end

  defp tar_padding(size), do: :binary.copy(<<0>>, rem(512 - rem(size, 512), 512))

  defp tar_header(name, size, type, link) do
    head = [
      tar_field(name, 100),
      tar_octal(0o644, 8),
      tar_octal(0, 8),
      tar_octal(0, 8),
      if(is_binary(size), do: size, else: tar_octal(size, 12)),
      tar_octal(0, 12)
    ]

    tail = [
      <<type>>,
      tar_field(link, 100),
      "ustar",
      <<0>>,
      "00",
      :binary.copy(<<0>>, 247)
    ]

    blank = IO.iodata_to_binary([head, "        ", tail])
    sum = blank |> :binary.bin_to_list() |> Enum.sum()
    checksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>>
    IO.iodata_to_binary([head, checksum, tail])
  end

  defp tar_field(value, size), do: value <> :binary.copy(<<0>>, size - byte_size(value))

  defp tar_octal(value, size) do
    String.pad_leading(Integer.to_string(value, 8), size - 1, "0") <> <<0>>
  end

  defp seed!(ctx, path, body) do
    {:ok, event} = AgentWorkspace.prepare_write(ctx.agent_id, path, body)
    seed_event!(ctx, event)
  end

  defp seed_stream!(ctx, path, body) do
    chunks =
      Stream.unfold(body, fn
        <<>> -> nil
        <<chunk::binary-size(1_048_576), rest::binary>> -> {chunk, rest}
        rest -> {rest, <<>>}
      end)

    {:ok, event} = AgentWorkspace.prepare_write_stream(ctx.agent_id, path, chunks)
    seed_event!(ctx, event)
  end

  defp seed_event!(ctx, event) do
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
