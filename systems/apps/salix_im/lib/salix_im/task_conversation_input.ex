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
         {:ok, published} <- creation_snapshot(group_id, conversation_id),
         :ok <- validate_schedule(schedule, content),
         initial when is_map(initial) <- attrs["initial_message_attrs"],
         {:ok, group} <- GroupDirectory.get_group(group_id),
         :ok <- validate_model_input(published, group, attrs),
         {:ok, delegator} <-
           delegator_agent(delegator_agent_id, group_id, collaboration_attrs?(attrs)),
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
         :ok <- admit_teams_task(published, group, initial, source_refs),
         :ok <- request_loop(group, conversation_id, worker_agent_id, attrs["loop"]),
         initial = loop_command(initial, attrs["loop"]),
         {:ok, owner_user_id} <- owner_user_id(group_id, attrs, source_refs),
         now <-
           if(published,
             do: published.conversation["created_at"],
             else: SystemsClock.system_time(:millisecond)
           ),
         conversation <-
           if(published,
             do: published.conversation,
             else:
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
                   "metadata" =>
                     attrs["conversation_metadata"]
                     |> Kernel.||(%{})
                     |> stringify()
                     |> put_present("human_wakeup_policy", attrs["human_wakeup_policy"]),
                   "labels" => attrs["labels"],
                   "latest_artifact" => attrs["latest_artifact"],
                   "artifact_manifest" => attrs["artifact_manifest"]
                 }
               )
           ),
         {:ok, participants} <-
           creation_participants(
             published,
             group,
             conversation,
             delegator,
             worker,
             owner_user_id,
             source_refs,
             investigation,
             attrs,
             now
           ),
         attrs <- published_placement(attrs, published, worker_agent_id),
         {:ok, spec} <-
           configure_model(
             %{
               "conversation" => Map.put(conversation, "participants", participants),
               "worker_agent_id" => worker_agent_id,
               "delegator_agent_id" => delegator_agent_id,
               "initial_message" => initial,
               "initial_delivery" => Keyword.get(opts, :initial_delivery, :command)
             }
             |> put_present("initial_wake", attrs["initial_wake"])
             |> Map.put("initial_worker_slots", initial_worker_slots(attrs["sessions"]))
             |> then(fn spec ->
               case wake_on_create_slots(attrs["sessions"]) do
                 nil -> spec
                 slots -> Map.put(spec, "wake_on_create_slots", slots)
               end
             end),
             published,
             group,
             attrs,
             delegator_agent_id,
             worker
           ),
         attrs_with_owner = Map.put(attrs, "owner_user_id", owner_user_id),
         {:ok, station_session} <-
           invite_station(
             group,
             conversation_id,
             worker,
             participants,
             attrs_with_owner
           ),
         {:ok, appended} <- ConversationServer.create_task(group_id, conversation_id, spec),
         committed_participants =
           committed_task_participants(group_id, conversation_id, participants),
         hydrated_station_session =
           hydrate_station_session_participants(
             group,
             conversation_id,
             worker,
             committed_participants,
             attrs_with_owner,
             station_session
           ),
         :ok <-
           station_joined(
             group,
             conversation_id,
             worker,
             committed_participants,
             attrs_with_owner,
             hydrated_station_session
           ) do
      observe_created_task(appended, group_id, conversation_id, now, attrs)

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

  defp admit_teams_task(nil, group, initial, source_refs) do
    if SalixIM.TeamsAdmission.new_work?(initial) and
         not accepted_parent?(group, initial, source_refs),
       do: SalixIM.TeamsAdmission.authorize_group(group),
       else: :ok
  end

  defp admit_teams_task(_published, _group, _initial, _refs), do: :ok

  defp accepted_parent?(group, %{"actor_type" => "user", "user_id" => user}, %{
         "parent_conversation_id" => parent,
         "parent_message_id" => message
       }) do
    case Conversations.get_group_conversation_message(group["group_id"], parent, message) do
      {:ok, %{"actor_type" => "user", "user_id" => ^user}} -> true
      _ -> false
    end
  end

  defp accepted_parent?(_, _, _), do: false

  defp validate_model_input(nil, group, attrs),
    do: SalixIM.TaskModelSelection.validate_explicit(group, attrs)

  defp validate_model_input(_published, _group, _attrs), do: :ok

  defp configure_model(spec, nil, group, attrs, delegator_id, worker),
    do:
      SalixIM.TaskModelSelection.configure_spec(
        spec,
        group,
        attrs,
        delegator_id,
        attrs["session_model"] || default_task_model(group) || worker_model(worker)
      )

  defp configure_model(spec, _published, _group, _attrs, _delegator_id, _worker),
    do: {:ok, spec}

  # The model a Worker runs a Task with when neither the Task nor its Group
  # names one: its own choice, else the platform model it follows.
  defp worker_model(%{"model" => %{"kind" => _} = model}), do: model
  defp worker_model(_worker), do: SalixIM.TaskModelSelection.builtin()

  defp creation_snapshot(group_id, conversation_id) do
    case Conversations.get_group_conversation_record(group_id, conversation_id) do
      {:ok, conversation} ->
        with {:ok, participants} <-
               SalixIM.ConversationParticipantProjection.list_bounded(group_id, conversation_id),
             do: {:ok, %{conversation: conversation, participants: participants}}

      {:error, :not_found} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp creation_participants(
         %{participants: participants},
         _group,
         _conversation,
         _delegator,
         _worker,
         _owner,
         _refs,
         _investigation,
         _attrs,
         _now
       ),
       do: {:ok, participants}

  defp creation_participants(
         nil,
         group,
         conversation,
         delegator,
         worker,
         owner_user_id,
         source_refs,
         investigation,
         attrs,
         now
       ) do
    with {:ok, delegator_participants} <-
           delegator_participants(group, conversation, delegator, investigation, attrs, now),
         {:ok, worker_participants} <-
           worker_participants(group, conversation, worker, attrs, now) do
      {:ok,
       SalixIM.Triage.Investigation.result_participants(investigation, now) ++
         owner_participants(owner_user_id, now) ++
         personal_status_participants(group["group_id"], conversation, now) ++
         origin_provider_participants(
           group["group_id"],
           conversation["conversation_id"],
           source_refs,
           now
         ) ++
         delegator_participants ++ worker_participants}
    end
  end

  defp worker_participants(
         group,
         conversation,
         worker,
         %{"sessions" => [_ | _] = sessions} = attrs,
         now
       ) do
    sessions
    |> Enum.reduce_while({:ok, []}, fn session, {:ok, acc} ->
      primary? = session["primary"] == true
      target_key = if primary?, do: nil, else: session["slot"]

      base_opts =
        if primary? do
          worker_participant_opts(
            Map.put(attrs, "session_model", session["model"] || attrs["session_model"]),
            group
          )
        else
          filter =
            if match?(%{"runs_on" => %{"device_id" => _}}, attrs),
              do: @station_worker_filter,
              else: %{"messages" => "mentioned", "statuses" => "none"}

          [
            notification_filter: filter,
            session_model: session["model"] || default_task_model(group)
          ]
        end

      opts =
        base_opts
        |> Keyword.put(:target_key, target_key)
        |> Keyword.put(:session_slot, session["slot"])
        |> Keyword.put(:session_label, session["label"])
        |> Keyword.put(:role_instructions, session["role"])

      case task_agent_participant(group, conversation, worker, "worker", now, opts) do
        {:ok, participant} -> {:cont, {:ok, [participant | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp worker_participants(group, conversation, worker, attrs, now) do
    with {:ok, participant} <-
           task_agent_participant(
             group,
             conversation,
             worker,
             "worker",
             now,
             worker_participant_opts(attrs, group)
           ) do
      {:ok, [participant]}
    end
  end

  defp wake_on_create_slots(sessions) when is_list(sessions) and length(sessions) > 1 do
    sessions
    |> Enum.filter(&(&1["wake_on_create"] == true and &1["primary"] != true))
    |> Enum.map(& &1["slot"])
    |> Enum.filter(&is_binary/1)
  end

  defp wake_on_create_slots(_sessions), do: nil

  defp initial_worker_slots(sessions) when is_list(sessions) and sessions != [] do
    Enum.map(sessions, fn entry ->
      if entry["primary"] == true,
        do: nil,
        else: SalixIM.TaskSessionSlots.normalize_target_key(entry["slot"])
    end)
  end

  defp initial_worker_slots(_sessions), do: [nil]

  defp delegator_participants(_group, conversation, nil, _investigation, _attrs, _now) do
    if collaboration?(conversation),
      do: {:ok, []},
      else: {:error, {:bad_request, "delegator agent is required"}}
  end

  defp delegator_participants(group, conversation, delegator, investigation, attrs, now) do
    with {:ok, delegator_participant} <-
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
                 # A Collaborative Task is shared with people outside the Group:
                 # the host's Router, whose Session holds the host's private
                 # context, receives none of it.
                 collaboration?(conversation) -> %{"messages" => "none", "statuses" => "none"}
                 true -> %{"messages" => "all", "statuses" => "none"}
               end
           ) do
      {:ok, [delegator_participant]}
    end
  end

  defp published_placement(attrs, nil, _worker), do: attrs

  defp published_placement(attrs, published, worker) do
    original_worker =
      Enum.find(
        published.participants,
        &(&1["actor_type"] == "agent" and &1["agent_id"] == worker and
            SalixIM.TaskSessionSlots.primary_worker?(&1))
      ) ||
        Enum.find(
          published.participants,
          &(&1["actor_type"] == "agent" and &1["agent_id"] == worker)
        )

    attrs
    |> Map.drop(~w(runs_on repo mini_app session_model))
    |> Map.merge(Map.take(published.conversation, ~w(runs_on repo mini_app)))
    |> Map.put(
      "session_model",
      get_in(original_worker || %{}, ["payload", "session_model"]) || attrs["session_model"]
    )
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
         participants,
         %{"runs_on" => %{"kind" => "sandbox", "device_id" => device_id}} = attrs
       ) do
    starts = station_starts(worker, participants, conversation_id, attrs)
    primary = Enum.find(starts, & &1["is_primary"]) || hd(starts)

    case SalixIM.Ports.TaskStations.sandbox(%{
           tenant_id: group["tenant_id"],
           group_id: group["group_id"],
           conversation_id: conversation_id,
           device_id: device_id,
           agent_id: worker["agent_id"],
           start: primary["start"],
           starts: starts,
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
  # (not connected, no such model, outdated for multi-session) refuses the create,
  # and nothing is written.
  defp invite_station(
         group,
         conversation_id,
         worker,
         participants,
         %{"runs_on" => %{"device_id" => device_id}} = attrs
       ) do
    starts = station_starts(worker, participants, conversation_id, attrs)

    if length(starts) > 1 do
      invite_station_multi(group, conversation_id, device_id, starts, attrs)
    else
      # An already joined Task owns its Session even while the Station is away.
      # The delivery path handles reconnect/catchup; a create replay starts none.
      case SalixStore.StationTaskSessions.of_task(group["group_id"], conversation_id) do
        {:error, reason} ->
          {:error, reason}

        {:ok, rows} ->
          joined =
            Enum.find(rows, &(&1.device_id == device_id and &1.agent_id == worker["agent_id"]))

          if joined do
            {:ok, :already_joined_multi}
          else
            primary = hd(starts)

            ask_station(group, conversation_id, device_id, primary["start"],
              slot: primary["slot"]
            )
          end
      end
    end
  end

  defp invite_station(_group, _conversation_id, _worker, _participants, _attrs), do: {:ok, nil}

  defp invite_station_multi(group, conversation_id, device_id, starts, attrs) do
    # Replay protection & per-slot reconciliation:
    # - DB read error propagates directly for retry (never treated as empty).
    # - If all slots are already bound on this device, return :already_joined_multi.
    # - If primary is bound but some secondaries are missing, invite ONLY the missing
    #   secondaries (never calling `leave_device`).
    # - On fresh create, never call device-wide `leave_device` on secondary failure
    #   (which could kill a concurrent duplicate create's sessions).
    with {:ok, rows} <- SalixStore.StationTaskSessions.of_task(group["group_id"], conversation_id) do
      existing_active =
        Enum.filter(
          rows,
          &(&1.device_id == device_id and not SalixStore.StationTaskSessions.awaited?(&1))
        )

      if existing_active != [] do
        bound_slots =
          MapSet.new(existing_active, fn r -> get_in(r.start || %{}, ["slot"]) || "lead" end)

        missing = Enum.reject(starts, &MapSet.member?(bound_slots, &1["slot"]))

        if missing == [] do
          {:ok, :already_joined_multi}
        else
          with :ok <-
                 check_station_multi_capability(
                   group["tenant_id"],
                   group["group_id"],
                   attrs["runs_on"]
                 ) do
            invite_missing_secondaries(group, conversation_id, device_id, missing)
          end
        end
      else
        with :ok <-
               check_station_multi_capability(
                 group["tenant_id"],
                 group["group_id"],
                 attrs["runs_on"]
               ) do
          [primary | secondaries] = starts
          claim_token = "create:" <> SalixStore.Ids.new_session_id()

          case ask_station(group, conversation_id, device_id, primary["start"],
                 slot: primary["slot"],
                 multi_session: true,
                 claim_token: claim_token
               ) do
            {:ok, :when_connected} ->
              {:ok, {:when_connected_multi, starts}}

            {:ok, {primary_session, primary_run_id}} when is_binary(primary_session) ->
              primary_entry =
                attach_session_and_run(primary, primary_session, primary_run_id, claim_token)

              secondaries
              |> Enum.with_index()
              |> Enum.reduce_while({:ok, [primary_entry]}, fn {entry, idx}, {:ok, acc} ->
                case ask_station(group, conversation_id, device_id, entry["start"],
                       slot: entry["slot"],
                       join: true,
                       multi_session: true,
                       claim_token: claim_token
                     ) do
                  {:ok, {session, used_run_id}} when is_binary(session) ->
                    {:cont,
                     {:ok,
                      [attach_session_and_run(entry, session, used_run_id, claim_token) | acc]}}

                  {:ok, :when_connected} ->
                    remaining = Enum.drop(secondaries, idx)
                    {:halt, {:partial, Enum.reverse(acc), remaining}}

                  {:error, _} = err ->
                    {:halt, {:rollback, err, [entry | acc]}}
                end
              end)
              |> case do
                {:ok, entries} ->
                  {:ok, {:multi, Enum.reverse(entries)}}

                {:partial, entries, remaining} ->
                  {:ok, {:multi_partial, entries, remaining}}

                {:rollback, err, attempted_entries} ->
                  # Fresh first-time create (confirmed no existing bindings above):
                  # undo EVERY attempted slot (primary, started secondaries, AND the
                  # failed/timed-out slot whose session id may be unknown) fenced by
                  # `claim_token`, so a concurrent create B that shared the same session
                  # keeps it alive even across Station restarts!
                  Enum.each(attempted_entries, fn attempted ->
                    _ =
                      SalixIM.Ports.TaskStations.leave_session(
                        group["tenant_id"],
                        group["group_id"],
                        conversation_id,
                        device_id,
                        attempted["session"],
                        get_in(attempted, ["start", "connector_run_id"]),
                        claim_token,
                        attempted["slot"]
                      )
                  end)

                  err
              end

            {:error, {:station_invite_unknown, _}} = err ->
              _ =
                SalixIM.Ports.TaskStations.leave_session(
                  group["tenant_id"],
                  group["group_id"],
                  conversation_id,
                  device_id,
                  nil,
                  nil,
                  claim_token,
                  primary["slot"]
                )

              err

            {:error, _} = err ->
              err
          end
        end
      end
    end
  end

  defp invite_missing_secondaries(group, conversation_id, device_id, missing) do
    missing
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, idx}, {:ok, acc} ->
      case ask_station(group, conversation_id, device_id, entry["start"],
             slot: entry["slot"],
             join: true,
             multi_session: true
           ) do
        {:ok, {session, used_run_id}} when is_binary(session) ->
          {:cont, {:ok, [attach_session_and_run(entry, session, used_run_id) | acc]}}

        {:ok, :when_connected} ->
          remaining = Enum.drop(missing, idx)
          {:halt, {:partial, Enum.reverse(acc), remaining}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, {:multi, Enum.reverse(entries)}}
      {:partial, entries, remaining} -> {:ok, {:multi_partial_append, entries, remaining}}
      {:error, _} = err -> err
    end
  end

  defp attach_session_and_run(entry, session, used_run_id, claim_token \\ nil) do
    entry
    |> Map.put("session", session)
    |> Map.update("start", %{}, fn st ->
      st
      |> then(fn s ->
        if is_binary(used_run_id) and used_run_id != "",
          do: Map.put(s, "connector_run_id", used_run_id),
          else: s
      end)
      |> then(fn s ->
        if is_binary(claim_token) and claim_token != "" do
          s
          |> Map.put("claim_token", claim_token)
          |> Map.put("claim_confirmed", false)
        else
          s
        end
      end)
    end)
  end

  defp check_station_multi_capability(tenant_id, group_id, runs_on) do
    case SalixIM.Ports.TaskStations.check_multi_session(tenant_id, group_id, runs_on) do
      :ok -> :ok
      {:error, :station_outdated} -> {:error, :station_outdated}
      {:error, {:station_outdated, _}} -> {:error, :station_outdated}
      {:error, _} = err -> err
    end
  end

  defp ask_station(group, conversation_id, device_id, start, opts) do
    invitation =
      %{
        tenant_id: group["tenant_id"],
        group_id: group["group_id"],
        conversation_id: conversation_id,
        device_id: device_id,
        start: start
      }
      |> then(&if(opts[:slot], do: Map.put(&1, :slot, opts[:slot]), else: &1))
      |> then(&if(opts[:join] == true, do: Map.put(&1, :join, true), else: &1))
      |> then(&if(opts[:multi_session] == true, do: Map.put(&1, :multi_session, true), else: &1))
      |> then(
        &if(opts[:claim_token], do: Map.put(&1, :claim_token, opts[:claim_token]), else: &1)
      )

    case SalixIM.Ports.TaskStations.invite_with_run(invitation) do
      {:ok, {session, used_run_id}} when is_binary(session) ->
        {:ok, {session, used_run_id}}

      {:ok, :when_connected} ->
        {:ok, :when_connected}

      {:error, :device_offline} ->
        {:error, {:bad_request, "that station is not connected now; the Task was not made"}}

      {:error, :station_outdated} ->
        {:error, :station_outdated}

      {:error, {:station_refused, why}} ->
        {:error, {:bad_request, "the station did not take the Task: #{why}"}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Builds per-slot station start descriptors (primary first) for a Task's active worker participants."
  def station_starts(worker, participants, conversation_id, attrs) do
    worker_agent_id = worker["agent_id"]
    person = canonical_person(attrs)

    workers =
      participants
      |> Enum.filter(
        &(&1["actor_type"] == "agent" and &1["agent_id"] == worker_agent_id and
            &1["role_label"] == "worker" and &1["state"] != "inactive")
      )
      |> Enum.sort_by(fn p ->
        if SalixIM.TaskSessionSlots.primary_worker?(p),
          do: {0, ""},
          else: {1, p["target_key"] || ""}
      end)

    case workers do
      [] ->
        [
          %{
            "slot" => "lead",
            "is_primary" => true,
            "participant_id" => nil,
            "agent_id" => worker_agent_id,
            "start" =>
              station_start(
                worker_agent_id,
                attrs["session_model"],
                attrs["repo"],
                attrs["mini_app"],
                slot: "lead",
                is_primary: true,
                person: person
              )
          }
        ]

      list ->
        roster =
          if length(list) > 1 do
            Enum.map(list, fn p ->
              %{
                "slot" => SalixIM.TaskSessionSlots.worker_slot(p) || "lead",
                "label" => SalixIM.TaskSessionSlots.worker_label(p),
                "role" => get_in(p, ["payload", "role_instructions"]),
                "primary" => SalixIM.TaskSessionSlots.primary_worker?(p)
              }
            end)
          else
            nil
          end

        multi? = length(list) > 1

        Enum.map(list, fn p ->
          primary? = SalixIM.TaskSessionSlots.primary_worker?(p)
          slot = SalixIM.TaskSessionSlots.worker_slot(p) || "lead"

          model =
            get_in(p, ["payload", "session_model"]) ||
              if(primary?, do: attrs["session_model"], else: nil)

          repo =
            if primary?,
              do: attrs["repo"],
              else: secondary_repo(attrs["repo"], conversation_id, slot)

          start_opts =
            cond do
              multi? ->
                [
                  slot: slot,
                  is_primary: primary?,
                  participant_id: p["participant_id"],
                  person: person,
                  roster: roster
                ]

              slot != "lead" ->
                [
                  slot: slot,
                  is_primary: primary?,
                  participant_id: p["participant_id"],
                  person: person
                ]

              true ->
                [person: person]
            end

          %{
            "slot" => slot,
            "is_primary" => primary?,
            "participant_id" => p["participant_id"],
            "agent_id" => worker_agent_id,
            "start" =>
              station_start(
                worker_agent_id,
                model,
                repo,
                if(primary?, do: attrs["mini_app"], else: nil),
                start_opts
              )
          }
        end)
    end
  end

  @doc "Derives the isolated secondary git worktree repo config (`comma-sessions/<task_short>/<slot>`)."
  def secondary_repo(%{"branch" => primary_branch} = repo, conversation_id, slot)
      when is_binary(primary_branch) and primary_branch != "" and is_binary(slot) and slot != "" do
    task_short =
      conversation_id |> String.replace(~r/[^A-Za-z0-9]/, "") |> String.slice(-10, 10)

    repo
    |> Map.delete("pull_request")
    |> Map.merge(%{
      "branch" => "comma-sessions/#{task_short}/#{slot}",
      "isolated" => true,
      "primary_branch" => primary_branch
    })
  end

  def secondary_repo(_repo, _conversation_id, _slot), do: nil

  @doc "Canonical human person ID for Station usage attribution (never an `@agents.salix` agent)."
  def canonical_person(%{"owner_user_id" => owner})
      when is_binary(owner) and owner != "",
      do: owner

  def canonical_person(%{"source_refs" => %{"ifc_requester" => principal}})
      when is_binary(principal) do
    case SalixIFC.Codec.decode_principal(principal) do
      {:ok, {:comma_user, user}} when is_binary(user) and user != "" -> user
      _ -> nil
    end
  end

  def canonical_person(_attrs), do: nil

  # A sandbox Task (`runs_on {kind: sandbox}`) runs on the device its sandboxes'
  # stations register as, the same for every sandbox. A coding Task (`repo`)
  # works on a session branch named after it unless the request named one.
  defp sandbox_place(%{"runs_on" => %{"kind" => "sandbox"}} = attrs, conversation_id) do
    attrs =
      Map.put(attrs, "runs_on", %{
        "kind" => "sandbox",
        "device_id" => SalixStore.CodingSandboxes.device_id(conversation_id)
      })

    case attrs["repo"] do
      %{} = repo ->
        Map.put(attrs, "repo", Map.put_new(repo, "branch", session_branch(conversation_id)))

      _none ->
        attrs
    end
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
  def station_start(agent_id, session_model, repo \\ nil, mini_app \\ nil, opts \\ []) do
    model = if is_map(session_model), do: session_model, else: %{}

    %{"requester" => agent_id <> "@agents.salix", "title" => agent_id}
    |> put_present("runtime", if(model["provider"] in ~w(claude codex), do: model["provider"]))
    |> put_present("model", model["model"])
    |> put_present("effort", model["reasoning_effort"])
    |> put_present("repo", repo)
    |> put_present("mini_app", mini_app)
    |> put_present("slot", opts[:slot])
    |> put_present("participant_id", opts[:participant_id])
    |> put_present("person", opts[:person])
    |> then(
      &if(is_boolean(opts[:is_primary]),
        do: Map.put(&1, "is_primary", opts[:is_primary]),
        else: &1
      )
    )
    |> then(&if(is_list(opts[:roster]), do: Map.put(&1, "roster", opts[:roster]), else: &1))
  end

  defp committed_task_participants(group_id, conversation_id, fallback) do
    case Conversations.list_group_conversation_participants(group_id, conversation_id) do
      {:ok, %{"participants" => [_ | _] = list}} -> list
      {:ok, [_ | _] = list} -> list
      _ -> fallback
    end
  end

  defp hydrate_station_session_participants(
         group,
         conversation_id,
         worker,
         committed_participants,
         attrs,
         station_session
       ) do
    worker_agent_id = worker["agent_id"]

    pid_by_slot =
      committed_participants
      |> Enum.filter(fn p ->
        p["actor_type"] == "agent" and p["agent_id"] == worker_agent_id and
          p["role_label"] == "worker" and p["state"] != "inactive" and
          is_binary(p["participant_id"]) and p["participant_id"] != ""
      end)
      |> Map.new(fn p ->
        slot = SalixIM.TaskSessionSlots.worker_slot(p) || "lead"
        {slot, p["participant_id"]}
      end)

    if get_in(attrs, ["runs_on", "kind"]) == "sandbox" and map_size(pid_by_slot) > 0 do
      _ =
        SalixIM.Ports.TaskStations.hydrate_participant_ids(
          group["tenant_id"],
          conversation_id,
          pid_by_slot
        )
    end

    hydrate_entries = fn entries ->
      Enum.map(entries, fn entry ->
        slot = entry["slot"] || "lead"

        case Map.get(pid_by_slot, slot) do
          pid when is_binary(pid) and pid != "" ->
            entry
            |> Map.put("participant_id", pid)
            |> Map.update(
              "start",
              %{"participant_id" => pid},
              &Map.put(&1, "participant_id", pid)
            )

          _ ->
            entry
        end
      end)
    end

    case station_session do
      {:multi, entries} ->
        {:multi, hydrate_entries.(entries)}

      {:multi_partial, entries, remaining} ->
        {:multi_partial, hydrate_entries.(entries), hydrate_entries.(remaining)}

      {:multi_partial_append, entries, remaining} ->
        {:multi_partial_append, hydrate_entries.(entries), hydrate_entries.(remaining)}

      {:when_connected_multi, starts} ->
        {:when_connected_multi, hydrate_entries.(starts)}

      other ->
        other
    end
  end

  defp station_joined(_group, _conversation_id, _worker, _participants, _attrs, nil), do: :ok

  defp station_joined(
         _group,
         _conversation_id,
         _worker,
         _participants,
         _attrs,
         :already_joined_multi
       ),
       do: :ok

  defp station_joined(
         group,
         conversation_id,
         worker,
         _participants,
         %{"runs_on" => %{"device_id" => device_id}},
         {:multi_partial_append, entries, remaining}
       ) do
    # Replay partial join: join newly invited secondaries and ALWAYS append `remaining`
    # onto the real primary row via `append_pending_multi_start` (never onto a secondary).
    with :ok <-
           station_joined(
             group,
             conversation_id,
             worker,
             [],
             %{"runs_on" => %{"device_id" => device_id}},
             {:multi, entries}
           ) do
      Enum.reduce_while(remaining, :ok, fn entry, :ok ->
        case SalixStore.StationTaskSessions.append_pending_multi_start(
               group["group_id"],
               conversation_id,
               device_id,
               entry
             ) do
          {:ok, _entry} -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp station_joined(
         group,
         conversation_id,
         worker,
         _participants,
         %{"runs_on" => %{"device_id" => device_id}},
         {:multi_partial, entries, remaining}
       ) do
    if entries == [] and remaining != [] do
      # Primary was already joined; append remaining missing secondaries onto primary row.
      Enum.reduce_while(remaining, :ok, fn entry, :ok ->
        case SalixStore.StationTaskSessions.append_pending_multi_start(
               group["group_id"],
               conversation_id,
               device_id,
               entry
             ) do
          {:ok, _entry} -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    else
      entries =
        case entries do
          [primary | rest] when remaining != [] ->
            remaining_with_ids =
              Enum.map(remaining, fn entry ->
                if is_binary(entry["invite_id"]) and entry["invite_id"] != "" do
                  entry
                else
                  Map.put(entry, "invite_id", SalixStore.Ids.new_session_id())
                end
              end)

            updated_primary =
              Map.update(
                primary,
                "start",
                %{"pending_multi_starts" => remaining_with_ids},
                &Map.put(&1, "pending_multi_starts", remaining_with_ids)
              )

            [updated_primary | rest]

          other ->
            other
        end

      station_joined(
        group,
        conversation_id,
        worker,
        [],
        %{"runs_on" => %{"device_id" => device_id}},
        {:multi, entries}
      )
    end
  end

  defp station_joined(
         group,
         conversation_id,
         worker,
         _participants,
         %{"runs_on" => %{"device_id" => device_id}},
         {:multi, entries}
       ) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case SalixIM.Ports.TaskStations.joined(%{
             tenant_id: group["tenant_id"],
             group_id: group["group_id"],
             conversation_id: conversation_id,
             device_id: device_id,
             session: entry["session"],
             agent_id: worker["agent_id"],
             start: entry["start"]
           }) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp station_joined(
         group,
         conversation_id,
         worker,
         _participants,
         %{"runs_on" => %{"device_id" => device_id}},
         {:when_connected_multi, starts}
       ) do
    primary = hd(starts)

    SalixIM.Ports.TaskStations.joined(%{
      tenant_id: group["tenant_id"],
      group_id: group["group_id"],
      conversation_id: conversation_id,
      device_id: device_id,
      session: nil,
      agent_id: worker["agent_id"],
      start: Map.put(primary["start"], "multi_starts", starts)
    })
  end

  # A station expected in the Task (`:when_connected`) joins it with no
  # Session: the product invites it when it connects.
  defp station_joined(
         group,
         conversation_id,
         worker,
         participants,
         %{"runs_on" => %{"device_id" => device_id}} = attrs,
         session_or_pair
       ) do
    starts = station_starts(worker, participants, conversation_id, attrs)
    primary = hd(starts)

    {session, start_map} =
      case session_or_pair do
        {sess, used_run_id} when is_binary(sess) ->
          st =
            if is_binary(used_run_id) and used_run_id != "",
              do: Map.put(primary["start"], "connector_run_id", used_run_id),
              else: primary["start"]

          {sess, st}

        :when_connected ->
          {nil, primary["start"]}

        sess ->
          {sess, primary["start"]}
      end

    SalixIM.Ports.TaskStations.joined(%{
      tenant_id: group["tenant_id"],
      group_id: group["group_id"],
      conversation_id: conversation_id,
      device_id: device_id,
      session: session,
      agent_id: worker["agent_id"],
      start: start_map
    })
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # The observer is told where the Task runs and on what model; it records
  # their kinds only.
  defp observe_created_task(%{"inserted" => true}, group_id, conversation_id, created_at, attrs) do
    case SystemsRuntime.get_env(:salix_im, :product_activity_observer) do
      nil ->
        :ok

      module ->
        module.task_created(
          group_id,
          conversation_id,
          created_at,
          Map.take(attrs, ~w(runs_on repo mini_app session_model))
        )
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp observe_created_task(_, _, _, _, _), do: :ok

  @doc """
  Create the Task a Slack thread bound to a Worker or to Tasks makes, once:
  `materialization` is its title, command and creation time, fixed when the
  thread was bound. `opts[:session_model]` is the model the Slack connection
  binds its Tasks to; without one the Task runs the default Task model
  (`default_task_model/1`), unless the Group requires an explicit choice.
  The model is not part of the materialization: the
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
         :ok <- validate_ingress_model(group, conversation_id, opts[:session_model]),
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
         session_model = opts[:session_model] || default_task_model(group),
         {:ok, worker_participant} <-
           task_agent_participant(
             group,
             conversation,
             worker,
             "worker",
             created_at,
             notification_filter: %{"messages" => "all", "statuses" => "none"},
             session_model: session_model
           ),
         {:ok, spec} <-
           ingress_model(
             %{
               "conversation" =>
                 conversation
                 |> Map.put("participants", [worker_participant])
                 |> Map.delete("task_materialization"),
               "worker_agent_id" => worker_agent_id,
               "materialization" => materialization
             },
             group,
             session_model || worker_model(worker),
             materialization
           ),
         {:ok, result} <- ConversationServer.create_task(group_id, conversation_id, spec) do
      {:ok, result}
    else
      false -> task_conflict()
      {:error, _reason} = error -> error
    end
  end

  def ensure_with_id(_group_id, _conversation_id, _worker_agent_id, _materialization, _opts),
    do: {:error, {:bad_request, "invalid task materialization"}}

  # A new Task that runs Comma's built-in model takes its model from the
  # platform route table, chosen once before its first commit. Redelivery to
  # a Task that exists asks for no decision: it keeps its model.
  defp ingress_model(spec, group, task_model, materialization) do
    case Conversations.get_group_conversation_record(
           group["group_id"],
           spec["conversation"]["conversation_id"]
         ) do
      {:error, :not_found} ->
        content = trim(materialization["title"]) <> "\n\n" <> materialization["command"]

        with {:ok, spec} <-
               SalixIM.TaskModelSelection.configure_ingress(spec, group, task_model, content),
             {:ok, selected} <- SalixIM.TaskModelSelection.select(spec),
             do: {:ok, Map.delete(selected, "model_selection")}

      _existing_or_unavailable ->
        {:ok, spec}
    end
  end

  # A Slack binding has no delegator and uses its connection's explicit choice.
  # Policy changes must not reject redelivery to an already committed Task.
  defp validate_ingress_model(group, conversation_id, model) do
    case SalixIM.TaskModelSelection.validate_explicit(group, %{"session_model" => model}) do
      :ok ->
        :ok

      error ->
        case Conversations.get_group_conversation_record(group["group_id"], conversation_id) do
          {:ok, _existing} -> :ok
          {:error, :not_found} -> error
          read_error -> read_error
        end
    end
  end

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

  defp delegator_agent(nil, _group_id, true), do: {:ok, nil}
  defp delegator_agent(agent_id, group_id, _collab?), do: task_agent(agent_id, group_id)

  defp collaboration_attrs?(attrs) when is_map(attrs) do
    case attrs["conversation_metadata"] do
      %{"collaboration" => %{} = collaboration} -> map_size(collaboration) > 0
      _ -> false
    end
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

    target_key = SalixIM.TaskSessionSlots.normalize_target_key(Keyword.get(opts, :target_key))

    participant =
      %{
        "actor_type" => "agent",
        "agent_id" => agent["agent_id"],
        "agent_name" => agent["name"],
        "role_label" => role_label,
        "state" => "active",
        "notification_filter" => notification_filter,
        "created_at" => now,
        "updated_at" => now
      }
      |> put_present("target_key", target_key)

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

  defp collaboration?(%{"metadata" => %{"collaboration" => %{} = collaboration}}),
    do: map_size(collaboration) > 0

  defp collaboration?(_conversation), do: false

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

  # The product adapter names the owner's bound personal chat, if any. Only a
  # Task asked for on that chat's provider follows there. Cards are an
  # accessory to the Task: a lookup failure never blocks its creation.
  defp personal_status_participants(group_id, conversation, now) do
    origin = get_in(conversation, ["metadata", "origin", "provider"])

    with module when is_atom(module) and not is_nil(module) <-
           SystemsRuntime.get_env(:salix_im, :task_status_personal_adapter),
         targets when is_list(targets) <- module.task_status_targets(group_id) do
      for %{"provider" => ^origin} = target <- targets do
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
