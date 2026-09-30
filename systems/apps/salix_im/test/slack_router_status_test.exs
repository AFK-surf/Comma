defmodule SalixIM.SlackRouterStatusTest do
  use ExUnit.Case, async: false

  alias SalixIM.{SlackRouterStatusActor}
  alias SalixIM.Provider.Slack
  alias SalixStore.Keys

  defmodule SessionDelivery do
    @behaviour SalixIM.Ports.AgentDelivery
    @behaviour SalixIM.Ports.SessionActivity

    use Agent

    def start_link(_opts),
      do:
        Agent.start_link(
          fn -> %{sessions: %{}, activity_reads: [], subscriptions: MapSet.new()} end,
          name: __MODULE__
        )

    def put(agent_id, session_id, session) do
      Agent.update(__MODULE__, &put_in(&1, [:sessions, {agent_id, session_id}], session))
    end

    def reset_activity_reads,
      do: Agent.update(__MODULE__, &Map.put(&1, :activity_reads, []))

    def activity_reads,
      do: Agent.get(__MODULE__, &Enum.reverse(&1.activity_reads))

    def notify_conversation(agent, source),
      do: SalixIM.TestSupport.ConversationDelivery.notify(__MODULE__, agent, source)

    def deliver(_agent_id, _payload, _opts), do: {:error, :not_supported}

    @impl true
    def get_session(agent_id, session_id, _opts) do
      case Agent.get(__MODULE__, &Map.get(&1.sessions, {agent_id, session_id})) do
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
        session -> {:ok, session}
      end
    end

    def get_session_activity(agent_id, session_id) do
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :activity_reads, fn reads -> [{agent_id, session_id} | reads] end)
      )

      case get_session(agent_id, session_id, []) do
        {:ok, session} ->
          activity = SalixAgent.SessionActivity.project(session)

          {:ok,
           Map.put(
             activity,
             "_active_source_message_ids",
             List.wrap(session["_active_source_message_ids"])
           )}

        {:error, _reason} = error ->
          error
      end
    end

    @impl true
    def get(agent_id, session_id), do: get_session_activity(agent_id, session_id)

    @impl true
    def get_session_messages(agent_id, session_id), do: get_session(agent_id, session_id, [])

    @impl true
    def subscribe(agent_id, session_id) do
      subscriber = self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscriptions, fn subscriptions ->
          MapSet.put(subscriptions, {agent_id, session_id, subscriber})
        end)
      )

      :ok
    end

    @impl true
    def unsubscribe(agent_id, session_id) do
      subscriber = self()

      Agent.update(
        __MODULE__,
        &Map.update!(&1, :subscriptions, fn subscriptions ->
          MapSet.delete(subscriptions, {agent_id, session_id, subscriber})
        end)
      )

      :ok
    end

    def notify(agent_id, session_id) do
      __MODULE__
      |> Agent.get(
        &Enum.filter(&1.subscriptions, fn {id, sid, _pid} ->
          id == agent_id and sid == session_id
        end)
      )
      |> Enum.each(fn {_id, _sid, pid} ->
        send(pid, {:session_activity_updated, agent_id, session_id})
      end)
    end

    def subscribed?(agent_id, session_id, subscriber),
      do:
        Agent.get(
          __MODULE__,
          &MapSet.member?(&1.subscriptions, {agent_id, session_id, subscriber})
        )
  end

  defmodule SlackMock do
    use Agent

    import Plug.Conn

    def start_link(_opts),
      do:
        Agent.start_link(
          fn ->
            %{requests: [], fail_next_status?: false, permanent_status_error?: false}
          end,
          name: __MODULE__
        )

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    def fail_next_status,
      do: Agent.update(__MODULE__, &Map.put(&1, :fail_next_status?, true))

    def fail_status_permanently,
      do: Agent.update(__MODULE__, &Map.put(&1, :permanent_status_error?, true))

    defp oversized_loading_message?(params) do
      params
      |> Map.get("loading_messages", "[]")
      |> Jason.decode!()
      |> Enum.any?(&(String.length(&1) > 50))
    end

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, raw_body, conn} = read_body(conn)
      method = Enum.join(conn.path_info, "/")

      request = %{
        method: method,
        params: URI.decode_query(raw_body),
        authorization: conn |> get_req_header("authorization") |> List.first()
      }

      failure =
        Agent.get_and_update(__MODULE__, fn state ->
          failure =
            cond do
              method == "api/assistant.threads.setStatus" and
                  oversized_loading_message?(request.params) ->
                :invalid_arguments

              state.permanent_status_error? and method == "api/assistant.threads.setStatus" ->
                :invalid_arguments

              state.fail_next_status? and method == "api/assistant.threads.setStatus" ->
                :rate_limited

              true ->
                nil
            end

          {failure,
           %{
             state
             | requests: [request | state.requests],
               fail_next_status?: state.fail_next_status? and failure != :rate_limited
           }}
        end)

      case failure do
        :rate_limited ->
          conn
          |> put_resp_header("retry-after", "1")
          |> put_resp_content_type("application/json")
          |> send_resp(429, Jason.encode!(%{"ok" => false, "error" => "rate_limited"}))

        :invalid_arguments ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            Jason.encode!(%{
              "ok" => false,
              "error" => "invalid_arguments",
              "detail" => "private provider detail",
              "response_metadata" => %{
                "messages" => [
                  "[ERROR] must be less than 51 characters [json-pointer:/loading_messages/0]",
                  "private echoed status text"
                ]
              }
            })
          )

        nil ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{"ok" => true}))
      end
    end
  end

  setup do
    SalixStore.S3.Fake.reset()
    start_supervised!(SessionDelivery)
    start_supervised!(SlackMock)

    start_supervised!(
      {Registry, keys: :unique, name: SalixIM.SlackRouterStatusRegistry},
      id: SalixIM.SlackRouterStatusRegistry
    )

    start_supervised!(
      {DynamicSupervisor, name: SalixIM.SlackRouterStatusFleetSup, strategy: :one_for_one},
      id: SalixIM.SlackRouterStatusFleetSup
    )

    start_supervised!(
      {Task.Supervisor, name: SalixIM.SlackRouterStatusTaskSupervisor},
      id: SalixIM.SlackRouterStatusTaskSupervisor
    )

    env_keys = [
      :agent_delivery_mod,
      :session_activity_mod,
      :slack_api_base_url,
      :slack_router_status_placement,
      :slack_router_status_refresh_ms
    ]

    previous_env = Map.new(env_keys, &{&1, Application.get_env(:salix_im, &1)})
    port = start_bandit_retry!()

    Application.put_env(:salix_im, :agent_delivery_mod, SessionDelivery)
    Application.put_env(:salix_im, :session_activity_mod, SessionDelivery)
    Application.put_env(:salix_im, :slack_api_base_url, "http://127.0.0.1:#{port}/api")

    Application.put_env(
      :salix_im,
      :slack_router_status_placement,
      SalixIM.SlackRouterStatusPlacement.LocalFleet
    )

    Application.put_env(:salix_im, :slack_router_status_refresh_ms, 10_000)

    on_exit(fn ->
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
    end)

    suffix = System.unique_integer([:positive])
    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = SalixStore.Ids.new_group_id(tenant_id)
    connect_id = "slack-status-#{suffix}"
    agent_id = SalixStore.Ids.new_agent_id(group_id)

    connect = %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "connect_id" => connect_id,
      "provider" => "slack",
      "workspace_id" => "TSTATUS",
      "bot_token" => "xoxb-status-test",
      "oauth_completed_at" => System.system_time(:millisecond)
    }

    router =
      SalixAgent.TestSupport.create_control_agent!(agent_id, %{
        "group_id" => group_id,
        "tenant_id" => tenant_id,
        "role" => "router"
      })

    SalixAgent.TestSupport.create_control_group!(group_id, %{"router_agent_id" => agent_id})
    session_id = router["router_session_id"]

    {:ok, _connect} =
      SalixStore.CasRecord.create(Keys.ctl_im_connect(group_id, connect_id), connect)

    SessionDelivery.put(agent_id, session_id, working_session())

    {:ok,
     connect: connect,
     tenant_id: tenant_id,
     group_id: group_id,
     connect_id: connect_id,
     agent_id: agent_id,
     session_id: session_id}
  end

  test "keeps five targets but projects Router activity only to its source thread", context do
    actor = start_actor(context)

    Enum.each(1..5, fn index -> activate(actor, context, index) end)

    assert eventually(fn ->
             case window(context) do
               %{"targets" => targets} ->
                 length(targets) == 5 and
                   target_status(targets, 1) == "is thinking..." and
                   Enum.all?(2..5, &(target_status(targets, &1) == "")) and
                   length(status_requests()) == 1

               _other ->
                 false
             end
           end)

    activate(actor, context, 6)

    assert eventually(fn ->
             case window(context) do
               %{"targets" => targets} ->
                 length(targets) == 5 and length(status_requests()) == 2

               _other ->
                 false
             end
           end)

    record = window(context)

    assert Enum.map(record["targets"], & &1["thread_ts"]) ==
             Enum.map(6..2//-1, &timestamp/1)

    clear = List.last(status_requests())
    assert clear.method == "api/assistant.threads.setStatus"
    assert clear.params["thread_ts"] == timestamp(1)
    assert clear.params["status"] == ""
    refute Map.has_key?(clear.params, "loading_messages")

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      working_session(["source-6-6"])
    )

    SessionDelivery.notify(context.agent_id, context.session_id)

    assert eventually(fn ->
             case {window(context), List.last(status_requests())} do
               {%{"targets" => targets}, %{params: params}} ->
                 target_status(targets, 6) == "is thinking..." and
                   Enum.all?(2..5, &(target_status(targets, &1) == "")) and
                   params["thread_ts"] == timestamp(6) and
                   params["status"] == "is thinking..."

               _other ->
                 false
             end
           end)
  end

  test "logs safe Slack schema details and status size on rejection", context do
    SlackMock.fail_status_permanently()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        actor = start_actor(context)
        activate(actor, context, 1)

        assert eventually(fn ->
                 case window(context) do
                   %{"targets" => [%{"rejected_projection" => _}]} -> true
                   _ -> false
                 end
               end)
      end)

    assert log =~ "must be less than 51 characters [json-pointer:/loading_messages/0]"
    assert log =~ "operation=set status_chars=14 status_bytes=14"
    refute log =~ "private provider detail"
    refute log =~ "private echoed status text"
  end

  test "projects long waiting text without a limited loading message", context do
    actor = start_actor(context)
    activate(actor, context, 1)
    assert eventually(fn -> last_status() == "is thinking..." end)

    reason = "async tool call still running: im_api.slack.post_message"
    expected = "is waiting: #{reason}"
    assert String.length(expected) > 50
    put_router_activity(context, "active", "waiting", %{"wait" => %{"reason" => reason}})

    assert eventually(fn ->
             target_status(window(context)["targets"], 1) == expected
           end)

    assert List.last(status_requests()).params["status"] == expected
    refute Map.has_key?(List.last(status_requests()).params, "loading_messages")

    put_router_activity(context, "idle", "paused")
    assert eventually(fn -> target_status(window(context)["targets"], 1) == "" end)
    assert last_status() == ""
  end

  test "uses Session Activity text, clears on stop, and reactivates the window", context do
    actor = start_actor(context)
    activate(actor, context, 1)

    assert eventually(fn -> length(status_requests()) == 1 end)

    assert eventually(fn ->
             SessionDelivery.subscribed?(context.agent_id, context.session_id, actor)
           end)

    SessionDelivery.reset_activity_reads()
    put_router_activity(context, "idle", "paused")
    assert eventually(fn -> last_status() == "" end)

    put_router_activity(context, "active", "waiting", %{"wait" => %{"reason" => "user"}})
    assert eventually(fn -> last_status() == "is waiting: user" end)

    put_router_activity(context, "idle", "failed")
    assert eventually(fn -> last_status() == "error: runtime failed" end)

    put_router_activity(context, "idle", "paused")

    assert eventually(fn ->
             target_status(window(context)["targets"], 1) == "" and last_status() == ""
           end)

    settled_request_count = length(SlackMock.requests())
    Process.sleep(100)
    assert length(SlackMock.requests()) == settled_request_count

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      working_session(["source-1-7"])
    )

    activate(actor, context, 1, 7)

    assert eventually(fn -> target_status(window(context)["targets"], 1) == "is thinking..." end)

    assert Enum.uniq(Enum.map(SlackMock.requests(), & &1.method)) == [
             "api/assistant.threads.setStatus"
           ]
  end

  test "does not bootstrap working status from routed inbound delivery", context do
    SessionDelivery.put(context.agent_id, context.session_id, %{
      "status" => "idle",
      "activity_status" => "paused",
      "messages" => []
    })

    actor = start_actor(context)
    activate(actor, context, 1)

    assert eventually(fn ->
             case window(context) do
               %{"targets" => [%{"last_status" => "", "thread_ts" => thread_ts}]} ->
                 thread_ts == timestamp(1)

               _other ->
                 false
             end
           end)

    assert status_requests() == []
  end

  test "explicit actor start reloads active targets and refreshes before Slack expiry", context do
    Application.put_env(:salix_im, :slack_router_status_refresh_ms, 300)
    actor = start_actor(context)

    activate(actor, context, 1)
    activate(actor, context, 2)

    # Both activations are casts. The first HTTP request can arrive before the
    # second target is persisted, so observe the complete window before restart.
    assert eventually(fn ->
             case window(context) do
               %{"targets" => targets} ->
                 length(targets) == 2 and length(status_requests()) >= 1

               _ ->
                 false
             end
           end)

    before_restart = window(context)
    GenServer.stop(actor, :normal)
    assert eventually(fn -> status_actor_stopped?(context) end)

    _recovered_actor = start_actor(context)

    assert eventually(fn ->
             record = window(context)

             Enum.map(record["targets"], & &1["thread_ts"]) ==
               Enum.map(before_restart["targets"], & &1["thread_ts"]) and
               length(status_requests()) >= 2
           end)

    recovery_request = List.last(status_requests())

    assert recovery_request.params["thread_ts"] == timestamp(1)
    assert recovery_request.params["status"] == "is thinking..."

    assert eventually(
             fn ->
               requests = status_requests()

               length(requests) >= 3 and
                 List.last(requests).params["thread_ts"] == timestamp(1) and
                 List.last(requests).params["status"] == "is thinking..."
             end,
             2_000
           )
  end

  test "does not restore a reply-cleared status while Router activity is unavailable", context do
    Application.put_env(:salix_im, :slack_router_status_refresh_ms, 1_000)
    actor = start_actor(context)

    activate(actor, context, 1)
    assert eventually(fn -> length(SlackMock.requests()) == 1 end)

    assert eventually(fn ->
             SessionDelivery.subscribed?(context.agent_id, context.session_id, actor)
           end)

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      {:error, :temporarily_unavailable}
    )

    assert {:ok, _reply} =
             Slack.call(nil, context.tenant_id, context.connect, "slack.post_message", %{
               "channel" => "CSTATUS",
               "thread_ts" => timestamp(1),
               "text" => "provider reply"
             })

    assert eventually(fn ->
             target_status(window(context)["targets"], 1) == "" and
               length(status_requests()) == 1 and length(SlackMock.requests()) == 2
           end)

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      working_session(["source-1-1"])
    )

    SessionDelivery.notify(context.agent_id, context.session_id)

    assert eventually(fn ->
             target_status(window(context)["targets"], 1) == "is thinking..." and
               length(status_requests()) == 2 and
               List.last(status_requests()).params["status"] == "is thinking..."
           end)
  end

  test "retries a failed active reassertion after a provider reply clears Slack status",
       context do
    Application.put_env(:salix_im, :slack_router_status_refresh_ms, 10_000)
    actor = start_actor(context)

    activate(actor, context, 1)
    assert eventually(fn -> length(status_requests()) == 1 end)

    SlackMock.fail_next_status()

    assert {:ok, _reply} =
             Slack.call(nil, context.tenant_id, context.connect, "slack.post_message", %{
               "channel" => "CSTATUS",
               "thread_ts" => timestamp(1),
               "text" => "provider reply before retry"
             })

    assert eventually(fn -> length(status_requests()) == 2 end)

    assert eventually(
             fn ->
               target_status(window(context)["targets"], 1) == "is thinking..." and
                 length(status_requests()) == 3
             end,
             3_000
           )
  end

  test "persists one permanent rejection without forgetting the last confirmed status", context do
    actor = start_actor(context)

    activate(actor, context, 1)

    assert eventually(fn -> length(status_requests()) == 1 end)

    SlackMock.fail_status_permanently()
    put_router_activity(context, "active", "waiting", %{"wait" => %{"reason" => "user"}})

    assert eventually(fn -> length(status_requests()) == 2 end)

    state = :sys.get_state(actor)
    assert state.retry_at == 0
    assert state.tick_ref == nil

    assert [
             %{
               "last_status" => "is thinking...",
               "rejected_projection" => %{"status" => "is waiting: user"}
             }
           ] = window(context)["targets"]

    SessionDelivery.notify(context.agent_id, context.session_id)

    Process.sleep(100)
    assert length(status_requests()) == 2

    GenServer.stop(actor, :normal)
    assert eventually(fn -> status_actor_stopped?(context) end)
    recovered_actor = start_actor(context)

    assert eventually(fn ->
             SessionDelivery.subscribed?(context.agent_id, context.session_id, recovered_actor)
           end)

    Process.sleep(100)
    assert length(status_requests()) == 2
  end

  test "clears instead of renewing unavailable Router activity", context do
    Application.put_env(:salix_im, :slack_router_status_refresh_ms, 300)
    actor = start_actor(context)

    activate(actor, context, 1)
    assert eventually(fn -> length(SlackMock.requests()) == 1 end)

    assert eventually(fn ->
             target_status(window(context)["targets"], 1) == "is thinking..."
           end)

    SessionDelivery.reset_activity_reads()

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      {:error, :temporarily_unavailable}
    )

    assert eventually(fn -> target_status(window(context)["targets"], 1) == "" end)

    assert length(status_requests()) == 2
    assert List.last(status_requests()).params["status"] == ""
    assert SessionDelivery.activity_reads() == [{context.agent_id, context.session_id}]

    Process.sleep(400)
    assert length(status_requests()) == 2
    assert SessionDelivery.activity_reads() == [{context.agent_id, context.session_id}]
  end

  test "keeps a fresh assertion through a transient Router activity read failure", context do
    Application.put_env(:salix_im, :slack_router_status_refresh_ms, 1_000)
    actor = start_actor(context)

    activate(actor, context, 1)
    assert eventually(fn -> length(SlackMock.requests()) == 1 end)

    assert eventually(fn ->
             SessionDelivery.subscribed?(context.agent_id, context.session_id, actor)
           end)

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      {:error, :temporarily_unavailable}
    )

    SessionDelivery.notify(context.agent_id, context.session_id)
    Process.sleep(100)

    assert target_status(window(context)["targets"], 1) == "is thinking..."
    assert length(SlackMock.requests()) == 1

    SessionDelivery.put(
      context.agent_id,
      context.session_id,
      working_session(["source-1-1"])
    )

    SessionDelivery.notify(context.agent_id, context.session_id)
    Process.sleep(100)

    assert target_status(window(context)["targets"], 1) == "is thinking..."
    assert length(SlackMock.requests()) == 1
  end

  test "aggregates named workers per conversation target and updates only the changed thread",
       context do
    codex = create_worker!(context, "codex", "Codex")
    kimi = create_worker!(context, "kimi", "Kimi")
    nova = create_worker!(context, "nova", "Nova")

    conversation_one =
      seed_conversation!(context, "conversation-one", [
        agent_participant(context.agent_id, "router", "Router", 0),
        agent_participant(codex, "codex", "Codex", 1),
        agent_participant(kimi, "kimi", "Kimi", 2)
      ])

    conversation_two =
      seed_conversation!(context, "conversation-two", [
        agent_participant(nova, "nova", "Nova", 1)
      ])

    SessionDelivery.put(
      codex,
      participant_session_id(context, conversation_one, codex),
      working_session()
    )

    SessionDelivery.put(kimi, participant_session_id(context, conversation_one, kimi), %{
      "status" => "active",
      "activity_status" => "waiting",
      "messages" => []
    })

    SessionDelivery.put(nova, participant_session_id(context, conversation_two, nova), %{
      "status" => "idle",
      "activity_status" => "paused",
      "messages" => []
    })

    actor = start_actor(context)
    activate_conversation(actor, context, 1, conversation_one, codex)
    activate_conversation(actor, context, 2, conversation_two, nova)

    assert eventually(fn ->
             targets = window(context)["targets"]

             target_status(targets, 1) == "Codex is thinking... | Kimi is waiting..." and
               target_status(targets, 2) == "" and length(status_requests()) == 1
           end)

    requests = status_requests()

    assert Enum.map(requests, &{&1.params["thread_ts"], &1.params["status"]}) == [
             {timestamp(1), "Codex is thinking... | Kimi is waiting..."}
           ]

    assert {:ok, _reply} =
             Slack.call(nil, context.tenant_id, context.connect, "slack.post_message", %{
               "channel" => "CSTATUS",
               "thread_ts" => timestamp(1),
               "text" => "worker reply"
             })

    assert eventually(fn ->
             length(status_requests()) == 2 and
               List.last(status_requests()).params["status"] ==
                 "Codex is thinking... | Kimi is waiting..."
           end)

    SessionDelivery.reset_activity_reads()

    kimi_session_id = participant_session_id(context, conversation_one, kimi)
    SessionDelivery.put(kimi, kimi_session_id, {:error, :temporarily_unavailable})
    SessionDelivery.notify(kimi, kimi_session_id)

    Process.sleep(100)
    assert length(status_requests()) == 2

    reads = SessionDelivery.activity_reads()
    assert Enum.any?(reads, &match?({^codex, _session_id}, &1))
    assert Enum.any?(reads, &match?({^kimi, _session_id}, &1))
    refute Enum.any?(reads, &match?({^nova, _session_id}, &1))

    assert target_status(window(context)["targets"], 1) ==
             "Codex is thinking... | Kimi is waiting..."

    SessionDelivery.reset_activity_reads()

    SessionDelivery.put(
      kimi,
      kimi_session_id,
      working_session()
    )

    SessionDelivery.notify(kimi, kimi_session_id)

    assert eventually(fn ->
             case List.last(SlackMock.requests()) do
               %{params: %{"thread_ts" => thread_ts, "status" => status}} ->
                 length(status_requests()) == 3 and thread_ts == timestamp(1) and
                   status == "Codex is thinking... | Kimi is thinking..."

               _other ->
                 false
             end
           end)

    refute Enum.any?(SessionDelivery.activity_reads(), &match?({^nova, _session_id}, &1))
  end

  test "clears a stopped conversation and Session Activity can reactivate it without new inbound",
       context do
    worker = create_worker!(context, "worker", "Worker")

    conversation_id =
      seed_conversation!(context, "conversation-reactivation", [
        agent_participant(worker, "worker", "Worker", 1)
      ])

    session_id = participant_session_id(context, conversation_id, worker)
    SessionDelivery.put(worker, session_id, working_session())

    actor = start_actor(context)
    activate_conversation(actor, context, 1, conversation_id, worker)

    assert eventually(fn ->
             case List.last(SlackMock.requests()) do
               %{params: %{"status" => "Worker is thinking..."}} -> true
               _other -> false
             end
           end)

    SessionDelivery.put(worker, session_id, %{
      "status" => "idle",
      "activity_status" => "paused",
      "messages" => []
    })

    SessionDelivery.notify(worker, session_id)

    assert eventually(fn ->
             case {window(context), List.last(SlackMock.requests())} do
               {%{"targets" => [%{"last_status" => ""}]}, %{params: %{"status" => ""}}} ->
                 true

               _other ->
                 false
             end
           end)

    cleared_request_count = length(SlackMock.requests())
    Process.sleep(100)
    assert length(SlackMock.requests()) == cleared_request_count
    GenServer.stop(actor, :normal)
    assert eventually(fn -> status_actor_stopped?(context) end)
    recovered_actor = start_actor(context, worker)

    assert eventually(fn -> SessionDelivery.subscribed?(worker, session_id, recovered_actor) end)

    SessionDelivery.put(worker, session_id, working_session())
    SessionDelivery.notify(worker, session_id)

    assert eventually(fn ->
             case List.last(SlackMock.requests()) do
               %{params: %{"status" => "Worker is thinking..."}} ->
                 length(SlackMock.requests()) == cleared_request_count + 1

               _other ->
                 false
             end
           end)
  end

  defp start_actor(context, owner_agent_id \\ nil) do
    owner_agent_id = owner_agent_id || context.agent_id
    {:ok, pid} = SalixIM.SlackRouterStatus.ensure_actor_local(context.connect_id, owner_agent_id)
    pid
  end

  defp activate(actor, context, thread_index, message_index \\ nil) do
    message_index = message_index || thread_index

    SlackRouterStatusActor.activate(
      actor,
      context.connect,
      %{
        channel_id: "CSTATUS",
        thread_ts: timestamp(thread_index),
        message_ts: timestamp(message_index),
        source_message_id: "source-#{thread_index}-#{message_index}"
      },
      context.agent_id,
      context.session_id
    )
  end

  defp activate_conversation(
         actor,
         context,
         thread_index,
         conversation_id,
         owner_agent_id
       ) do
    SlackRouterStatusActor.activate_conversation(
      actor,
      context.connect,
      %{
        channel_id: "CSTATUS",
        thread_ts: timestamp(thread_index),
        message_ts: timestamp(thread_index),
        source_message_id: "conversation-source-#{thread_index}"
      },
      owner_agent_id,
      conversation_id
    )
  end

  defp create_worker!(context, suffix, name) do
    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(
        context.tenant_id,
        context.group_id,
        %{"name" => "#{name}-#{suffix}", "role" => "worker"}
      )

    agent["agent_id"]
  end

  defp seed_conversation!(context, _suffix, participants) do
    {:ok, conversation} =
      SalixIM.ConversationInput.create_group_conversation(
        context.group_id,
        %{
          "kind" => "agent_task",
          "title" => "Status conversation",
          "participants" => participants
        }
      )

    conversation["conversation_id"]
  end

  defp agent_participant(agent_id, _suffix, name, created_offset) do
    now = System.system_time(:millisecond)

    %{
      "actor_type" => "agent",
      "agent_id" => agent_id,
      "agent_name" => name,
      "created_at" => now + created_offset
    }
  end

  defp participant_session_id(context, conversation_id, agent_id) do
    {:ok, %{"participants" => participants}} =
      SalixIM.Conversations.list_group_conversation_participants(
        context.group_id,
        conversation_id,
        limit: 1_000
      )

    participants
    |> Enum.find(&(&1["agent_id"] == agent_id))
    |> get_in(["payload", "session_id"])
  end

  defp target_status(targets, thread_index) when is_list(targets) do
    targets
    |> Enum.find(&(&1["thread_ts"] == timestamp(thread_index)))
    |> case do
      nil -> nil
      target -> target["last_status"]
    end
  end

  defp target_status(_targets, _thread_index), do: nil

  defp status_requests do
    Enum.filter(SlackMock.requests(), &(&1.method == "api/assistant.threads.setStatus"))
  end

  defp status_actor_stopped?(context) do
    Registry.lookup(
      SalixIM.SlackRouterStatusRegistry,
      SlackRouterStatusActor.key(context.connect_id)
    ) == []
  end

  defp window(context) do
    case SalixStore.CasRecord.get(Keys.ctl_im_slack_router_status_window(context.connect_id)) do
      {:ok, record} -> record
      {:error, _reason} -> nil
    end
  end

  defp working_session(source_message_ids \\ ["source-1-1"]) do
    %{
      "status" => "active",
      "activity_status" => "thinking",
      "_active_source_message_ids" => source_message_ids,
      "messages" => [],
      "async_tool_calls" => %{}
    }
  end

  defp put_router_activity(context, status, activity_status, extra \\ %{}) do
    session =
      Map.merge(
        %{
          "status" => status,
          "activity_status" => activity_status,
          "_active_source_message_ids" => ["source-1-1"],
          "messages" => []
        },
        extra
      )

    SessionDelivery.put(context.agent_id, context.session_id, session)
    SessionDelivery.notify(context.agent_id, context.session_id)
  end

  defp last_status do
    case List.last(status_requests()) do
      %{params: %{"status" => status}} -> status
      _other -> nil
    end
  end

  defp timestamp(index), do: "180000000#{index}.000001"

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        eventually_until(fun, deadline)
      end
    end
  end

  defp start_bandit_retry! do
    Enum.find_value(1..10, fn _attempt ->
      port = 40_000 + :erlang.phash2(make_ref(), 20_000)

      case start_supervised({Bandit, plug: SlackMock, port: port}, id: {:slack_mock, port}) do
        {:ok, _pid} -> port
        {:error, _reason} -> nil
      end
    end) || raise "could not bind Slack mock port"
  end

  defp restore_env(key, nil), do: Application.delete_env(:salix_im, key)
  defp restore_env(key, value), do: Application.put_env(:salix_im, key, value)
end
