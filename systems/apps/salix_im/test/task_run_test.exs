defmodule SalixIM.TaskRunTest do
  @moduledoc """
  A person runs a Task that exists on another model, and so perhaps in another
  place (`SalixIM.TaskRun`): the station that runs it now is asked first, the
  stations that ran it leave it, and the Task's owner records the place and
  the Worker participant and tells the Worker. The Task is real; the stations
  and the product's checks answer as the test says.
  """
  use SystemsClock.Case, async: false
  use SalixAgent.TestSupport.Settle

  alias SalixIM.{
    ConversationServer,
    ConversationSource,
    Conversations,
    TaskConversationInput,
    TaskRun
  }

  alias SalixStore.{Ids, Keys}

  defmodule Stations do
    @moduledoc "The stations (`SalixIM.Ports.TaskStations`): what they were asked, and how they answer."
    @behaviour SalixIM.Ports.TaskStations
    use Agent

    def start_link(_),
      do:
        SystemsRuntime.Agent.start_link(
          fn -> %{invite: {:ok, "ember:c-1"}, sessions: %{}, asked: []} end,
          name: __MODULE__
        )

    def answer(key, value), do: SystemsRuntime.Agent.update(__MODULE__, &Map.put(&1, key, value))
    def asked, do: SystemsRuntime.Agent.get(__MODULE__, &Enum.reverse(&1.asked))

    defp ask(request, answer),
      do:
        SystemsRuntime.Agent.get_and_update(__MODULE__, fn state ->
          {answer.(state), %{state | asked: [request | state.asked]}}
        end)

    @impl true
    def invite(invitation), do: ask({:invite, invitation}, & &1.invite)

    @impl true
    def joined(row), do: ask({:joined, row}, fn _ -> :ok end)

    @impl true
    def moved(move), do: ask({:moved, move}, fn _ -> :ok end)

    @impl true
    def sessions(_group_id, _conversation_id),
      do: {:ok, SystemsRuntime.Agent.get(__MODULE__, & &1.sessions)}

    @impl true
    def sandbox(reservation), do: ask({:sandbox, reservation}, fn _ -> :ok end)

    @impl true
    def task_status(_group_id, _conversation_id, _status), do: :ok

    @impl true
    def appended(_group_id, _conversation_id), do: :ok

    @impl true
    def standing(_group_id, _conversation_id), do: :not_station

    @impl true
    def session_status(_group_id, _conversation_id), do: :unknown
  end

  defmodule BusyWorker do
    @moduledoc "A Worker's Session in the middle of a turn (`SalixIM.Ports.SessionActivity`)."
    @behaviour SalixIM.Ports.SessionActivity

    @impl true
    def get(_agent_id, _session_id), do: {:ok, %{"state" => "active", "status" => "is working"}}

    @impl true
    def subscribe(_agent_id, _session_id), do: :ok

    @impl true
    def unsubscribe(_agent_id, _session_id), do: :ok
  end

  defmodule Product do
    @moduledoc "The product's checks of a place and a model (`SalixIM.Ports.TaskCreate`): each taken as asked."
    @behaviour SalixIM.Ports.TaskCreate

    @impl true
    def create_task_conversation(_group_id, _delegator, _target, _attrs), do: {:error, :unused}

    @impl true
    def runs_on(_scope, %{"kind" => "cloud_vm"}),
      do: {:ok, %{"kind" => "cloud_vm", "device_id" => "dev-cloud-vm"}}

    def runs_on(_scope, request), do: {:ok, request}

    @impl true
    def session_model(_scope, choice), do: {:ok, choice}
  end

  @switched TaskRun.message_type()
  @catalog %{"kind" => "catalog", "model" => "claude-opus-5-5", "allow_paid" => true}

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
    SalixAgent.TestSupport.create_control_group!(group_id, %{"name" => "Task run"})

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

  test "a Task on a station that cannot start runs inside Salix: its Worker takes it up with the model chosen",
       ctx do
    {conversation_id, worker} = start_task(ctx, "on-station", %{"device_id" => "dev-a"})
    session_id = worker["payload"]["session_id"]
    Stations.answer(:sessions, %{"dev-a" => "ember:c-1"})

    assert {:ok, record} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => %{"kind" => "salix"}, "model" => @catalog},
               "usr_ann"
             )

    refute Map.has_key?(record, "runs_on")

    # No station is asked to run it; the one that ran it leaves.
    assert Stations.asked() == [
             {:moved, %{group_id: ctx.group_id, conversation_id: conversation_id, to: nil}}
           ]

    worker = worker(ctx, conversation_id)
    refute TaskConversationInput.station_worker?(worker)
    assert worker["notification_filter"]["messages"] == "all"
    # A new Session, made with the model chosen: a Session takes its model when it is made.
    assert %{"session_id" => new_session, "session_model" => @catalog} = worker["payload"]
    refute new_session == session_id

    # The Worker is told, and only it.
    assert [notice] = messages_of_type(ctx, conversation_id, @switched)
    assert notice["delivery_filter"]["participant_ids"] == [worker["participant_id"]]
    assert notice["metadata"][@switched]["by_user_id"] == "usr_ann"
    assert text(notice["content"]) =~ "read its earlier Messages first"

    # The Worker's source reads the Task from its start: the command, then the notice, both to it.
    {:ok, conversation} = Conversations.get_group_conversation(ctx.group_id, conversation_id)
    source = ConversationSource.agent_source(conversation, worker)
    assert {:ok, binding} = ConversationSource.binding(ctx.worker_id, source)
    assert {:ok, _binding, messages} = ConversationSource.batch(binding, nil)

    assert [command, ^notice] =
             Enum.filter(messages, &ConversationSource.target?(binding.participant, &1))

    assert text(command["content"]) == "Summarize the thread and report back."
  end

  test "a Task inside Salix runs on a station: the station is asked first, then takes part, and the Worker is delivered nothing",
       ctx do
    {conversation_id, _worker} = start_task(ctx, "inside-salix", nil)
    model = %{"kind" => "runtime", "provider" => "codex", "model" => "gpt-5.5"}
    place = %{"kind" => "station", "device_id" => "dev-b"}

    assert {:ok, %{"runs_on" => ^place}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => place, "model" => model},
               "usr_ann"
             )

    start = TaskConversationInput.station_start(ctx.worker_id, model)
    assert %{"runtime" => "codex", "model" => "gpt-5.5"} = start

    assert [
             {:invite, %{device_id: "dev-b", start: ^start, replace: false}},
             {:moved, %{to: %{device_id: "dev-b", session: "ember:c-1", start: ^start}}}
           ] = Stations.asked()

    worker = worker(ctx, conversation_id)
    assert TaskConversationInput.station_worker?(worker)
    refute Map.has_key?(worker["payload"], "session_model")
    assert [_notice] = messages_of_type(ctx, conversation_id, @switched)
  end

  test "a Task switched onto the Group's Cloud VM while it sleeps moves there: its station is expected",
       ctx do
    {conversation_id, _worker} = start_task(ctx, "to-sleeping-vm", nil)
    Stations.answer(:invite, {:ok, :when_connected})
    model = %{"kind" => "runtime", "provider" => "codex"}
    place = %{"kind" => "station", "device_id" => "dev-vm"}

    assert {:ok, %{"runs_on" => ^place}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => place, "model" => model},
               "usr_ann"
             )

    assert [
             {:invite, %{device_id: "dev-vm", replace: false}},
             {:moved, %{to: %{device_id: "dev-vm", session: nil, start: %{"runtime" => "codex"}}}}
           ] = Stations.asked()

    assert TaskConversationInput.station_worker?(worker(ctx, conversation_id))
  end

  test "another model on the station that runs the Task replaces its Session; a station that keeps it refuses",
       ctx do
    {conversation_id, _worker} = start_task(ctx, "same-station", %{"device_id" => "dev-a"})
    Stations.answer(:sessions, %{"dev-a" => "ember:c-1"})
    place = %{"kind" => "station", "device_id" => "dev-a"}
    claude = %{"kind" => "runtime", "provider" => "claude"}

    # A station from before `replace` answers with the Session it had: nothing changes.
    assert {:error, {:station, :station_outdated}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => place, "model" => claude},
               "usr_ann"
             )

    assert [{:invite, %{replace: true}}] = Stations.asked()
    assert messages_of_type(ctx, conversation_id, @switched) == []

    Stations.answer(:invite, {:ok, "ember:c-2"})

    assert {:ok, %{"runs_on" => ^place}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => place, "model" => claude},
               "usr_ann"
             )

    assert [_old, {:invite, %{replace: true}}, {:moved, %{to: %{session: "ember:c-2"}}}] =
             Stations.asked()

    assert [_notice] = messages_of_type(ctx, conversation_id, @switched)
  end

  test "a station that does not take the Task, or a place not named, changes nothing", ctx do
    {conversation_id, before} = start_task(ctx, "refused", %{"device_id" => "dev-a"})
    Stations.answer(:sessions, %{"dev-a" => "ember:c-1"})
    Stations.answer(:invite, {:error, {:station_refused, "no account is chosen to run Codex"}})

    assert {:error, {:station, {:station_refused, "no account is chosen to run Codex"}}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{
                 "runs_on" => %{"kind" => "station", "device_id" => "dev-c"},
                 "model" => %{"kind" => "runtime", "provider" => "codex"}
               },
               "usr_ann"
             )

    assert {:error, {:bad_request, _}} =
             TaskRun.switch(ctx.group_id, conversation_id, %{"model" => @catalog}, "usr_ann")

    # A runtime model inside Salix is refused as a new Task's would be.
    assert {:error, {:placement, {:model, :runtime_requires_runs_on}}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{
                 "runs_on" => %{"kind" => "salix"},
                 "model" => %{"kind" => "runtime", "provider" => "codex"}
               },
               "usr_ann"
             )

    assert [{:invite, %{device_id: "dev-c"}}] = Stations.asked()
    assert worker(ctx, conversation_id) == before

    assert {:ok, %{"runs_on" => %{"device_id" => "dev-a"}}} =
             Conversations.get_group_conversation(ctx.group_id, conversation_id)

    assert messages_of_type(ctx, conversation_id, @switched) == []
  end

  test "another model inside Salix: a new Session made with it reads the Task from its start",
       ctx do
    {conversation_id, worker} = start_task(ctx, "salix-to-salix", nil)
    old_session = worker["payload"]["session_id"]

    assert {:ok, _record} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => %{"kind" => "salix"}, "model" => @catalog},
               "usr_ann"
             )

    assert Stations.asked() == []
    worker = worker(ctx, conversation_id)
    assert %{"session_id" => session_id, "session_model" => @catalog} = worker["payload"]
    refute session_id == old_session

    {:ok, conversation} = Conversations.get_group_conversation(ctx.group_id, conversation_id)
    source = ConversationSource.agent_source(conversation, worker)

    assert {:ok, %{session_id: ^session_id} = binding} =
             ConversationSource.binding(ctx.worker_id, source)

    assert {:ok, _binding, messages} = ConversationSource.batch(binding, nil)

    assert [command, notice] =
             Enum.filter(messages, &ConversationSource.target?(binding.participant, &1))

    assert text(command["content"]) == "Summarize the thread and report back."
    assert notice["metadata"]["message_type"] == @switched

    # What the Worker is delivered makes the new Session with the model chosen.
    assert {:ok, %{payload: payload}} = ConversationSource.entry(binding, notice)
    assert %{session_id: ^session_id, model: @catalog} = payload
  end

  test "a Worker inside Salix in the middle of a turn refuses the switch: two models never write at once",
       ctx do
    {conversation_id, before} = start_task(ctx, "mid-turn", nil)
    SystemsRuntime.put_env(:salix_im, :session_activity_mod, BusyWorker)

    assert {:error, {:station, :task_running}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{
                 "runs_on" => %{"kind" => "station", "device_id" => "dev-b"},
                 "model" => %{"kind" => "runtime", "provider" => "codex"}
               },
               "usr_ann"
             )

    assert Stations.asked() == []
    assert worker(ctx, conversation_id) == before
    assert messages_of_type(ctx, conversation_id, @switched) == []
  end

  test "a coding Task stays on its sandbox", ctx do
    {conversation_id, _worker} =
      start_task(ctx, "coding", nil, %{
        "runs_on" => %{"kind" => "sandbox"},
        "repo" => %{"owner" => "afk-surf", "name" => "cue"}
      })

    assert {:error, {:bad_request, "a coding Task runs on its own sandbox" <> _}} =
             TaskRun.switch(
               ctx.group_id,
               conversation_id,
               %{"runs_on" => %{"kind" => "salix"}, "model" => @catalog},
               "usr_ann"
             )

    assert Stations.asked() == []
  end

  defp start_task(ctx, request_id, station, extra \\ %{}) do
    command = "Summarize the thread and report back."

    attrs =
      %{
        "content" => command,
        "client_request_id" => request_id,
        "schedule" => %{"schedule_id" => nil, "command" => command},
        "initial_message_attrs" => %{
          "kind" => "message",
          "actor_type" => "agent",
          "agent_id" => ctx.router_id,
          "content" => command,
          "metadata" => %{"message_type" => "task_command"},
          "client_request_id" => "delegate-" <> request_id
        }
      }
      |> then(fn attrs ->
        if station,
          do: Map.put(attrs, "runs_on", Map.put(station, "kind", "station")),
          else: attrs
      end)
      |> Map.merge(extra)

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
    # What creating it asked of the stations is not what the switch asks.
    Stations.answer(:asked, [])
    {conversation_id, worker(ctx, conversation_id)}
  end

  defp worker(ctx, conversation_id) do
    assert {:ok, %{"participants" => participants}} =
             Conversations.list_group_conversation_participants(ctx.group_id, conversation_id)

    Enum.find(participants, &(&1["agent_id"] == ctx.worker_id))
  end

  defp messages_of_type(ctx, conversation_id, type) do
    assert {:ok, messages} =
             Conversations.list_group_conversation_messages(ctx.group_id, conversation_id,
               limit: 20
             )

    Enum.filter(messages, &(get_in(&1, ["metadata", "message_type"]) == type))
  end

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content),
    do: content |> Enum.map(&(&1["text"] || "")) |> Enum.join("\n")
end
