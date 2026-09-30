defmodule SalixIM.ControlCommandTest do
  @moduledoc """
  Inbound `<salix-command>` blocks: parsed at the provider funnel, executed
  against the group's Router agent, answered in the originating chat, and never
  staged for the agent loop.
  """
  use ExUnit.Case, async: false

  alias SalixIM.ControlCommand
  alias SalixIM.TestSupport.BanditServer
  alias SalixStore.Keys

  defmodule MockSlack do
    @moduledoc "Minimal recording mock of the Slack Web API."
    use Agent
    import Plug.Conn

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def requests(method) do
      Agent.get(__MODULE__, & &1) |> Enum.reverse() |> Enum.filter(&(&1.method == method))
    end

    def last_request(method), do: method |> requests() |> List.last()

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)

      case conn.path_info do
        ["api", method] ->
          req = %{method: method, params: URI.decode_query(raw)}
          Agent.update(__MODULE__, &[req | &1])

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true, "channel" => "C1", "ts" => "1.1"}))

        _ ->
          send_resp(conn, 404, "")
      end
    end
  end

  defmodule FakeTenantAppStore do
    @moduledoc false
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def put(tenant_id, app), do: Agent.update(__MODULE__, &Map.put(&1, tenant_id, app))

    def get_feishu_tenant_app(tenant_id) do
      case Agent.get(__MODULE__, &Map.get(&1, tenant_id)) do
        nil -> {:error, :not_configured}
        app -> {:ok, app}
      end
    end
  end

  defmodule MockFeishuAPI do
    @moduledoc "Token issuance, bot identity, and a recording message endpoint."
    use Agent
    import Plug.Conn

    def start_link(_ \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

    def requests, do: Agent.get(__MODULE__, & &1) |> Enum.reverse()

    def last_request(path_fragment) do
      requests()
      |> Enum.filter(&String.contains?(&1.path, path_fragment))
      |> List.last()
    end

    def init(opts), do: opts

    def call(%{request_path: "/open-apis/auth/v3/tenant_access_token/internal"} = conn, _opts) do
      json(conn, %{"code" => 0, "tenant_access_token" => "test-token"})
    end

    def call(%{request_path: "/open-apis/bot/v3/info"} = conn, _opts) do
      json(conn, %{"code" => 0, "bot" => %{"open_id" => "ou_test_bot"}})
    end

    def call(conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      body = if raw == "", do: %{}, else: Jason.decode!(raw)

      if Process.whereis(__MODULE__) do
        Agent.update(__MODULE__, &[%{path: conn.request_path, body: body} | &1])
      end

      json(conn, %{"code" => 0, "data" => %{"message_id" => "om_reply"}})
    end

    defp json(conn, body) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(body))
    end
  end

  defmodule DegradedAgentControl do
    @moduledoc "A runtime whose provider config could not be resolved."
    @behaviour SalixIM.Ports.AgentControl

    @impl true
    def switch_router_session(_agent_id, _tenant_id, _session_id),
      do: {:error, :agent_control_not_configured}

    @impl true
    def session_status(_agent_id, session_id),
      do: {:ok, %{"session_id" => session_id, "estimated_context_tokens" => 4_096}}

    @impl true
    def compact_session(_agent_id, _session_id),
      do: {:ok, %{"status" => "noop", "reason" => "no_new_live_messages"}}

    @impl true
    def emergency_compact_session(_agent_id, _session_id),
      do: {:ok, %{"status" => "emergency_compacted"}}
  end

  defmodule ExternalRuntimeAgentControl do
    @moduledoc "What the binding reports for a Router on an external runtime."
    @behaviour SalixIM.Ports.AgentControl

    @impl true
    def switch_router_session(_agent_id, _tenant_id, _session_id),
      do: {:error, :agent_control_not_configured}

    @impl true
    def session_status(_agent_id, _session_id), do: {:error, :internal_runtime_only}

    @impl true
    def compact_session(_agent_id, _session_id), do: {:error, :internal_runtime_only}

    @impl true
    def emergency_compact_session(_agent_id, _session_id), do: {:error, :internal_runtime_only}
  end

  defmodule FailedAgentControl do
    @moduledoc "A session whose live activity state differs from its status."
    @behaviour SalixIM.Ports.AgentControl

    @impl true
    def switch_router_session(_agent_id, _tenant_id, _session_id),
      do: {:error, :agent_control_not_configured}

    @impl true
    def session_status(_agent_id, session_id) do
      {:ok,
       %{
         "session_id" => session_id,
         "model" => "claude-opus-5",
         "context_tokens" => 128_000,
         "estimated_context_tokens" => 100,
         "message_count" => 3,
         "compacted_through" => 0,
         "status" => "active",
         "activity_status" => "failed"
       }}
    end

    @impl true
    def compact_session(_agent_id, _session_id), do: {:ok, %{"status" => "compacted"}}

    @impl true
    def emergency_compact_session(_agent_id, _session_id),
      do: {:ok, %{"status" => "emergency_compacted"}}
  end

  defmodule FreshAgentControl do
    @moduledoc "A session that has never been compacted."
    @behaviour SalixIM.Ports.AgentControl

    @impl true
    def switch_router_session(_agent_id, _tenant_id, _session_id),
      do: {:error, :agent_control_not_configured}

    @impl true
    def session_status(_agent_id, session_id) do
      {:ok,
       %{
         "session_id" => session_id,
         "model" => "claude-opus-5",
         "context_tokens" => 128_000,
         "estimated_context_tokens" => 2_048,
         "message_count" => 12,
         "compacted_through" => 0
       }}
    end

    @impl true
    def compact_session(_agent_id, _session_id), do: {:ok, %{"status" => "compacted"}}

    @impl true
    def emergency_compact_session(_agent_id, _session_id),
      do: {:ok, %{"status" => "emergency_compacted"}}
  end

  defmodule StubAgentControl do
    @moduledoc "Records control calls and answers with a fixed runtime status."
    @behaviour SalixIM.Ports.AgentControl

    @impl true
    def switch_router_session(agent_id, tenant_id, session_id) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | calls: [{:switch_router_session, agent_id, tenant_id, session_id} | state.calls]
        }
      end)

      Agent.get(
        __MODULE__,
        &Map.get(&1, :clear_result, {:ok, %{"router_session_id" => "ses1_0000000000000007002"}})
      )
    end

    use Agent

    def start_link(_ \\ []),
      do: Agent.start_link(fn -> %{calls: [], surfaces: []} end, name: __MODULE__)

    def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

    # Observed from inside whatever process ran the command, so a test can
    # prove the webhook's observability context travelled across the Task.
    def surfaces, do: Agent.get(__MODULE__, & &1.surfaces) |> Enum.reverse()

    @impl true
    def session_status(agent_id, session_id) do
      surface = SystemsObservability.Context.current_surface()

      Agent.update(__MODULE__, fn state ->
        %{
          state
          | calls: [{:session_status, agent_id, session_id} | state.calls],
            surfaces: [surface | state.surfaces]
        }
      end)

      {:ok,
       %{
         "agent_id" => agent_id,
         "session_id" => session_id,
         "model" => "claude-opus-5",
         "provider" => "anthropic",
         "context_tokens" => 128_000,
         "estimated_context_tokens" => 41_203,
         "message_count" => 214,
         "compacted_through" => 180,
         "status" => "active",
         "activity_status" => "thinking"
       }}
    end

    @impl true
    def compact_session(agent_id, session_id) do
      Agent.update(__MODULE__, fn state ->
        %{state | calls: [{:compact_session, agent_id, session_id} | state.calls]}
      end)

      Agent.get(__MODULE__, &Map.get(&1, :compact_result, {:ok, %{"status" => "compacted"}}))
    end

    @impl true
    def emergency_compact_session(agent_id, session_id) do
      Agent.update(__MODULE__, fn state ->
        %{state | calls: [{:emergency_compact_session, agent_id, session_id} | state.calls]}
      end)

      {:ok,
       %{
         "status" => "emergency_compacted",
         "through_id" => 214,
         "max_bytes" => 1_000,
         "replacement" => "[emergency-compacted non-model message over 1000 bytes]"
       }}
    end
  end

  defmodule StubAgentWorkspace do
    @moduledoc """
    A canned agent VFS.

    The bodies are served through a lazy, chunked stream so a test can prove
    `cat` stops enumerating at its cap. Production blob streams are RANGED but a
    range chunk can be larger than the displayed head, so this test protects the
    enumeration/heap bound rather than claiming an exact network byte count.
    """
    @behaviour SalixIM.Ports.AgentWorkspace
    use Agent

    @chunk 1_024

    def start_link(_ \\ []), do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    def chunks_read, do: Agent.get(__MODULE__, & &1)

    def files do
      %{
        "/notes.md" => "top level note\n",
        "/artifacts/report.md" => "launch report\nall green\n",
        "/artifacts/logo.png" => <<0x89, "PNG\r\n", 0x1A, 0x0A, 0, 0, 0>>,
        "/artifacts/nested/deep.txt" => "deep\n",
        "/empty.txt" => "",
        "/big.log" => String.duplicate("a", 20_000),
        # 3-byte codepoints, so the 8,000-byte cap lands mid-character.
        "/wide.txt" => String.duplicate("→", 4_000),
        "/artifacts/nested/invalid-tail.txt" => "hello" <> <<0xFF>>,
        "/artifacts/nested/incomplete-tail.txt" => "hello" <> <<0xE2, 0x86>>,
        "/artifacts/nested/invalid-large.log" =>
          String.duplicate("a", 7_999) <> <<0xFF>> <> String.duplicate("b", 1_000),
        "/artifacts/nested/stream-error.txt" => "body that cannot be fetched",
        "/ping.md" => "<!channel> ship it & <@U123>"
      }
    end

    @impl true
    def list(_agent_id, path) do
      files = files()

      case Map.fetch(files, path) do
        {:ok, body} ->
          {:file, %{"path" => path, "kind" => "file", "size" => byte_size(body)}}

        :error ->
          prefix = if String.ends_with?(path, "/"), do: path, else: path <> "/"

          entries =
            files
            |> Enum.filter(fn {file_path, _body} -> String.starts_with?(file_path, prefix) end)
            |> Enum.map(fn {file_path, body} ->
              case String.split(String.replace_prefix(file_path, prefix, ""), "/", parts: 2) do
                [name] ->
                  %{"path" => prefix <> name, "kind" => "file", "size" => byte_size(body)}

                [dir, _rest] ->
                  %{"path" => prefix <> dir <> "/", "kind" => "dir", "size" => 0}
              end
            end)
            |> Enum.uniq_by(& &1["path"])
            |> Enum.sort_by(&{&1["kind"], &1["path"]})

          if path == "/" or entries != [], do: {:ok, entries}, else: {:error, :not_found}
      end
    end

    @impl true
    def read_stream(_agent_id, path) do
      case Map.fetch(files(), path) do
        {:ok, body} when path == "/artifacts/nested/stream-error.txt" ->
          stream =
            Stream.map([:fetch], fn :fetch ->
              raise "injected ranged read failure for s3://private-bucket/blob"
            end)

          {:ok, stream, byte_size(body), Path.basename(path)}

        {:ok, body} ->
          {:ok, chunk_stream(body), byte_size(body), Path.basename(path)}

        :error ->
          {:error, "file not found in agent VFS: #{path}"}
      end
    end

    defp chunk_stream(body) do
      Stream.resource(
        fn -> 0 end,
        fn offset ->
          if offset >= byte_size(body) do
            {:halt, offset}
          else
            length = min(@chunk, byte_size(body) - offset)
            if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &(&1 + 1))
            {[binary_part(body, offset, length)], offset + length}
          end
        end,
        fn _offset -> :ok end
      )
    end

    @impl true
    def read_upload(_agent_id, _path, _title), do: {:error, "unsupported in this stub"}

    @impl true
    def write(_agent_id, _path, _body), do: {:error, "unsupported in this stub"}

    @impl true
    def put_ref(_agent_id, _path, _ref), do: {:error, "unsupported in this stub"}

    @impl true
    def file_ref(_agent_id, _path), do: {:error, "unsupported in this stub"}

    @impl true
    def read_ref_stream(_agent_id, _ref, _filename), do: {:error, "unsupported in this stub"}
  end

  defmodule UnreachableAgentWorkspace do
    @moduledoc "A workspace whose manifest cannot be read at all."
    @behaviour SalixIM.Ports.AgentWorkspace

    @impl true
    def list(_agent_id, _path), do: {:error, {:storage_unavailable, "s3://bucket/agents/a/vfs"}}

    @impl true
    def read_stream(_agent_id, _path), do: {:error, "agent VFS is not available"}

    @impl true
    def read_upload(_agent_id, _path, _title), do: {:error, "unsupported in this stub"}

    @impl true
    def write(_agent_id, _path, _body), do: {:error, "unsupported in this stub"}

    @impl true
    def put_ref(_agent_id, _path, _ref), do: {:error, "unsupported in this stub"}

    @impl true
    def file_ref(_agent_id, _path), do: {:error, "unsupported in this stub"}

    @impl true
    def read_ref_stream(_agent_id, _ref, _filename), do: {:error, "unsupported in this stub"}
  end

  # ---- parsing ----

  describe "parse/1" do
    test "recognizes the supported commands, with surrounding prose and casing" do
      assert {:ok, :clear} = ControlCommand.parse("<salix-command> CLEAR </salix-command>")

      assert {:error, {:unknown_command, "reset"}} =
               ControlCommand.parse("<salix-command>reset</salix-command>")

      assert {:ok, :status} = ControlCommand.parse("<salix-command>status</salix-command>")
      assert {:ok, :compact} = ControlCommand.parse("<salix-command>compact</salix-command>")

      assert {:ok, :emergency_compact} =
               ControlCommand.parse("<salix-command>emergency-compact</salix-command>")

      assert {:ok, :status} =
               ControlCommand.parse("@bot please <salix-command>\n  STATUS\n</salix-command> now")
    end

    test "recognizes the argument-taking commands and help" do
      assert {:ok, :help} = ControlCommand.parse("<salix-command>help</salix-command>")
      assert {:ok, {:ls, "/"}} = ControlCommand.parse("<salix-command>ls /</salix-command>")

      assert {:ok, {:cat, "/artifacts/report.md"}} =
               ControlCommand.parse("<salix-command>cat /artifacts/report.md</salix-command>")

      # A bare `ls` means the root, the way it means the working directory in a
      # shell; a bare `cat` has no file it could mean.
      assert {:ok, {:ls, "/"}} = ControlCommand.parse("<salix-command>ls</salix-command>")

      assert {:error, {:missing_path, "cat"}} =
               ControlCommand.parse("<salix-command>cat</salix-command>")
    end

    # Only the NAME is case-folded. A VFS path is a manifest key: downcasing it
    # makes every capitalised file unaddressable, and splitting on whitespace
    # past the name makes every file with a space in it unaddressable.
    test "the path keeps its case and its spaces" do
      assert {:ok, {:cat, "/Notes/Q3 Plan.md"}} =
               ControlCommand.parse("<salix-command>CAT  /Notes/Q3 Plan.md </salix-command>")
    end

    # Chat clients invite `code` formatting, and phone keyboards add smart
    # quotes; the marks are not part of the manifest key.
    test "a quoted or code-formatted path is unwrapped" do
      assert {:ok, {:cat, "/notes.md"}} =
               ControlCommand.parse("<salix-command>cat `/notes.md`</salix-command>")

      assert {:ok, {:ls, "/artifacts"}} =
               ControlCommand.parse(~s(<salix-command>ls "/artifacts"</salix-command>))
    end

    # A path typed without its leading slash is the same path. Leaving it
    # relative would miss every manifest key, which are all absolute.
    test "a relative path is made absolute" do
      assert {:ok, {:ls, "/artifacts"}} =
               ControlCommand.parse("<salix-command>ls artifacts</salix-command>")
    end

    test "an unsupported body still intercepts instead of leaking into the prompt" do
      assert {:error, {:unknown_command, "restart"}} =
               ControlCommand.parse("<salix-command>restart</salix-command>")

      assert {:error, {:unknown_command, ""}} =
               ControlCommand.parse("<salix-command></salix-command>")
    end

    test "text without a well-formed block is ordinary agent input" do
      assert :none = ControlCommand.parse("what is the status of the launch?")
      assert :none = ControlCommand.parse("<salix-command>status")
      assert :none = ControlCommand.parse("")
      assert :none = ControlCommand.parse(nil)
      assert :none = ControlCommand.parse(%{"text" => "<salix-command>status</salix-command>"})
    end

    # One message is one command: honoring every block would let a single
    # message fan out into repeated runtime operations.
    test "only the first block is honored" do
      assert {:ok, :status} =
               ControlCommand.parse(
                 "<salix-command>status</salix-command><salix-command>compact</salix-command>"
               )
    end

    # Every Slack ping primitive and link is `<`-delimited, and an unknown body
    # is quoted back into the chat. Excluding `<` from the body means the echo
    # can never make the bot mass-notify a channel.
    test "a body containing markup is not a command and is never echoed" do
      assert :none = ControlCommand.parse("<salix-command><!channel></salix-command>")
      assert :none = ControlCommand.parse("<salix-command><@U123></salix-command>")
      assert :none = ControlCommand.parse("<salix-command><https://evil|Click></salix-command>")
    end

    # The bound has to hold a command name plus a VFS path, so it is not tight
    # around a name; a body past it does not match at all.
    test "an over-long body is not a command" do
      assert {:error, {:unknown_command, _}} =
               ControlCommand.parse(
                 "<salix-command>" <> String.duplicate("x", 256) <> "</salix-command>"
               )

      assert :none =
               ControlCommand.parse(
                 "<salix-command>" <> String.duplicate("x", 257) <> "</salix-command>"
               )
    end

    # A lazy `.*?` body restarts a scan to end-of-input at every opener, which
    # costs ~0.9s at Slack's 40kB text cap on the webhook process before the
    # ACK. The bounded, `<`-free body keeps a failed match local.
    test "repeated openers stay linear" do
      payload = String.duplicate("<salix-command>", 10_000)

      {micros, :none} = :timer.tc(fn -> ControlCommand.parse(payload) end)

      assert micros < 100_000, "parse took #{div(micros, 1000)}ms on #{byte_size(payload)} bytes"
    end
  end

  # ---- pool configuration ----

  # The docs promise these caps are operator-movable; the pool is built once at
  # application start, so the helper is the only thing a test can pin.
  describe "pool caps" do
    test "the configured cap is honored, and bad values fall back" do
      key = :control_command_max_children_test_key
      previous = Application.get_env(:salix_im, key)
      on_exit(fn -> restore(:salix_im, key, previous) end)

      assert SalixIM.Application.control_command_max_children(key, 32) == 32

      Application.put_env(:salix_im, key, 7)
      assert SalixIM.Application.control_command_max_children(key, 32) == 7

      Application.put_env(:salix_im, key, :infinity)
      assert SalixIM.Application.control_command_max_children(key, 32) == :infinity

      for bad <- [0, -1, "16", nil] do
        Application.put_env(:salix_im, key, bad)

        assert SalixIM.Application.control_command_max_children(key, 32) == 32,
               "expected #{inspect(bad)} to fall back to the default"
      end
    end
  end

  defmodule ForbiddenAgentWorkspace do
    def list(_, _), do: raise("disabled command accessed VFS list")
    def read_stream(_, _), do: raise("disabled command accessed VFS read")
  end

  # ---- interception at the provider funnel ----

  describe "provider inbound" do
    setup context do
      SalixAgent.TestSupport.stop_all_agents()

      previous = %{
        s3: Application.get_env(:salix_store, :s3_backend),
        api: Application.get_env(:salix_im, :slack_api_base_url),
        agent_control: Application.get_env(:salix_im, :agent_control_mod),
        agent_workspace: Application.get_env(:salix_im, :agent_workspace_mod),
        execution: Application.get_env(:salix_im, :control_command_execution)
      }

      Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
      start_supervised!(SalixStore.S3.Fake)
      SalixAgent.TestSupport.configure_control_fixtures!()

      start_supervised!(MockSlack)
      start_supervised!(StubAgentControl)
      start_supervised!(StubAgentWorkspace)
      Application.put_env(:salix_im, :agent_control_mod, StubAgentControl)
      Application.put_env(:salix_im, :agent_workspace_mod, StubAgentWorkspace)
      # Commands run on a Task in production so a compaction cannot outlast the
      # webhook ACK; the suite runs them inline so the reply is observable.
      Application.put_env(:salix_im, :control_command_execution, :sync)

      port = BanditServer.start!(fn p -> {Bandit, plug: MockSlack, port: p} end)
      Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

      on_exit(fn ->
        SalixAgent.TestSupport.stop_all_agents()
        restore(:salix_store, :s3_backend, previous.s3)
        restore(:salix_im, :slack_api_base_url, previous.api)
        restore(:salix_im, :agent_control_mod, previous.agent_control)
        restore(:salix_im, :agent_workspace_mod, previous.agent_workspace)
        restore(:salix_im, :control_command_execution, previous.execution)
      end)

      tenant = SalixAgent.TestSupport.new_tenant_id()
      group_id = SalixStore.Ids.new_group_id(tenant)
      agent_id = SalixStore.Ids.new_agent_id(group_id)

      agent =
        SalixAgent.TestSupport.create_control_agent!(agent_id, %{
          "tenant_id" => tenant,
          "group_id" => group_id,
          "name" => "Router",
          "role" => "router"
        })

      {:ok, _group} =
        SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn rec ->
          rec
          |> Map.put("router_agent_id", agent["agent_id"])
          |> Map.put("control_command_vfs_enabled", context[:vfs_enabled] == true)
        end)

      connect_id = "sl-command"
      now = System.system_time(:millisecond)

      {:ok, _} =
        SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), %{
          "tenant_id" => tenant,
          "group_id" => group_id,
          "connect_id" => connect_id,
          "provider" => "slack",
          "app_id" => "A1",
          "workspace_id" => "T1",
          "bot_user_id" => "Ubot",
          "bot_token" => "xoxb-test",
          "inbound_agent_id" => agent["agent_id"],
          "oauth_completed_at" => 1,
          "created_at" => now,
          "updated_at" => now
        })

      %{group_id: group_id, agent_id: agent["agent_id"], connect_id: connect_id}
    end

    test "client commands reply in chat without Router delivery and execute once", ctx do
      attrs = %{
        "client_request_id" => "client-command-status",
        "content" => [%{"type" => "text", "text" => "<salix-command>status</salix-command>"}]
      }

      assert {:ok, first} =
               SalixIM.RouterConversationInput.append_user_message(ctx.group_id, attrs)

      assert first["inserted"]

      assert {:ok, retry} =
               SalixIM.RouterConversationInput.append_user_message(ctx.group_id, attrs)

      refute retry["inserted"]
      assert retry["message_id"] == first["message_id"]
      assert [{:session_status, agent_id, _session_id}] = StubAgentControl.calls()
      assert agent_id == ctx.agent_id

      assert {:ok, [command, reply]} =
               SalixIM.Conversations.list_group_conversation_messages(
                 ctx.group_id,
                 first["conversation_id"],
                 limit: 10
               )

      assert command["delivery_filter"] == %{"participant_ids" => []}
      assert reply["delivery_filter"] == %{"participant_ids" => []}
      assert [%{"type" => "text", "text" => text}] = reply["content"]
      assert text =~ "41,203 / 128,000 tokens"
      assert MockSlack.requests("chat.postMessage") == []
    end

    test "client compaction commands use the group's Router session", ctx do
      for command <- ["compact", "emergency-compact"] do
        assert {:ok, _} =
                 SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
                   "client_request_id" => "client-" <> command,
                   "content" => [
                     %{"type" => "text", "text" => "<salix-command>#{command}</salix-command>"}
                   ]
                 })
      end

      assert [
               {:compact_session, agent_id, session_id},
               {:session_status, agent_id, session_id},
               {:emergency_compact_session, agent_id, session_id}
             ] = StubAgentControl.calls()

      assert agent_id == ctx.agent_id

      assert {:ok, ^session_id} =
               SalixIM.ProviderConnects.agent_group_router_session_id(ctx.agent_id, ctx.group_id)
    end

    test "client unknown commands and disabled VFS return answers, not prompts", ctx do
      for {command, expected} <- [{"shutdown", "Unknown"}, {"cat /notes.md", "disabled"}] do
        assert {:ok, result} =
                 SalixIM.RouterConversationInput.append_user_message(ctx.group_id, %{
                   "client_request_id" => "client-" <> command,
                   "content" => [
                     %{"type" => "text", "text" => "<salix-command>#{command}</salix-command>"}
                   ]
                 })

        assert {:ok, messages} =
                 SalixIM.Conversations.list_group_conversation_messages(
                   ctx.group_id,
                   result["conversation_id"],
                   limit: 10
                 )

        reply = List.last(messages)
        assert reply["delivery_filter"] == %{"participant_ids" => []}
        assert hd(reply["content"])["text"] =~ expected
      end

      assert StubAgentControl.calls() == []
    end

    test "status answers in the source thread and stages nothing for the agent", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>status</salix-command>", "cmd-status")

      assert [{:session_status, agent_id, session_id}] = StubAgentControl.calls()
      assert agent_id == ctx.agent_id

      assert {:ok, ^session_id} =
               SalixIM.ProviderConnects.agent_group_router_session_id(ctx.agent_id, ctx.group_id)

      req = MockSlack.last_request("chat.postMessage")
      assert req.params["channel"] == "C1"
      assert req.params["thread_ts"] == "100.000"
      assert req.params["text"] =~ "claude-opus-5 (anthropic)"
      assert req.params["text"] =~ "41,203 / 128,000 tokens (32%)"
      assert req.params["text"] =~ "214 (compacted through #180)"
      # The state annotation is the operationally useful half of this line —
      # it is how a chat user learns the agent is thinking, waiting or failed.
      assert req.params["text"] =~ "Session: #{session_id} (thinking)"

      refute_router_message(ctx.group_id, "cmd-status")
    end

    test "clear switches only the group's Router and replies in the source thread", ctx do
      assert {:ok, session_id} =
               SalixIM.ProviderConnects.agent_group_router_session_id(ctx.agent_id, ctx.group_id)

      assert {:ok, group} = SalixIM.GroupDirectory.get_group(ctx.group_id)

      assert {:ok, :command} = enqueue(ctx, "<salix-command>clear</salix-command>", "cmd-clear")

      assert [{:switch_router_session, agent_id, tenant_id, ^session_id}] =
               StubAgentControl.calls()

      assert agent_id == ctx.agent_id
      assert tenant_id == group["tenant_id"]
      req = MockSlack.last_request("chat.postMessage")
      assert req.params["channel"] == "C1"
      assert req.params["thread_ts"] == "100.000"
      assert req.params["text"] =~ "Started a new Router session: ses1_0000000000000007002"
      assert req.params["text"] =~ "all chats"
      refute_router_message(ctx.group_id, "cmd-clear")
    end

    test "clear reports stale sessions and runtime failures without retrying", ctx do
      for {reason, expected} <- [
            {{:stale_router_session, "new-session"}, "already changed"},
            {:unavailable, "Router clear failed"}
          ] do
        Agent.update(StubAgentControl, &Map.put(&1, :clear_result, {:error, reason}))
        source = "clear-" <> expected
        assert {:ok, :command} = enqueue(ctx, "<salix-command>clear</salix-command>", source)
        assert MockSlack.last_request("chat.postMessage").params["text"] =~ expected
        refute_router_message(ctx.group_id, source)
      end

      assert length(StubAgentControl.calls()) == 2
    end

    test "client clear is executed once and never delivered as a prompt", ctx do
      attrs = %{
        "client_request_id" => "client-clear",
        "content" => [%{"type" => "text", "text" => "<salix-command>clear</salix-command>"}]
      }

      assert {:ok, first} =
               SalixIM.RouterConversationInput.append_user_message(ctx.group_id, attrs)

      assert {:ok, retry} =
               SalixIM.RouterConversationInput.append_user_message(ctx.group_id, attrs)

      assert first["inserted"]
      refute retry["inserted"]

      assert [{:switch_router_session, agent_id, _tenant_id, _session_id}] =
               StubAgentControl.calls()

      assert agent_id == ctx.agent_id

      assert {:ok, [command, reply]} =
               SalixIM.Conversations.list_group_conversation_messages(
                 ctx.group_id,
                 first["conversation_id"],
                 limit: 10
               )

      assert command["delivery_filter"] == %{"participant_ids" => []}
      assert reply["delivery_filter"] == %{"participant_ids" => []}
      assert hd(reply["content"])["text"] =~ "Started a new Router session"
      assert MockSlack.requests("chat.postMessage") == []
    end

    test "compact triggers a compaction and reports the resulting context", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>compact</salix-command>", "cmd-compact")

      assert [{:compact_session, _agent, _session}, {:session_status, _, _}] =
               StubAgentControl.calls()

      req = MockSlack.last_request("chat.postMessage")
      assert req.params["text"] =~ "Compaction complete."
      assert req.params["text"] =~ "41,203 / 128,000 tokens"

      refute_router_message(ctx.group_id, "cmd-compact")
    end

    test "compact result wait expiry does not claim the compaction failed", ctx do
      Agent.update(
        StubAgentControl,
        &Map.put(&1, :compact_result, {:error, :compact_result_wait_timeout})
      )

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>compact</salix-command>", "cmd-compact-wait")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "result wait timed out"
      assert text =~ "may still complete"
      refute text =~ "Compaction failed"
    end

    test "compact committed failure still reports failure", ctx do
      Agent.update(
        StubAgentControl,
        &Map.put(&1, :compact_result, {:error, {:compact_failed_hard, "dependency timeout"}})
      )

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>compact</salix-command>", "cmd-compact-failed")

      assert MockSlack.last_request("chat.postMessage").params["text"] =~ "Compaction failed"
    end

    test "emergency-compact masks oversized historical non-model messages", ctx do
      assert {:ok, :command} =
               enqueue(
                 ctx,
                 "<salix-command>emergency-compact</salix-command>",
                 "cmd-emergency-compact"
               )

      assert [{:emergency_compact_session, _agent, _session}] = StubAgentControl.calls()

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "Emergency compaction complete."
      assert text =~ "over 1,000 bytes"
      assert text =~ "through message #214"
      assert text =~ "[emergency-compacted non-model message over 1000 bytes]"

      refute_router_message(ctx.group_id, "cmd-emergency-compact")
    end

    test "VFS commands default to denied, remain intercepted, and read no workspace", ctx do
      Application.put_env(:salix_im, :agent_workspace_mod, ForbiddenAgentWorkspace)

      for setting <- [:missing, false, "true", 1, nil] do
        {:ok, _} =
          SalixStore.CasRecord.update(Keys.ctl_group(ctx.group_id), fn rec ->
            if setting == :missing,
              do: Map.delete(rec, "control_command_vfs_enabled"),
              else: Map.put(rec, "control_command_vfs_enabled", setting)
          end)

        for command <- ["ls /", "cat /notes.md"] do
          source_id = "denied-#{inspect(setting)}-#{command}"

          assert {:ok, :command} =
                   enqueue(ctx, "<salix-command>#{command}</salix-command>", source_id)

          assert MockSlack.last_request("chat.postMessage").params["text"] =~
                   "VFS control commands are disabled"

          refute_router_message(ctx.group_id, source_id)
        end
      end
    end

    @tag vfs_enabled: true
    test "disabling the group denies an already-resolved command", ctx do
      {:ok, _} =
        SalixStore.CasRecord.update(Keys.ctl_group(ctx.group_id), fn rec ->
          Map.put(rec, "control_command_vfs_enabled", false)
        end)

      Application.put_env(:salix_im, :agent_workspace_mod, ForbiddenAgentWorkspace)

      {:ok, session_id} =
        SalixIM.ProviderConnects.agent_group_router_session_id(ctx.agent_id, ctx.group_id)

      metadata = metadata(ctx)

      assert :ok =
               ControlCommand.run(
                 ctx.group_id,
                 {:ok, {:cat, "/notes.md"}},
                 metadata,
                 ctx.agent_id,
                 session_id
               )

      assert MockSlack.last_request("chat.postMessage").params["text"] =~
               "VFS control commands are disabled"
    end

    @tag vfs_enabled: true
    test "ls lists a vfs path, marking directories and sizing files", ctx do
      assert {:ok, :command} = enqueue(ctx, "<salix-command>ls /</salix-command>", "cmd-ls-root")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      # `/artifacts/nested/deep.txt` collapses into the `artifacts/` entry: a
      # listing shows one level, not the whole manifest.
      assert text =~ "/ (6 entries)"
      assert text =~ "• artifacts/"
      assert text =~ "• notes.md (15 bytes)"
      # The listing is a read: nothing was staged for the agent, and no session
      # operation ran.
      assert StubAgentControl.calls() == []
      refute_router_message(ctx.group_id, "cmd-ls-root")

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>ls /artifacts</salix-command>", "cmd-ls-dir")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "/artifacts (3 entries)"
      assert text =~ "• nested/"
      assert text =~ "• report.md (24 bytes)"
      # Names are shown relative to the listed directory, not as full paths.
      refute text =~ "/artifacts/report.md"
    end

    @tag vfs_enabled: true
    test "ls on a missing path says so, and on a file names the file", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>ls /nope</salix-command>", "cmd-ls-missing")

      assert MockSlack.last_request("chat.postMessage").params["text"] == "No such path: /nope"

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>ls /notes.md</salix-command>", "cmd-ls-file")

      assert MockSlack.last_request("chat.postMessage").params["text"] =~
               "/notes.md (15 bytes)"
    end

    @tag vfs_enabled: true
    test "cat dumps a file with its size", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /artifacts/report.md</salix-command>", "cmd-cat")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "/artifacts/report.md (24 bytes)"
      assert text =~ "launch report\nall green"
      refute text =~ "showing the first"

      assert StubAgentControl.calls() == []
      refute_router_message(ctx.group_id, "cmd-cat")
    end

    # A workspace file has no size ceiling — agents write build output and
    # recordings here — so `cat` must stop pulling at its cap rather than load
    # the body and slice it afterwards.
    @tag vfs_enabled: true
    test "cat truncates a large file and stops reading at the cap", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /big.log</salix-command>", "cmd-cat-big")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "/big.log (19.5 KB, showing the first 7.8 KB)"

      [_header, body] = String.split(text, "\n", parts: 2)
      assert byte_size(body) == 8_000

      # 8 chunks of 1,024 bytes reach the 8,000-byte cap; the file is 20.
      assert StubAgentWorkspace.chunks_read() == 8
    end

    # The cut at the cap lands mid-codepoint here. Judging the raw slice would
    # report an ordinary UTF-8 file as binary purely because of where it was cut.
    @tag vfs_enabled: true
    test "cat truncating mid-codepoint still shows text", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /wide.txt</salix-command>", "cmd-cat-wide")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "showing the first"
      assert text =~ "→→→"
      refute text =~ "not UTF-8"
    end

    @tag vfs_enabled: true
    test "cat refuses a file that is not text", ctx do
      assert {:ok, :command} =
               enqueue(
                 ctx,
                 "<salix-command>cat /artifacts/logo.png</salix-command>",
                 "cmd-cat-bin"
               )

      assert MockSlack.last_request("chat.postMessage").params["text"] =~
               "/artifacts/logo.png (11 bytes) is not UTF-8 text"
    end

    @tag vfs_enabled: true
    test "cat refuses malformed or incomplete UTF-8 in a complete file", ctx do
      assert {:ok, :command} =
               enqueue(
                 ctx,
                 "<salix-command>cat /artifacts/nested/invalid-tail.txt</salix-command>",
                 "cmd-cat-invalid-tail"
               )

      assert MockSlack.last_request("chat.postMessage").params["text"] =~
               "/artifacts/nested/invalid-tail.txt (6 bytes) is not UTF-8 text"

      assert {:ok, :command} =
               enqueue(
                 ctx,
                 "<salix-command>cat /artifacts/nested/incomplete-tail.txt</salix-command>",
                 "cmd-cat-incomplete-tail"
               )

      assert MockSlack.last_request("chat.postMessage").params["text"] =~
               "/artifacts/nested/incomplete-tail.txt (7 bytes) is not UTF-8 text"

      # Truncation permits only an incomplete codepoint. A malformed byte at
      # the cap must not be mistaken for one and silently removed.
      assert {:ok, :command} =
               enqueue(
                 ctx,
                 "<salix-command>cat /artifacts/nested/invalid-large.log</salix-command>",
                 "cmd-cat-invalid-large"
               )

      assert MockSlack.last_request("chat.postMessage").params["text"] =~
               "/artifacts/nested/invalid-large.log (8.8 KB) is not UTF-8 text"
    end

    @tag vfs_enabled: true
    test "cat answers when a lazy stream fails during enumeration", ctx do
      assert {:ok, :command} =
               enqueue(
                 ctx,
                 "<salix-command>cat /artifacts/nested/stream-error.txt</salix-command>",
                 "cmd-cat-stream-error"
               )

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text == "Salix could not read /artifacts/nested/stream-error.txt — unavailable."
      refute text =~ "private-bucket"
    end

    @tag vfs_enabled: true
    test "cat distinguishes an empty file, a directory and a missing path", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /empty.txt</salix-command>", "cmd-cat-empty")

      assert MockSlack.last_request("chat.postMessage").params["text"] ==
               "/empty.txt is empty (0 bytes)."

      # A directory has no manifest entry of its own, so reading first would
      # fail exactly like a typo and leave the sender guessing which they did.
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /artifacts</salix-command>", "cmd-cat-dir")

      assert MockSlack.last_request("chat.postMessage").params["text"] ==
               "/artifacts is a directory — list it with: ls /artifacts"

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /nope.md</salix-command>", "cmd-cat-missing")

      assert MockSlack.last_request("chat.postMessage").params["text"] == "No such file: /nope.md"
    end

    # `cat` is the one command that puts bytes Salix did not compose into a
    # chat. Every Slack ping primitive is `<`-delimited, so an unescaped dump
    # of a file containing one would make the bot mass-notify the channel.
    @tag vfs_enabled: true
    test "cat cannot make the bot ping a channel", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>cat /ping.md</salix-command>", "cmd-cat-ping")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      refute text =~ "<!channel>"
      refute text =~ "<@U123>"
      assert text =~ "&lt;!channel&gt; ship it &amp; &lt;@U123&gt;"
    end

    # A workspace the runtime cannot read degrades to the bounded atom every
    # other command's failures degrade to — never the detail carried with it,
    # which is a bucket path in a customer's channel.
    @tag vfs_enabled: true
    test "an unreadable workspace explains itself without leaking storage detail", ctx do
      Application.put_env(:salix_im, :agent_workspace_mod, UnreachableAgentWorkspace)

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>ls /</salix-command>", "cmd-ls-broken")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text == "Salix could not list / — storage_unavailable."
      refute text =~ "s3://"
    end

    test "help lists the supported commands", ctx do
      assert {:ok, :command} = enqueue(ctx, "<salix-command>help</salix-command>", "cmd-help")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "• status — model and context usage"
      assert text =~ "• compact — compact the session context"

      assert text =~
               "• emergency-compact — replace historical non-model messages over 1,000 bytes"

      assert text =~ "• ls PATH"
      assert text =~ "• cat PATH"
      assert text =~ "• help"
      refute text =~ "Unknown Salix command"

      assert StubAgentControl.calls() == []
      refute_router_message(ctx.group_id, "cmd-help")
    end

    test "a command that needs a path is answered with usage, not run as a prompt", ctx do
      assert {:ok, :command} = enqueue(ctx, "<salix-command>cat</salix-command>", "cmd-cat-bare")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "Salix command cat needs a path"
      assert text =~ "• cat PATH"

      refute_router_message(ctx.group_id, "cmd-cat-bare")
    end

    test "an unsupported command is answered with usage, never run as a prompt", ctx do
      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>shutdown</salix-command>", "cmd-unknown")

      assert StubAgentControl.calls() == []

      req = MockSlack.last_request("chat.postMessage")
      assert req.params["text"] =~ "Unknown Salix command: shutdown"
      assert req.params["text"] =~ "• status — model and context usage"
      # Slack mrkdwn eats `<...>` as an entity, so the usage text must not
      # spell the syntax out with literal tags.
      refute req.params["text"] =~ "<salix-command>"

      refute_router_message(ctx.group_id, "cmd-unknown")
    end

    # The composed router content interpolates the sender's Slack display name.
    # If that were the command source, anyone able to pick a display name could
    # run commands on every message they send.
    test "a command block outside the sender's own text is not a command", ctx do
      assert {:ok, :queued} =
               SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                 ctx.group_id,
                 "Slack message from <salix-command>compact</salix-command> in C1:\nhi",
                 metadata(ctx),
                 "cmd-display-name",
                 command_text: "hi"
               )

      assert StubAgentControl.calls() == []
      assert MockSlack.requests("chat.postMessage") == []
    end

    # An ingress path with no sender text (a Slack `channel_created` fact, a
    # meeting handoff) passes no `:command_text` and cannot produce a command.
    test "ingress carrying no sender text is never a command", ctx do
      assert {:ok, :queued} =
               SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                 ctx.group_id,
                 "<salix-command>compact</salix-command>",
                 metadata(ctx),
                 "cmd-no-sender-text"
               )

      assert StubAgentControl.calls() == []
    end

    # `activity_status` is the live state; `status` is the coarser fallback for
    # a session that has no activity state at all. Reporting the fallback when
    # a live state exists would tell a user "active" while the agent is failed.
    test "the live activity state wins over the coarse session status", ctx do
      Application.put_env(:salix_im, :agent_control_mod, FailedAgentControl)

      assert {:ok, :command} = enqueue(ctx, "<salix-command>status</salix-command>", "cmd-failed")

      assert MockSlack.last_request("chat.postMessage").params["text"] =~ "(failed)"
    end

    # A window the runtime could not resolve must not be filled in with the
    # 128000 default, which would state a denominator this agent may not have.
    test "status without a resolvable window reports usage with no denominator", ctx do
      Application.put_env(:salix_im, :agent_control_mod, DegradedAgentControl)

      assert {:ok, :command} =
               enqueue(ctx, "<salix-command>status</salix-command>", "cmd-degrade")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "Model: unknown"
      assert text =~ "Context: 4,096 tokens"
      refute text =~ "/"
      assert text =~ "Messages: unknown"
    end

    # 0 is the NORMAL value for a never-compacted session — the most common
    # Router — so the guard that suppresses it is load-bearing, not defensive.
    test "a never-compacted session does not claim a compaction watermark", ctx do
      Application.put_env(:salix_im, :agent_control_mod, FreshAgentControl)

      assert {:ok, :command} = enqueue(ctx, "<salix-command>status</salix-command>", "cmd-fresh")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "Messages: 12"
      refute text =~ "compacted through"
    end

    test "a compaction that does not run reports why, with the current context", ctx do
      Application.put_env(:salix_im, :agent_control_mod, DegradedAgentControl)

      assert {:ok, :command} = enqueue(ctx, "<salix-command>compact</salix-command>", "cmd-noop")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "Compaction did not run (noop: no_new_live_messages)."
      assert text =~ "Context: 4,096 tokens"
    end

    # `SalixAgent.Runtime` refuses a non-internal agent with its shared
    # HTTP-shaped `:bad_request`, which the binding translates. The chat must
    # get a sentence about runtimes, not that term — it reads as though the
    # SENDER did something wrong.
    test "an external-runtime Router explains itself instead of leaking a term", ctx do
      Application.put_env(:salix_im, :agent_control_mod, ExternalRuntimeAgentControl)

      assert {:ok, :command} = enqueue(ctx, "<salix-command>status</salix-command>", "cmd-ext")

      text = MockSlack.last_request("chat.postMessage").params["text"]
      assert text =~ "runs on an external runtime"
      refute text =~ "bad_request"
    end

    test "ordinary messages still reach the agent loop", ctx do
      assert {:ok, :queued} = enqueue(ctx, "what is the launch status?", "cmd-ordinary")
      assert StubAgentControl.calls() == []
      assert MockSlack.requests("chat.postMessage") == []
    end

    # A group that cannot answer a command must not swallow one either:
    # claiming ownership and then dropping it silently answers 200 for a
    # message that was neither executed nor delivered.
    test "a command in a group with no Router is an error, not a silent drop", ctx do
      {:ok, _group} =
        SalixStore.CasRecord.update(Keys.ctl_group(ctx.group_id), fn rec ->
          Map.put(rec, "router_agent_id", "")
        end)

      assert {:error, :router_not_configured} =
               enqueue(ctx, "<salix-command>status</salix-command>", "cmd-no-router")

      assert StubAgentControl.calls() == []
    end
  end

  # ---- dispatch refusal ----

  describe "refusal" do
    setup [:ingress_setup, :slack_connect]

    # Production runs commands on the task supervisor, and every other test
    # pins `:sync` — so without this, `async/1` could stop executing commands
    # entirely and the suite would stay green (verified: hard-coding
    # `async/1` to refuse left 89 tests passing).
    test "the async path actually runs the command and answers", ctx do
      Application.delete_env(:salix_im, :control_command_execution)
      attach_operation_telemetry()

      assert {:ok, :command} =
               SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                 ctx.group_id,
                 "Slack message from U1 in C1:\nhi",
                 %{
                   "provider" => "slack",
                   "connect_id" => ctx.connect["connect_id"],
                   "channel_id" => "C1"
                 },
                 "cmd-async",
                 command_text: "<salix-command>status</salix-command>"
               )

      assert eventually(fn ->
               req = MockSlack.last_request("chat.postMessage")
               req && req.params["text"] =~ "claude-opus-5"
             end)

      assert [{:session_status, _agent, _session}] = StubAgentControl.calls()

      # The catalog's queries select on this exact component/operation pair;
      # dropping it from the finite map degrades every one of them to nothing.
      assert_received {:operation, %{component: "salix_im", operation: "control_command"} = tags}
      assert tags.outcome == "ok"
      # `surface` is resolved on the webhook, so it must not be the junk bucket.
      assert tags.surface != "other"
    end

    # The telemetry GUIDE requires Task work to carry the request's context;
    # without it a command's spans are orphaned from the webhook that caused
    # them, which is the only trace tying an executed command to its sender.
    test "the command task carries the request's observability context", ctx do
      Application.delete_env(:salix_im, :control_command_execution)

      captured = SystemsObservability.Context.capture()
      test_pid = self()

      SystemsObservability.Context.run(%{captured | surface: "bft"}, fn ->
        assert {:ok, :command} =
                 SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                   ctx.group_id,
                   "Slack message from U1 in C1:\nhi",
                   %{
                     "provider" => "slack",
                     "connect_id" => ctx.connect["connect_id"],
                     "channel_id" => "C1"
                   },
                   "cmd-context",
                   command_text: "<salix-command>status</salix-command>"
                 )

        send(test_pid, :enqueued)
      end)

      assert_receive :enqueued

      assert eventually(fn ->
               req = MockSlack.last_request("chat.postMessage")
               req && req.params["text"] =~ "claude-opus-5"
             end)

      # The command ran on the task, and observed the surface the webhook was
      # serving — not the task's own empty context.
      assert [{:session_status, _agent, _session}] = StubAgentControl.calls()
      assert StubAgentControl.surfaces() == ["bft"]
    end

    # Every other test pins `:sync`, so without this the async branch, the
    # supervisor bound, and the refusal shape are never executed at all.
    test "a saturated supervisor answers the sender instead of failing the callback", ctx do
      Application.delete_env(:salix_im, :control_command_execution)
      attach_operation_telemetry()

      # Fill whatever the pool has left rather than assuming it starts empty: a
      # sibling test's command task can still be finishing, and ExUnit shuffles
      # order within the module. Hard-bounded, because `:infinity` is a legal
      # configured cap and an unbounded fill would spawn until the VM died.
      blockers =
        Stream.repeatedly(fn ->
          Task.Supervisor.start_child(SalixIM.ControlCommandTaskSupervisor, fn ->
            receive do
              :release -> :ok
            end
          end)
        end)
        |> Stream.take(64)
        |> Stream.take_while(&match?({:ok, _pid}, &1))
        |> Enum.map(fn {:ok, pid} -> pid end)

      # Registered BEFORE the assertion: the pool is application-owned, not
      # `start_supervised!`, so a failure here would otherwise leave it full
      # for the rest of the run and refuse every later async command.
      on_exit(fn -> Enum.each(blockers, &send(&1, :release)) end)

      assert length(blockers) < 64, "pool did not refuse within its configured cap"

      # The pool is full, so this command cannot start. The callback still
      # succeeds — saturation is not an ingress fault, and a retry could not
      # fix it before the parked tasks finish.
      assert {:ok, :command} =
               SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
                 ctx.group_id,
                 "Slack message from U1 in C1:\nhi",
                 %{
                   "provider" => "slack",
                   "connect_id" => ctx.connect["connect_id"],
                   "channel_id" => "C1"
                 },
                 "cmd-saturated",
                 command_text: "<salix-command>compact</salix-command>"
               )

      assert StubAgentControl.calls() == []

      # Sent from the REPLY pool, never inline: a provider POST on the webhook
      # process is unbounded and would blow the ACK budget precisely when the
      # node is already saturated.
      assert eventually(fn ->
               req = MockSlack.last_request("chat.postMessage")
               req && req.params["text"] =~ "too many commands"
             end)

      # Saturation is the one refusal that is deliberately NOT an ingress
      # error, so it needs its own signal or it is invisible to operators.
      assert_received {:operation, %{operation: "control_command", outcome: "over_budget"}}
    end
  end

  # ---- ingress (the seam the funnel-level tests above cannot see) ----
  #
  # Every test above calls the funnel directly with hand-built opts, so none of
  # them exercises the per-provider grant or the ingress return plumbing. That
  # gap shipped a `CaseClauseError` on every Feishu command.

  describe "slack ingress" do
    setup [:ingress_setup, :slack_connect]

    test "a display-name Meet URL is visible context but not sealed message authority", ctx do
      meet_url = "https://meet.google.com/abc-defg-hij"

      event =
        ctx
        |> slack_mention_event()
        |> Map.merge(%{
          "text" => "<@Ubot> hello from the actual message",
          "user_display_name" => meet_url
        })

      assert {:ok, :accepted} = slack_event(ctx, "Ev-display-url", event)

      {:ok, router_session_id} =
        SalixIM.ProviderConnects.agent_group_router_session_id(ctx.agent_id, ctx.group_id)

      assert eventually(fn ->
               case SalixAgent.TestSupport.SessionData.read(ctx.agent_id, router_session_id) do
                 {:ok, session} ->
                   Enum.any?(session.messages, fn message ->
                     origin = message.trusted_origin || %{}

                     message.role == "user" and is_binary(message.content) and
                       String.contains?(message.content, meet_url) and
                       origin["source_text"] == "<@Ubot> hello from the actual message" and
                       not String.contains?(origin["source_text"], "meet.google.com")
                   end)

                 _ ->
                   false
               end
             end)
    end

    test "a mention carrying a command executes it and answers in-thread", ctx do
      assert {:ok, :accepted} = slack_event(ctx, "Ev-cmd", slack_mention_event(ctx))

      assert [{:session_status, _agent, _session}] = StubAgentControl.calls()
      assert MockSlack.last_request("chat.postMessage").params["text"] =~ "claude-opus-5"

      # NOT `delivered`: nothing was staged for the Router session, so the
      # provider receipt must not claim that an agent input exists.
      assert_receive {:diagnostic, %{event_type: "slack.message.command"}}
      refute_received {:diagnostic, %{event_type: "slack.message.delivered"}}
    end

    # `enqueue_slack_event/2` admits `bot_message`, so a relay app posting into
    # a thread Salix is in would otherwise let whoever wrote the relayed text —
    # a PR title, an alert body — run commands.
    test "an app-authored message carrying a command is not a command", ctx do
      event =
        ctx
        |> slack_mention_event()
        |> Map.merge(%{"type" => "message", "bot_id" => "B-relay", "app_id" => "A-relay"})

      assert {:ok, :accepted} = slack_event(ctx, "Ev-bot", event)

      assert StubAgentControl.calls() == []
      assert MockSlack.requests("chat.postMessage") == []
    end

    # `&` must be unescaped LAST. A user quoting the syntax types
    # `&lt;salix-command&gt;…`, which Slack puts on the wire as
    # `&amp;lt;salix-command&amp;gt;…`; decoding `&` first turns that back into a
    # real block and fires a compaction nobody asked for.
    test "text that literally spells out an escaped block is not a command", ctx do
      event =
        Map.put(
          slack_mention_event(ctx),
          "text",
          "<@Ubot> you write it as &amp;lt;salix-command&amp;gt;compact&amp;lt;/salix-command&amp;gt;"
        )

      assert {:ok, :accepted} = slack_event(ctx, "Ev-literal", event)

      assert StubAgentControl.calls() == []
      assert MockSlack.requests("chat.postMessage") == []
      SalixAgent.TestSupport.stop_all_agents()
    end

    # A plain thread reply in a thread the bot participates in is ADMITTED by
    # `slack_message_relevant?/2` without any mention, so this reaches
    # `slack_command_text/5` and proves the mention requirement itself — unlike
    # a mention-less `app_mention`, which an older gate rejects first.
    test "an admitted thread reply that does not mention the bot is not a command", ctx do
      :ok =
        SalixStore.SlackRouterThreadParticipations.record(
          ctx.group_id,
          ctx.connect["connect_id"],
          "T1",
          "Ubot",
          "C1",
          "1787021700.000100"
        )

      event = %{
        "type" => "message",
        "user" => "U-human",
        "text" => "&lt;salix-command&gt;compact&lt;/salix-command&gt;",
        "channel" => "C1",
        "channel_type" => "channel",
        "thread_ts" => "1787021700.000100",
        "ts" => "1787021764.000900"
      }

      assert {:ok, :accepted} = slack_event(ctx, "Ev-threadreply", event)

      assert StubAgentControl.calls() == []
      assert MockSlack.requests("chat.postMessage") == []
      SalixAgent.TestSupport.stop_all_agents()
    end

    # Ordinary receipt dedupe on the legacy route. The Triage route's
    # deliberate `replay_duplicate?` re-drive is a different path and is
    # covered in `slack_triage_callback_route_test.exs`.
    test "a repeated event id does not re-run the command", ctx do
      event = slack_mention_event(ctx, "compact")

      assert {:ok, :accepted} = slack_event(ctx, "Ev-replay", event)
      assert [{:compact_session, _, _}, {:session_status, _, _}] = StubAgentControl.calls()

      # Same event id again: the receipt already exists, so the legacy path
      # answers duplicate without re-running.
      assert {:ok, :duplicate} = slack_event(ctx, "Ev-replay", event)
      assert [{:compact_session, _, _}, {:session_status, _, _}] = StubAgentControl.calls()
    end
  end

  describe "feishu ingress" do
    setup [:ingress_setup, :feishu_connect]

    # `ensure_feishu_router_relevant/2` admits any group message in a thread the
    # bot has replied in, with no mention — and the bot's own command reply
    # marks the thread participating. Without a mention requirement, one
    # legitimate command would leave every later message in that thread able to
    # trigger a compaction.
    test "a group message in a participating thread that does not mention the bot is not a command",
         ctx do
      :ok =
        SalixIM.ProviderConnects.record_feishu_thread_participation(
          ctx.connect,
          "oc_cmd",
          "omt_thread"
        )

      # Relevance admits this (participating thread, no mention needed), so the
      # command grant is the only thing that can refuse it.
      assert {:ok, %{ok: true, status: "queued"}} =
               feishu_event(ctx, "evt-group-nomention", "<salix-command>compact</salix-command>",
                 chat_type: "group",
                 thread_id: "omt_thread"
               )

      assert StubAgentControl.calls() == []
      SalixAgent.TestSupport.stop_all_agents()
    end

    # The regression that motivated this describe block: the inner dispatch
    # grew a `{:ok, :command}` clause and the outer one did not, so the command
    # ran, replied, and then raised — 500 to Feishu, and a permanent false
    # entry in the ingress error-rate alert.
    test "a command executes and the callback still answers cleanly", ctx do
      assert {:ok, %{ok: true, status: "command"}} =
               feishu_event(ctx, "evt-cmd", "<salix-command>status</salix-command>")

      assert [{:session_status, _agent, _session}] = StubAgentControl.calls()

      assert_receive {:diagnostic, %{event_type: "feishu.message.command"}}
      refute_received {:diagnostic, %{event_type: "feishu.message.delivered"}}
      # Round 2 added this callback outcome because its absence made every
      # Feishu command raise into `emit_feishu_diagnostic/3`'s own rescue.
      assert_receive {:diagnostic, %{event_type: "feishu.callback.command"}}

      # The answer actually reaches Feishu, threaded onto the source message.
      reply = MockFeishuAPI.last_request("/reply")
      assert reply.path =~ "om_evt-cmd"
      assert Jason.decode!(reply.body["content"])["text"] =~ "claude-opus-5"
      # p2p has no thread to stay in.
      assert reply.body["reply_in_thread"] == false
    end

    # The repo-wide Feishu rule keys off CHAT TYPE, not thread presence: a
    # top-level group @mention opens a topic so later replies continue without
    # another mention. Keying off thread presence answers it flat, and the
    # command becomes the only Router reply in the group that opens no thread.
    test "a top-level group command opens a thread and carries its chat", ctx do
      assert {:ok, %{ok: true, status: "command"}} =
               feishu_event(ctx, "evt-group-top", "<salix-command>status</salix-command>",
                 chat_type: "group",
                 thread_id: "omt_opened",
                 mention_bot: true
               )

      reply = MockFeishuAPI.last_request("/reply")
      assert reply.body["reply_in_thread"] == true

      # `chat_id`/`thread_id` are call PARAMS, not body fields, so the only way
      # to see them is the thing they exist to feed: Feishu records thread
      # participation from them when the API response omits them, which is what
      # keeps later replies in the topic flowing without another mention.
      assert SalixIM.ProviderConnects.feishu_thread_participation_active?(
               ctx.connect,
               "oc_cmd",
               "omt_opened"
             )
    end

    # A threaded request must be answered in its thread; posting the reply to
    # the top of the chat instead is the kind of break a green suite hid.
    test "a threaded command is answered inside its thread", ctx do
      assert {:ok, %{ok: true, status: "command"}} =
               feishu_event(ctx, "evt-threaded", "<salix-command>status</salix-command>",
                 chat_type: "group",
                 thread_id: "omt_live",
                 mention_bot: true
               )

      assert MockFeishuAPI.last_request("/reply").body["reply_in_thread"] == true
    end

    # Group chat is the primary Feishu surface, and only the mention branch
    # reaches it. Without this the whole branch could be neutered — verified by
    # mutation: hard-coding the mention predicate to `false` left the suite
    # green before this test existed.
    test "a group message that mentions the bot is a command", ctx do
      assert {:ok, %{ok: true, status: "command"}} =
               feishu_event(ctx, "evt-group-mention", "<salix-command>status</salix-command>",
                 chat_type: "group",
                 mention_bot: true
               )

      assert [{:session_status, _agent, _session}] = StubAgentControl.calls()
    end

    # The gate asserts "blank fails closed"; nothing tested that, so an
    # accidental `!= "app"` would have been indistinguishable.
    test "a message with no sender type is not a command", ctx do
      assert {:ok, %{ok: true}} =
               feishu_event(ctx, "evt-blank-sender", "<salix-command>compact</salix-command>",
                 sender_type: ""
               )

      assert StubAgentControl.calls() == []
      SalixAgent.TestSupport.stop_all_agents()
    end

    # Relayed app content is written by whoever wrote the thing being relayed.
    test "an app-authored message carrying a command is not a command", ctx do
      assert {:ok, %{ok: true}} =
               feishu_event(ctx, "evt-app", "<salix-command>compact</salix-command>",
                 sender_type: "app"
               )

      assert StubAgentControl.calls() == []
      # It went to the agent loop instead; settle that before teardown so a
      # detached round does not outlive this test's fixtures.
      SalixAgent.TestSupport.stop_all_agents()
    end

    test "an ordinary message still reaches the agent loop", ctx do
      assert {:ok, %{ok: true, status: "queued"}} =
               feishu_event(ctx, "evt-plain", "how is the launch going?")

      assert StubAgentControl.calls() == []
      SalixAgent.TestSupport.stop_all_agents()
    end
  end

  # Neither provider filters inbound for bot relevance, and Telegram's
  # `edited_message` mints a fresh `update_id`, so editing one old message into
  # a command would re-run it without limit. Both must stay non-granting until
  # such a gate exists.
  describe "providers that grant no command authority" do
    setup [:ingress_setup]

    test "telegram delivers a command as ordinary agent input", ctx do
      connect = runtime_connect(ctx, "telegram", %{"bot_token" => "tg-token"})

      update = %{
        "update_id" => 4242,
        "message" => %{
          "message_id" => 7,
          "text" => "<salix-command>compact</salix-command>",
          "chat" => %{"id" => 99, "type" => "group"},
          "from" => %{"id" => 5, "username" => "alice"}
        }
      }

      assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_telegram_update(connect, update)
      assert StubAgentControl.calls() == []
      SalixAgent.TestSupport.stop_all_agents()
    end

    test "wechat delivers a command as ordinary agent input", ctx do
      connect =
        runtime_connect(ctx, "wechat", %{
          "base_url" => "http://127.0.0.1:1",
          "token" => "wc-token",
          "wechat_id" => "wx1"
        })

      message = %{
        "message_id" => "wc-1",
        "text" => "<salix-command>compact</salix-command>",
        "context_token" => "ctx-1"
      }

      assert {:ok, :queued} = SalixIM.ProviderHTTP.handle_wechat_update(connect, message)
      assert StubAgentControl.calls() == []
      SalixAgent.TestSupport.stop_all_agents()
    end
  end

  # ---- ingress helpers ----

  defp runtime_connect(ctx, provider, extra) do
    connect_id = "#{provider}-cmd"
    now = System.system_time(:millisecond)

    rec =
      Map.merge(
        %{
          "tenant_id" => ctx.tenant,
          "group_id" => ctx.group_id,
          "connect_id" => connect_id,
          "provider" => provider,
          "status" => "connected",
          "inbound_agent_id" => ctx.agent_id,
          "created_at" => now,
          "updated_at" => now
        },
        extra
      )

    {:ok, _} = SalixStore.CasRecord.create(Keys.ctl_im_connect(ctx.group_id, connect_id), rec)
    rec
  end

  defp ingress_setup(_ctx) do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: Application.get_env(:salix_store, :s3_backend),
      slack_api: Application.get_env(:salix_im, :slack_api_base_url),
      feishu_api: Application.get_env(:salix_im, :feishu_api_base_url),
      store: Application.get_env(:salix_im, :provider_app_store_mod),
      sink: Application.get_env(:salix_im, :diagnostic_sink),
      agent_control: Application.get_env(:salix_im, :agent_control_mod),
      execution: Application.get_env(:salix_im, :control_command_execution),
      delivery: Application.get_env(:salix_im, :agent_delivery_mod)
    }

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixAgent.TestSupport.configure_control_fixtures!()

    start_supervised!(MockSlack)
    start_supervised!(StubAgentControl)
    start_supervised!(FakeTenantAppStore)
    start_supervised!(MockFeishuAPI)
    Application.put_env(:salix_im, :agent_control_mod, StubAgentControl)
    Application.put_env(:salix_im, :provider_app_store_mod, FakeTenantAppStore)
    Application.put_env(:salix_im, :control_command_execution, :sync)
    Application.put_env(:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery)

    test_pid = self()
    Application.put_env(:salix_im, :diagnostic_sink, fn d -> send(test_pid, {:diagnostic, d}) end)

    slack_port = BanditServer.start!(fn p -> {Bandit, plug: MockSlack, port: p} end)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{slack_port}/api")

    feishu_port = BanditServer.start!(fn p -> {Bandit, plug: MockFeishuAPI, port: p} end)

    Application.put_env(
      :salix_im,
      :feishu_api_base_url,
      "http://127.0.0.1:#{feishu_port}/open-apis"
    )

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore(:salix_store, :s3_backend, previous.s3)
      restore(:salix_im, :slack_api_base_url, previous.slack_api)
      restore(:salix_im, :feishu_api_base_url, previous.feishu_api)
      restore(:salix_im, :provider_app_store_mod, previous.store)
      restore(:salix_im, :diagnostic_sink, previous.sink)
      restore(:salix_im, :agent_control_mod, previous.agent_control)
      restore(:salix_im, :control_command_execution, previous.execution)
      restore(:salix_im, :agent_delivery_mod, previous.delivery)
    end)

    tenant = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant)
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    agent =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "tenant_id" => tenant,
        "group_id" => group_id,
        "name" => "Router",
        "role" => "router"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn rec ->
        Map.put(rec, "router_agent_id", agent["agent_id"])
      end)

    %{tenant: tenant, group_id: group_id, agent_id: agent["agent_id"]}
  end

  defp slack_connect(ctx) do
    connect_id = "sl-ingress"
    secret = "signing-secret"
    now = System.system_time(:millisecond)

    {:ok, _} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(ctx.group_id, connect_id), %{
        "tenant_id" => ctx.tenant,
        "group_id" => ctx.group_id,
        "connect_id" => connect_id,
        "provider" => "slack",
        "app_id" => "A1",
        "signing_secret" => secret,
        "workspace_id" => "T1",
        "bot_user_id" => "Ubot",
        "bot_token" => "xoxb-test",
        "inbound_agent_id" => ctx.agent_id,
        "oauth_completed_at" => 1,
        "created_at" => now,
        "updated_at" => now
      })

    {:ok, connect} = SalixStore.CasRecord.get(Keys.ctl_im_connect(ctx.group_id, connect_id))
    %{connect: connect, signing_secret: secret}
  end

  # Slack HTML-escapes user-typed `<`/`>` in `text` — this is the wire form a
  # real `<salix-command>` block arrives in, and the reason the ingress has to
  # unescape before parsing.
  defp slack_mention_event(_ctx, command \\ "status") do
    %{
      "type" => "app_mention",
      "user" => "U-human",
      "text" => "<@Ubot> &lt;salix-command&gt;#{command}&lt;/salix-command&gt;",
      "channel" => "C1",
      "channel_type" => "channel",
      "ts" => "1787021764.000900"
    }
  end

  defp slack_event(ctx, event_id, event) do
    envelope = %{
      "type" => "event_callback",
      "api_app_id" => "A1",
      "team_id" => "T1",
      "event_id" => event_id,
      "event" => event
    }

    raw = Jason.encode!(envelope)
    timestamp = System.system_time(:second)

    mac =
      :crypto.mac(:hmac, :sha256, ctx.signing_secret, "v0:#{timestamp}:#{raw}")
      |> Base.encode16(case: :lower)

    headers = [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> mac}
    ]

    SalixIM.ProviderHTTP.handle_slack_event(ctx.connect, envelope, headers, raw)
  end

  defp feishu_connect(ctx) do
    app_id = "cli_cmd_#{System.unique_integer([:positive])}"

    FakeTenantAppStore.put(ctx.tenant, %{
      "app_id" => app_id,
      "app_secret" => "fs-secret",
      "verification_token" => "verify-token"
    })

    {:ok, connect} =
      SalixIM.ProviderConnects.create_feishu_im_connect(ctx.tenant, ctx.group_id, %{
        "app_id" => app_id,
        "app_name" => "Commands"
      })

    %{connect: connect, app_id: app_id}
  end

  # A p2p message: `feishu_router_relevant/2` admits it without a mention, so
  # the only remaining grant condition is the sender being a person.
  defp feishu_event(ctx, event_id, text, opts \\ []) do
    envelope = %{
      "schema" => "2.0",
      "header" => %{
        "event_id" => event_id,
        "event_type" => "im.message.receive_v1",
        "token" => "verify-token",
        "app_id" => ctx.app_id
      },
      "event" => %{
        "sender" => %{
          "sender_id" => %{"open_id" => "ou_human"},
          "sender_type" => Keyword.get(opts, :sender_type, "user")
        },
        "message" => %{
          "message_id" => "om_" <> event_id,
          "chat_id" => "oc_cmd",
          "chat_type" => Keyword.get(opts, :chat_type, "p2p"),
          "thread_id" => Keyword.get(opts, :thread_id, ""),
          "message_type" => "text",
          "mentions" =>
            if(Keyword.get(opts, :mention_bot, false),
              do: [%{"key" => "@_user_1", "id" => %{"open_id" => "ou_test_bot"}}],
              else: []
            ),
          "content" => Jason.encode!(%{"text" => text})
        }
      }
    }

    SalixIM.ProviderHTTP.handle_feishu_request(ctx.app_id, envelope, [], Jason.encode!(envelope))
  end

  # ---- helpers ----

  defp enqueue(ctx, text, source_id) do
    SalixIM.ProviderConnects.enqueue_group_router_im_provider_message(
      ctx.group_id,
      "Slack message from U1 in C1 thread 100.000:\n" <> text,
      metadata(ctx),
      source_id,
      command_text: text
    )
  end

  defp metadata(ctx) do
    %{
      "provider" => "slack",
      "connect_id" => ctx.connect_id,
      "workspace_id" => "T1",
      "channel_id" => "C1",
      "thread_ts" => "100.000",
      "message_ts" => "100.000",
      "user_id" => "U1",
      "event_type" => "app_mention"
    }
  end

  defp refute_router_message(group_id, source_id) do
    case SalixIM.RouterConversationProjection.get_group_router_conversation(group_id) do
      {:ok, conversation} ->
        {:ok, messages} =
          SalixIM.Conversations.list_group_conversation_messages(
            group_id,
            conversation["conversation_id"],
            limit: 100
          )

        refute Enum.any?(messages, &(&1["source_message_id"] == source_id))

      {:error, _reason} ->
        # No Router conversation was ever created, which is the strongest form
        # of "nothing was staged for the agent loop".
        :ok
    end
  end

  # Runs the emitted metadata through the REAL `Salix.Telemetry` tag pipeline
  # (reached via the public `metrics/0`), so an operation missing from the
  # finite `@component_operations` map collapses to `"other"` here exactly as
  # it would on a scrape — which is the failure this needs to catch.
  defp attach_operation_telemetry do
    tag_values =
      Salix.Telemetry.metrics()
      |> Enum.find(&(&1.name == [:salix, :operations, :total]))
      |> Map.fetch!(:tag_values)

    test_pid = self()
    handler = "control-command-operations-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:salix, :operation, :stop],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:operation, tag_values.(metadata)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp eventually(fun, attempts \\ 100) do
    if fun.() do
      true
    else
      if attempts > 0 do
        Process.sleep(20)
        eventually(fun, attempts - 1)
      else
        false
      end
    end
  end

  # put_env(key, nil) shadows get_env defaults — delete when prev was nil.
  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
