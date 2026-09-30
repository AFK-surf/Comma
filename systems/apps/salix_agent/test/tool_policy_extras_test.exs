defmodule SalixAgent.ToolPolicyExtrasTest do
  @moduledoc """
  Session-scoped tool materialization, static role eligibility, and IM dynamic operation dispatch.
  """
  use ExUnit.Case, async: false

  alias SalixAgent.{SessionToolDispatch, ToolDisclosure, ToolPolicy, Tools}
  import ExUnit.CaptureLog

  @memory_names ["memory.get", "memory.search", "memory.write", "memory.ask_worker"]
  @im_names ["im.connects_list", "im.provider_apis_list"]

  test "UI creation is restricted to Workers and exposes the SDK manual" do
    for runtime <- [:internal, :external] do
      router = ctx_for("router", runtime)
      refute ToolDisclosure.callable?(router, "ui.create")
      worker = ctx_for("worker", runtime)
      assert ToolDisclosure.callable?(worker, "ui.create")
      manual = Tools.help(%{"tool" => "ui.create"}, worker) |> Jason.decode!()
      assert is_binary(manual["manual"])
      assert %{"html" => _, "script" => _, "summary" => _} = manual["input_schema"]["properties"]
    end
  end

  test "routine tools expose their schemas in the initial prompt without help" do
    ctx = ctx_for("router", :internal)
    prompt = ToolDisclosure.prompt_section(ctx.tool_disclosure, :internal)

    for name <- [
          "help",
          "fs.read_file",
          "env.exec",
          "web.search",
          "memory.write",
          "tool_call.get_result"
        ] do
      entry = ToolDisclosure.find_disclosure_entry(ctx, name)
      assert entry["callable"]

      [_, section] = String.split(prompt, "- #{name}:", parts: 2)
      [schema] = Regex.run(~r/^  schema: (.+)$/m, section, capture: :all_but_first)
      assert Jason.decode!(schema) == entry["input_schema"]
    end
  end

  test "common IM schemas are preloaded only for operations exposed to the session" do
    Application.put_env(:salix_agent, :im_provider_mod, __MODULE__.FakeIMProvider)

    router = ctx_for("router", :internal)
    worker = ctx_for("worker", :internal, "aw1")

    for name <- ["im_api.slack.search", "im_api.slack.fetch_file"] do
      for ctx <- [router, worker] do
        entry = ToolDisclosure.find_disclosure_entry(ctx, name)
        assert entry["prompt_visibility"] == "manual"
        assert entry["input_schema"]["required"] != []
      end
    end

    assert ToolDisclosure.callable?(router, "im_api.slack.post_task_card")
    refute ToolDisclosure.callable?(worker, "im_api.slack.post_task_card")
    refute ToolDisclosure.helpable?(worker, "im_api.slack.post_task_card")
  end

  test "summary tools retain callable help and complete native schemas" do
    for {role, name, required} <- [
          {"worker", "ui.create", "html"},
          {"worker", "meeting.preparation.publish_personal_report", "report"},
          {"router", "runtime.auth", "action"},
          {"router", "memory.get", "path"}
        ] do
      ctx = ctx_for(role, :internal)
      entry = ToolDisclosure.find_disclosure_entry(ctx, name)
      assert entry["prompt_visibility"] == "summary"
      assert ToolDisclosure.callable?(ctx, name)

      [result] =
        SessionToolDispatch.execute(
          [%{id: "read-tool-help", name: "help", args: %{"tool" => name}}],
          ctx
        )

      refute result.error
      help = Jason.decode!(result.content)
      assert required in help["input_schema"]["required"]

      external = ctx_for(role, :external)

      spec =
        external.tool_disclosure
        |> ToolPolicy.external_specs_for()
        |> Enum.find(&(&1["name"] == name))

      assert spec["input_schema"] == help["input_schema"]

      if name in ["ui.create", "meeting.preparation.publish_personal_report"] do
        assert String.length(help["manual"]) > String.length(help["summary"])
      end
    end
  end

  test "restricted Workers cannot create UI" do
    for ctx <- [
          %{recommendation_policy: :restricted},
          %{recommendation_policy: :unresolved},
          %{inspector_policy: :invalid}
        ] do
      disclosure = ToolDisclosure.materialize_static("worker", :internal, ctx)
      refute Enum.any?(disclosure["tools"], &(&1["name"] == "ui.create" and &1["callable"]))
    end
  end

  defmodule FakeIMProvider do
    @behaviour SalixAgent.Tools.ImRouter

    @impl true
    def list_connects(_agent_id) do
      {:ok,
       [
         %{"connect_id" => "internal", "provider" => "internal"},
         %{
           "connect_id" => "sl1",
           "provider" => "slack",
           "workspace_id" => "W1",
           "workspace_name" => "Acme",
           "oauth_bot_scopes" => %{
             "status" => "known",
             "scopes" => ["chat:write"],
             "observed_at" => 123
           }
         },
         %{
           "connect_id" => "sl-malformed",
           "provider" => "slack",
           "oauth_bot_scopes" => %{
             "status" => "known",
             "scopes" => ["chat:write", 42]
           }
         },
         %{"connect_id" => "wc1", "provider" => "wechat", "wechat_id" => "wx_1"}
       ]}
    end

    @impl true
    def provider_manual(provider) do
      provider
      |> manual_apis()
      |> case do
        :unsupported -> {:error, :unsupported}
        apis -> {:ok, %{"provider" => provider, "apis" => apis}}
      end
    end

    # Mirrors the production seam's agent-aware manual: the worker stand-in
    # discovers only granted operations (read plus the enumerated
    # slack.fetch_file download).
    def provider_manual(provider, "aw1") do
      case provider_manual(provider) do
        {:ok, %{"apis" => apis} = manual} ->
          {:ok, Map.put(manual, "apis", Enum.filter(apis, &worker_visible?/1))}

        other ->
          other
      end
    end

    def provider_manual(provider, _agent_id), do: provider_manual(provider)

    defp worker_visible?(api),
      do: api["safety"] == "read" or api["name"] == "slack.fetch_file"

    @impl true
    def call_api(_agent_id, "slack", "slack.fetch_file", _args) do
      {:ok,
       %{
         "vfs_path" => "/slack/files/report.pdf",
         "name" => "report.pdf",
         "mimetype" => "application/pdf",
         "size" => 42
       }}
    end

    def call_api(_agent_id, "slack", "slack.fetch_image", _args) do
      {:ok,
       %{
         "vfs_path" => "/slack/files/photo.png",
         "name" => "photo.png",
         "mimetype" => "application/octet-stream",
         "size" => 8
       }}
    end

    def call_api(agent_id, provider, api, args) do
      {:ok, %{"agent_id" => agent_id, "provider" => provider, "api" => api, "args" => args}}
    end

    defp manual_apis("internal") do
      [
        %{
          "name" => "internal.task.create",
          "roles" => ["router"],
          "safety" => "write",
          "description" => "Create a durable internal Comma Task.",
          "input_schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "agent_id" => %{"type" => "string"},
              "content" => %{
                "type" => "string",
                "description" =>
                  "For a scheduled Task, repeat it in the final Task response as a reminder to the Router."
              }
            },
            "required" => ["agent_id", "content"]
          },
          "required_params" => ["agent_id", "content"]
        },
        %{
          "name" => "internal.task.update",
          "roles" => ["router"],
          "safety" => "write",
          "description" => "Update one Task's future command or recurrence.",
          "input_schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "conversation_id" => %{"type" => "string", "minLength" => 1},
              "command" => %{"type" => "string", "minLength" => 1},
              "schedule" => %{
                "anyOf" => [%{"type" => "object"}, %{"type" => "null"}]
              }
            },
            "required" => ["conversation_id"],
            "anyOf" => [%{"required" => ["command"]}, %{"required" => ["schedule"]}]
          },
          "required_params" => ["conversation_id"]
        },
        %{
          "name" => "internal.task.list",
          "roles" => ["router"],
          "runtimes" => ["internal", "script"],
          "safety" => "read",
          "description" => "List internal Comma task resources.",
          "input_schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 1_000},
              "cursor" => %{"type" => "string", "minLength" => 1}
            },
            "required" => []
          },
          "required_params" => []
        },
        %{
          "name" => "internal.search_conversations",
          "safety" => "read",
          "description" => "Search visible internal Comma conversations.",
          "parameters" => %{"query" => "Search query."},
          "required_params" => ["query"]
        },
        %{
          "name" => "internal.read_conversation",
          "safety" => "read",
          "description" => "Read one visible internal Comma conversation.",
          "parameters" => %{
            "conversation_id" => "Conversation id.",
            "query" => "Question to answer from the conversation."
          },
          "required_params" => ["conversation_id", "query"]
        },
        %{
          "name" => "internal.update_conversation",
          "roles" => ["router"],
          "safety" => "write",
          "description" => "Update ordinary Conversation state without a Message.",
          "parameters" => %{
            "conversation_id" => "Conversation id.",
            "status" => "Conversation status."
          },
          "required_params" => ["conversation_id", "status"]
        },
        %{
          "name" => "internal.send_message",
          "safety" => "write",
          "description" => "Send a visible internal conversation message.",
          "parameters" => %{
            "conversation_id" => "Conversation id from source context.",
            "content" => "Message body."
          },
          "required_params" => ["conversation_id", "content"]
        }
      ]
    end

    defp manual_apis("slack") do
      [
        %{
          "name" => "slack.post_message",
          "safety" => "write",
          "required_scopes" => ["chat:write"],
          "description" => "Post a Slack message to a channel or thread.",
          "parameters" => %{
            "channel" => "Slack channel id.",
            "text" => "Standard Markdown message text.",
            "thread_ts" => "Optional thread timestamp."
          },
          "required_params" => ["channel", "text"]
        },
        %{
          "name" => "slack.post_task_card",
          "safety" => "write",
          "description" =>
            "Publish one native Slack Task surface after im_api.internal.task.create.",
          "parameters" => %{
            "conversation_id" => "Task conversation_id returned by im_api.internal.task.create.",
            "channel" => "Slack channel ID from the source context.",
            "thread_ts" => "Slack source thread root timestamp."
          },
          "required_params" => ["conversation_id", "channel", "thread_ts"]
        },
        %{
          "name" => "slack.create_canvas",
          "safety" => "write",
          "required_scopes" => ["canvases:write"],
          "description" => "Create a Slack Canvas.",
          "parameters" => %{"content" => "Canvas content."},
          "required_params" => ["content"]
        },
        %{
          "name" => "slack.fetch_file",
          "safety" => "media",
          "description" => "Stage a Slack file into VFS.",
          "parameters" => %{"file_id" => "Slack file id."},
          "required_params" => ["file_id"]
        },
        %{
          "name" => "slack.fetch_image",
          "safety" => "media",
          "description" => "Stage a Slack image into VFS.",
          "parameters" => %{"file_id" => "Slack file id."},
          "required_params" => ["file_id"]
        },
        %{
          "name" => "slack.search",
          "safety" => "read",
          "description" => "Search indexed Slack messages.",
          "parameters" => %{"query" => "Search query."},
          "required_params" => ["query"]
        }
      ]
    end

    defp manual_apis("wechat"), do: []
    defp manual_apis(_provider), do: :unsupported
  end

  setup do
    prev_im = Application.get_env(:salix_agent, :im_provider_mod)
    Application.delete_env(:salix_agent, :im_provider_mod)

    on_exit(fn ->
      if prev_im,
        do: Application.put_env(:salix_agent, :im_provider_mod, prev_im),
        else: Application.delete_env(:salix_agent, :im_provider_mod)
    end)

    :ok
  end

  defp ctx(agent_id) do
    ctx =
      %{
        agent_id: agent_id,
        session_id: "s1",
        role: "router",
        runtime_kind: :internal,
        visible_reply_guard: :clean,
        visible_reply_phase: :clean
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    disclosure = ToolDisclosure.materialize("router", :internal, ctx)
    Map.put(ctx, :tool_disclosure, disclosure)
  end

  defp run_tool(name, args, ctx_overrides \\ %{}) do
    ctx =
      "a1"
      |> ctx()
      |> Map.merge(ctx_overrides)

    [res] =
      SessionToolDispatch.execute(
        [%{"id" => "u1", "name" => name, "args" => args}],
        ctx
      )

    res
  end

  defp call_args(tool, params), do: %{"tool" => tool, "params" => params}

  test "router memory tools are registry tools with router role eligibility" do
    for name <- @memory_names do
      entry = Tools.find_entry(name)
      assert entry
      assert Tools.entry_roles(entry) == ["router"]
      assert is_binary(Tools.entry_description(entry))
      assert Tools.entry_schema(entry)["type"] == "object"
      assert is_function(Tools.entry_fun(entry), 2)
      assert Tools.entry_auto_wait_seconds(entry) == 20
    end
  end

  test "static outbound writes carry visible-side-effect safety into disclosure" do
    for name <- [
          "email.send_to_owners",
          "permission.request",
          "location.request",
          "script.run",
          "script.run_file",
          "oauth.request_authorization",
          "composio.request_connection",
          "composio.execute",
          "schedule.create",
          "preview.publish_html"
        ] do
      entry = Tools.find_entry(name)
      assert Tools.entry_safety(entry) == "write"

      disclosed =
        "a1"
        |> ctx()
        |> get_in([:tool_disclosure, "tools"])
        |> Enum.find(&(&1["name"] == name))

      assert disclosed["safety"] == "write"
    end
  end

  test "static reads carry the only repair-time non-egress safety class" do
    for name <- [
          "help",
          "fs.read_file",
          "fs.list_files",
          "fs.grep",
          "fs.glob",
          "fs.stat_file",
          "web.search",
          "tool_call.get_status",
          "tool_call.get_result",
          "plugin.definitions_list",
          "plugin.definition_get",
          "plugin.projection_get",
          "web.read_pages",
          "memory.get",
          "memory.search",
          "memory.ask_worker",
          "env.process_list",
          "env.process_tail",
          "device.list",
          "device.get",
          "agent.list",
          "agent.get",
          "env.runtime_targets",
          "calendar.list_items",
          "calendar.get_item",
          "im.connects_list",
          "im.provider_apis_list",
          "mcp_manager.definition_list",
          "mcp.list",
          "mcp.get",
          "schedule.list",
          "oauth.list_credentials",
          "oauth.complete_authorization",
          "composio.list_connections",
          "composio.check_connection",
          "composio.list_tools",
          "composio.get_tool",
          "composio.list_toolkits"
        ] do
      entry = Tools.find_entry(name)
      assert Tools.entry_safety(entry) == "read"

      disclosed =
        "a1"
        |> ctx()
        |> get_in([:tool_disclosure, "tools"])
        |> Enum.find(&(&1["name"] == name))

      assert disclosed["safety"] == "read"
    end

    assert Tools.entry_safety(Tools.find_entry("memory.write")) == nil
    assert Tools.entry_safety(Tools.find_entry("agent.create_worker")) == "write"
  end

  test "missing Exa configuration leaves web tools disclosed and fails at execution" do
    previous_key = Application.get_env(:salix_agent, :exa_api_key)
    Application.delete_env(:salix_agent, :exa_api_key)

    on_exit(fn ->
      if previous_key,
        do: Application.put_env(:salix_agent, :exa_api_key, previous_key),
        else: Application.delete_env(:salix_agent, :exa_api_key)
    end)

    disclosed_names =
      "a1"
      |> ctx()
      |> get_in([:tool_disclosure, "tools"])
      |> Enum.map(& &1["name"])

    assert "web.search" in disclosed_names
    assert "web.read_pages" in disclosed_names

    assert_raise RuntimeError, ~r/no Exa API key configured/, fn ->
      Tools.web_search(%{"query" => "current information"}, %{})
    end
  end

  test "external specs expose static IM discovery tools and router memory tools" do
    worker_names = external_names("worker")
    router_names = external_names("router")

    assert @im_names -- worker_names == []
    assert @im_names -- router_names == []
    assert @memory_names -- router_names == []
  end

  test "Tools.execute resolves schema-carrying registry memory tools for router sessions" do
    res = run_tool("memory.get", %{"path" => "/memory/none.md"})
    refute res.error
    assert Jason.decode!(res.content) == %{"path" => "/memory/none.md", "exists" => false}
  end

  test "static IM discovery tools return unavailable when no provider seam is configured" do
    for {name, args} <- [
          {"im.connects_list", %{}},
          {"im.provider_apis_list", %{"provider" => "slack"}}
        ] do
      res = run_tool(name, args)
      assert res.error
      assert res.content == "error: control db is required"
    end
  end

  test "undisclosed dynamic IM operation returns call guidance" do
    res =
      run_tool("im_api.slack.post_message", %{
        "connect_id" => "sl1",
        "channel" => "C1",
        "text" => "hi"
      })

    refute res.error
    out = Jason.decode!(res.content)
    assert out["status"] == "guidance"
    assert out["error"] == "tool is not callable in this session"
    assert out["tool"] == "im_api.slack.post_message"
  end

  test "im.connects_list lists visible connects and filters by provider" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res = run_tool("im.connects_list", %{})
    refute res.error
    %{"connects" => connects} = Jason.decode!(res.content)

    assert Enum.map(connects, & &1["connect_id"]) == [
             "internal",
             "sl1",
             "sl-malformed",
             "wc1"
           ]

    res = run_tool("im.connects_list", %{"provider" => "slack"})
    %{"connects" => slack_connects} = Jason.decode!(res.content)
    assert Enum.map(slack_connects, & &1["connect_id"]) == ["sl1", "sl-malformed"]
    connect = Enum.find(slack_connects, &(&1["connect_id"] == "sl1"))
    assert connect["connect_id"] == "sl1"
    assert connect["workspace_id"] == "W1"

    res = run_tool("im.connects_list", %{"provider" => "telegraph"})
    assert Jason.decode!(res.content) == %{"connects" => []}
  end

  test "im.provider_apis_list returns dynamic operation ids" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res = run_tool("im.provider_apis_list", %{"provider" => "slack", "connect_id" => "sl1"})
    refute res.error
    %{"apis" => apis} = Jason.decode!(res.content)

    post = Enum.find(apis, &(&1["operation_id"] == "im_api.slack.post_message"))
    canvas = Enum.find(apis, &(&1["operation_id"] == "im_api.slack.create_canvas"))

    assert post["required_scopes"] == ["chat:write"]
    assert post["scope_availability"] == "granted"
    refute post["missing_scopes"]

    assert canvas["required_scopes"] == ["canvases:write"]
    assert canvas["scope_availability"] == "missing"
    assert canvas["missing_scopes"] == ["canvases:write"]
    assert Enum.all?(apis, &(&1["helpable"] == true and &1["callable"] == true))

    provider_level =
      run_tool("im.provider_apis_list", %{"provider" => "slack"})
      |> Map.fetch!(:content)
      |> Jason.decode!()

    provider_post =
      Enum.find(provider_level["apis"], &(&1["operation_id"] == "im_api.slack.post_message"))

    assert provider_post["scope_availability"] == "unknown"

    malformed =
      run_tool("im.provider_apis_list", %{
        "provider" => "slack",
        "connect_id" => "sl-malformed"
      })
      |> Map.fetch!(:content)
      |> Jason.decode!()

    malformed_post =
      Enum.find(malformed["apis"], &(&1["operation_id"] == "im_api.slack.post_message"))

    assert malformed_post["scope_availability"] == "unknown"
    refute malformed_post["missing_scopes"]
  end

  test "im.provider_apis_list rejects a connect outside the visible set" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res =
      run_tool("im.provider_apis_list", %{
        "provider" => "slack",
        "connect_id" => "missing-connect"
      })

    assert res.error
    assert res.content =~ "connect not found"
  end

  test "dynamic IM candidates default on and follow disabled plugin refs" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    names = fn projection_opts ->
      %{agent_id: "a1", role: "router", runtime_kind: :internal}
      |> SalixAgent.TestSupport.with_plugin_projection(projection_opts)
      |> then(&ToolDisclosure.materialize("router", :internal, &1))
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])
    end

    assert "im_api.slack.post_message" in names.(tools: [], tool_prefixes: [])

    refute "im_api.slack.post_message" in names.(
             tools: [],
             tool_prefixes: [],
             disabled_tool_prefixes: ["im_api.slack."]
           )

    assert "im_api.slack.post_message" in names.(
             tools: ["im_api.slack.post_message"],
             tool_prefixes: [],
             disabled_tool_prefixes: ["im_api.slack."]
           )
  end

  test "workers disclose, discover, and dispatch only granted Slack operations" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    worker_ctx = ctx_for("worker", :internal, "aw1")

    worker_names =
      worker_ctx
      |> Map.fetch!(:tool_disclosure)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "im_api.slack.search" in worker_names
    assert "im_api.slack.fetch_file" in worker_names
    refute "im_api.slack.post_message" in worker_names
    refute "im_api.slack.fetch_image" in worker_names

    router_names =
      ctx_for("router", :internal)
      |> Map.fetch!(:tool_disclosure)
      |> Map.fetch!("tools")
      |> Enum.map(& &1["name"])

    assert "im_api.slack.search" in router_names
    assert "im_api.slack.post_message" in router_names
    assert "im_api.slack.fetch_file" in router_names
    assert "im_api.slack.fetch_image" in router_names

    [listed] =
      SessionToolDispatch.execute(
        [
          %{
            "id" => "worker-slack-apis",
            "name" => "im.provider_apis_list",
            "args" => %{"provider" => "slack", "connect_id" => "sl1"}
          }
        ],
        worker_ctx
      )

    refute listed.error

    assert listed.content |> Jason.decode!() |> Map.fetch!("apis") |> Enum.map(& &1["api"]) ==
             ["slack.fetch_file", "slack.search"]

    [read_result] =
      SessionToolDispatch.execute(
        [
          %{
            "id" => "worker-slack-search",
            "name" => "im_api.slack.search",
            "args" => %{"connect_id" => "sl1", "query" => "deploy"}
          }
        ],
        worker_ctx
      )

    refute read_result.error
    assert Jason.decode!(read_result.content)["api"] == "slack.search"
  end

  test "Slack Task-card publication keeps standing prompt visibility" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    disclosure = ctx("a1") |> Map.fetch!(:tool_disclosure)
    by_name = Map.new(disclosure["tools"], &{&1["name"], &1})

    assert by_name["im_api.slack.post_task_card"]["prompt_visibility"] == "manual"
    assert by_name["im_api.slack.post_task_card"]["callable"]
    assert by_name["im_api.slack.post_message"]["prompt_visibility"] == "hidden"

    section = ToolDisclosure.prompt_section(disclosure, :internal)

    assert section =~
             "- im_api.slack.post_task_card: Publish one native Slack Task surface after im_api.internal.task.create."
  end

  test "dynamic IM operation can be called directly when facts are known" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res =
      run_tool(
        "im_api.slack.post_message",
        %{
          "connect_id" => "sl1",
          "channel" => "C1",
          "text" => "hi",
          "thread_ts" => "123.45"
        }
      )

    refute res.error

    payload = Jason.decode!(res.content)

    assert Map.drop(payload["args"], ["tool_context"]) == %{
             "connect_id" => "sl1",
             "params" => %{"channel" => "C1", "text" => "hi", "thread_ts" => "123.45"},
             "tool_call_id" => "u1"
           }

    assert Map.drop(payload, ["args"]) == %{
             "agent_id" => "a1",
             "provider" => "slack",
             "api" => "slack.post_message"
           }
  end

  test "scope discovery evidence does not pre-empt direct Slack dispatch" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    missing_scope =
      run_tool("im_api.slack.create_canvas", %{
        "connect_id" => "sl1",
        "content" => "Meeting notes"
      })

    refute missing_scope.error
    missing_payload = Jason.decode!(missing_scope.content)
    assert missing_payload["api"] == "slack.create_canvas"
    assert get_in(missing_payload, ["args", "connect_id"]) == "sl1"

    unknown_scope =
      run_tool("im_api.slack.post_message", %{
        "connect_id" => "sl-malformed",
        "channel" => "C1",
        "text" => "Meeting notes"
      })

    refute unknown_scope.error
    unknown_payload = Jason.decode!(unknown_scope.content)
    assert unknown_payload["api"] == "slack.post_message"
    assert get_in(unknown_payload, ["args", "connect_id"]) == "sl-malformed"
  end

  test "call envelope dispatches known dynamic IM operation without discovery" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res =
      run_tool(
        "call",
        call_args("im_api.slack.post_message", %{
          "connect_id" => "sl1",
          "channel" => "C1",
          "text" => "hi"
        }),
        %{llm_tool_envelope: true}
      )

    refute res.error
    assert Jason.decode!(res.content)["api"] == "slack.post_message"
  end

  test "call envelope unwraps exactly one unambiguous params wrapper" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    params = %{
      "connect_id" => "internal",
      "conversation_id" => "conv-double-wrapped",
      "content" => [%{"type" => "text", "text" => "hello"}]
    }

    res =
      run_tool(
        "call",
        %{
          "params" => %{
            "tool" => "im_api.internal.send_message",
            "params" => params
          }
        },
        %{llm_tool_envelope: true}
      )

    refute res.error
    assert Jason.decode!(res.content)["api"] == "internal.send_message"

    assert Jason.decode!(res.content)["args"]["params"] ==
             Map.drop(params, ["connect_id"])
  end

  test "call envelope does not discard sibling fields" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    nested = %{
      "params" => %{
        "tool" => "im_api.internal.send_message",
        "params" => %{
          "connect_id" => "internal",
          "conversation_id" => "conv-double-wrapped",
          "content" => [%{"type" => "text", "text" => "hello"}]
        }
      },
      "unexpected" => true
    }

    res = run_tool("call", nested, %{llm_tool_envelope: true})

    assert res.status == "guidance"
    assert Jason.decode!(res.content)["error"] == "'tool' is required"
  end

  test "call envelope does not recursively unwrap a three-layer params wrapper" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    nested = %{
      "params" => %{
        "params" => %{
          "tool" => "im_api.internal.send_message",
          "params" => %{
            "connect_id" => "internal",
            "conversation_id" => "conv-triple-wrapped",
            "content" => [%{"type" => "text", "text" => "hello"}]
          }
        }
      }
    }

    res = run_tool("call", nested, %{llm_tool_envelope: true})

    assert res.status == "guidance"
    assert Jason.decode!(res.content)["error"] == "'tool' is required"
  end

  test "repair classifier leaves executable and historical direct calls at most once" do
    assert :not_recoverable ==
             Tools.recoverable_envelope_guidance(%{
               id: "executable-wrapper",
               name: "call",
               args: %{
                 "params" => %{
                   "tool" => "im_api.internal.send_message",
                   "params" => %{
                     "connect_id" => "internal",
                     "conversation_id" => "conv-double-wrapped",
                     "content" => [%{"type" => "text", "text" => "hello"}]
                   }
                 }
               }
             })

    assert :not_recoverable ==
             Tools.recoverable_envelope_guidance(%{
               id: "historical-direct",
               name: "env.exec",
               args: %{"command" => "echo already-ran"}
             })
  end

  test "call envelope guidance is returned for invalid params" do
    res =
      run_tool(
        "call",
        %{
          "tool" => "im_api.slack.post_message",
          "params" => "not an object"
        },
        %{llm_tool_envelope: true}
      )

    refute res.error
    out = Jason.decode!(res.content)
    assert out["status"] == "guidance"
    assert out["error"] == "'params' is required and must be a JSON object"
    assert out["tool"] == "im_api.slack.post_message"
  end

  test "dynamic IM operation returns help guidance when required params are missing" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    {res, log} =
      with_log(fn ->
        run_tool("im_api.slack.post_message", %{
          "connect_id" => "sl1",
          "channel" => "  ",
          "text" => "private message body"
        })
      end)

    refute res.error
    out = Jason.decode!(res.content)
    assert out["status"] == "guidance"
    assert out["error"] == "missing required params: channel (empty string)"
    assert out["help_tool"] == "help"
    assert out["help_params"] == %{"tool" => "im_api.slack.post_message"}
    refute log =~ "im_provider_operation_validation_failed"
    refute log =~ "private message body"
  end

  test "historical provider fetch returns a native VFS file block" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res =
      run_tool("im_api.slack.fetch_file", %{
        "connect_id" => "sl1",
        "file_id" => "F-report"
      })

    refute res.error

    assert [
             %{"type" => "text", "text" => result_json},
             %{
               "type" => "file",
               "path" => "/slack/files/report.pdf",
               "file_name" => "report.pdf",
               "mime_type" => "application/pdf"
             }
           ] = Jason.decode!(res.content)

    assert Jason.decode!(result_json)["vfs_path"] == "/slack/files/report.pdf"
  end

  test "historical generic-MIME provider image returns a native VFS image block" do
    Application.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res =
      run_tool("im_api.slack.fetch_image", %{
        "connect_id" => "sl1",
        "file_id" => "F-photo"
      })

    refute res.error

    assert [
             %{"type" => "text"},
             %{
               "type" => "image",
               "file_ref" => %{
                 "environment_id" => "vfs",
                 "path" => "/slack/files/photo.png"
               },
               "file_name" => "photo.png",
               "mime_type" => "image/png"
             }
           ] = Jason.decode!(res.content)
  end

  defp external_names(role) do
    ctx =
      %{agent_id: "a1", role: role, runtime_kind: :external}
      |> SalixAgent.TestSupport.with_plugin_projection()

    disclosure = ToolDisclosure.materialize(role, :external, ctx)

    disclosure
    |> ToolPolicy.external_specs_for()
    |> Enum.map(& &1["name"])
  end

  defp ctx_for(role, runtime_kind, agent_id \\ "a1") do
    base =
      %{
        agent_id: agent_id,
        session_id: "s1",
        role: role,
        runtime_kind: runtime_kind,
        visible_reply_guard: :clean,
        visible_reply_phase: :clean
      }
      |> SalixAgent.TestSupport.with_plugin_projection()

    Map.put(base, :tool_disclosure, ToolDisclosure.materialize(role, runtime_kind, base))
  end

  defp internal_api_names(role, runtime_kind) do
    ctx = ctx_for(role, runtime_kind)

    [result] =
      SessionToolDispatch.execute(
        [
          %{
            "id" => "list-internal-apis",
            "name" => "im.provider_apis_list",
            "args" => %{"provider" => "internal", "connect_id" => "internal"}
          }
        ],
        ctx
      )

    refute result.error

    result.content
    |> Jason.decode!()
    |> Map.fetch!("apis")
    |> Enum.map(& &1["api"])
  end
end
