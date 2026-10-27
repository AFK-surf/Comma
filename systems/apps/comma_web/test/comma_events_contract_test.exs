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
