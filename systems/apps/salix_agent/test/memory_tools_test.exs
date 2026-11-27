defmodule SalixAgent.MemoryToolsTest do
  @moduledoc """
  Willow memory tools (`internal/agent/memory_tools.go` port —
  `SalixAgent.Tools.Memory`): memory.get path normalization + line slicing,
  memory.search matching/snippet/limit semantics, memory.write allowed-path table,
  write/append modes, and the today-only-append rule. Against the Fake backend,
  driven through the same registry-backed `Tools.execute/2` path a round uses.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, ToolDisclosure, Tools}
  alias SalixAgent.Tools.Memory

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)

    {:ok, agent: "mem-#{SystemsRuntime.Proc.unique_integer([:positive])}"}
  end

  # Workspace fixture: seed agent-level files; runtime state stays session-only.
  defp state_with(agent, files) do
    events =
      Enum.map(files, fn {path, content} ->
        {:ok, ev} = AgentWorkspace.prepare_write(agent, path, content)
        ev
      end)

    commit_workspace!(agent, "seed-#{SystemsRuntime.Proc.unique_integer([:positive])}", events)
    :ok
  end

  defp commit_workspace!(agent, operation_id, events) do
    assert {:ok, _} =
             AgentWorkspace.seed_operation(agent, "memory-test:" <> operation_id, %{}, events)

    :ok
  end

  defp ctx(agent, _workspace_seed) do
    ctx =
      %{agent_id: agent, session_id: "s1", role: "router", runtime_kind: :internal}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      ToolDisclosure.materialize("router", :internal, ctx)
    )
  end

  # Dispatch through the ordinary registry path; role eligibility on the memory
  # entries makes them available to router sessions.
  defp run(name, args, ctx, declaration \\ nil) do
    [res] =
      Tools.execute(
        [
          %{
            "id" => "t-#{SystemsRuntime.Proc.unique_integer([:positive])}",
            "name" => name,
            "args" => args,
            "ifc" => declaration
          }
        ],
        ctx
      )

    res
  end

  defp run_json(name, args, ctx) do
    res = run(name, args, ctx)
    refute res.error, "expected success, got: #{res.content}"
    {Jason.decode!(res.content), res}
  end

  describe "memory.get" do
    test "reads a /memory file with willow's line-numbered formatting", %{agent: a} do
      state = state_with(a, [{"/memory/semantic/user.md", "alpha\nbeta\ngamma"}])
      {out, _} = run_json("memory.get", %{"path" => "/memory/semantic/user.md"}, ctx(a, state))

      assert out["exists"] == true
      assert out["path"] == "/memory/semantic/user.md"
      assert out["start_line"] == 1
      assert out["end_line"] == 3
      assert out["total_lines"] == 3
      assert out["content"] == "     1→alpha\n     2→beta\n     3→gamma\n"
    end

    test "paths outside /memory are rejected, including traversal", %{agent: a} do
      state = state_with(a, [])

      res = run("memory.get", %{"path" => "/notes/x.md"}, ctx(a, state))
      assert res.error
      assert res.content == ~s(error: memory path "/notes/x.md" must stay under /memory)

      res = run("memory.get", %{"path" => "/memory/../etc/passwd"}, ctx(a, state))
      assert res.error
      assert res.content == ~s(error: memory path "/etc/passwd" must stay under /memory)

      res = run("memory.get", %{"path" => ""}, ctx(a, state))
      assert res.status == "guidance"
      assert res.content =~ "missing required params: path"
    end
  end

  describe "memory.search" do
    setup %{agent: a} do
      state =
        state_with(a, [
          {"/memory/episodes/2025-01-01.md", "Saw comma note\nnothing here"},
          {"/memory/index.md", "# Index\nComma notes live here\ntail"},
          {"/memory/raw.txt", "comma but not markdown"}
        ])

      {:ok, state: state}
    end

    test "case-insensitive matches over /memory markdown only, path-ascending, with context snippets",
         %{agent: a, state: state} do
      {out, _} = run_json("memory.search", %{"query" => "COMMA"}, ctx(a, state))

      assert out["truncated"] == false
      assert [m1, m2] = out["matches"]

      # /memory/episodes/... sorts before /memory/index.md
      assert m1["path"] == "/memory/episodes/2025-01-01.md"
      assert m1["line_start"] == 1
      assert m1["line_end"] == 2
      assert m1["snippet"] == "     1→Saw comma note\n     2→nothing here\n"

      # match on line 2 → snippet spans previous line .. next line
      assert m2["path"] == "/memory/index.md"
      assert m2["line_start"] == 1
      assert m2["line_end"] == 3
      assert m2["snippet"] == "     1→# Index\n     2→Comma notes live here\n     3→tail\n"

      # the .txt file never matches
      refute Enum.any?(out["matches"], &(&1["path"] == "/memory/raw.txt"))
    end

    test "a multi-word query matches each word, lines with more words first", %{agent: a} do
      state =
        state_with(a, [
          {"/memory/episodes/2026-11-05.md", "GitLab token saved\nunrelated"},
          {"/memory/semantic/environments/acme.md", "代码在 GitLab\n账号 Abby 的 GitLab token 在跳板机"}
        ])

      {out, _} =
        run_json("memory.search", %{"query" => "gitlab 账号 token 仓库"}, ctx(a, state))

      assert out["truncated"] == false

      assert Enum.map(out["matches"], &{&1["path"], &1["line_start"]}) == [
               # 3 words: gitlab, 账号, token
               {"/memory/semantic/environments/acme.md", 1},
               # 2 words: gitlab, token
               {"/memory/episodes/2026-11-05.md", 1},
               # 1 word: gitlab
               {"/memory/semantic/environments/acme.md", 1}
             ]

      assert hd(out["matches"])["snippet"] =~ "账号 Abby 的 GitLab token 在跳板机"

      {out, _} =
        run_json("memory.search", %{"query" => "gitlab", "limit" => 2}, ctx(a, state))

      assert length(out["matches"]) == 2
      assert out["truncated"] == true
    end
  end

  describe "memory.write — write mode" do
    test "writes an allowed semantic path and returns the vfs_write event", %{agent: a} do
      state = state_with(a, [])

      res =
        run(
          "memory.write",
          %{"path" => "/memory/semantic/user.md", "content" => "# U"},
          ctx(a, state)
        )

      refute res.error

      assert Jason.decode!(res.content) == %{
               "ok" => true,
               "path" => "/memory/semantic/user.md",
               "mode" => "write"
             }

      assert [%{"type" => "vfs_write", "path" => "/memory/semantic/user.md"}] = res.events

      # committing the event makes the content readable
      commit_workspace!(a, "semantic-write", res.events)
      assert {:ok, "# U"} = AgentWorkspace.read(a, "/memory/semantic/user.md")
    end

    # Meeting transcripts and notes spell names from it, and a person's
    # correction is kept there.
    test "writes the meeting glossary", %{agent: a} do
      res =
        run(
          "memory.write",
          %{"path" => "/memory/semantic/glossary.md", "content" => "- 金飞 → Jimmfly\n"},
          ctx(a, state_with(a, []))
        )

      refute res.error
      commit_workspace!(a, "glossary-write", res.events)
      assert {:ok, "- 金飞 → Jimmfly\n"} = AgentWorkspace.read(a, "/memory/semantic/glossary.md")
    end
  end

  describe "memory.write — append mode (today-only)" do
    test "append creates today's file, then appends with newline joining", %{agent: a} do
      today = Memory.today_episode_path()
      state = state_with(a, [])

      res =
        run(
          "memory.write",
          %{"path" => today, "content" => "first", "mode" => "append"},
          ctx(a, state)
        )

      refute res.error
      assert Jason.decode!(res.content)["mode"] == "append"
      commit_workspace!(a, "append-first", res.events)
      assert {:ok, "first"} = AgentWorkspace.read(a, today)

      # existing content without a trailing newline gets one inserted
      res =
        run(
          "memory.write",
          %{"path" => today, "content" => "second", "mode" => "append"},
          ctx(a, state)
        )

      refute res.error
      commit_workspace!(a, "append-second", res.events)
      assert {:ok, "first\nsecond"} = AgentWorkspace.read(a, today)

      # existing content WITH a trailing newline is not doubled
      {:ok, ev} = AgentWorkspace.prepare_write(a, today, "first\nsecond\n")
      commit_workspace!(a, "append-existing-newline", [ev])

      res =
        run(
          "memory.write",
          %{"path" => today, "content" => "third", "mode" => "append"},
          ctx(a, state)
        )

      refute res.error
      commit_workspace!(a, "append-third", res.events)
      assert {:ok, "first\nsecond\nthird"} = AgentWorkspace.read(a, today)
    end
  end

  describe "memory.write — rejected paths and modes" do
    for {name, args, message} <- [
          {"unsupported paths get willow's full guidance wording",
           %{"path" => "/memory/foo.md", "content" => "x"},
           "error: Unsupported memory path. Use /memory/semantic/user.md, /memory/semantic/agent.md, " <>
             "/memory/semantic/people.md, /memory/semantic/glossary.md, " <>
             "/memory/semantic/environments/<alias>.md, " <>
             "/memory/index.md, /memory/scoped/<name>.md, or /memory/episodes/YYYY-MM-DD.md."},
          {"write mode is rejected for daily memory files",
           %{"path" => "/memory/episodes/2030-01-05.md", "content" => "x", "mode" => "write"},
           "error: memory.write write mode is not allowed for daily memory; use append mode on today's file"},
          {"append on a non-today daily file is rejected with willow's wording",
           %{"path" => "/memory/episodes/2020-01-01.md", "content" => "x", "mode" => "append"},
           "error: memory.write append mode is only allowed for today's daily memory file"},
          {"append on a non-daily allowed path is rejected (append is daily-only)",
           %{"path" => "/memory/index.md", "content" => "x", "mode" => "append"},
           "error: memory.write append mode is only allowed for today's daily memory file"}
        ] do
    end
  end

  # An administrator can let only named people change memory (the Group's
  # `memory_writers`, set on the CFT Data policy page).
  describe "memory.write — who may write" do
    defmodule WritersGroupContext do
      @moduledoc false
      @behaviour SalixAgent.GroupContext

      @impl true
      def list(_tenant_id), do: []

      @impl true
      def get(group_id, tenant_id) do
        {:ok,
         %{
           "group_id" => group_id,
           "tenant_id" => tenant_id,
           "memory_writers" => SystemsRuntime.get_env(:salix_agent, :memory_writers_stub)
         }}
      end
    end

    setup do
      prev = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
      SystemsRuntime.put_env(:salix_agent, :group_context_mod, WritersGroupContext)

      on_exit(fn ->
        SystemsRuntime.put_env(:salix_agent, :group_context_mod, prev)
        SystemsRuntime.delete_env(:salix_agent, :memory_writers_stub)
      end)
    end

    defp writers(restricted, writers),
      do:
        SystemsRuntime.put_env(:salix_agent, :memory_writers_stub, %{
          "restricted" => restricted,
          "writers" => writers
        })

    defp sent_by(ctx, origin),
      do: Map.merge(ctx, %{group_id: "grp-mem", tenant_id: "ten-mem", trusted_origin: origin})

    defp person(user),
      do: %{"principal_ref" => %{"connect_id" => "imc-lark", "subject_id" => user}}

    defp write(a, origin) do
      run(
        "memory.write",
        %{"path" => "/memory/semantic/people.md", "content" => "- note"},
        a |> ctx(nil) |> sent_by(origin)
      )
    end

    test "anyone writes while the switch is off, even with people named", %{agent: a} do
      writers(false, ["provider_user|imc-lark|ou_boss"])
      refute write(a, person("ou_new")).error
    end

    test "with the switch on only a named person writes", %{agent: a} do
      writers(true, ["provider_user|imc-lark|ou_boss"])

      refute write(a, person("ou_boss")).error

      refused = write(a, person("ou_new"))
      assert refused.error
      assert refused.content =~ "only by the people an administrator named"
      assert refused.events in [nil, []]
    end

    test "Easy preserves the shared memory writer whitelist", %{agent: a} do
      writers(true, ["provider_user|imc-lark|ou_boss"])
      context = a |> ctx(nil) |> sent_by(person("ou_new")) |> Map.put(:ifc_mode, :easy)

      refused =
        run(
          "memory.write",
          %{"path" => "/memory/semantic/people.md", "content" => "note"},
          context,
          %{"sources" => []}
        )

      assert refused.error
      assert refused.content =~ "only by the people an administrator named"
      assert refused.events in [nil, []]

      allowed = sent_by(context, person("ou_boss"))

      refute run(
               "memory.write",
               %{"path" => "/memory/semantic/people.md", "content" => "note"},
               allowed,
               %{"sources" => []}
             ).error
    end

    test "with the switch on a request with nobody to name is refused", %{agent: a} do
      writers(true, ["provider_user|imc-lark|ou_boss"])
      assert write(a, %{"provider" => "internal"}).error
    end

    # The limit sits where every tool's events are checked, so file tools
    # cannot reach /memory around memory.write.
    test "with the switch on, file tools cannot change memory for anyone else", %{agent: a} do
      writers(true, ["provider_user|imc-lark|ou_boss"])
      state_with(a, [{"/memory/semantic/people.md", "- boss"}, {"/notes.md", "x"}])
      ctx = a |> ctx(nil) |> sent_by(person("ou_new"))

      for {tool, args} <- [
            {"fs.write_file", %{"path" => "/memory/semantic/people.md", "content" => "- new"}},
            {"fs.edit_file",
             %{"path" => "/memory/semantic/people.md", "old" => "boss", "new" => "x"}},
            {"fs.delete_file", %{"path" => "/memory/semantic/people.md"}},
            {"fs.copy_file", %{"from" => "/notes.md", "to" => "/memory/semantic/people.md"}},
            {"fs.move_file", %{"from" => "/memory/semantic/people.md", "to" => "/old.md"}}
          ] do
        refused = run(tool, args, ctx)
        assert refused.error, "#{tool} was allowed"
        assert refused.content =~ "only by the people an administrator named"
        assert refused.events == []
      end

      assert {:ok, "- boss"} = AgentWorkspace.read(a, "/memory/semantic/people.md")

      # Files outside memory are untouched by the switch.
      refute run("fs.write_file", %{"path" => "/notes.md", "content" => "y"}, ctx).error

      boss = a |> ctx(nil) |> sent_by(person("ou_boss"))

      refute run(
               "fs.edit_file",
               %{"path" => "/memory/semantic/people.md", "old" => "boss", "new" => "x"},
               boss
             ).error
    end

    test "a schedule writes for the named person who made it", %{agent: a} do
      writers(true, ["provider_user|imc-lark|ou_boss"])

      schedule = fn creator ->
        %{
          "provider" => "schedule",
          "ifc" => %{"principal" => "provider_user|imc-lark|" <> creator}
        }
      end

      refute write(a, schedule.("ou_boss")).error
      assert write(a, schedule.("ou_new")).error
    end

    # Only provider users can be named, so a Comma user in an internal
    # conversation is refused even though Comma knows who they are.
    test "with the switch on a Comma user in an internal conversation is refused", %{agent: a} do
      writers(true, ["provider_user|imc-lark|ou_boss"])
      origin = %{"provider" => "internal", "principal_ref" => %{"subject_id" => "usr_owner"}}

      assert write(a, origin).error

      by_ifc =
        run(
          "memory.write",
          %{"path" => "/memory/semantic/people.md", "content" => "- note"},
          a
          |> ctx(nil)
          |> sent_by(origin)
          |> Map.put(:ifc, %{"requester" => "comma_user|usr_owner"})
        )

      assert by_ifc.error
      assert by_ifc.content =~ "only by the people an administrator named"
    end

    # A writer is a provider user on one connect. The same person on another
    # connect is someone else until they are named there too, even when that
    # connect reports the same user id (one Telegram user seen by two bots).
    test "a person named on one connect writes only from that connect", %{agent: a} do
      on = fn connect, user ->
        %{"principal_ref" => %{"connect_id" => connect, "subject_id" => user}}
      end

      writers(true, ["provider_user|imc-lark|ou_boss"])

      refute write(a, person("ou_boss")).error
      assert write(a, on.("imc-telegram", "4242")).error

      writers(true, ["provider_user|imc-lark|ou_boss", "provider_user|imc-telegram|4242"])

      refute write(a, on.("imc-telegram", "4242")).error
      assert write(a, on.("imc-telegram-2", "4242")).error
    end
  end
end
