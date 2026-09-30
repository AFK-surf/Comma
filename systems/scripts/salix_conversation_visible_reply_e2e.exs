# End-to-end validation for visible internal conversation replies.
#
# Run through Deno:
#   deno test --allow-all e2e/tests/salix_conversation_visible_reply_test.ts
#
# The product path under test is public HTTP only: admin/runtime REST APIs create
# the tenant, template, group, agents and conversations; conversation messages
# are written and read through `/v1/runtime/agent-groups/.../conversations`.

defmodule SalixConversationVisibleReplyE2E do
  @admin_token "conversation-visible-reply-e2e-admin"
  @timeout_ms 20_000

  def run do
    configure_s3_from_env!()
    Application.put_env(:salix_web, :api_token, @admin_token)
    Application.put_env(:salix_web, :port, 0)
    Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock)

    {:ok, _} = Application.ensure_all_started(:salix_web)
    {:ok, _} = SalixAgent.LLM.Mock.start_link()

    run_id = System.unique_integer([:positive])
    tenant_key = create_tenant_key!(run_id)
    template_id = create_template!(run_id)
    group_id = create_group!(tenant_key, run_id)

    run_worker_conversation!(tenant_key, group_id, template_id, run_id)
    run_router_conversation!(tenant_key, group_id, template_id, run_id)

    IO.puts("SALIX_CONVERSATION_VISIBLE_REPLY_E2E: PASS")
  rescue
    error ->
      IO.puts("SALIX_CONVERSATION_VISIBLE_REPLY_E2E: FAIL #{Exception.message(error)}")
      IO.puts(Exception.format(:error, error, __STACKTRACE__))
      System.halt(1)
  end

  defp run_worker_conversation!(tenant_key, group_id, template_id, run_id) do
    agent =
      post_runtime!(tenant_key, "/v1/runtime/agents", %{
        "group_id" => group_id,
        "template_id" => template_id,
        "name" => "Conversation worker #{run_id}",
        "role" => "worker"
      })

    agent_id = agent["agent_id"]
    visible_reply = "VISIBLE_WORKER_REPLY_#{run_id}"

    conversation = create_direct_conversation!(tenant_key, group_id, agent_id, run_id)
    conversation_id = conversation["conversation_id"]
    terminal_marker = "WORKER_TURN_COMPLETE_#{run_id}"

    script_visible_reply!(
      conversation_id,
      visible_reply,
      "worker-visible-reply-#{run_id}",
      terminal_marker
    )

    post_runtime!(
      tenant_key,
      "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
      %{
        "content" => [%{"type" => "text", "text" => "worker should reply visibly"}],
        "client_request_id" => "worker-message-#{run_id}"
      },
      201
    )

    messages = wait_for_visible_agent_reply!(tenant_key, group_id, conversation_id, visible_reply)
    assert_one_visible_agent_reply!(messages, agent_id, visible_reply, "worker conversation")
    wait_for_agent_terminal_marker!(tenant_key, agent_id, terminal_marker, "worker conversation")
    wait_for_agent_sessions_settled!(tenant_key, agent_id, "worker conversation")
  end

  defp run_router_conversation!(tenant_key, group_id, template_id, run_id) do
    router =
      post_runtime!(tenant_key, "/v1/runtime/agents", %{
        "group_id" => group_id,
        "template_id" => template_id,
        "name" => "Conversation router #{run_id}",
        "role" => "router"
      })

    router_id = router["agent_id"]

    patch_runtime!(tenant_key, "/v1/runtime/agent-groups/#{group_id}", %{
      "router_agent_id" => router_id
    })

    conversation =
      get_runtime!(tenant_key, "/v1/runtime/agent-groups/#{group_id}/router/conversation")

    conversation_id = conversation["conversation_id"]
    visible_reply = "VISIBLE_ROUTER_REPLY_#{run_id}"

    script_visible_reply!(
      conversation_id,
      visible_reply,
      "router-visible-reply-#{run_id}",
      "ROUTER_TURN_COMPLETE_#{run_id}"
    )

    post_runtime!(
      tenant_key,
      "/v1/runtime/agent-groups/#{group_id}/router/messages",
      %{
        "content" => [%{"type" => "text", "text" => "router should reply visibly"}],
        "client_request_id" => "router-message-#{run_id}"
      },
      201
    )

    messages = wait_for_visible_agent_reply!(tenant_key, group_id, conversation_id, visible_reply)
    assert_one_visible_agent_reply!(messages, router_id, visible_reply, "router conversation")

    conversation =
      get_runtime!(
        tenant_key,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}"
      )

    assert!(conversation["message_count"] == 2, "router conversation has user + visible reply")
  end

  defp script_visible_reply!(conversation_id, visible_reply, request_id, terminal_marker) do
    SalixAgent.LLM.Mock.script([
      {:assistant, "internal transcript only",
       [
         %{
           id: request_id,
           name: "call",
           args: %{
             "tool" => "im_api.internal.send_message",
             "params" => %{
               "connect_id" => "internal",
               "conversation_id" => conversation_id,
               "content" => [%{"type" => "text", "text" => visible_reply}]
             }
           }
         }
       ]},
      {:final, terminal_marker}
    ])
  end

  defp create_direct_conversation!(tenant_key, group_id, agent_id, run_id) do
    post_runtime!(
      tenant_key,
      "/v1/runtime/agent-groups/#{group_id}/conversations",
      %{
        "client_request_id" => "visible-worker-conversation-#{run_id}",
        "title" => "Visible worker reply",
        "participants" => [
          %{
            "actor_type" => "user",
            "user_id" => "current",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          },
          %{
            "actor_type" => "agent",
            "agent_id" => agent_id,
            "role_label" => "agent",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"}
          }
        ]
      },
      201
    )
  end

  defp wait_for_visible_agent_reply!(tenant_key, group_id, conversation_id, visible_reply) do
    eventually(fn ->
      messages =
        get_runtime!(
          tenant_key,
          "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages?limit=100"
        )

      if Enum.any?(messages, &(content_text(&1["content"]) == visible_reply)) do
        messages
      end
    end)
  end

  defp wait_for_agent_sessions_settled!(tenant_key, agent_id, label) do
    eventually(fn ->
      sessions =
        get_runtime!(tenant_key, "/v1/runtime/agents/#{agent_id}/sessions?include_hidden=true")

      cond do
        sessions == [] ->
          nil

        Enum.all?(sessions, &session_settled?/1) ->
          sessions

        true ->
          nil
      end
    end)
  rescue
    error ->
      raise(
        "#{label} did not settle before the next scripted LLM response: #{Exception.message(error)}"
      )
  end

  defp wait_for_agent_terminal_marker!(tenant_key, agent_id, terminal_marker, label) do
    eventually(fn ->
      sessions =
        get_runtime!(tenant_key, "/v1/runtime/agents/#{agent_id}/sessions?include_hidden=true")

      Enum.find_value(sessions, fn session ->
        session_id = session["session_id"]

        response =
          get_runtime!(
            tenant_key,
            "/v1/runtime/agents/#{agent_id}/sessions/#{session_id}/messages"
          )

        messages = response["messages"] || []

        if Enum.any?(messages, &(content_text(&1["content"]) == terminal_marker)) do
          messages
        end
      end)
    end)
  rescue
    error ->
      raise "#{label} did not commit terminal marker #{terminal_marker}: #{Exception.message(error)}"
  end

  defp session_settled?(session) do
    status = session["status"]
    activity_status = session["activity_status"]
    status not in ["active", "running"] and activity_status not in ["running", "queued"]
  end

  defp assert_one_visible_agent_reply!(messages, agent_id, visible_reply, label) do
    agent_messages = Enum.filter(messages, &(&1["actor_type"] == "agent"))

    assert!(
      length(agent_messages) == 1,
      "#{label} should expose exactly one visible agent message, got #{length(agent_messages)}"
    )

    [message] = agent_messages
    assert!(message["agent_id"] == agent_id, "#{label} visible reply agent id")
    assert!(content_text(message["content"]) == visible_reply, "#{label} visible reply content")
  end

  defp create_tenant_key!(run_id) do
    tenant =
      post_admin!("/v1/admin/tenants", %{
        "name" => "Conversation Visible #{run_id}"
      })

    key =
      post_admin!("/v1/admin/tenants/#{tenant["tenant_id"]}/api-keys", %{
        "name" => "conversation-visible-e2e"
      })

    key["key"] || raise("tenant API key response did not include key")
  end

  defp create_template!(run_id) do
    template =
      post_admin!("/v1/admin/templates", %{
        "template_id" => "conversation-visible-template-#{run_id}",
        "name" => "Conversation Visible #{run_id}",
        "model" => "mock-model"
      })

    template["template_id"] || raise("template response did not include template_id")
  end

  defp create_group!(tenant_key, run_id) do
    group =
      post_runtime!(tenant_key, "/v1/runtime/agent-groups", %{
        "name" => "Conversation Visible #{run_id}"
      })

    group["group_id"] || raise("group response did not include group_id")
  end

  defp post_admin!(path, body, expected_status \\ 201),
    do: request!(@admin_token, :post, path, body, expected_status)

  defp post_runtime!(token, path, body, expected_status \\ 201),
    do: request!(token, :post, path, body, expected_status)

  defp patch_runtime!(token, path, body, expected_status \\ 200),
    do: request!(token, :patch, path, body, expected_status)

  defp get_runtime!(token, path), do: request!(token, :get, path, nil, 200)

  defp request!(token, method, path, body, expected_status) do
    opts = [
      method: method,
      url: base_url() <> path,
      headers: [{"authorization", "Bearer " <> token}],
      retry: false
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)
    response = Req.request!(opts)

    assert!(
      response.status == expected_status,
      "#{method} #{path} returned #{response.status}, expected #{expected_status}: #{inspect(response.body)}"
    )

    response.body
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + @timeout_ms) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise("condition did not become true before timeout")
        end

        Process.sleep(100)
        eventually(fun, deadline)

      false ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise("condition did not become true before timeout")
        end

        Process.sleep(100)
        eventually(fun, deadline)

      value ->
        value
    end
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp content_text(content), do: to_string(content)

  defp base_url, do: SalixWeb.Application.base_url()

  defp configure_s3_from_env! do
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.AWS)
    put_env(:s3_endpoint, "SALIX_S3_ENDPOINT")
    put_env(:s3_region, "SALIX_S3_REGION")
    put_env(:s3_bucket, "SALIX_S3_BUCKET")
    put_env(:s3_access_key_id, "SALIX_S3_ACCESS_KEY_ID", System.get_env("AWS_ACCESS_KEY_ID"))

    put_env(
      :s3_secret_access_key,
      "SALIX_S3_SECRET_ACCESS_KEY",
      System.get_env("AWS_SECRET_ACCESS_KEY")
    )
  end

  defp put_env(key, name, fallback \\ nil) do
    case System.get_env(name) || fallback do
      value when is_binary(value) and value != "" -> Application.put_env(:salix_store, key, value)
      _ -> :ok
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
end

SalixConversationVisibleReplyE2E.run()
