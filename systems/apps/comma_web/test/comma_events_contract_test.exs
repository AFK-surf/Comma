defmodule CommaWeb.CommaEventsContractTest do
  use Comma.DataCase, async: false

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
        "created_at" => System.system_time(:second),
        "updated_at" => System.system_time(:second)
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

      send(
        subscriber,
        {:conversation_message_created, workspace["default_group_id"], conversation_id,
         SalixStore.Ids.new_message_id(), 987_654}
      )

      {:ok, %{"owner_pid" => Process.whereis(__MODULE__), "tail_seq" => 987_653}}
    end

    def subscribe_group_conversation_list(_workspace, "agent_task", subscriber) do
      version =
        Agent.get_and_update(__MODULE__, fn state ->
          {"test.#{state.task_list_version}",
           Map.update!(state, :task_list_subscribers, &MapSet.put(&1, subscriber))}
        end)

      {:ok,
       %{
         "owner_pid" => Process.whereis(__MODULE__),
         "resync_required" => true,
         "version" => version
       }}
    end

    def invalidate_task_list(group_id, conversation_id) do
      Agent.get_and_update(__MODULE__, fn state ->
        next_version = state.task_list_version + 1
        version = "test.#{next_version}"

        Enum.each(state.task_list_subscribers, fn subscriber ->
          send(
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
        |> Map.put_new("created_at", System.system_time(:second))

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
        Process.whereis(__MODULE__),
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
        send(
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
        "created_at" => System.system_time(:second),
        "updated_at" => System.system_time(:second)
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
        |> Map.put_new("created_at", System.system_time(:second))

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
          "created_at" => System.system_time(:second),
          "updated_at" => System.system_time(:second)
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
    unless Process.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    previous_backend = Application.get_env(:salix_store, :s3_backend)
    previous_client = Application.get_env(:comma_core, :salix_client)
    previous_api_token = Application.get_env(:comma_web, :api_token)

    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    Application.put_env(:comma_core, :salix_client, SalixClientFake)
    Application.put_env(:comma_web, :api_token, @admin_token)

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

  test "task-list SSE starts with a canonical resync barrier and streams exact Group changes" do
    %{workspace: workspace, session: session} = create_fixture("task-list-events@example.com")
    group_id = workspace["default_group_id"]

    response_task =
      Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?wait=300"
        )
      end)

    assert eventually(fn -> SalixClientFake.task_list_subscriber_count() == 1 end)
    SalixClientFake.invalidate_task_list(group_id, SalixStore.Ids.new_conversation_id())

    body = Task.await(response_task, 2_000) |> expect_status(200)
    assert [resync] = sse_payloads(body, "conversation_list_resync_required")
    assert [invalidation] = sse_payloads(body, "conversation_list_invalidated")

    assert Map.take(resync, ~w(type group_id kind version)) == %{
             "type" => "conversation_list_resync_required",
             "group_id" => group_id,
             "kind" => "agent_task",
             "version" => "test.0"
           }

    assert Map.take(invalidation, ~w(type group_id kind version)) == %{
             "type" => "conversation_list_invalidated",
             "group_id" => group_id,
             "kind" => "agent_task",
             "version" => "test.1"
           }
  end

  test "Task SSE reports two exact participants independently and survives one owner loss" do
    %{workspace: workspace, session: session} = create_fixture("task-participants@example.com")
    {:ok, task} = SalixClientFake.create_group_conversation(workspace, %{"kind" => "agent_task"})
    task_id = task["conversation_id"]
    group_id = workspace["default_group_id"]
    router_id = SalixStore.Ids.new_participant_id()
    worker_id = SalixStore.Ids.new_participant_id()

    router_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    worker_owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn ->
      send(router_owner, :stop)
      send(worker_owner, :stop)
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
      Task.async(fn ->
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

    Process.exit(worker_owner, :kill)
    SalixClientFake.invalidate_task_list(group_id, task_id)
    body = Task.await(response_task, 2000) |> expect_status(200)
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

  test "Task SSE hides waiting participants and restores them when work resumes" do
    %{workspace: workspace, session: session} = create_fixture("task-waiting@example.com")
    {:ok, task} = SalixClientFake.create_group_conversation(workspace, %{"kind" => "agent_task"})
    task_id = task["conversation_id"]
    group_id = workspace["default_group_id"]
    router_id = SalixStore.Ids.new_participant_id()
    worker_id = SalixStore.Ids.new_participant_id()
    active = %{"state" => "active", "status" => "is thinking...", "updated_at" => 1}
    wait = %{"reason" => "Waiting for new instructions", "remaining_seconds" => 300}

    SalixClientFake.put_task_participants(task_id, [
      %{"participant_id" => router_id, "name" => "Router"},
      %{
        "participant_id" => worker_id,
        "name" => "Worker",
        "agent_id" => workspace["default_worker_agent_id"]
      }
    ])

    SalixClientFake.put_task_status(workspace, task_id, router_id, active)
    # Deliberately keep identical text: only structured wait controls visibility.
    SalixClientFake.put_task_status(workspace, task_id, worker_id, active, wait: wait)

    response_task =
      Task.async(fn ->
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{group_id}/conversations/events?conversation_id=#{task_id}&wait=600"
        )
      end)

    assert eventually(fn -> SalixClientFake.participant_subscriber_count() == 1 end)
    reads = SalixClientFake.participant_status_read_count()
    SalixClientFake.put_task_status(workspace, task_id, router_id, active, wait: wait)
    assert eventually(fn -> SalixClientFake.participant_status_read_count() > reads end)
    reads = SalixClientFake.participant_status_read_count()
    SalixClientFake.put_task_status(workspace, task_id, worker_id, %{active | "updated_at" => 2})
    assert eventually(fn -> SalixClientFake.participant_status_read_count() > reads end)
    reads = SalixClientFake.participant_status_read_count()

    SalixClientFake.put_task_status(
      workspace,
      task_id,
      worker_id,
      %{
        "state" => "error",
        "status" => "Runtime unavailable",
        "updated_at" => 3
      },
      wait: wait
    )

    assert eventually(fn -> SalixClientFake.participant_status_read_count() > reads end)
    SalixClientFake.invalidate_task_list(group_id, task_id)
    body = Task.await(response_task, 2000) |> expect_status(200)
    [first | rest] = sse_payloads(body, "task_participant_statuses")

    assert %{"participant_id" => ^worker_id, "name" => "Worker", "actor_id" => "actor_" <> _} =
             first["bound_worker"]

    assert Enum.all?(rest, &(&1["bound_worker"] == first["bound_worker"]))
    assert [%{"participant_id" => ^router_id}] = first["participants"]
    assert Enum.any?(rest, &(&1["participants"] == []))

    assert Enum.any?(rest, fn frame ->
             match?(
               [%{"participant_id" => ^worker_id, "state" => "active"}],
               frame["participants"]
             )
           end)

    assert [%{"participant_id" => ^worker_id, "state" => "error"}] =
             List.last(rest)["participants"]

    assert [_] = sse_payloads(body, "conversation_list_invalidated")
  end

  test "Task participant subscription failure leaves canonical invalidations available" do
    %{workspace: workspace, session: session} =
      create_fixture("task-participants-unavailable@example.com")

    {:ok, task} = SalixClientFake.create_group_conversation(workspace, %{"kind" => "agent_task"})
    task_id = task["conversation_id"]

    SalixClientFake.put_task_participants(task_id, [
      %{"participant_id" => SalixStore.Ids.new_participant_id(), "name" => "Worker"}
    ])

    SalixClientFake.fail_participant_subscriptions(:unavailable)

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/events?conversation_id=#{task_id}&wait=1"
      )

    body = expect_status(response, 200)
    assert [%{"participants" => []}] = sse_payloads(body, "task_participant_statuses")
    assert [_] = sse_payloads(body, "conversation_list_resync_required")
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

  test "participant subscription failure does not disable canonical conversation events" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-participant-unavailable@example.com")

    SalixClientFake.fail_participant_subscriptions(:participant_status_unavailable)

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}/events?wait=0"
      )

    assert response.status == 200
    assert [snapshot] = sse_payloads(response.body, "snapshot")
    refute Map.has_key?(snapshot, "participant_draft")
    refute Map.has_key?(snapshot, "participant_status")
    assert sse_payloads(response.body, "participant_status") == []
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

    response_key = "rsp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

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

  test "user_chat SSE projects the exact participant display status" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-participant-display-status@example.com")

    conversation_id = conversation["id"]
    participant_id = SalixClientFake.participant_id_for(conversation_id)

    SalixClientFake.put_participant_status(
      workspace,
      conversation_id,
      %{
        "activity" => %{
          "state" => "active",
          "status" => "is executing a tool...",
          "updated_at" => 1_780_000_000_123
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

    assert participant_status == %{
             "type" => "participant_status",
             "conversation_id" => conversation_id,
             "participant_id" => participant_id,
             "state" => "active",
             "status" => "is executing a tool...",
             "updated_at" => 1_780_000_000_123
           }

    assert [%{"participant_status" => ^participant_status}] =
             sse_payloads(response.body, "snapshot")

    assert :binary.match(response.body, "event: snapshot") <
             :binary.match(response.body, "event: participant_status")
  end

  test "a completed reply snapshot carries stopped status with its cleared draft" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-reply-status-handoff@example.com")

    conversation_id = conversation["id"]
    participant_id = SalixClientFake.participant_id_for(conversation_id)

    SalixClientFake.put_message(conversation_id, %{
      "actor_type" => "agent",
      "content" => "The requested answer is ready."
    })

    SalixClientFake.put_participant_status(
      workspace,
      conversation_id,
      %{
        "activity" => %{
          "state" => "stopped",
          "status" => "",
          "updated_at" => 1_790_160_598_626
        }
      },
      notify: false
    )

    reads = SalixClientFake.participant_status_read_count()

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}/events?wait=0"
      )

    assert response.status == 200

    assert [
             %{
               "messages" => [%{"content" => "The requested answer is ready."}],
               "participant_draft" => nil,
               "participant_status" => %{
                 "conversation_id" => ^conversation_id,
                 "participant_id" => ^participant_id,
                 "state" => "stopped",
                 "status" => "",
                 "updated_at" => 1_790_160_598_626
               }
             }
           ] = sse_payloads(response.body, "snapshot")

    assert SalixClientFake.participant_status_read_count() == reads
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

    response_key = "rsp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    response_task =
      Task.async(fn ->
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

    response = Task.await(response_task, 2_000) |> expect_status(200)
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

  test "a reconnect first frame includes the exact current draft before separate realtime events" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-atomic-draft@example.com")

    conversation_id = conversation["id"]

    source =
      SalixClientFake.put_message(conversation_id, %{
        "actor_type" => "user",
        "content" => "Continue"
      })

    participant_id = SalixClientFake.participant_id_for(conversation_id)

    assert {:ok, source_identity} =
             SalixIM.ConversationSourceIdentity.encode(
               conversation_id,
               source["message_id"],
               participant_id
             )

    response_key = "rsp_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    SalixClientFake.put_participant_status(workspace, conversation_id, %{
      "draft" => %{
        "response_key" => response_key,
        "revision" => 3,
        "source_message_ids" => [source_identity],
        "text" => "An already visible prefix"
      }
    })

    path =
      "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation_id}/events?wait=0"

    body = user_req(session["token"], :get, path) |> expect_status(200)

    assert [
             %{
               "messages" => [%{"message_id" => public_source_id}],
               "participant_draft" => initial
             }
           ] = sse_payloads(body, "snapshot")

    assert initial["text"] == "An already visible prefix"
    assert initial["revision"] == 3
    assert initial["response_key"] == response_key
    assert initial["source_message_ids"] == [public_source_id]
    assert [^initial] = sse_payloads(body, "message_draft_started")
    refute body =~ source_identity

    # A later owner snapshot with no draft explicitly retires the presentation;
    # it never changes the independently read canonical user message.
    SalixClientFake.put_participant_status(workspace, conversation_id, %{})
    cleared = user_req(session["token"], :get, path) |> expect_status(200)

    assert [%{"messages" => [%{"message_id" => ^public_source_id}], "participant_draft" => nil}] =
             sse_payloads(cleared, "snapshot")

    assert sse_payloads(cleared, "message_draft_started") == []
  end

  test "agent_task events are explicitly unsupported" do
    %{workspace: public_workspace, session: session} = create_fixture("events-task@example.com")
    {:ok, workspace} = Comma.Workspaces.get(public_workspace["id"])
    salix_id = SalixStore.Ids.new_conversation_id()
    SalixClientFake.put_task(salix_id)

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{salix_id}/events?wait=0"
      )

    assert response.status == 409

    assert response.body == %{
             "error" => "unsupported_for_kind",
             "code" => "unsupported_for_kind",
             "kind" => "agent_task",
             "operation" => "events"
           }
  end

  test "conversation failures never expose canonical Salix identities" do
    %{workspace: workspace, session: session, conversation: conversation} =
      create_fixture("events-redacted-error@example.com")

    salix_id = conversation["id"]
    group_id = workspace["default_group_id"]

    SalixClientFake.fail_reads({:owner_unreachable, group_id <> ":" <> salix_id, :timeout})

    response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
      )

    assert response.status == 503
    assert response.body == %{"error" => "conversation_unavailable"}

    SalixClientFake.fail_reads(:salix_participant_validation_incomplete)

    atom_response =
      user_req(
        session["token"],
        :get,
        "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
      )

    assert atom_response.status == 503
    assert atom_response.body == %{"error" => "conversation_unavailable"}

    for internal_reason <- [
          :grp1_private,
          "grp1_private:cnv1_private",
          {:bad_request, "invalid grp1_private/cnv1_private"}
        ] do
      SalixClientFake.fail_reads(internal_reason)

      internal_response =
        user_req(
          session["token"],
          :get,
          "/v1/comma/groups/#{workspace["default_group_id"]}/conversations/#{conversation["id"]}"
        )

      assert internal_response.status == 503
      assert internal_response.body == %{"error" => "conversation_unavailable"}
    end
  end

  defp create_fixture(email) do
    user =
      admin_req(:post, "/v1/comma/admin/users", json: %{"email" => email, "name" => "Events"})
      |> expect_status(201)

    workspace = create_ready_workspace!(user["id"])

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])

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
    headers = [{"authorization", "Bearer " <> token}]
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

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp ensure_fake_s3! do
    if Process.whereis(SalixStore.S3.Fake) do
      SalixStore.S3.Fake.reset()
    else
      start_supervised!(SalixStore.S3.Fake)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
  defp base, do: CommaWeb.Application.base_url()
end
