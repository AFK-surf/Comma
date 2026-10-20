defmodule SalixAgent.ScriptRunTest do
  require SystemsRuntime.Proc

  @moduledoc """
  `script.run` / `script.run_file` against the pinned spinfoam binary: the
  program is compiled by the embedded compiler and run once as a script
  object of this node's Host, with `salix.call` going back through the
  session tool dispatch. Every test skips itself without the binary.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{AgentWorkspace, ScriptRun, SessionToolDispatch, ToolDisclosure, Tools}
  alias SalixAgent.Loops.Host
  alias SalixAgent.SpinfoamFixture, as: Fixture

  @moduletag :spinfoam
  @moduletag skip:
               if(SalixAgent.SpinfoamFixture.available?(),
                 do: false,
                 else: "spinfoam binary unavailable"
               )

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> SystemsRuntime.put_env(:salix_store, :s3_backend, prev) end)

    await(fn -> Host.status().available end)

    agent = SalixAgent.TestSupport.new_agent_id()
    big = String.duplicate("x", 20_000)

    events = [
      write_event(agent, "/notes/source.txt", "alpha from vfs"),
      write_event(agent, "/notes/big.txt", big),
      write_event(agent, "/scripts/env.c", Fixture.script_env_program())
    ]

    commit_workspace!(agent, "script-run-seed", events)

    ctx =
      %{agent_id: agent, role: "worker", runtime_kind: :script}
      |> SalixAgent.TestSupport.with_plugin_projection()

    {:ok,
     agent: agent,
     ctx: Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :script, ctx))}
  end

  test "a program's script.result and script.log become the tool content", %{ctx: ctx} do
    out = Tools.script_run(%{"source" => Fixture.script_log_program()}, ctx)
    assert out == "7\n--- console ---\nfirst line\nsecond line"
  end

  test "salix.call reaches canonical tools through the session dispatch", %{ctx: ctx} do
    call = Jason.encode!(%{"tool" => "help", "args" => %{"tool" => "fs.read_file"}})

    assert {:tool_observations, content, [], [%{tool_name: "help", status: "completed"}]} =
             Tools.script_run(%{"source" => Fixture.script_call_program(call, pick: "name")}, ctx)

    assert Jason.decode!(content) == "fs.read_file"
  end

  test "a tool outside the disclosure and a recursive script.run are refused", %{ctx: ctx} do
    unknown = Jason.encode!(%{"tool" => "nope.tool", "args" => %{}})

    assert {:tool_failure, _diagnostic, _class, _visibility, _summary, [], _observations} =
             Tools.script_run(%{"source" => Fixture.script_call_program(unknown)}, ctx)

    recursive = Jason.encode!(%{"tool" => "script.run", "args" => %{"source" => "x"}})

    assert %{"ok" => false, "error" => error} =
             Tools.script_run(%{"source" => Fixture.script_call_program(recursive)}, ctx)
             |> decode_content()

    assert error =~ "cannot be called from inside a script"
  end

  test "a capability name outside the three is SF_DENIED before any host call", %{ctx: ctx} do
    call = Jason.encode!(%{"message" => "x"})

    assert {:tool_failure, diagnostic, _, _, nil, [], []} =
             Tools.script_run(
               %{"source" => Fixture.script_call_program(call, capability: "loop.log")},
               ctx
             )

    assert diagnostic =~ "script exited with code -4"
  end

  test "script.run_file reads the program from the VFS and exposes env as config.env", %{ctx: ctx} do
    out =
      Tools.Web.script_run_file(
        %{
          "path" => "/scripts/env.c",
          "env" => [
            %{"name" => "GREETING", "value" => "Hello"},
            %{"name" => "NAME", "value" => "World"}
          ]
        },
        ctx
      )

    assert Jason.decode!(out) == "Hello, World"

    assert_raise RuntimeError, ~r/duplicate name "A"/, fn ->
      Tools.Web.script_run_file(
        %{
          "path" => "/scripts/env.c",
          "env" => [%{"name" => "A", "value" => "1"}, %{"name" => "A", "value" => "2"}]
        },
        ctx
      )
    end

    assert_raise RuntimeError, ~r/no such file/, fn ->
      Tools.Web.script_run_file(%{"path" => "/scripts/missing.c"}, ctx)
    end
  end

  test "journal events of completed host calls survive the program's own failure", %{ctx: ctx} do
    call =
      Jason.encode!(%{
        "tool" => "fs.write_file",
        "args" => %{"path" => "/out/from-script.txt", "content" => "written"}
      })

    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, events, observations} =
             Tools.script_run(%{"source" => Fixture.script_call_program(call, exit_code: 2)}, ctx)

    assert diagnostic =~ "script exited with code 2"

    assert Enum.any?(
             events,
             &(&1["type"] == "vfs_write" and &1["path"] == "/out/from-script.txt")
           )

    assert [%{tool_name: "fs.write_file", status: "completed"}] = observations
  end

  test "the wall limit stops a program that never returns and releases its object", %{ctx: ctx} do
    previous = SystemsRuntime.get_env(:salix_agent, :script_wall_timeout_ms)
    SystemsRuntime.put_env(:salix_agent, :script_wall_timeout_ms, 500)
    on_exit(fn -> restore_env(:script_wall_timeout_ms, previous) end)

    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [], []} =
             Tools.script_run(%{"source" => Fixture.script_sleep_program(60_000)}, ctx)

    assert diagnostic =~ "script wall time limit exceeded: 500ms"
    assert Host.status().script_objects == 0
  end

  # ---- helpers -----------------------------------------------------------------

  defp decode_content({:tool_observations, content, _events, _observations}),
    do: Jason.decode!(content)

  defp decode_content({content, _events}) when is_binary(content), do: Jason.decode!(content)
  defp decode_content(content) when is_binary(content), do: Jason.decode!(content)

  defp write_event(agent, path, content) do
    {:ok, event} = AgentWorkspace.prepare_write(agent, path, content)
    event
  end

  defp commit_workspace!(agent, operation, events) do
    {:ok, _} = AgentWorkspace.seed_operation(agent, operation, %{}, events)
    :ok
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)

  defp await(fun, retries \\ 1200) do
    cond do
      fun.() -> true
      retries == 0 -> flunk("condition never held")
      true -> SystemsRuntime.Proc.sleep(25) && await(fun, retries - 1)
    end
  end
end
