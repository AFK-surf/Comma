defmodule CommaWeb.CommaEventsContractTest do
  require SystemsRuntime.Proc

  use Comma.DataCase, async: false
  # A stream stays open for its `wait` window on a clock the tests drive: the
  # window ends after a test's changes, never in the middle of them.
  use SalixAgent.TestSupport.Settle, scope: ["Elixir.CommaWeb", "Elixir.Comma"]

  @admin_token "test-token"

  defmodule SalixClientFake do
    @behaviour Comma.Salix.Client

    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            conversations: %{},
            messages: %{},
            participant_ids: %{},
            task_participants: %{},
            participant_subscribe_error: nil,
            participant_statuses: %{},
            participant_subscribers: MapSet.new(),
            participant_status_reads: 0,
            read_error: nil,
            router_conversations: %{},
            task_list_version: 0,
            task_list_subscribers: MapSet.new(),
            mutation_version: 0,
            mutation_subscribers: MapSet.new(),
            station_tasks: [],
            station_task_subscribers: MapSet.new(),
            subscribers: MapSet.new()
          }
        end,
        name: __MODULE__
      )
    end

    @impl true
    def provision_workspace_scope(_workspace), do: :ok

    @impl true
    def resolve_workspace_scope(workspace) do
      {:ok, Map.put(workspace, "router_conversation_id", router_conversation_id(workspace))}
    end

    @impl true
    def update_workspace_vm(_workspace, _vm), do: :ok

    @impl true
    def create_group_conversation(_workspace, attrs) do
      conversation = %{
        "conversation_id" => SalixStore.Ids.new_conversation_id(),
        "kind" => attrs["kind"] || "user_chat",
        "title" => attrs["title"] || "聊天",
        "status" => "active",
        "message_count" => 0,
        "created_at" => SystemsClock.system_time(:second),
        "updated_at" => SystemsClock.system_time(:second)
      }

      Agent.update(__MODULE__, fn state ->
        state
        |> put_in([:conversations, conversation["conversation_id"]], conversation)
        |> put_in([:messages, conversation["conversation_id"]], [])
      end)

      {:ok, conversation}
    end

    @impl true
    def ensure_group_router_conversation(workspace) do
      conversation_id = router_conversation_id(workspace)
      get_group_conversation(workspace, conversation_id)
    end

    @impl true
    def get_group_conversation(_workspace, conversation_id) do
      case Agent.get(__MODULE__, fn state ->
             {state.read_error, get_in(state, [:conversations, conversation_id])}
           end) do
        {reason, _conversation} when not is_nil(reason) -> {:error, reason}
        {nil, nil} -> {:error, :not_found}
        {nil, conversation} -> {:ok, refresh_count(conversation, messages(conversation_id))}
      end
    end

    @impl true
    def get_group_conversation_with_messages(_workspace, conversation_id, _opts) do
      with {:ok, conversation} <- get_group_conversation(nil, conversation_id) do
        {:ok, %{"conversation" => conversation, "messages" => messages(conversation_id)}}
      end
    end

    @impl true
    def subscribe_group_conversation(workspace, conversation_id, subscriber) do
      Agent.update(__MODULE__, fn state ->
        Map.update!(state, :subscribers, &MapSet.put(&1, subscriber))
      end)

      SystemsRuntime.Proc.send(
        subscriber,
        {:conversation_message_created, workspace["default_group_id"], conversation_id,
         SalixStore.Ids.new_message_id(), 987_654}
      )

      {:ok, %{"owner_pid" => SystemsRuntime.Proc.whereis(__MODULE__), "tail_seq" => 987_653}}
    end

    def subscribe_group_conversation_list(_workspace, "agent_task", subscriber) do
      version =
        Agent.get_and_update(__MODULE__, fn state ->
          {"test.#{state.task_list_version}",
           Map.update!(state, :task_list_subscribers, &MapSet.put(&1, subscriber))}
        end)

      {:ok,
       %{
         "owner_pid" => SystemsRuntime.Proc.whereis(__MODULE__),
         "resync_required" => true,
         "version" => version
       }}
    end

    @impl true
    def list_station_tasks(_workspace),
      do: {:ok, Agent.get(__MODULE__, & &1.station_tasks)}

    @impl true
    def subscribe_station_tasks(_workspace, subscriber) do
      Agent.update(
        __MODULE__,
        &Map.update!(&1, :station_task_subscribers, fn s -> MapSet.put(s, subscriber) end)
      )
    end

    def station_task_subscriber_count,
      do: Agent.get(__MODULE__, &MapSet.size(&1.station_task_subscribers))

    def put_station_tasks(group_id, rows) do
      Agent.update(__MODULE__, fn state ->
        Enum.each(state.station_task_subscribers, fn subscriber ->
          SystemsRuntime.Proc.send(subscriber, {:station_tasks_invalidated, group_id})
        end)

        %{state | station_tasks: rows}
      end)
    end

    def invalidate_task_list(group_id, conversation_id) do
      Agent.get_and_update(__MODULE__, fn state ->
        next_version = state.task_list_version + 1
        version = "test.#{next_version}"

        Enum.each(state.task_list_subscribers, fn subscriber ->
          SystemsRuntime.Proc.send(
            subscriber,
            {:group_conversation_list_invalidated, group_id, "agent_task", conversation_id,
             version}
          )
        end)

        {:ok, %{state | task_list_version: next_version}}
      end)
    end

    @impl true
    def ensure_group_conversation_user_participant(_workspace, conversation_id, user_id) do
      {:ok, %{"conversation_id" => conversation_id, "user_id" => user_id}}
    end

    @impl true
    def reconcile_group_conversation_router_participant(_workspace, conversation_id) do
      {:ok, %{"conversation_id" => conversation_id}}
    end

    @impl true
    def list_group_conversation_participants(workspace, conversation_id, _opts) do
      participant_id = participant_id(conversation_id)

      {:ok,
       %{
         "conversation_id" => conversation_id,
         "participants" => [
           %{
             "participant_id" => participant_id,
             "actor_type" => "agent",
             "agent_id" => workspace["router_agent_id"],
             "state" => "active"
           },
           %{
             "actor_type" => "user",
             "user_id" => workspace["owner_user_id"],
             "state" => "active"
           }
         ],
         "has_more" => false
       }}
    end

    @impl true
    def get_group_conversation_messages(_workspace, conversation_id),
      do: {:ok, messages(conversation_id)}

    @impl true
    def append_group_conversation_message(_workspace, conversation_id, attrs) do
      message =
        attrs
        |> Map.put("message_id", SalixStore.Ids.new_message_id())
        |> Map.put_new("created_at", SystemsClock.system_time(:second))

      Agent.update(
        __MODULE__,
        &update_in(&1, [:messages, conversation_id], fn rows ->
          (rows || []) ++ [message]
        end)
      )

      {:ok, %{"conversation_id" => conversation_id, "message_id" => message["message_id"]}}
    end

    @impl true
    def conversation_activity_context(_workspace, conversation_id) do
      {:ok,
       %{
         participant_id: participant_id(conversation_id),
         conversation_id: conversation_id
       }}
    end

    @impl true
    def subscribe_group_conversation_participant(
          _workspace,
          conversation_id,
          participant_id,
          subscriber
        ) do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.participant_subscribe_error do
          nil ->
            status =
              state.participant_statuses[{conversation_id, participant_id}] ||
                state.participant_statuses[conversation_id] ||
                participant_status(conversation_id, participant_id, nil)

            {{:ok,
              %{
                "owner_pid" => task_owner(state, conversation_id, participant_id),
                "status" => status
              }}, Map.update!(state, :participant_subscribers, &MapSet.put(&1, subscriber))}

          reason ->
            {{:error, reason}, state}
        end
      end)
    end

    @impl true
    def get_group_conversation_participant_status(_workspace, conversation_id, participant_id) do
      status =
        Agent.get_and_update(__MODULE__, fn state ->
          status =
            state.participant_statuses[{conversation_id, participant_id}] ||
              state.participant_statuses[conversation_id] ||
              participant_status(conversation_id, participant_id, nil)

          {status, Map.update!(state, :participant_status_reads, &(&1 + 1))}
        end)

      {:ok, status}
    end

    defp task_owner(state, conversation_id, participant_id) do
      Enum.find_value(
        state.task_participants[conversation_id] || [],
        SystemsRuntime.Proc.whereis(__MODULE__),
        fn p ->
          if p["participant_id"] == participant_id, do: p["owner"]
        end
      )
    end

    @impl true
    def task_activity_participants(_workspace, conversation_id) do
      {:ok, Agent.get(__MODULE__, &(&1.task_participants[conversation_id] || []))}
    end

    def put_task_participants(conversation_id, participants) do
      Agent.update(__MODULE__, &put_in(&1, [:task_participants, conversation_id], participants))
    end

    def put_task_status(workspace, conversation_id, participant_id, activity, opts \\ []) do
      subscribers =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.participant_subscribers,
           put_in(state, [:participant_statuses, {conversation_id, participant_id}], %{
             "activity" => activity,
             "wait" => Keyword.get(opts, :wait)
           })}
        end)

      Enum.each(subscribers, fn subscriber ->
        SystemsRuntime.Proc.send(
          subscriber,
          {:conversation_participant_status_changed, workspace["default_group_id"],
           conversation_id, participant_id}
        )
      end)
    end

    @impl true
    def list_agent_skills(_workspace), do: {:ok, %{"skills" => []}}

    @impl true
    def write_agent_file(_workspace, path, _body), do: {:ok, %{"path" => path}}

    @impl true
    def read_agent_file(_workspace, _path, _max_bytes), do: {:error, :not_found}

    def put_task(conversation_id) do
      conversation = %{
        "conversation_id" => conversation_id,
        "kind" => "agent_task",
        "title" => "Task",
        "status" => "running",
        "message_count" => 0,
        "created_at" => SystemsClock.system_time(:second),
        "updated_at" => SystemsClock.system_time(:second)
      }

      Agent.update(__MODULE__, fn state ->
        state
        |> put_in([:conversations, conversation_id], conversation)
        |> put_in([:messages, conversation_id], [])
      end)
    end

    def put_message(conversation_id, attrs) do
      message =
        attrs
        |> Map.put_new("message_id", SalixStore.Ids.new_message_id())
        |> Map.put_new("created_at", SystemsClock.system_time(:second))

      Agent.update(
        __MODULE__,
        &update_in(&1, [:messages, conversation_id], fn rows ->
          (rows || []) ++ [message]
        end)
      )

      message
    end

    def fail_reads(reason), do: Agent.update(__MODULE__, &Map.put(&1, :read_error, reason))

    def fail_participant_subscriptions(reason),
      do: Agent.update(__MODULE__, &Map.put(&1, :participant_subscribe_error, reason))

    def put_participant_status(workspace, conversation_id, attrs, opts \\ [])
        when is_map(attrs) and is_list(opts) do
      participant_id = participant_id(conversation_id)
      status = participant_status(conversation_id, participant_id, attrs)

      subscribers =
        Agent.get_and_update(__MODULE__, fn state ->
          {state.participant_subscribers,
           put_in(state, [:participant_statuses, conversation_id], status)}
        end)

      if Keyword.get(opts, :notify, true) do
        event =
          {:conversation_participant_status_changed, workspace["default_group_id"],
           conversation_id, participant_id}

        Enum.each(subscribers, &send(&1, event))
      end

      status
    end

    def participant_id_for(conversation_id), do: participant_id(conversation_id)

    def participant_subscriber_count,
      do: Agent.get(__MODULE__, &MapSet.size(&1.participant_subscribers))

    def task_list_subscriber_count,
      do: Agent.get(__MODULE__, &MapSet.size(&1.task_list_subscribers))

    @impl true
    def subscribe_group_conversation_mutations(_workspace, subscriber) do
      version =
        Agent.get_and_update(__MODULE__, fn state ->
          {"changes.#{state.mutation_version}",
           Map.update!(state, :mutation_subscribers, &MapSet.put(&1, subscriber))}
        end)

      {:ok, %{"owner_pid" => SystemsRuntime.Proc.whereis(__MODULE__), "version" => version}}
    end

    def mutation_subscriber_count,
      do: Agent.get(__MODULE__, &MapSet.size(&1.mutation_subscribers))

    def mutate(group_id, mutation) do
      Agent.update(__MODULE__, fn state ->
        next = state.mutation_version + 1

        Enum.each(state.mutation_subscribers, fn subscriber ->
          SystemsRuntime.Proc.send(
            subscriber,
            {:group_conversation_mutated, group_id, mutation, "changes.#{next}"}
          )
        end)

        %{state | mutation_version: next}
      end)
    end

    def participant_status_read_count,
      do: Agent.get(__MODULE__, & &1.participant_status_reads)

    def send_subscription_events(events) when is_list(events) do
      Agent.get(__MODULE__, fn state ->
        Enum.each(MapSet.union(state.subscribers, state.participant_subscribers), fn subscriber ->
          Enum.each(events, &send(subscriber, &1))
        end)
      end)
    end

    defp messages(conversation_id),
      do: Agent.get(__MODULE__, &(get_in(&1, [:messages, conversation_id]) || []))

    defp refresh_count(conversation, messages),
      do: Map.put(conversation, "message_count", length(messages))

    defp participant_id(conversation_id) do
      Agent.get_and_update(__MODULE__, fn state ->
        participant_id =
          state.participant_ids[conversation_id] || SalixStore.Ids.new_participant_id()

        {participant_id, put_in(state, [:participant_ids, conversation_id], participant_id)}
      end)
    end

    defp participant_status(conversation_id, participant_id, attrs) do
      %{
        "conversation_id" => conversation_id,
        "participant_id" => participant_id
      }
      |> Map.merge(attrs || %{})
    end

    defp router_conversation_id(workspace) do
      Agent.get_and_update(__MODULE__, fn state ->
        group_id = workspace["default_group_id"]

        conversation_id =
          state.router_conversations[group_id] || SalixStore.Ids.new_conversation_id()

        conversation = %{
          "conversation_id" => conversation_id,
          "kind" => "user_chat",
          "title" => "聊天",
          "status" => "active",
          "message_count" => length(state.messages[conversation_id] || []),
          "created_at" => SystemsClock.system_time(:second),
          "updated_at" => SystemsClock.system_time(:second)
        }

        state =
          state
          |> put_in([:router_conversations, group_id], conversation_id)
          |> put_in(
            [:conversations, conversation_id],
            state.conversations[conversation_id] || conversation
          )
          |> put_in([:messages, conversation_id], state.messages[conversation_id] || [])

        {conversation_id, state}
      end)
    end
  end

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    previous_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    previous_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    previous_api_token = SystemsRuntime.get_env(:comma_web, :api_token)

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_core, :salix_client, SalixClientFake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)

    ensure_fake_s3!()
    start_supervised!(SalixClientFake)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, previous_backend)
      restore_env(:comma_core, :salix_client, previous_client)
      restore_env(:comma_web, :api_token, previous_api_token)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  test "a Group's station-hosted Tasks, and a task list stream that asks says when they change" do
    %{workspace: workspace, session: session} = create_fixture("station-tasks@example.com")
    group_id = workspace["default_group_id"]
    path = "/v1/comma/groups/#{group_id}/station-tasks"

    row = %{
      station_id: String.duplicate("a", 64),
      device_id: "dev_mac",
      thread: "EMBER/1",
      task: "EMBER/1",
      title: "Fix the build",
      status: "needs_review",
      created_by: "usr_1",
      created_at: 1_000,
      last_activity_at: 2_000,
      runtime: "codex",
      model: "gpt-5.5",
      labels: ["lbl_ship"],
      rev: 3
    }

    SalixClientFake.put_station_tasks(group_id, [row])
    response = user_req(session["token"], :get, path)
    assert response.status == 200

    assert %{
             "tasks" => [
               %{
                 "thread" => "EMBER/1",
                 "status" => "needs_review",
                 "device_id" => "dev_mac",
                 "labels" => ["lbl_ship"]
               }
             ]
           } =
             response.body

    [etag] = Req.Response.get_header(response, "etag")

    assert user_req(session["token"], :get, path, headers: [{"if-none-match", etag}]).status ==
             304

    events = fn query ->
      SystemsRuntime.Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?wait=300" <> query
        )
      end)
    end

    with_station_tasks = events.("&with=station_tasks")
    plain = events.("")
    assert eventually(fn -> SalixClientFake.station_task_subscriber_count() == 1 end)
    SalixClientFake.put_station_tasks(group_id, [%{row | status: "done", rev: 4}])

    assert [%{"type" => "station_tasks_invalidated", "group_id" => ^group_id}] =
             with_station_tasks
             |> settled_await()
             |> expect_status(200)
             |> sse_payloads("station_tasks_invalidated")

    assert plain
           |> settled_await()
           |> expect_status(200)
           |> sse_payloads("station_tasks_invalidated") == []
  end

  test "a task list stream that asks says when a request to the Workspace came, or one the person sent changed" do
    %{workspace: workspace, session: session, user: user} =
      create_fixture("task-requests@example.com")

    group_id = workspace["default_group_id"]
    topic = "task_requests:" <> workspace["id"]
    sent_topic = "sent_task_requests:" <> user["id"]

    events = fn query ->
      SystemsRuntime.Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?wait=300" <> query
        )
      end)
    end

    with_requests = events.("&with=station_tasks,task_requests")
    plain = events.("")

    assert eventually(fn ->
             length(Registry.lookup(CommaWeb.PubSub, topic)) == 1 and
               length(Registry.lookup(CommaWeb.PubSub, sent_topic)) == 1
           end)

    # Another Workspace's request is not this stream's.
    Phoenix.PubSub.broadcast(
      CommaWeb.PubSub,
      "task_requests:wsp_other",
      {:task_requests_changed, "wsp_other"}
    )

    Phoenix.PubSub.broadcast(CommaWeb.PubSub, topic, {:task_requests_changed, workspace["id"]})

    Phoenix.PubSub.broadcast(
      CommaWeb.PubSub,
      sent_topic,
      {:sent_task_requests_changed, user["id"]}
    )

    assert [
             %{"type" => "task_requests_invalidated", "group_id" => ^group_id},
             %{"type" => "task_requests_invalidated", "group_id" => ^group_id}
           ] =
             with_requests
             |> settled_await()
             |> expect_status(200)
             |> sse_payloads("task_requests_invalidated")

    assert plain
           |> settled_await()
           |> expect_status(200)
           |> sse_payloads("task_requests_invalidated") == []
  end

  describe "the Group change feed (?changes=1)" do
    test "names each conversation that changed, its kind and a message's seq" do
      %{workspace: workspace, session: session, conversation: chat} =
        create_fixture("group-changes@example.com")

      group_id = workspace["default_group_id"]
      task_id = SalixStore.Ids.new_conversation_id()
      other_chat_id = SalixStore.Ids.new_conversation_id()
      message_id = SalixStore.Ids.new_message_id()

      response_task =
        SystemsRuntime.Task.async(fn ->
          user_req(
            session["token"],
            :get,
            "/v1/comma/groups/#{group_id}/conversations/events?changes=1&wait=300"
          )
        end)

      assert eventually(fn -> SalixClientFake.mutation_subscriber_count() == 1 end)

      SalixClientFake.mutate(group_id, %{
        event: :conversation_upsert,
        conversation_id: task_id,
        kind: "agent_task"
      })

      # Another conversation of the Group this user's Workspace does not show.
      SalixClientFake.mutate(group_id, %{
        event: :message_created,
        conversation_id: other_chat_id,
        kind: "user_chat",
        message_id: message_id,
        seq: 3
      })

      SalixClientFake.mutate(group_id, %{
        event: :message_created,
        conversation_id: chat["id"],
        kind: "user_chat",
        message_id: message_id,
        seq: 7
      })

      SalixClientFake.mutate(group_id, %{
        event: :conversation_delete,
        conversation_id: task_id,
        kind: "agent_task"
      })

      # Another Group's change does not reach this one's stream.
      SalixClientFake.mutate("grp_other_group", %{
        event: :conversation_upsert,
        conversation_id: task_id,
        kind: "agent_task"
      })

      body = settled_await(response_task) |> expect_status(200)

      assert [
               %{
                 "type" => "conversation_changes_resync_required",
                 "group_id" => ^group_id,
                 "version" => "changes.0"
               }
             ] = sse_payloads(body, "conversation_changes_resync_required")

      assert sse_payloads(body, "conversation_changed") == [
               %{
                 "type" => "conversation_changed",
                 "group_id" => group_id,
                 "conversation_id" => task_id,
                 "kind" => "agent_task",
                 "change" => "upsert",
                 "version" => "changes.1"
               },
               %{
                 "type" => "conversation_changed",
                 "group_id" => group_id,
                 "conversation_id" => chat["id"],
                 "kind" => "user_chat",
                 "change" => "message",
                 "seq" => 7,
                 "version" => "changes.3"
               },
               %{
                 "type" => "conversation_changed",
                 "group_id" => group_id,
                 "conversation_id" => task_id,
                 "kind" => "agent_task",
                 "change" => "delete",
                 "version" => "changes.4"
               }
             ]

      refute body =~ other_chat_id
      assert sse_payloads(body, "conversation_list_invalidated") == []
    end

    test "a session restricted to one conversation sees only that conversation's changes" do
      %{user: user, workspace: workspace, conversation: chat} =
        create_fixture("group-changes-restricted@example.com")

      group_id = workspace["default_group_id"]

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

      response_task =
        SystemsRuntime.Task.async(fn ->
          user_req(
            restricted["token"],
            :get,
            "/v1/comma/groups/#{group_id}/conversations/events?changes=1&wait=300"
          )
        end)

      assert eventually(fn -> SalixClientFake.mutation_subscriber_count() == 1 end)

      SalixClientFake.mutate(group_id, %{
        event: :conversation_upsert,
        conversation_id: SalixStore.Ids.new_conversation_id(),
        kind: "agent_task"
      })

      SalixClientFake.mutate(group_id, %{
        event: :conversation_upsert,
        conversation_id: chat["id"],
        kind: "user_chat"
      })

      body = settled_await(response_task) |> expect_status(200)

      assert [%{"conversation_id" => conversation_id, "change" => "upsert"}] =
               sse_payloads(body, "conversation_changed")

      assert conversation_id == chat["id"]
    end
  end

  test "Task SSE reports two exact participants independently and survives one owner loss" do
    %{workspace: workspace, session: session} = create_fixture("task-participants@example.com")
    {:ok, task} = SalixClientFake.create_group_conversation(workspace, %{"kind" => "agent_task"})
    task_id = task["conversation_id"]
    group_id = workspace["default_group_id"]
    router_id = SalixStore.Ids.new_participant_id()
    worker_id = SalixStore.Ids.new_participant_id()

    router_owner =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.receive do
          :stop -> :ok
        end
      end)

    worker_owner =
      SystemsRuntime.Proc.spawn(fn ->
        SystemsRuntime.Proc.receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      SystemsRuntime.Proc.send(router_owner, :stop)
      SystemsRuntime.Proc.send(worker_owner, :stop)
    end)

    SalixClientFake.put_task_participants(task_id, [
      %{
        "participant_id" => router_id,
        "name" => "Router",
        "owner" => router_owner,
        "agent_id" => workspace["router_agent_id"]
      },
      %{
        "participant_id" => worker_id,
        "name" => "Worker",
        "owner" => worker_owner,
        "agent_id" => workspace["default_worker_agent_id"]
      }
    ])

    SalixClientFake.put_task_status(workspace, task_id, router_id, %{
      "state" => "active",
      "status" => "is thinking...",
      "updated_at" => 1
    })

    SalixClientFake.put_task_status(workspace, task_id, worker_id, %{
      "state" => "active",
      "status" => "is composing a message...",
      "updated_at" => 1
    })

    response_task =
      SystemsRuntime.Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?conversation_id=#{task_id}&wait=600"
        )
      end)

    assert eventually(fn -> SalixClientFake.participant_subscriber_count() == 1 end)

    SalixClientFake.put_task_status(workspace, task_id, router_id, %{
      "state" => "stopped",
      "status" => "",
      "updated_at" => 2
    })

    assert eventually(fn -> SalixClientFake.participant_status_read_count() > 0 end)
    reads = SalixClientFake.participant_status_read_count()

    SalixClientFake.send_subscription_events([
      {:conversation_participant_status_changed, group_id, "foreign", worker_id}
    ])

    SystemsRuntime.Proc.exit(worker_owner, :kill)
    SalixClientFake.invalidate_task_list(group_id, task_id)
    body = settled_await(response_task) |> expect_status(200)
    [first | rest] = sse_payloads(body, "task_participant_statuses")

    assert MapSet.new(Enum.map(first["participants"], & &1["name"])) ==
             MapSet.new(["Router", "Worker"])

    assert Enum.all?(first["participants"], &(&1["state"] == "active"))

    assert Enum.find(first["participants"], &(&1["participant_id"] == router_id))["actor_role"] ==
             "router"

    assert Enum.find(first["participants"], &(&1["participant_id"] == worker_id))["actor_role"] ==
             "worker"

    assert Enum.all?(first["participants"], &String.starts_with?(&1["actor_id"], "actor_"))
    refute body =~ "agent_id"

    assert Enum.any?(rest, fn snapshot ->
             Enum.any?(
               snapshot["participants"],
               &(&1["participant_id"] == router_id and &1["state"] == "stopped")
             )
           end)

    assert [%{"participant_id" => ^router_id}] = List.last(rest)["participants"]
    assert SalixClientFake.participant_status_read_count() == reads
    assert [_] = sse_payloads(body, "conversation_list_invalidated")
    refute body =~ "session_id"
    refute body =~ "draft"
  end

  test "user_chat events expose a canonical snapshot followed by an opaque invalidation" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-chat@example.com")

    salix_id = conversation["id"]

    SalixClientFake.put_message(salix_id, %{
      "actor_type" => "agent",
      "content" => "canonical reply"
    })

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/events?wait=60"
      )

    assert response.status == 200
    assert response.body =~ "event: snapshot"
    assert response.body =~ "canonical reply"
    assert response.body =~ "event: conversation_invalidated"
    assert response.body =~ ~s("conversation_id":"#{conversation["id"]}")
    refute response.body =~ "987654"
    refute response.body =~ "last_event_id"
    refute response.body =~ "after_event_id"
  end

  test "a user_chat stream or read asked after a seq carries only the messages after it" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-resume@example.com")

    for {seq, text} <- [{1, "held one"}, {2, "held two"}, {3, "new reply"}] do
      SalixClientFake.put_message(conversation["id"], %{
        "actor_type" => "agent",
        "content" => text,
        "seq" => seq
      })
    end

    events =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/events?wait=60"

    resumed = user_req(session["token"], :get, events <> "&after_seq=2")
    assert [snapshot] = sse_payloads(resumed.body, "snapshot")
    assert snapshot["after_seq"] == 2
    assert [%{"seq" => 3, "content" => "new reply"}] = snapshot["messages"]

    caught_up = user_req(session["token"], :get, events <> "&after_seq=3")
    assert [%{"messages" => [], "after_seq" => 3}] = sse_payloads(caught_up.body, "snapshot")

    whole = user_req(session["token"], :get, events)
    assert [snapshot] = sse_payloads(whole.body, "snapshot")
    refute Map.has_key?(snapshot, "after_seq")
    assert Enum.map(snapshot["messages"], & &1["seq"]) == [1, 2, 3]

    read =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}?after_seq=2"
      )

    assert %{"after_seq" => 2, "messages" => [%{"seq" => 3}]} = expect_status(read, 200)
  end

  test "a request's card takes what its person fills in: a secret, then a Workspace's own app" do
    %{session: session, user: user, workspace: workspace, conversation: conversation} =
      create_fixture("card-input@example.com")

    group = workspace["default_group_id"]
    {:ok, %{"salix_tenant_id" => tenant}} = Comma.Workspaces.get_by_group(group)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    path = "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests"

    request! = fn provider, owner, input ->
      state = "state-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

      :ok =
        SalixStore.OAuth.AuthState.create(%{
          "state" => state,
          "tenant" => tenant,
          "group_id" => group,
          "agent_id" => agent["agent_id"],
          "provider" => provider,
          "alias" => "card",
          "owner" => owner,
          "scopes" => [],
          "code_verifier" => "verifier",
          "redirect_uri" => "https://api.example.com/v1/oauth/#{provider}/callback",
          "origin" => "agent",
          "status" => "pending",
          "expires_at" => SystemsClock.system_time(:millisecond) + 600_000,
          "created_at" => SystemsClock.system_time(:millisecond)
        })

      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => SalixStore.Ids.new_session_id(),
          "tool_call_id" => state,
          "request_type" => "oauth_authorization",
          "group_id" => group,
          "tenant_id" => tenant,
          "surface_kind" => "conversation",
          "surface_ref" => %{"conversation_id" => conversation["id"]},
          "request_payload" => %{
            "oauth_authorization" => %{
              "provider" => provider,
              "alias" => "card",
              "state" => state,
              "reason" => "It is needed.",
              "scopes" => [],
              "input" => input
            }
          }
        })

      request["request_id"]
    end

    # Someone else's credential is theirs to fill in.
    theirs = request!.("secret", "comma_user|usr_someone_else", %{"kind" => "secret"})

    assert user_req(session["token"], :post, "#{path}/#{theirs}/input",
             json: %{"value" => "sk-mine"}
           ).status ==
             403

    mine =
      request!.("secret", "comma_user|" <> user["id"], %{
        "kind" => "secret",
        "label" => "OpenAI API Key"
      })

    assert %{"data" => listed} = user_req(session["token"], :get, path) |> expect_status(200)

    assert %{"input" => %{"kind" => "secret", "label" => "OpenAI API Key"}} =
             Enum.find(listed, &(&1["id"] == mine))["oauth"]

    assert user_req(session["token"], :post, "#{path}/#{mine}/input", json: %{"value" => "  "}).status ==
             400

    filled =
      user_req(session["token"], :post, "#{path}/#{mine}/input", json: %{"value" => "sk-mine"})
      |> expect_status(200)

    assert %{"status" => "completed", "outcome" => "connected", "oauth" => oauth} = filled
    refute Map.has_key?(oauth, "input")
    refute Jason.encode!(filled) =~ "sk-mine"

    # A Workspace owner gives its app; the card then has the provider's page.
    app = request!.("lark", "comma_user|" <> user["id"], %{"kind" => "app"})

    opened =
      user_req(session["token"], :post, "#{path}/#{app}/input",
        json: %{
          "client_id" => "cli_own",
          "client_secret" => "own-secret"
        }
      )
      |> expect_status(200)

    assert %{"status" => "pending", "oauth" => %{"authorization_url" => url} = oauth} = opened
    assert url =~ "cli_own"
    refute Map.has_key?(oauth, "input")
    refute Jason.encode!(opened) =~ "own-secret"

    assert {:ok, %{"client_id" => "cli_own"}} = Salix.Control.OAuthApps.get_own(tenant, "lark")

    # Answered once: the card takes nothing more.
    assert user_req(session["token"], :post, "#{path}/#{mine}/input", json: %{"value" => "again"}).status ==
             409
  end

  test "a Router asks to install a plugin: its card waits for the install from any page, or a decline" do
    %{session: session, user: user, workspace: workspace, conversation: conversation} =
      create_fixture("plugin-card@example.com")

    group = workspace["default_group_id"]
    tenant = workspace["salix_tenant_id"]

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    plugin! = fn name ->
      {:ok, definition} =
        Salix.Control.Plugins.create_definition(tenant, group, %{
          "name" => name,
          "owner_scope" => "group"
        })

      definition["plugin_id"]
    end

    notes = plugin!.("Test notes")
    sheets = plugin!.("Test sheets")

    ctx = fn sender, tool_call_id ->
      %{
        agent_id: agent["agent_id"],
        session_id: SalixStore.Ids.new_session_id(),
        tool_call_id: tool_call_id,
        group_id: group,
        tenant_id: tenant,
        trusted_origin: %{
          "provider" => "internal",
          "conversation_id" => conversation["id"],
          "message_id" => "msg-plugin-card",
          "principal_ref" => %{"namespace" => "comma_user", "subject_id" => sender}
        }
      }
    end

    ask = fn plugin_id, tool_call_id ->
      SalixAgent.Tools.PluginInstall.request_install(
        %{"plugin_id" => plugin_id, "reason" => "To keep the meeting notes."},
        ctx.(user["id"], tool_call_id)
      )
    end

    path = "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests"

    assert {content, [%{"type" => "async_tool_call_started"} | _]} = ask.(notes, "call-notes")

    assert %{"status" => "running", "plugin" => %{"name" => "Test notes"}} =
             Jason.decode!(content)

    assert %{"data" => [card]} = user_req(session["token"], :get, path) |> expect_status(200)

    assert %{
             "type" => "plugin_install",
             "status" => "pending",
             "source_message_id" => "msg-plugin-card",
             "plugin" => %{
               "id" => ^notes,
               "name" => "Test notes",
               "reason" => "To keep the meeting notes.",
               "workspace_id" => workspace_id
             }
           } = card

    assert workspace_id == workspace["id"]

    # Installed on the Plugins page: the card's request ends, and the Router's call returns installed.
    user_req(
      session["token"],
      :post,
      "/v1/comma/workspaces/#{workspace_id}/plugins/#{notes}/install",
      json: %{}
    )
    |> expect_status(200)

    assert {:ok, ended} = SalixAgent.CapabilityRequests.get(group, card["id"], tenant)
    assert ended["status"] == "completed"
    assert ended["response_payload"] == %{"status" => "installed", "plugin_id" => notes}
    assert Jason.decode!(ended["result"]["content"])["status"] == "installed"

    assert %{"data" => [%{"status" => "completed", "outcome" => "installed"}]} =
             user_req(session["token"], :get, path) |> expect_status(200)

    # Installed: a second ask answers so and puts up no card.
    assert %{"status" => "installed", "plugin" => %{"id" => ^notes}} =
             ask.(notes, "call-notes-again") |> Jason.decode!()

    # Declined on the card: the call returns that the person declined.
    assert {_content, _events} = ask.(sheets, "call-sheets")

    assert %{"data" => cards} = user_req(session["token"], :get, path) |> expect_status(200)
    declining = Enum.find(cards, &(&1["status"] == "pending"))

    assert %{"status" => "completed", "outcome" => "declined"} =
             user_req(session["token"], :post, "#{path}/#{declining["id"]}/decline", json: %{})
             |> expect_status(200)

    assert {:ok, declined} = SalixAgent.CapabilityRequests.get(group, declining["id"], tenant)
    assert declined["result"]["error_class"] == "permission_denied"

    # Only the Workspace owner installs; an id the catalog lacks names the plugins there are.
    {:ok, other} =
      Comma.Accounts.create_user(%{
        "email" =>
          "plugin-card-other-#{SystemsRuntime.Proc.unique_integer([:positive])}@comma.test"
      })

    assert {:tool_failure, _content, "forbidden", _, _, _} =
             SalixAgent.Tools.PluginInstall.request_install(
               %{"plugin_id" => sheets, "reason" => "To read the sheets."},
               ctx.(other["id"], "call-other")
             )

    assert {:tool_failure, unknown, "unknown_plugin", _, _, _} = ask.("no-such-plugin", "call-x")
    assert Enum.any?(Jason.decode!(unknown)["plugins"], &(&1["id"] == sheets))

    # The Mac apps run on the member's own Mac: they are added there, not from a card.
    assert {:tool_failure, _content, "device_plugin", _, _, _} = ask.("mac-apps", "call-mac")
  end

  test "an install ends its plugin's waiting card behind more than a page of newer requests" do
    %{session: session, user: user, workspace: workspace, conversation: conversation} =
      create_fixture("plugin-card-page@example.com")

    group = workspace["default_group_id"]
    tenant = workspace["salix_tenant_id"]

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    plugin! = fn name ->
      {:ok, definition} =
        Salix.Control.Plugins.create_definition(tenant, group, %{
          "name" => name,
          "owner_scope" => "group"
        })

      definition["plugin_id"]
    end

    notes = plugin!.("Paged notes")
    sheets = plugin!.("Paged sheets")

    ask = fn plugin_id, tool_call_id ->
      SalixAgent.Tools.PluginInstall.request_install(
        %{"plugin_id" => plugin_id, "reason" => "To keep the meeting notes."},
        %{
          agent_id: agent["agent_id"],
          session_id: SalixStore.Ids.new_session_id(),
          tool_call_id: tool_call_id,
          group_id: group,
          tenant_id: tenant,
          trusted_origin: %{
            "provider" => "internal",
            "conversation_id" => conversation["id"],
            "message_id" => "msg-plugin-page",
            "principal_ref" => %{"namespace" => "comma_user", "subject_id" => user["id"]}
          }
        }
      )
    end

    assert {_content, _events} = ask.(notes, "call-notes")
    {:ok, [waiting]} = SalixAgent.CapabilityRequests.list_group(group, tenant, status: "pending")

    # More newer pending requests than one page of the Group's requests holds.
    SystemsClock.advance(2_000)
    for n <- 1..101, do: assert({_content, _events} = ask.(sheets, "call-sheets-#{n}"))

    user_req(
      session["token"],
      :post,
      "/v1/comma/workspaces/#{workspace["id"]}/plugins/#{notes}/install",
      json: %{}
    )
    |> expect_status(200)

    assert {:ok, %{"status" => "completed", "response_payload" => %{"status" => "installed"}}} =
             SalixAgent.CapabilityRequests.get(group, waiting["request_id"], tenant)

    {:ok, pending} =
      SalixAgent.CapabilityRequests.list_group(group, tenant, status: "pending", limit: 500)

    assert length(pending) == 101
  end

  test "a person's location stream tells of the requests their own messages led to, and only those" do
    %{user: user, workspace: workspace, session: session, conversation: conversation} =
      create_fixture("requests-location-stream@example.com")

    group = workspace["default_group_id"]
    {:ok, %{"salix_tenant_id" => tenant}} = Comma.Workspaces.get_by_group(group)
    requester = "comma_user|" <> user["id"]

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    request! = fn who ->
      surface_ref =
        if who,
          do: %{"conversation_id" => conversation["id"], "requester" => who},
          else: %{"conversation_id" => conversation["id"]}

      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => SalixStore.Ids.new_session_id(),
          "tool_call_id" =>
            "call-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
          "request_type" => "location",
          "group_id" => group,
          "tenant_id" => tenant,
          "surface_kind" => "conversation",
          "surface_ref" => surface_ref,
          "request_payload" => %{"location" => %{"reason" => "Directions."}},
          "expires_at" => SystemsClock.system_time(:second) + 120
        })

      request["request_id"]
    end

    before = request!.(requester)
    anothers = request!.("comma_user|someone-else")
    no_ones = request!.(nil)
    topic = SalixAgent.CapabilityRequests.location_requester_topic(requester)

    stream =
      SystemsRuntime.Task.async(fn ->
        user_req(session["token"], :get, "/v1/comma/location-requests/events")
      end)

    assert eventually(fn -> Registry.lookup(SalixWeb.PubSub, topic) != [] end)
    after_snapshot = request!.(requester)

    assert {:ok, %{"result" => %{"content" => result}}} =
             SalixAgent.CapabilityRequests.share_location(
               group,
               before,
               %{
                 "status" => "success",
                 "location" => %{"latitude" => 35.67, "longitude" => 139.76, "accuracy_m" => 20}
               },
               tenant
             )

    assert result =~ "read_at"
    assert result =~ "accuracy_m"

    # An unreadable change ends the stream, so the test can read what it sent.
    Phoenix.PubSub.broadcast(
      SalixWeb.PubSub,
      topic,
      {:location_request_event, group, tenant, "car_missing"}
    )

    body = stream |> settled_await() |> expect_status(200)
    assert body =~ "event: snapshot"
    assert body =~ before
    assert body =~ after_snapshot
    assert body =~ group
    refute body =~ anothers
    refute body =~ no_ones
    refute body =~ "35.67"
  end

  test "an Agent's location request: a reader shares once or declines, and no card shows the position" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("requests-location@example.com")

    %{session: outsider} = create_fixture("requests-location-outsider@example.com")
    group = workspace["default_group_id"]
    {:ok, %{"salix_tenant_id" => tenant}} = Comma.Workspaces.get_by_group(group)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    path = "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests"

    request! = fn ->
      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => SalixStore.Ids.new_session_id(),
          "tool_call_id" =>
            "call-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
          "request_type" => "location",
          "group_id" => group,
          "tenant_id" => tenant,
          "surface_kind" => "conversation",
          "surface_ref" => %{"conversation_id" => conversation["id"], "message_id" => "msg-1"},
          "request_payload" => %{"location" => %{"reason" => "Find cafes near you."}},
          "expires_at" => SystemsClock.system_time(:second) + 120
        })

      request["request_id"]
    end

    shared = request!.()

    assert %{"data" => listed} = user_req(session["token"], :get, path) |> expect_status(200)

    assert %{
             "type" => "location",
             "status" => "pending",
             "source_message_id" => "msg-1",
             "location" => %{"reason" => "Find cafes near you."}
           } = Enum.find(listed, &(&1["id"] == shared))

    position = %{"latitude" => 35.67, "longitude" => 139.76, "accuracy_m" => 20}

    assert user_req(outsider["token"], :post, "#{path}/#{shared}/location", json: position).status ==
             404

    assert user_req(session["token"], :post, "#{path}/#{shared}/location",
             json: %{"latitude" => 91, "longitude" => 0}
           ).status == 400

    answered =
      user_req(session["token"], :post, "#{path}/#{shared}/location", json: position)
      |> expect_status(200)

    assert %{"status" => "completed", "outcome" => "shared"} = answered
    refute Jason.encode!(answered) =~ "35.67"

    assert {:ok, %{"response_payload" => %{"location" => %{"latitude" => 35.67}}}} =
             SalixAgent.CapabilityRequests.get(group, shared, tenant)

    # Answered once: the card takes nothing more.
    assert user_req(session["token"], :post, "#{path}/#{shared}/location", json: position).status ==
             409

    declined = request!.()

    assert %{"status" => "completed", "outcome" => "declined"} =
             user_req(session["token"], :post, "#{path}/#{declined}/decline")
             |> expect_status(200)
  end

  test "an Agent's requests in a Conversation: its readers see and decline them, nobody else" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("requests@example.com")

    %{session: outsider} = create_fixture("requests-outsider@example.com")
    group = workspace["default_group_id"]
    {:ok, %{"salix_tenant_id" => tenant}} = Comma.Workspaces.get_by_group(group)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "router",
        "runtime_config" => %{"kind" => "internal"}
      })

    request! = fn conversation_id, call ->
      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => SalixStore.Ids.new_session_id(),
          "tool_call_id" => call,
          "request_type" => "oauth_authorization",
          "group_id" => group,
          "tenant_id" => tenant,
          "surface_kind" => "conversation",
          "surface_ref" => %{"conversation_id" => conversation_id, "message_id" => "msg-1"},
          "request_payload" => %{
            "oauth_authorization" => %{
              "provider" => "github",
              "alias" => "github",
              "state" => "state-" <> call,
              "reason" => "An app keeps its code in GitHub.",
              "scopes" => ["repo"],
              "authorization_url" => "https://github.com/login/oauth/authorize?state=" <> call
            }
          }
        })

      request
    end

    shown = request!.(conversation["id"], "call-1")
    _elsewhere = request!.("cnv1_elsewhere", "call-2")
    path = "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests"

    # Only this Conversation's requests, projected without where they came from.
    assert %{"data" => [listed]} = user_req(session["token"], :get, path) |> expect_status(200)

    assert %{
             "id" => id,
             "type" => "oauth_authorization",
             "status" => "pending",
             "source_message_id" => "msg-1",
             "oauth" => %{
               "provider" => "github",
               "scopes" => ["repo"],
               "authorization_url" => "https://github.com/login/oauth/authorize?state=call-1"
             }
           } = listed

    assert id == shown["request_id"]

    for key <- ~w(tenant_id source_agent_id source_session_id tool_call_id),
        do: refute(Map.has_key?(listed, key))

    refute Map.has_key?(listed["oauth"], "state")

    # A member who cannot read the Conversation sees nothing of it.
    assert user_req(outsider["token"], :get, path).status == 404
    assert user_req(outsider["token"], :post, "#{path}/#{id}/decline").status == 404

    # The person declines: the stored ending is the answer, though no Agent session is live to hear it.
    assert %{"status" => "completed", "outcome" => "declined", "oauth" => oauth} =
             user_req(session["token"], :post, "#{path}/#{id}/decline") |> expect_status(200)

    refute Map.has_key?(oauth, "authorization_url")

    assert %{"data" => [%{"outcome" => "declined"}]} =
             user_req(session["token"], :get, path) |> expect_status(200)
  end

  test "a phone's consent card: its Conversation's readers see it, only the computer's owner allows it" do
    %{workspace: workspace, session: session, user: user, conversation: conversation} =
      create_fixture("phone-consent@example.com")

    group = workspace["default_group_id"]
    {:ok, %{"salix_tenant_id" => tenant}} = Comma.Workspaces.get_by_group(group)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "worker",
        "runtime_config" => %{"kind" => "internal"}
      })

    device! = fn owner ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group, tenant, %{
          "meta" => %{"owner_user_id" => owner, "surface" => "comma"}
        })

      token["device_id"]
    end

    request! = fn device_id, capability ->
      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => SalixStore.Ids.new_session_id(),
          "tool_call_id" =>
            "call-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
          "request_type" => "computer_use_start",
          "group_id" => group,
          "tenant_id" => tenant,
          "surface_kind" => "conversation",
          "surface_ref" => %{"conversation_id" => conversation["id"]},
          "expires_at" => SystemsClock.system_time(:second) + 600,
          "request_payload" => %{
            "computer_use_start" => %{
              "capability" => capability,
              "tool_name" => "env.android",
              "device_id" => device_id,
              "target" => "android:3B162S00P0N00000",
              "title" => "Pixel 8 · Android 15"
            }
          }
        })

      request["request_id"]
    end

    path = "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests"
    mine = request!.(device!.(user["id"]), "android_phone")
    theirs = request!.(device!.("usr_someone_else"), "android_phone")
    # Another computer-use start is no card here.
    _other = request!.(device!.(user["id"]), "computer_use")

    assert %{"data" => listed} = user_req(session["token"], :get, path) |> expect_status(200)
    assert listed |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort([mine, theirs])

    assert %{
             "type" => "computer_use_start",
             "status" => "pending",
             "phone" => %{"title" => "Pixel 8 · Android 15"}
           } =
             Enum.find(listed, &(&1["id"] == mine))

    # Someone else's phone is theirs to allow.
    assert user_req(session["token"], :post, "#{path}/#{theirs}/decision",
             json: %{"approved" => true}
           ).status ==
             403

    assert user_req(session["token"], :post, "#{path}/#{mine}/decision", json: %{}).status == 400

    assert %{"status" => "completed", "outcome" => "allowed"} =
             user_req(session["token"], :post, "#{path}/#{mine}/decision",
               json: %{"approved" => true}
             )
             |> expect_status(200)

    assert user_req(session["token"], :post, "#{path}/#{mine}/decision",
             json: %{"approved" => false}
           ).status ==
             409
  end

  test "a simulator's consent card: shown in its Conversation, only the computer's owner allows it" do
    %{workspace: workspace, session: session, user: user, conversation: conversation} =
      create_fixture("simulator-consent@example.com")

    group = workspace["default_group_id"]
    {:ok, %{"salix_tenant_id" => tenant}} = Comma.Workspaces.get_by_group(group)

    agent =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant, group, %{
        "role" => "worker",
        "runtime_config" => %{"kind" => "internal"}
      })

    device! = fn owner ->
      {:ok, token} =
        SalixEnv.ConnectorTokens.create_group_connector_token(group, tenant, %{
          "meta" => %{"owner_user_id" => owner, "surface" => "comma"}
        })

      token["device_id"]
    end

    request! = fn device_id ->
      {:ok, request} =
        SalixAgent.CapabilityRequests.create_capability_request(%{
          "source_agent_id" => agent["agent_id"],
          "source_session_id" => SalixStore.Ids.new_session_id(),
          "tool_call_id" =>
            "call-" <> Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive])),
          "request_type" => "computer_use_start",
          "group_id" => group,
          "tenant_id" => tenant,
          "surface_kind" => "conversation",
          "surface_ref" => %{"conversation_id" => conversation["id"]},
          "expires_at" => SystemsClock.system_time(:second) + 600,
          "request_payload" => %{
            "computer_use_start" => %{
              "capability" => "ios_simulator",
              "tool_name" => "env.screen",
              "device_id" => device_id,
              "target" => "simulator:0702F8CC-2E2A-4D0A-8401-C37FA01E1646",
              "title" => "iPhone 17 Pro · iOS 27.2"
            }
          }
        })

      request
    end

    path = "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests"
    mine = request!.(device!.(user["id"]))
    theirs = request!.(device!.("usr_someone_else"))
    # The call that asked waits for the card's answer.
    assert SalixAgent.CapabilityRequests.tool_name_for_request(mine) == "env.screen"

    assert %{"data" => listed} = user_req(session["token"], :get, path) |> expect_status(200)

    assert listed |> Enum.map(& &1["id"]) |> Enum.sort() ==
             Enum.sort([mine["request_id"], theirs["request_id"]])

    # A simulator on someone else's computer is theirs to allow.
    assert user_req(session["token"], :post, "#{path}/#{theirs["request_id"]}/decision",
             json: %{"approved" => true}
           ).status == 403

    assert %{"status" => "completed", "outcome" => "allowed"} =
             user_req(session["token"], :post, "#{path}/#{mine["request_id"]}/decision",
               json: %{"approved" => true}
             )
             |> expect_status(200)
  end

  test "an Agent's request stream ends on a change it cannot read, so the client reads the list again" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("requests-stream@example.com")

    group = workspace["default_group_id"]
    topic = SalixAgent.CapabilityRequests.topic(group)

    stream =
      SystemsRuntime.Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group}/conversations/#{conversation["id"]}/requests/events"
        )
      end)

    assert eventually(fn -> Registry.lookup(SalixWeb.PubSub, topic) != [] end)

    Phoenix.PubSub.broadcast(
      SalixWeb.PubSub,
      topic,
      {:capability_request_event, group, "car_missing"}
    )

    body = stream |> settled_await() |> expect_status(200)
    assert body =~ "event: snapshot"
  end

  test "user_chat SSE projects the subscribed participant activity snapshot" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-participant-activity@example.com")

    conversation_id = conversation["id"]

    source =
      SalixClientFake.put_message(conversation_id, %{
        "actor_type" => "user",
        "content" => "activity source"
      })

    detail =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}"
      )
      |> expect_status(200)

    public_source_id = hd(detail["messages"])["message_id"]
    participant_id = SalixClientFake.participant_id_for(conversation_id)

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               source["message_id"],
               participant_id
             )

    response_key =
      "rsp_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

    SalixClientFake.put_participant_status(
      workspace,
      conversation_id,
      %{
        "activity" => %{
          "state" => "active",
          "status" => "is thinking...",
          "updated_at" => 1_780_000_000_123
        },
        "presentation_activity" => %{
          "phase" => "thinking",
          "status" => "running",
          "action" => "Checking",
          "summary" => "Checking",
          "summary_class" => "public",
          "producer_epoch" => "epoch-a",
          "response_key" => response_key,
          "sequence" => 1,
          "source_message_ids" => [source_identity]
        }
      },
      notify: false
    )

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}/events?wait=0"
      )

    assert response.status == 200
    [participant_status] = sse_payloads(response.body, "participant_status")
    [activity] = sse_payloads(response.body, "activity")

    assert participant_status == %{
             "type" => "participant_status",
             "conversation_id" => conversation_id,
             "participant_id" => participant_id,
             "state" => "active",
             "status" => "is thinking...",
             "updated_at" => 1_780_000_000_123
           }

    assert activity["type"] == "activity"
    assert activity["conversation_id"] == conversation_id
    assert activity["producer_epoch"] == "epoch-a"
    assert activity["response_key"] == response_key
    assert activity["sequence"] == 1
    assert activity["summary"] == "Checking"
    assert activity["source_message_ids"] == [public_source_id]

    assert :binary.match(response.body, "event: snapshot") <
             :binary.match(response.body, "event: participant_status")

    assert :binary.match(response.body, "event: participant_status") <
             :binary.match(response.body, "event: activity")
  end

  test "user_chat SSE names a running tool call, what it works on and when it began" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-tool-call@example.com")

    conversation_id = conversation["id"]

    source =
      SalixClientFake.put_message(conversation_id, %{
        "actor_type" => "user",
        "content" => "search source"
      })

    participant_id = SalixClientFake.participant_id_for(conversation_id)

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               source["message_id"],
               participant_id
             )

    SalixClientFake.put_participant_status(
      workspace,
      conversation_id,
      %{
        "activity" => %{
          "state" => "active",
          "status" => "is waiting: async tool call still running: web.search",
          "updated_at" => 1_780_000_000_123,
          "wait_tool" => "web.search",
          "wait_started_at" => 1_780_000_000_000
        },
        "presentation_activity" => %{
          "phase" => "execution",
          "status" => "running",
          "action" => "Searching the web",
          "summary" => "Searching the web",
          "summary_class" => "public",
          "target" => "北京天气",
          "tool_name" => "web.search",
          "producer_epoch" => "epoch-a",
          "response_key" =>
            "rsp_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false),
          "sequence" => 1,
          "source_message_ids" => [source_identity]
        }
      },
      notify: false
    )

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}/events?wait=0"
      )

    assert response.status == 200
    [participant_status] = sse_payloads(response.body, "participant_status")
    [activity] = sse_payloads(response.body, "activity")

    assert participant_status["wait_tool"] == "web.search"
    assert participant_status["wait_started_at"] == 1_780_000_000_000
    refute Map.has_key?(participant_status, "waiting")
    assert activity["tool_name"] == "web.search"
    assert activity["target"] == "北京天气"
  end

  test "participant draft snapshots stream revisions and clear through participant status" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-participant-draft@example.com")

    conversation_id = conversation["id"]

    source =
      SalixClientFake.put_message(conversation_id, %{
        "actor_type" => "user",
        "content" => "draft source"
      })

    detail =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}"
      )
      |> expect_status(200)

    public_source_id = hd(detail["messages"])["message_id"]
    participant_id = SalixClientFake.participant_id_for(conversation_id)

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               source["message_id"],
               participant_id
             )

    response_key =
      "rsp_" <> Base.url_encode64(SystemsRuntime.Proc.random_bytes(18), padding: false)

    response_task =
      SystemsRuntime.Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}/events?wait=300"
        )
      end)

    assert eventually(fn -> SalixClientFake.participant_subscriber_count() == 1 end)

    publish_participant_draft(
      workspace,
      conversation_id,
      response_key,
      1,
      "Target",
      [source_identity]
    )

    publish_participant_draft(
      workspace,
      conversation_id,
      response_key,
      2,
      "Target draft",
      [source_identity]
    )

    publish_participant_draft(
      workspace,
      conversation_id,
      response_key,
      3,
      "Replacement",
      [source_identity]
    )

    previous_reads = SalixClientFake.participant_status_read_count()
    SalixClientFake.put_participant_status(workspace, conversation_id, %{})

    assert eventually(fn ->
             SalixClientFake.participant_status_read_count() > previous_reads
           end)

    response = settled_await(response_task) |> expect_status(200)
    frames = draft_payloads(response)

    assert Enum.map(frames, & &1["status"]) == ["started", "delta", "delta", "cancelled"]
    assert Enum.map(frames, & &1["revision"]) == [1, 2, 3, 3]

    assert Enum.map(frames, & &1["text"]) == [
             "Target",
             "Target draft",
             "Replacement",
             "Replacement"
           ]

    [started, appended, replacement, cancelled] = frames
    assert appended["delta"] == " draft"
    assert replacement["delta"] == nil
    assert cancelled["draft_id"] == started["draft_id"]
    assert Enum.all?(frames, &(&1["response_key"] == response_key))
    assert Enum.all?(frames, &(&1["source_message_ids"] == [public_source_id]))
  end

  defp create_fixture(email) do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => email, "name" => "Events"})
      |> expect_status(201)

    workspace = create_ready_workspace!(user["id"])

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)

    conversation =
      user_req(
        session["token"],
        :post,
        "/v1/comma/groups/#{workspace["default_group_id"]}/assistant-chat",
        json: %{}
      )
      |> expect_status(200)

    %{user: user, workspace: workspace, session: session, conversation: conversation}
  end

  defp admin_req(method, path, opts), do: req(@admin_token, method, path, opts)
  defp user_req(token, method, path, opts \\ []), do: req(token, method, path, opts)

  defp req(token, method, path, opts) do
    {extra, opts} = Keyword.pop(opts, :headers, [])
    headers = [{"authorization", "Bearer " <> token} | extra]
    Req.request!([method: method, url: base() <> path, headers: headers, retry: false] ++ opts)
  end

  defp expect_status(response, status) do
    assert response.status == status, inspect(response.body)
    response.body
  end

  defp publish_participant_draft(
         workspace,
         conversation_id,
         response_key,
         revision,
         text,
         source_message_ids
       ) do
    previous_reads = SalixClientFake.participant_status_read_count()

    SalixClientFake.put_participant_status(workspace, conversation_id, %{
      "draft" => %{
        "response_key" => response_key,
        "revision" => revision,
        "status" => "streaming",
        "text" => text,
        "source_message_ids" => source_message_ids
      }
    })

    assert eventually(fn ->
             SalixClientFake.participant_status_read_count() > previous_reads
           end)
  end

  defp draft_payloads(body) do
    body
    |> String.split("\n\n")
    |> Enum.flat_map(fn frame ->
      lines = String.split(frame, "\n")
      event = Enum.find(lines, &String.starts_with?(&1, "event: message_draft_"))
      data = Enum.find(lines, &String.starts_with?(&1, "data: "))

      if event && data do
        [data |> String.replace_prefix("data: ", "") |> Jason.decode!()]
      else
        []
      end
    end)
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

  # Settles until the condition holds; it fails on clock time if it never does.
  defp eventually(fun), do: settle_until(fun)

  defp ensure_fake_s3! do
    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
  defp base, do: CommaWeb.Application.base_url()
end
