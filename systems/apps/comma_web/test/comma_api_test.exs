defmodule CommaWeb.CommaApiTest do
  use ExUnit.Case, async: false

  import Comma.WorkspaceTestSupport

  alias SalixAgent.LLM.Mock
  alias SalixIM.ConversationSearchProjection
  alias SalixStore.{ConversationSearch, Repo, SearchDocumentEnvelope}

  @admin_token "test-token"

  defmodule SearchFailureSalixClient do
    @moduledoc false

    def resolve_workspace_scope(workspace), do: {:ok, workspace}

    def search_group_tasks(_workspace, _query, opts) do
      if owner = Application.get_env(:comma_web, :task_search_test_pid) do
        send(owner, {:task_search_backend_called, opts})
      end

      {:error, {:owner_unreachable, "internal-search-owner", :timeout}}
    end
  end

  defmodule PluginInstallComposio do
    @moduledoc false

    def get(_tenant_id), do: {:ok, %{"api_key" => "ck_test"}}

    def list_connected_accounts(_settings, group_id) do
      accounts = Application.get_env(:comma_web, :comma_api_plugin_install_accounts, [])
      {:ok, Enum.filter(accounts, &(&1["user_id"] == group_id))}
    end

    def list_connected_accounts_all(settings, group_id, _opts \\ []),
      do: list_connected_accounts(settings, group_id)

    def ensure_auth_config(_settings, toolkit), do: {:ok, "auth-#{toolkit}"}

    def create_connect_link(_settings, "auth-" <> toolkit, group_id, _opts) do
      {:ok,
       %{
         "redirect_url" => "https://connect.composio.dev/link/#{toolkit}",
         "connected_account_id" => "ca_#{group_id}_#{toolkit}"
       }}
    end

    def get_connected_account(_settings, id) do
      case Enum.find(
             Application.get_env(:comma_web, :comma_api_plugin_install_accounts, []),
             &(&1["id"] == id)
           ) do
        nil -> {:error, :not_found}
        account -> {:ok, account}
      end
    end

    def delete_connected_account(_settings, id) do
      accounts = Application.get_env(:comma_web, :comma_api_plugin_install_accounts, [])

      Application.put_env(
        :comma_web,
        :comma_api_plugin_install_accounts,
        Enum.reject(accounts, &(&1["id"] == id))
      )

      :ok
    end
  end

  defmodule FollowUpLLM do
    @moduledoc false
    @behaviour SalixAgent.LLM
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def script(input, [response]) do
      Agent.update(__MODULE__, &Map.put(&1, input, response))
    end

    @impl true
    def complete(messages, _tools) do
      latest_input =
        messages
        |> Enum.reverse()
        |> Enum.find(%{}, &((&1[:role] || &1["role"]) == "user"))
        |> then(&(&1[:content] || &1["content"] || ""))
        |> Jason.encode!()

      Agent.get_and_update(__MODULE__, fn responses ->
        case Enum.find(responses, fn {input, _} -> String.contains?(latest_input, input) end) do
          {input, response} ->
            {response, Map.delete(responses, input)}

          nil ->
            {{:assistant, "done",
              [
                %{
                  id: "done-#{System.unique_integer([:positive])}",
                  name: "end_turn",
                  args: %{"outcome" => "done"}
                }
              ]}, responses}
        end
      end)
    end
  end

  defmodule ReliableParticipantSessionActivity do
    @moduledoc false
    @behaviour SalixIM.Ports.SessionActivity

    @state_key {__MODULE__, :snapshot}

    def configure(snapshot) when is_map(snapshot),
      do: :persistent_term.put(@state_key, snapshot)

    def clear, do: :persistent_term.erase(@state_key)

    @impl true
    def get(_agent_id, _session_id), do: {:ok, :persistent_term.get(@state_key)}

    @impl true
    def subscribe(_agent_id, _session_id), do: :ok

    @impl true
    def unsubscribe(_agent_id, _session_id), do: :ok
  end

  setup context do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)

    comma_owner =
      CommaWeb.TestRepoSandbox.start_owner!(
        if(context[:multi_connection_comma_repo], do: :multi_connection, else: :transaction)
      )

    ensure_fake_s3!()
    SalixAgent.TestSupport.stop_all_agents()
    SalixStore.Repo.query!("TRUNCATE session_work_candidates")

    prev_backend = Application.get_env(:salix_store, :s3_backend)
    prev_llm = Application.get_env(:salix_agent, :llm)
    prev_im_provider = Application.get_env(:salix_agent, :im_provider_mod)
    prev_salix_client = Application.get_env(:comma_core, :salix_client)
    prev_api_token = Application.get_env(:comma_web, :api_token)
    prev_im_notifier = Application.get_env(:salix_im, :conversation_notifier)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_web, :api_token, @admin_token)
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)
    Application.put_env(:salix_agent, :im_provider_mod, Salix.Bindings.AgentIMProvider)
    CommaWeb.Application.register_im_notifier()
    start_supervised!(Mock)
    Application.put_env(:salix_agent, :llm, Mock)
    start_stripe_recorder()
    seed_comma_v1_provider_prices()

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      Application.put_env(:salix_store, :s3_backend, prev_backend)
      Application.put_env(:salix_agent, :llm, prev_llm)
      restore_env(:salix_agent, :im_provider_mod, prev_im_provider)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      restore_env(:salix_im, :conversation_notifier, prev_im_notifier)
      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  test "Participant execution history returns a bounded tail, pages older records and rejects restricted sessions" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "session-history@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    chat = active_chat!(session, workspace)
    group_id = workspace["default_group_id"]

    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(group_id, chat["id"])

    participant = Enum.find(participants, &(&1["actor_type"] == "agent"))
    agent_id = participant["agent_id"]
    sid = get_in(participant, ["payload", "session_id"])

    # A shared Router history is not scoped to the Conversation used to open it.
    # Only finite source facts may cross the diagnostic API, not raw routing or
    # principal/credential metadata. A prose lookalike must stay unclassified.
    telegram_origin = %{
      "provider" => "telegram",
      "source_actor_type" => "provider_user",
      "source_text" => "我今天的天气如何",
      "principal_ref" => %{"credential" => "private-principal"},
      "provider_context" => %{"chat_type" => "private", "chat_id" => "private-chat-id"}
    }

    voice_origin = %{
      "provider" => "voice",
      "source_actor_type" => "provider_user",
      "source_text" => "What is on my calendar today?",
      "provider_context" => %{"chat_type" => "private", "chat_id" => "vc_private-call-id"}
    }

    signal_origin = %{
      "provider" => "signal",
      "source_actor_type" => "provider_user",
      "source_text" => "Where do we meet?",
      "provider_context" => %{"chat_type" => "group", "chat_id" => "group:private-group-id"}
    }

    internal_origin = %{
      "provider" => "internal",
      "source_actor_type" => "agent",
      "source_text" => String.duplicate("界", 400),
      "conversation_kind" => "agent_task",
      "conversation_id" => "another-task-not-the-open-chat"
    }

    events =
      for id <- 1..8,
          do: %{
            "type" => "delivery",
            "from_queue" => true,
            "message_id" => id,
            "role" => "user",
            "content" => "Execution #{id}",
            "source_message_id" => "history-#{id}",
            "trusted_origin" =>
              case id do
                4 -> signal_origin
                5 -> voice_origin
                6 -> telegram_origin
                7 -> internal_origin
                _ -> nil
              end,
            "created_at" => 1000 + id
          }

    # Fixture writes use the same explicit owner registration as the Session
    # storage suite; the read-only HTTP path never activates the agent loop.
    assert {:ok, _} =
             Registry.register(
               SalixAgent.Registry,
               SalixAgent.InternalSessionActor.key(agent_id, sid),
               nil
             )

    path =
      "/v1/comma/groups/#{group_id}/conversations/#{chat["id"]}/participants/#{participant["participant_id"]}/history"

    # Open the real authorized HTTP stream while storage is empty. Wait for its
    # empty checkpoint before committing: no sleeps or reconnect can fill the gap.
    assert {:ok, _} = SalixAgent.InternalSessionStore.create(agent_id, sid, %{})
    {:ok, _} = Application.ensure_all_started(:inets)
    server = start_supervised!({Bandit, plug: CommaWeb.Router, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, request_id} =
      :httpc.request(
        :get,
        {String.to_charlist("http://127.0.0.1:#{port}#{path}/events?wait_ms=3000"),
         [{~c"authorization", String.to_charlist("Bearer #{session["token"]}")}]},
        [timeout: 6000],
        sync: false,
        stream: :self
      )

    empty_stream =
      receive_history_http(request_id, &String.contains?(&1, "\"phase\":\"checkpoint\""))

    assert empty_stream =~ "\"checkpoint\":null"
    assert {:ok, _} = SalixAgent.InternalSessionStore.commit(agent_id, sid, events)

    Phoenix.PubSub.broadcast(
      Application.get_env(:comma_core, :pubsub_server, CommaWeb.PubSub),
      CommaWeb.PubSubNotifier.topic(agent_id),
      {:salix_agent_event, agent_id, {:session_updated, sid}}
    )

    first_update = receive_history_http(request_id, &String.contains?(&1, "\"checkpoint\":\"8\""))

    first_frames =
      first_update
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn line -> line |> String.replace_prefix("data: ", "") |> Jason.decode!() end)

    first_ids = first_frames |> Enum.flat_map(& &1["records"]) |> Enum.map(& &1["id"])
    assert first_ids == Enum.map(1..8, &Integer.to_string/1)

    stream_telegram =
      first_frames |> Enum.flat_map(& &1["records"]) |> Enum.find(&(&1["id"] == "6"))

    assert stream_telegram["input_source"] == %{
             "provider" => "telegram",
             "actor_type" => "user",
             "chat_type" => "private"
           }

    # A phone or voice-client call reaches the Router as the voice provider.
    assert first_frames
           |> Enum.flat_map(& &1["records"])
           |> Enum.find(&(&1["id"] == "5"))
           |> Map.fetch!("input_source") == %{
             "provider" => "voice",
             "actor_type" => "user",
             "chat_type" => "private"
           }

    # A bound Signal chat reaches the Router as the signal provider.
    assert first_frames
           |> Enum.flat_map(& &1["records"])
           |> Enum.find(&(&1["id"] == "4"))
           |> Map.fetch!("input_source") == %{
             "provider" => "signal",
             "actor_type" => "user",
             "chat_type" => "group"
           }

    :httpc.cancel_request(request_id)

    latest =
      user_req(session["token"], :get, path <> "?limit=3")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert length(latest["records"]) == 3
    assert latest["has_more"]

    assert Enum.map(latest["records"], &get_in(&1, ["content", "content"])) == [
             "Execution 6",
             "Execution 7",
             "Execution 8"
           ]

    refute inspect(latest) =~ sid
    [telegram, task, legacy] = latest["records"]
    assert telegram["input_text"] == "我今天的天气如何"
    assert telegram["content"]["content"] == "Execution 6"
    refute Map.has_key?(legacy, "input_text")
    assert telegram["input_source"] == stream_telegram["input_source"]
    assert task["input_text"] == String.duplicate("界", 321)

    assert task["input_source"] == %{
             "provider" => "internal",
             "actor_type" => "agent",
             "conversation_kind" => "agent_task"
           }

    assert legacy["input_source"] == %{}
    refute inspect(latest) =~ "private-principal"
    refute inspect(latest) =~ "private-chat-id"
    refute inspect(first_frames) =~ "private-group-id"
    refute inspect(latest) =~ "another-task-not-the-open-chat"
    refute inspect(latest) =~ "trusted_origin"

    older =
      user_req(session["token"], :get, path <> "?limit=50&before=" <> latest["next_before"])
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert Enum.map(older["records"], &get_in(&1, ["content", "content"])) ==
             for(id <- 1..5, do: "Execution #{id}")

    refute older["has_more"]
    user_req(session["token"], :get, path <> "?limit=100000") |> expect_status(400)

    timing = %{
      "version" => 1,
      "started_at_ms" => 1_788_564_963_000,
      "first_token_at_ms" => 1_788_564_963_050,
      "observed_at_ms" => 1_788_564_963_250,
      "completed_at_ms" => 1_788_564_963_250,
      "duration_ms" => 250
    }

    assert {:ok, _} =
             SalixAgent.InternalSessionStore.commit(agent_id, sid, [
               %{
                 "type" => "assistant",
                 "message_id" => 9,
                 "content" => "Measured reply",
                 "model" => "history-test-model",
                 "input_tokens" => 12000,
                 "output_tokens" => 600,
                 "cache_read_input_tokens" => 9000,
                 "cache_write_input_tokens" => 1000,
                 "execution_timing" => timing,
                 "created_at" => 1_788_564_963
               },
               %{
                 "type" => "runtime_message",
                 "from_context_provider" => true,
                 "no_wake" => true,
                 "message_id" => 10,
                 "runtime_message_id" => "migration-history-test",
                 "runtime_message_type" => "migration_notice_delta",
                 "summary" => "Tool contract updated",
                 "content" => "Complete migration instructions",
                 "created_at" => 1_788_564_964
               }
             ])

    timed_page =
      user_req(session["token"], :get, path <> "?limit=2")
      |> expect_status(200)
      |> Map.fetch!(:body)

    [model, notice] = timed_page["records"]
    assert model["timestamp_ms"] == 1_788_564_963_000
    assert model["execution"]["lane"] == "model"
    assert model["execution"]["duration_ms"] == 250
    assert model["content"]["model"] == "history-test-model"
    assert model["content"]["input_tokens"] == 12000
    assert model["content"]["output_tokens"] == 600
    assert model["content"]["cache_read_input_tokens"] == 9000
    assert model["content"]["cache_write_input_tokens"] == 1000

    assert model["execution"]["first_token_at_ms"] == 1_788_564_963_050
    assert notice["kind"] == "runtime"
    assert notice["content"]["type"] == "migration_notice_delta"
    assert notice["content"]["summary"] == "Tool contract updated"
    assert notice["timestamp_ms"] == 1_788_564_964_000

    # A dense three-minute preview streams bounded batches independently of the
    # three-row preview and fifty-row manual ledger. Reconnect replays by seq.
    now = System.system_time(:second)

    assert {:ok, _} =
             SalixAgent.InternalSessionStore.commit(
               agent_id,
               sid,
               for id <- 11..130 do
                 %{
                   "type" => "delivery",
                   "from_queue" => true,
                   "message_id" => id,
                   "role" => "user",
                   "content" => "Recent #{id}",
                   "source_message_id" => "history-#{id}",
                   "created_at" => now
                 }
               end
             )

    streamed =
      user_req(session["token"], :get, path <> "/events?after=10&wait_ms=100")
      |> expect_status(200)

    frames =
      streamed.body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(fn line -> line |> String.replace_prefix("data: ", "") |> Jason.decode!() end)

    assert Enum.all?(frames, &(length(&1["records"]) <= 50))
    recent = frames |> Enum.filter(&(&1["phase"] == "recent")) |> Enum.flat_map(& &1["records"])
    updates = frames |> Enum.filter(&(&1["phase"] == "update")) |> Enum.flat_map(& &1["records"])
    assert length(recent) == 120
    assert length(updates) == 120
    assert List.last(frames)["checkpoint"] == "130"
    refute inspect(frames) =~ sid

    restricted =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => group_id,
          "conversation_id" => chat["id"],
          "restricted" => true
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    user_req(restricted["token"], :get, path) |> expect_status(403)
    user_req(restricted["token"], :get, path <> "/events?wait_ms=100") |> expect_status(403)

    other =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "history-other@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    other_session =
      admin_req(:post, "/v1/comma/admin/users/#{other["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert user_req(other_session["token"], :get, path).status in [403, 404]
  end

  test "admin creates user/workspace/session and user session drives a conversation to final state" do
    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "user@example.com", "name" => "User"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Team"})

    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    public_workspace =
      user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert public_workspace["id"] == workspace["id"]
    assert public_workspace["billing_account_id"] == workspace["billing_account_id"]

    for internal_key <- [
          "salix_tenant_id",
          "router_agent_id",
          "default_worker_agent_id"
        ] do
      refute Map.has_key?(public_workspace, internal_key)
      refute inspect(public_workspace) =~ workspace[internal_key]
    end

    assert public_workspace["group_id"] == workspace["default_group_id"]

    conversation = active_chat!(session, workspace)

    refute Map.has_key?(conversation, "internal")
    assert conversation["group_id"] == workspace["default_group_id"]

    Mock.script(visible_reply_script(conversation["id"], "hello from comma", "reply-req-1"))

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"

    first =
      user_req(session["token"], :post, send_path,
        json: %{
          "client_request_id" => "req-1",
          "message" => %{"content" => "hello"}
        }
      )
      |> expect_status(202)
      |> Map.fetch!(:body)

    retry =
      user_req(session["token"], :post, send_path,
        json: %{
          "client_request_id" => "req-1",
          "message" => %{"content" => "hello"}
        }
      )
      |> expect_status(202)
      |> Map.fetch!(:body)

    assert Enum.count(first["messages"], &(&1["actor_type"] == "user")) == 1
    assert Enum.count(retry["messages"], &(&1["actor_type"] == "user")) == 1

    final =
      eventually(fn ->
        body =
          user_req(
            session["token"],
            :get,
            "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
          )
          |> expect_status(200)
          |> Map.fetch!(:body)

        if Enum.any?(body["messages"], &(&1["actor_type"] == "agent")), do: body
      end)

    assert [
             %{"actor_type" => "user"} = user_message,
             %{
               "actor_type" => "agent",
               "content" => [%{"type" => "text", "text" => "hello from comma"}]
             } = assistant_message
           ] =
             final["messages"]

    assert String.starts_with?(user_message["message_id"], "msg1_")
    assert String.starts_with?(assistant_message["message_id"], "msg1_")
    assert final["final_message_id"] == List.last(final["messages"])["message_id"]

    recent =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}?message_limit=1"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert recent["messages"] == [assistant_message]
    assert recent["message_count"] == final["message_count"]
    assert recent["final_message_id"] == assistant_message["message_id"]

    assert inspect(final) =~ workspace["router_agent_id"]

    events_resp =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/events?wait=0"
      )
      |> expect_status(200)

    assert header(events_resp, "content-type") =~ "text/event-stream"
    assert events_resp.body =~ "event: snapshot"
    assert events_resp.body =~ "hello from comma"
    refute events_resp.body =~ "event: message_created"
    refute events_resp.body =~ "last_event_id"

    reloaded =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert reloaded["id"] == conversation["id"]
    assert reloaded["final_message_id"] == final["final_message_id"]

    reloaded_events =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/events?wait=0"
      )
      |> expect_status(200)

    assert reloaded_events.body =~ "event: snapshot"
    assert reloaded_events.body =~ "hello from comma"
    refute reloaded_events.body =~ "event: message_created"
  end

  test "Comma lists and reads canonical Salix Tasks immediately without adoption or projection" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "canonical-task@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    assert {:ok, task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               workspace["default_group_id"],
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Canonical immediately visible Task",
                 "content" => "Read this Task directly from Salix",
                 "client_request_id" => "canonical-task-no-adoption"
               }
             )

    task_id = task["conversation_id"]

    # Status discovery uses the Task's actual initiator/primary Worker and
    # the Conversation owner's indexed membership, never the current default
    # Worker or a participant/session scan.
    assert {:ok, participants} =
             CommaWeb.SalixClient.task_activity_participants(workspace, task_id)

    assert length(participants) == 2

    assert Enum.all?(
             participants,
             &(Map.keys(&1) -- ["participant_id", "name", "agent_id"] == [])
           )

    assert Enum.sort(Enum.map(participants, & &1["name"])) ==
             [workspace["name"] <> " Router", workspace["name"] <> " Worker"]

    assert task["worker_participant_id"] in Enum.map(participants, & &1["participant_id"])

    assert {:ok, same_participants} =
             CommaWeb.SalixClient.task_activity_participants(
               Map.put(workspace, "default_worker_agent_id", "not-the-task-worker"),
               task_id
             )

    assert same_participants == participants

    group_id = workspace["default_group_id"]

    listed =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"id" => ^task_id, "kind" => "agent_task"} = listed_task] = listed["data"]
    assert listed_task["group_id"] == group_id
    assert listed_task["title"] == "Canonical immediately visible Task"
    assert listed_task["freshness"]["state"] == "fresh"

    assert {:ok, _updated} =
             SalixIM.ConversationServer.update_group_conversation(
               workspace["default_group_id"],
               task_id,
               %{"title" => "Canonical updated Task", "status" => "failed"}
             )

    refreshed =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"id" => ^task_id, "title" => "Canonical updated Task", "status" => "failed"}] =
             refreshed["data"]

    detail =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{group_id}/conversations/#{task_id}"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert detail["id"] == task_id
    assert detail["title"] == "Canonical updated Task"
    assert Enum.any?(detail["messages"], &(salix_message_text(&1) =~ "Read this Task directly"))
  end

  test "Comma stores the dragged Task order per bucket through Group-addressed routes" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "task-order@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    task_ids =
      for title <- ["Order me first", "Order me second"] do
        assert {:ok, task} =
                 SalixCluster.TaskSchedules.create_task_conversation(
                   workspace["default_group_id"],
                   workspace["router_agent_id"],
                   workspace["default_worker_agent_id"],
                   %{
                     "title" => title,
                     "content" => "Keep this Task ordered",
                     "client_request_id" => "group-task-order-#{title}"
                   }
                 )

        task["conversation_id"]
      end

    group_id = workspace["default_group_id"]
    order_path = "/v1/comma/groups/#{group_id}/task-order"

    # Nothing stored yet: the arrangement reads as empty, never as an error.
    assert user_req(session["token"], :get, order_path)
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"orders" => %{}}

    reordered = Enum.reverse(task_ids)

    assert user_req(
             session["token"],
             :put,
             order_path <> "/backlog",
             json: %{"ids" => reordered}
           )
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"orders" => %{"backlog" => reordered}}

    # The arrangement survives a fresh read — this is what outlives a reload.
    assert user_req(session["token"], :get, order_path)
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"orders" => %{"backlog" => reordered}}

    # A Conversation-scoped support session may observe its Task's position,
    # but it must neither learn another Conversation id nor replace the
    # Group-wide aggregate that also belongs to those other Conversations.
    scoped_task_id = hd(task_ids)

    restricted_session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "restricted" => true,
          "workspace_id" => workspace["id"],
          "group_id" => group_id,
          "conversation_id" => scoped_task_id
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    scoped_read =
      user_req(restricted_session["token"], :get, order_path)
      |> expect_status(200)
      |> Map.fetch!(:body)

    scoped_write =
      user_req(
        restricted_session["token"],
        :put,
        order_path <> "/backlog",
        json: %{"ids" => [scoped_task_id]}
      )

    canonical_after_rejected_write =
      user_req(session["token"], :get, order_path)
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert scoped_read == %{"orders" => %{"backlog" => [scoped_task_id]}}
    assert scoped_write.status == 403
    assert canonical_after_rejected_write == %{"orders" => %{"backlog" => reordered}}

    # A support session scoped to the Group rather than one Conversation still
    # owns the whole collection boundary and can read/write the aggregate.
    group_session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "restricted" => true,
          "workspace_id" => workspace["id"],
          "group_id" => group_id
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert user_req(group_session["token"], :get, order_path)
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"orders" => %{"backlog" => reordered}}

    assert user_req(
             group_session["token"],
             :put,
             order_path <> "/backlog",
             json: %{"ids" => reordered}
           )
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"orders" => %{"backlog" => reordered}}

    # Clearing a bucket removes it wholesale.
    assert user_req(session["token"], :put, order_path <> "/backlog", json: %{"ids" => []})
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"orders" => %{}}

    user_req(session["token"], :put, order_path <> "/backlog", json: %{"ids" => ["nope"]})
    |> expect_status(400)

    user_req(session["token"], :put, order_path <> "/backlog", json: %{})
    |> expect_status(400)
  end

  test "Comma pins and renames canonical Tasks through Group-addressed routes" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "task-pins@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    assert {:ok, task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               workspace["default_group_id"],
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Task to pin",
                 "content" => "Keep this Task visible",
                 "client_request_id" => "group-pin-task"
               }
             )

    group_id = workspace["default_group_id"]
    task_id = task["conversation_id"]
    detail_path = "/v1/comma/groups/#{group_id}/conversations/#{task_id}"

    pin =
      user_req(session["token"], :put, detail_path <> "/pin")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert pin["conversation"]["id"] == task_id
    assert pin["conversation"]["group_id"] == group_id
    assert is_integer(pin["pinned_at"])

    pins =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversation-pins")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"conversation" => %{"id" => ^task_id}}] = pins["data"]

    renamed =
      user_req(session["token"], :patch, detail_path, json: %{"title" => "  Group-owned title  "})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert renamed["id"] == task_id
    assert renamed["group_id"] == group_id
    assert renamed["title"] == "Group-owned title"

    user_req(session["token"], :patch, detail_path, json: %{"title" => "   "})
    |> expect_status(400)

    user_req(session["token"], :delete, detail_path <> "/pin")
    |> expect_status(204)

    assert user_req(
             session["token"],
             :get,
             "/v1/comma/groups/#{group_id}/conversation-pins"
           )
           |> expect_status(200)
           |> Map.fetch!(:body) == %{"data" => []}
  end

  test "Task search enforces HTTP scope and maps unavailable dependencies to a generic 503" do
    # Keep the Task fixtures stable while manually draining search claims.
    # A stopped mock Worker now emits watch Messages, advancing the canonical
    # version and legitimately invalidating an in-flight projection claim.
    previous_activity = Application.get_env(:salix_im, :session_activity_mod)

    ReliableParticipantSessionActivity.configure(%{
      "state" => "active",
      "status" => "is working..."
    })

    Application.put_env(:salix_im, :session_activity_mod, ReliableParticipantSessionActivity)

    on_exit(fn ->
      ReliableParticipantSessionActivity.clear()
      restore_env(:salix_im, :session_activity_mod, previous_activity)
    end)

    on_exit(fn -> Application.delete_env(:comma_web, :task_search_test_pid) end)

    eventually(fn ->
      if SalixIM.ConversationSearchEnqueuer.pending_count() == 0, do: true
    end)

    reset_search_projection!()

    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "task-search@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]

    assert {:ok, target} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Exact restricted needle",
                 "content" => "Searchable private needle content",
                 "client_request_id" => "task-search-target"
               }
             )

    assert {:ok, _decoy} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Needle outside exact scope",
                 "content" => "Searchable decoy content",
                 "client_request_id" => "task-search-decoy"
               }
             )

    matched_grapheme = "e" <> String.duplicate("\u0301", 16_319)

    boundary_content =
      String.duplicate("a", 49) <>
        matched_grapheme <>
        String.duplicate("b", 80)

    assert byte_size(boundary_content) == SearchDocumentEnvelope.max_bytes(:message)

    assert {:ok, boundary_task} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Boundary Unicode Task",
                 "content" => boundary_content,
                 "client_request_id" => "task-search-boundary"
               }
             )

    eventually(fn ->
      if SalixIM.ConversationSearchEnqueuer.pending_count() == 0 and
           search_projection_job_count(group_id) == 3,
         do: true
    end)

    drain_search_projection!()
    path = "/v1/comma/groups/#{group_id}/conversations/search?q=needle&limit=1"

    successful =
      user_req(session["token"], :get, path)
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert length(successful["data"]) == 1

    boundary_response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{group_id}/conversations/search?q=e%CC%81%CC%81"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [boundary_hit] = boundary_response["data"]
    assert boundary_hit["conversation_id"] == boundary_task["conversation_id"]
    assert byte_size(boundary_hit["snippet"]) == SearchDocumentEnvelope.max_bytes(:message)
    assert [%{"start" => start, "end" => finish}] = boundary_hit["highlights"]
    assert utf16_slice(boundary_hit["snippet"], start, finish) == matched_grapheme

    restricted =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => group_id,
          "conversation_id" => target["conversation_id"],
          "restricted" => true
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    restricted_response =
      user_req(restricted["token"], :get, path)
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [
             %{
               "conversation_id" => target_id,
               "matched_field" => "title",
               "updated_at" => target_updated_at,
               "content_match" => %{"snippet" => content_snippet, "highlights" => [range]}
             }
           ] = restricted_response["data"]

    assert target_id == target["conversation_id"]

    assert {:ok, canonical_target} =
             SalixIM.Conversations.get_group_conversation_record(group_id, target_id)

    assert target_updated_at == canonical_target["updated_at"]
    assert utf16_slice(content_snippet, range["start"], range["end"]) == "needle"

    no_auth = Req.get!(base() <> path)
    assert no_auth.status == 401

    user_req(
      session["token"],
      :get,
      "/v1/comma/groups/#{group_id}/conversations/search?q=e%CC%81"
    )
    |> expect_status(400)

    other_user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "task-search-other@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    other_workspace = create_ready_workspace!(other_user["id"])
    Application.put_env(:comma_web, :task_search_test_pid, self())
    Application.put_env(:comma_core, :salix_client, SearchFailureSalixClient)

    assert user_req(
             restricted["token"],
             :get,
             "/v1/comma/groups/#{other_workspace["default_group_id"]}/conversations/search?q=needle"
           ).status == 403

    refute_receive {:task_search_backend_called, _opts}, 50
    Application.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)

    Repo.query!(
      "DELETE FROM salix_cutover_markers " <>
        "WHERE name = 'conversation_search_projection_v1'"
    )

    unavailable = user_req(session["token"], :get, path, retry: false) |> expect_status(503)
    assert unavailable.body == %{"error" => "conversation_unavailable"}
    seed_search_ready_marker!()

    Application.put_env(:comma_core, :salix_client, SearchFailureSalixClient)
    timed_out = user_req(session["token"], :get, path, retry: false) |> expect_status(503)
    assert timed_out.body == %{"error" => "conversation_unavailable"}
    assert_receive {:task_search_backend_called, _opts}
  end

  test "Task-list SSE invalidates the old collection when a conversation changes kind" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "task-kind-events@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]

    assert {:ok, %{"conversation_id" => task_id}} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Task moving between collections",
                 "content" => "Move this canonical conversation out of Tasks",
                 "client_request_id" => "task-kind-events"
               }
             )

    response_task =
      Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?wait=300"
        )
      end)

    assert eventually(fn ->
             if group_list_subscriber_count(group_id) == 1, do: true
           end)

    assert {:error, {:bad_request, "invalid conversation kind"}} =
             SalixIM.ConversationServer.update_group_conversation(group_id, task_id, %{
               "kind" => "agent_job"
             })

    assert {:error, {:bad_request, "invalid conversation kind"}} =
             SalixIM.ConversationInput.create_group_conversation(group_id, %{
               "kind" => "agent_job",
               "title" => "Unknown collection"
             })

    assert {:ok, %{"kind" => "user_chat"}} =
             SalixIM.ConversationServer.update_group_conversation(group_id, task_id, %{
               "kind" => "user_chat"
             })

    response = Task.await(response_task, 2_000) |> expect_status(200)
    assert [resync] = sse_payloads(response.body, "conversation_list_resync_required")
    payloads = sse_payloads(response.body, "conversation_list_invalidated")

    assert resync["type"] == "conversation_list_resync_required"
    assert resync["kind"] == "agent_task"
    assert [invalidation] = payloads
    assert invalidation["kind"] == "agent_task"
    assert invalidation["version"] != resync["version"]

    refreshed =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations")
      |> expect_status(200)
      |> Map.fetch!(:body)

    refute Enum.any?(refreshed["data"], &(&1["id"] == task_id))
  end

  test "Task-list SSE invalidates the collection when a canonical Task is created" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "task-create-events@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]

    # Subscribe first: a Task created while the client is listening must reach
    # it as an invalidation, not wait for the Task's first later mutation.
    response_task =
      Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?wait=3000"
        )
      end)

    assert eventually(fn ->
             if group_list_subscriber_count(group_id) == 1, do: true
           end)

    assert {:ok, %{"conversation_id" => task_id}} =
             SalixCluster.TaskSchedules.create_task_conversation(
               group_id,
               workspace["router_agent_id"],
               workspace["default_worker_agent_id"],
               %{
                 "title" => "Task announced to an open stream",
                 "content" => "Announce this canonical Task while the client listens",
                 "client_request_id" => "task-create-events"
               }
             )

    response = Task.await(response_task, 10_000) |> expect_status(200)
    assert [resync] = sse_payloads(response.body, "conversation_list_resync_required")
    assert resync["kind"] == "agent_task"

    assert [_ | _] = invalidations = sse_payloads(response.body, "conversation_list_invalidated")
    assert Enum.all?(invalidations, &(&1["kind"] == "agent_task"))
    assert Enum.all?(invalidations, &(&1["version"] != resync["version"]))

    listed =
      user_req(session["token"], :get, "/v1/comma/groups/#{group_id}/conversations")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert Enum.any?(listed["data"], &(&1["id"] == task_id))
  end

  test "Participant owner failure clears realtime status and draft without closing canonical Conversation SSE" do
    previous_session_activity = Application.get_env(:salix_im, :session_activity_mod)

    ReliableParticipantSessionActivity.configure(%{
      "state" => "active",
      "status" => "is thinking...",
      "updated_at" => System.system_time(:millisecond)
    })

    Application.put_env(
      :salix_im,
      :session_activity_mod,
      ReliableParticipantSessionActivity
    )

    on_exit(fn ->
      ReliableParticipantSessionActivity.clear()
      restore_env(:salix_im, :session_activity_mod, previous_session_activity)
    end)

    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "participant-owner-sse@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    conversation = active_chat!(session, workspace)
    group_id = workspace["default_group_id"]
    conversation_id = conversation["id"]

    assert {:ok, user_participant} =
             CommaWeb.SalixClient.ensure_group_conversation_user_participant(
               workspace,
               conversation_id,
               user["id"]
             )

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               conversation_id
             )

    router_participant =
      Enum.find(participants, fn participant ->
        participant["actor_type"] == "agent" and
          participant["agent_id"] == workspace["router_agent_id"] and
          participant["state"] == "active"
      end)

    assert is_map(router_participant)
    router_participant_id = router_participant["participant_id"]

    assert {:ok, %{"inserted" => true, "message_id" => source_message_id}} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => user["id"],
                 "participant_id" => user_participant["participant_id"],
                 "client_request_id" => "participant-owner-sse-source",
                 "content" => "Show realtime status and draft"
               }
             )

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               source_message_id,
               user_participant["participant_id"]
             )

    response_identity =
      "rsp_" <> Base.url_encode64(:binary.copy(<<9>>, 18), padding: false)

    ReliableParticipantSessionActivity.configure(%{
      "state" => "active",
      "status" => "is thinking...",
      "updated_at" => System.system_time(:millisecond),
      "_participant_realtime" => %{
        "draft" => %{
          "agent_group_id" => group_id,
          "conversation_id" => conversation_id,
          "participant_id" => router_participant_id,
          "response_key" => response_identity,
          "revision" => 1,
          "status" => "streaming",
          "text" => "Transient participant draft",
          "source_message_ids" => [source_identity],
          "updated_at" => System.system_time(:millisecond)
        }
      }
    })

    assert participant_status_subscriber_count(
             group_id,
             conversation_id,
             router_participant_id
           ) == 0

    response_task =
      Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/#{conversation_id}/events?wait=1000"
        )
      end)

    assert eventually(fn ->
             if participant_status_subscriber_count(
                  group_id,
                  conversation_id,
                  router_participant_id
                ) == 1,
                do: true
           end)

    assert [{conversation_owner, _value}] =
             Registry.lookup(
               SalixIM.ConversationRegistry,
               SalixIM.ConversationActor.key(group_id, conversation_id)
             )

    assert [{participant_owner, _value}] =
             Registry.lookup(
               SalixIM.ConversationRegistry,
               SalixIM.ConversationParticipantActor.key(
                 group_id,
                 conversation_id,
                 router_participant_id
               )
             )

    participant_state = :sys.get_state(participant_owner)
    assert [stream_process] = Map.keys(participant_state.realtime_subscribers)

    assert eventually(fn ->
             case Process.info(stream_process, :monitors) do
               {:monitors, monitors} ->
                 if {:process, participant_owner} in monitors, do: true

               nil ->
                 nil
             end
           end)

    assert :ok =
             DynamicSupervisor.terminate_child(
               SalixIM.ConversationFleetSup,
               participant_owner
             )

    assert Process.alive?(conversation_owner)
    assert Task.yield(response_task, 300) == nil

    assert {:ok, %{"inserted" => true}} =
             SalixIM.ConversationServer.append_group_conversation_message(
               group_id,
               conversation_id,
               %{
                 "actor_type" => "user",
                 "user_id" => user["id"],
                 "participant_id" => user_participant["participant_id"],
                 "client_request_id" => "participant-owner-sse-message",
                 "content" => "Canonical messages remain available"
               }
             )

    response = Task.await(response_task, 2_000) |> expect_status(200)
    participant_statuses = sse_payloads(response.body, "participant_status")

    participant_status_cleared =
      sse_payloads(response.body, "participant_status_cleared")

    draft_started = sse_payloads(response.body, "message_draft_started")
    draft_cancelled = sse_payloads(response.body, "message_draft_cancelled")
    invalidations = sse_payloads(response.body, "conversation_invalidated")

    assert Enum.any?(participant_statuses, fn status ->
             status["state"] == "active" and status["status"] == "is thinking..."
           end)

    refute Enum.any?(participant_statuses, &(&1["state"] == "stopped"))

    assert [
             %{
               "conversation_id" => ^conversation_id,
               "participant_id" => ^router_participant_id,
               "reason" => "owner_unavailable"
             }
           ] = participant_status_cleared

    assert [%{"text" => "Transient participant draft", "draft_id" => draft_id}] =
             draft_started

    assert [%{"draft_id" => ^draft_id}] = draft_cancelled
    assert [%{"conversation_id" => ^conversation_id}] = invalidations
  end

  test "conversation send exposes an actionable insufficient-credit reason" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "no-credits@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    conversation = active_chat!(session, workspace)

    response =
      user_req(
        session["token"],
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages",
        json: %{
          "client_request_id" => "no-credits",
          "message" => %{"content" => "hello"}
        }
      )
      |> expect_status(402)
      |> Map.fetch!(:body)

    assert response == %{
             "error" => "billing_unavailable",
             "reason" => "insufficient_credits"
           }
  end

  test "assistant-chat is the Group fixed Router Conversation and sends through its input adapter" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "fixed-router-chat@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    assert {:ok, group} =
             Salix.Control.Groups.get(
               workspace["default_group_id"],
               workspace["salix_tenant_id"]
             )

    router_conversation_id = group["router_conversation_id"]
    group_id = workspace["default_group_id"]
    path = "/v1/comma/groups/#{group_id}/assistant-chat"

    first =
      user_req(session["token"], :post, path, json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    second =
      user_req(session["token"], :post, path, json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert first["id"] == router_conversation_id
    assert first["group_id"] == group_id
    assert first["status"] == "active"
    assert second["id"] == router_conversation_id

    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(
               workspace["default_group_id"],
               limit: 100
             )

    assert conversations
           |> Enum.filter(&(&1["kind"] == "user_chat"))
           |> Enum.map(& &1["conversation_id"]) == [router_conversation_id]

    user_req(
      session["token"],
      :post,
      "/v1/comma/groups/#{group_id}/conversations/#{router_conversation_id}/messages",
      json: %{
        "client_request_id" => "fixed-router-message",
        "message" => %{"content" => "Use the fixed Router conversation"}
      }
    )
    |> expect_status(202)

    assert {:ok, messages} =
             SalixIM.RouterConversationProjection.list_group_router_messages(
               workspace["default_group_id"]
             )

    assert %{
             "client_request_id" => "fixed-router-message",
             "metadata" => %{"source" => "group_router"}
           } = List.last(messages)

    assert {:ok, unrelated_chat} =
             SalixIM.ConversationInput.create_group_conversation(
               workspace["default_group_id"],
               %{"kind" => "user_chat", "title" => "Not the fixed Router conversation"}
             )

    user_req(
      session["token"],
      :get,
      "/v1/comma/groups/#{group_id}/conversations/#{unrelated_chat["conversation_id"]}"
    )
    |> expect_status(404)
  end

  test "workspace Compute API exposes stable intent without provider identity" do
    suffix = System.unique_integer([:positive])

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "compute-#{suffix}@example.com"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Compute Workspace"})

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert {:ok, pool} =
             SalixStore.Compute.ensure_managed_default_pool(
               workspace["salix_tenant_id"],
               "cloudflare"
             )

    assert {:ok, _binding} =
             SalixStore.Compute.create_provider_binding(%{
               id: "binding_comma_api_#{suffix}",
               pool_id: pool.id,
               provider: "cloudflare",
               provider_ref: "provider-private-#{suffix}"
             })

    environment =
      user_req(
        session["token"],
        :post,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/environments",
        json: %{}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    placed =
      user_req(
        session["token"],
        :post,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/workloads",
        json: %{
          "environment_id" => environment["id"],
          "request_id" => "compute-request-#{suffix}",
          "kind" => "external_worker",
          "capability_requirements" => ["runtime_exec"]
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    repeated =
      user_req(
        session["token"],
        :post,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/workloads",
        json: %{
          "request_id" => "compute-request-#{suffix}",
          "environment_id" => environment["id"],
          "kind" => "external_worker",
          "capability_requirements" => ["runtime_exec"]
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert repeated["workload"]["id"] == placed["workload"]["id"]
    assert repeated["allocation"]["id"] == placed["allocation"]["id"]

    recovered =
      user_req(
        session["token"],
        :get,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/requests/compute-request-#{suffix}"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert recovered["workload"]["id"] == placed["workload"]["id"]

    user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/compute/workloads",
      json: %{
        "request_id" => "compute-request-#{suffix}",
        "environment_id" => environment["id"],
        "kind" => "external_worker",
        "spec" => %{"changed" => true}
      }
    )
    |> expect_status(409)

    grant =
      user_req(
        session["token"],
        :post,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/grants",
        json: %{
          "environment_id" => environment["id"],
          "workload_id" => placed["workload"]["id"],
          "principal_type" => "agent",
          "principal_id" => workspace["default_worker_agent_id"],
          "permissions" => ["runtime"]
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    projection =
      user_req(
        session["token"],
        :get,
        "/v1/comma/workspaces/#{workspace["id"]}/compute"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"id" => environment_id}] = projection["environments"]
    assert environment_id == environment["id"]
    assert environment["pool_id"] == pool.id
    assert [%{"id" => workload_id}] = projection["workloads"]
    assert workload_id == placed["workload"]["id"]
    assert [%{"id" => grant_id}] = projection["grants"]
    assert grant_id == grant["id"]

    public_wire = Jason.encode!(projection)
    refute public_wire =~ "sprites"
    refute public_wire =~ "provider-private"
    refute public_wire =~ "provider_binding"

    retained =
      user_req(
        session["token"],
        :put,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/environments/#{environment["id"]}/retention",
        json: %{"expected_revision" => 1, "mode" => "release_on_stop"}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert retained["retention"] == %{"mode" => "release_on_stop"}

    drained =
      user_req(
        session["token"],
        :post,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/environments/#{environment["id"]}/drain",
        json: %{"expected_revision" => retained["revision"]}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert drained["desired_state"] == "draining"

    revoked =
      user_req(
        session["token"],
        :post,
        "/v1/comma/workspaces/#{workspace["id"]}/compute/environments/#{environment["id"]}/revoke",
        json: %{"expected_revision" => drained["revision"]}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert revoked["desired_state"] == "revoked"
  end

  test "workspace owner lists, installs, and uninstalls product plugins" do
    previous_settings = Application.get_env(:salix_web, :composio_settings_mod)
    previous_client = Application.get_env(:salix_web, :composio_client_mod)
    Application.put_env(:salix_web, :composio_settings_mod, PluginInstallComposio)
    Application.put_env(:salix_web, :composio_client_mod, PluginInstallComposio)
    Application.put_env(:comma_web, :comma_api_plugin_install_accounts, [])

    on_exit(fn ->
      restore_env(:salix_web, :composio_settings_mod, previous_settings)
      restore_env(:salix_web, :composio_client_mod, previous_client)
      Application.delete_env(:comma_web, :comma_api_plugin_install_accounts)
    end)

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "plugins@example.com", "name" => "Plugin Owner"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Plugin Workspace"})

    assert {:ok, alias_fixture} =
             Salix.Control.Plugins.create_definition(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               %{
                 "name" => "MCP alias precedence fixture",
                 "refs" => %{
                   "mcp_refs" => [
                     %{
                       "mcp_id" => "mcp1_ref_name",
                       "name" => "Explicit ref name",
                       "alias" => "ignored-ref-alias"
                     },
                     %{"mcp_id" => "mcp1_ref_alias", "alias" => "Explicit ref alias"},
                     %{"mcp_id" => "mcp1_setup_name"},
                     "mcp1_binary_setup_alias"
                   ]
                 },
                 "setup" => %{
                   "mcps" => [
                     %{
                       "mcp_id" => "mcp1_ref_name",
                       "name" => "ignored-setup-name",
                       "alias" => "ignored-setup-alias"
                     },
                     %{
                       "mcp_id" => "mcp1_ref_alias",
                       "name" => "ignored-setup-name",
                       "alias" => "ignored-setup-alias"
                     },
                     %{
                       "mcp_id" => "mcp1_setup_name",
                       "name" => "Setup name",
                       "alias" => "ignored-setup-alias"
                     },
                     %{
                       "mcp_id" => "mcp1_binary_setup_alias",
                       "alias" => "Binary setup alias"
                     }
                   ]
                 }
               }
             )

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    path = "/v1/comma/workspaces/#{workspace["id"]}/plugins"

    assert :ok =
             Salix.Control.PluginCatalogCache.invalidate_group(workspace["default_group_id"])

    SalixStore.S3.Fake.reset_read_log()

    plugins =
      user_req(session["token"], :get, path)
      |> expect_status(200)
      |> Map.fetch!(:body)
      |> Map.fetch!("data")

    catalog_reads = SalixStore.S3.Fake.read_log()

    group_definition_prefix =
      SalixStore.Keys.ctl_group_plugin_definitions_prefix(
        workspace["salix_tenant_id"],
        workspace["default_group_id"]
      )

    assert Enum.any?(catalog_reads, fn
             {:list, ^group_definition_prefix, _opts} -> true
             _other -> false
           end)

    forbidden_child_prefixes = [
      SalixStore.Keys.ctl_oauth_group_bindings_prefix(workspace["default_group_id"]),
      "ctl/oauth/connections/",
      SalixStore.Keys.ctl_mcp_group_bindings_prefix(
        workspace["salix_tenant_id"],
        workspace["default_group_id"]
      ),
      SalixStore.Keys.ctl_im_connects_prefix(workspace["default_group_id"])
    ]

    refute Enum.any?(catalog_reads, fn
             {:list, prefix, _opts} ->
               Enum.any?(forbidden_child_prefixes, fn forbidden ->
                 String.starts_with?(prefix, forbidden) or
                   String.starts_with?(forbidden, prefix)
               end)

             {operation, key} when operation in [:get, :head] ->
               Enum.any?(forbidden_child_prefixes, &String.starts_with?(key, &1))

             _other ->
               false
           end)

    assert %{"installed" => false} = Enum.find(plugins, &(&1["id"] == "github"))
    refute Enum.any?(plugins, &(&1["id"] == "core-runtime"))

    assert %{"installed" => false, "category" => "Integrations"} =
             Enum.find(plugins, &(&1["id"] == "slack"))

    assert %{
             "mcps" => [
               %{
                 "id" => "mcp1_0000000000000000006",
                 "name" => "google-workspace"
               }
             ]
           } = Enum.find(plugins, &(&1["id"] == "google"))

    assert %{
             "mcps" => [
               %{"id" => "mcp1_ref_name", "name" => "Explicit ref name"},
               %{"id" => "mcp1_ref_alias", "name" => "Explicit ref alias"},
               %{"id" => "mcp1_setup_name", "name" => "Setup name"},
               %{"id" => "mcp1_binary_setup_alias", "name" => "Binary setup alias"}
             ]
           } = Enum.find(plugins, &(&1["id"] == alias_fixture["plugin_id"]))

    user_req(session["token"], :post, path <> "/agent-collaboration/install", json: %{})
    |> expect_status(404)

    {:ok, composio_fixture} =
      Salix.Control.Plugins.create_definition(
        workspace["salix_tenant_id"],
        workspace["default_group_id"],
        %{
          "name" => "Test messaging",
          "owner_scope" => "group",
          "setup" => %{
            "type" => "integration",
            "default_connection" => "slack-composio",
            "connections" => [
              %{
                "id" => "slack-composio",
                "kind" => "composio",
                "label" => "Slack via Composio",
                "toolkit" => "slack"
              }
            ]
          }
        }
      )

    plugin_id = composio_fixture["plugin_id"]

    # A legacy enablement without Comma's completed-install evidence must not be
    # presented as installed after the Connect concept is removed.
    assert {:ok, _enablement} =
             SalixAgent.PluginStore.enable_group(
               workspace["salix_tenant_id"],
               workspace["default_group_id"],
               plugin_id
             )

    legacy_plugins =
      user_req(session["token"], :get, path)
      |> expect_status(200)
      |> Map.fetch!(:body)
      |> Map.fetch!("data")

    assert Enum.find(legacy_plugins, &(&1["id"] == plugin_id))["installed"] == false

    # Old clients omit the unified contract marker and still receive the plain
    # plugin shape plus their compatibility-only authorize endpoint.
    legacy_install =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install", json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert legacy_install["id"] == plugin_id
    assert legacy_install["installed"] == true
    refute Map.has_key?(legacy_install, "plugin")

    legacy_authorization =
      user_req(session["token"], :post, path <> "/#{plugin_id}/authorize", json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert legacy_authorization["authorizationUrl"] =~ "/slack"

    user_req(session["token"], :delete, path <> "/#{plugin_id}")
    |> expect_status(200)

    pending_install =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install",
        json: %{"contract" => "unified_v1"}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert pending_install["plugin"]["id"] == plugin_id
    assert pending_install["plugin"]["installed"] == false
    assert pending_install["authorization"]["authorizationUrl"] =~ "/slack"

    plugins_after_pending =
      user_req(session["token"], :get, path)
      |> expect_status(200)
      |> Map.fetch!(:body)
      |> Map.fetch!("data")

    assert Enum.find(plugins_after_pending, &(&1["id"] == plugin_id))["installed"] == false

    cancelled_install =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install",
        json: %{
          "authorization_state" => pending_install["authorization"]["state"],
          "contract" => "unified_v1",
          "verify_only" => true
        }
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert cancelled_install["plugin"]["installed"] == false
    assert cancelled_install["authorization"] == nil

    restarted_install =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install",
        json: %{"contract" => "unified_v1"}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert restarted_install["plugin"]["installed"] == false
    assert restarted_install["authorization"]["authorizationUrl"] =~ "/slack"

    Application.put_env(:comma_web, :comma_api_plugin_install_accounts, [
      %{
        "id" => "ca_#{workspace["default_group_id"]}_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    installed =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install",
        json: %{
          "authorization_state" => restarted_install["authorization"]["state"],
          "contract" => "unified_v1",
          "verify_only" => true
        }
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert installed["plugin"]["id"] == plugin_id
    assert installed["plugin"]["installed"] == true
    assert installed["authorization"] == nil

    uninstalled =
      user_req(session["token"], :delete, path <> "/#{plugin_id}")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert uninstalled["id"] == plugin_id
    assert uninstalled["installed"] == false

    Application.put_env(:comma_web, :comma_api_plugin_install_accounts, [
      %{
        "id" => "ca_#{workspace["default_group_id"]}_slack",
        "user_id" => workspace["default_group_id"],
        "toolkit" => %{"slug" => "slack"},
        "status" => "ACTIVE"
      }
    ])

    delayed_verification =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install",
        json: %{
          "authorization_state" => restarted_install["authorization"]["state"],
          "contract" => "unified_v1",
          "verify_only" => true
        }
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert delayed_verification["plugin"]["installed"] == false
    assert delayed_verification["authorization"] == nil

    reinstallation =
      user_req(session["token"], :post, path <> "/#{plugin_id}/install",
        json: %{"contract" => "unified_v1"}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert reinstallation["plugin"]["installed"] == false
    assert reinstallation["authorization"]["authorizationUrl"] =~ "/slack"
  end

  test "the next Comma Chat send follows an explicitly reassigned Group Router" do
    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "router-reassignment@example.com", "name" => "Router Reassignment"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    chat = active_chat!(session, workspace)
    salix_conversation_id = chat["id"]
    router_a = workspace["router_agent_id"]
    group_id = workspace["default_group_id"]
    tenant_id = workspace["salix_tenant_id"]
    router_b = SalixStore.Ids.new_agent_id(group_id)

    assert {:ok, _router} =
             SalixAgent.Control.create_preallocated(
               %{
                 "group_id" => group_id,
                 "name" => "Explicitly reassigned Router",
                 "role" => "router",
                 "purpose" => "comma_router_reassignment_regression"
               },
               tenant_id,
               router_b
             )

    assert {:ok, stale_router_a} =
             SalixIM.ConversationInput.prepare_agent(
               group_id,
               salix_conversation_id,
               %{
                 "actor_type" => "agent",
                 "agent_id" => router_a,
                 "role_label" => "agent",
                 "state" => "active",
                 "notification_filter" => %{
                   "messages" => "all",
                   "statuses" => "none"
                 }
               }
             )

    assert {:ok, _group} =
             Salix.Control.Groups.update(
               group_id,
               %{"router_agent_id" => router_b},
               tenant_id
             )

    Mock.script(visible_reply_script(chat["id"], "reply from Router B", "router-b-reply"))

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{chat["id"]}/messages"

    responses =
      1..4
      |> Task.async_stream(
        fn _retry ->
          user_req(session["token"], :post, send_path,
            json: %{
              "client_request_id" => "send-after-explicit-router-reassignment",
              "message" => %{"content" => "continue with the reassigned Router"}
            }
          )
          |> expect_status(202)
          |> Map.fetch!(:body)
        end,
        max_concurrency: 4,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, response} -> response end)

    assert [chat["id"]] == responses |> Enum.map(& &1["id"]) |> Enum.uniq()

    final =
      eventually(fn ->
        body =
          user_req(
            session["token"],
            :get,
            "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{chat["id"]}"
          )
          |> expect_status(200)
          |> Map.fetch!(:body)

        if Enum.any?(body["messages"], &(salix_message_text(&1) == "reply from Router B")),
          do: body
      end)

    assert final["id"] == chat["id"]

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               salix_conversation_id,
               limit: 50
             )

    assert Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_a and
               participant["state"] == "inactive"
           end)

    assert Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_b and
               participant["state"] == "active"
           end)

    assert {:error, :stale_group_router_authority} =
             SalixIM.ConversationServer.reconcile_group_conversation_agent_participants(
               group_id,
               salix_conversation_id,
               %{
                 "desired" => stale_router_a,
                 "selector" => %{
                   "actor_type" => "agent",
                   "role_label" => ["agent", "router"]
                 },
                 "authority_guard" => %{
                   "type" => "group_router",
                   "router_agent_id" => router_a
                 }
               }
             )

    assert {:ok, %{"participants" => participants_after_stale_write}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               salix_conversation_id,
               limit: 50
             )

    assert Enum.any?(participants_after_stale_write, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_a and
               participant["state"] == "inactive"
           end)

    assert Enum.any?(participants_after_stale_write, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_b and
               participant["state"] == "active"
           end)

    router_b_participant =
      Enum.find(participants, fn participant ->
        participant["actor_type"] == "agent" and participant["agent_id"] == router_b and
          participant["state"] == "active"
      end)

    router_b_session_id = get_in(router_b_participant, ["payload", "session_id"])

    assert {:ok, router_b_session} =
             SalixAgent.InternalSessionStore.read(router_b, router_b_session_id)

    assert Enum.any?(
             SalixAgent.InternalSession.get(router_b_session, :messages),
             &String.contains?(&1.content, "continue with the reassigned Router")
           )

    assert {:ok, salix_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               salix_conversation_id,
               limit: 100
             )

    assert Enum.count(
             salix_messages,
             &(salix_message_text(&1) == "continue with the reassigned Router")
           ) == 1

    assert {:ok, _participant} =
             SalixIM.ConversationServer.reconcile_group_conversation_agent_participants(
               group_id,
               salix_conversation_id,
               %{
                 "desired" => stale_router_a,
                 "selector" => %{
                   "actor_type" => "agent",
                   "role_label" => ["agent", "router"]
                 }
               }
             )

    assert {:ok,
            %{
              conversation_id: ^salix_conversation_id,
              participant_id: current_router_participant_id
            }} =
             CommaWeb.SalixClient.conversation_activity_context(workspace, salix_conversation_id)

    assert current_router_participant_id == router_b_participant["participant_id"]

    assert {:ok, %{"participants" => repaired_participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               salix_conversation_id,
               limit: 50
             )

    assert Enum.any?(repaired_participants, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_a and
               participant["state"] == "inactive"
           end)

    assert Enum.any?(repaired_participants, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_b and
               participant["participant_id"] == current_router_participant_id and
               participant["state"] == "active"
           end)
  end

  test "the next Comma Chat send fails closed before append when current Group Router is archived" do
    request = "do not append through an archived Router"

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "archived-router-send@example.com", "name" => "Archived Router Send"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    chat = active_chat!(session, workspace)
    salix_conversation_id = chat["id"]
    group_id = workspace["default_group_id"]
    router_id = workspace["router_agent_id"]

    assert {:ok, archived_router} = SalixAgent.Control.delete(router_id)
    assert is_integer(archived_router["archived_at"])

    path = "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{chat["id"]}/messages"

    failed =
      user_req(session["token"], :post, path,
        json: %{
          "client_request_id" => "send-after-router-archive",
          "message" => %{"content" => request}
        }
      )
      |> expect_status(503)

    assert failed.body["error"] == "conversation_unavailable"

    assert {:ok, salix_messages} =
             SalixIM.Conversations.list_group_conversation_messages(
               group_id,
               salix_conversation_id,
               limit: 100
             )

    refute Enum.any?(salix_messages, &(salix_message_text(&1) == request))
    assert_no_agent_task_for(group_id, 500)

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               group_id,
               salix_conversation_id,
               limit: 50
             )

    assert Enum.any?(participants, fn participant ->
             participant["actor_type"] == "agent" and participant["agent_id"] == router_id and
               participant["state"] == "active"
           end)
  end

  @tag :chat_input_reliability
  test "a failed append retries once through the canonical participant despite inactive history" do
    run_id = "chat-input-retry-#{System.unique_integer([:positive])}"
    request = "Build me a small personal website."

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "#{run_id}@example.com", "name" => "Chat Input Retry"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    chat = active_chat!(session, workspace)
    chat_salix_id = chat["id"]

    assert {:ok, ensured_user_participant} =
             CommaWeb.SalixClient.ensure_group_conversation_user_participant(
               workspace,
               chat_salix_id,
               user["id"]
             )

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               workspace["default_group_id"],
               chat_salix_id
             )

    canonical =
      Enum.find(participants, fn participant ->
        participant["actor_type"] == "user" and participant["user_id"] == user["id"] and
          participant["state"] == "active"
      end)

    canonical_id = canonical["participant_id"]
    assert ensured_user_participant["participant_id"] == canonical_id
    identity_key = Jason.encode!(["user", canonical["user_id"]])

    assert {:ok, %{"_participant_identity_slots" => identity_slots}} =
             SalixStore.CasRecord.get(
               SalixStore.Keys.ctl_group_conversation(
                 workspace["default_group_id"],
                 chat_salix_id
               )
             )

    assert identity_slots[identity_key] == canonical_id

    legacy_id = SalixStore.Ids.new_participant_id()
    now = System.system_time(:millisecond)

    inactive_legacy =
      canonical
      |> Map.put("participant_id", legacy_id)
      |> Map.put("state", "inactive")
      |> Map.put("created_at", now)
      |> Map.put("updated_at", now)

    assert {:ok, _stored} =
             SalixStore.S3.put(
               SalixStore.Keys.ctl_group_conversation_participant_state(
                 workspace["default_group_id"],
                 chat_salix_id,
                 legacy_id
               ),
               Jason.encode!(inactive_legacy),
               if_none_match: "*"
             )

    assert {:ok, chat_owner} =
             SalixIM.ConversationPlacement.ensure_started(
               workspace["default_group_id"],
               chat_salix_id
             )

    :ok = GenServer.stop(chat_owner, :normal)
    Mock.script(task_create_script(workspace, run_id))

    path = "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{chat["id"]}/messages"

    body = %{
      "client_request_id" => run_id,
      "message" => %{"content" => request}
    }

    first_segment_key =
      SalixStore.Keys.ctl_group_conversation_message_segment(
        workspace["default_group_id"],
        chat_salix_id,
        "000000000000000001"
      )

    :ok = SalixStore.S3.Fake.set_fault({:fail, 503, :put, first_segment_key})

    failed = user_req(session["token"], :post, path, json: body) |> expect_status(503)
    assert failed.body["error"] == "conversation_unavailable"
    assert :sys.get_state(SalixStore.S3.Fake).faults == []

    assert {:ok, messages_after_failure} =
             SalixIM.Conversations.list_group_conversation_messages(
               workspace["default_group_id"],
               chat_salix_id,
               limit: 100
             )

    refute Enum.any?(messages_after_failure, &(salix_message_text(&1) == request))

    assert_no_agent_task_for(workspace["default_group_id"], 500)

    first = user_req(session["token"], :post, path, json: body) |> expect_status(202)
    retry = user_req(session["token"], :post, path, json: body) |> expect_status(202)

    assert Enum.count(first.body["messages"], &(&1["actor_type"] == "user")) == 1
    assert Enum.count(retry.body["messages"], &(&1["actor_type"] == "user")) == 1

    committed =
      eventually(fn ->
        with {:ok, messages} <-
               SalixIM.Conversations.list_group_conversation_messages(
                 workspace["default_group_id"],
                 chat_salix_id,
                 limit: 100
               ),
             [_message] = selected <-
               Enum.filter(messages, &(salix_message_text(&1) == request)) do
          selected
        else
          _ -> nil
        end
      end)

    assert length(committed) == 1

    tasks =
      eventually(fn ->
        with {:ok, %{"data" => conversations}} <-
               SalixIM.Conversations.list_group_conversations(
                 workspace["default_group_id"],
                 limit: 100
               ),
             [task] <- Enum.filter(conversations, &(&1["kind"] == "agent_task")) do
          [task]
        else
          _ -> nil
        end
      end)

    assert length(tasks) == 1
  end

  @tag :chat_input_reliability

  @tag :chat_input_reliability
  test "an active duplicate participant rejects Chat before message or Task creation" do
    run_id = "ambiguous-participant-#{System.unique_integer([:positive])}"
    request = "Build me a small personal website."

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "#{run_id}@example.com", "name" => "Ambiguous Participant"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    chat = active_chat!(session, workspace)
    chat_salix_id = chat["id"]

    assert {:ok, ensured_user_participant} =
             CommaWeb.SalixClient.ensure_group_conversation_user_participant(
               workspace,
               chat_salix_id,
               user["id"]
             )

    assert {:ok, %{"participants" => participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               workspace["default_group_id"],
               chat_salix_id
             )

    canonical =
      Enum.find(participants, fn participant ->
        participant["actor_type"] == "user" and participant["user_id"] == user["id"] and
          participant["state"] == "active"
      end)

    canonical_id = canonical["participant_id"]
    assert ensured_user_participant["participant_id"] == canonical_id
    identity_key = Jason.encode!(["user", canonical["user_id"]])

    assert {:ok, %{"_participant_identity_slots" => identity_slots}} =
             SalixStore.CasRecord.get(
               SalixStore.Keys.ctl_group_conversation(
                 workspace["default_group_id"],
                 chat_salix_id
               )
             )

    assert identity_slots[identity_key] == canonical_id

    duplicate_id = SalixStore.Ids.new_participant_id()
    now = System.system_time(:millisecond)

    inactive_duplicate =
      canonical
      |> Map.put("participant_id", duplicate_id)
      |> Map.put("state", "inactive")
      |> Map.put("created_at", now)
      |> Map.put("updated_at", now)

    assert {:ok, _stored} =
             SalixStore.S3.put(
               SalixStore.Keys.ctl_group_conversation_participant_state(
                 workspace["default_group_id"],
                 chat_salix_id,
                 duplicate_id
               ),
               Jason.encode!(inactive_duplicate),
               if_none_match: "*"
             )

    assert {:ok, duplicate_owner} =
             SalixIM.ConversationFleet.ensure_participant_started(
               workspace["default_group_id"],
               chat_salix_id,
               duplicate_id
             )

    assert {:ok, %{"state" => "active"}} =
             SalixIM.ConversationParticipantActor.activate(duplicate_owner, %{
               "notification_filter" => %{"messages" => "none", "statuses" => "none"}
             })

    assert {:ok, %{"participants" => duplicated_participants}} =
             SalixIM.Conversations.list_group_conversation_participants(
               workspace["default_group_id"],
               chat_salix_id
             )

    assert Enum.count(duplicated_participants, fn participant ->
             participant["actor_type"] == "user" and
               participant["user_id"] == canonical["user_id"] and
               participant["state"] == "active"
           end) == 2

    assert {:ok, chat_owner} =
             SalixIM.ConversationPlacement.ensure_started(
               workspace["default_group_id"],
               chat_salix_id
             )

    :ok = GenServer.stop(chat_owner, :normal)
    Mock.script(task_create_script(workspace, run_id))

    assert {:error, {:bad_request, "user participant target is ambiguous"}} =
             CommaWeb.SalixClient.ensure_group_conversation_user_participant(
               workspace,
               chat_salix_id,
               user["id"]
             )

    response =
      user_req(
        session["token"],
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{chat["id"]}/messages",
        json: %{
          "client_request_id" => run_id,
          "message" => %{"content" => request}
        }
      )

    assert response.status == 503
    assert response.body["error"] == "conversation_unavailable"

    assert {:ok, messages_after_rejection} =
             SalixIM.Conversations.list_group_conversation_messages(
               workspace["default_group_id"],
               chat_salix_id,
               limit: 100
             )

    assert messages_after_rejection == []

    assert_no_agent_task_for(workspace["default_group_id"], 500)

    assert {:ok, %{"conversation_id" => ^chat_salix_id}} =
             SalixIM.Conversations.get_group_conversation(
               workspace["default_group_id"],
               chat_salix_id
             )
  end

  test "/v1 Chat read exposes only the Salix-derived public conversation contract" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "aggregate-contract@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Contract"})

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    conversation = active_chat!(session, workspace)

    detail_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"

    detail_response =
      user_req(
        session["token"],
        :get,
        detail_path
      )
      |> expect_status(200)

    body = Map.fetch!(detail_response, :body)
    etag = header(detail_response, "etag")

    assert body["id"] == conversation["id"]
    assert body["kind"] == "user_chat"
    assert body["group_id"] == workspace["default_group_id"]
    assert body["messages"] == []
    assert body["freshness"]["state"] == "fresh"
    assert is_binary(etag)

    user_req(session["token"], :get, detail_path, headers: [{"if-none-match", etag}])
    |> expect_status(304)

    for retired_or_internal <- [
          "internal",
          "snapshot_version",
          "last_event_id",
          "applied_operations",
          "message_index",
          "version"
        ] do
      refute Map.has_key?(body, retired_or_internal)
    end
  end

  test "public create endpoints reject Workspace creation and ignore caller supplied conversation ids" do
    unique = System.unique_integer([:positive])

    victim =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "victim-#{unique}@example.com", "name" => "Victim"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    victim_workspace =
      create_ready_workspace!(victim["id"], %{"name" => "Victim Workspace"})

    :ok = CommaWeb.TestConvergence.workspace!(victim_workspace["id"])

    {:ok, victim_conversation} =
      Comma.AssistantChats.ensure_chat(victim, %{}, victim_workspace["default_group_id"])

    attacker =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "attacker-#{unique}@example.com", "name" => "Attacker"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    attacker_session =
      admin_req(:post, "/v1/comma/admin/users/#{attacker["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    managed_creation =
      user_req(attacker_session["token"], :post, "/v1/comma/workspaces",
        json: %{
          "workspace_id" => victim_workspace["id"],
          "billing_account_id" => victim_workspace["billing_account_id"],
          "salix_tenant_id" => victim_workspace["salix_tenant_id"],
          "default_group_id" => victim_workspace["default_group_id"],
          "router_agent_id" => victim_workspace["router_agent_id"],
          "default_worker_agent_id" => victim_workspace["default_worker_agent_id"],
          "name" => "Attacker Workspace"
        }
      )
      |> expect_status(409)
      |> Map.fetch!(:body)

    assert managed_creation == %{"error" => "workspace_creation_managed"}

    attacker_workspace =
      create_ready_workspace!(attacker["id"], %{"name" => "Attacker Workspace"})

    refute attacker_workspace["id"] == victim_workspace["id"]
    refute attacker_workspace["billing_account_id"] == victim_workspace["billing_account_id"]
    refute attacker_workspace["salix_tenant_id"] == victim_workspace["salix_tenant_id"]
    refute attacker_workspace["default_group_id"] == victim_workspace["default_group_id"]
    refute attacker_workspace["router_agent_id"] == victim_workspace["router_agent_id"]

    refute attacker_workspace["default_worker_agent_id"] ==
             victim_workspace["default_worker_agent_id"]

    {:ok, stored_victim_workspace} = Comma.Workspaces.get(victim_workspace["id"])
    assert stored_victim_workspace["owner_user_id"] == victim["id"]

    assert billing_product_owner_id(victim_workspace["billing_account_id"]) ==
             victim_workspace["id"]

    attacker_conversation =
      active_chat!(attacker_session, attacker_workspace, %{
        "conversation_id" => victim_conversation["id"]
      })

    refute attacker_conversation["id"] == victim_conversation["id"]
    assert attacker_conversation["group_id"] == attacker_workspace["default_group_id"]

    assert user_req(
             attacker_session["token"],
             :get,
             "/v1/comma/groups/#{victim_workspace["default_group_id"]}/conversations/#{victim_conversation["id"]}"
           ).status == 404

    assert {:ok, %{"conversation_id" => victim_conversation_id}} =
             SalixIM.Conversations.get_group_conversation(
               victim_workspace["default_group_id"],
               victim_conversation["id"]
             )

    assert victim_conversation_id == victim_conversation["id"]
  end

  test "user can view billing plans, create checkout, open mapped portal, and read summary" do
    unique = System.unique_integer([:positive])

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "billing-user-#{unique}@example.com", "name" => "Billing User"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Billing"})

    issue_billing_grant(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    plans =
      user_req(session["token"], :get, "/v1/comma/billing/plans")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert Enum.any?(plans["data"], &(&1["plan_key"] == "comma_value_v1"))
    refute Enum.any?(plans["data"], &Map.has_key?(&1, "provider_price_id"))

    checkout =
      user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/billing/checkout",
        json: %{
          "plan_key" => "comma_value_v1",
          "success_url" => "https://comma.test/success",
          "cancel_url" => "https://comma.test/cancel",
          "client_request_id" => "checkout-1"
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert checkout["provider"] == "stripe"
    assert checkout["url"] =~ "checkout.stripe.test"
    refute Map.has_key?(checkout, "request")
    refute Jason.encode!(checkout) =~ "authorization"
    refute Jason.encode!(checkout) =~ "secret"

    [{:customer, customer_params, customer_opts}, {:checkout, checkout_params, _checkout_opts}] =
      stripe_calls()

    assert customer_params.email == "billing-user-#{unique}@example.com"
    assert customer_params.metadata["billing_account_id"] == workspace["billing_account_id"]
    assert customer_opts[:idempotency_key] == "comma:customer:#{workspace["id"]}"
    assert checkout_params.customer =~ "cus_"

    retry_checkout =
      user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/billing/checkout",
        json: %{
          "plan_key" => "comma_value_v1",
          "success_url" => "https://comma.test/success",
          "cancel_url" => "https://comma.test/cancel",
          "client_request_id" => "checkout-2"
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert retry_checkout["provider"] == "stripe"

    assert [
             {:customer, _customer_params, _customer_opts},
             {:checkout, _checkout_params, _checkout_opts},
             {:checkout, retry_checkout_params, _retry_checkout_opts}
           ] = stripe_calls()

    assert retry_checkout_params.customer == checkout_params.customer

    user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/billing/checkout",
      json: %{
        "provider_price_id" => "price_comma_value_v1",
        "success_url" => "https://comma.test/success",
        "cancel_url" => "https://comma.test/cancel",
        "client_request_id" => "checkout-provider-price-id"
      }
    )
    |> expect_status(400)

    portal =
      user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/billing/portal",
        json: %{
          "customer_id" => "cus_attacker",
          "return_url" => "https://comma.test/billing",
          "client_request_id" => "portal-1"
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert portal["provider"] == "stripe"
    assert portal["url"] =~ "billing.stripe.test"

    {:portal, portal_params, _portal_opts} = List.last(stripe_calls())
    assert portal_params.customer == checkout_params.customer
    refute portal_params.customer == "cus_attacker"

    summary =
      user_req(session["token"], :get, "/v1/comma/workspaces/#{workspace["id"]}/billing/summary")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert summary["billing_account_id"] == workspace["billing_account_id"]
    assert summary["current_credits"] >= 100
    assert [%{"remaining_credits" => 100} | _] = summary["active_grants"]
  end

  test "workspace member can redeem a code without choosing the billing target" do
    seed_redeem_package()
    unique = System.unique_integer([:positive])

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "self-redeem-#{unique}@example.com", "name" => "Self Redeem"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "Self Redeem"})

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    raw_code = "comma-self-redeem-#{unique}"

    {:ok, created} =
      BillingCommerce.create_redeem_code(%{
        "code" => raw_code,
        "package_code" => "comma_api_redeem_once",
        "package_version" => "2026-06",
        "code_type" => "one_time_package",
        "surface" => "comma",
        "max_redemptions" => 1,
        "per_account_limit" => 1,
        "valid_from" => "2026-06-01T00:00:00Z"
      })

    redeemed =
      user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/billing/redeem",
        json: %{
          "code" => created.code,
          "client_request_id" => "self-redeem-#{unique}"
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert redeemed["redemption"]["billing_account_id"] == workspace["billing_account_id"]
    assert redeemed["redemption"]["product_owner_id"] == workspace["id"]
    assert redeemed["grant"]["remaining_credits"] == 700
  end

  test "billing portal returns 409 before any Stripe customer is linked" do
    unique = System.unique_integer([:positive])

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "no-customer-#{unique}@example.com", "name" => "No Customer"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"], %{"name" => "No Customer"})

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    portal_error =
      user_req(session["token"], :post, "/v1/comma/workspaces/#{workspace["id"]}/billing/portal",
        json: %{
          "customer_id" => "cus_attacker",
          "return_url" => "https://comma.test/billing",
          "client_request_id" => "portal-before-checkout"
        }
      )
      |> expect_status(409)
      |> Map.fetch!(:body)

    assert portal_error["error"] == "stripe_customer_not_linked"
    assert stripe_calls() == []
  end

  test "public Stripe webhook route uses the raw provider payload to grant top-up credits" do
    seed_stripe_package()

    unique = System.unique_integer([:positive])
    account_id = "comma-ba-wsp-webhook-api-#{unique}"
    owner_id = "wsp-webhook-api-#{unique}"

    payload =
      Jason.encode!(%{
        "id" => "evt_comma_web_checkout_#{unique}",
        "type" => "checkout.session.completed",
        "data" => %{
          "object" => %{
            "id" => "cs_comma_web_#{unique}",
            "mode" => "payment",
            "payment_status" => "paid",
            "payment_intent" => "pi_comma_web_#{unique}",
            "metadata" => %{
              "billing_account_id" => account_id,
              "surface" => "comma",
              "product_owner_type" => "workspace",
              "product_owner_id" => owner_id,
              "package_code" => "comma_api_topup_once",
              "package_version" => "2026-06",
              "period_start" => "1780272000",
              "period_end" => "1782864000"
            }
          }
        }
      })

    webhook =
      Req.request!(
        method: :post,
        url: base() <> "/v1/comma/billing/stripe/webhook",
        headers: [{"content-type", "application/json"}, {"stripe-signature", "t=1,v1=ok"}],
        body: payload
      )
      |> expect_status(200)

    assert webhook.body == %{"received" => true}
    assert grant_count(account_id) == 1

    rejected =
      Req.request!(
        method: :post,
        url: base() <> "/v1/comma/billing/stripe/webhook",
        headers: [{"content-type", "application/json"}, {"stripe-signature", "t=1,v1=bad"}],
        body: payload
      )
      |> expect_status(400)

    assert rejected.body["error"] == "invalid_signature"
  end

  test "admin billing redeem API creates, audits, disables, and applies without listing plaintext codes" do
    seed_redeem_package()

    packages =
      admin_req(:get, "/v1/comma/admin/billing/package-versions", json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert %{
             "package_code" => "comma_api_redeem_once",
             "package_name" => "Comma API Redeem Once",
             "version" => "2026-06",
             "grant_credits" => 700,
             "status" => "active"
           } = Enum.find(packages["data"], &(&1["package_code"] == "comma_api_redeem_once"))

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "redeem-api@example.com", "name" => "Redeem API"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    unique = System.unique_integer([:positive])

    workspace = create_ready_workspace!(user["id"], %{"name" => "Redeem"})

    raw_code = "cma-api-redeem-#{unique}"

    created =
      admin_req(:post, "/v1/comma/admin/billing/redeem-codes",
        json: %{
          "code" => raw_code,
          "package_code" => "comma_api_redeem_once",
          "package_version" => "2026-06",
          "code_type" => "one_time_package",
          "surface" => "comma",
          "max_redemptions" => 1,
          "valid_from" => "2026-06-01T00:00:00Z",
          "metadata" => %{"campaign" => "ops"}
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert created["code"] == String.upcase(raw_code)
    assert created["display_prefix"] == "CMA-API-"
    refute Map.has_key?(created, "code_hash")

    listed =
      admin_req(:get, "/v1/comma/admin/billing/redeem-codes", json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    listed_code = Enum.find(listed["data"], &(&1["id"] == created["id"]))
    assert listed_code["display_prefix"] == "CMA-API-"
    refute Map.has_key?(listed_code, "code")
    refute Map.has_key?(listed_code, "code_hash")

    applied =
      admin_req(:post, "/v1/comma/admin/billing/redeem-codes/apply",
        json: %{
          "code" => created["code"],
          "billing_account_id" => workspace["billing_account_id"],
          "surface" => "comma",
          "product_owner_type" => "workspace",
          "product_owner_id" => workspace["id"],
          "idempotency_key" => "redeem-api-#{unique}-1",
          "at" => "2026-06-15T00:00:00Z",
          "operator" => %{"id" => "ops-api", "reason" => "customer credit"}
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    assert applied["redemption"]["redeem_code_id"] == created["id"]
    assert applied["redemption"]["billing_account_id"] == workspace["billing_account_id"]
    assert applied["redemption"]["source_type"] == "redeem_one_time"
    assert applied["grant"]["remaining_credits"] == 700

    duplicate =
      admin_req(:post, "/v1/comma/admin/billing/redeem-codes/apply",
        json: %{
          "code" => created["code"],
          "billing_account_id" => workspace["billing_account_id"],
          "surface" => "comma",
          "product_owner_type" => "workspace",
          "product_owner_id" => workspace["id"],
          "idempotency_key" => "redeem-api-#{unique}-2",
          "at" => "2026-06-15T00:00:00Z",
          "operator" => %{"id" => "ops-api", "reason" => "customer credit"}
        }
      )
      |> expect_status(409)
      |> Map.fetch!(:body)

    assert duplicate["error"] == "redeem_code_account_limit_reached"

    redemptions =
      admin_req(:get, "/v1/comma/admin/billing/redemptions?redeem_code_id=#{created["id"]}", json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"status" => "applied", "operator_snapshot" => %{"id" => "ops-api"}}] =
             redemptions["data"]

    disabled =
      admin_req(:post, "/v1/comma/admin/billing/redeem-codes/#{created["id"]}/disable", json: %{})
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert disabled["status"] == "disabled"
    refute Map.has_key?(disabled, "code")
    refute Map.has_key?(disabled, "code_hash")
  end

  test "business conversation API rejects missing, out-of-scope, over-budget, and disallowed-tool sessions" do
    user = admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "grant@example.com"}).body
    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)

    assert {:ok, other_user} = Comma.Accounts.create_user(%{"email" => "grant-other@example.com"})
    other = create_ready_workspace!(other_user["id"], %{"name" => "Other"})

    open_session = admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{}).body

    conversation = active_chat!(open_session, workspace)

    no_auth =
      Req.request!(
        method: :get,
        url:
          base() <>
            "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
      )

    assert no_auth.status == 401

    assert {:ok, expired} =
             Comma.Accounts.create_session(user["id"],
               session_source: "ops_api",
               ttl_seconds: -1
             )

    assert user_req(expired["token"], :get, "/v1/comma/workspaces").status == 401

    grant =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => workspace["default_group_id"],
          "conversation_id" => conversation["id"],
          "budget" => 1,
          "tool_allowlist" => ["echo"],
          "restricted" => true
        }
      ).body

    token = grant["token"]

    out_of_scope =
      user_req(token, :post, "/v1/comma/groups/#{other["default_group_id"]}/assistant-chat", json: %{})

    assert out_of_scope.status == 403

    scoped_workspaces =
      user_req(token, :get, "/v1/comma/workspaces")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert Enum.map(scoped_workspaces["data"], & &1["id"]) == [workspace["id"]]
    assert user_req(token, :post, "/v1/comma/workspaces", json: %{"name" => "Escalate"}).status == 403

    conversation_only =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => workspace["default_group_id"],
          "conversation_id" => conversation["id"],
          "restricted" => true
        }
      ).body

    conversation_only_workspaces =
      user_req(conversation_only["token"], :get, "/v1/comma/workspaces")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert Enum.map(conversation_only_workspaces["data"], & &1["id"]) == [workspace["id"]]

    assert user_req(conversation_only["token"], :get, "/v1/comma/workspaces/#{other["id"]}").status ==
             403

    disallowed_tool =
      user_req(
        token,
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages",
        json: %{
          "client_request_id" => "bad-tool",
          "requested_tools" => ["shell"],
          "message" => %{"content" => "x"}
        }
      )

    assert disallowed_tool.status == 403

    undeclared_tool =
      user_req(
        token,
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages",
        json: %{
          "client_request_id" => "undeclared-tool",
          "message" => %{"content" => "x"}
        }
      )

    assert undeclared_tool.status == 403

    assert user_req(
             token,
             :post,
             "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat",
             json: %{}
           ).status == 403

    scoped_list =
      user_req(token, :get, "/v1/comma/groups/#{workspace["default_group_id"]}/conversations")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert Enum.map(scoped_list["data"], & &1["id"]) == [conversation["id"]]

    user_req(
      token,
      :get,
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
    )
    |> expect_status(200)

    Mock.script([{:final, "ok"}])

    assert 202 =
             user_req(
               token,
               :post,
               "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages",
               json: %{
                 "client_request_id" => "ok",
                 "requested_tools" => ["echo"],
                 "message" => %{"content" => "x"}
               }
             ).status

    assert 202 =
             user_req(
               token,
               :post,
               "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages",
               json: %{
                 "client_request_id" => "ok",
                 "requested_tools" => ["echo"],
                 "message" => %{"content" => "x"}
               }
             ).status

    exhausted =
      user_req(
        token,
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages",
        json: %{
          "client_request_id" => "over",
          "requested_tools" => ["echo"],
          "message" => %{"content" => "again"}
        }
      )

    assert exhausted.status == 402
  end

  test "a legacy conversation-restricted session remains exact during a rolling Group-scope deploy" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "legacy-group-scope@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    open_session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    conversation = active_chat!(open_session, workspace)

    assert {:ok, unrelated_conversation} =
             SalixIM.ConversationInput.create_group_conversation(
               workspace["default_group_id"],
               %{"kind" => "user_chat", "title" => "Outside the legacy grant"}
             )

    other_user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "legacy-other-group@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    other_workspace =
      create_ready_workspace!(other_user["id"], %{"name" => "Other legacy scope"})

    token = "comma_sess_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    Ecto.Adapters.SQL.query!(
      Comma.Repo,
      """
      INSERT INTO comma_auth_sessions (
        id, user_id, token_hash, auth_method, session_source,
        authenticated_at, expires_at, last_seen_at, user_auth_epoch,
        restricted, workspace_id, group_id, conversation_id,
        interaction_budget_remaining, tool_allowlist, consumed_interaction_ids,
        created_at, updated_at
      )
      SELECT
        $1::uuid, comma_users.id, $2::bytea, NULL, 'ops_api',
        now(), now() + interval '1 hour', now(), comma_users.auth_epoch,
        TRUE, $3, NULL, $4,
        NULL, '{}'::text[], '{}'::jsonb,
        now(), now()
      FROM comma_users
      WHERE comma_users.id = $5
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        :crypto.hash(:sha256, token),
        workspace["id"],
        conversation["id"],
        user["id"]
      ]
    )

    user_req(
      token,
      :get,
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
    )
    |> expect_status(200)

    assert user_req(
             token,
             :get,
             "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{unrelated_conversation["conversation_id"]}"
           ).status == 403

    assert user_req(
             token,
             :get,
             "/v1/comma/groups/#{other_workspace["default_group_id"]}/conversations"
           ).status == 403
  end

  @tag :task_archive
  test "Task archive API preserves empty filtered pages and restores the exact lifecycle" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "archive-api@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    token = session["token"]
    group = workspace["default_group_id"]
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    create = fn title ->
      {:ok, task} =
        SalixCluster.TaskSchedules.create_task_conversation(
          group,
          workspace["router_agent_id"],
          workspace["default_worker_agent_id"],
          %{"title" => title, "content" => title, "client_request_id" => "archive-api-#{title}"}
        )

      task["conversation_id"]
    end

    id = create.("first")

    {:ok, ready} =
      SalixIM.ConversationServer.update_group_conversation(group, id, %{"status" => "failed"})

    base = "/v1/comma/groups/#{group}/conversations"

    archived =
      user_req(token, :post, "#{base}/#{id}/archive",
        json: %{"expected_updated_at" => ready["updated_at"]}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert archived["status"] == "archived"
    assert archived["archived_from_status"] == "failed"

    user_req(token, :post, "#{base}/#{id}/archive",
      json: %{"expected_updated_at" => ready["updated_at"]}
    )
    |> expect_status(200)

    user_req(token, :post, "#{base}/#{id}/unarchive",
      json: %{"expected_updated_at" => ready["updated_at"]}
    )
    |> expect_status(409)

    newer = create.("second")

    page =
      user_req(token, :get, "#{base}?archive=only&limit=1")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert page["data"] == []
    assert page["has_more"]

    next =
      user_req(
        token,
        :get,
        "#{base}?archive=only&limit=1&cursor=#{URI.encode_www_form(page["next_cursor"])}"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert [%{"id" => ^id}] = next["data"]
    ordinary = user_req(token, :get, base) |> expect_status(200) |> Map.fetch!(:body)
    assert Enum.map(ordinary["data"], & &1["id"]) == [newer]

    exact =
      user_req(token, :get, "/v1/comma/groups/#{group}/task-summaries?ids=#{id},#{newer}")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert length(exact["data"]) == 2
    assert Enum.find(exact["data"], &(&1["id"] == id))["status"] == "archived"
    too_many = Enum.map_join(1..51, ",", &"id#{&1}")

    user_req(token, :get, "/v1/comma/groups/#{group}/task-summaries?ids=#{too_many}")
    |> expect_status(400)

    restored =
      user_req(token, :post, "#{base}/#{id}/unarchive",
        json: %{"expected_updated_at" => archived["updated_at"]}
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert restored["status"] == "failed"
    assert is_nil(restored["archived_from_status"])
  end

  test "conversation list enforces product pagination with an opaque signed cursor" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "paging@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

    salix_tasks =
      for {title, index} <- Enum.with_index(["One", "Two", "Three"], 1) do
        assert {:ok, task} =
                 SalixCluster.TaskSchedules.create_task_conversation(
                   workspace["default_group_id"],
                   workspace["router_agent_id"],
                   workspace["default_worker_agent_id"],
                   %{
                     "title" => title,
                     "content" => "Task #{index}",
                     "client_request_id" => "pagination-task-#{index}"
                   }
                 )

        task
      end

    first_response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations?limit=2"
      )
      |> expect_status(200)

    first = Map.fetch!(first_response, :body)
    first_etag = header(first_response, "etag")
    assert is_binary(first_etag)
    refute Enum.any?(salix_tasks, &(first_etag =~ &1["conversation_id"]))

    user_req(
      session["token"],
      :get,
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations?limit=2",
      headers: [{"if-none-match", first_etag}]
    )
    |> expect_status(304)

    assert length(first["data"]) == 2
    assert first["has_more"] == true
    assert is_binary(first["next_cursor"])
    refute Enum.any?(first["data"], &(first["next_cursor"] =~ &1["id"]))

    second =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations?limit=2&cursor=#{URI.encode_www_form(first["next_cursor"])}"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert length(second["data"]) == 1
    assert second["has_more"] == false
    assert second["next_cursor"] == nil

    returned_ids = Enum.map(first["data"] ++ second["data"], & &1["id"])
    assert length(Enum.uniq(returned_ids)) == 3

    assert MapSet.new(returned_ids) ==
             MapSet.new(salix_tasks, & &1["conversation_id"])

    user_req(
      session["token"],
      :get,
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations?cursor=tampered"
    )
    |> expect_status(400)
  end

  test "assistant conversation ensure rejects restricted workspace and conversation sessions" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "restricted-rail@example.com"})
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])

    open_session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    conversation = active_chat!(open_session, workspace)

    workspace_grant =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "restricted" => true
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    conversation_grant =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => workspace["default_group_id"],
          "conversation_id" => conversation["id"],
          "restricted" => true
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    path = "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat"

    assert user_req(workspace_grant["token"], :post, path, json: %{}).status == 403
    assert user_req(conversation_grant["token"], :post, path, json: %{}).status == 403
  end

  test "runtime tool calls are not projected and visible reply uses internal IM" do
    user = admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "tools@example.com"}).body
    workspace = create_ready_workspace!(user["id"])
    issue_billing_grant(workspace)
    session = admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{}).body

    conversation = active_chat!(session, workspace)

    Mock.script([
      {:assistant, "checking",
       [
         %{
           id: "call-1",
           name: "call",
           args: %{"tool" => "help", "params" => %{"tool" => "fs.read_file"}}
         }
       ]},
      visible_reply_turn(conversation["id"], "all done now", "reply-tool-call"),
      {:final, "session transcript only"}
    ])

    send_path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/messages"

    user_req(session["token"], :post, send_path,
      json: %{
        "client_request_id" => "tool-call",
        "requested_tools" => ["call"],
        "message" => %{"content" => "please use a tool"}
      }
    )
    |> expect_status(202)

    final =
      eventually(fn ->
        body =
          user_req(
            session["token"],
            :get,
            "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
          )
          |> expect_status(200)
          |> Map.fetch!(:body)

        if Enum.any?(body["messages"], &(salix_message_text(&1) == "all done now")), do: body
      end)

    assert List.last(final["messages"])["content"] == [
             %{"type" => "text", "text" => "all done now"}
           ]

    assert final["final_message_id"] == List.last(final["messages"])["message_id"]

    events =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/events?wait=0"
      )
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert events =~ "event: snapshot"
    assert events =~ "all done now"
    refute events =~ "event: message_created"
    refute events =~ "event: tool_call"
    refute events =~ "event: tool_result"
    refute events =~ "last_event_id"
  end

  test "Comma conversation SSE ignores Salix runtime events" do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => "sse-isolation@example.com"}).body

    workspace = create_ready_workspace!(user["id"])
    session = admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{}).body

    conversation_a = active_chat!(session, workspace)

    events_task =
      Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_a["id"]}/events?wait=500"
        )
      end)

    Process.sleep(100)

    for _ <- 1..10 do
      Phoenix.PubSub.broadcast(
        Application.fetch_env!(:comma_core, :pubsub_server),
        CommaWeb.PubSubNotifier.topic(workspace["router_agent_id"]),
        {:salix_agent_event, workspace["router_agent_id"],
         {:delta, "any-runtime-session", "runtime text must not enter Comma conversation"}}
      )

      Process.sleep(50)
    end

    events_resp = Task.await(events_task, 2_000) |> expect_status(200)

    refute events_resp.body =~ "runtime text must not enter Comma conversation"
  end

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp reset_search_projection! do
    Repo.query!(
      "TRUNCATE conversation_search_gc_runs, conversation_search_jobs, " <>
        "conversation_search_states, conversation_search_discovery_cursors, " <>
        "conversation_search_backfill_runs CASCADE"
    )

    Repo.query!(
      "DELETE FROM salix_cutover_markers " <>
        "WHERE name = 'conversation_search_projection_v1'"
    )

    Repo.query!("""
    INSERT INTO conversation_search_backfill_runs
      (writer_generation, writer_barrier_authority, writer_barrier_at,
       required_discovery_cycle, sealed_at, inserted_at, updated_at)
    VALUES ('test-search-generation', 'comma-api-test-fixture', now(),
            1, now(), now(), now())
    """)

    Repo.query!("""
    INSERT INTO conversation_search_discovery_cursors
      (id, writer_generation, completed_cycles, cycle_started_at,
       last_cycle_completed_at, inserted_at, updated_at)
    VALUES ('main', 'test-search-generation', 1, now(), now(), now(), now())
    """)

    seed_search_ready_marker!()
  end

  defp seed_search_ready_marker! do
    Repo.query!("""
    INSERT INTO salix_cutover_markers (name, completed_at, evidence)
    VALUES ('conversation_search_projection_v1', now(),
            jsonb_build_object(
              'writer_generation', 'test-search-generation',
              'mode', 'comma-api-test-fixture'
            ))
    ON CONFLICT (name) DO UPDATE
    SET completed_at = EXCLUDED.completed_at, evidence = EXCLUDED.evidence
    """)
  end

  defp search_projection_job_count(group_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM conversation_search_jobs " <>
          "WHERE writer_generation = 'test-search-generation' AND agent_group_id = $1",
        [group_id]
      )

    count
  end

  defp drain_search_projection! do
    case ConversationSearch.claim_one("comma-api-search-projector", 30_000) do
      {:ok, nil} ->
        :ok

      {:ok, claim} ->
        assert :ok = ConversationSearchProjection.process_claim(claim)
        assert :ok = ConversationSearch.complete(claim)
        drain_search_projection!()

      {:error, reason} ->
        flunk("Task-search projection claim failed: #{inspect(reason)}")
    end
  end

  defp utf16_slice(value, start, finish) do
    utf16 = :unicode.characters_to_binary(value, :utf8, {:utf16, :little})
    bytes = binary_part(utf16, start * 2, (finish - start) * 2)
    :unicode.characters_to_binary(bytes, {:utf16, :little}, :utf8)
  end

  defp admin_req(method, path, opts) do
    req(@admin_token, method, path, opts)
  end

  defp receive_history_http(request_id, ready?, body \\ "") do
    if ready?.(body) and String.ends_with?(body, "\n\n") do
      body
    else
      receive do
        {:http, {^request_id, :stream_start, _headers}} ->
          receive_history_http(request_id, ready?, body)

        {:http, {^request_id, :stream, chunk}} ->
          receive_history_http(request_id, ready?, body <> IO.iodata_to_binary(chunk))

        {:http, {^request_id, :stream_end, _headers}} ->
          flunk("History HTTP stream ended before expected frame: #{body}")

        {:http, {^request_id, error}} ->
          flunk("History HTTP stream failed: #{inspect(error)}")
      after
        6000 -> flunk("History HTTP stream did not send expected frame: #{body}")
      end
    end
  end

  defp user_req(token, method, path, opts \\ []) do
    req(token, method, path, opts)
  end

  defp active_chat!(session, workspace, attrs \\ %{}) do
    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    path = "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat"

    user_req(session["token"], :post, path, json: attrs)
    |> expect_status(200)
    |> Map.fetch!(:body)
    |> tap(&assert &1["status"] == "active")
  end

  defp req(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token} | Keyword.get(opts, :headers, [])]
    opts = Keyword.put(opts, :headers, headers)
    Req.request!([method: method, url: base() <> path] ++ opts)
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp header(resp, name), do: resp |> Req.Response.get_header(name) |> List.first()
  defp base, do: CommaWeb.Application.base_url()

  defp group_list_subscriber_count(group_id) do
    case Registry.lookup(
           SalixIM.ConversationRegistry,
           SalixIM.ConversationGroupActor.key(group_id)
         ) do
      [{pid, _value}] -> pid |> :sys.get_state() |> Map.fetch!(:list_subscribers) |> map_size()
      [] -> 0
    end
  end

  defp participant_status_subscriber_count(group_id, conversation_id, participant_id) do
    key =
      SalixIM.ConversationParticipantActor.key(group_id, conversation_id, participant_id)

    case Registry.lookup(SalixIM.ConversationRegistry, key) do
      [{pid, _value}] ->
        pid |> :sys.get_state() |> Map.fetch!(:realtime_subscribers) |> map_size()

      [] ->
        0
    end
  end

  defp sse_payloads(body, event_name) do
    body
    |> String.split("\n\n")
    |> Enum.flat_map(fn frame ->
      lines = String.split(frame, "\n")

      if ("event: " <> event_name) in lines do
        case Enum.find(lines, &String.starts_with?(&1, "data: ")) do
          nil -> []
          data -> [data |> String.replace_prefix("data: ", "") |> Jason.decode!()]
        end
      else
        []
      end
    end)
  end

  defp salix_message_text(message) do
    case message["content"] do
      content when is_binary(content) ->
        content

      content when is_list(content) ->
        Enum.map_join(content, "\n", fn
          %{"text" => text} -> text
          _other -> ""
        end)

      _other ->
        ""
    end
  end

  defp task_create_script(workspace, request_id) do
    [
      {:assistant, "delegating requested work",
       [
         %{
           id: "task-create-#{request_id}",
           name: "call",
           args: %{
             "tool" => "im_api.internal.task.create",
             "params" => %{
               "connect_id" => "internal",
               "agent_id" => workspace["default_worker_agent_id"],
               "content" => "Build the requested small website.",
               "title" => "Build small website"
             }
           }
         }
       ]},
      {:final, "Delegated."}
    ]
  end

  defp assert_no_agent_task_for(group_id, wait_ms) do
    deadline = System.monotonic_time(:millisecond) + wait_ms
    do_assert_no_agent_task(group_id, deadline)
  end

  defp do_assert_no_agent_task(group_id, deadline) do
    assert {:ok, %{"data" => conversations}} =
             SalixIM.Conversations.list_group_conversations(group_id, limit: 100)

    refute Enum.any?(conversations, &(&1["kind"] == "agent_task"))

    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(20)
      do_assert_no_agent_task(group_id, deadline)
    else
      :ok
    end
  end

  defp issue_billing_grant(%{"billing_account_id" => account_id, "id" => workspace_id}) do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    :ok =
      BillingCore.Accounts.ensure_account(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        surface: "comma",
        product_owner_type: "workspace",
        product_owner_id: workspace_id
      })

    {:ok, _grant} =
      BillingCore.Credits.issue_grant(%{
        repo: BillingCore.Repo,
        billing_account_id: account_id,
        credits: 100,
        valid_from: ~U[2026-06-17 00:00:00Z],
        expires_at: future_expiry(),
        source_type: "manual_contract",
        source_id: "comma-web-test:#{workspace_id}",
        source_event_id: "comma-web-test:#{workspace_id}",
        idempotency_key: "comma-web-test:#{workspace_id}:2026-06"
      })

    :ok
  end

  defp future_expiry do
    DateTime.utc_now()
    |> DateTime.add(30, :day)
    |> DateTime.truncate(:second)
  end

  defp seed_redeem_package do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    {:ok, _} =
      BillingCommerce.create_package(%{
        code: "comma_api_redeem_once",
        surface: "comma",
        name: "Comma API Redeem Once"
      })

    {:ok, _} =
      BillingCommerce.create_package_version(%{
        package_code: "comma_api_redeem_once",
        version: "2026-06",
        surface: "comma",
        kind: "one_time",
        billing_period: "month",
        grant_credits: 700,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })

    :ok
  end

  defp seed_stripe_package do
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    {:ok, _} =
      BillingCommerce.create_package(%{
        code: "comma_api_topup_once",
        surface: "comma",
        name: "Comma API Top-Up Once"
      })

    {:ok, _} =
      BillingCommerce.create_package_version(%{
        package_code: "comma_api_topup_once",
        version: "2026-06",
        surface: "comma",
        kind: "one_time",
        billing_period: "month",
        grant_credits: 900,
        grant_period: "current_period",
        currency: "usd",
        amount_minor: 0,
        usage_policy: %{},
        effective_at: ~U[2026-06-01 00:00:00Z],
        status: "active"
      })

    :ok
  end

  defp seed_comma_v1_provider_prices do
    # Defensive: comma_release_test commits the real catalog outside the sandbox
    # (digest-shaped price ids); if a previous run left those rows behind, our
    # deterministic ids below would hit :provider_price_mapping_conflict — and
    # a crashed setup here leaks the shared owner into every following test.
    # This delete runs inside the sandbox, so it rolls back with the rest.
    Ecto.Adapters.SQL.query!(
      BillingCore.Repo,
      "DELETE FROM billing_provider_prices WHERE provider = 'stripe' AND provider_lookup_key LIKE 'comma_%'",
      []
    )

    {:ok, _} = BillingCommerce.sync_local_pricing_catalog(Comma.Billing.PricingV1.catalog())

    Comma.Billing.PricingV1.catalog().versions
    |> Enum.each(fn version ->
      {:ok, _} =
        BillingCommerce.put_provider_price(%{
          package_code: version.package_code,
          package_version: version.version,
          provider: "stripe",
          provider_lookup_key: version.provider_lookup_key,
          provider_price_id: "price_" <> version.provider_lookup_key,
          currency: version.currency,
          amount_minor: version.amount_minor
        })
    end)
  end

  defp start_stripe_recorder do
    start_supervised!(%{
      id: BillingStripe.TestAPI.Recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: BillingStripe.TestAPI.Recorder]]}
    })
  end

  defp stripe_calls do
    BillingStripe.TestAPI.Recorder
    |> Agent.get(&Enum.reverse/1)
  end

  defp grant_count(account_id) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT count(*) FROM credit_grants WHERE billing_account_id = $1",
        [account_id]
      )

    count
  end

  defp billing_product_owner_id(account_id) do
    %{rows: [[owner_id]]} =
      Ecto.Adapters.SQL.query!(
        BillingCore.Repo,
        "SELECT product_owner_id FROM billing_accounts WHERE id = $1",
        [account_id]
      )

    owner_id
  end

  defp visible_reply_script(conversation_id, text, request_id),
    do: [
      visible_reply_turn(conversation_id, text, request_id),
      {:final, "session transcript only"}
    ]

  defp visible_reply_turn(conversation_id, text, request_id) do
    {:assistant, "sending visible internal message",
     [
       %{
         id: request_id,
         name: "call",
         args: %{
           "tool" => "im_api.internal.send_message",
           "params" => %{
             "connect_id" => "internal",
             "conversation_id" => conversation_id,
             "content" => [%{"type" => "text", "text" => text}],
             "request_id" => request_id
           }
         }
       }
     ]}
  end

  defp eventually(fun, retries \\ 100) do
    case fun.() do
      nil when retries > 0 ->
        Process.sleep(20)
        eventually(fun, retries - 1)

      nil ->
        flunk("condition did not become true")

      value ->
        value
    end
  end
end
