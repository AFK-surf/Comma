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
  defp run(name, args, ctx) do
    [res] =
      Tools.execute(
        [
          %{
            "id" => "t-#{SystemsRuntime.Proc.unique_integer([:positive])}",
            "name" => name,
            "args" => args
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
             "/memory/semantic/people.md, /memory/semantic/environments/<alias>.md, " <>
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
end
