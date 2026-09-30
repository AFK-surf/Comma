defmodule SalixWeb.ConversationMessagingTest do
  @moduledoc """
  Conversation messaging end-to-end:
  POST conversations/{id}/messages accepts durable group conversation messages
  without synchronously materializing a runtime session. Router conversation
  messages remain the explicit special case that deliver into the router agent.
  Also covers the message validation contract, activity-surface dismissal, and
  the group conversation SSE events stream (`message_created` over a real
  chunked connection).
  """
  use ExUnit.Case, async: false

  alias SalixAgent.LLM.Mock

  alias SalixIM.{
    ConversationServer,
    ProviderConnects,
    RouterConversationInput,
    TaskConversationInput
  }

  alias SalixStore.{Ids, Keys}

  @host {127, 0, 0, 1}
  @token "test-token"

  defmodule RecordingSlackAPI do
    @moduledoc false
    use Agent
    import Plug.Conn

    def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def requests, do: Agent.get(__MODULE__, &Enum.reverse/1)

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw_body, conn} = read_body(conn)

      Agent.update(__MODULE__, fn requests ->
        [%{method: conn.method, path: conn.request_path, body: raw_body} | requests]
      end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{"ok" => true, "channel" => "C-loop", "ts" => "700.001"})
      )
    end
  end

  defmodule RecordingFeishuDirectDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.FeishuDirectDelivery

    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def records, do: Agent.get(__MODULE__, & &1)

    @impl true
    def post_text(connect, target, text, mentions, operation_ref) do
      record = %{
        "connect_id" => connect["connect_id"],
        "target" => target,
        "text" => text,
        "mentions" => mentions,
        "operation_ref" => operation_ref
      }

      Agent.get_and_update(__MODULE__, fn records ->
        existing = records[operation_ref]
        status = %{"message_id" => "om_calendar", "operation_ref" => operation_ref}

        if existing do
          {{:ok, status}, put_in(records, [operation_ref, "attempts"], existing["attempts"] + 1)}
        else
          {{:ok, status}, Map.put(records, operation_ref, Map.put(record, "attempts", 1))}
        end
      end)
    end

    @impl true
    def post_file(_agent_id, _connect, _target, _path, _blob_ref, _operation_ref),
      do: {:error, :unexpected_file_delivery}
  end

  defmodule CaptureAgentDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent_id, _payload, _opts), do: {:ok, :created}

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_implemented}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_implemented}

    @impl true
    def consult_memory(agent_id, session_id, question, request_id, _opts) do
      send(self(), {:memory_consulted, agent_id, session_id, question, request_id})
      {:ok, %{"status" => "answered", "answer" => "captured"}}
    end
  end

  defmodule BlockingMemoryDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.AgentDelivery

    @impl true
    def deliver(_agent_id, _payload, _opts), do: {:ok, :created}

    @impl true
    def get_session(_agent_id, _session_id, _opts), do: {:error, :not_implemented}

    @impl true
    def get_session_messages(_agent_id, _session_id), do: {:error, :not_implemented}

    @impl true
    def consult_memory(_agent_id, _session_id, _question, _request_id, _opts) do
      owner = :persistent_term.get({__MODULE__, :owner})
      send(owner, {:memory_consultation_started, self()})

      receive do
        :finish_memory_consultation -> {:ok, %{"status" => "answered", "answer" => "stale"}}
      end
    end
  end

  # Routing/session-isolation fixtures keep the Worker busy. Its scripted LLM
  # does not publish a Task result; testing silent-stop recovery belongs to
  # the TaskWorkerWatch actor tests, not these exact-message assertions.
  defmodule WorkingSessionActivity do
    @behaviour SalixIM.Ports.SessionActivity
    @impl true
    def get(_agent_id, _session_id),
      do: {:ok, %{"state" => "active", "status" => "is working..."}}

    @impl true
    def subscribe(_agent_id, _session_id), do: :ok
    @impl true
    def unsubscribe(_agent_id, _session_id), do: :ok
  end

  setup context do
    if context[:keep_worker_working] do
      previous = Application.get_env(:salix_im, :session_activity_mod)
      Application.put_env(:salix_im, :session_activity_mod, WorkingSessionActivity)
      on_exit(fn -> put_or_delete_env(:salix_im, :session_activity_mod, previous) end)
    end

    :ok
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    prev = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    prev_visible_reply = Application.get_env(:salix_agent, :visible_reply_mod)
    prev_oauth_store_mod = Application.get_env(:salix_agent, :oauth_store_mod)
    prev_task_create_mod = Application.get_env(:salix_im, :task_create_mod)
    prev_agent_delivery = Application.get_env(:salix_im, :agent_delivery_mod)
    prev_agent_workspace = Application.get_env(:salix_im, :agent_workspace_mod)
    prev_provider_app_store = Application.get_env(:salix_im, :provider_app_store_mod)
    prev_api_token = Application.get_env(:salix_web, :api_token)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:salix_web, :api_token, @token)

    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end

    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    Application.put_env(:salix_agent, :visible_reply_mod, Salix.Bindings.AgentVisibleReply)
    Application.put_env(:salix_agent, :oauth_store_mod, Salix.Bindings.AgentOAuthStore)
    Application.put_env(:salix_im, :task_create_mod, Salix.Bindings.AgentConversations)
    Application.put_env(:salix_im, :agent_delivery_mod, Salix.Bindings.IMAgentDelivery)
    Application.put_env(:salix_im, :agent_workspace_mod, Salix.Bindings.IMAgentWorkspace)
    Application.put_env(:salix_im, :provider_app_store_mod, Salix.Bindings.IMProviderAppStore)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev)
      Application.put_env(:salix_agent, :llm, prev_llm)
      put_or_delete_env(:salix_agent, :im_provider_mod, prev_im_provider)
      put_or_delete_env(:salix_agent, :visible_reply_mod, prev_visible_reply)
      put_or_delete_env(:salix_agent, :oauth_store_mod, prev_oauth_store_mod)
      put_or_delete_env(:salix_im, :task_create_mod, prev_task_create_mod)
      put_or_delete_env(:salix_im, :agent_delivery_mod, prev_agent_delivery)
      put_or_delete_env(:salix_im, :agent_workspace_mod, prev_agent_workspace)
      put_or_delete_env(:salix_im, :provider_app_store_mod, prev_provider_app_store)
      put_or_delete_env(:salix_web, :api_token, prev_api_token)
    end)

    uniq = System.unique_integer([:positive])

    tenant_id =
      admin_req(:post, "/v1/admin/tenants", json: %{name: "Conv Tenant"}).body["tenant_id"]

    tenant_key =
      admin_req(:post, "/v1/admin/tenants/#{tenant_id}/api-keys", json: %{name: "test"}).body[
        "key"
      ]

    Process.put(:test_tenant_id, tenant_id)
    Process.put(:test_tenant_key, tenant_key)

    template =
      admin_req(:post, "/v1/admin/templates",
        json: %{template_id: "tmpl-conv-#{uniq}", name: "Conv", model: "gpt-test"}
      ).body

    group =
      req(:post, "/v1/runtime/agent-groups", json: %{name: "Conv group"}).body

    agent =
      req(:post, "/v1/runtime/agents",
        json: %{
          group_id: group["group_id"],
          template_id: template["template_id"],
          name: "Conv agent",
          role: "router"
        }
      ).body

    assert req(:patch, "/v1/runtime/agent-groups/#{group["group_id"]}",
             json: %{router_agent_id: agent["agent_id"]}
           ).status == 200

    {:ok,
     group_id: group["group_id"],
     agent_id: agent["agent_id"],
     template_id: template["template_id"],
     tenant_id: tenant_id}
  end

  # Tenant-scoped calls use the tenant API key; admin_req uses the admin token
  # for the genuinely-admin surface (tenant + key + template creation).
  defp req(method, path, opts \\ []), do: req_as(tenant_key(), method, path, opts)

  @doc false
  def terminal_llm_response(content) when is_binary(content) do
    {:assistant, content,
     [
       %{
         id: "test-end-turn-#{System.unique_integer([:positive, :monotonic])}",
         name: "end_turn",
         args: %{"outcome" => "done"}
       }
     ]}
  end

  defp admin_req(method, path, opts), do: req_as(@token, method, path, opts)

  defp req_as(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token}]
    Req.request!([method: method, url: base() <> path, headers: headers] ++ opts)
  end

  defp tenant_key, do: Process.get(:test_tenant_key)

  defp base, do: SalixWeb.Application.base_url()

  defp router_session_id(agent_id, group_id),
    do:
      unwrap_router_session_id(ProviderConnects.agent_group_router_session_id(agent_id, group_id))

  defp unwrap_router_session_id({:ok, session_id}), do: session_id

  defp assert_direct_router_session_message(agent_id, group_id, source_id, text) do
    session_id = router_session_id(agent_id, group_id)

    assert eventually(fn ->
             case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
               {:ok, session} ->
                 Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
                   message.role == "user" and
                     to_string(Map.get(message, :source_message_id) || "") == source_id and
                     String.contains?(to_string(Map.get(message, :content) || ""), text)
                 end)

               _ ->
                 false
             end
           end)

    assert {:ok, messages} =
             SalixIM.RouterConversationProjection.list_group_router_messages(group_id)

    assert Enum.count(messages, &(&1["source_message_id"] == source_id)) == 1

    {:ok, session} = SalixAgent.InternalSessionStore.read(agent_id, session_id)
    session
  end

  defmodule AttachmentWriteFault do
    @moduledoc false
    @behaviour SalixStore.S3
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> Map.new(opts) end, name: __MODULE__)
    def attempts, do: Agent.get(__MODULE__, & &1.attempts)

    @impl true
    def put(key, body, opts) do
      failure =
        Agent.get_and_update(__MODULE__, fn state ->
          if key == state.key do
            attempt = state.attempts + 1
            fail? = state.mode == :always or attempt == 2
            {if(fail?, do: state.reason), %{state | attempts: attempt}}
          else
            {nil, state}
          end
        end)

      if failure, do: {:error, failure}, else: SalixStore.S3.Fake.put(key, body, opts)
    end

    defdelegate get(key, opts), to: SalixStore.S3.Fake
    defdelegate list(prefix, opts), to: SalixStore.S3.Fake
    defdelegate put_stream(key, stream, opts), to: SalixStore.S3.Fake
    defdelegate stream(key, opts), to: SalixStore.S3.Fake
    defdelegate head(key), to: SalixStore.S3.Fake
    defdelegate delete(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_create(key, opts), to: SalixStore.S3.Fake
    defdelegate multipart_upload_part(key, upload_id, part_number, body), to: SalixStore.S3.Fake
    defdelegate multipart_complete(key, upload_id, parts), to: SalixStore.S3.Fake
    defdelegate multipart_abort(key, upload_id), to: SalixStore.S3.Fake
    defdelegate multipart_uploads(prefix, opts), to: SalixStore.S3.Fake
  end

  @tag :worker_file_delivery
  test "HTTP-triggered Agent corrects a rejected file_ref block before publishing a downloadable PDF",
       %{
         group_id: group_id,
         agent_id: agent_id
       } do
    conversation = create_conversation_with_agent(group_id, agent_id, title: "Deliver a PDF")
    conversation_id = conversation["conversation_id"]
    participants = conversation_participants(group_id, conversation_id)
    user = Enum.find(participants, &(&1["actor_type"] == "user"))
    participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    session_id = get_in(participant, ["payload", "session_id"])
    pdf = File.read!(Path.expand("../../salix_agent/test/fixtures/attached-report.pdf", __DIR__))
    path = "/artifacts/Apple_Report_2026.pdf"
    assert %{status: 200} = req(:put, "/v1/runtime/agents/#{agent_id}/files" <> path, body: pdf)

    block = %{
      "type" => "file",
      "file_name" => "Apple_Report_2026.pdf",
      "mime_type" => "application/pdf"
    }

    forged_ref = %{
      "kind" => "blob",
      "uuid" => String.duplicate("a", 32),
      "hash" => String.duplicate("b", 64),
      "size" => 1
    }

    bad =
      block
      |> Map.put("file_ref", %{"environment_id" => "vfs", "path" => path})
      |> Map.put("blob_ref", forged_ref)

    good = block |> Map.put("path", path) |> Map.put("blob_ref", forged_ref)

    send_call = fn id, file ->
      %{
        id: id,
        name: "call",
        args: %{
          "tool" => "im_api.internal.send_message",
          "params" => %{
            "connect_id" => "internal",
            "conversation_id" => conversation_id,
            "content" => [%{"type" => "text", "text" => "PDF report"}, file]
          }
        }
      }
    end

    Mock.script([
      {:assistant, "", [send_call.("bad-file-block", bad)]},
      {:assistant, "", [send_call.("corrected-file-block", good)]},
      terminal_llm_response("")
    ])

    assert %{status: 201} =
             req(
               :post,
               "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
               json: %{
                 participant_id: user["participant_id"],
                 actor_type: "user",
                 user_id: "current",
                 content: [%{type: "text", text: "Please deliver the PDF file"}],
                 client_request_id: "pdf-request"
               }
             )

    session =
      eventually(fn ->
        with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id),
             {:ok, %{"status" => status}} when status in ["completed", "failed"] <-
               SalixAgent.InternalSession.lookup_async_call(session, "corrected-file-block") do
          session
        else
          _ -> nil
        end
      end)

    assert {:ok, %{"status" => "completed"}} =
             SalixAgent.InternalSession.lookup_async_call(session, "corrected-file-block")

    assert {:ok, %{"status" => "failed"} = rejected} =
             SalixAgent.InternalSession.lookup_async_call(session, "bad-file-block")

    assert Jason.encode!(rejected) =~ "path"
    assert Jason.encode!(rejected) =~ "VFS"

    response =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages")

    assert response.status == 200
    assert [message] = Enum.filter(response.body, &(&1["actor_type"] == "agent"))
    assert [_, file] = message["content"]
    assert file["path"] == path
    refute file["blob_ref"] == forged_ref
    assert {:ok, %{"ref" => ref}} = SalixAgent.AgentWorkspace.entry(agent_id, path)
    assert file["blob_ref"] == ref
    assert %{status: 200, body: ^pdf} = req(:get, "/v1/runtime/agents/#{agent_id}/files" <> path)
  end

  for {name, mode, reason, outcome, failures} <- [
        {"recovers after a partial multi-file materialization", :second, {:http, 503},
         "delivered", 1},
        {"exhausts the existing budget during a storage outage", :always, {:http, 503}, "failed",
         3},
        {"does not retry permanent storage rejection", :always, {:http, 403}, "failed", 1}
      ] do
    @tag :worker_file_delivery
    test "Worker attachment delivery #{name}", context do
      %{group_id: group_id, agent_id: router_id, template_id: template_id} = context

      worker =
        req(:post, "/v1/runtime/agents",
          json: %{
            group_id: group_id,
            template_id: template_id,
            name: "PDF worker",
            role: "worker"
          }
        ).body

      worker_id = worker["agent_id"]

      assert {:ok, task} =
               SalixCluster.TaskSchedules.create_task_conversation(
                 group_id,
                 router_id,
                 worker_id,
                 %{
                   content: "Prepare the PDF",
                   title: "PDF task",
                   client_request_id: "pdf-task",
                   origin_session_id: router_session_id(router_id, group_id)
                 }
               )

      conversation_id = task["conversation_id"]
      participants = conversation_participants(group_id, conversation_id)
      worker_participant = Enum.find(participants, &(&1["agent_id"] == worker_id))
      router_participant = Enum.find(participants, &(&1["agent_id"] == router_id))
      worker_session_id = get_in(worker_participant, ["payload", "session_id"])

      eventually_admission(group_id, conversation_id, task["message_id"], worker_participant)

      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(worker_id, worker_session_id) do
          {:ok, session} -> SalixAgent.InternalSession.status(session) == :idle
          _ -> false
        end
      end)

      paths = ["/artifacts/report.pdf", "/artifacts/notes.txt"]

      bodies = [
        File.read!(Path.expand("../../salix_agent/test/fixtures/attached-report.pdf", __DIR__)),
        "notes"
      ]

      for {path, body} <- Enum.zip(paths, bodies) do
        assert %{status: 200} =
                 req(:put, "/v1/runtime/agents/#{worker_id}/files" <> path, body: body)
      end

      # Only the receiving workspace's PUT is faulted. The production binding,
      # attachment mapper, ParticipantActor and Agent session delivery all run.
      start_supervised!(
        {AttachmentWriteFault,
         key: Keys.agent_workspace_state(router_id),
         attempts: 0,
         mode: unquote(mode),
         reason: unquote(Macro.escape(reason))}
      )

      Application.put_env(:salix_store, :s3_backend, AttachmentWriteFault)
      old_backoff = Application.get_env(:salix_im, :conversation_delivery_retry_backoff_ms)
      Application.put_env(:salix_im, :conversation_delivery_retry_backoff_ms, 25)

      on_exit(fn ->
        put_or_delete_env(:salix_im, :conversation_delivery_retry_backoff_ms, old_backoff)
      end)

      blocks =
        Enum.map(paths, &%{"type" => "file", "path" => &1, "file_name" => Path.basename(&1)})

      assert {:ok, sent} =
               Salix.Bindings.AgentIMProvider.call_api(
                 worker_id,
                 "internal",
                 "internal.send_message",
                 %{
                   "connect_id" => "internal",
                   "tool_call_id" => "deliver-worker-files",
                   "params" => %{
                     "conversation_id" => conversation_id,
                     "content" => [%{"type" => "text", "text" => "Files ready"} | blocks]
                   },
                   "tool_context" => %{
                     "runtime_kind" => "internal",
                     "session_id" => worker_session_id
                   }
                 }
               )

      message_id = sent["message_id"]

      progress = eventually_admission(group_id, conversation_id, message_id, router_participant)

      if unquote(outcome) == "failed",
        do: assert(AttachmentWriteFault.attempts() == unquote(failures))

      source_id =
        "groupconv:#{conversation_id}:#{message_id}:#{router_participant["participant_id"]}"

      if unquote(outcome) == "delivered" do
        session =
          eventually(fn ->
            with {:ok, session} <-
                   SalixAgent.InternalSessionStore.read(
                     router_id,
                     router_session_id(router_id, group_id)
                   ),
                 true <-
                   Enum.any?(
                     SalixAgent.InternalSession.get(session, :messages),
                     &(Map.get(&1, :source_message_id) == source_id)
                   ) do
              session
            else
              _ -> nil
            end
          end)

        assert [_] =
                 Enum.filter(
                   SalixAgent.InternalSession.get(session, :messages),
                   &(&1.role == "user" and Map.get(&1, :source_message_id) == source_id)
                 )

        for {{path, body}, index} <- Enum.zip(paths, bodies) |> Enum.with_index(1) do
          local = "/.conversation-attachments/#{message_id}/#{index}-#{Path.basename(path)}"

          assert %{status: 200, body: ^body} =
                   req(:get, "/v1/runtime/agents/#{router_id}/files" <> local)

          assert {:ok, %{"ref" => source_ref}} = SalixAgent.AgentWorkspace.entry(worker_id, path)

          assert {:ok, %{"ref" => ^source_ref}} =
                   SalixAgent.AgentWorkspace.entry(router_id, local)
        end
      else
        assert inspect(progress["last_rejection"]) =~ "cannot share Conversation attachment"

        case SalixAgent.InternalSessionStore.read(
               router_id,
               router_session_id(router_id, group_id)
             ) do
          {:ok, session} ->
            refute Enum.any?(
                     SalixAgent.InternalSession.get(session, :messages),
                     &(Map.get(&1, :source_message_id) == source_id)
                   )

          {:error, :not_found} ->
            :ok
        end
      end

      assert %{status: 200, body: messages} =
               req(
                 :get,
                 "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
               )

      assert [_] = Enum.filter(messages, &(&1["message_id"] == message_id))
    end
  end

  test "memory consultation search resolves a Task hit to its exact Worker Session", %{
    group_id: group_id,
    agent_id: router_id,
    template_id: template_id
  } do
    Application.put_env(:salix_im, :agent_delivery_mod, CaptureAgentDelivery)

    worker =
      req(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Recall worker",
          role: "worker"
        }
      ).body

    attrs = %{
      "title" => "Recall deployment",
      "content" => "The recall needle is blue deployment.",
      "client_request_id" => "recall-task-#{System.unique_integer([:positive])}"
    }

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               group_id,
               router_id,
               worker["agent_id"],
               attrs
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             TaskConversationInput.create_with_id(
               group_id,
               conversation_id,
               router_id,
               worker["agent_id"],
               attrs
               |> Map.put("schedule", %{
                 "schedule_id" => nil,
                 "command" => attrs["content"]
               })
               |> Map.put("initial_message_attrs", %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => router_id,
                 "content" => attrs["content"],
                 "metadata" => %{"message_type" => "task_command"},
                 "client_request_id" => "delegate-" <> conversation_id
               })
             )

    assert {:ok, %{targets: [target], truncated: false}} =
             Salix.Bindings.AgentConversations.search_worker_sessions(
               group_id,
               "recall needle",
               [],
               10
             )

    assert target.agent_id == worker["agent_id"]
    assert Ids.valid_participant_id?(target.participant_id)
    assert Ids.valid_session_id?(target.session_id)
    assert target.runtime_kind == "internal"
    assert target.conversation_ref["conversation_id"] == conversation_id
    assert target.conversation_ref["snippet"] =~ "recall needle"

    assert {:ok, %{targets: [keyword_target], truncated: false}} =
             Salix.Bindings.AgentConversations.search_worker_sessions(
               group_id,
               "unrelated recall deployment words",
               [],
               10
             )

    assert keyword_target.agent_id == worker["agent_id"]
    assert keyword_target.session_id == target.session_id

    assert {:ok, %{targets: [referenced_target], truncated: false}} =
             Salix.Bindings.AgentConversations.search_worker_sessions(
               group_id,
               "keywords that do not match",
               [%{"conversation_id" => conversation_id}],
               10
             )

    assert referenced_target.agent_id == worker["agent_id"]
    assert referenced_target.session_id == target.session_id
    assert referenced_target.conversation_ref["conversation_id"] == conversation_id

    assert {:ok, before_conversation} =
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, before_participants} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               conversation_id
             )

    assert {:ok, before_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 100
             )

    assert {:ok, %{"status" => "answered", "answer" => "captured"}} =
             Salix.Bindings.AgentConversations.consult_worker_session(
               group_id,
               target,
               "What did this Worker remember?",
               "memory-consultation-test",
               timeout: 1_000
             )

    assert_receive {:memory_consulted, worker_id, session_id, "What did this Worker remember?",
                    "memory-consultation-test"}

    assert worker_id == worker["agent_id"]
    assert session_id == target.session_id

    assert {:ok, ^before_conversation} =
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id)

    assert {:ok, ^before_participants} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               conversation_id
             )

    assert {:ok, ^before_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               conversation_id,
               limit: 100
             )

    Application.put_env(:salix_im, :agent_delivery_mod, BlockingMemoryDelivery)
    :persistent_term.put({BlockingMemoryDelivery, :owner}, self())
    on_exit(fn -> :persistent_term.erase({BlockingMemoryDelivery, :owner}) end)

    stale_consultation =
      Task.async(fn ->
        Salix.Bindings.AgentConversations.consult_worker_session(
          group_id,
          target,
          "Can a removed Participant still authorize this answer?",
          "memory-consultation-stale-binding",
          timeout: 1_000
        )
      end)

    assert_receive {:memory_consultation_started, consultation_pid}

    assert {:ok, _participant} =
             ConversationServer.deactivate_group_conversation_participant(
               group_id,
               conversation_id,
               target.participant_id
             )

    send(consultation_pid, :finish_memory_consultation)
    assert {:error, _reason} = Task.await(stale_consultation, 1_000)

    assert {:ok, %{targets: [], truncated: false}} =
             Salix.Bindings.AgentConversations.search_worker_sessions(
               group_id,
               "recall needle",
               [%{"conversation_id" => Ids.new_conversation_id()}],
               10
             )
  end

  test "Feishu calendar notifications deliver directly without creating a Router Conversation",
       %{group_id: group_id, tenant_id: tenant_id, agent_id: router_id} do
    start_supervised!(RecordingFeishuDirectDelivery)
    previous_delivery = Application.get_env(:salix_im, :feishu_direct_delivery_mod)

    Application.put_env(
      :salix_im,
      :feishu_direct_delivery_mod,
      RecordingFeishuDirectDelivery
    )

    on_exit(fn ->
      put_or_delete_env(:salix_im, :feishu_direct_delivery_mod, previous_delivery)
    end)

    now = System.system_time(:millisecond)

    connect = %{
      "connect_id" => "feishu-calendar-#{System.unique_integer([:positive])}",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "feishu",
      "status" => "connected",
      "app_name" => "calendar-notify-test",
      "app_id" => "cli_calendar_notify",
      "app_secret" => "secret",
      "inbound_agent_id" => router_id,
      "bot_open_id" => "ou_bot",
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, ^connect} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(group_id, connect["connect_id"]),
               connect
             )

    target = %{
      "provider" => "feishu",
      "mode" => "notify",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect["connect_id"],
      "chat_id" => "oc_calendar",
      "mentions" => %{
        "mode" => "users",
        "users" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
      }
    }

    event = %{
      "event_id" => "evt-calendar-1",
      "title" => "项目同步会",
      "start_time" => "2026-07-20T10:00:00+08:00",
      "time_zone" => "Asia/Shanghai",
      "meet_url" => "https://meet.google.com/abc-defg-hij"
    }

    assert {:ok, :queued} =
             Salix.Bindings.MeetingCalendarNotifier.notify(target, event, "occurrence-1")

    assert {:ok, :queued} =
             Salix.Bindings.MeetingCalendarNotifier.notify(target, event, "occurrence-1")

    assert %{
             "calendar-notify:occurrence-1" => %{
               "attempts" => 2,
               "connect_id" => connect_id,
               "operation_ref" => "calendar-notify:occurrence-1",
               "target" => %{"chat_id" => "oc_calendar", "chat_type" => "group"},
               "mentions" => %{
                 "mode" => "users",
                 "users" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
               }
             }
           } = RecordingFeishuDirectDelivery.records()

    assert connect_id == connect["connect_id"]
  end

  defmodule TwoTaskDelegationLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    use Agent

    def start_link(_opts \\ []) do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    def configure(config) when is_map(config) do
      ensure_started()
      Agent.update(__MODULE__, fn _ -> config end)
    end

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete(messages, tools, llm_opts),
      do: complete_stream(messages, tools, fn _ -> :ok end, llm_opts)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, tools, on_delta, _llm_opts) do
      config = config()

      cond do
        completed_delegate_results?(messages) ->
          stream("delegated", on_delta)
          SalixWeb.ConversationMessagingTest.terminal_llm_response("delegated")

        router_task_request?(messages, tools) ->
          stream("delegating two tasks", on_delta)

          {:assistant, "delegating two tasks",
           [
             %{
               id: "delegate-a",
               name: "call",
               args: %{
                 "tool" => "im_api.internal.task.create",
                 "params" => %{
                   "connect_id" => "internal",
                   "agent_id" => config.target_agent_id,
                   "content" => config.task_a_content,
                   "title" => "Task A"
                 }
               }
             },
             %{
               id: "delegate-b",
               name: "call",
               args: %{
                 "tool" => "im_api.internal.task.create",
                 "params" => %{
                   "connect_id" => "internal",
                   "agent_id" => config.target_agent_id,
                   "content" => config.task_b_content,
                   "title" => "Task B"
                 }
               }
             }
           ]}

        true ->
          stream("worker received task", on_delta)
          SalixWeb.ConversationMessagingTest.terminal_llm_response("worker received task")
      end
    end

    defp ensure_started do
      case Process.whereis(__MODULE__) do
        nil -> {:ok, _pid} = start_link()
        _pid -> :ok
      end
    end

    defp config do
      ensure_started()
      Agent.get(__MODULE__, & &1)
    end

    defp completed_delegate_results?(messages) do
      ids =
        messages
        |> Enum.filter(fn message ->
          (Map.get(message, :role) || Map.get(message, "role")) == "runtime" and
            (Map.get(message, :type) || Map.get(message, "type")) == "tool_call_completed"
        end)
        |> Enum.map(&(Map.get(&1, :source_tool_call_id) || Map.get(&1, "source_tool_call_id")))
        |> MapSet.new()

      MapSet.subset?(MapSet.new(["delegate-a", "delegate-b"]), ids)
    end

    defp router_task_request?(messages, tools) do
      has_tool?(tools, "call") and
        messages_text(messages) =~ "create two tasks for the codex worker"
    end

    defp has_tool?(tools, name) do
      Enum.any?(tools, &((Map.get(&1, "name") || Map.get(&1, :name)) == name))
    end

    defp messages_text(messages) do
      messages
      |> Enum.map(&(Map.get(&1, :content) || Map.get(&1, "content") || ""))
      |> Enum.map_join("\n", &content_text/1)
    end

    defp content_text(content) when is_binary(content), do: content

    defp content_text(content) when is_list(content) do
      content
      |> Enum.map(fn
        %{"text" => text} -> text
        %{text: text} -> text
        other -> inspect(other)
      end)
      |> Enum.join("\n")
    end

    defp content_text(content), do: to_string(content)

    defp stream(text, on_delta) do
      if text != "", do: on_delta.(text)
    end
  end

  defp fake_dump_body(%{body: body}), do: body
  defp fake_dump_body(body), do: body

  defp create_conversation(group_id, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

    req(:post, "/v1/runtime/agent-groups/#{group_id}/conversations",
      json:
        attrs
        |> Map.put_new("client_request_id", "test-create-#{System.unique_integer([:positive])}")
        |> Map.put_new("title", "Chat")
        |> Map.put_new("participants", [])
    ).body
  end

  defp create_conversation_with_agent(group_id, agent_id, attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    now = System.system_time(:millisecond)

    create_conversation(group_id, %{
      "title" => attrs["title"] || "Chat",
      "participants" => [
        %{
          "actor_type" => "user",
          "user_id" => "current",
          "state" => "active",
          "notification_filter" => %{"messages" => "all", "statuses" => "none"},
          "created_at" => now,
          "updated_at" => now
        },
        %{
          "actor_type" => "agent",
          "agent_id" => agent_id,
          "role_label" => "agent",
          "state" => "active",
          "notification_filter" => %{"messages" => "all", "statuses" => "none"},
          "created_at" => now,
          "updated_at" => now
        }
      ]
    })
  end

  defp conversation_participants(group_id, conversation_id) do
    req(
      :get,
      "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/participants"
    ).body["participants"] || []
  end

  test "provider participant message route queues provider-only delivery", %{group_id: group_id} do
    conversation =
      create_conversation(group_id, %{
        "title" => "Provider route",
        "participants" => [
          %{
            "actor_type" => "provider",
            "provider" => "slack",
            "role_label" => "slack_thread",
            "state" => "active",
            "notification_filter" => %{"messages" => "all", "statuses" => "none"},
            "payload" => %{
              "connect_id" => "route-connect",
              "workspace_id" => "T-route",
              "channel_id" => "C-route",
              "thread_ts" => "111.000"
            }
          }
        ]
      })

    conversation_id = conversation["conversation_id"]
    assert SalixStore.Ids.valid_conversation_id?(conversation_id)

    [provider_participant] = conversation_participants(group_id, conversation_id)
    participant_id = provider_participant["participant_id"]
    assert SalixStore.Ids.valid_participant_id?(participant_id)

    response =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/provider-participants/#{URI.encode_www_form(participant_id)}/messages",
        json: %{
          "idempotency_key" => "route-provider-message",
          "content" => [%{"type" => "text", "text" => "Task: https://task.example"}],
          "metadata" => %{"source" => "route_test"}
        }
      )

    assert response.status == 202
    assert response.body["delivery_status"] == "queued"
    assert response.body["participant_id"] == participant_id

    [command] =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages").body

    assert command["kind"] == "app_event"
    assert command["delivery_filter"] == %{"participant_ids" => [participant_id]}

    delivery_record_key =
      delivery_key(
        group_id,
        conversation_id,
        response.body["message_id"],
        participant_id
      )

    delivery = eventually_delivery(delivery_record_key)
    assert delivery["delivery_kind"] == "participant_notification"
    assert delivery["notification_kind"] == "provider_participant_message"
    assert delivery["participant_actor_type"] == "provider"
    assert delivery["participant_payload"]["connect_id"] == "route-connect"
    assert delivery["participant_payload"]["channel_id"] == "C-route"
    assert delivery["participant_payload"]["thread_ts"] == "111.000"

    assert delivery["message_content"] == [
             %{"type" => "text", "text" => "Task: https://task.example"}
           ]
  end

  test "internal Task-create provider returns production binding validation failures as errors",
       %{
         group_id: group_id,
         agent_id: router_id
       } do
    assert {:error, "content is required"} =
             call_internal_provider(
               router_id,
               group_id,
               "internal.task.create",
               %{},
               "invalid-production-task-create"
             )
  end

  test "im_api.internal.task.create task conversation uses normal participant dispatch and source context",
       %{
         group_id: group_id,
         agent_id: delegator_id,
         template_id: template_id
       } do
    target =
      req(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Task worker",
          role: "worker"
        }
      ).body

    target_id = target["agent_id"]
    parent = create_conversation_with_agent(group_id, delegator_id, %{title: "Parent chat"})
    parent_conversation_id = parent["conversation_id"]
    task_request_id = "task-e2e-#{System.unique_integer([:positive])}"

    assert {:ok, result} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               delegator_id,
               target_id,
               %{
                 content: "compute 6*7",
                 title: "Math task",
                 client_request_id: task_request_id,
                 origin_session_id: router_session_id(delegator_id, group_id),
                 source_refs: %{"parent_conversation_id" => parent_conversation_id}
               }
             )

    conversation_id = result["conversation_id"]
    assert SalixStore.Ids.valid_conversation_id?(conversation_id)
    assert result["delivery_status"] == "queued"
    assert result["worker_agent_id"] == target_id

    conversation =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}").body

    assert conversation["kind"] == "agent_task"
    assert conversation["created_by_agent_id"] == delegator_id
    assert conversation["source_refs"]["parent_conversation_id"] == parent_conversation_id

    participants = conversation_participants(group_id, conversation_id)

    # Router agents always use the canonical group router session. The original
    # task source stays in conversation context, not participant session
    # identity.
    assert Enum.any?(
             participants,
             &(&1["agent_id"] == delegator_id and &1["role_label"] == "delegator" and
                 get_in(&1, ["payload", "session_id"]) ==
                   router_session_id(delegator_id, group_id) and
                 not Map.has_key?(&1, "session_id"))
           )

    assert Enum.any?(
             participants,
             &(&1["agent_id"] == target_id and &1["role_label"] == "worker" and
                 SalixStore.Ids.valid_session_id?(get_in(&1, ["payload", "session_id"])) and
                 not Map.has_key?(&1, "session_id"))
           )

    worker_participant = Enum.find(participants, &(&1["agent_id"] == target_id))
    delegator_participant = Enum.find(participants, &(&1["agent_id"] == delegator_id))
    worker_participant_id = worker_participant["participant_id"]
    delegator_participant_id = delegator_participant["participant_id"]
    worker_session_id = get_in(worker_participant, ["payload", "session_id"])
    refute worker_session_id == router_session_id(delegator_id, group_id)

    assert {:ok, _retry_result} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               delegator_id,
               target_id,
               %{
                 content: "compute 6*7",
                 title: "Math task",
                 client_request_id: task_request_id,
                 origin_session_id: router_session_id(delegator_id, group_id),
                 source_refs: %{"parent_conversation_id" => parent_conversation_id}
               }
             )

    retry_worker =
      group_id
      |> conversation_participants(conversation_id)
      |> Enum.find(&(&1["agent_id"] == target_id))

    assert get_in(retry_worker, ["payload", "session_id"]) == worker_session_id

    messages =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert [
             %{
               "actor_type" => "agent",
               "agent_id" => ^delegator_id,
               "participant_id" => ^delegator_participant_id,
               "content" => [%{"type" => "text", "text" => "compute 6*7"}]
             }
           ] = messages

    session =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(target_id, worker_session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "user" and &1.content == "compute 6*7")
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "summary" and
                 &1.content =~ "conversation_kind: agent_task" and
                 &1.content =~ "participant_id: #{worker_participant_id}" and
                 &1.content =~ "participant_role_label: worker" and
                 not (&1.content =~ "parent_conversation_id") and
                 &1.content =~ "from_participant_id: #{delegator_participant_id}" and
                 &1.content =~ "from_role_label: delegator" and
                 &1.content =~ "conversation_id: #{conversation_id}")
           )

    assert Enum.any?(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "user" and &1.content == "compute 6*7")
           )

    assert {:ok, worker_result} =
             SalixIM.ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               target_id,
               %{
                 "client_request_id" => "worker-report-1",
                 "content" => [%{"type" => "text", "text" => "result is 42"}]
               }
             )

    assert worker_result["delivery_status"] == "queued"

    delegator_session_id = router_session_id(delegator_id, group_id)

    delegator_session =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(delegator_id, delegator_session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "user" and &1.content == "result is 42")
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    report_context =
      Enum.find(
        SalixAgent.InternalSession.get(delegator_session, :messages),
        &(&1.role == "summary" and
            &1.content =~ "from_participant_id: #{worker_participant_id}")
      )

    assert report_context.content =~ "conversation_kind: agent_task"
    assert report_context.content =~ "participant_id: #{delegator_participant_id}"
    assert report_context.content =~ "participant_role_label: delegator"
    refute report_context.content =~ "parent_conversation_id"
    assert report_context.content =~ "from_role_label: worker"
    refute report_context.content =~ parent_conversation_id
    refute report_context.content =~ "im_api.internal.send_message"

    assert SalixAgent.InternalSession.session_id(delegator_session) != worker_session_id
  end

  test "Slack endpoint ignores own bot mentions and accepts app-attributed users",
       %{group_id: group_id, tenant_id: tenant_id, agent_id: router_id} do
    secret = "slack-loop-secret"
    app_id = "A-loop-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    connect = %{
      "connect_id" => "slack-loop-#{System.unique_integer([:positive])}",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "app_name" => "loop-test",
      "app_id" => app_id,
      "signing_secret" => secret,
      "inbound_agent_id" => router_id,
      "bot_token" => "xoxb-loop-test",
      "bot_id" => "B-own",
      "bot_user_id" => "Ubot",
      "workspace_id" => "T-worker",
      "oauth_completed_at" => now,
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, ^connect} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(group_id, connect["connect_id"]),
               connect
             )

    start_supervised!(RecordingSlackAPI)
    port = start_bandit_retry!(fn port -> {Bandit, plug: RecordingSlackAPI, port: port} end)
    previous_slack_api_base = Application.get_env(:salix_im, :slack_api_base_url)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      put_or_delete_env(:salix_im, :slack_api_base_url, previous_slack_api_base)
    end)

    ignored_response =
      post_slack_event!(
        secret,
        slack_envelope(app_id, "Ev-own-bot-profile", %{
          "type" => "app_mention",
          "subtype" => "bot_message",
          "bot_id" => "B-own",
          "text" => "echo <@Ubot>",
          "channel" => "C-loop",
          "channel_type" => "channel",
          "ts" => "700.000"
        })
      )

    assert ignored_response.status == 200
    assert ignored_response.body == %{"ignored" => true}

    Process.sleep(50)
    assert SalixIM.RouterConversationProjection.list_group_router_messages(group_id) == {:ok, []}

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 10)

    refute Enum.any?(conversations, &(&1["kind"] == "agent_task"))
    assert RecordingSlackAPI.requests() == []

    Mock.script([{:final, "accepted human reply"}])

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, "Ev-human-same-app", %{
        "type" => "app_mention",
        "user" => "U-human",
        "bot_id" => "B-own",
        "app_id" => app_id,
        "bot_profile" => %{"app_id" => app_id},
        "text" => "<@Ubot> human request",
        "channel" => "C-loop",
        "channel_type" => "channel",
        "ts" => "700.002"
      })
    )

    source_id = "im_provider:slack:#{connect["connect_id"]}:C-loop:700.002"

    assert_direct_router_session_message(router_id, group_id, source_id, "human request")

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, "Ev-human-same-app-duplicate", %{
        "type" => "message",
        "user" => "U-human",
        "bot_id" => "B-own",
        "app_id" => app_id,
        "bot_profile" => %{"app_id" => app_id},
        "text" => "<@Ubot> human request",
        "channel" => "C-loop",
        "channel_type" => "channel",
        "ts" => "700.002"
      })
    )

    Process.sleep(50)

    {:ok, session} =
      SalixAgent.InternalSessionStore.read(router_id, router_session_id(router_id, group_id))

    assert Enum.count(
             SalixAgent.InternalSession.get(session, :messages),
             &(&1.role == "user" and
                 to_string(Map.get(&1, :source_message_id) || "") == source_id)
           ) == 1
  end

  test "Slack endpoint ignores foreign Task-card metadata without entering settlement",
       %{group_id: group_id, tenant_id: tenant_id, agent_id: router_id} do
    secret = "slack-foreign-task-card-secret"
    app_id = "A-foreign-task-card-#{System.unique_integer([:positive])}"
    connect_id = "slack-foreign-task-card-#{System.unique_integer([:positive])}"
    foreign_conversation_id = Ids.new_conversation_id()
    now = System.system_time(:millisecond)

    connect = %{
      "connect_id" => connect_id,
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "app_name" => "foreign-task-card-test",
      "app_id" => app_id,
      "signing_secret" => secret,
      "inbound_agent_id" => router_id,
      "bot_token" => "xoxb-foreign-task-card-test",
      "bot_user_id" => "Ubot",
      "workspace_id" => "T-worker",
      "oauth_completed_at" => now,
      "triage_provisioned_at" => now,
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, ^connect} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(group_id, connect_id),
               connect
             )

    previous_diagnostic_sink = Application.get_env(:salix_im, :diagnostic_sink)
    parent = self()

    Application.put_env(:salix_im, :diagnostic_sink, fn diagnostic ->
      send(parent, {:foreign_task_card_diagnostic, diagnostic})
    end)

    on_exit(fn ->
      put_or_delete_env(:salix_im, :diagnostic_sink, previous_diagnostic_sink)
    end)

    response =
      post_slack_event!(
        secret,
        slack_envelope(app_id, "Ev-foreign-task-card", %{
          "type" => "message_metadata_posted",
          "app_id" => app_id,
          "channel_id" => "C-foreign-task-card",
          "message_ts" => "701.001",
          "metadata" => %{
            "event_type" => SalixIM.SlackTaskCard.metadata_event_type(),
            "event_payload" => %{
              "group_id" => group_id,
              "conversation_id" => foreign_conversation_id,
              "participant_id" => "ptp_foreign",
              "delivery_id" => "delivery_foreign",
              "operation_ref" => "operation_foreign",
              "connect_id" => "another-connect",
              "block_id" => "block_foreign",
              "render_version" => 3
            }
          }
        })
      )

    assert response.status == 200

    assert response.body == %{
             "ignored" => true,
             "ignored_reason" => "invalid_task_card_metadata_route"
           }

    assert_receive {:foreign_task_card_diagnostic, diagnostic}
    assert diagnostic.status == "ignored"
    assert diagnostic.severity == "warning"
    assert diagnostic.reason_class == "invalid_task_card_metadata_route"
    assert diagnostic.event_type == "slack.callback.ignored"

    assert SalixIM.Conversations.get_group_conversation_record(
             group_id,
             foreign_conversation_id
           ) == {:error, :not_found}
  end

  @tag :keep_worker_working
  test "legacy Slack connects keep their thread owner when rebound",
       %{
         group_id: group_id,
         template_id: template_id,
         tenant_id: tenant_id,
         agent_id: router_id
       } do
    worker =
      req(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Slack worker",
          role: "worker"
        }
      ).body

    worker_id = worker["agent_id"]
    secret = "slack-worker-secret"
    app_id = "A-worker-e2e-#{System.unique_integer([:positive])}"
    now = System.system_time(:millisecond)

    connect = %{
      "connect_id" => "slack-worker-e2e-#{System.unique_integer([:positive])}",
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "app_name" => "codex-bft-test",
      "app_id" => app_id,
      "client_id" => "client-#{app_id}",
      "client_secret" => "client-secret",
      "signing_secret" => secret,
      "inbound_agent_id" => worker_id,
      "bot_token" => "xoxb-worker-e2e",
      "bot_user_id" => "Ubot",
      "workspace_id" => "T-worker",
      "workspace_name" => "Worker E2E",
      "oauth_completed_at" => now,
      "created_at" => now,
      "updated_at" => now
    }

    assert {:ok, ^connect} =
             SalixStore.CasRecord.create(
               Keys.ctl_im_connect(group_id, connect["connect_id"]),
               connect
             )

    first_event_id = "Ev-worker-session-e2e"

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, first_event_id, %{
        "type" => "app_mention",
        "user" => "U-worker-user",
        "text" => "<@Ubot> investigate the staging failure",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "ts" => "400.000"
      })
    )

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 10)

    conversation = Enum.find(conversations, &(&1["kind"] == "agent_task"))
    assert conversation
    conversation_id = conversation["conversation_id"]
    assert conversation["kind"] == "agent_task"

    worker_participant =
      group_id
      |> conversation_participants(conversation_id)
      |> Enum.find(&(&1["agent_id"] == worker_id and &1["role_label"] == "worker"))

    assert worker_participant["agent_id"] == worker_id
    worker_session_id = get_in(worker_participant, ["payload", "session_id"])
    assert SalixStore.Ids.valid_session_id?(worker_session_id)

    [source_message] =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert source_message["source_message_id"] ==
             "im_provider:slack:#{connect["connect_id"]}:#{first_event_id}"

    assert SalixStore.Ids.valid_message_id?(source_message["message_id"])

    worker_session =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(worker_id, worker_session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "user" and
                     &1.content =~ "investigate the staging failure")
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    assert SalixAgent.InternalSession.session_id(worker_session) == worker_session_id

    assert Enum.any?(
             SalixAgent.InternalSession.get(worker_session, :messages),
             &(&1.role == "summary" and
                 &1.content =~ "provider: internal" and
                 &1.content =~ "conversation_id: #{conversation_id}" and
                 &1.content =~ "participant_role_label: worker" and
                 &1.content =~ "from_actor_type: provider_user")
           )

    assert worker_session_id != router_session_id(router_id, group_id)

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, "Ev-worker-followup-e2e", %{
        "type" => "message",
        "user" => "U-worker-user",
        "text" => "follow up in the same thread",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "thread_ts" => "400.000",
        "ts" => "400.001"
      })
    )

    same_thread_messages =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.map(same_thread_messages, &content_text(&1["content"])) == [
             "investigate the staging failure",
             "follow up in the same thread"
           ]

    second_thread_event_id = "Ev-worker-second-thread-e2e"

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, second_thread_event_id, %{
        "type" => "app_mention",
        "user" => "U-worker-user",
        "text" => "<@Ubot> investigate a separate failure",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "ts" => "500.000"
      })
    )

    assert {:ok, %{"data" => after_second_thread}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 10)

    [second_task] =
      Enum.filter(
        after_second_thread,
        &(&1["kind"] == "agent_task" and &1["conversation_id"] != conversation_id)
      )

    second_worker_participant =
      group_id
      |> conversation_participants(second_task["conversation_id"])
      |> Enum.find(&(&1["agent_id"] == worker_id and &1["role_label"] == "worker"))

    assert SalixStore.Ids.valid_session_id?(
             get_in(second_worker_participant, ["payload", "session_id"])
           )

    refute get_in(second_worker_participant, ["payload", "session_id"]) == worker_session_id

    assert {:ok, _updated_connect} =
             ProviderConnects.update_slack_im_connect(
               tenant_id,
               group_id,
               connect["connect_id"],
               %{"inbound_agent_id" => router_id}
             )

    assert {:ok, %{"inbound_agent_id" => ^router_id}} =
             ProviderConnects.get_active_connect_by_id(group_id, connect["connect_id"], "slack")

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, "Ev-worker-after-rebind-e2e", %{
        "type" => "message",
        "user" => "U-worker-user",
        "text" => "the original thread still belongs to the worker task",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "thread_ts" => "400.000",
        "ts" => "400.002"
      })
    )

    rebound_thread_messages =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.map(rebound_thread_messages, &content_text(&1["content"])) == [
             "investigate the staging failure",
             "follow up in the same thread",
             "the original thread still belongs to the worker task"
           ]

    deliver_slack_event!(
      secret,
      slack_envelope(app_id, "Ev-router-after-rebind-e2e", %{
        "type" => "app_mention",
        "user" => "U-worker-user",
        "text" => "<@Ubot> this new thread belongs to the router",
        "channel" => "C-worker",
        "channel_type" => "channel",
        "ts" => "600.000"
      })
    )

    assert_direct_router_session_message(
      router_id,
      group_id,
      "im_provider:slack:#{connect["connect_id"]}:Ev-router-after-rebind-e2e",
      "this new thread belongs to the router"
    )

    assert {:ok, %{"data" => final_conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 10)

    assert Enum.count(final_conversations, &(&1["kind"] == "agent_task")) == 2
  end

  @tag :keep_worker_working
  test "router im_api.internal.task.create creates two task conversations for the same worker without sharing sessions",
       %{
         group_id: group_id,
         agent_id: router_id,
         template_id: template_id
       } do
    target =
      req(:post, "/v1/runtime/agents",
        json: %{
          group_id: group_id,
          template_id: template_id,
          name: "Codex worker",
          role: "worker"
        }
      ).body

    target_id = target["agent_id"]
    task_a_content = "task A marker #{System.unique_integer([:positive])}"
    task_b_content = "task B marker #{System.unique_integer([:positive])}"

    TwoTaskDelegationLLM.configure(%{
      target_agent_id: target_id,
      task_a_content: task_a_content,
      task_b_content: task_b_content
    })

    Application.put_env(:salix_agent, :llm, TwoTaskDelegationLLM)

    send_result =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/router/messages",
        json: %{
          content: [%{type: "text", text: "create two tasks for the codex worker"}],
          client_request_id: "router-two-tasks"
        }
      )

    assert send_result.status == 201
    assert send_result.body["delivery_status"] == "queued"

    router_session_id = router_session_id(router_id, group_id)

    router_session =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(router_id, router_session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "assistant" and &1.content == "delegated")
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    assert {:ok, %{"status" => "completed"} = delegate_a} =
             SalixAgent.InternalSession.lookup_async_call(router_session, "delegate-a")

    assert get_in(delegate_a, ["result", "content"]) =~
             "\"conversation_kind\":\"agent_task\""

    assert get_in(delegate_a, ["result", "content"]) =~ "\"title\":\"Task A\""

    assert {:ok, %{"status" => "completed"} = delegate_b} =
             SalixAgent.InternalSession.lookup_async_call(router_session, "delegate-b")

    assert get_in(delegate_b, ["result", "content"]) =~
             "\"conversation_kind\":\"agent_task\""

    assert get_in(delegate_b, ["result", "content"]) =~ "\"title\":\"Task B\""

    {:ok, listed} = SalixIM.Conversations.list_group_conversations(group_id, limit: 100)

    task_conversations =
      listed["data"]
      |> Enum.filter(&(&1["kind"] == "agent_task"))
      |> Enum.sort_by(& &1["title"])

    assert length(task_conversations) == 2

    task_a = Enum.find(task_conversations, &(&1["title"] == "Task A"))
    task_b = Enum.find(task_conversations, &(&1["title"] == "Task B"))

    assert task_a["created_by_agent_id"] == router_id
    assert task_b["created_by_agent_id"] == router_id
    refute task_a["conversation_id"] == task_b["conversation_id"]

    worker_deliveries =
      Map.new([task_a, task_b], fn conversation ->
        participants = conversation_participants(group_id, conversation["conversation_id"])

        assert Enum.any?(
                 participants,
                 &(&1["agent_id"] == router_id and &1["role_label"] == "delegator" and
                     get_in(&1, ["payload", "session_id"]) ==
                       router_session_id(router_id, group_id) and
                     not Map.has_key?(&1, "session_id"))
               )

        worker_participant =
          Enum.find(
            participants,
            &(&1["agent_id"] == target_id and &1["role_label"] == "worker")
          )

        worker_session_id = get_in(worker_participant, ["payload", "session_id"])
        assert SalixStore.Ids.valid_session_id?(worker_session_id)
        refute Map.has_key?(worker_participant, "session_id")

        {conversation["conversation_id"],
         %{
           participant_id: worker_participant["participant_id"],
           session_id: worker_session_id
         }}
      end)

    task_a_id = task_a["conversation_id"]
    task_b_id = task_b["conversation_id"]
    task_a_delivery = Map.fetch!(worker_deliveries, task_a_id)
    task_b_delivery = Map.fetch!(worker_deliveries, task_b_id)
    task_a_session_id = task_a_delivery.session_id
    task_b_session_id = task_b_delivery.session_id
    refute task_a_session_id == task_b_session_id

    task_a_messages =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/#{task_a_id}/messages").body

    task_b_messages =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/conversations/#{task_b_id}/messages").body

    assert [
             %{
               "actor_type" => "agent",
               "agent_id" => ^router_id,
               "content" => task_a_content_body,
               "message_id" => _task_a_message_id
             }
           ] =
             task_a_messages

    assert content_text(task_a_content_body) == task_a_content

    assert [
             %{
               "actor_type" => "agent",
               "agent_id" => ^router_id,
               "content" => task_b_content_body,
               "message_id" => _task_b_message_id
             }
           ] =
             task_b_messages

    assert content_text(task_b_content_body) == task_b_content

    session_a =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(target_id, task_a_session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "user" and &1.content == task_a_content)
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    session_b =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(target_id, task_b_session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "user" and &1.content == task_b_content)
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    assert SalixAgent.InternalSession.session_id(session_a) == task_a_session_id
    assert SalixAgent.InternalSession.session_id(session_b) == task_b_session_id

    refute SalixAgent.InternalSession.session_id(session_a) ==
             SalixAgent.InternalSession.session_id(session_b)

    assert SalixAgent.InternalSession.session_id(router_session) not in [
             task_a_session_id,
             task_b_session_id
           ]
  end

  test "agent conversation routes are not exposed; group routes own conversations", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    assert req(:get, "/v1/runtime/agents/#{agent_id}/conversations").status == 404

    created =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations",
        json: %{
          client_request_id: "group-route-create",
          title: "Via group route",
          participants: [
            %{
              actor_type: "user",
              user_id: "current",
              state: "active",
              notification_filter: %{messages: "all", statuses: "none"}
            },
            %{
              actor_type: "agent",
              agent_id: agent_id,
              state: "active",
              notification_filter: %{messages: "all", statuses: "none"}
            }
          ]
        }
      )

    assert created.status == 201
    conversation_id = created.body["conversation_id"]

    assert req(
             :get,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}"
           ).body["title"] == "Via group route"

    sent =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
        json: %{
          content: [%{type: "text", text: "hello group conversation"}],
          client_request_id: "group-cm-1"
        }
      )

    assert sent.status == 201
    assert sent.body["conversation_id"] == conversation_id
    assert sent.body["delivery_status"] == "queued"

    session_id = router_session_id(agent_id, group_id)

    session =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
          {:ok, session} ->
            if Enum.any?(
                 SalixAgent.InternalSession.get(session, :messages),
                 &(&1.role == "user" and &1.content == "hello group conversation")
               ) do
              session
            end

          _ ->
            nil
        end
      end)

    guidance =
      Enum.find(
        SalixAgent.InternalSession.get(session, :messages),
        &(&1.role == "summary" and &1.content =~ "conversation_kind: user_chat")
      )

    assert guidance.content =~ "from_actor_type: user"
    refute guidance.content =~ "im_api.internal.send_message"
    refute guidance.content =~ "end_turn"
  end

  defmodule SlowLLM do
    @moduledoc "Blocks a round long enough to detect runtime-coupled read paths."
    @behaviour SalixAgent.LLM
    def complete(_messages, _tools) do
      Process.sleep(4_000)
      SalixWeb.ConversationMessagingTest.terminal_llm_response("slow reply")
    end
  end

  defmodule StreamingInternalSendLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    @owner_key {__MODULE__, :owner}
    @tool_call_id "streaming-internal-send"
    @draft_prefix "正在"
    @final_text "正在给你发送"

    def configure(owner, outcome \\ :success),
      do: :persistent_term.put(@owner_key, %{owner: owner, outcome: outcome})

    def clear, do: :persistent_term.erase(@owner_key)

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete(messages, tools, opts),
      do: complete_stream(messages, tools, fn _ -> :ok end, opts)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, _tools, _on_delta, opts) do
      if tool_completed?(messages) do
        SalixWeb.ConversationMessagingTest.terminal_llm_response("done")
      else
        %{owner: owner, outcome: outcome} = :persistent_term.get(@owner_key)
        conversation_id = source_field(messages, "conversation_id")

        rejected_param =
          if outcome == :rejected,
            do: ~s(,"delivery_filter":{"participant_ids":["ptp1_0000000000000000000"]}),
            else: ""

        encoded_args =
          ~s({"tool":"im_api.internal.send_message","params":{"connect_id":"internal","conversation_id":#{Jason.encode!(conversation_id)},"content":[{"type":"text","text":"#{@final_text}"}]#{rejected_param}}})

        {prefix, suffix} = split_after(encoded_args, @draft_prefix)
        on_tool_delta = option(opts, :on_tool_delta)

        send(owner, {:streaming_internal_send_started, self()})

        receive do
          :emit_send_message_prefix ->
            emit_fragments(on_tool_delta, prefix, true)
            send(owner, :send_message_prefix_emitted)
        after
          10_000 -> raise "timed out waiting to emit send_message prefix"
        end

        receive do
          :emit_send_message_suffix ->
            emit_fragments(on_tool_delta, suffix, false)
            send(owner, :send_message_suffix_emitted)
        after
          10_000 -> raise "timed out waiting to emit send_message suffix"
        end

        receive do
          :finish_send_message_stream ->
            {:assistant, "",
             [
               %{
                 id: @tool_call_id,
                 name: "call",
                 args: Jason.decode!(encoded_args)
               }
             ]}
        after
          10_000 -> raise "timed out waiting to finish send_message stream"
        end
      end
    end

    defp emit_fragments(on_tool_delta, encoded, first?) when is_function(on_tool_delta, 1) do
      encoded
      |> String.graphemes()
      |> Enum.chunk_every(7)
      |> Enum.map(&Enum.join/1)
      |> Enum.with_index()
      |> Enum.each(fn {fragment, index} ->
        on_tool_delta.(%{
          index: 0,
          name: if(first? and index == 0, do: "call"),
          fragment: fragment
        })
      end)
    end

    defp emit_fragments(_on_tool_delta, _encoded, _first?), do: :ok

    defp split_after(encoded, marker) do
      {start, size} = :binary.match(encoded, marker)
      split_at = start + size
      :erlang.split_binary(encoded, split_at)
    end

    defp tool_completed?(messages) do
      Enum.any?(messages, fn message ->
        (Map.get(message, :role) || Map.get(message, "role")) == "tool" and
          (Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")) == @tool_call_id
      end)
    end

    # The source-context summary is not necessarily the last summary: the
    # runtime appends per-request reminders (reply guidance, turn outcome)
    # behind it. Read the field from whichever summary carries it.
    defp source_field(messages, field) do
      pattern = ~r/(?:^|\n)- #{Regex.escape(field)}: ([^\n]+)/

      messages
      |> Enum.filter(&((Map.get(&1, :role) || Map.get(&1, "role")) == "summary"))
      |> Enum.reverse()
      |> Enum.find_value("", fn message ->
        content = to_string(Map.get(message, :content) || Map.get(message, "content") || "")

        case Regex.run(pattern, content) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
      end)
    end

    defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
    defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  end

  defmodule VisibleReplyNestedSendLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    @owner_key {__MODULE__, :owner}
    @outer_tool_call_id "nested-source-send-js"
    @explicit_text "explicit nested reply"
    @runtime_final "runtime-only after nested send"

    def configure(owner), do: :persistent_term.put(@owner_key, owner)
    def clear, do: :persistent_term.erase(@owner_key)

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete(messages, tools, opts),
      do: complete_stream(messages, tools, fn _ -> :ok end, opts)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(messages, _tools, on_delta, _opts) do
      if nested_send_completed?(messages) do
        on_delta.(@runtime_final)
        send(:persistent_term.get(@owner_key), :nested_source_send_final_returned)
        SalixWeb.ConversationMessagingTest.terminal_llm_response(@runtime_final)
      else
        conversation_id = source_field(messages, "conversation_id")

        params = %{
          "connect_id" => "internal",
          "conversation_id" => conversation_id,
          "content" => [%{"type" => "text", "text" => @explicit_text}]
        }

        source =
          SalixAgent.SpinfoamFixture.script_call_program(
            Jason.encode!(%{"tool" => "im_api.internal.send_message", "args" => params})
          )

        {:assistant, "",
         [
           %{
             id: @outer_tool_call_id,
             name: "call",
             args: %{"tool" => "script.run", "params" => %{"source" => source}}
           }
         ]}
      end
    end

    defp nested_send_completed?(messages) do
      Enum.any?(messages, fn message ->
        (Map.get(message, :role) || Map.get(message, "role")) == "tool" and
          (Map.get(message, :tool_call_id) || Map.get(message, "tool_call_id")) ==
            @outer_tool_call_id
      end)
    end

    # The source-context summary is not necessarily the last summary: the
    # runtime appends per-request reminders (reply guidance, turn outcome)
    # behind it. Read the field from whichever summary carries it.
    defp source_field(messages, field) do
      pattern = ~r/(?:^|\n)- #{Regex.escape(field)}: ([^\n]+)/

      messages
      |> Enum.filter(&((Map.get(&1, :role) || Map.get(&1, "role")) == "summary"))
      |> Enum.reverse()
      |> Enum.find_value("", fn message ->
        content = to_string(Map.get(message, :content) || Map.get(message, "content") || "")

        case Regex.run(pattern, content) do
          [_, value] -> String.trim(value)
          _ -> nil
        end
      end)
    end
  end

  defmodule RepairNestedFailureLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM

    @state_key {__MODULE__, :state}
    @outer_tool_call_id "nested-source-send-js-failure"
    @repair_tool_call_id "nested-source-send-repair-action"
    @explicit_text "explicit nested reply before JavaScript failure"
    @repair_text "agent-chosen follow-up after JavaScript failure"
    @runtime_final "runtime-only after nested send failure"

    def configure(owner, conversation_id) do
      :persistent_term.put(@state_key, %{
        owner: owner,
        conversation_id: conversation_id,
        calls: :atomics.new(1, [])
      })
    end

    def clear, do: :persistent_term.erase(@state_key)

    @impl true
    def complete(messages, tools), do: complete_stream(messages, tools, fn _ -> :ok end, [])

    @impl true
    def complete(messages, tools, opts),
      do: complete_stream(messages, tools, fn _ -> :ok end, opts)

    @impl true
    def complete_stream(messages, tools, on_delta),
      do: complete_stream(messages, tools, on_delta, [])

    @impl true
    def complete_stream(_messages, _tools, on_delta, _opts) do
      %{owner: owner, conversation_id: conversation_id, calls: calls} =
        :persistent_term.get(@state_key)

      initial_params = %{
        "connect_id" => "internal",
        "conversation_id" => conversation_id,
        "content" => [%{"type" => "text", "text" => @explicit_text}]
      }

      case :atomics.add_get(calls, 1, 1) do
        1 ->
          # Send, then fail: the program returns non-zero after the nested send.
          source =
            SalixAgent.SpinfoamFixture.script_call_program(
              Jason.encode!(%{
                "tool" => "im_api.internal.send_message",
                "args" => initial_params
              }),
              exit_code: 1
            )

          {:assistant, "",
           [
             %{
               id: @outer_tool_call_id,
               name: "call",
               args: %{"tool" => "script.run", "params" => %{"source" => source}}
             }
           ]}

        2 ->
          repair_params =
            put_in(initial_params, ["content"], [
              %{"type" => "text", "text" => @repair_text}
            ])

          {:assistant, "",
           [
             %{
               id: @repair_tool_call_id,
               name: "call",
               args: %{"tool" => "im_api.internal.send_message", "params" => repair_params}
             }
           ]}

        _ ->
          on_delta.(@runtime_final)
          send(owner, :nested_source_send_failure_final_returned)
          SalixWeb.ConversationMessagingTest.terminal_llm_response(@runtime_final)
      end
    end
  end

  test "message reads are served from durable conversation state", %{
    group_id: group_id
  } do
    Application.put_env(:salix_agent, :llm, SlowLLM)
    on_exit(fn -> Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock) end)

    conversation =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/router/conversation").body

    conversation_id = conversation["conversation_id"]
    path = "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"

    sent =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/router/messages",
        json: %{
          content: [%{type: "text", text: "take your time"}],
          client_request_id: "slow-1"
        }
      ).body

    assert sent["delivery_status"] == "queued"
    assert SalixStore.Ids.valid_message_id?(sent["message_id"])

    {micros, response} = :timer.tc(fn -> req(:get, path <> "?limit=500") end)

    assert response.status == 200
    assert Enum.any?(response.body, &(&1["message_id"] == sent["message_id"]))
    # Conversation reads are backed by durable conversation state. They must not
    # depend on whether the agent runtime has processed participant delivery.
    assert micros < 3_000_000
  end

  test "conversation events stream carries a canonical user message append", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    Application.put_env(:salix_agent, :llm, SlowLLM)
    on_exit(fn -> Application.put_env(:salix_agent, :llm, SalixAgent.LLM.Mock) end)

    conversation = create_conversation_with_agent(group_id, agent_id, title: "Live user")
    conversation_id = conversation["conversation_id"]

    client = open_stream("/v1/runtime/agent-groups/#{group_id}/conversations/events")
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, headers}, 3_000
    assert headers =~ "HTTP/1.1 200"

    sent =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
        json: %{
          content: [%{type: "text", text: "show immediately"}],
          client_request_id: "sse-user-1"
        }
      ).body

    assert sent["delivery_status"] == "queued"
    message_id = sent["message_id"]
    assert Ids.valid_message_id?(message_id)

    assert_receive {:sse_frame,
                    %{
                      "event" => "message_created",
                      "data" => %{
                        "conversation_id" => ^conversation_id,
                        "message_id" => ^message_id,
                        "actor_type" => "user"
                      }
                    }},
                   7_000
  end

  test "an explicit internal send streams through the exact participant before Message append", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, StreamingInternalSendLLM)
    StreamingInternalSendLLM.configure(self())

    on_exit(fn ->
      StreamingInternalSendLLM.clear()
      Application.put_env(:salix_agent, :llm, previous_llm)
    end)

    conversation =
      create_conversation_with_agent(group_id, agent_id, title: "Streaming internal send")

    conversation_id = conversation["conversation_id"]
    participants = conversation_participants(group_id, conversation_id)
    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))
    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    participant_id = agent_participant["participant_id"]

    sent =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
        json: %{
          participant_id: user_participant["participant_id"],
          actor_type: "user",
          user_id: "current",
          content: [%{type: "text", text: "流式回复给我"}],
          client_request_id: "streaming-internal-send-1"
        }
      )

    assert sent.status == 201
    assert_receive {:streaming_internal_send_started, llm_pid}, 5_000

    assert {:ok, %{"owner_pid" => _owner, "status" => initial_status}} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id,
               self()
             )

    assert initial_status["conversation_id"] == conversation_id
    assert initial_status["participant_id"] == participant_id

    send(llm_pid, :emit_send_message_prefix)
    assert_receive :send_message_prefix_emitted, 2_000

    prefix_status =
      eventually(fn ->
        case ConversationServer.get_group_conversation_participant_status(
               group_id,
               conversation_id,
               participant_id
             ) do
          {:ok, %{"draft" => %{"text" => "正在"}} = status} -> status
          _ -> nil
        end
      end)

    assert prefix_status["draft"]["status"] == "streaming"

    messages_before_send =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.map(messages_before_send, &content_text(&1["content"])) == ["流式回复给我"]

    send(llm_pid, :emit_send_message_suffix)
    assert_receive :send_message_suffix_emitted, 2_000

    assert eventually(fn ->
             case ConversationServer.get_group_conversation_participant_status(
                    group_id,
                    conversation_id,
                    participant_id
                  ) do
               {:ok, %{"draft" => %{"text" => "正在给你发送"}}} -> true
               _ -> false
             end
           end)

    send(llm_pid, :finish_send_message_stream)

    messages_after_send =
      eventually(fn ->
        messages =
          req(
            :get,
            "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
          ).body

        if Enum.map(messages, &content_text(&1["content"])) == [
             "流式回复给我",
             "正在给你发送"
           ],
           do: messages
      end)

    assert Enum.map(messages_after_send, & &1["actor_type"]) == ["user", "agent"]

    assert eventually(fn ->
             case ConversationServer.get_group_conversation_participant_status(
                    group_id,
                    conversation_id,
                    participant_id
                  ) do
               {:ok, status} -> is_nil(status["draft"])
               _ -> false
             end
           end)
  end

  test "a rejected streamed internal send clears participant draft without appending a Message",
       %{
         group_id: group_id,
         agent_id: agent_id
       } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, StreamingInternalSendLLM)
    StreamingInternalSendLLM.configure(self(), :rejected)

    on_exit(fn ->
      StreamingInternalSendLLM.clear()
      Application.put_env(:salix_agent, :llm, previous_llm)
    end)

    conversation =
      create_conversation_with_agent(group_id, agent_id, title: "Rejected streaming send")

    conversation_id = conversation["conversation_id"]
    participants = conversation_participants(group_id, conversation_id)
    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))
    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    participant_id = agent_participant["participant_id"]
    session_id = get_in(agent_participant, ["payload", "session_id"])

    assert %{status: 201} =
             req(
               :post,
               "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
               json: %{
                 participant_id: user_participant["participant_id"],
                 actor_type: "user",
                 user_id: "current",
                 content: [%{type: "text", text: "这条不要发出去"}],
                 client_request_id: "rejected-streaming-internal-send-1"
               }
             )

    assert_receive {:streaming_internal_send_started, llm_pid}, 5_000

    assert {:ok, %{"status" => _initial_status}} =
             ConversationServer.subscribe_group_conversation_participant(
               group_id,
               conversation_id,
               participant_id,
               self()
             )

    send(llm_pid, :emit_send_message_prefix)
    assert_receive :send_message_prefix_emitted, 2_000
    send(llm_pid, :emit_send_message_suffix)
    assert_receive :send_message_suffix_emitted, 2_000

    assert eventually(fn ->
             case ConversationServer.get_group_conversation_participant_status(
                    group_id,
                    conversation_id,
                    participant_id
                  ) do
               {:ok, %{"draft" => %{"text" => "正在给你发送"}}} -> true
               _ -> false
             end
           end)

    send(llm_pid, :finish_send_message_stream)

    failed_call =
      eventually(fn ->
        with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id),
             {:ok, %{"status" => "failed"} = call} <-
               SalixAgent.InternalSession.lookup_async_call(
                 session,
                 "streaming-internal-send"
               ) do
          call
        else
          _ -> nil
        end
      end)

    assert failed_call["tool_name"] == "im_api.internal.send_message"

    assert eventually(fn ->
             case ConversationServer.get_group_conversation_participant_status(
                    group_id,
                    conversation_id,
                    participant_id
                  ) do
               {:ok, status} -> is_nil(status["draft"])
               _ -> false
             end
           end)

    messages =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.map(messages, &content_text(&1["content"])) == ["这条不要发出去"]
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "a successful internal send nested in a script owns the source reply", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, VisibleReplyNestedSendLLM)
    VisibleReplyNestedSendLLM.configure(self())

    on_exit(fn ->
      VisibleReplyNestedSendLLM.clear()
      Application.put_env(:salix_agent, :llm, previous_llm)
    end)

    conversation = create_conversation_with_agent(group_id, agent_id, title: "Nested source send")
    conversation_id = conversation["conversation_id"]

    participants = conversation_participants(group_id, conversation_id)
    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))
    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    session_id = get_in(agent_participant, ["payload", "session_id"])

    sent =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
        json: %{
          participant_id: user_participant["participant_id"],
          actor_type: "user",
          user_id: "current",
          content: [%{type: "text", text: "send from a nested script"}],
          client_request_id: "visible-reply-nested-send-1"
        }
      )

    assert sent.status == 201

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               sent.body["message_id"],
               agent_participant["participant_id"]
             )

    assert_receive :nested_source_send_final_returned, 5_000

    session =
      eventually(fn ->
        with {:ok, session} <- SalixAgent.InternalSessionStore.read(agent_id, session_id),
             :idle <- SalixAgent.InternalSession.status(session) do
          session
        else
          _ -> nil
        end
      end)

    assert Enum.any?(SalixAgent.InternalSession.get(session, :events), fn event ->
             event["kind"] == "visible_reply_egress" and
               event["source"] == "script_host" and
               event["method"] == "im_api.internal.send_message" and
               get_in(event, ["event", "agent_group_id"]) == group_id and
               get_in(event, ["event", "conversation_id"]) == conversation_id and
               get_in(event, ["event", "source_message_ids"]) == [source_identity]
           end)

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "assistant" and
               message.content == "runtime-only after nested send" and
               message.tool_calls == []
           end)

    messages =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.map(messages, &content_text(&1["content"])) == [
             "send from a nested script",
             "explicit nested reply"
           ]

    assert Enum.map(messages, & &1["actor_type"]) == ["user", "agent"]
  end

  @tag :spinfoam
  @tag skip:
         if(SalixAgent.SpinfoamFixture.available?(),
           do: false,
           else: "spinfoam binary unavailable"
         )
  test "repair after a nested script failure executes the agent's follow-up send", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    previous_llm = Application.get_env(:salix_agent, :llm)
    Application.put_env(:salix_agent, :llm, RepairNestedFailureLLM)

    conversation =
      create_conversation_with_agent(group_id, agent_id, title: "Nested source send failure")

    conversation_id = conversation["conversation_id"]
    RepairNestedFailureLLM.configure(self(), conversation_id)

    on_exit(fn ->
      RepairNestedFailureLLM.clear()
      Application.put_env(:salix_agent, :llm, previous_llm)
    end)

    participants = conversation_participants(group_id, conversation_id)
    user_participant = Enum.find(participants, &(&1["actor_type"] == "user"))
    agent_participant = Enum.find(participants, &(&1["agent_id"] == agent_id))
    session_id = get_in(agent_participant, ["payload", "session_id"])

    sent =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages",
        json: %{
          participant_id: user_participant["participant_id"],
          actor_type: "user",
          user_id: "current",
          content: [%{type: "text", text: "send, then fail in the script"}],
          client_request_id: "visible-reply-nested-send-failure-1"
        }
      )

    assert sent.status == 201

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               sent.body["message_id"],
               agent_participant["participant_id"]
             )

    assert_receive :nested_source_send_failure_final_returned, 5_000

    session =
      eventually(fn ->
        case SalixAgent.InternalSessionStore.read(agent_id, session_id) do
          {:ok, session} ->
            if SalixAgent.InternalSession.status(session) == :idle and
                 SalixAgent.InternalSession.get(session, :visible_reply_repair) == nil and
                 not SalixAgent.InternalSession.pending_visible_reply?(session) and
                 SalixAgent.InternalSession.work_reasons(session) == [],
               do: session

          _ ->
            nil
        end
      end)

    assert Enum.any?(SalixAgent.InternalSession.get(session, :events), fn event ->
             event["kind"] == "visible_reply_egress" and
               event["source"] == "script_host" and
               event["method"] == "im_api.internal.send_message" and
               get_in(event, ["event", "agent_group_id"]) == group_id and
               get_in(event, ["event", "conversation_id"]) == conversation_id and
               get_in(event, ["event", "source_message_ids"]) == [source_identity]
           end)

    assert {:ok, %{"status" => "failed"} = js_failure} =
             SalixAgent.InternalSession.lookup_async_call(
               session,
               "nested-source-send-js-failure"
             )

    assert js_failure["error_class"] == "tool_error"
    assert js_failure["diagnostic_visibility"] == "model_only"
    assert get_in(js_failure, ["result", "content"]) =~ "script exited with code 1"

    assert Enum.any?(SalixAgent.InternalSession.get(session, :messages), fn message ->
             message.role == "assistant" and
               message.content == "runtime-only after nested send failure" and
               message.tool_calls == []
           end)

    messages =
      req(
        :get,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/messages"
      ).body

    assert Enum.map(messages, &content_text(&1["content"])) == [
             "send, then fail in the script",
             "explicit nested reply before JavaScript failure",
             "agent-chosen follow-up after JavaScript failure"
           ]

    assert Enum.map(messages, & &1["actor_type"]) == ["user", "agent", "agent"]
  end

  test "message validation matches willow's contract", %{group_id: group_id} do
    conversation =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/conversations",
        json: %{
          name: "Val",
          participants: [
            %{
              actor_type: "user",
              user_id: "current",
              state: "active",
              notification_filter: %{messages: "all", statuses: "none"}
            }
          ]
        }
      ).body

    path =
      "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation["conversation_id"]}/messages"

    assert %{status: 400, body: %{"error" => "content is required"}} =
             req(:post, path, json: %{content: [], source_message_id: "test-msg-10"})

    assert %{status: 400, body: %{"error" => "invalid IM message kind"}} =
             req(:post, path, json: %{kind: "bogus", content: [%{type: "text", text: "x"}]})

    assert %{
             status: 400,
             body: %{"error" => "content must include at least one non-image_url content block"}
           } =
             req(:post, path,
               json: %{content: [%{type: "image_url", image_url: %{url: "http://x"}}]}
             )

    assert %{status: 400, body: %{"error" => "invalid IM message metadata"}} =
             req(:post, path, json: %{content: [%{type: "text", text: "x"}], metadata: "nope"})

    # app_event: no content required, recorded without participant delivery.
    assert %{status: 201, body: %{"delivery_status" => "recorded"}} =
             req(:post, path, json: %{kind: "app_event"})

    assert %{status: 400, body: %{"error" => "limit must be <= 1000"}} =
             req(:get, path <> "?limit=2000")
  end

  test "activity surface dismissal stamps the conversation", %{group_id: group_id} do
    conversation =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/conversations", json: %{title: "Dismiss"}).body

    conversation_id = conversation["conversation_id"]

    dismissal =
      req(
        :post,
        "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}/activity-surface-dismissal"
      )

    assert dismissal.status == 200
    assert dismissal.body["conversation_id"] == conversation_id
    assert is_integer(dismissal.body["activity_surface_dismissed_at"])

    assert req(
             :get,
             "/v1/runtime/agent-groups/#{group_id}/conversations/#{conversation_id}"
           ).body[
             "activity_surface_dismissed_at"
           ] == dismissal.body["activity_surface_dismissed_at"]
  end

  test "conversation events stream emits explicitly appended user and agent messages", %{
    group_id: group_id,
    agent_id: agent_id
  } do
    conversation =
      req(:get, "/v1/runtime/agent-groups/#{group_id}/router/conversation").body

    conversation_id = conversation["conversation_id"]

    client = open_stream("/v1/runtime/agent-groups/#{group_id}/conversations/events")
    on_exit(fn -> Process.exit(client, :kill) end)

    assert_receive {:sse_headers, headers}, 3_000
    assert headers =~ "HTTP/1.1 200"
    assert String.downcase(headers) =~ "content-type: text/event-stream"

    sent =
      req(:post, "/v1/runtime/agent-groups/#{group_id}/router/messages",
        json: %{content: [%{type: "text", text: "stream me"}], client_request_id: "sse-1"}
      ).body

    assert sent["delivery_status"] == "queued"
    message_id = sent["message_id"]
    assert Ids.valid_message_id?(message_id)

    assert_receive {:sse_frame,
                    %{
                      "event" => "message_created",
                      "data" => %{
                        "conversation_id" => ^conversation_id,
                        "message_id" => ^message_id,
                        "actor_type" => "user"
                      }
                    }},
                   7_000

    assert {:ok, %{"message_id" => agent_message_id}} =
             ConversationServer.append_group_conversation_agent_message(
               group_id,
               conversation_id,
               agent_id,
               %{
                 "content" => "explicit SSE reply",
                 "client_request_id" => "explicit-sse-reply-1"
               }
             )

    assert_receive {:sse_frame,
                    %{
                      "event" => "message_created",
                      "data" => %{
                        "conversation_id" => ^conversation_id,
                        "message_id" => ^agent_message_id,
                        "actor_type" => "agent",
                        "content" => [%{"type" => "text", "text" => "explicit SSE reply"}]
                      }
                    }},
                   7_000
  end

  # ---- minimal raw SSE client (chunked HTTP; pattern from sse_live_test) ----

  defp open_stream(path) do
    parent = self()
    # Capture the key in the test process — the spawned reader has its own
    # (empty) process dictionary, so tenant_key() must be resolved out here.
    token = tenant_key()

    spawn(fn ->
      port = SalixWeb.Application.http_port()
      {:ok, sock} = :gen_tcp.connect(@host, port, [:binary, active: false, packet: :raw], 2_000)

      request =
        "GET #{path} HTTP/1.1\r\n" <>
          "host: 127.0.0.1:#{port}\r\n" <>
          "authorization: Bearer #{token}\r\n" <>
          "accept: text/event-stream\r\n" <>
          "\r\n"

      :ok = :gen_tcp.send(sock, request)
      recv_loop(sock, parent, %{phase: :headers, buf: "", sse: ""})
      :gen_tcp.close(sock)
    end)
  end

  defp recv_loop(sock, parent, st) do
    case :gen_tcp.recv(sock, 0, 15_000) do
      {:ok, bytes} ->
        case ingest(parent, %{st | buf: st.buf <> bytes}) do
          {:cont, st} -> recv_loop(sock, parent, st)
          :done -> send(parent, {:sse_closed, :final_chunk})
        end

      {:error, reason} ->
        send(parent, {:sse_closed, reason})
    end
  end

  defp ingest(parent, %{phase: :headers, buf: buf} = st) do
    case :binary.split(buf, "\r\n\r\n") do
      [head, rest] ->
        send(parent, {:sse_headers, head})
        ingest(parent, %{st | phase: :body, buf: rest})

      [_incomplete] ->
        {:cont, st}
    end
  end

  defp ingest(parent, %{phase: :body, buf: buf, sse: sse} = st) do
    case dechunk(buf, "") do
      {:more, data, rest} ->
        {:cont, emit_frames(parent, %{st | buf: rest, sse: sse <> data})}

      {:done, data, _} ->
        _ = emit_frames(parent, %{st | sse: sse <> data})
        :done
    end
  end

  defp dechunk(buf, acc) do
    case :binary.split(buf, "\r\n") do
      [size_line, rest] ->
        size = size_line |> String.split(";") |> hd() |> String.trim() |> String.to_integer(16)

        cond do
          size == 0 ->
            {:done, acc, rest}

          byte_size(rest) >= size + 2 ->
            <<data::binary-size(^size), "\r\n", rest2::binary>> = rest
            dechunk(rest2, acc <> data)

          true ->
            {:more, acc, buf}
        end

      [_incomplete] ->
        {:more, acc, buf}
    end
  end

  defp emit_frames(parent, %{sse: sse} = st) do
    parts = String.split(sse, "\n\n")
    {complete, [remainder]} = Enum.split(parts, length(parts) - 1)

    for frame <- complete, frame != "" do
      parsed =
        frame
        |> String.split("\n", trim: true)
        |> Enum.reduce(%{}, fn line, acc ->
          case line do
            "event: " <> event -> Map.put(acc, "event", event)
            "data: " <> data -> Map.put(acc, "data", Jason.decode!(data))
            _ -> acc
          end
        end)

      if Map.has_key?(parsed, "event"), do: send(parent, {:sse_frame, parsed})
    end

    %{st | sse: remainder}
  end

  defp start_bandit_retry!(spec_fun) do
    Enum.find_value(1..10, fn _ ->
      port = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case start_supervised(spec_fun.(port), id: {:recording_slack_api, port}) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || raise "could not bind a test port after 10 attempts"
  end

  defp eventually(fun, retries \\ 200) do
    case fun.() do
      nil when retries > 0 ->
        Process.sleep(25)
        eventually(fun, retries - 1)

      nil ->
        flunk("condition never became true")

      false when retries > 0 ->
        Process.sleep(25)
        eventually(fun, retries - 1)

      false ->
        flunk("condition never became true")

      value ->
        value
    end
  end

  defp eventually_admission(group, conversation, message, participant) do
    {:ok, messages} = SalixIM.Conversations.list_group_conversation_messages(group, conversation)
    seq = Enum.find(messages, &(&1["message_id"] == message))["seq"]

    eventually(fn ->
      with {:ok, sources, _} <-
             SalixAgent.ConversationConsumer.progress(
               participant["agent_id"],
               participant["payload"]["session_id"]
             ),
           %{"seq" => admitted} = source <- sources[participant["participant_id"]],
           true <- admitted >= seq,
           do: source,
           else: (_ -> nil)
    end)
  end

  defp eventually_delivery(key) do
    eventually(fn -> delivery_record(key) end)
  end

  defp delivery_record(key) do
    with %{^key => body} <- SalixStore.S3.Fake.dump() do
      body |> fake_dump_body() |> Jason.decode!()
    else
      _ -> nil
    end
  end

  defp delivery_key(group_id, conversation_id, delivery_identity, participant_id) do
    Keys.ctl_group_conversation_participant_delivery_state(
      group_id,
      conversation_id,
      participant_id,
      Enum.join([group_id, conversation_id, delivery_identity, participant_id], ":")
    )
  end

  defp content_text(content) when is_binary(content), do: content

  defp content_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &to_string(&1["text"] || ""))
  end

  defp content_text(_content), do: ""

  defp slack_envelope(app_id, event_id, event) do
    %{
      "type" => "event_callback",
      "api_app_id" => app_id,
      "team_id" => "T-worker",
      "event_id" => event_id,
      "event" => event
    }
  end

  defp deliver_slack_event!(secret, envelope) do
    response = post_slack_event!(secret, envelope)

    assert response.status == 200
    assert response.body == %{"ok" => true}
  end

  defp post_slack_event!(secret, envelope) do
    raw = Jason.encode!(envelope)

    Req.post!(base() <> "/v1/im/slack/events",
      body: raw,
      headers: [{"content-type", "application/json"} | sign_slack_body(raw, secret)]
    )
  end

  defp sign_slack_body(body, secret, timestamp \\ System.system_time(:second)) do
    mac =
      :crypto.mac(:hmac, :sha256, secret, "v0:#{timestamp}:#{body}")
      |> Base.encode16(case: :lower)

    [
      {"x-slack-request-timestamp", Integer.to_string(timestamp)},
      {"x-slack-signature", "v0=" <> mac}
    ]
  end

  defp call_internal_provider(agent_id, group_id, api, params, tool_call_id) do
    Salix.Bindings.AgentIMProvider.call_api(agent_id, "internal", api, %{
      "connect_id" => "internal",
      "tool_call_id" => tool_call_id,
      "params" => params,
      "tool_context" => %{
        "runtime_kind" => "internal",
        "session_id" => router_session_id(agent_id, group_id)
      }
    })
  end

  defp put_or_delete_env(app, key, nil), do: Application.delete_env(app, key)
  defp put_or_delete_env(app, key, value), do: Application.put_env(app, key, value)
end
