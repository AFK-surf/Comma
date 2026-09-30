defmodule SalixAgent.ToolsTest do
  @moduledoc """
  Expanded tool inventory: VFS tools (edit/copy/move/grep/glob/stat),
  workspace tools, and the in-order / event-emitting dispatcher
  contract. Against the Fake backend with real VFS bodies.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{AgentWorkspace, SessionToolExecution, ToolDisclosure, Tools}

  defmodule FakeEnvDispatch do
    @behaviour SalixAgent.EnvDispatch

    @impl true
    def list_devices(_agent_id, _opts), do: {:ok, %{devices: [], next_cursor: nil}}

    @impl true
    def list_envs(_agent_id), do: {:ok, []}

    @impl true
    def get_device(_agent_id, _device_id), do: {:error, :no_environment}

    @impl true
    def exec(_agent_id, _env_id, _cmd, _opts), do: {:error, :no_environment}

    @impl true
    def computer_use(_agent_id, _env_id, _action), do: {:error, :no_environment}
    @impl true
    def android(_agent_id, _env_id, _action), do: {:error, :no_environment}

    @impl true
    def process_list(_agent_id, _env_id), do: {:error, :no_environment}

    @impl true
    def process_write(_agent_id, _env_id, _process_name, _data, _opts),
      do: {:error, :no_environment}

    @impl true
    def process_tail(_agent_id, _env_id, _process_name, _opts), do: {:error, :no_environment}

    @impl true
    def read_stream(agent_id, env_id, path) do
      cfg = Application.get_env(:salix_agent, :copy_test_env_dispatch, %{})
      send(cfg[:pid], {:read_stream, agent_id, env_id, path})

      case Map.fetch(cfg[:reads] || %{}, {env_id.environment_id, path}) do
        {:ok, body} -> {:ok, [body], byte_size(body)}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def write_stream(agent_id, env_id, path, stream) do
      cfg = Application.get_env(:salix_agent, :copy_test_env_dispatch, %{})
      body = IO.iodata_to_binary(Enum.to_list(stream))
      send(cfg[:pid], {:write_stream, agent_id, env_id, path, body})
      {:ok, %{"size" => byte_size(body)}}
    end
  end

  defmodule FakeMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id) do
      cfg = Application.get_env(:salix_agent, :tools_test_media, %{})
      {:ok, Map.get(cfg, agent_id, %{})}
    end
  end

  defmodule FakeMCPProvider do
    def provider_state(_agent_id), do: {:ok, %{}}

    def dynamic_disclosure_entries(_agent_id) do
      {:ok,
       [
         %{
           "name" => "mcp.discovery.safe_tool",
           "summary" => "Fake MCP tool used to verify dynamic tool error status.",
           "manual" => "Fake MCP tool used to verify dynamic tool error status.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         },
         %{
           "name" => "mcp.discovery.cancelled_tool",
           "summary" => "Fake MCP tool used to verify dynamic tool cancelled status.",
           "manual" => "Fake MCP tool used to verify dynamic tool cancelled status.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         },
         %{
           "name" => "mcp.discovery.crash_tool",
           "summary" => "Fake MCP tool used to verify crashed tool timing.",
           "manual" => "Fake MCP tool used to verify crashed tool timing.",
           "input_schema" => %{"type" => "object", "properties" => %{}}
         }
       ]}
    end

    def list_bindings(_agent_id) do
      {:ok,
       [
         %{
           "binding_id" => "binding-discovery",
           "alias" => "discovery",
           "enabled" => true,
           "connection" => %{
             "status" => "connected",
             "discovered" => %{
               "tools" => [
                 %{"name" => "safe_tool", "operation_id" => "mcp.discovery.safe_tool"}
               ]
             }
           }
         }
       ]}
    end

    def call_tool(_agent_id, "discovery", "safe_tool", _args, _ctx) do
      {:ok, %{"content" => "redacted MCP server failure", "status" => "error"}}
    end

    def call_tool(_agent_id, "discovery", "cancelled_tool", _args, _ctx) do
      {:ok, %{"content" => "cancelled by host", "status" => "cancelled"}}
    end

    def call_tool(_agent_id, "discovery", "crash_tool", _args, _ctx) do
      Process.sleep(200)
      exit(:crash_tool_boom)
    end
  end

  defmodule ObservabilityFake do
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(fact) do
      send(Application.fetch_env!(:salix_agent, :tools_test_pid), {:tool_observation, fact})
      :ok
    end

    @impl true
    def agent_run(_fact), do: :ok
  end

  setup do
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_env_dispatch = Application.get_env(:salix_agent, :env_dispatch)
    prev_copy_test = Application.get_env(:salix_agent, :copy_test_env_dispatch)
    prev_media_resolver = Application.get_env(:salix_agent, :media_resolver)
    prev_tools_test_media = Application.get_env(:salix_agent, :tools_test_media)
    prev_group_context = Application.get_env(:salix_agent, :group_context_mod)
    prev_mcp_provider = Application.get_env(:salix_agent, :mcp_provider_mod)
    prev_observability = Application.get_env(:salix_agent, :agent_observability_mod)
    prev_tools_test_pid = Application.get_env(:salix_agent, :tools_test_pid)
    SalixAgent.TestSupport.stop_all_agents()
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_agent, :media_resolver, FakeMediaResolver)
    Application.put_env(:salix_agent, :tools_test_media, %{})
    Application.put_env(:salix_agent, :agent_observability_mod, ObservabilityFake)
    Application.put_env(:salix_agent, :tools_test_pid, self())
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      Application.put_env(:salix_store, :s3_backend, prev)

      if is_nil(prev_env_dispatch),
        do: Application.delete_env(:salix_agent, :env_dispatch),
        else: Application.put_env(:salix_agent, :env_dispatch, prev_env_dispatch)

      if is_nil(prev_copy_test),
        do: Application.delete_env(:salix_agent, :copy_test_env_dispatch),
        else: Application.put_env(:salix_agent, :copy_test_env_dispatch, prev_copy_test)

      if is_nil(prev_media_resolver),
        do: Application.delete_env(:salix_agent, :media_resolver),
        else: Application.put_env(:salix_agent, :media_resolver, prev_media_resolver)

      if is_nil(prev_tools_test_media),
        do: Application.delete_env(:salix_agent, :tools_test_media),
        else: Application.put_env(:salix_agent, :tools_test_media, prev_tools_test_media)

      if is_nil(prev_group_context),
        do: Application.delete_env(:salix_agent, :group_context_mod),
        else: Application.put_env(:salix_agent, :group_context_mod, prev_group_context)

      if is_nil(prev_mcp_provider),
        do: Application.delete_env(:salix_agent, :mcp_provider_mod),
        else: Application.put_env(:salix_agent, :mcp_provider_mod, prev_mcp_provider)

      if is_nil(prev_observability),
        do: Application.delete_env(:salix_agent, :agent_observability_mod),
        else: Application.put_env(:salix_agent, :agent_observability_mod, prev_observability)

      if is_nil(prev_tools_test_pid),
        do: Application.delete_env(:salix_agent, :tools_test_pid),
        else: Application.put_env(:salix_agent, :tools_test_pid, prev_tools_test_pid)

      SalixAgent.TestSupport.stop_all_agents()
    end)

    agent = SalixAgent.TestSupport.new_agent_id()
    SalixAgent.TestSupport.create_control_agent!(agent)

    # Seed a couple of VFS files into the agent workspace.
    commit_workspace!(agent, "seed", [
      write_event(agent, "/src/a.txt", "hello world\nsecond line"),
      write_event(agent, "/src/b.txt", "no match here"),
      write_event(agent, "/src/cat.png", <<137, 80, 78, 71>>),
      write_event(agent, "/memory/n1.md", "remember the milk")
    ])

    {:ok, agent: agent, ctx: tool_ctx(agent)}
  end

  test "stat_file returns size/hash; missing file raises", %{ctx: ctx} do
    [r] = Tools.execute([call("fs.stat_file", %{"path" => "/src/a.txt"})], ctx)
    assert r.error == false
    assert Jason.decode!(r.content)["size"] > 0

    [miss] = Tools.execute([call("fs.stat_file", %{"path" => "/nope"})], ctx)
    assert miss.error == true
  end

  test "Session live tool observations include bounded operation input", %{ctx: ctx} do
    ctx = Map.put(ctx, :session_id, "history-operation-test")
    body = String.duplicate("x", 500)

    [result] =
      Tools.execute(
        [call("fs.write_file", %{"path" => "/operation.txt", "content" => body})],
        ctx
      )

    assert result.error == false
    [record] = SalixAgent.ExecutionSurface.get(ctx.agent_id, ctx.session_id)

    assert record["content"]["input"] == %{
             "path" => "/operation.txt",
             "content" => String.slice(body, 0, 320)
           }

    assert record["execution"]["completed_at_ms"] != nil
    assert Jason.decode!(result.input)["content"] == body
  end

  test "raised tool errors classify by exception kind", %{ctx: ctx} do
    # RuntimeError raises are the ordinary tool error protocol (the
    # session-trace API promises "tool_error" for them).
    [miss] = Tools.execute([call("fs.read_file", %{"path" => "/nope.txt"})], ctx)
    assert miss.error == true
    assert miss.error_class == "tool_error"
    assert miss.error_message =~ "no such file"

    # Non-RuntimeError raises are genuine bugs, not tool-reported errors.
    assert Tools.exception_error_class(%ArgumentError{}) == "exception"
    assert Tools.exception_error_class(%Protocol.UndefinedError{}) == "exception"
  end

  test "per-turn capped tool results keep original call order", %{ctx: ctx} do
    calls = [
      call("script.run", %{"source" => "int a;"}) |> Map.put(:id, "js1"),
      call("script.run", %{"source" => "int b;"}) |> Map.put(:id, "js2"),
      call("script.run", %{"source" => "int c;"}) |> Map.put(:id, "js3"),
      call("script.run", %{"source" => "int d;"}) |> Map.put(:id, "js4"),
      call("script.run", %{"source" => "int e;"}) |> Map.put(:id, "js5"),
      call("fs.read_file", %{"path" => "/src/a.txt"}) |> Map.put(:id, "e1"),
      call("script.run", %{"source" => "int f;"}) |> Map.put(:id, "js6")
    ]

    results = Tools.execute(calls, ctx)

    assert Enum.map(results, & &1.id) == ["js1", "js2", "js3", "js4", "js5", "e1", "js6"]
    assert Enum.at(results, 5).content == "hello world\nsecond line"
    assert Enum.at(results, 6).content =~ "per-turn cap exceeded"
  end

  test "hidden MCP tools remain executable after on-demand help", %{agent: agent} do
    Application.put_env(:salix_agent, :mcp_provider_mod, FakeMCPProvider)

    for runtime <- [:internal, :external] do
      ctx =
        tool_ctx(agent)
        |> Map.put(:runtime_kind, runtime)
        |> Map.put(:llm_tool_envelope, runtime == :internal)

      ctx = Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", runtime, ctx))
      name = "mcp.discovery.safe_tool"
      refute Enum.any?(ToolDisclosure.external_specs(ctx.tool_disclosure), &(&1["name"] == name))

      wrap = fn target, params ->
        if runtime == :internal,
          do: %{
            "id" => "on-demand",
            "name" => "call",
            "args" => %{"tool" => target, "params" => params}
          },
          else: %{"id" => "on-demand", "name" => target, "args" => params}
      end

      [discovery] =
        Tools.execute(
          [wrap.("mcp.list", %{"kind" => "tools", "binding_alias" => "discovery"})],
          ctx
        )

      refute discovery.error
      assert discovery.status != "guidance", inspect(discovery)
      assert [%{"operation_id" => ^name}] = Jason.decode!(discovery.content)["tools"]

      [help] = Tools.execute([wrap.("help", %{"tool" => name})], ctx)
      refute help.error
      assert Jason.decode!(help.content)["name"] == name
      [result] = Tools.execute([wrap.(name, %{})], ctx)
      # The provider's error proves dispatch reached it, rather than rejecting a hidden tool.
      assert result.error_message == "redacted MCP server failure"

      denied =
        update_in(ctx.tool_disclosure["tools"], &Enum.reject(&1, fn e -> e["name"] == name end))

      [result] = Tools.execute([wrap.(name, %{})], denied)
      assert result.status == "guidance"
      assert result.guidance_reason == "not_callable"
    end
  end

  test "dynamic MCP error statuses remain failed tool results", %{agent: agent} do
    Application.put_env(:salix_agent, :mcp_provider_mod, FakeMCPProvider)
    ctx = tool_ctx(agent)

    [result] =
      Tools.execute(
        [
          %{
            "id" => "mcp-failed",
            "name" => "mcp.discovery.safe_tool",
            "args" => %{}
          }
        ],
        ctx
      )

    assert result.error == true
    assert result.status == "error"
    assert result.error_class == "tool_error"
    assert result.error_message == "redacted MCP server failure"
  end

  test "sync tool collection emits terminal observations from Tools.execute", %{ctx: ctx} do
    [result] = Tools.execute([call("fs.stat_file", %{"path" => "/src/a.txt"})], ctx)

    assert result.status == "completed"

    assert_receive {:tool_observation,
                    %{
                      tool_name: "fs.stat_file",
                      status: "completed",
                      async: false,
                      args_fingerprint: args_fingerprint,
                      result_fingerprint: result_fingerprint
                    }},
                   1_000

    assert args_fingerprint =~ ~r/^[0-9a-f]{16}$/
    assert result_fingerprint =~ ~r/^[0-9a-f]{16}$/
  end

  test "cancelled sync tool status emits a cancelled observation", %{agent: agent} do
    Application.put_env(:salix_agent, :mcp_provider_mod, FakeMCPProvider)
    ctx = tool_ctx(agent)

    [result] = Tools.execute([call("mcp.discovery.cancelled_tool", %{})], ctx)

    assert result.status == "cancelled"

    assert_receive {:tool_observation,
                    %{
                      tool_name: "mcp.discovery.cancelled_tool",
                      status: "cancelled",
                      async: false
                    }},
                   1_000
  end

  test "guidance reason is carried structurally instead of through model-visible args", %{
    ctx: ctx
  } do
    [result] = Tools.execute([call("missing.tool", %{})], ctx)

    assert result.status == "guidance"
    assert result.guidance_reason == "not_callable"
    refute result.input =~ "_guidance_reason"
    refute result.input =~ "_guidance_error"

    assert_receive {:tool_observation,
                    %{
                      tool_name: "missing.tool",
                      status: "guidance",
                      guidance_reason: "not_callable"
                    }},
                   1_000
  end

  test "async window requires an explicit session id", %{ctx: ctx} do
    assert_raise RuntimeError, "ctx.session_id is required", fn ->
      Tools.execute_with_async_window([call("fs.stat_file", %{"path" => "/src/a.txt"})], ctx)
    end
  end

  test "async tool admission never waits in the caller mailbox and keeps batch start timing", %{
    agent: agent
  } do
    Application.put_env(:salix_agent, :mcp_provider_mod, FakeMCPProvider)
    ctx = agent |> tool_ctx() |> Map.put(:session_id, "main")

    before_ms = System.system_time(:millisecond)
    started = System.monotonic_time(:millisecond)

    {[early], [pending]} =
      Tools.execute_with_async_window([call("mcp.discovery.crash_tool", %{})], ctx)

    assert System.monotonic_time(:millisecond) - started < 100
    assert early.status == "async_running"
    assert %SalixAgent.DependencyJob{} = pending.dependency_job

    assert {:ok, result} =
             SalixAgent.DependencyJob.yield(pending.dependency_job, 1_000)

    assert result.status == "error"
    assert result.error_class == "crashed"
    assert result.content =~ "tool crashed"

    # started_at anchors at the batch start (not the crash handling time) and
    # duration_ms covers the real runtime instead of defaulting to 0.
    assert result.started_at - before_ms < 150
    assert result.duration_ms >= 200

    SessionToolExecution.emit_async(agent, pending, result)

    assert_receive {:tool_observation,
                    %{
                      tool_name: "mcp.discovery.crash_tool",
                      status: "error",
                      error_type: "crashed",
                      async: true,
                      duration_ms: observed_duration_ms
                    }},
                   1_000

    assert observed_duration_ms >= 200
  end

  test "grep finds matching lines across files", %{ctx: ctx} do
    [r] = Tools.execute([call("fs.grep", %{"pattern" => "second", "prefix" => "/src/"})], ctx)
    assert r.content =~ "/src/a.txt:2:second line"
    refute r.content =~ "/src/b.txt"
  end

  test "glob matches VFS paths", %{ctx: ctx} do
    [r] = Tools.execute([call("fs.glob", %{"pattern" => "/src/*.txt"})], ctx)
    paths = String.split(r.content, "\n")
    assert "/src/a.txt" in paths and "/src/b.txt" in paths
    refute "/memory/n1.md" in paths
  end

  test "edit_file emits a vfs_write event with the replacement", %{ctx: ctx, agent: agent} do
    [r] =
      Tools.execute(
        [call("fs.edit_file", %{"path" => "/src/a.txt", "old" => "hello", "new" => "goodbye"})],
        ctx
      )

    assert r.error == false
    assert [%{"type" => "vfs_write", "path" => "/src/a.txt"} = ev] = r.events
    commit_workspace!(agent, "edit-file", [ev])
    assert {:ok, "goodbye world\nsecond line"} = AgentWorkspace.read(agent, "/src/a.txt")
  end

  test "edit_file deletes the old text when new is empty", %{ctx: ctx, agent: agent} do
    # The schema says new may be empty to delete. The shared required-param
    # check rejected "" as missing until new declared minLength 0.
    [r] =
      Tools.execute(
        [call("fs.edit_file", %{"path" => "/src/a.txt", "old" => "hello ", "new" => ""})],
        ctx
      )

    assert r.error == false
    assert [%{"type" => "vfs_write", "path" => "/src/a.txt"} = ev] = r.events
    commit_workspace!(agent, "edit-file-delete", [ev])
    assert {:ok, "world\nsecond line"} = AgentWorkspace.read(agent, "/src/a.txt")
  end

  test "write_file reminds the model about fs.edit_file on a sizeable write, without reading the old file",
       %{ctx: ctx, agent: agent} do
    big = String.duplicate("a line of text that will be rewritten\n", 200)

    [first] =
      Tools.execute([call("fs.write_file", %{"path" => "/src/big.txt", "content" => big})], ctx)

    assert first.error == false
    assert first.content =~ "wrote #{byte_size(big)} bytes to /src/big.txt"
    assert first.content =~ "use fs.edit_file"
    # The reminder is about this write only: nothing from the old file (which
    # did not exist here) is read or reported.
    refute first.content =~ "existing"
    [event] = first.events
    commit_workspace!(agent, "write-big", [event])

    [rewrite] =
      Tools.execute(
        [call("fs.write_file", %{"path" => "/src/big.txt", "content" => big <> "one more\n"})],
        ctx
      )

    assert rewrite.error == false
    assert rewrite.content =~ "use fs.edit_file"
    refute rewrite.content =~ "#{byte_size(big)}-byte"

    # A small write, to a new or an existing file, gets the plain result.
    [small] =
      Tools.execute([call("fs.write_file", %{"path" => "/src/a.txt", "content" => "tiny"})], ctx)

    assert small.content == "wrote 4 bytes to /src/a.txt"
  end

  test "copy and move emit the right manifest events", %{ctx: ctx} do
    [cp] =
      Tools.execute([call("fs.copy_file", %{"from" => "/src/a.txt", "to" => "/src/c.txt"})], ctx)

    assert [%{"type" => "vfs_copy", "from" => "/src/a.txt", "to" => "/src/c.txt"}] = cp.events

    [mv] =
      Tools.execute([call("fs.move_file", %{"from" => "/src/a.txt", "to" => "/src/d.txt"})], ctx)

    assert [%{"type" => "vfs_copy"}, %{"type" => "vfs_delete", "path" => "/src/a.txt"}] =
             mv.events
  end

  test "Copy streams VFS source to a remote destination", %{ctx: ctx, agent: agent} do
    Application.put_env(:salix_agent, :env_dispatch, FakeEnvDispatch)
    Application.put_env(:salix_agent, :copy_test_env_dispatch, %{pid: self(), reads: %{}})

    [r] =
      Tools.execute(
        [
          call("env.copy", %{
            "src_environment" => "vfs",
            "src_path" => "/src/a.txt",
            "dst_device_id" => "device-test",
            "dst_environment" => "laptop",
            "dst_path" => "/tmp/a.txt"
          })
        ],
        ctx
      )

    assert r.error == false
    assert r.events == []
    assert %{"copied" => true, "size" => 23} = Jason.decode!(r.content)

    assert_receive {:write_stream, ^agent, %{device_id: "device-test", environment_id: "laptop"},
                    "/tmp/a.txt", "hello world\nsecond line"}
  end

  test "Copy streams a remote source into VFS as a committed write event", %{
    ctx: ctx,
    agent: agent
  } do
    Application.put_env(:salix_agent, :env_dispatch, FakeEnvDispatch)

    Application.put_env(:salix_agent, :copy_test_env_dispatch, %{
      pid: self(),
      reads: %{{"laptop", "/tmp/report.bin"} => <<0, 1, 2, 3>>}
    })

    [r] =
      Tools.execute(
        [
          call("env.copy", %{
            "src_device_id" => "device-test",
            "src_environment" => "laptop",
            "src_path" => "/tmp/report.bin",
            "dst_environment" => "vfs",
            "dst_path" => "/src/report.bin"
          })
        ],
        ctx
      )

    assert r.error == false
    assert %{"copied" => true, "size" => 4} = Jason.decode!(r.content)
    assert [%{"type" => "vfs_write", "path" => "/src/report.bin"} = ev] = r.events
    commit_workspace!(agent, "copy-remote-to-vfs", [ev])
    assert {:ok, <<0, 1, 2, 3>>} = AgentWorkspace.read(agent, "/src/report.bin")

    assert_receive {:read_stream, ^agent, %{device_id: "device-test", environment_id: "laptop"},
                    "/tmp/report.bin"}
  end

  test "Copy streams remote source to remote destination in order", %{ctx: ctx, agent: agent} do
    Application.put_env(:salix_agent, :env_dispatch, FakeEnvDispatch)

    Application.put_env(:salix_agent, :copy_test_env_dispatch, %{
      pid: self(),
      reads: %{{"src", "/a.bin"} => "remote bytes"}
    })

    [r] =
      Tools.execute(
        [
          call("env.copy", %{
            "src_device_id" => "device-test",
            "src_environment" => "src",
            "src_path" => "/a.bin",
            "dst_device_id" => "device-test",
            "dst_environment" => "dst",
            "dst_path" => "/b.bin"
          })
        ],
        ctx
      )

    assert r.error == false
    assert %{"copied" => true, "size" => 12} = Jason.decode!(r.content)

    assert_receive {:read_stream, ^agent, %{device_id: "device-test", environment_id: "src"},
                    "/a.bin"}

    assert_receive {:write_stream, ^agent, %{device_id: "device-test", environment_id: "dst"},
                    "/b.bin", "remote bytes"}
  end

  test "read_file vision_query uses native image support without an auxiliary model", %{
    ctx: ctx,
    agent: agent
  } do
    Application.put_env(:salix_agent, :tools_test_media, %{
      agent => %{"supports_images" => true, "vision_describer_config" => %{}}
    })

    [result] =
      Tools.execute(
        [
          call("fs.read_file", %{
            "path" => "/src/cat.png",
            "vision_query" => "Read the task titles"
          })
        ],
        ctx
      )

    refute result.error
    assert [image, _summary] = Jason.decode!(result.content)
    assert image["file_ref"] == %{"environment_id" => "vfs", "path" => "/src/cat.png"}
  end

  test "image reads use the requesting model capability after a template switch", %{
    ctx: ctx,
    agent: agent
  } do
    for {request_support, current_support} <- [{true, false}, {false, true}],
        query <- [%{}, %{"vision_query" => "Read the task titles"}] do
      Application.put_env(:salix_agent, :tools_test_media, %{
        agent => %{"supports_images" => current_support, "vision_describer_config" => %{}}
      })

      [result] =
        Tools.execute(
          [call("fs.read_file", Map.put(query, "path", "/src/cat.png"))],
          Map.put(ctx, :model_supports_images, request_support)
        )

      assert result.error == not request_support

      if request_support do
        assert [image, _] = Jason.decode!(result.content)
        assert image["file_ref"]["path"] == "/src/cat.png"
      end
    end
  end

  test "read_file vision_query preserves the configured auxiliary model", %{
    ctx: ctx,
    agent: agent
  } do
    start_supervised!(SalixMedia.MockMedia)

    bandit =
      start_supervised!(
        {Bandit, plug: SalixMedia.MockMedia, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    SalixMedia.MockMedia.set("/chat/completions", %{
      "choices" => [%{"message" => %{"content" => "Task A, Task B"}}]
    })

    Application.put_env(:salix_agent, :tools_test_media, %{
      agent => %{
        "supports_images" => true,
        "vision_describer_config" => %{
          "endpoint" => "http://127.0.0.1:#{port}",
          "model" => "gpt-4o-mini"
        }
      }
    })

    [result] =
      Tools.execute(
        [
          call("fs.read_file", %{
            "path" => "/src/cat.png",
            "vision_query" => "Read the task titles"
          })
        ],
        ctx
      )

    refute result.error
    assert Jason.decode!(result.content)["answer"] == "Task A, Task B"

    assert [%{"role" => "user", "content" => [question, image]}] =
             SalixMedia.MockMedia.last_request()["messages"]

    assert question["text"] == "Read the task titles"
    assert image["image_url"]["url"] =~ "data:image/png;base64,"
  end

  test "read_file vision_query on image requires configured describer", %{ctx: ctx} do
    [r] =
      Tools.execute(
        [call("fs.read_file", %{"path" => "/src/cat.png", "vision_query" => "describe"})],
        ctx
      )

    assert r.error == true
    assert r.content =~ "vision_describer_config"
  end

  test "read_file keeps default text behavior and supports line-paged VFS reads", %{ctx: ctx} do
    [default] = Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt"})], ctx)
    assert default.error == false
    assert default.content == "hello world\nsecond line"

    [first] =
      Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt", "num_lines" => 1})], ctx)

    first_payload = Jason.decode!(first.content)
    assert first_payload["content"] == "hello world"
    assert first_payload["start_line"] == 1
    assert first_payload["end_line"] == 1
    assert first_payload["total_lines"] == 2
    assert first_payload["size_bytes"] == byte_size("hello world\nsecond line")
    assert first_payload["truncated"] == true
    assert first_payload["next_start_line"] == 2

    [second] =
      Tools.execute(
        [call("fs.read_file", %{"path" => "/src/a.txt", "start_line" => 2, "num_lines" => 1})],
        ctx
      )

    second_payload = Jason.decode!(second.content)
    assert second_payload["content"] == "second line"
    assert second_payload["start_line"] == 2
    assert second_payload["end_line"] == 2
    assert second_payload["truncated"] == false
  end

  test "read_file and grep decode canonical stdcopy frames across uint32 lengths", %{
    ctx: ctx,
    agent: agent
  } do
    line_255 = String.duplicate("a", 254) <> "\n"
    line_256 = String.duplicate("b", 255) <> "\n"
    failed_prefix = "Gateway failed to start "
    line_300 = failed_prefix <> String.duplicate("c", 300 - byte_size(failed_prefix) - 1) <> "\n"

    body =
      stdcopy_frame(1, "gateway starting\n") <>
        stdcopy_frame(1, line_255) <>
        stdcopy_frame(2, line_256) <>
        stdcopy_frame(2, line_300) <>
        stdcopy_frame(1, "ERROR config invalid\n")

    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/stdcopy.log", body)
    commit_workspace!(agent, "stdcopy-text", [ev])

    [read] = Tools.execute([call("fs.read_file", %{"path" => "/src/stdcopy.log"})], ctx)

    assert read.error == false

    assert read.content ==
             "gateway starting\n" <>
               line_255 <> line_256 <> line_300 <> "ERROR config invalid\n"

    refute read.content =~ <<0>>

    [page] =
      Tools.execute(
        [
          call("fs.read_file", %{
            "path" => "/src/stdcopy.log",
            "start_line" => 4,
            "num_lines" => 1
          })
        ],
        ctx
      )

    page_payload = Jason.decode!(page.content)
    assert page_payload["content"] == String.trim_trailing(line_300)
    assert page_payload["start_line"] == 4
    assert page_payload["end_line"] == 4
    assert page_payload["size_bytes"] == byte_size(body)
    assert page_payload["decoded_size_bytes"] == byte_size(read.content)

    [grep] =
      Tools.execute(
        [
          call("fs.grep", %{
            "prefix" => "/src/stdcopy.log",
            "pattern" => "(?i)(failed|error)"
          })
        ],
        ctx
      )

    assert grep.error == false
    assert grep.content =~ "/src/stdcopy.log:4:Gateway failed to start"
    assert grep.content =~ "/src/stdcopy.log:5:ERROR config invalid"
  end

  test "read_file decodes the observed lossy stdcopy text export", %{ctx: ctx, agent: agent} do
    short = "gateway starting\n"
    long = String.duplicate("x", 236) <> "\n"
    body = lossy_stdcopy_frame(1, short) <> lossy_stdcopy_frame(2, long)

    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/exported-log.txt", body)
    commit_workspace!(agent, "lossy-stdcopy-text", [ev])

    [read] = Tools.execute([call("fs.read_file", %{"path" => "/src/exported-log.txt"})], ctx)

    assert read.error == false
    assert read.content == short <> long
  end

  test "read_file supports VFS tail-line reads", %{ctx: ctx, agent: agent} do
    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/tail.txt", "one\ntwo\nthree\nfour")
    commit_workspace!(agent, "tail-lines", [ev])

    [result] =
      Tools.execute(
        [call("fs.read_file", %{"path" => "/src/tail.txt", "tail_lines" => 2})],
        ctx
      )

    payload = Jason.decode!(result.content)
    assert payload["content"] == "three\nfour"
    assert payload["start_line"] == 3
    assert payload["end_line"] == 4
    assert payload["total_lines"] == 4
    assert payload["tail_lines"] == 2
    assert payload["truncated"] == true
    assert payload["content_omitted"] == false
    assert payload["omitted_characters"] == 0
    refute Map.has_key?(payload, "next_start_line")
  end

  test "read_file line paging keeps Unicode text intact", %{ctx: ctx, agent: agent} do
    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/unicode.txt", "alpha 你 beta\nnext")
    commit_workspace!(agent, "unicode-page", [ev])

    [result] =
      Tools.execute(
        [call("fs.read_file", %{"path" => "/src/unicode.txt", "num_lines" => 1})],
        ctx
      )

    payload = Jason.decode!(result.content)
    assert payload["content"] == "alpha 你 beta"
    assert payload["next_start_line"] == 2
    assert String.valid?(payload["content"])
  end

  test "read_file omits the middle of oversized text results in every text mode", %{
    ctx: ctx,
    agent: agent
  } do
    large_line =
      String.duplicate("A", 80_000) <>
        "OMITTED_SENTINEL" <> String.duplicate("Z", 80_000)

    body = "intro\n#{large_line}\nending"
    {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/large.txt", body)
    commit_workspace!(agent, "large-read", [ev])

    [full] = Tools.execute([call("fs.read_file", %{"path" => "/src/large.txt"})], ctx)
    full_payload = Jason.decode!(full.content)
    assert full_payload["content_omitted"] == true
    assert full_payload["omitted_characters"] > 0
    assert full_payload["content"] =~ "read_file omitted"
    assert full_payload["content"] =~ String.duplicate("A", 32)
    assert full_payload["content"] =~ String.duplicate("Z", 32)
    refute full_payload["content"] =~ "OMITTED_SENTINEL"

    [paged] =
      Tools.execute(
        [
          call("fs.read_file", %{
            "path" => "/src/large.txt",
            "start_line" => 2,
            "num_lines" => 1
          })
        ],
        ctx
      )

    paged_payload = Jason.decode!(paged.content)
    assert paged_payload["content_omitted"] == true
    assert paged_payload["omitted_characters"] > 0
    assert paged_payload["content"] =~ "content is not complete"
    refute paged_payload["content"] =~ "OMITTED_SENTINEL"

    [tail] =
      Tools.execute(
        [call("fs.read_file", %{"path" => "/src/large.txt", "tail_lines" => 2})],
        ctx
      )

    tail_payload = Jason.decode!(tail.content)
    assert tail_payload["content_omitted"] == true
    assert tail_payload["omitted_characters"] > 0
    assert tail_payload["content"] =~ "ending"
    assert tail_payload["content"] =~ "read_file omitted"
    refute tail_payload["content"] =~ "OMITTED_SENTINEL"
  end

  test "read_file line-paged mode rejects old byte offsets and invalid line windows", %{ctx: ctx} do
    [old_offset] =
      Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt", "offset" => 0})], ctx)

    assert old_offset.error == true
    assert old_offset.content =~ "use start_line/num_lines"

    [old_limit] =
      Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt", "limit" => 10})], ctx)

    assert old_limit.error == true
    assert old_limit.content =~ "use start_line/num_lines"

    [bad_start_line] =
      Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt", "start_line" => -1})], ctx)

    assert bad_start_line.error == false
    assert bad_start_line.status == "guidance"
    assert bad_start_line.content =~ "start_line must be >= 1"

    [bad_num_lines] =
      Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt", "num_lines" => "abc"})], ctx)

    assert bad_num_lines.error == false
    assert bad_num_lines.status == "guidance"
    assert bad_num_lines.content =~ "num_lines must be integer"

    [bad_tail_lines] =
      Tools.execute([call("fs.read_file", %{"path" => "/src/a.txt", "tail_lines" => 0})], ctx)

    assert bad_tail_lines.error == false
    assert bad_tail_lines.status == "guidance"
    assert bad_tail_lines.content =~ "tail_lines must be >= 1"

    [mixed_window] =
      Tools.execute(
        [
          call("fs.read_file", %{
            "path" => "/src/a.txt",
            "start_line" => 1,
            "tail_lines" => 1
          })
        ],
        ctx
      )

    assert mixed_window.error == true
    assert mixed_window.content =~ "tail_lines cannot be used with start_line/num_lines"
  end

  test "tool registration order is stable and includes the full set", %{} do
    names = Enum.map(Tools.specs(), & &1["name"])
    assert Enum.take(names, 3) == ["help", "fs.write_file", "fs.read_file"]

    for t <-
          ~w(fs.write_file fs.read_file fs.edit_file fs.copy_file fs.move_file fs.grep fs.glob fs.stat_file script.run env.copy) do
      assert t in names
    end
  end

  test "media generation tools have longer dispatcher timeouts" do
    assert Tools.tool_timeout_ms("image.generate") == 120_000
    assert Tools.tool_timeout_ms("video.generate") == 600_000
    assert Tools.tool_timeout_ms("audio.transcribe") == 615_000
    assert Tools.tool_timeout_ms("env.android") == 221_000
    assert Tools.tool_timeout_ms("fs.read_file") == 30_000
  end

  test "Exec dispatcher timeout includes readiness, execution and grace" do
    # An omitted timeout uses the same readiness and execution budgets.
    assert Tools.tool_timeout_ms("env.exec") == 435_000

    # The original call can wait five minutes for VM readiness. Execution starts
    # after connection, and the outer deadline includes both budgets and grace.
    assert Tools.tool_timeout_ms("env.exec", %{"timeout" => 120}) == 435_000
    assert Tools.tool_timeout_ms("env.exec", %{"timeout" => "120"}) == 435_000

    # Bounded by a ceiling so a runaway request can't pin a dispatcher slot.
    assert Tools.tool_timeout_ms("env.exec", %{"timeout" => 100_000}) == 915_000

    # Invalid execution timeouts use 120 seconds plus readiness and grace.
    assert Tools.tool_timeout_ms("env.exec", %{"timeout" => 0}) == 435_000
    assert Tools.tool_timeout_ms("env.exec", %{"timeout" => "soon"}) == 435_000

    # Only Exec opts into per-call timeouts.
    assert Tools.tool_timeout_ms("fs.read_file", %{"timeout" => 120}) == 30_000
  end

  test "operator-configured Exec timeout overrides the per-call timeout arg" do
    previous = Application.get_env(:salix_agent, :tool_timeouts)

    try do
      Application.put_env(:salix_agent, :tool_timeouts, %{"env.exec" => 5_000})
      assert Tools.tool_timeout_ms("env.exec", %{"timeout" => 120}) == 5_000
    after
      case previous do
        nil -> Application.delete_env(:salix_agent, :tool_timeouts)
        value -> Application.put_env(:salix_agent, :tool_timeouts, value)
      end
    end
  end

  test "tool dispatcher timeouts can be configured for heavy e2e harnesses" do
    previous = Application.get_env(:salix_agent, :tool_timeouts)

    try do
      Application.put_env(:salix_agent, :tool_timeouts, %{
        "env.copy" => 1_200_000,
        "fs.read_file" => "45000",
        "image.generate" => 0
      })

      assert Tools.tool_timeout_ms("env.copy") == 1_200_000
      assert Tools.tool_timeout_ms("fs.read_file") == 45_000
      assert Tools.tool_timeout_ms("image.generate") == 120_000
    after
      case previous do
        nil -> Application.delete_env(:salix_agent, :tool_timeouts)
        value -> Application.put_env(:salix_agent, :tool_timeouts, value)
      end
    end
  end

  # The journal is JSON-lines: tool results must never carry raw bytes
  # (Jason.EncodeError in Codec.encode_segment would crash-loop the round).
  describe "binary-safe tool results" do
    test "read_file on an image returns a block array only for image-capable agents", %{
      ctx: ctx,
      agent: agent
    } do
      Application.put_env(:salix_agent, :tools_test_media, %{
        agent => %{"supports_images" => true}
      })

      [r] = Tools.execute([call("fs.read_file", %{"path" => "/src/cat.png"})], ctx)
      assert r.error == false

      assert [image, text] = Jason.decode!(r.content)

      assert %{
               "type" => "image",
               "file_ref" => %{"environment_id" => "vfs", "path" => "/src/cat.png"},
               "mime_type" => "image/png",
               "size_bytes" => 4
             } = image

      assert text == %{"type" => "text", "text" => "[Image: /src/cat.png, 4 bytes]"}
    end

    test "read_file on an image errors clearly without image or vision support", %{ctx: ctx} do
      [r] = Tools.execute([call("fs.read_file", %{"path" => "/src/cat.png"})], ctx)

      assert r.error == true
      assert r.content =~ "image-capable model"
      assert r.content =~ "vision_describer_config"
    end

    test "read_file on an unsupported binary returns an explicit unsupported-format error", %{
      ctx: ctx,
      agent: agent
    } do
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/blob.bin", <<0xFF, 0xD8, 0, 16>>)
      commit_workspace!(agent, "binary-unsupported", [ev])

      [r] = Tools.execute([call("fs.read_file", %{"path" => "/src/blob.bin"})], ctx)

      assert r.error == true
      assert r.content =~ "unsupported bin file"
      assert r.content =~ "dedicated reader"
    end

    test "read_file does not decode framed content without a text extension", %{
      ctx: ctx,
      agent: agent
    } do
      body = <<1, 0, 0, 0, 0, 0, 0, 13, "looks textual">>
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/framed.bin", body)
      commit_workspace!(agent, "framed-binary", [ev])

      [r] = Tools.execute([call("fs.read_file", %{"path" => "/src/framed.bin"})], ctx)

      assert r.error == true
      assert r.content =~ "unsupported bin file"
    end

    test "read_file does not decode framed text with invalid UTF-8", %{
      ctx: ctx,
      agent: agent
    } do
      body = <<1, 0, 0, 0, 0, 0, 0, 1, 0xFF>>
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/framed-invalid.txt", body)
      commit_workspace!(agent, "framed-invalid-text", [ev])

      [r] = Tools.execute([call("fs.read_file", %{"path" => "/src/framed-invalid.txt"})], ctx)

      assert r.error == true
      assert r.content =~ "unsupported txt file"
    end

    test "read_file does not decode framed text with a mismatched length", %{
      ctx: ctx,
      agent: agent
    } do
      body = <<1, 0, 0, 0, 0, 0, 0, 4, "abc">>
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/framed-mismatch.txt", body)
      commit_workspace!(agent, "framed-mismatch-text", [ev])

      [r] = Tools.execute([call("fs.read_file", %{"path" => "/src/framed-mismatch.txt"})], ctx)

      assert r.error == true
      assert r.content =~ "unsupported txt file"
    end

    test "edit_file rejects decoded stdcopy views without corrupting raw framing", %{
      ctx: ctx,
      agent: agent
    } do
      body = stdcopy_frame(1, "hello")
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/framed.txt", body)
      commit_workspace!(agent, "framed-edit-read-only", [ev])

      [before_edit] = Tools.execute([call("fs.read_file", %{"path" => "/src/framed.txt"})], ctx)

      [edit] =
        Tools.execute(
          [
            call("fs.edit_file", %{
              "path" => "/src/framed.txt",
              "old" => "hello",
              "new" => "hello!"
            })
          ],
          ctx
        )

      [after_edit] = Tools.execute([call("fs.read_file", %{"path" => "/src/framed.txt"})], ctx)

      assert before_edit.content == "hello"
      assert edit.error == true
      assert edit.content =~ "decoded framed text view is read-only"
      assert after_edit.content == "hello"
      assert {:ok, ^body} = AgentWorkspace.read(agent, "/src/framed.txt")
    end

    test "read_file rejects record streams above the frame-count work cap", %{
      ctx: ctx,
      agent: agent
    } do
      body = :binary.copy(<<1, 0, 0, 0, 0::unsigned-big-32>>, 65_537)
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/src/too-many-frames.log", body)
      commit_workspace!(agent, "stdcopy-frame-cap", [ev])

      [read] =
        Tools.execute([call("fs.read_file", %{"path" => "/src/too-many-frames.log"})], ctx)

      assert read.error == true
      assert read.content =~ "unsupported log file"
    end

    test "grep fails explicitly without retrying a canonical stream past the frame budget", %{
      ctx: ctx,
      agent: agent
    } do
      body = :binary.copy(stdcopy_frame(1, ""), 65_537)
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/grep-cap/one.log", body)
      commit_workspace!(agent, "grep-single-frame-cap", [ev])

      [grep] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "x", "prefix" => "/grep-cap/one.log"})],
          ctx
        )

      assert grep.error == true
      assert grep.error_class != "timeout"
      assert grep.content =~ "frame work budget exceeded"
    end

    test "grep carries the frame budget across files in one request", %{
      ctx: ctx,
      agent: agent
    } do
      body = :binary.copy(stdcopy_frame(1, ""), 32_769)
      {:ok, first} = AgentWorkspace.prepare_write(agent, "/grep-request/a.log", body)
      {:ok, second} = AgentWorkspace.prepare_write(agent, "/grep-request/b.log", body)
      commit_workspace!(agent, "grep-request-frame-cap", [first, second])

      [grep] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "x", "prefix" => "/grep-request/"})],
          ctx
        )

      assert grep.error == true
      assert grep.content =~ "frame work budget exceeded"
    end

    test "grep enforces request-wide file and input-byte budgets", %{ctx: ctx, agent: agent} do
      {:ok, empty} = AgentWorkspace.prepare_write(agent, "/grep-files/seed.txt", "")

      copies =
        for index <- 1..1_000 do
          AgentWorkspace.prepare_copy(
            "/grep-files/seed.txt",
            "/grep-files/copy-#{index}.txt"
          )
        end

      commit_workspace!(agent, "grep-file-cap", [empty | copies])

      [too_many_files] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "x", "prefix" => "/grep-files/"})],
          ctx
        )

      assert too_many_files.error == true
      assert too_many_files.content =~ "file budget exceeded"

      body = String.duplicate("a", 9 * 1024 * 1024)
      {:ok, first} = AgentWorkspace.prepare_write(agent, "/grep-bytes/a.txt", body)
      second = AgentWorkspace.prepare_copy("/grep-bytes/a.txt", "/grep-bytes/b.txt")
      commit_workspace!(agent, "grep-byte-cap", [first, second])

      [too_many_bytes] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "z", "prefix" => "/grep-bytes/"})],
          ctx
        )

      assert too_many_bytes.error == true
      assert too_many_bytes.content =~ "input byte budget exceeded"
    end

    test "grep bounds framed match count and output while scanning", %{ctx: ctx, agent: agent} do
      body = stdcopy_frame(1, :binary.copy("x\n", 500_000))
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/grep-output/many.log", body)
      commit_workspace!(agent, "grep-output-cap", [ev])

      [grep] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "x", "prefix" => "/grep-output/many.log"})],
          ctx
        )

      assert grep.error == false
      assert byte_size(grep.content) <= 120_000
      assert grep.content =~ "[fs.grep truncated:"
      assert length(String.split(grep.content, "\n")) == 2_001
    end

    test "grep does not materialize one oversized matching line", %{ctx: ctx, agent: agent} do
      body = stdcopy_frame(1, String.duplicate("x", 200_000))
      {:ok, ev} = AgentWorkspace.prepare_write(agent, "/grep-output/oversized.log", body)
      commit_workspace!(agent, "grep-oversized-line", [ev])

      [grep] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "x", "prefix" => "/grep-output/oversized.log"})],
          ctx
        )

      assert grep.error == false

      assert grep.content ==
               "[fs.grep truncated: additional matches omitted after reaching result limits]"
    end

    test "grep skips binary bodies instead of emitting raw lines", %{ctx: ctx, agent: agent} do
      {:ok, ev} =
        AgentWorkspace.prepare_write(agent, "/src/blob.bin", <<0xFF, ?s, ?e, ?c, ?o, ?n, ?d, 0>>)

      commit_workspace!(agent, "grep-binary", [ev])

      [r] =
        Tools.execute(
          [call("fs.grep", %{"pattern" => "second", "prefix" => "/src/"})],
          ctx
        )

      assert r.content =~ "/src/a.txt:2:second line"
      refute r.content =~ "blob.bin"
      assert String.valid?(r.content)
    end
  end

  defp write_event(agent, path, body) do
    {:ok, ev} = AgentWorkspace.prepare_write(agent, path, body)
    ev
  end

  defp commit_workspace!(agent, operation_id, events) do
    assert {:ok, _} =
             AgentWorkspace.seed_operation(agent, "tools-test:" <> operation_id, %{}, events)
  end

  defp call(name, args),
    do: %{"id" => "c-#{System.unique_integer([:positive])}", "name" => name, "args" => args}

  defp stdcopy_frame(stream, payload) do
    <<stream, 0, 0, 0, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  defp lossy_stdcopy_frame(stream, payload) do
    encoded_length =
      if byte_size(payload) < 128,
        do: <<byte_size(payload)>>,
        else: <<0xEF, 0xBF, 0xBD>>

    <<stream, 0, 0, 0, 0, 0, 0>> <> encoded_length <> payload
  end

  defp tool_ctx(agent_id) do
    ctx =
      %{agent_id: agent_id, role: "worker", runtime_kind: :external}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(
      ctx,
      :tool_disclosure,
      ToolDisclosure.materialize("worker", :external, ctx)
    )
  end
end
