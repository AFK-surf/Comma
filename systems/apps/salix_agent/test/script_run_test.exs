defmodule SalixAgent.ScriptRunTest do
  @moduledoc """
  `script.run` / `script.run_file` against the pinned spinfoam binary: the
  program is compiled by the embedded compiler and run once as a script
  object of this node's Host, with `salix.call` going back through the
  session tool dispatch. Every test skips itself without the binary.
  """
  use ExUnit.Case, async: false

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
    prev = Application.get_env(:salix_store, :s3_backend)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    on_exit(fn -> Application.put_env(:salix_store, :s3_backend, prev) end)

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

  test "a compiled program selects a source through decide using integer confidence", %{ctx: ctx} do
    SalixAgent.DecideFixture.start_provider()
    group = SalixStore.Ids.group_id_from_agent!(ctx.agent_id)

    ctx =
      Map.merge(ctx, %{
        group_id: group,
        tenant_id: SalixStore.Ids.tenant_id_from_group!(group),
        session_id: SalixStore.Ids.new_session_id(),
        billing_context: %{}
      })

    assert {:tool_observations, content, [], [%{tool_name: "decide", status: "completed"}]} =
             Tools.script_run(%{"source" => SalixAgent.Decide.example_program(:script)}, ctx)

    assert Jason.decode!(content) == %{"source" => "meetings"}
    assert_receive {:decision_request, "/v1/systemone", _, _}

    uncertain =
      SalixAgent.Decide.example_program(:script)
      |> String.replace("Find meeting decisions", "uncertain")

    assert {:tool_observations, content, [], _} = Tools.script_run(%{"source" => uncertain}, ctx)
    assert Jason.decode!(content) == %{"source" => "none"}
  end

  test "a program's script.result and script.log become the tool content", %{ctx: ctx} do
    out = Tools.script_run(%{"source" => Fixture.script_log_program()}, ctx)
    assert out == "7\n--- console ---\nfirst line\nsecond line"
  end

  test "a program without a result reports its exit code; a non-zero return fails", %{ctx: ctx} do
    assert Tools.script_run(%{"source" => Fixture.exit_program(0)}, ctx) == ~s({"exit_code":0})

    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [], []} =
             Tools.script_run(%{"source" => Fixture.exit_program(3)}, ctx)

    assert diagnostic =~ "script exited with code 3"
  end

  test "a build failure returns the compiler's diagnostics", %{ctx: ctx} do
    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [], []} =
             Tools.script_run(%{"source" => "int main(void) { return missing; }"}, ctx)

    assert diagnostic =~ "script build:"
    assert diagnostic =~ "missing"
  end

  test "a guest fault fails the call with the runtime's reason", %{ctx: ctx} do
    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [], []} =
             Tools.script_run(%{"source" => Fixture.script_fault_program()}, ctx)

    assert diagnostic =~ "script fault:"
  end

  test "salix.call reaches canonical tools through the session dispatch", %{ctx: ctx} do
    call = Jason.encode!(%{"tool" => "help", "args" => %{"tool" => "fs.read_file"}})

    assert {:tool_observations, content, [], [%{tool_name: "help", status: "completed"}]} =
             Tools.script_run(%{"source" => Fixture.script_call_program(call, pick: "name")}, ctx)

    assert Jason.decode!(content) == "fs.read_file"
  end

  test "a nested tool failure is data to the program and a model-only failure to the round", %{
    ctx: ctx
  } do
    # The program sees {"ok": false, "error"} and keeps running; the round
    # still gets the nested tool's model-only diagnostic, as with the
    # JavaScript host, so a swallowed failure cannot pass as success.
    call = Jason.encode!(%{"tool" => "fs.read_file", "args" => %{"path" => "/nope.txt"}})

    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [],
            [%{tool_name: "fs.read_file", status: "error"}]} =
             Tools.script_run(%{"source" => Fixture.script_call_program(call)}, ctx)

    assert diagnostic =~ "no such file"
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

  test "tool content larger than 16 KiB is cut and marked instead of failing the call", %{
    ctx: ctx
  } do
    call = Jason.encode!(%{"tool" => "fs.read_file", "args" => %{"path" => "/notes/big.txt"}})

    assert %{"ok" => true, "truncated" => true, "value" => value} =
             Tools.script_run(%{"source" => Fixture.script_call_program(call)}, ctx)
             |> decode_content()

    assert is_binary(value) and byte_size(value) < 16 * 1024
  end

  test "a large result made of escapes is cut by its encoded size, not its raw bytes", %{
    ctx: ctx,
    agent: agent
  } do
    commit_workspace!(agent, "script-run-quotes", [
      write_event(agent, "/notes/quotes.txt", String.duplicate("\"", 20_000))
    ])

    call = Jason.encode!(%{"tool" => "fs.read_file", "args" => %{"path" => "/notes/quotes.txt"}})

    assert %{"ok" => true, "truncated" => true, "value" => value} =
             Tools.script_run(%{"source" => Fixture.script_call_program(call)}, ctx)
             |> decode_content()

    # The file tool's result is a map, so the guest sees its encoded text.
    assert String.starts_with?(value, ~s({"content":"\\"\\"))

    assert byte_size(Jason.encode!(%{"ok" => true, "value" => value, "truncated" => true})) <
             16 * 1024
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

  test "nested host tools reuse the outer admission lane at a per-tenant limit of one", %{
    ctx: ctx
  } do
    previous_global = Application.get_env(:salix_agent, :dependency_max_children)
    previous_tenant = Application.get_env(:salix_agent, :dependency_max_children_per_tenant)
    Application.put_env(:salix_agent, :dependency_max_children, 1)
    Application.put_env(:salix_agent, :dependency_max_children_per_tenant, 1)

    on_exit(fn ->
      restore_env(:dependency_max_children, previous_global)
      restore_env(:dependency_max_children_per_tenant, previous_tenant)
    end)

    call = Jason.encode!(%{"tool" => "help", "args" => %{"tool" => "fs.read_file"}})

    [result] =
      SessionToolDispatch.execute(
        [
          %{
            id: "script-single-lane",
            name: "script.run",
            args: %{"source" => Fixture.script_call_program(call, pick: "name")}
          }
        ],
        Map.merge(ctx, %{visible_reply_phase: :clean, visible_reply_guard: :clean})
      )

    refute result.error
    assert Jason.decode!(result.content) == "fs.read_file"
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
    previous = Application.get_env(:salix_agent, :script_wall_timeout_ms)
    Application.put_env(:salix_agent, :script_wall_timeout_ms, 500)
    on_exit(fn -> restore_env(:script_wall_timeout_ms, previous) end)

    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [], []} =
             Tools.script_run(%{"source" => Fixture.script_sleep_program(60_000)}, ctx)

    assert diagnostic =~ "script wall time limit exceeded: 500ms"
    assert Host.status().script_objects == 0
  end

  test "a program that exits after a dropped notification is still an exit, not a wall violation",
       %{ctx: ctx} do
    # The wall timer's `sf.object.stop` reads the object's terminal state:
    # an object that exited just before the timer fired is reported as its
    # exit. A 30 ms program with a 100 ms wall exercises the timer path
    # only when the notification is late, so run it several times.
    previous = Application.get_env(:salix_agent, :script_wall_timeout_ms)
    Application.put_env(:salix_agent, :script_wall_timeout_ms, 100)
    on_exit(fn -> restore_env(:script_wall_timeout_ms, previous) end)

    for _ <- 1..5 do
      assert Tools.script_run(%{"source" => Fixture.script_sleep_program(30)}, ctx) ==
               ~s({"exit_code":0})
    end
  end

  test "a script owner that dies takes its object with it", %{ctx: ctx} do
    parent = self()

    owner =
      spawn(fn ->
        send(parent, {:started, self()})
        Tools.script_run(%{"source" => Fixture.script_sleep_program(60_000)}, ctx)
      end)

    assert_receive {:started, ^owner}, 5_000
    await(fn -> Host.status().script_objects == 1 end)
    Process.exit(owner, :kill)
    await(fn -> Host.status().script_objects == 0 end)
    assert Enum.all?(Host.objects(), fn {_id, ref} -> ref[:kind] != :script end)
  end

  test "the per-node script capacity fails closed without touching Loop objects", %{ctx: ctx} do
    previous = Application.get_env(:salix_agent, :script_max_objects)
    Application.put_env(:salix_agent, :script_max_objects, 0)
    on_exit(fn -> restore_env(:script_max_objects, previous) end)

    assert {:tool_failure, diagnostic, "tool_error", "model_only", nil, [], []} =
             Tools.script_run(%{"source" => Fixture.exit_program(0)}, ctx)

    assert diagnostic =~ "script runtime busy on this node"
  end

  test "a burst of concurrent loads cannot overshoot the per-node script capacity", %{ctx: ctx} do
    previous = Application.get_env(:salix_agent, :script_max_objects)
    Application.put_env(:salix_agent, :script_max_objects, 1)
    on_exit(fn -> restore_env(:script_max_objects, previous) end)

    elf = Fixture.compile!(Fixture.script_sleep_program(60_000))
    parent = self()
    capabilities = Enum.map(ScriptRun.capabilities(), &%{"name" => &1, "arguments" => %{}})

    # Suspend the Host so the twelve loads arrive as one burst, before any
    # load reply could have made an object resident.
    :ok = :sys.suspend(Host)

    owners =
      for n <- 1..12 do
        spawn_link(fn ->
          ref = %{kind: :script, owner: self(), agent_id: ctx.agent_id}

          send(
            parent,
            {:loaded, n, Host.object_load(ref, elf, %{"kind" => "script"}, capabilities)}
          )

          receive do
            :release -> :ok
          end
        end)
      end

    await(fn ->
      {:messages, messages} = Process.info(Process.whereis(Host), :messages)
      length(messages) >= 12
    end)

    :ok = :sys.resume(Host)

    results =
      for _ <- owners,
          do:
            (receive do
               {:loaded, _n, result} -> result
             end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :script_capacity})) == 11
    assert Host.status().script_objects == 1
    assert Host.status().script_loads == 0

    for owner <- owners, do: send(owner, :release)
    await(fn -> Host.status().script_objects == 0 end)
  end

  test "the script guide example compiles" do
    program = ScriptRun.Sdk.example_program()
    elf = Fixture.compile!(program)
    assert binary_part(elf, 0, 4) == <<0x7F, "ELF">>
  end

  test "the bundled skill scripts compile and run: the picker draws deterministically, the validator validates",
       %{ctx: ctx} do
    root = Path.expand("../../../../resources/salix-system-files/skills", __DIR__)
    picker = File.read!(Path.join(root, "ui-designer/scripts/pick_random_reference.c"))
    validator = File.read!(Path.join(root, "website-manager/scripts/validate_website.c"))

    commit_workspace!(ctx.agent_id, "skill-scripts", [
      write_event(ctx.agent_id, "/skills/pick.c", picker),
      write_event(ctx.agent_id, "/skills/validate.c", validator),
      write_event(
        ctx.agent_id,
        "/.salix/websites/docs/_api.json",
        Jason.encode!(%{
          "storage" => %{
            "rules" => [%{"key_prefix" => "", "operations" => ["write"], "require_auth" => false}]
          },
          "llm" => %{"enabled" => "yes"}
        })
      )
    ])

    seeded = [%{"name" => "SEED", "value" => "no-style"}]

    first =
      Tools.Web.script_run_file(%{"path" => "/skills/pick.c", "env" => seeded}, ctx)
      |> Jason.decode!()

    second =
      Tools.Web.script_run_file(%{"path" => "/skills/pick.c", "env" => seeded}, ctx)
      |> Jason.decode!()

    assert first == second
    assert %{"slug" => "runwayml", "reference_count" => 68, "seed" => "no-style"} = first

    env = [
      %{"name" => "SITE_NAME", "value" => "docs"},
      %{"name" => "REQUIRE_API_JSON", "value" => "true"}
    ]

    assert {:tool_observations, content, [], [%{tool_name: "fs.read_file"}]} =
             Tools.Web.script_run_file(%{"path" => "/skills/validate.c", "env" => env}, ctx)

    report = Jason.decode!(content)
    assert report["ok"] == false
    assert report["website_root"] == "/.salix/websites/docs"

    assert report["checks"]["api_json"] == %{
             "path" => "/.salix/websites/docs/_api.json",
             "present" => true,
             "valid_json" => true,
             "schema_valid" => false
           }

    assert report["errors"] == ["llm.enabled must be a boolean"]

    assert report["warnings"] == [
             "storage.rules[0] allows unauthenticated write/delete access"
           ]
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

  defp restore_env(key, nil), do: Application.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: Application.put_env(:salix_agent, key, value)

  defp await(fun, retries \\ 400) do
    cond do
      fun.() -> true
      retries == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && await(fun, retries - 1)
    end
  end
end
