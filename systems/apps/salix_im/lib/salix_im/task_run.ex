defmodule SalixIM.TaskRun do
  @moduledoc """
  A member of the Group runs a Task that exists on another model, and so
  perhaps in another place: inside Salix, on the Group's Cloud VM, or on a
  station (`runs_on`). Its products offer it where the Task's model cannot
  start (a station's `task_run_blocked` Message, `SalixWeb.StationTasks`) and
  on the Task's panel.

  The new place and model are checked as a new Task's are
  (`SalixIM.TaskPlacement.resolve/4`): the place is named, never the Group's
  default; with no model, a Task inside Salix runs the Group's default Task
  model and a station its runtime's default. Then, in order, each step
  failing leaves what follows undone:

    0. A Worker inside Salix in the middle of a turn refuses the switch
       (`:task_running`): it would go on writing beside the new model. A
       station's Session in a turn is stopped by its station when it leaves.
    1. A station that runs the Task now is asked first (`task.invite`): one
       that cannot (not connected, no such model, no account for it there)
       refuses the switch, and nothing changes. A station that ran the Task
       already starts a new Session in place of the old one (`replace`); a
       station too old to do so answers with the Session it had, and the switch
       is refused.
    2. The stations that ran the Task leave it (`SalixIM.Ports.TaskStations`
       `moved/1`, told with `task.leave`), and the new one takes part.
    3. The Task's owner records where it runs (`runs_on`, nil inside Salix)
       and its Worker participant: delivered Messages and given the model
       inside Salix, delivered nothing on a station
       (`SalixIM.TaskConversationInput.station_worker?/1`). It writes a
       `task_run_switched` Message to the Worker, which takes the Task up: a
       Worker inside Salix reads the Task from its start, as it always does; a
       station's new Session is given the Task from its start, and handed what
       its station had not answered.

  The Task keeps its id, Messages, labels, status and Router.
  """

  alias SalixIM.{ConversationParticipantActivity, ConversationServer, ConversationSource}
  alias SalixIM.{Conversations, GroupDirectory}
  alias SalixIM.{TaskConversationInput, TaskLoop, TaskPlacement}
  alias SalixIM.Ports.TaskStations

  @message_type "task_run_switched"

  @doc "The `message_type` of the Message a switch writes to the Worker."
  def message_type, do: @message_type

  @doc """
  Run Task `conversation_id` of Group `group_id` where `params` says
  (`"runs_on"`: `{kind: salix}`, `{kind: cloud_vm}` or `{kind: station,
  device_id}`) with its `"model"` (a Model Choice, or nil for the default),
  as `user_id` asks. Answers the Task record, or why not: a refusal of
  `SalixIM.TaskPlacement` (`{:placement, refusal}`), `{:station, reason}`
  when the station did not take it, or an error of the reads.
  """
  @spec switch(String.t(), String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def switch(group_id, conversation_id, params, user_id) when is_map(params) do
    with {:ok, conversation} <- task(group_id, conversation_id),
         {:ok, runs_on} <- requested_place(params["runs_on"]),
         {:ok, group} <- GroupDirectory.get_group(group_id),
         scope = %{tenant_id: group["tenant_id"], group_id: group_id},
         worker_agent_id = conversation["task_worker_agent_id"],
         {:ok, worker} <- worker(group_id, conversation_id, worker_agent_id),
         {:ok, placement} <- placement(scope, conversation, worker_agent_id, runs_on, params),
         :ok <- not_mid_turn(group_id, conversation_id, worker),
         {:ok, stations} <- TaskStations.sessions(group_id, conversation_id),
         {:ok, to} <- invite(scope, conversation_id, worker_agent_id, placement, stations),
         :ok <- moved(group_id, conversation_id, stations, to) do
      ConversationServer.switch_task_run(group_id, conversation_id, %{
        "runs_on" => placement.runs_on,
        "worker" => desired_worker(worker, placement, group),
        "notice" => notice(placement, user_id)
      })
    end
  end

  def switch(_group_id, _conversation_id, _params, _user_id),
    do: {:error, {:bad_request, "runs_on and model are required"}}

  defp task(group_id, conversation_id) do
    case Conversations.get_group_conversation(group_id, conversation_id) do
      # A coding Task runs on the sandbox made for its repository: it moves nowhere.
      {:ok, %{"kind" => "agent_task", "runs_on" => %{"kind" => "sandbox"}}} ->
        {:error,
         {:bad_request, "a coding Task runs on its own sandbox; its model is not switched"}}

      {:ok, %{"kind" => "agent_task", "task_worker_agent_id" => worker} = conversation}
      when is_binary(worker) and worker != "" ->
        {:ok, conversation}

      {:ok, _not_a_task} ->
        {:error, :not_found}

      {:error, _reason} = error ->
        error
    end
  end

  # The place is always named: a switch never falls to the Group's default.
  defp requested_place(%{"kind" => "salix"} = place) when map_size(place) == 1, do: {:ok, place}

  defp requested_place(%{"kind" => "cloud_vm"} = place) when map_size(place) == 1,
    do: {:ok, place}

  defp requested_place(%{"kind" => "station", "device_id" => device} = place)
       when map_size(place) == 2 and is_binary(device) and device != "",
       do: {:ok, place}

  defp requested_place(_place),
    do:
      {:error,
       {:bad_request,
        "runs_on must be {kind: salix}, {kind: cloud_vm} or {kind: station, device_id}"}}

  defp worker(group_id, conversation_id, agent_id) do
    with {:ok, %{"participant_id" => participant_id}} <-
           ConversationServer.get_group_conversation_agent_participant_identity(
             group_id,
             conversation_id,
             agent_id
           ),
         {:ok, %{"state" => "active"} = participant} <-
           Conversations.get_group_conversation_participant(
             group_id,
             conversation_id,
             participant_id
           ) do
      {:ok, participant}
    else
      {:ok, _inactive} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  # A Worker inside Salix that is in a turn would go on writing into the Task
  # beside the new model: the switch waits for the turn to end. A station's
  # Session in a turn is stopped by its station instead (`task.leave`, or
  # `replace`). A status that cannot be read is no turn.
  defp not_mid_turn(group_id, conversation_id, worker) do
    with true <- ConversationSource.receives_messages?(worker),
         {:ok, %{"activity" => %{"state" => "active"}}} <-
           ConversationParticipantActivity.read(
             group_id,
             conversation_id,
             worker["participant_id"],
             worker
           ) do
      {:error, {:station, :task_running}}
    else
      _idle -> :ok
    end
  end

  defp placement(scope, conversation, worker_agent_id, runs_on, params) do
    case TaskPlacement.resolve(
           scope,
           worker_agent_id,
           %{"runs_on" => runs_on, "model" => params["model"]},
           TaskLoop.loop_runs?(conversation)
         ) do
      {:ok, placement} -> {:ok, placement}
      {:error, refusal} -> {:error, {:placement, refusal}}
    end
  end

  # The station that runs the Task now is asked first; one that ran it
  # already replaces its Session. Inside Salix, no station is asked.
  defp invite(_scope, _conversation_id, _worker_agent_id, %{runs_on: nil}, _stations),
    do: {:ok, nil}

  defp invite(scope, conversation_id, worker_agent_id, placement, stations) do
    device = placement.runs_on["device_id"]
    start = TaskConversationInput.station_start(worker_agent_id, placement.session_model)
    before = Map.get(stations, device)

    case TaskStations.invite(%{
           tenant_id: scope.tenant_id,
           group_id: scope.group_id,
           conversation_id: conversation_id,
           device_id: device,
           start: start,
           replace: not is_nil(before)
         }) do
      # A station from before `replace` keeps its Session: it would run the
      # old model on, so nothing changes.
      {:ok, ^before} when is_binary(before) ->
        {:error, {:station, :station_outdated}}

      # The Group's Cloud VM is not up: the Task moves to it all the same, its
      # station expected and invited once the VM is ready (`joined/1`).
      {:ok, :when_connected} ->
        {:ok, to(scope, conversation_id, device, nil, worker_agent_id, start)}

      {:ok, session} ->
        {:ok, to(scope, conversation_id, device, session, worker_agent_id, start)}

      {:error, reason} ->
        {:error, {:station, reason}}
    end
  end

  defp to(scope, conversation_id, device, session, worker_agent_id, start) do
    %{
      tenant_id: scope.tenant_id,
      group_id: scope.group_id,
      conversation_id: conversation_id,
      device_id: device,
      session: session,
      agent_id: worker_agent_id,
      start: start
    }
  end

  # No station took part or takes part now: nothing to move.
  defp moved(_group_id, _conversation_id, stations, nil) when map_size(stations) == 0, do: :ok

  defp moved(group_id, conversation_id, _stations, to),
    do: TaskStations.moved(%{group_id: group_id, conversation_id: conversation_id, to: to})

  # The Worker participant as it is from now on: inside Salix delivered the
  # Task's Messages in a new Session made with its model (the Group's default
  # Task model when none is named); on a station delivered nothing, its
  # Session id kept.
  defp desired_worker(worker, placement, group) do
    base = %{"session_id" => get_in(worker, ["payload", "session_id"])}

    {filter, payload} =
      case placement.runs_on do
        nil ->
          model = placement.session_model || TaskConversationInput.default_task_model(group)
          # A Session takes its model when it is made, so the Worker gets a new
          # one: it reads the Task from its source start, the old one is
          # delivered nothing more.
          new = %{"session_id" => SalixStore.Ids.new_session_id()}

          {%{"messages" => "all", "statuses" => "none"},
           if(is_map(model), do: Map.put(new, "session_model", model), else: new)}

        %{} ->
          {TaskConversationInput.station_worker_filter(), base}
      end

    worker
    |> Map.take(["agent_id", "role_label", "agent_name"])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.merge(%{"state" => "active", "notification_filter" => filter, "payload" => payload})
  end

  # What the Worker is told, and people see in the Task: who switched it, and
  # that the earlier Messages are the Task so far.
  defp notice(placement, user_id) do
    %{
      "idempotency_key" => "task-run:" <> SalixStore.Ids.new_message_id(),
      "role_label" => "runtime",
      "content" =>
        "A person switched this Task to run on #{place_words(placement.runs_on)} with " <>
          "#{model_words(placement)}. You take the Task over from here: read its earlier " <>
          "Messages first (they are the Task so far, including what was said before the switch), " <>
          "then go on with what was asked and not yet answered.",
      "metadata" => %{
        "message_type" => @message_type,
        @message_type => %{"runs_on" => placement.runs_on, "by_user_id" => user_id}
      }
    }
  end

  defp place_words(nil), do: "Comma's own servers"
  defp place_words(%{"kind" => "cloud_vm"}), do: "the workspace's Cloud VM"
  defp place_words(%{"device_id" => device}), do: "the computer #{device}"

  defp model_words(%{session_model: %{"model" => model}}) when is_binary(model),
    do: "the model #{model}"

  defp model_words(%{session_model: %{"kind" => "platform"}}), do: "Comma's own model"

  defp model_words(%{session_model: %{"provider" => runtime}}),
    do: "#{runtime}'s default model"

  defp model_words(%{runs_on: nil}), do: "the workspace's default Task model"
  defp model_words(_placement), do: "the station's default model"
end
