defmodule SalixAgent.MemoryToolsTest do
  @moduledoc """
  Willow memory tools (`internal/agent/memory_tools.go` port —
  `SalixAgent.Tools.Memory`): memory.get path normalization + line slicing,
  memory.search matching/snippet/limit semantics, memory.write allowed-path table,
  write/append modes, and the today-only-append rule. Against the Fake backend,
  driven through the same registry-backed `Tools.execute/2` path a round uses.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentWorkspace, ToolDisclosure, Tools}
  alias SalixAgent.Tools.Memory

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)

    {:ok, agent: "mem-#{System.unique_integer([:positive])}"}
  end

  # Workspace fixture: seed agent-level files; runtime state stays session-only.
  defp state_with(agent, files) do
    events =
      Enum.map(files, fn {path, content} ->
        {:ok, ev} = AgentWorkspace.prepare_write(agent, path, content)
        ev
      end)

    commit_workspace!(agent, "seed-#{System.unique_integer([:positive])}", events)
    :ok
  end

  defp commit_workspace!(agent, operation_id, events) do
    assert {:ok, _} =
             AgentWorkspace.seed_operation(agent, "memory-test:" <> operation_id, %{}, events)

    :ok
  end

  defp ctx(agent, _workspace_seed) do
    ctx =
      %{agent_id: agent, session_id: "s1", role: "router", runtime_kind: :external}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      ToolDisclosure.materialize("router", :external, ctx)
    )
  end

  # Dispatch through the ordinary registry path; role eligibility on the memory
  # entries makes them available to router sessions.
  defp run(name, args, ctx) do
    [res] =
      Tools.execute(
        [%{"id" => "t-#{System.unique_integer([:positive])}", "name" => name, "args" => args}],
        ctx
      )

    res
  end

  defp run_json(name, args, ctx) do
    res = run(name, args, ctx)
    refute res.error, "expected success, got: #{res.content}"
    {Jason.decode!(res.content), res}
  end

  describe "entries/0" do
    test "willow tool names, descriptions, schemas — schema-carrying shape" do
      assert [
               {"memory.get", _get_desc, get_schema, get_fun, get_auto_wait, get_opts},
               {"memory.search", _search_desc, search_schema, _, search_auto_wait, search_opts},
               {"memory.write", _write_desc, write_schema, _, write_auto_wait, write_opts},
               {"memory.ask_worker", _ask_desc, ask_schema, ask_fun, ask_auto_wait, ask_opts}
             ] = Memory.entries()

      assert is_function(get_fun, 2)
      assert get_auto_wait == 20
      assert search_auto_wait == 20
      assert write_auto_wait == 20
      assert get_opts == [roles: ["router"]]
      assert search_opts == [roles: ["router"]]
      assert write_opts == [roles: ["router"]]
      assert ask_opts == [roles: ["router"], safety: "read"]
      assert ask_auto_wait == 20
      assert is_function(ask_fun, 2)
      assert ask_schema["required"] == ["question"]

      assert Map.keys(ask_schema["properties"]) |> Enum.sort() == [
               "conversation_refs",
               "keywords",
               "question"
             ]

      assert ask_schema["properties"]["conversation_refs"]["items"]["required"] == [
               "conversation_id"
             ]

      assert Map.keys(ask_schema["properties"]["conversation_refs"]["items"]["properties"])
             |> Enum.sort() == ["conversation_id", "message_id"]

      assert get_schema["required"] == ["path"]

      assert Map.keys(get_schema["properties"]) |> Enum.sort() == [
               "num_lines",
               "path",
               "start_line"
             ]

      assert search_schema["required"] == ["query"]

      assert write_schema["required"] == ["path", "content"]
      assert write_schema["properties"]["mode"]["enum"] == ["write", "append"]
    end
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

    test "start_line/num_lines slicing (1-indexed window)", %{agent: a} do
      state = state_with(a, [{"/memory/index.md", "l1\nl2\nl3\nl4\nl5"}])

      {out, _} =
        run_json(
          "memory.get",
          %{"path" => "/memory/index.md", "start_line" => 2, "num_lines" => 2},
          ctx(a, state)
        )

      assert out["start_line"] == 2
      assert out["end_line"] == 3
      assert out["total_lines"] == 5
      assert out["content"] == "     2→l2\n     3→l3\n"

      # start beyond EOF: empty window, end_line == start_line - 1 (willow's
      # end==start branch).
      {out, _} =
        run_json("memory.get", %{"path" => "/memory/index.md", "start_line" => 99}, ctx(a, state))

      assert out["content"] == ""
      assert out["start_line"] == 6
      assert out["end_line"] == 5
    end

    test "missing file reports exists: false (not an error)", %{agent: a} do
      state = state_with(a, [])
      {out, _} = run_json("memory.get", %{"path" => "/memory/nope.md"}, ctx(a, state))
      assert out == %{"path" => "/memory/nope.md", "exists" => false}
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

    test "limit clamps results and flags truncated when more matches exist", %{
      agent: a,
      state: state
    } do
      {out, _} = run_json("memory.search", %{"query" => "comma", "limit" => 1}, ctx(a, state))

      assert length(out["matches"]) == 1
      assert out["truncated"] == true

      # limit at exactly the match count: not truncated
      {out, _} = run_json("memory.search", %{"query" => "comma", "limit" => 2}, ctx(a, state))
      assert length(out["matches"]) == 2
      assert out["truncated"] == false
    end

    test "no matches yields an empty list", %{agent: a, state: state} do
      {out, _} = run_json("memory.search", %{"query" => "zebra"}, ctx(a, state))
      assert out == %{"matches" => [], "truncated" => false}
    end

    test "blank query is rejected", %{agent: a, state: state} do
      res = run("memory.search", %{"query" => "   "}, ctx(a, state))
      assert res.status == "guidance"
      assert res.content =~ "missing required params: query"
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

    test "environment alias files are allowed; nested env paths are not", %{agent: a} do
      state = state_with(a, [])
      ctx = ctx(a, state)

      res =
        run(
          "memory.write",
          %{"path" => "/memory/semantic/environments/dev.md", "content" => "x"},
          ctx
        )

      refute res.error

      res =
        run(
          "memory.write",
          %{"path" => "/memory/semantic/environments/a/b.md", "content" => "x"},
          ctx
        )

      assert res.error
      assert res.content =~ "Unsupported memory path"
    end

    test "unsupported paths get willow's full guidance wording", %{agent: a} do
      res =
        run(
          "memory.write",
          %{"path" => "/memory/foo.md", "content" => "x"},
          ctx(a, state_with(a, []))
        )

      assert res.error

      assert res.content ==
               "error: Unsupported memory path. Use /memory/semantic/user.md, /memory/semantic/agent.md, " <>
                 "/memory/semantic/people.md, /memory/semantic/environments/<alias>.md, " <>
                 "/memory/index.md, /memory/scoped/<name>.md, or /memory/episodes/YYYY-MM-DD.md."
    end

    test "write mode is rejected for daily memory files", %{agent: a} do
      res =
        run(
          "memory.write",
          %{"path" => "/memory/episodes/2030-01-05.md", "content" => "x", "mode" => "write"},
          ctx(a, state_with(a, []))
        )

      assert res.error

      assert res.content ==
               "error: memory.write write mode is not allowed for daily memory; use append mode on today's file"
    end

    test "invalid mode wording", %{agent: a} do
      res =
        run(
          "memory.write",
          %{"path" => "/memory/index.md", "content" => "x", "mode" => "frob"},
          ctx(a, state_with(a, []))
        )

      assert res.error == false
      assert res.status == "guidance"
      guidance = Jason.decode!(res.content)
      assert guidance["error"] =~ "mode must be one of"
      assert guidance["error"] =~ ~s("write")
      assert guidance["error"] =~ ~s("append")
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

    test "append on a non-today daily file is rejected with willow's wording", %{agent: a} do
      res =
        run(
          "memory.write",
          %{"path" => "/memory/episodes/2020-01-01.md", "content" => "x", "mode" => "append"},
          ctx(a, state_with(a, []))
        )

      assert res.error

      assert res.content ==
               "error: memory.write append mode is only allowed for today's daily memory file"
    end

    test "append on a non-daily allowed path is rejected (append is daily-only)", %{agent: a} do
      res =
        run(
          "memory.write",
          %{"path" => "/memory/index.md", "content" => "x", "mode" => "append"},
          ctx(a, state_with(a, []))
        )

      assert res.error

      assert res.content ==
               "error: memory.write append mode is only allowed for today's daily memory file"
    end
  end
end
