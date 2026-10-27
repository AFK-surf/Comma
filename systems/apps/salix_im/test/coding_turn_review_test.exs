defmodule SalixIM.CodingTurnReviewTest do
  @moduledoc """
  A coding Task goes into review once its sandbox Session ends a turn
  (`SalixIM.ConversationServer.coding_turn_ended/3`), with no Router turn: the
  Task is real; the stations answer as the test says.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{ConversationServer, Conversations, TaskConversationInput}
  alias SalixStore.{Ids, Keys}

  defmodule Stations do
    @moduledoc "The stations (`SalixIM.Ports.TaskStations`): the statuses they were told."
    @behaviour SalixIM.Ports.TaskStations
    use Agent

    def start_link(_), do: SystemsRuntime.Agent.start_link(fn -> [] end, name: __MODULE__)
    def told, do: SystemsRuntime.Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def invite(_invitation), do: {:ok, "ember:c-1"}

    @impl true
    def joined(_row), do: :ok

    @impl true
    def moved(_move), do: :ok

    @impl true
    def sessions(_group_id, _conversation_id), do: {:ok, %{}}

    @impl true
    def sandbox(_reservation), do: :ok

    @impl true
    def task_status(_group_id, conversation_id, status),
      do: SystemsRuntime.Agent.update(__MODULE__, &[{conversation_id, status} | &1])

    @impl true
    def appended(_group_id, _conversation_id), do: :ok

    @impl true
    def standing(_group_id, _conversation_id), do: :not_station

    @impl true
    def session_status(_group_id, _conversation_id), do: :unknown
  end

  defmodule Product do
    @moduledoc "The product's checks of a place and a model (`SalixIM.Ports.TaskCreate`): each taken as asked."
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, _delegator, _target, _attrs), do: {:error, :unused}

    @impl true
    def runs_on(_scope, request), do: {:ok, request}

    @impl true
    def session_model(_scope, choice), do: {:ok, choice}
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
      {:salix_im, :task_create_mod, Product}
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
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Coding"})

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

  test "a coding Task is in review once its sandbox Session's turn ends, and its sandbox is told",
       ctx do
    task = start_task(ctx, "coding", %{"kind" => "sandbox"})
    seq = reply(ctx, task, "r1")

    assert {:ok, "ready_for_review"} =
             ConversationServer.coding_turn_ended(ctx.group_id, task, seq)

    assert status(ctx, task) == "ready_for_review"
    assert {task, "ready_for_review"} in Stations.told()

    # Told again (the station posts again), nothing changes.
    assert {:ok, "ready_for_review"} =
             ConversationServer.coding_turn_ended(ctx.group_id, task, seq)
  end

  test "a Message for the Worker of a coding Task in review makes it active again; its own does not",
       ctx do
    task = start_task(ctx, "reopen", %{"kind" => "sandbox"})
    seq = reply(ctx, task, "r1")

    assert {:ok, "ready_for_review"} =
             ConversationServer.coding_turn_ended(ctx.group_id, task, seq)

    reply(ctx, task, "r2")
    assert status(ctx, task) == "ready_for_review"

    follow_up(ctx, task)
    assert status(ctx, task) == "active"
    assert {task, "active"} in Stations.told()
  end

  test "a follow-up after the Message that ended the turn keeps the coding Task active", ctx do
    task = start_task(ctx, "follow-up", %{"kind" => "sandbox"})
    seq = reply(ctx, task, "r1")

    follow_up(ctx, task)

    assert {:ok, "active"} = ConversationServer.coding_turn_ended(ctx.group_id, task, seq)
    assert status(ctx, task) == "active"
  end

  test "a Task that runs on a person's station stays active when a turn ends", ctx do
    task = start_task(ctx, "station", %{"kind" => "station", "device_id" => "dev-a"})
    seq = reply(ctx, task, "r1")

    assert {:ok, "active"} = ConversationServer.coding_turn_ended(ctx.group_id, task, seq)
    assert status(ctx, task) == "active"
  end

  defp start_task(ctx, request_id, runs_on) do
    command = "Fix the failing test."

    attrs = %{
      "content" => command,
      "client_request_id" => request_id,
      "schedule" => %{"schedule_id" => nil, "command" => command},
      "runs_on" => runs_on,
      "repo" => %{"owner" => "afk-surf", "name" => "cue"},
      "initial_message_attrs" => %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => ctx.router_id,
        "content" => command,
        "metadata" => %{"message_type" => "task_command"},
        "client_request_id" => "delegate-" <> request_id
      }
    }

    assert {:ok, conversation_id} =
             ConversationServer.reserve_task_conversation_id(
               ctx.group_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    assert {:ok, %{"conversation_id" => ^conversation_id}} =
             TaskConversationInput.create_with_id(
               ctx.group_id,
               conversation_id,
               ctx.router_id,
               ctx.worker_id,
               attrs
             )

    settle()
    conversation_id
  end

  # The Worker's Message, as its station posts it: its seq.
  defp reply(ctx, task, key) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group_id, task)

    worker = Enum.find(participants, &(&1["agent_id"] == ctx.worker_id))

    assert {:ok, %{"seq" => seq}} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group_id,
               task,
               ctx.worker_id,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.worker_id,
                 "participant_id" => worker["participant_id"],
                 "content" => "done",
                 "client_request_id" => "station-task:" <> key
               }
             )

    seq
  end

  # The Router's follow-up in the Task.
  defp follow_up(ctx, task) do
    assert {:ok, _} =
             ConversationServer.append_group_conversation_agent_message(
               ctx.group_id,
               task,
               ctx.router_id,
               %{
                 "kind" => "message",
                 "actor_type" => "agent",
                 "agent_id" => ctx.router_id,
                 "content" => "also fix the docs",
                 "client_request_id" => "follow-up"
               }
             )
  end

  defp status(ctx, task) do
    assert {:ok, %{"status" => status}} = Conversations.get_group_conversation(ctx.group_id, task)
    status
  end
end
