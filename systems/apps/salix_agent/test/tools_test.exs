defmodule SalixAgent.ToolsTest do
  @moduledoc """
  Expanded tool inventory: VFS tools (edit/copy/move/grep/glob/stat),
  workspace tools, and the in-order / event-emitting dispatcher
  contract. Against the Fake backend with real VFS bodies.
  """
  use SystemsClock.Case, async: false

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
      cfg = SystemsRuntime.get_env(:salix_agent, :copy_test_env_dispatch, %{})
      SystemsRuntime.Proc.send(cfg[:pid], {:read_stream, agent_id, env_id, path})

      case Map.fetch(cfg[:reads] || %{}, {env_id.environment_id, path}) do
        {:ok, body} -> {:ok, [body], byte_size(body)}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def write_stream(agent_id, env_id, path, stream) do
      cfg = SystemsRuntime.get_env(:salix_agent, :copy_test_env_dispatch, %{})
      body = IO.iodata_to_binary(Enum.to_list(stream))
      SystemsRuntime.Proc.send(cfg[:pid], {:write_stream, agent_id, env_id, path, body})
      {:ok, %{"size" => byte_size(body)}}
    end
  end

  defmodule FakeMediaResolver do
    @behaviour SalixAgent.MediaResolver

    @impl true
    def resolve(agent_id) do
      cfg = SystemsRuntime.get_env(:salix_agent, :tools_test_media, %{})
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
      SystemsRuntime.Proc.sleep(200)
      exit(:crash_tool_boom)
    end
  end

  defmodule ObservabilityFake do
    @behaviour SalixAgent.Observability

    @impl true
    def tool_call(fact) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.fetch_env!(:salix_agent, :tools_test_pid),
        {:tool_observation, fact}
      )

      :ok
    end

    @impl true
    def agent_run(_fact), do: :ok
  end

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_env_dispatch = SystemsRuntime.get_env(:salix_agent, :env_dispatch)
    prev_copy_test = SystemsRuntime.get_env(:salix_agent, :copy_test_env_dispatch)
    prev_media_resolver = SystemsRuntime.get_env(:salix_agent, :media_resolver)
    prev_tools_test_media = SystemsRuntime.get_env(:salix_agent, :tools_test_media)
    prev_group_context = SystemsRuntime.get_env(:salix_agent, :group_context_mod)
    prev_mcp_provider = SystemsRuntime.get_env(:salix_agent, :mcp_provider_mod)
    prev_observability = SystemsRuntime.get_env(:salix_agent, :agent_observability_mod)
    prev_tools_test_pid = SystemsRuntime.get_env(:salix_agent, :tools_test_pid)
    SalixAgent.TestSupport.stop_all_agents()
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:salix_agent, :media_resolver, FakeMediaResolver)
    SystemsRuntime.put_env(:salix_agent, :tools_test_media, %{})
    SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, ObservabilityFake)
    SystemsRuntime.put_env(:salix_agent, :tools_test_pid, SystemsRuntime.Proc.self())
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)

      if is_nil(prev_env_dispatch),
        do: SystemsRuntime.delete_env(:salix_agent, :env_dispatch),
        else: SystemsRuntime.put_env(:salix_agent, :env_dispatch, prev_env_dispatch)

      if is_nil(prev_copy_test),
        do: SystemsRuntime.delete_env(:salix_agent, :copy_test_env_dispatch),
        else: SystemsRuntime.put_env(:salix_agent, :copy_test_env_dispatch, prev_copy_test)

      if is_nil(prev_media_resolver),
        do: SystemsRuntime.delete_env(:salix_agent, :media_resolver),
        else: SystemsRuntime.put_env(:salix_agent, :media_resolver, prev_media_resolver)

      if is_nil(prev_tools_test_media),
        do: SystemsRuntime.delete_env(:salix_agent, :tools_test_media),
        else: SystemsRuntime.put_env(:salix_agent, :tools_test_media, prev_tools_test_media)

      if is_nil(prev_group_context),
        do: SystemsRuntime.delete_env(:salix_agent, :group_context_mod),
        else: SystemsRuntime.put_env(:salix_agent, :group_context_mod, prev_group_context)

      if is_nil(prev_mcp_provider),
        do: SystemsRuntime.delete_env(:salix_agent, :mcp_provider_mod),
        else: SystemsRuntime.put_env(:salix_agent, :mcp_provider_mod, prev_mcp_provider)

      if is_nil(prev_observability),
        do: SystemsRuntime.delete_env(:salix_agent, :agent_observability_mod),
        else: SystemsRuntime.put_env(:salix_agent, :agent_observability_mod, prev_observability)

      if is_nil(prev_tools_test_pid),
        do: SystemsRuntime.delete_env(:salix_agent, :tools_test_pid),
        else: SystemsRuntime.put_env(:salix_agent, :tools_test_pid, prev_tools_test_pid)

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

  test "hidden MCP tools remain executable after on-demand help", %{agent: agent} do
    SystemsRuntime.put_env(:salix_agent, :mcp_provider_mod, FakeMCPProvider)

    ctx = tool_ctx(agent) |> Map.put(:llm_tool_envelope, true)
    ctx = Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
    name = "mcp.discovery.safe_tool"

    wrap = fn target, params ->
      %{"id" => "on-demand", "name" => "call", "args" => %{"tool" => target, "params" => params}}
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
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, FakeEnvDispatch)

    SystemsRuntime.put_env(:salix_agent, :copy_test_env_dispatch, %{
      pid: SystemsRuntime.Proc.self(),
      reads: %{}
    })

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
    SystemsRuntime.put_env(:salix_agent, :env_dispatch, FakeEnvDispatch)

    SystemsRuntime.put_env(:salix_agent, :copy_test_env_dispatch, %{
      pid: SystemsRuntime.Proc.self(),
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

    SystemsRuntime.put_env(:salix_agent, :tools_test_media, %{
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

  # The journal is JSON-lines: tool results must never carry raw bytes
  # (Jason.EncodeError in Codec.encode_segment would crash-loop the round).
  describe "binary-safe tool results" do
    test "read_file on an image returns a block array only for image-capable agents", %{
      ctx: ctx,
      agent: agent
    } do
      SystemsRuntime.put_env(:salix_agent, :tools_test_media, %{
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

    for {name, path, body, fragments} <- [
          {"read_file on an unsupported binary returns an explicit unsupported-format error",
           "/src/blob.bin", <<0xFF, 0xD8, 0, 16>>, ["unsupported bin file", "dedicated reader"]},
          {"read_file does not decode framed content without a text extension", "/src/framed.bin",
           <<1, 0, 0, 0, 0, 0, 0, 13, "looks textual">>, ["unsupported bin file"]},
          {"read_file does not decode framed text with invalid UTF-8", "/src/framed-invalid.txt",
           <<1, 0, 0, 0, 0, 0, 0, 1, 0xFF>>, ["unsupported txt file"]},
          {"read_file does not decode framed text with a mismatched length",
           "/src/framed-mismatch.txt", <<1, 0, 0, 0, 0, 0, 0, 4, "abc">>,
           ["unsupported txt file"]}
        ] do
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
    do: %{
      "id" => "c-#{SystemsRuntime.Proc.unique_integer([:positive])}",
      "name" => name,
      "args" => args
    }

  defp stdcopy_frame(stream, payload) do
    <<stream, 0, 0, 0, byte_size(payload)::unsigned-big-32, payload::binary>>
  end

  defp tool_ctx(agent_id) do
    ctx =
      %{agent_id: agent_id, role: "worker", runtime_kind: :internal}
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(ctx, :tool_disclosure, ToolDisclosure.materialize("worker", :internal, ctx))
  end
end
