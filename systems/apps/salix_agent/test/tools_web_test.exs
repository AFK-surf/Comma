defmodule SalixAgent.ToolsWebTest do
  @moduledoc """
  Web/script/skill tool ports (`SalixAgent.Tools.Web`): `web.read_pages`
  against a Bandit mock of the Exa /contents endpoint, `script.run_file`
  against the real spinfoam child with VFS-seeded C programs (skipped without
  the pinned binary). Against the Fake S3 backend.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.Tools.Web
  alias SalixAgent.{AgentWorkspace, SpinfoamFixture, ToolDisclosure}

  defmodule MockExa do
    @moduledoc "Mock Exa /contents endpoint; records requests for assertions."
    @behaviour Plug
    import Plug.Conn

    def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
    def requests, do: Agent.get(__MODULE__, & &1)
    def last_request, do: __MODULE__ |> Agent.get(& &1) |> List.first()

    @impl true
    def init(opts), do: opts

    @impl true
    def call(%{method: "POST", request_path: "/contents"} = conn, _opts) do
      {:ok, raw, conn} = read_body(conn)
      req = Jason.decode!(raw)
      api_key = conn |> get_req_header("x-api-key") |> List.first()
      Agent.update(__MODULE__, &[%{body: req, api_key: api_key} | &1])

      urls = req["urls"] || []

      if Enum.any?(urls, &String.contains?(&1, "fail")) do
        send_resp(conn, 404, "no such page")
      else
        results =
          Enum.map(urls, fn u ->
            %{
              "title" => "  Title #{u}  ",
              "url" => u,
              "author" => "",
              "publishedDate" => "2026-01-01",
              "text" => "text for #{u}",
              "highlights" => []
            }
          end)

        resp = %{
          "requestId" => "req-1",
          "results" => results,
          "costDollars" => %{"total" => 0.001}
        }

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(resp))
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "not found")
  end

  defmodule SuccessfulInternalSendIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    def set_owner(pid), do: SystemsRuntime.PersistentTerm.put({__MODULE__, :owner}, pid)

    @impl true
    def list_connects(_agent_id),
      do: {:ok, [%{"connect_id" => "internal", "provider" => "internal"}]}

    @impl true
    def provider_manual("internal") do
      {:ok,
       %{
         "provider" => "internal",
         "apis" => [
           %{
             "name" => "internal.send_message",
             "safety" => "write",
             "required_params" => ["conversation_id", "content"],
             "parameters" => %{
               "conversation_id" => "target conversation",
               "content" => "visible content"
             }
           }
         ]
       }}
    end

    def provider_manual(_provider), do: {:error, :unsupported}

    @impl true
    def call_api(agent_id, "internal", "internal.send_message", args) do
      SystemsRuntime.Proc.send(
        SystemsRuntime.PersistentTerm.get({__MODULE__, :owner}),
        {:nested_file_send, agent_id, args}
      )

      {:ok, %{"ok" => true}}
    end
  end

  setup do
    prev = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)

    on_exit(fn ->
      SystemsRuntime.put_env(:salix_store, :s3_backend, prev)
    end)

    agent = SalixAgent.TestSupport.new_agent_id()

    read_call =
      Jason.encode!(%{"tool" => "fs.read_file", "args" => %{"path" => "/notes/source.txt"}})

    send_call =
      Jason.encode!(%{
        "tool" => "im_api.internal.send_message",
        "args" => %{
          "connect_id" => "internal",
          "conversation_id" => "conversation-source",
          "content" => [%{"type" => "text", "text" => "from file"}]
        }
      })

    workspace_events = [
      write_event(agent, "/scripts/add.c", SpinfoamFixture.script_result_program("3")),
      write_event(agent, "/scripts/env.c", SpinfoamFixture.script_env_program()),
      write_event(
        agent,
        "/scripts/read-via-host.c",
        SpinfoamFixture.script_call_program(read_call, pick: "content")
      ),
      write_event(
        agent,
        "/scripts/nested-send.c",
        SpinfoamFixture.script_call_program(send_call, pick: "ok")
      ),
      write_event(agent, "/notes/source.txt", "alpha from vfs"),
      write_event(agent, "/notes/skillish.md", "terraform mentioned outside skill roots")
    ]

    commit_workspace!(agent, "tools-web-seed", workspace_events)

    ctx =
      %{agent_id: agent, role: "worker", runtime_kind: :script}
      |> SalixAgent.TestSupport.with_plugin_projection()

    disclosure = ToolDisclosure.materialize("worker", :script, ctx)

    {:ok, agent: agent, ctx: Map.put(ctx, :tool_disclosure, disclosure)}
  end

  describe "defs/0" do
  end

  describe "web.read_pages (Bandit mock)" do
    setup do
      start_supervised!(MockExa)

      # Retry on port collisions (randomized ports can collide across suites).
      port =
        Enum.find_value(1..10, fn _ ->
          p = 40000 + :erlang.phash2(SystemsRuntime.Proc.make_ref(), 20000)

          case start_supervised({Bandit, plug: MockExa, port: p}, id: {:bandit, p}) do
            {:ok, _pid} -> p
            {:error, _} -> nil
          end
        end)

      prev_base = SystemsRuntime.get_env(:salix_agent, :exa_base_url)
      prev_key = SystemsRuntime.get_env(:salix_agent, :exa_api_key)
      SystemsRuntime.put_env(:salix_agent, :exa_base_url, "http://127.0.0.1:#{port}")
      SystemsRuntime.put_env(:salix_agent, :exa_api_key, "test-key")

      on_exit(fn ->
        restore_env(:exa_base_url, prev_base)
        restore_env(:exa_api_key, prev_key)
      end)

      :ok
    end

    test "fetches contents for comma-separated urls and formats the Go payload shape", %{ctx: ctx} do
      out = Web.exa_contents(%{"urls" => "http://x/a, http://x/b ,"}, ctx)
      decoded = Jason.decode!(out)

      assert decoded["count"] == 2
      assert decoded["requestId"] == "req-1"
      assert decoded["costDollars"] == %{"total" => 0.001}

      assert [r1, r2] = decoded["results"]
      assert r1["url"] == "http://x/a"
      assert r2["url"] == "http://x/b"
      # trimmed title, empty/omitempty fields dropped
      assert r1["title"] == "Title http://x/a"
      assert r1["text"] == "text for http://x/a"
      assert r1["publishedDate"] == "2026-01-01"
      refute Map.has_key?(r1, "author")
      refute Map.has_key?(r1, "highlights")

      # request carried the trimmed url list, the text cap, and the api key
      assert %{body: body, api_key: "test-key"} = MockExa.last_request()
      assert body["urls"] == ["http://x/a", "http://x/b"]
      assert body["text"] == %{"maxCharacters" => 10_000}
    end
  end

  describe "script_run_file (real spinfoam child)" do
    @describetag :spinfoam
    @describetag skip:
                   if(SpinfoamFixture.available?(),
                     do: false,
                     else: "spinfoam binary unavailable"
                   )

    test "script.run_file preserves a successful nested source-send execution fact", %{ctx: ctx} do
      previous_provider = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, SuccessfulInternalSendIMProvider)
      SuccessfulInternalSendIMProvider.set_owner(SystemsRuntime.Proc.self())

      on_exit(fn ->
        if previous_provider,
          do: SystemsRuntime.put_env(:salix_agent, :im_provider_mod, previous_provider),
          else: SystemsRuntime.delete_env(:salix_agent, :im_provider_mod)
      end)

      ctx =
        ctx
        |> Map.merge(%{
          group_id: "group-source",
          session_id: "session-source",
          source_message_id: "source-2",
          source_message_ids: ["source-1", "source-2"],
          tool_call_id: "outer-run-file",
          visible_reply_phase: :clean,
          visible_reply_guard: :clean
        })
        |> then(&Map.put(&1, :tool_disclosure, ToolDisclosure.materialize("worker", :script, &1)))

      assert {:tool_observations, content, events, observations} =
               Web.script_run_file(%{"path" => "/scripts/nested-send.c"}, ctx)

      assert Jason.decode!(content) == true
      assert [%{tool_name: "im_api.internal.send_message", status: "completed"}] = observations

      assert_receive {:nested_file_send, _,
                      %{"params" => %{"conversation_id" => "conversation-source"}}}

      assert [egress] = Enum.filter(events, &(&1["kind"] == "visible_reply_egress"))
      assert egress["method"] == "im_api.internal.send_message"
      assert get_in(egress, ["event", "agent_group_id"]) == "group-source"
      assert get_in(egress, ["event", "conversation_id"]) == "conversation-source"
      assert get_in(egress, ["event", "source_message_ids"]) == ["source-1", "source-2"]
      assert get_in(egress, ["event", "outer_tool_call_id"]) == "outer-run-file"
    end
  end

  defp write_event(agent, path, body) do
    {:ok, ev} = AgentWorkspace.prepare_write(agent, path, body)
    ev
  end

  defp commit_workspace!(agent, operation_id, events) do
    assert {:ok, _} = AgentWorkspace.seed_operation(agent, operation_id, %{}, events)
  end

  defp restore_env(key, nil), do: SystemsRuntime.delete_env(:salix_agent, key)
  defp restore_env(key, value), do: SystemsRuntime.put_env(:salix_agent, key, value)
end
