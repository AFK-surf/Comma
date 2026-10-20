defmodule SalixAgent.ToolPolicyExtrasTest do
  @moduledoc """
  Session-scoped tool materialization, static role eligibility, and IM dynamic operation dispatch.
  """
  use SystemsClock.Case, async: false

  alias SalixAgent.{SessionToolDispatch, ToolDisclosure, Tools}
  import ExUnit.CaptureLog

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
    prev_im = SystemsRuntime.get_env(:salix_agent, :im_provider_mod)
    SystemsRuntime.delete_env(:salix_agent, :im_provider_mod)

    on_exit(fn ->
      if prev_im,
        do: SystemsRuntime.put_env(:salix_agent, :im_provider_mod, prev_im),
        else: SystemsRuntime.delete_env(:salix_agent, :im_provider_mod)
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

  test "im.provider_apis_list returns dynamic operation ids" do
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

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
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    res =
      run_tool("im.provider_apis_list", %{
        "provider" => "slack",
        "connect_id" => "missing-connect"
      })

    assert res.error
    assert res.content =~ "connect not found"
  end

  test "workers discover and dispatch only granted Slack operations" do
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

    worker_ctx = ctx_for("worker", :internal, "aw1")

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

  test "dynamic IM operation can be called directly when facts are known" do
    SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

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

  for {name, envelope} <- [
        {"call envelope does not discard sibling fields",
         %{
           "params" => %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => "conv-double-wrapped",
               "content" => [%{"type" => "text", "text" => "hello"}]
             }
           },
           "unexpected" => true
         }},
        {"call envelope does not recursively unwrap a three-layer params wrapper",
         %{
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
         }}
      ] do
    test name do
      SystemsRuntime.put_env(:salix_agent, :im_provider_mod, FakeIMProvider)

      res = run_tool("call", unquote(Macro.escape(envelope)), %{llm_tool_envelope: true})

      assert res.status == "guidance"
      assert Jason.decode!(res.content)["error"] == "'tool' is required"
    end
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
end
