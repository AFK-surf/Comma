defmodule SalixIM.TaskConversationInput do
  @moduledoc """
  Product input adapter for canonical Task conversations.

  It resolves group, agent, provenance, participant, and initial-message facts
  before sending the bounded Task materialization command through
  `ConversationServer`.
  """

  require Logger

  alias SalixIM.{
    ConversationInput,
    ConversationServer,
    Conversations,
    GroupDirectory,
    ProviderConversationInput
  }

  alias SalixStore.Ids

  # The Worker of a Task that runs on a station is delivered nothing: a
  # Session of that station writes as it (`SalixIM.Ports.TaskStations`).
  @station_worker_filter %{"messages" => "none", "statuses" => "none"}

  def create_with_id(
        group_id,
        conversation_id,
        delegator_agent_id,
        worker_agent_id,
        attrs,
        opts \\ []
      )
      when is_map(attrs) do
    attrs = attrs |> stringify() |> sandbox_place(conversation_id)
    schedule = attrs["schedule"]
    content = trim(attrs["content"])

    with true <- content != "",
         :ok <- validate_schedule(schedule, content),
         initial when is_map(initial) <- attrs["initial_message_attrs"],
         {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, delegator} <- task_agent(delegator_agent_id, group_id),
         {:ok, worker} <- worker_agent(worker_agent_id, group_id),
         source_refs <- stringify(attrs["source_refs"] || %{}),
         {:ok, investigation} <-
           SalixIM.Triage.Investigation.creation(
             group_id,
             delegator_agent_id,
             worker_agent_id,
             attrs
           ),
         :ok <- validate_parent_refs(group_id, source_refs),
         :ok <- request_loop(group, conversation_id, worker_agent_id, attrs["loop"]),
         initial = loop_command(initial, attrs["loop"]),
         {:ok, owner_user_id} <- owner_user_id(group_id, attrs, source_refs),
         now <- SystemsClock.system_time(:millisecond),
         conversation <-
           task_conversation(
             group_id,
             conversation_id,
             attrs["title"],
             worker,
             schedule,
             now,
             %{
               "created_by_agent_id" => delegator_agent_id,
               "owner_user_id" => owner_user_id,
               "source_refs" => source_refs,
               # Where the Task runs, resolved to a device: what a station Task
               # is still known to run on once its station left it.
               "runs_on" => attrs["runs_on"],
               # A coding Task's repository and session branch (`runs_on {kind:
               # sandbox}`).
               "repo" => attrs["repo"],
               # The Mini App a build Task makes (`SalixIM.TaskPlacement`): its
               # sandbox's station may deploy that app only.
               "mini_app" => attrs["mini_app"],
               "metadata" => stringify(attrs["conversation_metadata"] || %{}),
               "labels" => attrs["labels"],
               "latest_artifact" => attrs["latest_artifact"],
               "artifact_manifest" => attrs["artifact_manifest"]
             }
           ),
         {:ok, delegator_participant} <-
           task_agent_participant(
             group,
             conversation,
             delegator,
             "delegator",
             now,
             origin_session_id: attrs["origin_session_id"],
             notification_filter:
               cond do
                 investigation != nil -> %{"messages" => "none", "statuses" => "none"}
                 true -> %{"messages" => "all", "statuses" => "none"}
               end
           ),
         {:ok, worker_participant} <-
           task_agent_participant(
             group,
             conversation,
             worker,
             "worker",
             now,
             worker_participant_opts(attrs, group)
           ),
         {:ok, station_session} <-
           invite_station(
             group,
             conversation_id,
             worker,
             Map.put(attrs, "owner_user_id", owner_user_id)
           ),
         participants <-
           SalixIM.Triage.Investigation.result_participants(investigation, now) ++
             owner_participants(owner_user_id, now) ++
             personal_status_participants(group_id, now) ++
             origin_provider_participants(group_id, conversation_id, source_refs, now) ++
             [delegator_participant, worker_participant],
         {:ok, appended} <-
           ConversationServer.create_task(
             group_id,
             conversation_id,
             %{
               "conversation" => Map.put(conversation, "participants", participants),
               "worker_agent_id" => worker_agent_id,
               "delegator_agent_id" => delegator_agent_id,
               "initial_message" => initial,
               "initial_delivery" => Keyword.get(opts, :initial_delivery, :command)
             }
           ),
         :ok <- station_joined(group, conversation_id, worker, attrs, station_session) do
      observe_created_task(appended, group_id, conversation_id, now)

      {:ok,
       appended
       |> Map.merge(%{
         "conversation_id" => conversation["conversation_id"],
         "conversation_kind" => "agent_task",
         "worker_agent_id" => worker_agent_id,
         "schedule" => schedule
       })}
    else
      false -> {:error, {:bad_request, "task command and canonical identity are required"}}
      nil -> {:error, {:bad_request, "task conversation initial message is missing"}}
      {:error, _reason} = error -> error
    end
  end

  # A Loop Task's Loop is written, `pending`, before its Task and the command
  # that reaches the Worker (`SalixIM.TaskLoop`). Only a new Task requests
  # it: a repeated create of a Task that exists leaves its Loop alone.
  defp request_loop(_group, _conversation_id, _worker_agent_id, nil), do: :ok

  defp request_loop(group, conversation_id, worker_agent_id, %{} = request) do
    case Conversations.get_group_conversation(group["group_id"], conversation_id) do
      {:ok, _existing} ->
        :ok

      {:error, :not_found} ->
        scope = %{tenant_id: group["tenant_id"], group_id: group["group_id"]}

        case SalixIM.TaskLoop.request_loop(scope, worker_agent_id, conversation_id, request) do
          {:ok, _view} -> :ok
          {:error, reason} -> {:error, {:task_loop, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # The command carries its Loop request for the Worker's guidance.
  defp loop_command(initial, %{} = request), do: Map.put(initial, :task_loop_request, request)
  defp loop_command(initial, _request), do: initial

  # A Task that runs on a station (`runs_on`) is run by a Session of that
  # station, not by Salix: its Worker participant is delivered nothing and only
  # authors what that Session writes (`SalixIM.Ports.TaskStations`).
  defp worker_participant_opts(%{"runs_on" => %{"device_id" => _}}, _group),
    do: [notification_filter: @station_worker_filter]

  defp worker_participant_opts(attrs, group),
    do: [session_model: attrs["session_model"] || default_task_model(group)]

  @doc """
  The model a Task inside Salix runs when it names none: the Group's default
  Task model (`SalixAgent.TaskModel`, the Group record's
  `default_task_model`): a catalog choice or the platform model. A Group that
  has set none takes its product's default (a BridgeForTeams org's default
  Task model, `SalixIM.Ports.TaskCreate.default_task_model/1`); without one
  (nil) the Task runs its Worker's model. A Task created through any path (a
  Router, a product, a Schedule, a Slack thread) takes it, and it is not part
  of the create command, so a create asked again after the default changed is
  the same Task. A Task switched into Salix without a model takes it too
  (`SalixIM.TaskRun`).
  """
  def default_task_model(group) do
    case task_model(group["default_task_model"]) do
      nil -> product_task_model(group)
      choice -> choice
    end
  end

  defp product_task_model(%{"tenant_id" => tenant_id, "group_id" => group_id}) do
    case SalixIM.Ports.TaskCreate.default_task_model(%{tenant_id: tenant_id, group_id: group_id}) do
      {:ok, choice} ->
        task_model(choice)

      {:error, reason} ->
        Logger.warning("product default Task model unavailable: #{inspect(reason)}")
        nil
    end
  end

  defp product_task_model(_group), do: nil

  defp task_model(%{"kind" => "platform"} = choice)
       when choice == %{"kind" => "platform", "tier" => "worker"},
       do: choice

  defp task_model(%{"kind" => "catalog", "model" => model} = choice) when is_binary(model),
    do: choice

  defp task_model(_value), do: nil

  @doc "The notification filter of the Worker of a Task that runs on a station: delivered nothing."
  def station_worker_filter, do: @station_worker_filter

  @doc """
  Whether a Task's Worker participant is the one of a Task that runs on a
  station: the only Worker delivered nothing (`worker_participant_opts/2`).
  Its Session id names no Session Salix runs, so `SalixIM.TaskWorkerWatch`
  never hears it stop; `SalixIM.StationTaskWatch` watches such a Task instead.
  """
  def station_worker?(%{"actor_type" => "agent", "role_label" => "worker"} = participant),
    do: participant["notification_filter"] == @station_worker_filter

  def station_worker?(_participant), do: false

  # A coding Task's sandbox does not exist yet: it is reserved instead, and its
  # station is invited once it connects (`SalixIM.Ports.TaskStations.sandbox/1`).
  defp invite_station(
         group,
         conversation_id,
         worker,
         %{"runs_on" => %{"kind" => "sandbox", "device_id" => device_id}} = attrs
       ) do
    case SalixIM.Ports.TaskStations.sandbox(%{
           tenant_id: group["tenant_id"],
           group_id: group["group_id"],
           conversation_id: conversation_id,
           device_id: device_id,
           agent_id: worker["agent_id"],
           start:
             station_start(
               worker["agent_id"],
               attrs["session_model"],
               attrs["repo"],
               attrs["mini_app"]
             ),
           repo: attrs["repo"],
           account_id: attrs["account_id"],
           requester: attrs["owner_user_id"]
         }) do
      :ok ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:bad_request, "the sandbox was not reserved: #{inspect(reason)}"}}
    end
  end

  # The station is asked before the Task is made: one that cannot take it
  # (not connected, no such model) refuses the create, and nothing is written.
  # A create asked again asks again; the station keeps its first Session.
  # The Group's Cloud VM that is not connected now (it sleeps, or was never
  # made) is the one exception: the product wakes it, so the Task is made and
  # the station expected in it (`:when_connected`), invited and given the
  # Task once it connects (`station_joined/5`).
  defp invite_station(
         group,
         conversation_id,
         worker,
         %{"runs_on" => %{"device_id" => device_id}} = attrs
       ) do
    # An already joined Task owns its Session even while the Station is away.
    # The delivery path handles reconnect/catchup; a create replay starts none.
    joined =
      case SalixStore.StationTaskSessions.of_task(group["group_id"], conversation_id) do
        {:ok, rows} ->
          Enum.find(rows, &(&1.device_id == device_id and &1.agent_id == worker["agent_id"]))

        _ ->
          nil
      end

    if joined do
      {:ok, joined.session}
    else
      ask_station(group, conversation_id, worker, attrs)
    end
  end

  defp invite_station(_group, _conversation_id, _worker, _attrs), do: {:ok, nil}

  defp ask_station(
         group,
         conversation_id,
         worker,
         %{"runs_on" => %{"device_id" => device_id}} = attrs
       ) do
    case SalixIM.Ports.TaskStations.invite(%{
           tenant_id: group["tenant_id"],
           group_id: group["group_id"],
           conversation_id: conversation_id,
           device_id: device_id,
           start: station_start(worker["agent_id"], attrs["session_model"])
         }) do
      {:ok, session} when is_binary(session) ->
        {:ok, session}

      {:ok, :when_connected} ->
        {:ok, :when_connected}

      {:error, :device_offline} ->
        {:error, {:bad_request, "that station is not connected now; the Task was not made"}}

      {:error, {:station_refused, why}} ->
        {:error, {:bad_request, "the station did not take the Task: #{why}"}}

      {:error, _reason} = error ->
        error
    end
  end

  # A coding Task (`runs_on {kind: sandbox}`) runs on the device its sandboxes'
  # stations register as, the same for every sandbox, and works on a session
  # branch named after it unless the request named one.
  defp sandbox_place(%{"runs_on" => %{"kind" => "sandbox"}} = attrs, conversation_id) do
    repo = attrs["repo"] || %{}

    attrs
    |> Map.put("runs_on", %{
      "kind" => "sandbox",
      "device_id" => SalixStore.CodingSandboxes.device_id(conversation_id)
    })
    |> Map.put("repo", Map.put_new(repo, "branch", session_branch(conversation_id)))
  end

  defp sandbox_place(attrs, _conversation_id), do: attrs

  defp session_branch(conversation_id) do
    "comma/" <> (conversation_id |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(-10, 10))
  end

  @doc """
  What a station is asked to start the Session of a Task of Worker `agent_id`
  with (`task.invite`'s `start`), from the Task's runtime model choice. A
  coding Task's start names its repository, and a Mini App build's its app
  (`mini_app {app_id}`), which gives its Session the app tools. The station
  keeps the start with its Session, so an invite again carries them too.
  """
  def station_start(agent_id, session_model, repo \\ nil, mini_app \\ nil) do
    model = if is_map(session_model), do: session_model, else: %{}

    %{"requester" => agent_id <> "@agents.salix", "title" => agent_id}
    |> put_present("runtime", if(model["provider"] in ~w(claude codex), do: model["provider"]))
    |> put_present("model", model["model"])
    |> put_present("effort", model["reasoning_effort"])
    |> put_present("repo", repo)
    |> put_present("mini_app", mini_app)
  end

  defp station_joined(_group, _conversation_id, _worker, _attrs, nil), do: :ok

  # A station expected in the Task (`:when_connected`) joins it with no
  # Session: the product invites it when it connects.
  defp station_joined(
         group,
         conversation_id,
         worker,
         %{"runs_on" => %{"device_id" => device_id}} = attrs,
         session
       ),
       do:
         SalixIM.Ports.TaskStations.joined(%{
           tenant_id: group["tenant_id"],
           group_id: group["group_id"],
           conversation_id: conversation_id,
           device_id: device_id,
           session: if(session == :when_connected, do: nil, else: session),
           agent_id: worker["agent_id"],
           start: station_start(worker["agent_id"], attrs["session_model"])
         })

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp observe_created_task(%{"inserted" => true}, group_id, conversation_id, created_at) do
    case SystemsRuntime.get_env(:salix_im, :product_activity_observer) do
      nil -> :ok
      module -> module.task_created(group_id, conversation_id, created_at)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe_created_task(_, _, _, _), do: :ok

  @doc """
  Create the Task a Slack thread bound to a Worker or to Tasks makes, once:
  `materialization` is its title, command and creation time, fixed when the
  thread was bound. `opts[:session_model]` is the model the Slack connection
  binds its Tasks to; without one the Task runs the default Task model
  (`default_task_model/1`). The model is not part of the materialization: the
  Task made first keeps its model.
  """
  def ensure_with_id(group_id, conversation_id, worker_agent_id, materialization, opts \\ [])

  def ensure_with_id(
        group_id,
        conversation_id,
        worker_agent_id,
        %{"title" => title, "command" => command, "created_at" => created_at} = materialization,
        opts
      )
      when map_size(materialization) == 3 and is_binary(title) and is_binary(command) and
             is_integer(created_at) do
    with true <- Ids.valid_conversation_id?(conversation_id) and trim(title) != "",
         {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, worker} <- worker_agent(worker_agent_id, group_id),
         conversation <-
           task_conversation(
             group_id,
             conversation_id,
             title,
             worker,
             %{"schedule_id" => nil, "command" => command},
             created_at,
             %{"task_materialization" => materialization}
           ),
         {:ok, worker_participant} <-
           task_agent_participant(
             group,
             conversation,
             worker,
             "worker",
             created_at,
             notification_filter: %{"messages" => "all", "statuses" => "none"},
             session_model: opts[:session_model] || default_task_model(group)
           ),
         {:ok, result} <-
           ConversationServer.create_task(
             group_id,
             conversation_id,
             %{
               "conversation" =>
                 conversation
                 |> Map.put("participants", [worker_participant])
                 |> Map.delete("task_materialization"),
               "worker_agent_id" => worker_agent_id,
               "materialization" => materialization
             }
           ) do
      {:ok, result}
    else
      false -> task_conflict()
      {:error, _reason} = error -> error
    end
  end

  def ensure_with_id(_group_id, _conversation_id, _worker_agent_id, _materialization, _opts),
    do: {:error, {:bad_request, "invalid task materialization"}}

  defp task_conversation(group_id, conversation_id, title, worker, schedule, created_at, extras) do
    worker_name =
      case trim(worker["name"]) do
        "" -> trim(worker["agent_id"])
        name -> name
      end

    %{
      "agent_group_id" => group_id,
      "conversation_id" => conversation_id,
      "kind" => "agent_task",
      "title" => if(trim(title) == "", do: "Task for " <> worker_name, else: trim(title)),
      "status" => "active",
      "activity_status" => "idle",
      "schedule" => schedule,
      "created_at" => created_at,
      "updated_at" => created_at
    }
    |> Map.merge(extras)
    |> Map.reject(fn {_key, value} -> value in [nil, "", %{}] end)
  end

  defp task_agent(agent_id, group_id) do
    with {:ok, %{"group_id" => ^group_id} = agent} <- GroupDirectory.get_agent(agent_id) do
      {:ok, agent}
    else
      {:ok, _agent} -> {:error, {:bad_request, "task agent is outside the group"}}
      {:error, _reason} = error -> error
    end
  end

  defp worker_agent(agent_id, group_id) do
    with {:ok, agent} <- task_agent(agent_id, group_id),
         true <- agent["role"] != "router" do
      {:ok, agent}
    else
      false -> {:error, {:bad_request, "router cannot be a Task command target"}}
      {:error, _reason} = error -> error
    end
  end

  defp task_agent_participant(group, conversation, agent, role_label, now, opts) do
    notification_filter =
      Keyword.get(opts, :notification_filter, %{
        "messages" => "all",
        "statuses" => "none"
      })

    participant = %{
      "actor_type" => "agent",
      "agent_id" => agent["agent_id"],
      "agent_name" => agent["name"],
      "role_label" => role_label,
      "state" => "active",
      "notification_filter" => notification_filter,
      "created_at" => now,
      "updated_at" => now
    }

    ConversationInput.prepare_agent_for_create(
      group["group_id"],
      conversation,
      participant,
      opts
    )
  end

  defp owner_participants(value, now) when is_binary(value) and value != "" do
    [
      %{
        "actor_type" => "user",
        "user_id" => value,
        "role_label" => "requester",
        "state" => "active",
        "notification_filter" => %{"messages" => "all", "statuses" => "none"},
        "created_at" => now,
        "updated_at" => now
      }
    ]
  end

  defp owner_participants(_value, _now), do: []

  # A Task the Router creates while answering a provider chat (a Linear agent
  # session) keeps that provider on it, so the Task's progress reaches the
  # place the request came from. The product adapter reads the parent
  # Conversation in `source_refs` and names the Participants; a lookup failure
  # never blocks creation.
  defp origin_provider_participants(group_id, conversation_id, source_refs, now) do
    with module when is_atom(module) and not is_nil(module) <-
           SystemsRuntime.get_env(:salix_im, :origin_provider_participants_adapter),
         participants when is_list(participants) <-
           module.task_participants(group_id, conversation_id, source_refs) do
      for participant <- participants, is_map(participant) do
        Map.merge(participant, %{"created_at" => now, "updated_at" => now})
      end
    else
      _ -> []
    end
  rescue
    error ->
      Logger.warning("Task origin provider participants unavailable",
        group_id: group_id,
        reason: Exception.message(error)
      )

      []
  end

  # The product adapter names the owner's bound personal chat, if any. Cards
  # are an accessory to the Task: a lookup failure never blocks its creation.
  defp personal_status_participants(group_id, now) do
    with module when is_atom(module) and not is_nil(module) <-
           SystemsRuntime.get_env(:salix_im, :task_status_personal_adapter),
         targets when is_list(targets) <- module.task_status_targets(group_id) do
      for target <- targets, is_map(target) do
        target
        |> ProviderConversationInput.provider_participant(%{
          "role_label" => "task_status_personal",
          "notification_filter" => %{
            "messages" => "none",
            # Intermediate states retire the previous attention card before re-entry.
            "statuses" => "all"
          }
        })
        |> Map.merge(%{"created_at" => now, "updated_at" => now})
      end
    else
      _ -> []
    end
  rescue
    error ->
      Logger.warning("Task status card destination unavailable",
        group_id: group_id,
        reason: Exception.message(error)
      )

      []
  end

  defp owner_user_id(group_id, attrs, source_refs) do
    case trim(attrs["owner_user_id"]) do
      "" ->
        case trim(source_refs["parent_conversation_id"]) do
          "" ->
            {:ok, nil}

          parent_id ->
            case Conversations.get_group_conversation(group_id, parent_id) do
              {:ok, parent} -> {:ok, blank_to_nil(parent["owner_user_id"])}
              {:error, _reason} = error -> error
            end
        end

      owner_user_id ->
        {:ok, owner_user_id}
    end
  end

  defp validate_parent_refs(group_id, source_refs) do
    parent_id = trim(source_refs["parent_conversation_id"])
    message_id = trim(source_refs["parent_message_id"])

    cond do
      parent_id == "" and message_id == "" ->
        :ok

      not Ids.valid_conversation_id?(parent_id) ->
        {:error, {:bad_request, "parent_conversation_id must be canonical"}}

      message_id != "" and not Ids.valid_message_id?(message_id) ->
        {:error, {:bad_request, "parent_message_id must be canonical"}}

      true ->
        with {:ok, _parent} <- Conversations.get_group_conversation(group_id, parent_id),
             :ok <- validate_parent_message(group_id, parent_id, message_id) do
          :ok
        end
    end
  end

  defp validate_parent_message(_group_id, _parent_id, ""), do: :ok

  defp validate_parent_message(group_id, parent_id, message_id) do
    case Conversations.get_group_conversation_message(group_id, parent_id, message_id) do
      {:ok, _message} ->
        :ok

      {:error, :not_found} ->
        {:error, {:bad_request, "parent_message_id does not belong to parent_conversation_id"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_schedule(
         %{"schedule_id" => schedule_id, "command" => command} = schedule,
         content
       )
       when map_size(schedule) == 2 and command == content do
    if is_nil(schedule_id) or Ids.valid_schedule_id?(schedule_id),
      do: :ok,
      else: {:error, {:bad_request, "invalid task schedule mapping"}}
  end

  defp validate_schedule(_schedule, _content),
    do: {:error, {:bad_request, "task schedule must match the complete command"}}

  defp task_conflict,
    do: {:error, {:conflict, "conversation_id is already assigned to another task"}}

  defp blank_to_nil(value), do: if(trim(value) == "", do: nil, else: trim(value))

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
