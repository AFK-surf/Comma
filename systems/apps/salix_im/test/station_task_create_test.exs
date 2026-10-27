defmodule SalixIM.StationTaskCreateTest do
  @moduledoc """
  Making a Task that runs on a station (`SalixIM.TaskConversationInput`): the
  station is asked before the Task is made (`SalixIM.Ports.TaskStations`). A
  station that cannot take it refuses the Task. The Group's Cloud VM that is
  not connected is the exception: the product answers `when_connected`, the
  Task is made, and the station joins it with no Session, to be invited when
  it connects. The port answers as the test says; the Task is real.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{ConversationServer, Conversations, TaskConversationInput}
  alias SalixStore.{Ids, Keys}

  defmodule Stations do
    @moduledoc "The stations Tasks run on: what they are asked, and how they answer (`answer/1`)."
    @behaviour SalixIM.Ports.TaskStations
    use Agent

    def start_link(_),
      do: SystemsRuntime.Agent.start_link(fn -> {:ok, "ember:c-1"} end, name: __MODULE__)

    def answer(how), do: SystemsRuntime.Agent.update(__MODULE__, fn _ -> how end)

    defp tell(message),
      do:
        SystemsRuntime.Proc.send(
          SystemsRuntime.fetch_env!(:salix_im, :station_task_create_test_pid),
          message
        )

    @impl true
    def invite(invitation) do
      tell({:station_invite, invitation})
      SystemsRuntime.Agent.get(__MODULE__, & &1)
    end

    @impl true
    def joined(row) do
      tell({:station_joined, row})
      :ok
    end

    @impl true
    def appended(_group_id, _conversation_id), do: :ok

    @impl true
    def standing(_group_id, _conversation_id), do: :not_station

    @impl true
    def session_status(_group_id, _conversation_id), do: :unknown
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()
    SalixIM.TestSupport.Fleet.stop_all!()

    keys = [
      {:salix_store, :s3_backend, SalixStore.S3.Fake},
      {:salix_agent, :llm, SalixAgent.LLM.Mock},
      {:salix_im, :agent_delivery_mod, SalixIM.TestSupport.AgentDelivery},
      {:salix_im, :session_activity_mod, SalixIM.TestSupport.SessionActivity},
      {:salix_im, :task_stations_mod, Stations},
      {:salix_im, :station_task_create_test_pid, SystemsRuntime.Proc.self()}
    ]

    previous =
      Enum.map(keys, fn {app, key, _value} -> {app, key, SystemsRuntime.get_env(app, key)} end)

    Enum.each(keys, fn {app, key, value} -> SystemsRuntime.put_env(app, key, value) end)

    start_supervised!(SalixStore.S3.Fake)
    start_supervised!(SalixAgent.LLM.Mock)
    start_supervised!(Stations)

    on_exit(fn ->
      try do
        SalixAgent.TestSupport.stop_all_agents()
        SalixIM.TestSupport.Fleet.stop_all!()
      after
        Enum.each(previous, fn
          {app, key, nil} -> SystemsRuntime.delete_env(app, key)
          {app, key, value} -> SystemsRuntime.put_env(app, key, value)
        end)
      end
    end)

    tenant_id = SalixAgent.TestSupport.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Station Task create"})

    router =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Router",
        "role" => "router"
      })

    worker =
      SalixAgent.TestSupport.create_control_agent_in_group!(tenant_id, group_id, %{
        "name" => "Worker",
        "role" => "worker"
      })

    {:ok, _group} =
      SalixStore.CasRecord.update(Keys.ctl_group(group_id), fn group ->
        Map.put(group, "router_agent_id", router["agent_id"])
      end)

    {:ok, group_id: group_id, router_id: router["agent_id"], worker_id: worker["agent_id"]}
  end

  test "a Task for the Group's Cloud VM that sleeps is made, its station expected; asked again, it is the same Task",
       ctx do
    vm = SalixStore.RuntimeIds.cloud_vm_device_id(ctx.group_id)
    Stations.answer({:ok, :when_connected})
    attrs = attrs("vm-asleep", %{"kind" => "cloud_vm", "device_id" => vm})

    assert {:ok, conversation_id} = reserve(ctx, attrs)

    assert {:ok, %{"conversation_id" => ^conversation_id, "inserted" => true}} =
             create(ctx, conversation_id, attrs)

    assert_received {:station_invite,
                     %{device_id: ^vm, conversation_id: ^conversation_id, start: start}}

    assert start == %{
             "requester" => ctx.worker_id <> "@agents.salix",
             "title" => ctx.worker_id,
             "runtime" => "codex"
           }

    # Expected in the Task with no Session: the product invites it when it connects.
    assert_received {:station_joined,
                     %{
                       device_id: ^vm,
                       conversation_id: ^conversation_id,
                       session: nil,
                       start: ^start
                     }}

    assert {:ok, %{"runs_on" => %{"kind" => "cloud_vm", "device_id" => ^vm}}} =
             Conversations.get_group_conversation(ctx.group_id, conversation_id)

    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group_id, conversation_id)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker_id))
    assert TaskConversationInput.station_worker?(worker)

    # The same create again: the same Task, expected once more (the product adds nothing).
    assert {:ok, %{"conversation_id" => ^conversation_id, "inserted" => false}} =
             create(ctx, conversation_id, attrs)

    assert_received {:station_joined, %{conversation_id: ^conversation_id, session: nil}}

    assert {:ok, [_command]} =
             Conversations.list_group_conversation_messages(ctx.group_id, conversation_id,
               limit: 10
             )
  end

  test "a person's station that is not connected refuses the Task, and nothing is made", ctx do
    laptop = "dev-laptop-#{SystemsRuntime.Proc.unique_integer([:positive])}"
    Stations.answer({:error, :device_offline})
    attrs = attrs("laptop-offline", %{"kind" => "station", "device_id" => laptop})
    assert {:ok, conversation_id} = reserve(ctx, attrs)

    assert {:error, {:bad_request, "that station is not connected now; the Task was not made"}} =
             create(ctx, conversation_id, attrs)

    assert_received {:station_invite, %{device_id: ^laptop}}
    refute_received {:station_joined, _row}

    assert {:error, :not_found} =
             Conversations.get_group_conversation(ctx.group_id, conversation_id)
  end

  defp attrs(request_id, runs_on) do
    command = "Summarize the thread and report back."

    %{
      "content" => command,
      "client_request_id" => request_id,
      "schedule" => %{"schedule_id" => nil, "command" => command},
      "runs_on" => runs_on,
      "session_model" => %{"kind" => "runtime", "provider" => "codex"},
      "initial_message_attrs" => %{
        "kind" => "message",
        "actor_type" => "agent",
        "content" => command,
        "metadata" => %{"message_type" => "task_command"},
        "client_request_id" => "delegate-" <> request_id,
        "created_at" => SystemsClock.system_time(:millisecond)
      }
    }
  end

  defp reserve(ctx, attrs),
    do:
      ConversationServer.reserve_task_conversation_id(
        ctx.group_id,
        ctx.router_id,
        ctx.worker_id,
        put_in(attrs, ["initial_message_attrs", "agent_id"], ctx.router_id)
      )

  defp create(ctx, conversation_id, attrs),
    do:
      TaskConversationInput.create_with_id(
        ctx.group_id,
        conversation_id,
        ctx.router_id,
        ctx.worker_id,
        put_in(attrs, ["initial_message_attrs", "agent_id"], ctx.router_id)
      )
end
