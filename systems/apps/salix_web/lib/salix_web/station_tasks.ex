defmodule SalixWeb.StationTasks do
  require SystemsRuntime.Proc

  @moduledoc """
  Salix as the Station a Task is kept on, for the Sessions of other stations
  taking part in it (`systems/station/docs/tasks.md`): the same requests
  as between any two stations, over the device's connector connection.

    * `invite/1` (`task.invite`): asks the station to start a Session for the
      Task, before the Task is made. Answered at once: the Session, or why not
      (not connected, cannot run the model). Nothing is written into the Task.
      The Group's Cloud VM whose Workload is not `ready` (archived, waking,
      not made yet, or its station not connected) is not asked: it answers
      `when_connected`, and the Task is made for it all the same.
      With `replace` (the Task now runs another model there), the station's
      new Session takes the place of those it had in the Task.
    * `moved/1`: the Task now runs elsewhere (`SalixIM.TaskRun`). Each station
      that took part and does not run it now is told (`task.leave`, best
      effort: one not connected is not told) and given nothing more; the
      station that runs it now, if one does, takes part with its new Session
      and is given the Task from its start.
    * `joined/1`: the Session takes part (`SalixStore.StationTaskSessions`,
      `sent` 0) and is given the Task. With no Session (`when_connected`), the
      station is expected in the Task: given it as any station is, which asks
      for its VM's wake (below), and invited with its `start` once the VM is
      ready and it is connected (its hello, or the VM's `vm_ready/2`), its
      Session then taking part; the first giving follows at once.
    * `give/3` (`task.put`): the Messages after `sent`, a part at a time, until
      the station has all. Given when a Message is added (`appended/2`), when
      Salix starts (`give_all/0`) and when the station says hello. A station
      that is not connected is not asked again: it says hello when it is. The
      Group's Cloud VM comes back only when Salix wakes it, so its wake is
      asked for then, once for each giving, as work for the VM asks
      (`SalixWeb.GroupStationLifecycle.wake/1`). One
      that was asked but did not answer is given again after 1 s, 2 s, 4 s… at
      most a minute, until it has it; a new Message or its hello gives at once.
      A station that has no thread of the Task (it lost it) answers `unknown`:
      it is invited again with the `start` it was first invited with, its new
      Session takes the place of the old, and it is given the Task from its
      start. That invite says through which Message its Sessions answered the
      Task already (`answered`: the seq of the last Message one of them ended
      a turn with), so it answers nothing again; each Message its Sessions
      posted, the old one's too, is given as its own. One whose Sessions of
      it ended answers `gone`: it is given nothing more.
    * `post/2` (`task.post`): a Message of the station's Session, written as the
      Task's Worker (who is delivered nothing), once per `key`; its seq. Its
      `milestones` become the Message's `milestone` blocks
      (`SalixIM.ConversationMilestone`); a Message of milestones alone has no
      text. `task.put` gives a Message's milestones back the same way. A post
      that ends a coding Task's turn has its sandbox's facts read
      (`SalixWeb.CodingSandboxes.turn_ended/2`).
    * `file/2` (`task.file`): a part of a file of a Message the station's
      Session was given (`files` with the Message: each by its part's index,
      its name and size); the station fetches it into the Session's uploads,
      a part at a time, before the Session hears the Message.
    * `session_status/2` (`task.status`): where the station's Session of the
      Task stands (running, waiting, idle, cannot start, gone), for the
      Task's `SalixIM.StationTaskWatch`; a read that starts nothing there.
    * `sandbox/1`, `task_status/3`: a coding Task's sandbox, reserved before
      the Task is made and given up when it ends (`SalixWeb.CodingSandboxes`),
      whose station is invited once it connects. Giving to a stopped sandbox
      makes a new one, as giving to the Cloud VM wakes it.
    * `app_deploy/2` (`task.app_deploy`), `app_logs/2` (`task.app_logs`): the
      Session of a Mini App build Task deploys a preview Version of its app,
      or reads its backend's recent logs, from the Task's current sandbox.
    * `tools/2` (`task.tools`), `tool_call/2` (`task.tool_call`): the Session
      of a sandbox Task lists, and calls, Salix registry tools as the Task's
      Worker (`SalixAgent.StationToolCalls`: the Worker's own disclosure),
      with the authority of `app_deploy/2`.
    * `ask/4`: a request about the station's Session of a coding Task
      (`task.diff`, `task.pull_request`).
    * `hello/2` (`task.hello`): the station connected; it is given what it
      missed, and told to leave (`task.leave`) each Task it names that it no
      longer takes part in (one that moved while it was not connected). With `tasks` (`[{task, fetched}]`, how far it has each), from
      there: one it has less of than it was given is given the rest again, one
      it does not name it has none of (its put answers `unknown`). Without (a
      station from before `tasks`), from what it was given.
  """

  @behaviour SalixIM.Ports.TaskStations

  require Logger
  require SystemsClock

  alias SalixStore.{StationMembers, StationTaskSessions}

  @put_limit 100
  @put_timeout_ms 30_000
  @invite_timeout_ms 60_000
  @status_timeout_ms 10_000
  # How far back a reopened Task looks for a Message its Worker has not answered.
  @recent_messages 50
  @last_failure_chars 200
  @session_states %{
    "running" => :running,
    "waiting" => :waiting,
    "idle" => :idle,
    "cannot_start" => :cannot_start,
    "gone" => :gone
  }
  @put_again_max_ms 60_000
  # Bytes one `task.file` answers at most (the station's FILE_PART).
  @file_part 256 * 1024
  # The files one post may name: how many, and their bytes together.
  @max_post_files 20
  @max_post_bytes 1024 * 1024 * 1024
  @file_types ~w(file image)
  @max_text_bytes 64 * 1024
  # The files of a Mini App deploy (`task.app_deploy`), by name: what each is
  # to the app's owner, and the most bytes it may have. The owner checks the
  # bundle's contents (index.html at most 8 MiB, 25 MiB and 2,000 files in all)
  # and the backend's compressed size (3 MiB); the tar of a full bundle is a
  # little larger than its files.
  @app_files %{
    "comma-app.json" => {:manifest, 64 * 1024},
    "bundle.tar" => {:bundle, 28 * 1024 * 1024},
    "source.tar.gz" => {:source, 50 * 1024 * 1024},
    "worker.js" => {:worker, 10 * 1024 * 1024}
  }
  @max_notes_chars 2_000
  @refusal_guard_table :salix_station_task_refusal_guards

  defmodule RefusalGuard do
    @moduledoc false
    use GenServer

    def start_link(_opts) do
      GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    end

    @impl true
    def init(:ok) do
      table =
        case :ets.whereis(:salix_station_task_refusal_guards) do
          :undefined ->
            :ets.new(:salix_station_task_refusal_guards, [
              :named_table,
              :public,
              :set,
              read_concurrency: true,
              write_concurrency: true
            ])

          tid ->
            tid
        end

      {:ok, %{table: table}}
    end
  end

  @doc false
  def reset_refusal_guard_for_test do
    case :ets.whereis(@refusal_guard_table) do
      :undefined -> :ok
      tid -> :ets.delete_all_objects(tid) && :ok
    end
  end

  defp entry_guard_identity(entry) when is_map(entry) do
    pid = entry["participant_id"] || get_in(entry, ["start", "participant_id"])

    cond do
      is_binary(entry["invite_id"]) and entry["invite_id"] != "" ->
        {:invite, entry["invite_id"]}

      is_binary(pid) and pid != "" ->
        {:pid, pid}

      is_binary(entry["demoted_binding_token"]) and entry["demoted_binding_token"] != "" ->
        {:token, entry["demoted_binding_token"]}

      is_binary(entry["demoted_session"]) and entry["demoted_session"] != "" ->
        {:session, entry["demoted_session"]}

      true ->
        nil
    end
  end

  defp record_pending_deactivation(group, conversation, device, slot, entry, why_label) do
    with id when id != nil <- entry_guard_identity(entry),
         tid when tid != :undefined <- :ets.whereis(@refusal_guard_table) do
      :ets.insert(tid, {{group, conversation, device, slot, id}, why_label})
    end

    :ok
  end

  defp pending_deactivation_reason(group, conversation, device, slot, entry) do
    with id when id != nil <- entry_guard_identity(entry),
         tid when tid != :undefined <- :ets.whereis(@refusal_guard_table),
         key = {group, conversation, device, slot, id},
         [{^key, why}] <- :ets.lookup(tid, key) do
      why
    else
      _ -> nil
    end
  end

  defp clear_pending_deactivation(group, conversation, device, slot, entry) do
    with id when id != nil <- entry_guard_identity(entry),
         tid when tid != :undefined <- :ets.whereis(@refusal_guard_table) do
      :ets.delete(tid, {group, conversation, device, slot, id})
    end

    :ok
  end

  defp clear_device_pending_deactivations(group, conversation, device) do
    case :ets.whereis(@refusal_guard_table) do
      :undefined -> :ok
      tid -> :ets.match_delete(tid, {{group, conversation, device, :_, :_}, :_}) && :ok
    end
  end

  @declared ~w(all_done need_help waiting)
  @ended_turn ~w(all_done need_help)

  @doc """
  Checks whether the target Station / Cloud VM supports `multi_session_tasks`
  before any external side effects occur. Returns `:ok` or `{:error, :station_outdated}`.
  """
  @impl SalixIM.Ports.TaskStations
  def check_multi_session(tenant, group, %{"kind" => "sandbox", "device_id" => device})
      when is_binary(tenant) and is_binary(group) and is_binary(device) and device != "" do
    case SalixEnv.Registry.get_device(tenant, group, device) do
      {:ok, %{"meta" => %{"capabilities" => caps}}} when is_map(caps) ->
        check_multi_caps(caps)

      {:ok, %{"status" => "connected"}} ->
        {:error, :station_outdated}

      {:error, :not_found} ->
        :ok

      _ ->
        :ok
    end
  end

  def check_multi_session(_tenant, _group, %{"kind" => "sandbox"}), do: :ok

  def check_multi_session(tenant, group, %{"device_id" => device})
      when is_binary(tenant) and is_binary(group) and is_binary(device) do
    case SalixEnv.Registry.get_device(tenant, group, device) do
      {:ok, %{"status" => "connected", "meta" => %{"capabilities" => caps}}} when is_map(caps) ->
        check_multi_caps(caps)

      {:ok, %{"status" => "connected"}} ->
        {:error, :station_outdated}

      {:ok, %{"meta" => %{"capabilities" => caps}}} when is_map(caps) ->
        check_multi_caps(caps)

      {:error, :not_found} ->
        if device == SalixStore.RuntimeIds.cloud_vm_device_id(group),
          do: :ok,
          else: {:error, :device_offline}

      _ ->
        :ok
    end
  end

  def check_multi_session(_tenant, _group, _runs_on), do: :ok

  defp check_multi_caps(caps) do
    case SalixStore.StationReadiness.check_multi_session(caps) do
      :ready -> :ok
      {:station_outdated, _info} -> {:error, :station_outdated}
      {:device_needs_station, _info} -> {:error, :device_needs_station}
    end
  end

  @doc """
  Adds a dynamically created secondary worker session to a station or sandbox Task.
  """
  @impl SalixIM.Ports.TaskStations
  def add_session(
        %{
          tenant_id: tenant,
          group_id: group,
          conversation_id: conversation,
          device_id: device,
          agent_id: agent_id,
          slot: slot,
          start: start
        } = entry
      ) do
    participant_id = Map.get(entry, :participant_id) || get_in(start || %{}, ["participant_id"])

    invite_id =
      case Map.get(entry, :invite_id) || Map.get(entry, "invite_id") do
        id when is_binary(id) and id != "" -> id
        _ -> SalixStore.Ids.new_session_id()
      end

    if SalixStore.CodingSandboxes.device?(device) or
         get_in(entry, [:runs_on, "kind"]) == "sandbox" do
      start_entry = %{
        "slot" => slot,
        "is_primary" => false,
        "agent_id" => agent_id,
        "participant_id" => participant_id,
        "invite_id" => invite_id,
        "start" => start
      }

      SalixWeb.CodingSandboxes.add_session_start(tenant, conversation, start_entry)
    else
      start_entry = %{
        "slot" => slot,
        "is_primary" => false,
        "agent_id" => agent_id,
        "participant_id" => participant_id,
        "invite_id" => invite_id,
        "start" => start
      }

      with {:ok, rows} <- StationTaskSessions.of_task(group, conversation) do
        device_rows = Enum.filter(rows, &(&1.device_id == device))
        active_rows = Enum.reject(device_rows, &StationTaskSessions.awaited?/1)
        awaited_rows = Enum.filter(device_rows, &StationTaskSessions.awaited?/1)

        cond do
          active_rows == [] and awaited_rows != [] ->
            # Primary is still awaited (waking Cloud VM / unjoined): never fire a `join: true`
            # RPC that would fail with `no_active_primary`. Persist onto the awaited primary row
            # first (serialized through ParticipantActor when participant_id is present), then
            # trigger `give/3` to bring up primary + secondaries in order.
            with {:ok, _persisted_entry} <-
                   reserve_pending_multi_start(
                     group,
                     conversation,
                     device,
                     participant_id,
                     start_entry
                   ) do
              give(group, conversation, device)
              :ok
            end

          device_rows == [] ->
            # No carrier row (neither active nor awaited) exists on this device yet:
            # return a retryable error without sending any RPC.
            {:error, :primary_not_ready}

          true ->
            # Active primary row exists: persist pending start BEFORE sending `task.invite`
            # (serialized through ParticipantActor when participant_id is present) and confirm
            # the write succeeds; never fire an RPC if DB persistence fails.
            with {:ok, persisted_entry} <-
                   reserve_pending_multi_start(
                     group,
                     conversation,
                     device,
                     participant_id,
                     start_entry
                   ) do
              persisted_invite_id = persisted_entry["invite_id"]
              persisted_start = persisted_entry["start"] || start
              persisted_agent_id = persisted_entry["agent_id"] || agent_id
              persisted_pid = persisted_entry["participant_id"] || participant_id

              persisted_answered =
                case persisted_entry["answered"] do
                  n when is_integer(n) and n >= 0 -> n
                  _ -> 0
                end

              case slot_pending_deactivation_reason(
                     group,
                     conversation,
                     device,
                     slot,
                     persisted_entry
                   ) do
                why when is_binary(why) ->
                  refusal_err =
                    if why == "station_outdated",
                      do: {:error, :station_outdated},
                      else: {:error, {:station_refused, why}}

                  handle_online_permanent_slot_refusal(
                    group,
                    conversation,
                    device,
                    slot,
                    persisted_entry,
                    refusal_err
                  )

                nil ->
                  case check_multi_session(tenant, group, %{"device_id" => device}) do
                    :ok ->
                      case mark_pending_dispatched(
                             group,
                             conversation,
                             device,
                             slot,
                             persisted_invite_id
                           ) do
                        {:error, :pending_invite_not_found} ->
                          # If background recovery already committed this exact invite_id to an
                          # active slot binding and cleared pending, return `:ok` idempotently so
                          # callers (e.g. Provider.Internal) proceed with kickoff; otherwise abort.
                          if active_slot_matches_invite?(
                               group,
                               conversation,
                               device,
                               slot,
                               persisted_invite_id
                             ) do
                            :ok
                          else
                            {:error, :pending_invite_not_found}
                          end

                        {:error, :pending_deactivation} ->
                          # Pending entry was already locked for permanent deactivation:
                          # abort RPC immediately without firing `task.invite` or writing backoff.
                          {:error, :pending_deactivation}

                        {:error, _} = disp_err ->
                          schedule_online_add_retry(
                            group,
                            conversation,
                            device,
                            slot,
                            persisted_invite_id
                          )

                          disp_err

                        :ok ->
                          persisted_entry = Map.put(persisted_entry, "dispatched", true)

                          case invite_with_run(%{
                                 tenant_id: tenant,
                                 group_id: group,
                                 conversation_id: conversation,
                                 device_id: device,
                                 start: persisted_start,
                                 answered: persisted_answered,
                                 slot: slot,
                                 claim_token: persisted_invite_id,
                                 invite_id: persisted_invite_id,
                                 join: true,
                                 multi_session: true
                               }) do
                            {:ok, :when_connected} ->
                              give(group, conversation, device)
                              :ok

                            {:ok, {session, used_run_id}} when is_binary(session) ->
                              fenced_start =
                                if is_binary(used_run_id) and used_run_id != "",
                                  do: Map.put(persisted_start, "connector_run_id", used_run_id),
                                  else: persisted_start

                              case register_slot_binding(%{
                                     tenant_id: tenant,
                                     group_id: group,
                                     conversation_id: conversation,
                                     device_id: device,
                                     session: session,
                                     agent_id: persisted_agent_id,
                                     answered: persisted_answered,
                                     participant_id: persisted_pid,
                                     expected_pending_invite_id: persisted_invite_id,
                                     start: fenced_start
                                   }) do
                                :ok ->
                                  _ =
                                    StationTaskSessions.remove_pending_multi_starts(
                                      group,
                                      conversation,
                                      device,
                                      [pending_remove_target(slot, persisted_invite_id)]
                                    )

                                  :ok

                                {:error, {:stale_slot_binding, :invite_superseded}} = err ->
                                  # Uncommitted orphan session on Station: durably record pending_orphan_leaves
                                  # and fence-revoke with claim_token == persisted_invite_id (never nil).
                                  case revoke_orphan_slot_session(
                                         tenant,
                                         group,
                                         conversation,
                                         device,
                                         slot,
                                         session,
                                         used_run_id,
                                         persisted_invite_id
                                       ) do
                                    {:error, {:orphan_leave_unpersisted, _}} = revoke_err ->
                                      revoke_err

                                    _ ->
                                      err
                                  end

                                {:error, reg_err} = err ->
                                  unless reg_err == :participant_inactive do
                                    schedule_online_add_retry(
                                      group,
                                      conversation,
                                      device,
                                      slot,
                                      persisted_invite_id
                                    )
                                  end

                                  err
                              end

                            {:error, :device_offline} ->
                              :ok

                            {:error, {:station_invite_unknown, _}} = unknown_err ->
                              # Keep `pending_multi_starts` intact, record `next_retry_at`, and wake
                              # the giver so a quiet personal station auto-reconciles on SystemsClock!
                              schedule_online_add_retry(
                                group,
                                conversation,
                                device,
                                slot,
                                persisted_invite_id
                              )

                              unknown_err

                            {:error, reason} = err ->
                              cond do
                                no_active_primary_error?(reason) ->
                                  # Primary missing on station: keep persisted pending start and trigger
                                  # primary-first recovery without dropping pending or deactivating participant.
                                  old_run_id = primary_persisted_run_id(active_rows)

                                  case invite_again_all(
                                         active_rows,
                                         group,
                                         conversation,
                                         device,
                                         0,
                                         old_run_id
                                       ) do
                                    res when res in [:ok, :stale] ->
                                      give(group, conversation, device)
                                      :ok

                                    :unreachable ->
                                      schedule_online_add_retry(
                                        group,
                                        conversation,
                                        device,
                                        slot,
                                        persisted_invite_id
                                      )

                                      :ok

                                    {:error, _} = rec_err ->
                                      schedule_online_add_retry(
                                        group,
                                        conversation,
                                        device,
                                        slot,
                                        persisted_invite_id
                                      )

                                      rec_err
                                  end

                                permanent_slot_refusal?(reason) ->
                                  handle_online_permanent_slot_refusal(
                                    group,
                                    conversation,
                                    device,
                                    slot,
                                    persisted_entry,
                                    err
                                  )

                                true ->
                                  schedule_online_add_retry(
                                    group,
                                    conversation,
                                    device,
                                    slot,
                                    persisted_invite_id
                                  )

                                  err
                              end
                          end
                      end

                    {:error, :device_offline} ->
                      :ok

                    {:error, reason} = err ->
                      if permanent_slot_refusal?(reason) do
                        handle_online_permanent_slot_refusal(
                          group,
                          conversation,
                          device,
                          slot,
                          persisted_entry,
                          err
                        )
                      else
                        err
                      end
                  end
              end
            end
        end
      end
    end
  end

  defp slot_pending_deactivation_reason(group, conversation, device, slot, entry) do
    guard_reason = pending_deactivation_reason(group, conversation, device, slot, entry)

    cond do
      entry["pending_deactivation"] == true ->
        entry["refusal_reason"] || guard_reason || "refused"

      is_binary(guard_reason) ->
        guard_reason

      true ->
        nil
    end
  end

  @doc """
  Single shared binding registration entry point for online `add_session`,
  Sandbox `reconcile_invites`/`add_session_start`, and offline/recovery
  `invite_secondary_list`:
  1. When `participant_id` is present, atomically marks `station_bound: true` in
     `ConversationParticipantActor` (propagating errors, never swallowing them).
  2. Persists the binding in `StationTaskSessions.join/1` and triggers `give/3`
     unless `give: false` is passed.
  """
  def register_slot_binding(entry) when is_map(entry) do
    pid = entry[:participant_id] || get_in(entry[:start] || %{}, ["participant_id"])
    start_map = if is_map(entry[:start]), do: entry[:start], else: %{}
    run_part = start_map["connector_run_id"] || ""

    req_answered =
      case entry[:answered] do
        n when is_integer(n) and n >= 0 -> n
        _ -> 0
      end

    candidate_token =
      "#{entry[:session]}@#{run_part}:#{SalixStore.Ids.new_session_id()}"

    expected_invite_id = entry[:expected_pending_invite_id]

    enriched_start =
      start_map
      |> Map.put("binding_token", candidate_token)
      |> then(fn s ->
        if is_binary(expected_invite_id) and expected_invite_id != "" do
          existing_ids = List.wrap(s["committed_invite_ids"])

          s
          |> Map.put_new("invite_id", expected_invite_id)
          |> Map.put("claim_token", expected_invite_id)
          |> Map.put("claim_confirmed", false)
          |> Map.put("committed_invite_ids", Enum.uniq(existing_ids ++ [expected_invite_id]))
        else
          s
        end
      end)

    tokenized_entry =
      entry
      |> Map.put(:start, enriched_start)
      |> Map.put(:tx_guard, entry[:pre_join_check])

    join_fun = fn ->
      do_join_with_readback(tokenized_entry, candidate_token, req_answered)
    end

    bind_res =
      if is_binary(pid) and pid != "" do
        case SalixIM.ConversationServer.bind_task_participant_session(
               entry.group_id,
               entry.conversation_id,
               pid,
               join_fun
             ) do
          :ok ->
            :ok

          {:error, :not_found} ->
            if conversations() != SalixWeb.StationTasks.Conversations do
              with :ok <-
                     strict_ensure_participant_active(entry.group_id, entry.conversation_id, pid),
                   {:ok, _tok} <- join_fun.() do
                :ok
              end
            else
              {:error, :not_found}
            end

          {:error, _} = err ->
            err
        end
      else
        case join_fun.() do
          {:ok, _tok} -> :ok
          {:error, _} = err -> err
        end
      end

    with :ok <- bind_res do
      if entry[:give] != false do
        give(entry.group_id, entry.conversation_id, entry.device_id)
      end

      :ok
    end
  end

  defp do_join_with_readback(tokenized_entry, candidate_token, req_answered) do
    req_slot = get_in(tokenized_entry[:start] || %{}, ["slot"]) || "lead"
    req_start_seq = get_in(tokenized_entry[:start] || %{}, ["start_seq"])
    req_invite_id = tokenized_entry[:expected_pending_invite_id]

    case StationTaskSessions.join_with_token(tokenized_entry) do
      {:ok, committed_token} ->
        final_token =
          if is_binary(committed_token) and committed_token != "",
            do: committed_token,
            else: candidate_token

        {:ok, final_token}

      {:error, {:stale_slot_binding, _}} = stale_err ->
        stale_err

      {:error, _} = join_err ->
        case StationTaskSessions.of_task(
               tokenized_entry.group_id,
               tokenized_entry.conversation_id
             ) do
          {:ok, rows} ->
            row =
              Enum.find(
                rows,
                &(not StationTaskSessions.awaited?(&1) and
                    &1.device_id == tokenized_entry.device_id and
                    &1.session == tokenized_entry.session and
                    (get_in(&1.start || %{}, ["slot"]) || "lead") == req_slot)
              )

            existing_tok = if row, do: get_in(row.start || %{}, ["binding_token"]), else: nil
            has_valid_tok? = is_binary(existing_tok) and existing_tok != ""
            row_answered = if row, do: row.answered || 0, else: -1
            row_start_seq = if row, do: get_in(row.start || %{}, ["start_seq"]) || 0, else: -1
            seq_ok? = not is_integer(req_start_seq) or row_start_seq >= req_start_seq

            invite_ok? =
              not (is_binary(req_invite_id) and req_invite_id != "") or
                (row != nil and
                   (get_in(row.start || %{}, ["invite_id"]) == req_invite_id or
                      req_invite_id in List.wrap(
                        get_in(row.start || %{}, ["committed_invite_ids"])
                      )))

            if row != nil and has_valid_tok? and row_answered >= req_answered and seq_ok? and
                 invite_ok? do
              {:ok, existing_tok}
            else
              join_err
            end

          {:error, _of_err} ->
            join_err
        end
    end
  end

  defp reserve_pending_multi_start(group, conversation, device, participant_id, start_entry) do
    reserve_fun = fn ->
      StationTaskSessions.append_pending_multi_start(group, conversation, device, start_entry)
    end

    if is_binary(participant_id) and participant_id != "" do
      mod = conversations()

      res =
        if function_exported?(mod, :reserve_task_participant_session, 4) do
          mod.reserve_task_participant_session(group, conversation, participant_id, reserve_fun)
        else
          SalixIM.ConversationServer.reserve_task_participant_session(
            group,
            conversation,
            participant_id,
            reserve_fun
          )
        end

      case res do
        {:error, :not_found} when mod != SalixWeb.StationTasks.Conversations ->
          reserve_fun.()

        other ->
          other
      end
    else
      reserve_fun.()
    end
  end

  defp handle_online_permanent_slot_refusal(group, conversation, device, slot, start_entry, err) do
    why_label =
      case err do
        {:error, {:station_refused, why}} -> to_string(why)
        {:error, :station_outdated} -> "station_outdated"
        _ -> "refused"
      end

    case deactivate_dropped_slot(group, conversation, start_entry, device) do
      {:error, :superseded} ->
        # A newer invite already replaced or cleared this pending entry: never write ETS,
        # never delete or mark the newer entry.
        err

      res when res in [:ok, {:ok, :already_bound}] ->
        # Always delegate orphan decision to `remove_pending_multi_starts` under `lock_device_tx`:
        # if an active row already holds `invite_id` it skips writing orphan; if an older binding A
        # holds the slot while X was dispatched, X is accurately recorded for fenced revocation.
        invite_id = start_entry["invite_id"]

        remove_target =
          cond do
            is_binary(invite_id) and invite_id != "" and err == {:error, :station_outdated} ->
              {slot, invite_id, :record_orphan_if_dispatched}

            is_binary(invite_id) and invite_id != "" ->
              {slot, invite_id, :record_orphan}

            true ->
              pending_remove_target(slot, invite_id)
          end

        case remove_pending_starts(
               group,
               conversation,
               device,
               [remove_target],
               []
             ) do
          {:ok, _} ->
            clear_pending_deactivation(group, conversation, device, slot, start_entry)
            err

          {:error, rm_err} ->
            Logger.warning(
              "failed to remove permanently refused pending start for slot #{slot} on Task #{conversation}: #{inspect(rm_err)}; locking refusal guard for retry"
            )

            persist_refusal_and_schedule(
              group,
              conversation,
              device,
              slot,
              start_entry,
              why_label,
              err
            )
        end

      {:error, _} ->
        persist_refusal_and_schedule(
          group,
          conversation,
          device,
          slot,
          start_entry,
          why_label,
          err
        )
    end
  end

  defp persist_refusal_and_schedule(
         group,
         conversation,
         device,
         slot,
         start_entry,
         why_label,
         err
       ) do
    # Lock refusal guard in-process BEFORE attempting DB backoff write so even if DB
    # persistence fails transiently, the giver NEVER sends a second `task.invite`!
    record_pending_deactivation(group, conversation, device, slot, start_entry, why_label)

    persist_res =
      persist_online_add_backoff(
        group,
        conversation,
        device,
        slot,
        Map.merge(
          %{
            "pending_deactivation" => true,
            "refusal_reason" => why_label
          },
          expected_invite_id_meta(start_entry["invite_id"])
        )
      )

    # Always wake the giver so quiet tasks never stall even if backoff write failed transiently.
    give(group, conversation, device)

    if err == {:error, :station_outdated} and persist_res != :ok do
      # Local capability precheck never sent an RPC to Station; since DB persistence
      # of `pending_deactivation` also failed, do NOT claim a settled permanent refusal.
      {:error, :binding_state_unavailable}
    else
      err
    end
  end

  defp persist_online_add_backoff(group, conversation, device, slot, extra) do
    case task_sessions().update_pending_multi_starts_backoff(
           group,
           conversation,
           device,
           %{
             slot =>
               Map.merge(
                 %{
                   "attempts" => 1,
                   "next_retry_at" =>
                     SystemsClock.system_time(:millisecond) + secondary_retry_delay_ms(1)
                 },
                 extra
               )
           }
         ) do
      :ok ->
        :ok

      {:error, persist_err} = err ->
        Logger.warning(
          "failed to persist pending_multi_starts backoff for slot #{slot} on Task #{conversation}: #{inspect(persist_err)}"
        )

        err
    end
  end

  defp schedule_online_add_retry(group, conversation, device, slot, expected_invite_id) do
    _ =
      persist_online_add_backoff(
        group,
        conversation,
        device,
        slot,
        expected_invite_id_meta(expected_invite_id)
      )

    give(group, conversation, device)
    :ok
  end

  defp remove_pending_starts(group, conversation, device, targets, opts) do
    mod = task_sessions()

    if opts != [] and Code.ensure_loaded?(mod) and
         function_exported?(mod, :remove_pending_multi_starts, 5) do
      mod.remove_pending_multi_starts(group, conversation, device, targets, opts)
    else
      mod.remove_pending_multi_starts(group, conversation, device, targets)
    end
  end

  defp mark_pending_dispatched(group, conversation, device, slot, invite_id) do
    if is_binary(invite_id) and invite_id != "" do
      mod = task_sessions()

      if Code.ensure_loaded?(mod) and
           function_exported?(mod, :mark_pending_multi_start_dispatched, 5) do
        mod.mark_pending_multi_start_dispatched(group, conversation, device, slot, invite_id)
      else
        StationTaskSessions.mark_pending_multi_start_dispatched(
          group,
          conversation,
          device,
          slot,
          invite_id
        )
      end
    else
      :ok
    end
  end

  defp update_orphan_leave_backoff(group, conversation, device, slot, session, claim_token, meta) do
    mod = task_sessions()

    if Code.ensure_loaded?(mod) and
         function_exported?(mod, :update_pending_orphan_leave_backoff, 7) do
      mod.update_pending_orphan_leave_backoff(
        group,
        conversation,
        device,
        slot,
        session,
        claim_token,
        meta
      )
    else
      StationTaskSessions.update_pending_orphan_leave_backoff(
        group,
        conversation,
        device,
        slot,
        session,
        claim_token,
        meta
      )
    end
  end

  defp pending_remove_target(slot, invite_id) when is_binary(invite_id) and invite_id != "",
    do: {slot, invite_id}

  defp pending_remove_target(slot, _), do: slot

  defp expected_invite_id_meta(invite_id) when is_binary(invite_id) and invite_id != "",
    do: %{"expected_invite_id" => invite_id}

  defp expected_invite_id_meta(_), do: %{}

  defp put_retry_update(retry_updates, slot, entry, meta) do
    Map.put(
      retry_updates,
      slot,
      Map.merge(meta, expected_invite_id_meta(entry["invite_id"]))
    )
  end

  defp fetch_participants(group, conversation) do
    mod = conversations()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :participants, 2) do
      mod.participants(group, conversation)
    else
      {:error, :participants_not_implemented}
    end
  end

  defp strict_ensure_participant_active(group, conversation, pid) do
    case fetch_participants(group, conversation) do
      {:ok, list} when is_list(list) ->
        case Enum.find(list, &(&1["participant_id"] == pid)) do
          %{"state" => "inactive"} -> {:error, :participant_inactive}
          %{} -> :ok
          nil -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Asks the station `device_id` to start a Session for Task `conversation_id`.
  `{:ok, session}`, or why not: `:device_offline`, `:station_outdated`, or the
  station's refusal. The Group's Cloud VM whose Workload is not `ready`, or
  whose station is not connected, is `{:ok, :when_connected}`: Salix wakes it,
  and it is invited once it is up (`joined/1`, `vm_ready/2`).
  """
  @impl SalixIM.Ports.TaskStations
  def invite(invitation) do
    case invite_with_run(invitation) do
      {:ok, {session, _used_run_id}} -> {:ok, session}
      {:ok, :when_connected} -> {:ok, :when_connected}
      {:error, _} = err -> err
    end
  end

  @doc """
  Same as `invite/1`, but returns `{:ok, {session, used_run_id}}` carrying the
  exact `connector_run_id` that executed the `task.invite` RPC so callers can
  persist it into `joined/1` without ever re-reading the current connection.
  """
  @impl SalixIM.Ports.TaskStations
  def invite_with_run(%{tenant_id: tenant, group_id: group, device_id: device} = invitation) do
    multi? = invitation[:multi_session] == true or invitation[:join] == true

    with :ok <- SalixStore.ComputeStation.admit_device(tenant, group, device),
         {:ok, start} <- start(invitation),
         :up <- cloud_vm_up(group, device),
         :ok <- maybe_check_multi_capability(tenant, group, device, multi?) do
      ask_invite(
        tenant,
        group,
        device,
        invitation.conversation_id,
        start,
        invitation[:answered] || 0,
        invitation[:replace] == true,
        slot: invitation[:slot] || get_in(start, ["slot"]),
        join: invitation[:join] == true,
        multi_session: multi?,
        claim_token: invitation[:claim_token],
        invite_id: invitation[:invite_id]
      )
    end
  end

  defp maybe_check_multi_capability(_tenant, _group, _device, false), do: :ok

  defp maybe_check_multi_capability(tenant, group, device, true) do
    case check_multi_session(tenant, group, %{"device_id" => device}) do
      {:error, :device_offline} -> not_connected(group, device) |> normalize_cap_check()
      other -> other
    end
  end

  defp normalize_cap_check({:ok, :when_connected}), do: :ok
  defp normalize_cap_check(other), do: other

  # A Task on a Group Station that names no model runs the platform's
  # worker model, which Salix lends that station for Codex
  # (`SalixWeb.StationLLM`), as a Worker inside Salix would. Another station,
  # a coding sandbox among them, runs its runtime's own default: a sandbox
  # runs on the subscription lent to it, which may not serve the platform's
  # model.
  defp start(%{start: start, tenant_id: tenant, group_id: group, device_id: device}) do
    start = resolve_start_person(tenant, group, start)
    group_station? = group_station?(group, device)

    case {group_station? and blank?(start["model"]), start["runtime"], SalixWeb.StationLLM.tier()} do
      {false, _runtime, _tier} ->
        {:ok, start}

      {true, runtime, {:ok, tier}} when runtime in [nil, "", "codex"] ->
        {:ok, Map.merge(start, %{"runtime" => "codex", "model" => tier["model"]})}

      {true, "claude", {:ok, _tier}} ->
        {:ok, start}

      {true, _runtime, _no_tier} ->
        {:ok, start}
    end
  end

  defp resolve_start_person(tenant, group, %{"person" => person} = start)
       when is_binary(person) and person != "" do
    if String.contains?(person, "@") do
      start
    else
      case StationMembers.member(tenant, group, person) do
        {:ok, %{"email" => email}} when is_binary(email) and email != "" ->
          Map.put(start, "person", email)

        _ ->
          start
      end
    end
  end

  defp resolve_start_person(_tenant, _group, start), do: start

  defp blank?(value), do: value in [nil, ""]

  defp group_station?(group, device) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    case SalixStore.ComputeStation.device_owner(tenant, group, device) do
      {_kind, %{"owner" => owner}} when owner in ["group_default", "group_station"] -> true
      :unmanaged -> device == SalixStore.RuntimeIds.cloud_vm_device_id(group)
      _ -> false
    end
  end

  defp ask_invite(tenant, group, device, conversation, start, answered, replace, opts) do
    slot = Keyword.get(opts, :slot)
    join? = Keyword.get(opts, :join) == true
    multi? = Keyword.get(opts, :multi_session) == true or join?
    claim_token = Keyword.get(opts, :claim_token)
    invite_id = Keyword.get(opts, :invite_id)

    case admitted_run_with_caps(tenant, group, device) do
      {:error, :device_offline} ->
        not_connected(group, device)

      {:error, _} = error ->
        error

      {:ok, run_id, caps} ->
        if multi? and not SalixStore.StationReadiness.multi_session_ready?(caps) do
          {:error, :station_outdated}
        else
          wire_start =
            if is_map(start), do: Map.delete(start, "connector_run_id"), else: start

          params =
            %{"task" => conversation, "start" => wire_start}
            |> put_answered(answered)
            |> put_links(group, conversation)
            |> then(&if(replace, do: Map.put(&1, "replace", true), else: &1))
            |> then(&if(is_binary(slot) and slot != "", do: Map.put(&1, "slot", slot), else: &1))
            |> then(&if(join?, do: Map.put(&1, "join", true), else: &1))
            |> then(
              &if(is_binary(claim_token) and claim_token != "",
                do: Map.put(&1, "claim_token", claim_token),
                else: &1
              )
            )
            |> then(
              &if(is_binary(invite_id) and invite_id != "",
                do: Map.put(&1, "invite_id", invite_id),
                else: &1
              )
            )

          case connector().request(run_id, "task.invite", params, timeout: @invite_timeout_ms) do
            {:ok, %{"session" => session} = answer} when is_binary(session) and session != "" ->
              expected_slot = if is_binary(slot) and slot != "", do: slot, else: "lead"

              if multi? and answer["slot"] != expected_slot do
                {:error, :station_outdated}
              else
                {:ok, {session, run_id}}
              end

            {:ok, _answer} ->
              {:error, {:station_refused, "the station started no Session"}}

            {:error, :disconnected} ->
              not_connected(group, device)

            {:error, reason} when is_binary(reason) ->
              if transient_station_refusal_message?(reason) do
                {:error, {:station_transient, reason}}
              else
                {:error, {:station_refused, reason}}
              end

            {:error, reason} ->
              {:error, {:station_invite_unknown, reason}}
          end
        end
    end
  end

  # The Group's Cloud VM takes a Task once its Workload is `ready`: a wake's
  # Container restores the archive and then starts its station, and while
  # the VM wakes the device record may still show the Container before as
  # connected. Until the VM is ready, its station is not asked: it is invited
  # when the VM is ready (`vm_ready/2`). A Group with no Workload record has
  # nothing waking: its station, when connected, is up. Another station is
  # up when connected.
  defp cloud_vm_up(group, device) do
    if device == SalixStore.RuntimeIds.cloud_vm_device_id(group) do
      case SalixStore.Compute.group_workload(group) do
        {:ok, %{"status" => status}} when status != "ready" -> {:ok, :when_connected}
        _ -> :up
      end
    else
      :up
    end
  end

  # A person's station comes back when its person opens the laptop: a Task
  # for it is not made. The Group's Cloud VM comes back when Salix wakes it:
  # the Task is made, and the station invited when it connects.
  defp not_connected(group, device) do
    if device == SalixStore.RuntimeIds.cloud_vm_device_id(group),
      do: {:ok, :when_connected},
      else: {:error, :device_offline}
  end

  @doc """
  The station's Session takes part in the Task from now on, and is given it
  from its start. With no Session, the station is expected: it is given the
  Task as any station is (its VM woken), and invited once it is connected.
  """
  @impl SalixIM.Ports.TaskStations
  def joined(%{session: nil} = row) do
    with :ok <- StationTaskSessions.expect(row) do
      give(row.group_id, row.conversation_id, row.device_id)
      :ok
    end
  end

  def joined(row) do
    # Never re-read `online_run` here: a reconnect between `invite` and `joined`
    # would stamp the newer `run_B` onto `session_A`! Preserve whatever
    # `connector_run_id` came from `invite_with_run` (via `row[:connector_run_id]`
    # or `row[:start]["connector_run_id"]`).
    row =
      case row[:connector_run_id] do
        run_id when is_binary(run_id) and run_id != "" ->
          start_map = if is_map(row[:start]), do: row[:start], else: %{}
          Map.put(row, :start, Map.put_new(start_map, "connector_run_id", run_id))

        _ ->
          row
      end

    with :ok <- StationTaskSessions.join(row) do
      give(row.group_id, row.conversation_id, row.device_id)
      :ok
    end
  end

  @doc "Reserves a coding Task's sandbox (`SalixWeb.CodingSandboxes.reserve/1`)."
  @impl SalixIM.Ports.TaskStations
  def sandbox(reservation), do: SalixWeb.CodingSandboxes.reserve(reservation)

  @impl SalixIM.Ports.TaskStations
  def hydrate_participant_ids(tenant, conversation, pid_by_slot),
    do: SalixWeb.CodingSandboxes.hydrate_participant_ids(tenant, conversation, pid_by_slot)

  @impl SalixIM.Ports.TaskStations
  def leave_device(tenant, group, conversation, device) do
    clear_device_pending_deactivations(group, conversation, device)
    tell_left(tenant, group, conversation, device)
    :ok
  end

  @impl SalixIM.Ports.TaskStations
  def leave_session(
        tenant,
        group,
        conversation,
        device,
        session,
        run_id,
        claim_token \\ nil,
        slot \\ nil
      )
      when (is_binary(session) and session != "") or (is_binary(slot) and slot != "") do
    case request_leave_session(
           tenant,
           group,
           conversation,
           device,
           session,
           run_id,
           claim_token,
           slot
         ) do
      {:ok, true} ->
        :ok

      {:ok, :kept} ->
        :ok

      other when other in [{:ok, false}, {:error, :station_outdated}] ->
        if is_binary(claim_token) and claim_token != "" do
          schedule_pending_leave(tenant, group, conversation, device, session, slot, claim_token)
        end

        :ok
    end
  end

  defp fenced_leave_run(tenant, group, device, preferred_run_id) do
    case admitted_run_with_caps(tenant, group, device) do
      {:ok, current_run, caps} ->
        cond do
          is_binary(preferred_run_id) and preferred_run_id != "" and
              current_run != preferred_run_id ->
            {:error, :device_offline}

          not SalixStore.StationReadiness.multi_session_ready?(caps) ->
            {:error, :station_outdated}

          true ->
            {:ok, current_run}
        end

      {:error, _} = err ->
        err
    end
  end

  defp request_leave_session(
         tenant,
         group,
         conversation,
         device,
         session,
         run_id,
         claim_token,
         slot
       ) do
    has_session? = is_binary(session) and session != ""
    has_slot? = is_binary(slot) and slot != ""
    has_token? = is_binary(claim_token) and claim_token != ""
    fenced? = has_session? or has_slot? or has_token?

    run_res =
      if fenced? do
        fenced_leave_run(tenant, group, device, run_id)
      else
        case if(is_binary(run_id) and run_id != "",
               do: run_id,
               else: online_run(tenant, group, device)
             ) do
          r when is_binary(r) and r != "" -> {:ok, r}
          _ -> {:error, :device_offline}
        end
      end

    case run_res do
      {:error, :station_outdated} ->
        {:error, :station_outdated}

      {:error, _} ->
        {:ok, false}

      {:ok, run} ->
        params =
          %{"task" => conversation}
          |> then(&if(has_session?, do: Map.put(&1, "session", session), else: &1))
          |> then(&if(has_slot?, do: Map.put(&1, "slot", slot), else: &1))
          |> then(&if(has_token?, do: Map.put(&1, "claim_token", claim_token), else: &1))

        case connector().request(run, "task.leave", params, timeout: @status_timeout_ms) do
          {:ok, answer} ->
            cond do
              has_token? and is_map(answer) and answer["kept"] == true ->
                Logger.warning(
                  "fenced task.leave kept committed or shared session: group=#{group} task=#{conversation} device=#{device} slot=#{inspect(slot)} session=#{inspect(session)} claim_token=#{inspect(claim_token)}"
                )

                {:ok, :kept}

              has_token? and is_map(answer) and
                  (Map.has_key?(answer, "removed") or Map.has_key?(answer, "kept")) ->
                {:ok, true}

              has_token? ->
                Logger.warning(
                  "fenced task.leave received legacy ACK without explicit removed/kept: group=#{group} task=#{conversation} device=#{device} slot=#{inspect(slot)} session=#{inspect(session)} answer=#{inspect(answer)}"
                )

                {:ok, false}

              true ->
                {:ok, true}
            end

          _ ->
            {:ok, false}
        end
    end
  end

  defp revoke_orphan_slot_session(
         tenant,
         group,
         conversation,
         device,
         slot,
         session,
         used_run_id,
         claim_token
       ) do
    session_str = if is_binary(session), do: session, else: ""

    if is_binary(claim_token) and claim_token != "" and is_binary(slot) and slot != "" do
      record_res =
        task_sessions().record_pending_orphan_leave(group, conversation, device, %{
          "slot" => slot,
          "session" => session_str,
          "claim_token" => claim_token
        })

      case request_leave_session(
             tenant,
             group,
             conversation,
             device,
             session_str,
             used_run_id,
             claim_token,
             slot
           ) do
        res when res in [{:ok, true}, {:ok, :kept}] ->
          if record_res == :ok do
            _ =
              task_sessions().remove_pending_orphan_leave(
                group,
                conversation,
                device,
                slot,
                session_str,
                claim_token
              )
          end

          :ok

        other when other in [{:ok, false}, {:error, :station_outdated}] ->
          if record_res == :ok do
            wake(group, conversation, device)
            give(group, conversation, device)
            :ok
          else
            Logger.warning(
              "orphan leave persistence failed (#{inspect(record_res)}) and station is unreachable; scheduling recoverable pending_leave: group=#{group} task=#{conversation} device=#{device} slot=#{slot} session=#{session_str}"
            )

            schedule_pending_leave(
              tenant,
              group,
              conversation,
              device,
              session_str,
              slot,
              claim_token
            )

            wake(group, conversation, device)
            give(group, conversation, device)
            {:error, {:orphan_leave_unpersisted, record_res}}
          end
      end
    else
      leave_session(tenant, group, conversation, device, session, used_run_id, claim_token, slot)
    end
  end

  @pending_leave_max_retries 5
  @pending_leave_ttl_ms 86_400_000

  defp schedule_pending_leave(tenant, group, conversation, device, session, slot, claim_token) do
    key = {:pending_leave, group, conversation, device, slot || session, claim_token}

    case SystemsRuntime.Registry.lookup(SalixWeb.StationTasks.Registry, key) do
      [{pid, _}] ->
        SystemsRuntime.Proc.send(pid, :retry_now)

      [] ->
        SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
          case SystemsRuntime.Registry.register(SalixWeb.StationTasks.Registry, key, nil) do
            {:ok, _} ->
              deadline_ms = SystemsClock.system_time(:millisecond) + @pending_leave_ttl_ms

              pending_leave_loop(
                tenant,
                group,
                conversation,
                device,
                session,
                slot,
                claim_token,
                0,
                deadline_ms
              )

              SystemsRuntime.Registry.unregister(SalixWeb.StationTasks.Registry, key)

            {:error, {:already_registered, pid}} ->
              SystemsRuntime.Proc.send(pid, :retry_now)
          end
        end)
    end

    :ok
  end

  # After active exponential retries are exhausted, stay passively registered (zero polling)
  # awaiting `hello` -> `wake_pending_leaves/2` (`:retry_now`) until Station confirms or 24h TTL expires.
  defp pending_leave_loop(
         tenant,
         group,
         conversation,
         device,
         session,
         slot,
         claim_token,
         attempts,
         deadline_ms
       ) do
    now_ms = SystemsClock.system_time(:millisecond)
    remaining_ttl = deadline_ms - now_ms

    if remaining_ttl <= 0 do
      :ok
    else
      wait =
        if attempts < @pending_leave_max_retries do
          min(remaining_ttl, min(16_000, 1_000 * Integer.pow(2, attempts)))
        else
          remaining_ttl
        end

      woke =
        SystemsClock.vreceive do
          :retry_now -> :retry_now
        after
          wait -> if attempts < @pending_leave_max_retries, do: :backoff, else: :ttl_expired
        end

      if woke == :ttl_expired do
        :ok
      else
        case request_leave_session(
               tenant,
               group,
               conversation,
               device,
               session,
               nil,
               claim_token,
               slot
             ) do
          res when res in [{:ok, true}, {:ok, :kept}] ->
            if is_binary(slot) and slot != "" and is_binary(claim_token) and claim_token != "" do
              _ =
                task_sessions().remove_pending_orphan_leave(
                  group,
                  conversation,
                  device,
                  slot,
                  if(is_binary(session), do: session, else: ""),
                  claim_token
                )
            end

            :ok

          {:error, :station_outdated} ->
            persisted? =
              if is_binary(slot) and slot != "" and is_binary(claim_token) and claim_token != "" do
                task_sessions().record_pending_orphan_leave(group, conversation, device, %{
                  "slot" => slot,
                  "session" => if(is_binary(session), do: session, else: ""),
                  "claim_token" => claim_token
                }) == :ok
              else
                false
              end

            if persisted? do
              :ok
            else
              next_attempts = if woke == :retry_now, do: 0, else: attempts + 1

              pending_leave_loop(
                tenant,
                group,
                conversation,
                device,
                session,
                slot,
                claim_token,
                next_attempts,
                deadline_ms
              )
            end

          {:ok, false} ->
            if is_binary(slot) and slot != "" and is_binary(claim_token) and claim_token != "" do
              _ =
                task_sessions().record_pending_orphan_leave(group, conversation, device, %{
                  "slot" => slot,
                  "session" => if(is_binary(session), do: session, else: ""),
                  "claim_token" => claim_token
                })
            end

            next_attempts = if woke == :retry_now, do: 0, else: attempts + 1

            pending_leave_loop(
              tenant,
              group,
              conversation,
              device,
              session,
              slot,
              claim_token,
              next_attempts,
              deadline_ms
            )
        end
      end
    end
  end

  defp wake_pending_leaves(group, device) do
    pids =
      Registry.select(SalixWeb.StationTasks.Registry, [
        {{{:pending_leave, group, :_, device, :_, :_}, :"$1", :_}, [], [:"$1"]}
      ])

    Enum.each(pids, &SystemsRuntime.Proc.send(&1, :retry_now))
    :ok
  rescue
    _ -> :ok
  end

  @impl SalixIM.Ports.TaskStations
  def update_github(group, conversation, github),
    do: SalixWeb.CodingSandboxes.update_github(group, conversation, github)

  @doc "Coding Tasks' terminal links (`SalixWeb.CodingSandboxes.terminal_urls/2`)."
  @impl SalixIM.Ports.TaskStations
  def terminal_urls(group, conversations),
    do: SalixWeb.CodingSandboxes.terminal_urls(group, conversations)

  @doc "A coding Task's status changed (`SalixWeb.CodingSandboxes.task_status/3`)."
  @impl SalixIM.Ports.TaskStations
  def task_status(group, conversation, status),
    do: SalixWeb.CodingSandboxes.task_status(group, conversation, status)

  @doc "Task `conversation`'s status now: `{:ok, status}`, or an error when it cannot be read."
  def current_status(group, conversation), do: conversations().status(group, conversation)

  @doc "Task `conversation`'s owner: `{:ok, user_id}`, or an error when it has none or cannot be read."
  def owner(group, conversation), do: conversations().owner(group, conversation)

  @doc """
  Task `conversation` as `SalixIM.Conversations.get_group_conversation/2`
  reads it, its `source_refs` with it: `{:ok, conversation}`, or an error
  when it cannot be read.
  """
  def task(group, conversation), do: conversations().task(group, conversation)

  @doc "Task `conversation`'s last Message, or an error when it has none or cannot be read."
  def last_message(group, conversation), do: conversations().last(group, conversation)

  @doc """
  Whether Task `conversation`'s latest Message of a person or Agent is one its
  Worker `agent_id` has not answered, among the last #{@recent_messages}.
  System Messages (a status, a watch's) and Worker Messages of milestones alone
  are passed over; Salix's notices are the Worker's own.
  `{:ok, boolean}`, or an error when the Messages cannot be read.
  """
  def worker_owes_answer?(group, conversation, agent_id) do
    with {:ok, messages} <- conversations().recent(group, conversation, @recent_messages) do
      latest =
        messages
        |> Enum.reject(&passed_over?(&1, agent_id))
        |> Enum.max_by(& &1["seq"], fn -> nil end)

      {:ok, not is_nil(latest) and latest["agent_id"] != agent_id}
    end
  end

  defp passed_over?(%{"actor_type" => "system"}, _agent_id), do: true

  defp passed_over?(%{"agent_id" => agent_id} = message, agent_id),
    do: SalixIM.ConversationMilestone.only_milestones?(message["content"])

  defp passed_over?(_message, _agent_id), do: false

  @doc """
  Asks the station taking part in Task `conversation` `method` about its
  Session (`params` plus `task` and `session`), within `timeout` ms.
  Defaults to the primary slot (or explicit `params["slot"]`), never
  `Enum.min_by(&1.sent)`.
  `{:error, :not_connected}` when its station is not connected now.
  """
  def ask(group, conversation, method, params, timeout \\ @status_timeout_ms) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         [_ | _] = active_rows <- Enum.reject(rows, &StationTaskSessions.awaited?/1),
         %{tenant_id: tenant, device_id: device, session: session} <-
           pick_ask_row(active_rows, params["slot"]),
         {:ok, run_id} <- admitted_run(tenant, group, device) do
      params = Map.merge(params, %{"task" => conversation, "session" => session})

      case connector().request(run_id, method, params, timeout: timeout) do
        {:ok, answer} when is_map(answer) -> {:ok, answer}
        {:ok, _answer} -> {:error, :bad_answer}
        {:error, :disconnected} -> {:error, :not_connected}
        {:error, reason} -> {:error, {:station, reason(reason)}}
      end
    else
      {:ok, []} -> {:error, :not_station}
      [] -> {:error, :not_station}
      nil -> {:error, :not_station}
      {:error, _} = error -> error
    end
  end

  defp pick_ask_row(rows, slot) when is_binary(slot) and slot != "" do
    Enum.find(rows, &(slot_of(&1) == slot))
  end

  defp pick_ask_row(rows, _slot) do
    Enum.find(rows, &primary_row?/1) || hd(rows)
  end

  defp slot_of(%{start: %{"slot" => slot}}) when is_binary(slot) and slot != "", do: slot
  defp slot_of(_row), do: "lead"

  defp primary_row?(%{start: %{"is_primary" => false}}), do: false
  defp primary_row?(%{start: %{"is_primary" => true}}), do: true
  defp primary_row?(row), do: slot_of(row) == "lead"

  @doc """
  Writes `text` into Task `conversation` as its Worker, as the station's
  Session would, for what Salix says about the Task's sandbox. Once per `key`.
  It is for the person: on its own it wakes no sandbox
  (`SalixWeb.CodingSandboxes.wake/2`). `kind` is the Message's
  `metadata.kind`: `cloud_vm_notice` for the Cloud VM cutover
  (`SalixWeb.Migrations.CloudVMCutover`).
  """
  def notice(group, conversation, agent_id, key, text, kind \\ "sandbox_notice") do
    row = %{conversation_id: conversation, agent_id: agent_id}

    with {:ok, participant_id} <- worker(group, row) do
      conversations().append(group, conversation, agent_id, %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => agent_id,
        "participant_id" => participant_id,
        "content" => truncate(text),
        "client_request_id" => "sandbox-notice:" <> digest([conversation, key]),
        "metadata" => %{"kind" => kind}
      })
    end
  end

  @doc """
  The Task now runs elsewhere: the stations that took part leave it, those
  that do not run it now told so; `to` (the row `joined/1` takes, or nil when
  it runs inside Salix now) takes part and is given the Task from its start.
  """
  @impl SalixIM.Ports.TaskStations
  def moved(%{group_id: group, conversation_id: conversation} = move) do
    to = move[:to]

    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation) do
      rows
      |> Enum.map(&{&1.tenant_id, &1.device_id})
      |> Enum.uniq()
      |> Enum.each(fn {tenant, device} ->
        clear_device_pending_deactivations(group, conversation, device)
        StationTaskSessions.leave(group, conversation, device)

        if is_nil(to) or to.device_id != device,
          do: tell_left(tenant, group, conversation, device)
      end)

      if is_nil(to), do: :ok, else: joined(to)
    end
  end

  @doc "The Sessions of stations taking part in the Task, by device."
  @impl SalixIM.Ports.TaskStations
  def sessions(group, conversation) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         do: {:ok, Map.new(rows, &{&1.device_id, &1.session})}
  end

  # Best effort: a station not connected now is not told, and is given
  # nothing more of the Task all the same.
  defp tell_left(tenant, group, conversation, device) do
    with run_id when is_binary(run_id) <- online_run(tenant, group, device),
         {:ok, _answer} <-
           connector().request(run_id, "task.leave", %{"task" => conversation},
             timeout: @status_timeout_ms
           ) do
      :ok
    else
      other ->
        Logger.info(
          "a station that no longer runs a Task was not told: group=#{group} task=#{conversation} device=#{device} #{inspect(other)}"
        )

        :ok
    end
  end

  @doc "A Message was added to the Task: the stations taking part are given it. Never waits for them."
  @impl SalixIM.Ports.TaskStations
  def appended(group, conversation) do
    SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
      case StationTaskSessions.of_task(group, conversation) do
        # A coding Task whose sandbox's station never took it: the Message
        # asks for a sandbox that will.
        {:ok, []} ->
          SalixWeb.CodingSandboxes.appended(group, conversation)

        {:ok, rows} ->
          rows
          |> Enum.map(& &1.device_id)
          |> Enum.uniq()
          |> Enum.each(&give(group, conversation, &1))

        {:error, reason} ->
          Logger.warning("station task sessions not read: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc """
  Where the station taking part in the Task stands, for the Task's
  `SalixIM.StationTaskWatch`: one read of its participation, one of its device
  record and, for the Group's Cloud VM, one of the Group's Workload.
  `:not_station` when none takes part; `{:error, reason}` when one of the
  reads failed, to be asked again.
  """
  @impl SalixIM.Ports.TaskStations
  def standing(group, conversation) do
    with {:ok, [_ | _] = rows} <- StationTaskSessions.of_task(group, conversation) do
      # One station runs a Task; were there more, the one given the least is
      # the one the Task waits on.
      %{tenant_id: tenant, device_id: device, sent: sent} = Enum.min_by(rows, & &1.sent)
      place = place_of(group, device)

      with {:ok, vm_status} <- place_status(place, tenant, group, device) do
        {:ok,
         %{
           place: place,
           connected?: online_run(tenant, group, device) != nil,
           sent: sent,
           vm_status: vm_status
         }}
      end
    else
      {:ok, []} -> :not_station
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Queries all active session statuses (`task.status {all: true}`) on a station or
  sandbox Task. Aggregates across all active slots: `:idle` only when every slot
  is `:idle` with `pending == 0`, `for_ms` is `min(for_ms)` across slots, and
  `dirty`/`unpushed`/`unmerged`/`standing_unknown` are OR-ed across all workspaces.
  Falls back gracefully to single-session `task.status` answers from older stations.
  """
  @impl SalixIM.Ports.TaskStations
  def session_statuses(group, conversation) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         [_ | _] = active_rows <- Enum.reject(rows, &StationTaskSessions.awaited?/1),
         {:ok, authoritative_slots} <- authoritative_active_slots(group, conversation),
         %{tenant_id: tenant, device_id: device, session: session} <-
           pick_ask_row(active_rows, nil),
         {:ok, run_id} <- admitted_run(tenant, group, device) do
      expected_sessions_by_slot = Map.new(active_rows, &{slot_of(&1), &1.session})
      row_slots = MapSet.new(Map.keys(expected_sessions_by_slot))

      # Strict 1:1 between authoritative Conversation participants and DB bindings
      # (no extra unbound participant, no stale deactivated row left in DB).
      db_matches_authoritative? =
        length(active_rows) == MapSet.size(row_slots) and
          MapSet.equal?(authoritative_slots, row_slots)

      multi? = MapSet.size(authoritative_slots) > 1
      params = %{"task" => conversation, "session" => session, "all" => true}

      case connector().request(run_id, "task.status", params, timeout: @status_timeout_ms) do
        {:ok, %{"slots" => [_ | _] = raw_slots} = answer} ->
          slots = Enum.map(raw_slots, &parse_slot_status/1)

          if Enum.any?(slots, &is_nil/1) or not db_matches_authoritative? do
            :unknown
          else
            reported_by_slot = Map.new(slots, &{&1.slot, &1.session})
            reported_slots = MapSet.new(Map.keys(reported_by_slot))
            no_duplicate_slots? = length(slots) == MapSet.size(reported_slots)

            # Strict 1:1 equality across all three sets:
            # authoritative Conversation slots == DB bound slots == Station reported slots & sessions.
            if no_duplicate_slots? and MapSet.equal?(reported_slots, row_slots) and
                 reported_by_slot == expected_sessions_by_slot do
              {:ok, aggregate_slot_statuses(slots, answer)}
            else
              :unknown
            end
          end

        {:ok, %{"state" => state} = answer} when is_map_key(@session_states, state) ->
          if multi? or not db_matches_authoritative? do
            :unknown
          else
            case parse_single_status(answer) do
              nil ->
                :unknown

              parsed ->
                {:ok,
                 Map.put(parsed, :slots, [
                   Map.merge(parsed, %{slot: hd(MapSet.to_list(row_slots)), session: session})
                 ])}
            end
          end

        {:ok, _answer} ->
          :unknown

        {:error, reason} ->
          Logger.info(
            "a station was not asked where its Sessions of a Task stand: group=#{group} task=#{conversation} device=#{device} #{inspect(reason)}"
          )

          :unknown
      end
    else
      _ -> :unknown
    end
  end

  # Authoritative active worker slot set strictly from Conversation participants
  # (never unioned with DB rows so stale/deactivated bindings are detected).
  defp authoritative_active_slots(group, conversation) do
    case fetch_participants(group, conversation) do
      {:ok, list} when is_list(list) ->
        participant_slots =
          list
          |> Enum.filter(fn p ->
            p["actor_type"] == "agent" and p["role_label"] == "worker" and
              p["state"] != "inactive"
          end)
          |> Enum.map(&(SalixIM.TaskSessionSlots.worker_slot(&1) || "lead"))
          |> MapSet.new()

        {:ok, participant_slots}

      _ ->
        :error
    end
  end

  defp parse_single_status(%{"state" => state} = answer)
       when is_map_key(@session_states, state) do
    pending =
      case answer["pending"] do
        n when is_integer(n) and n >= 0 -> n
        nil -> 0
        _ -> nil
      end

    if is_integer(pending) do
      %{
        state: Map.fetch!(@session_states, state),
        pending: pending,
        for_ms: if(is_integer(answer["for_ms"]) and answer["for_ms"] >= 0, do: answer["for_ms"]),
        last_failure: last_failure(answer["last_failure"]),
        dirty: answer["dirty"] == true,
        unpushed: answer["unpushed"] == true,
        unmerged: answer["unmerged"] == true,
        standing_unknown: answer["standing_unknown"] == true
      }
    else
      nil
    end
  end

  defp parse_single_status(_answer), do: nil

  defp parse_slot_status(%{"state" => state, "pending" => pending, "session" => sess} = entry)
       when is_map_key(@session_states, state) and is_integer(pending) and pending >= 0 and
              is_binary(sess) and sess != "" do
    case parse_single_status(entry) do
      nil ->
        nil

      parsed ->
        Map.merge(parsed, %{
          slot: entry["slot"] || "lead",
          session: sess
        })
    end
  end

  defp parse_slot_status(_entry), do: nil

  defp aggregate_slot_statuses(slots, _answer) do
    states = Enum.map(slots, & &1.state)

    agg_state =
      cond do
        Enum.any?(states, &(&1 in [:running, :waiting])) -> :running
        Enum.any?(states, &(&1 == :cannot_start)) -> :cannot_start
        Enum.all?(states, &(&1 == :gone)) -> :gone
        Enum.all?(states, &(&1 == :idle)) -> :idle
        true -> :running
      end

    pending = slots |> Enum.map(& &1.pending) |> Enum.sum()

    for_ms =
      if Enum.all?(slots, &is_integer(&1.for_ms)) do
        slots |> Enum.map(& &1.for_ms) |> Enum.min()
      else
        nil
      end

    %{
      state: agg_state,
      pending: pending,
      for_ms: for_ms,
      last_failure: Enum.find_value(slots, & &1.last_failure),
      dirty: Enum.any?(slots, & &1.dirty),
      unpushed: Enum.any?(slots, & &1.unpushed),
      unmerged: Enum.any?(slots, & &1.unmerged),
      standing_unknown: Enum.any?(slots, & &1.standing_unknown),
      slots: slots
    }
  end

  @doc """
  Where the station's Session of the Task stands, for the Task's
  `SalixIM.StationTaskWatch` once the station has the delegation: one
  `task.status` request, which starts nothing there. `:unknown` when no
  station takes part, the station is not connected, it does not answer in
  #{@status_timeout_ms} ms, or it does not know the request (a station from
  before it).
  """
  @impl SalixIM.Ports.TaskStations
  def session_status(group, conversation) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         [_ | _] = active_rows <- Enum.reject(rows, &StationTaskSessions.awaited?/1),
         %{tenant_id: tenant, device_id: device, session: session} <-
           pick_ask_row(active_rows, nil),
         {:ok, run_id} <- admitted_run(tenant, group, device) do
      params = %{"task" => conversation, "session" => session}

      case connector().request(run_id, "task.status", params, timeout: @status_timeout_ms) do
        {:ok, %{"state" => state} = answer} when is_map_key(@session_states, state) ->
          case parse_single_status(answer) do
            nil -> :unknown
            parsed -> {:ok, parsed}
          end

        {:ok, _answer} ->
          :unknown

        {:error, reason} ->
          Logger.info(
            "a station was not asked where its Session of a Task stands: group=#{group} task=#{conversation} device=#{device} #{inspect(reason)}"
          )

          :unknown
      end
    else
      _ -> :unknown
    end
  end

  defp last_failure(text) when is_binary(text) and text != "",
    do: text |> String.slice(0, @last_failure_chars) |> String.trim()

  defp last_failure(_text), do: nil

  defp place_status(:cloud_vm, _tenant, group, _device), do: vm_status(group)

  # A coding Task's sandbox state (`starting`, `ready`, `stopped`…).
  defp place_status(:sandbox, tenant, _group, device) do
    case SalixStore.CodingSandboxes.get_by_device(tenant, device) do
      {:ok, workload} -> {:ok, workload.spec["state"]}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp place_status(:device, _tenant, _group, _device), do: {:ok, nil}

  # The Group's Cloud VM Workload status (`ready`, `waking`, `archived`…); nil
  # when the Group has no Cloud VM Workload at all. A Workload that cannot be
  # read now is an error, not a status.
  defp vm_status(group) do
    case SalixStore.Compute.group_workload(group) do
      {:ok, %{"status" => status}} when is_binary(status) and status != "" -> {:ok, status}
      {:ok, _workload} -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @doc "Salix started: every station taking part in a Task is given what it has not had."
  def give_all do
    case StationTaskSessions.all() do
      {:ok, rows} ->
        rows
        |> Enum.map(&{&1.group_id, &1.conversation_id, &1.device_id})
        |> Enum.uniq()
        |> Enum.each(fn {group, conversation, device} -> give(group, conversation, device) end)

      {:error, reason} ->
        Logger.warning("station task sessions not read: #{inspect(reason)}")
    end

    :ok
  end

  @doc "`task.hello` from the device of `view`: it is given what it missed of every Task it takes part in."
  def hello(%{tenant_id: tenant, group_id: group, device_id: device} = view, params) do
    run_id = Map.get(view, :connector_run_id) || online_run(tenant, group, device)
    with :ok <- give_device(tenant, group, device, had(params), run_id, :hello), do: {:ok, %{}}
  end

  @doc """
  The Group's Cloud VM Workload became `ready` (`previous` to `committed`,
  as its provider committed it): its station is invited to the Tasks it is
  expected in and given what waits for it. Its hello came while the VM was
  still waking, when it was not asked (`invite/1`). Any other write is
  nothing to the stations.
  """
  def vm_ready(
        %{"status" => was},
        %{"status" => "ready", "tenant_id" => tenant, "group_id" => group, "device_id" => device}
      )
      when was != "ready" and is_binary(device) do
    _ = give_device(tenant, group, device, nil, online_run(tenant, group, device), :vm_ready)
    :ok
  end

  def vm_ready(_previous, _committed), do: :ok

  # The station `device` is given what it missed of every Task it takes part
  # in; with `had` (how far it has each Task), from there.
  # `:vm_ready` NEVER stamps `connector_run_id` onto unverified `sent > 0` rows
  # (only `hello` reports authoritative `fetched`); `:hello` with `had == nil`
  # (very old station without `tasks`) safely resets `sent = 0` instead of trusting
  # an unverified positive watermark.
  defp give_device(tenant, group, device, had, run_id, source) do
    wake_pending_leaves(group, device)

    case StationTaskSessions.of_device(tenant, group, device) do
      {:ok, rows} ->
        taking = rows |> Enum.map(& &1.conversation_id) |> MapSet.new()

        # A Task it names that runs elsewhere now (it was not connected when the
        # Task moved, `moved/1`): its Sessions there leave it. A station names
        # only Tasks its Sessions still take part in, so it is told once. One it
        # was given nothing of yet may be one it is being invited to, not yet
        # recorded here: it has nothing to run, and is left alone.
        for {task, fetched} <- had || %{},
            fetched > 0 and not MapSet.member?(taking, task) do
          SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
            tell_left(tenant, group, task, device)
          end)
        end

        Enum.reduce(taking, :ok, fn conversation, acc ->
          fetched_res =
            case source do
              :hello when had != nil ->
                fetched_watermarks(
                  group,
                  conversation,
                  device,
                  Map.get(had, conversation, 0),
                  run_id
                )

              :hello when is_binary(run_id) and run_id != "" ->
                StationTaskSessions.reset_unconfirmed_hello(group, conversation, device, run_id)

              :hello ->
                :ok

              :vm_ready ->
                :ok
            end

          case fetched_res do
            :ok ->
              give(group, conversation, device)
              acc

            {:error, reason} ->
              Logger.warning(
                "station task fetched watermark update failed: group=#{group} task=#{conversation} device=#{device} #{inspect(reason)}"
              )

              if acc == :ok, do: {:error, reason}, else: acc
          end
        end)

      {:error, reason} ->
        Logger.warning("station task sessions not read: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetched_watermarks(group, conversation, device, fetched, run_id) do
    mod = task_sessions()

    if Code.ensure_loaded?(mod) and function_exported?(mod, :fetched, 5) do
      mod.fetched(group, conversation, device, fetched, run_id)
    else
      StationTaskSessions.fetched(group, conversation, device, fetched, run_id)
    end
  end

  # How far the station has each Task it names; nil when it names none at all
  # (a station from before `tasks`).
  defp had(%{"tasks" => tasks}) when is_list(tasks) do
    for %{"task" => task, "fetched" => fetched} <- tasks,
        is_binary(task) and is_integer(fetched) and fetched >= 0,
        into: %{},
        do: {task, fetched}
  end

  defp had(_params), do: nil

  @doc """
  Gives `device` the Messages of the Task it has not had. One giver at a time
  for each Task and station on this node; asked meanwhile, it gives once more
  (or at once, while it waits to give again).
  """
  def give(group, conversation, device) do
    key = {group, conversation, device}

    case SystemsRuntime.Registry.lookup(SalixWeb.StationTasks.Registry, key) do
      [{pid, _}] ->
        SystemsRuntime.Proc.send(pid, :give)

      [] ->
        SystemsRuntime.TaskSupervisor.start_child(SalixWeb.StationTasks.Supervisor, fn ->
          giver(key)
        end)
    end

    :ok
  end

  defp giver(key) do
    case SystemsRuntime.Registry.register(SalixWeb.StationTasks.Registry, key, nil) do
      {:ok, _} ->
        giving(key, 0)
        SystemsRuntime.Registry.unregister(SalixWeb.StationTasks.Registry, key)

        # Asked between the last look and letting go: given once more.
        SystemsRuntime.Proc.receive do
          :give -> giver(key)
        after
          0 -> :ok
        end

      {:error, {:already_registered, pid}} ->
        SystemsRuntime.Proc.send(pid, :give)
    end
  end

  defp giving(key, failures) do
    {group, conversation, device} = key

    case give_now(group, conversation, device, false) do
      result when result in [:ok, :unreachable, {:ok, :retry_pending}] ->
        # Not connected (:unreachable): it says hello when it is.
        if result == :unreachable, do: wake(group, conversation, device)

        pending_wait =
          case result do
            :ok ->
              next_pending_retry_wait_ms(group, conversation, device)

            {:ok, :retry_pending} ->
              next_pending_retry_wait_ms(group, conversation, device) ||
                secondary_retry_delay_ms(1)

            :unreachable ->
              nil
          end

        # Coalesced per `{group, conversation, device}` (1 giver per active Task-device pair,
        # capped at 30s per-slot backoff via `secondary_retry_delay_ms/1`) so backed-off secondaries
        # wake deterministically without polling or unbounded process cardinality.
        if is_integer(pending_wait) do
          SystemsClock.vreceive do
            :give -> giving(key, 0)
          after
            pending_wait -> giving(key, 0)
          end
        else
          SystemsRuntime.Proc.receive do
            :give -> giving(key, 0)
          after
            0 -> :ok
          end
        end

      {:error, reason} ->
        wait = min(@put_again_max_ms, 1_000 * Integer.pow(2, failures))

        Logger.warning(
          "a station taking part in a Task did not take what it was given; given again in #{wait} ms: #{inspect(reason)}"
        )

        SystemsClock.vreceive do
          :give -> :ok
        after
          wait -> :ok
        end

        giving(key, failures + 1)
    end
  end

  # A person's station comes back by itself. The Group's Cloud VM, archived or
  # stopped, comes back only when Salix, its control plane, wakes it: the
  # station that has something to take is the work that wakes it, asked as
  # other work for the VM is. Which device that is, the Group's Workload says;
  # a Group whose VM was never made has none, and the Cloud VM's station with
  # a Task to take asks for the VM to be made, as its Worker running a command
  # there would (`SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning/1`).
  # The VM's station then says hello and is given the Task. A wake already on
  # its way is the same wake; one that cannot be made is said once, and asked
  # again only when the station is next given something.
  defp wake(group, conversation, device) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    case SalixStore.ComputeStation.device_owner(tenant, group, device) do
      {:workload, %{"owner" => "coding_task"}} -> SalixWeb.CodingSandboxes.wake(group, device)
      _ -> wake_cloud_vm(group, conversation, device)
    end
  end

  # The Group's Cloud VM (`group_default`) is woken; a Group whose VM was
  # never made (`:none`) has it made for the Task's Worker; a Group Station
  # Workload on the Host is started by `wake_device` itself.
  defp wake_cloud_vm(group, conversation, device) do
    tenant = SalixStore.Ids.tenant_id_from_group!(group)

    result =
      case SalixStore.ComputeGroupStation.wake_device(tenant, group, device) do
        :group_default ->
          SalixWeb.GroupStationLifecycle.wake(group)

        :none ->
          if device == SalixStore.RuntimeIds.cloud_vm_device_id(group),
            do: make_vm(group, conversation),
            else: :ok

        other ->
          other
      end

    with {:error, reason} when reason != :runtime_waking <- result do
      Logger.warning(
        "the Cloud VM of a station with a Task to take was not woken; asked again when it is next given something: group=#{group} device=#{device} #{inspect(reason)}"
      )
    end

    :ok
  end

  # The Group's VM is made for the Task's Worker, when the Group's Cloud VM
  # switch lets it (`SalixAgent.CloudVM.allowed?/1`); the Compute reconciler
  # carries the creation out. A retired Cloud VM is not made, and a retired
  # one that sleeps is not woken (`SalixWeb.GroupStationLifecycle.wake/1`):
  # the Task's watch tells the Router its station is not ready
  # (`SalixIM.StationTaskWatch`).
  defp make_vm(group, conversation) do
    with :ok <-
           if(SalixAgent.Sandboxes.cloud_vm_retired?(group),
             do: {:error, :cloud_vm_retired},
             else: :ok
           ),
         {:ok, [%{agent_id: agent_id} | _]} <- StationTaskSessions.of_task(group, conversation),
         {:ok, %{"group_id" => ^group} = agent} <- SalixAgent.Control.get_record(agent_id),
         true <- SalixAgent.CloudVM.allowed?(agent) || {:error, :cloud_vm_disabled},
         {:ok, _record} <- SalixWeb.ComputeProviders.Cloudflare.ensure_provisioning(agent) do
      :ok
    else
      {:ok, _} -> {:error, :no_station_worker}
      {:error, _reason} = error -> error
    end
  end

  # `invited_again`: the station was invited again in this giving already.
  defp give_now(group, conversation, device, invited_again) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         [_ | _] = device_rows <- Enum.filter(rows, &(&1.device_id == device)),
         false <- Enum.all?(device_rows, &StationTaskSessions.awaited?/1) do
      active_rows = Enum.reject(device_rows, &StationTaskSessions.awaited?/1)

      case drain_pending_orphan_leaves(active_rows) do
        :unreachable ->
          :unreachable

        {:ok, blocked_slots, any_leave_failed?} ->
          case resume_pending_multi_starts(active_rows, blocked_slots) do
            :ok ->
              case give_active(active_rows, group, conversation, device, invited_again) do
                :ok when any_leave_failed? -> {:ok, :retry_pending}
                other -> other
              end

            :resumed ->
              give_now(group, conversation, device, invited_again)

            :needs_primary_recovery when invited_again ->
              {:error, :unknown_after_invite}

            :needs_primary_recovery ->
              old_run_id = primary_persisted_run_id(active_rows)

              case invite_again_all(active_rows, group, conversation, device, 0, old_run_id) do
                :ok -> give_now(group, conversation, device, true)
                :stale -> :ok
                other -> other
              end

            :unreachable ->
              :unreachable

            {:error, :pending_invite_id_retry} ->
              # Healthy bound slots are still delivered immediately, while the quiet task
              # is guaranteed a bounded SystemsClock wakeup to retry pending invite_id backfill.
              case give_active(active_rows, group, conversation, device, invited_again) do
                :ok -> {:ok, :retry_pending}
                other -> other
              end

            {:error, _} ->
              # A single secondary's transient error must NEVER starve healthy bound slots (`lead`, `qa`).
              case give_active(active_rows, group, conversation, device, invited_again) do
                :ok when any_leave_failed? -> {:ok, :retry_pending}
                other -> other
              end
          end
      end
    else
      [] ->
        :ok

      # Expected in the Task, with no Session of it yet: invited now that it
      # is connected, and given the Task from its start.
      true ->
        with :ok <- invite_expected(group, conversation, device),
             do: give_now(group, conversation, device, true)

      {:error, _} = error ->
        error
    end
  end

  defp give_active(active_rows, group, conversation, device, invited_again) do
    give_active_pinned(active_rows, group, conversation, device, invited_again, 0)
  end

  defp give_active_pinned(active_rows, group, conversation, device, invited_again, stale_retries) do
    %{tenant_id: tenant} = hd(active_rows)

    case admitted_run(tenant, group, device) do
      {:error, :device_offline} ->
        :unreachable

      {:error, reason} ->
        {:error, reason}

      {:ok, pinned_run_id} ->
        # Re-read authoritative rows AFTER pinning `pinned_run_id` so the `sent` cursor
        # never predates the connection generation we are about to deliver to.
        case StationTaskSessions.of_task(group, conversation) do
          {:ok, fresh_rows} ->
            fresh_active =
              Enum.filter(
                fresh_rows,
                &(&1.device_id == device and not StationTaskSessions.awaited?(&1))
              )

            other_run_positive? =
              Enum.any?(fresh_active, fn r ->
                row_run = get_in(r.start || %{}, ["connector_run_id"])

                r.sent > 0 and is_binary(row_run) and row_run != "" and
                  row_run != pinned_run_id
              end)

            unstamped_positive? =
              Enum.any?(fresh_active, fn r ->
                row_run = get_in(r.start || %{}, ["connector_run_id"])
                r.sent > 0 and (is_nil(row_run) or row_run == "")
              end)

            cond do
              fresh_active == [] ->
                :ok

              admitted_run(tenant, group, device) != {:ok, pinned_run_id} ->
                if stale_retries < 2 do
                  give_active_pinned(
                    fresh_active,
                    group,
                    conversation,
                    device,
                    invited_again,
                    stale_retries + 1
                  )
                else
                  :ok
                end

              other_run_positive? ->
                # A newer connection generation was admitted, while `hello` has not yet
                # reset/stamped the older generation's `sent > 0` cursor: refuse to reuse
                # the old cursor on the new connection and wait for `hello`/retry.
                {:ok, :retry_pending}

              unstamped_positive? ->
                # Legacy PR 1 row with `sent > 0` and missing/empty `connector_run_id`:
                # never skip messages 1..sent on an unverified cursor; safely reset to 0
                # and stamp `pinned_run_id`, then re-read and replay cleanly.
                case StationTaskSessions.reset_unstamped_sent(
                       group,
                       conversation,
                       device,
                       pinned_run_id
                     ) do
                  :ok when stale_retries < 2 ->
                    give_active_pinned(
                      fresh_active,
                      group,
                      conversation,
                      device,
                      invited_again,
                      stale_retries + 1
                    )

                  :ok ->
                    {:ok, :retry_pending}

                  {:error, reason} ->
                    {:error, reason}
                end

              true ->
                case give_rows_once(
                       fresh_active,
                       group,
                       conversation,
                       device,
                       invited_again,
                       allow_recurse?: true,
                       pinned_run_id: pinned_run_id
                     ) do
                  :stale when stale_retries < 2 ->
                    give_active_pinned(
                      fresh_active,
                      group,
                      conversation,
                      device,
                      invited_again,
                      stale_retries + 1
                    )

                  :stale ->
                    :ok

                  other ->
                    other
                end
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp give_rows_once(rows, group, conversation, device, invited_again, opts) do
    sent = rows |> Enum.map(& &1.sent) |> Enum.min()
    %{tenant_id: tenant} = hd(rows)

    with {:ok, answered} <- answered(rows, group, conversation, device),
         {:ok, messages} <-
           conversations().messages_after(group, conversation, sent, @put_limit) do
      put(
        rows,
        tenant,
        group,
        conversation,
        device,
        {sent, answered},
        messages,
        invited_again,
        opts
      )
    else
      # The Task is no more: there is nothing to give of it.
      {:error, reason}
      when reason == :not_found or (is_tuple(reason) and elem(reason, 0) == :bad_request) ->
        Logger.info(
          "a Task given to a station is no more: group=#{group} task=#{conversation} device=#{device} #{inspect(reason)}"
        )

        clear_device_pending_deactivations(group, conversation, device)
        StationTaskSessions.leave(group, conversation, device)

      {:error, _} = error ->
        error
    end
  end

  # Independently paginates confirmed rows to latest without carrying unconfirmed rows'
  # `confirmed_claims` or recursively hammering unconfirmed rows via `give_now`, while
  # preserving full-task `routing_rows` and pinning to `pinned_run_id` so a generation
  # switch or watermark CAS `:stale` stops immediately without feeding stale cursors.
  defp drain_confirmed_rows_pages(
         [],
         _routing_rows,
         _group,
         _conversation,
         _device,
         _invited_again,
         _pinned_run_id
       ),
       do: :ok

  defp drain_confirmed_rows_pages(
         rows,
         routing_rows,
         group,
         conversation,
         device,
         invited_again,
         pinned_run_id
       ) do
    sent = rows |> Enum.map(& &1.sent) |> Enum.min()
    %{tenant_id: tenant} = hd(rows)

    with {:ok, answered} <- answered(routing_rows, group, conversation, device),
         {:ok, [_ | _] = messages} <-
           conversations().messages_after(group, conversation, sent, @put_limit) do
      next_through = Enum.reduce(messages, sent, &max(&1["seq"], &2))

      case put(
             rows,
             tenant,
             group,
             conversation,
             device,
             {sent, answered},
             messages,
             invited_again,
             allow_recurse?: false,
             routing_rows: routing_rows,
             pinned_run_id: pinned_run_id
           ) do
        :ok when next_through > sent ->
          advanced = Enum.map(rows, &%{&1 | sent: max(&1.sent, next_through)})

          drain_confirmed_rows_pages(
            advanced,
            routing_rows,
            group,
            conversation,
            device,
            invited_again,
            pinned_run_id
          )

        other ->
          other
      end
    else
      {:ok, []} -> :ok
      other -> other
    end
  end

  # Drains any persisted `pending_orphan_leaves` on the device's rows BEFORE
  # `resume_pending_multi_starts` runs, with per-slot blocking and per-entry backoff
  # so a timed-out orphan leave on one slot never starves independent slots (e.g. `qa`).
  defp drain_pending_orphan_leaves(active_rows) do
    leaves =
      active_rows
      |> Enum.flat_map(&List.wrap(get_in(&1.start || %{}, ["pending_orphan_leaves"])))
      |> Enum.uniq_by(&{&1["slot"], &1["session"], &1["claim_token"]})

    if leaves == [] do
      {:ok, MapSet.new(), false}
    else
      %{tenant_id: tenant, group_id: group, conversation_id: conversation, device_id: device} =
        hd(active_rows)

      now_ms = SystemsClock.system_time(:millisecond)

      case online_run(tenant, group, device) do
        run_id when is_binary(run_id) and run_id != "" ->
          Enum.reduce_while(leaves, {:ok, MapSet.new(), false}, fn entry,
                                                                   {:ok, blocked, failed?} ->
            slot = entry["slot"]
            session = entry["session"]
            claim_token = entry["claim_token"]
            next_retry_at = entry["next_retry_at"]

            if is_integer(next_retry_at) and next_retry_at > now_ms do
              {:cont, {:ok, MapSet.put(blocked, slot), failed?}}
            else
              case request_leave_session(
                     tenant,
                     group,
                     conversation,
                     device,
                     session,
                     run_id,
                     claim_token,
                     slot
                   ) do
                res when res in [{:ok, true}, {:ok, :kept}] ->
                  _ =
                    task_sessions().remove_pending_orphan_leave(
                      group,
                      conversation,
                      device,
                      slot,
                      session,
                      claim_token
                    )

                  {:cont, {:ok, blocked, failed?}}

                other when other in [{:ok, false}, {:error, :station_outdated}] ->
                  if is_binary(online_run(tenant, group, device)) do
                    attempts = (entry["attempts"] || 0) + 1
                    retry_at = now_ms + secondary_retry_delay_ms(attempts)

                    _ =
                      update_orphan_leave_backoff(
                        group,
                        conversation,
                        device,
                        slot,
                        session,
                        claim_token,
                        %{"attempts" => attempts, "next_retry_at" => retry_at}
                      )

                    {:cont, {:ok, MapSet.put(blocked, slot), true}}
                  else
                    {:halt, :unreachable}
                  end
              end
            end
          end)

        _ ->
          :unreachable
      end
    end
  end

  # Resumes any secondary slots saved under `pending_multi_starts` on the primary
  # row after a partial Cloud VM reconnect, skipping slots blocked by pending orphan
  # leaves and skipping entries whose `invite_id` is already committed on the active row.
  defp resume_pending_multi_starts(active_rows, blocked_slots) do
    case Enum.find(active_rows, fn r ->
           is_list(get_in(r.start || %{}, ["pending_multi_starts"])) and
             get_in(r.start || %{}, ["pending_multi_starts"]) != []
         end) do
      nil ->
        :ok

      primary_row ->
        pending = get_in(primary_row.start, ["pending_multi_starts"])

        remaining =
          Enum.reject(pending, fn entry ->
            MapSet.member?(blocked_slots, entry["slot"]) or
              pending_entry_committed?(entry, active_rows)
          end)

        if remaining == [], do: :ok, else: invite_secondary_list(primary_row, remaining)
    end
  end

  defp pending_entry_committed?(entry, active_rows) do
    slot = entry["slot"]
    invite_id = entry["invite_id"]

    case Enum.find(active_rows, &(slot_of(&1) == slot)) do
      nil ->
        false

      row ->
        if is_binary(invite_id) and invite_id != "" do
          st = row.start || %{}

          st["invite_id"] == invite_id or
            invite_id in List.wrap(st["committed_invite_ids"])
        else
          true
        end
    end
  end

  # The station expected in the Task is invited with the `start` the Task was
  # made with (`SalixIM.TaskConversationInput.station_start/2`), and its
  # Session takes the expected row's place. For multi-session Tasks expected on
  # a waking Cloud VM (`start["multi_starts"]`), invites primary first then
  # secondaries with `join: true`.
  defp invite_expected(group, conversation, device) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation),
         %{} = row <-
           Enum.find(rows, &(&1.device_id == device and StationTaskSessions.awaited?(&1))) do
      start = start_of(row)
      extra_pending = List.wrap(start["pending_multi_starts"])

      case start["multi_starts"] do
        [primary_entry | secondary_entries] ->
          merged_secondaries =
            merge_secondary_starts(secondary_entries, extra_pending, primary_entry["slot"])

          invite_expected_multi(row, primary_entry, merged_secondaries)

        _ when extra_pending != [] ->
          primary_slot = slot_of(row)

          primary_entry = %{
            "slot" => primary_slot,
            "is_primary" => true,
            "agent_id" => row.agent_id,
            "start" => Map.delete(start, "pending_multi_starts")
          }

          merged_secondaries = merge_secondary_starts([], extra_pending, primary_slot)
          invite_expected_multi(row, primary_entry, merged_secondaries)

        _ ->
          invite_expected_single(row, start)
      end
    else
      nil -> :ok
      {:error, _} = error -> error
    end
  end

  defp invite_expected_single(row, start) do
    case invite_with_run(%{
           tenant_id: row.tenant_id,
           group_id: row.group_id,
           conversation_id: row.conversation_id,
           device_id: row.device_id,
           start: start,
           slot: slot_of(row),
           join: not primary_row?(row)
         }) do
      {:ok, {session, used_run_id}} when is_binary(session) ->
        Logger.info(
          "a station expected in a Task was invited to it: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id} session=#{session}"
        )

        case StationTaskSessions.replace_awaited(row, session, used_run_id, start, 0) do
          {:ok, _status, [_ | _]} ->
            give(row.group_id, row.conversation_id, row.device_id)
            :ok

          {:ok, _status, []} ->
            :ok

          {:error, :stale} ->
            :ok

          {:error, _} = err ->
            err
        end

      {:ok, :when_connected} ->
        :unreachable

      {:error, :device_offline} ->
        :unreachable

      {:error, {:station_refused, why}} ->
        Logger.warning(
          "a station expected in a Task did not take it; it is expected no more: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id} #{why}"
        )

        case StationTaskSessions.leave_awaited(row.group_id, row.conversation_id, row.device_id) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      {:error, :station_outdated} ->
        Logger.warning(
          "a station expected in a Task is outdated; it is expected no more: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id}"
        )

        case StationTaskSessions.leave_awaited(row.group_id, row.conversation_id, row.device_id) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      {:error, _} = error ->
        error
    end
  end

  defp invite_expected_multi(row, primary_entry, secondary_entries) do
    with :ok <- check_multi_session(row.tenant_id, row.group_id, %{"device_id" => row.device_id}) do
      primary_start = primary_entry["start"]

      case invite_with_run(%{
             tenant_id: row.tenant_id,
             group_id: row.group_id,
             conversation_id: row.conversation_id,
             device_id: row.device_id,
             start: primary_start,
             slot: primary_entry["slot"] || "lead",
             multi_session: true
           }) do
        {:ok, {primary_session, used_run_id}} when is_binary(primary_session) ->
          # Persist `pending_multi_starts` on the primary row via `recover_device_primary`
          # (`FOR UPDATE`) so any concurrently appended `pending_multi_starts` on the
          # awaited row are merged atomically rather than overwritten.
          primary_start_with_pending =
            if secondary_entries == [],
              do: primary_start,
              else: Map.put(primary_start, "pending_multi_starts", secondary_entries)

          case StationTaskSessions.recover_device_primary(
                 row,
                 primary_session,
                 used_run_id,
                 primary_start_with_pending,
                 0,
                 [],
                 nil
               ) do
            {:ok, _status, committed_pending} ->
              primary_row = %{
                row
                | session: primary_session,
                  start:
                    if(committed_pending == [],
                      do: Map.delete(primary_start, "pending_multi_starts"),
                      else: Map.put(primary_start, "pending_multi_starts", committed_pending)
                    )
              }

              case invite_secondary_list(primary_row, committed_pending) do
                :resumed -> :ok
                :ok -> :ok
                :needs_primary_recovery -> {:error, :needs_primary_recovery}
                other -> other
              end

            {:error, :stale} ->
              :ok

            {:error, _} = err ->
              err
          end

        {:ok, :when_connected} ->
          :unreachable

        {:error, :device_offline} ->
          :unreachable

        {:error, {:station_refused, why}} ->
          Logger.warning(
            "a station expected in a multi-session Task did not take it: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id} #{why}"
          )

          case StationTaskSessions.leave_awaited(row.group_id, row.conversation_id, row.device_id) do
            {:ok, _} -> :ok
            {:error, _} = err -> err
          end

        {:error, :station_outdated} ->
          Logger.warning(
            "a station expected in a multi-session Task is outdated: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id}"
          )

          case StationTaskSessions.leave_awaited(row.group_id, row.conversation_id, row.device_id) do
            {:ok, _} -> :ok
            {:error, _} = err -> err
          end

        {:error, _} = error ->
          error
      end
    else
      {:error, :device_offline} ->
        :unreachable

      {:error, :station_outdated} ->
        Logger.warning(
          "a station expected in a multi-session Task is outdated: group=#{row.group_id} task=#{row.conversation_id} device=#{row.device_id}"
        )

        case StationTaskSessions.leave_awaited(row.group_id, row.conversation_id, row.device_id) do
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      {:error, _} = error ->
        error
    end
  end

  defp merge_secondary_starts(base_entries, extra_entries, primary_slot) do
    seen = MapSet.new([primary_slot || "lead"])

    {merged, _seen} =
      Enum.reduce(base_entries ++ extra_entries, {[], seen}, fn entry, {acc, s} ->
        slot = entry["slot"]

        if is_binary(slot) and slot != "" and not MapSet.member?(s, slot) do
          {acc ++ [entry], MapSet.put(s, slot)}
        else
          {acc, s}
        end
      end)

    merged
  end

  defp no_active_primary_error?({:station_refused, why}) when is_binary(why),
    do: String.contains?(why, "no_active_primary")

  defp no_active_primary_error?(_), do: false

  @doc false
  def permanent_slot_refusal?(:station_outdated), do: true

  def permanent_slot_refusal?({:station_refused, why} = r) do
    not no_active_primary_error?(r) and not transient_station_refusal_message?(why)
  end

  def permanent_slot_refusal?(_), do: false

  defp transient_station_refusal_message?(why) when is_binary(why) do
    String.contains?(why, "SQLITE_BUSY") or
      String.contains?(why, "SQLITE_LOCKED") or
      String.contains?(why, "database is locked") or
      String.contains?(why, "failed to persist invite decision") or
      String.contains?(why, "slot_invite_pending")
  end

  defp transient_station_refusal_message?(_), do: false

  defp primary_persisted_run_id(rows) when is_list(rows) do
    primary_row = Enum.find(rows, &primary_row?/1) || hd(rows)

    case get_in(primary_row.start || %{}, ["connector_run_id"]) do
      run when is_binary(run) and run != "" -> run
      _ -> nil
    end
  end

  defp secondary_retry_delay_ms(attempts), do: min(30_000, 1_000 * max(attempts, 1))

  defp next_pending_retry_wait_ms(group, conversation, device) do
    with {:ok, rows} <- StationTaskSessions.of_task(group, conversation) do
      active_rows =
        Enum.filter(rows, &(&1.device_id == device and not StationTaskSessions.awaited?(&1)))

      now_ms = SystemsClock.system_time(:millisecond)

      orphan_leaves =
        active_rows
        |> Enum.flat_map(&List.wrap(get_in(&1.start || %{}, ["pending_orphan_leaves"])))

      blocked_orphan_slots = MapSet.new(orphan_leaves, & &1["slot"])

      orphan_times =
        orphan_leaves
        |> Enum.map(& &1["next_retry_at"])
        |> Enum.filter(&is_integer/1)

      pending_times =
        active_rows
        |> Enum.flat_map(&List.wrap(get_in(&1.start || %{}, ["pending_multi_starts"])))
        |> Enum.reject(fn entry ->
          MapSet.member?(blocked_orphan_slots, entry["slot"]) or
            pending_entry_committed?(entry, active_rows)
        end)
        |> Enum.map(& &1["next_retry_at"])
        |> Enum.filter(&is_integer/1)

      case orphan_times ++ pending_times do
        [] -> nil
        times -> max(secondary_retry_delay_ms(1), Enum.min(times) - now_ms)
      end
    else
      _ -> nil
    end
  end

  defp active_slot_matches_invite?(group, conversation, device, slot, invite_id)
       when is_binary(invite_id) and invite_id != "" do
    case StationTaskSessions.of_task(group, conversation) do
      {:ok, rows} ->
        Enum.any?(rows, fn r ->
          if r.device_id == device and not StationTaskSessions.awaited?(r) and slot_of(r) == slot do
            start = r.start || %{}

            start["invite_id"] == invite_id or
              start["claim_token"] == invite_id or
              invite_id in List.wrap(start["committed_invite_ids"])
          else
            false
          end
        end)

      _ ->
        false
    end
  end

  defp active_slot_matches_invite?(_group, _conversation, _device, _slot, _invite_id), do: false

  defp slot_has_active_binding?(group, conversation, device, slot, demoted_token) do
    case StationTaskSessions.of_task(group, conversation) do
      {:ok, rows} ->
        Enum.any?(rows, fn r ->
          current_token = get_in(r.start || %{}, ["binding_token"]) || r.session

          r.device_id == device and not StationTaskSessions.awaited?(r) and slot_of(r) == slot and
            (is_nil(demoted_token) or current_token != demoted_token)
        end)

      _ ->
        false
    end
  end

  defp invite_secondary_list(primary_row, secondary_entries) do
    now_ms = SystemsClock.system_time(:millisecond)

    result =
      Enum.reduce_while(secondary_entries, {:ok, [], %{}, false}, fn entry,
                                                                     {:ok, done_entries,
                                                                      retry_updates, needs_retry?} ->
        slot = entry["slot"]

        # Step 1: Resolve authoritative entry FIRST (even when `entry["invite_id"]` is already
        # present, re-verify live DB primary `pending_multi_starts` so a superseded or newly
        # refused entry NEVER fires a stale `task.invite` RPC).
        entry_res =
          if is_binary(entry["invite_id"]) and entry["invite_id"] != "" do
            verify_pending_entry_live(
              primary_row.group_id,
              primary_row.conversation_id,
              primary_row.device_id,
              slot,
              entry
            )
          else
            task_sessions().ensure_pending_invite_id(
              primary_row.group_id,
              primary_row.conversation_id,
              primary_row.device_id,
              slot,
              entry
            )
          end

        case entry_res do
          {:error, {:entry_changed, _}} ->
            {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

          {:error, :not_found} ->
            {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

          {:error, _id_err} ->
            # Transient error while snapshot had no invite_id: NEVER write bare-slot
            # retry_updates (which could overwrite a newer entry), do NOT block healthy
            # sibling slots, and mark `needs_retry? = true` so quiet tasks wake on a bounded timer.
            {:cont, {:ok, done_entries, retry_updates, true}}

          {:ok, auth_entry} ->
            entry = auth_entry
            resolved_invite_id = entry["invite_id"]
            next_retry_at = entry["next_retry_at"]

            refusal_why =
              slot_pending_deactivation_reason(
                primary_row.group_id,
                primary_row.conversation_id,
                primary_row.device_id,
                slot,
                entry
              )

            cond do
              is_integer(next_retry_at) and next_retry_at > now_ms ->
                {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

              is_binary(refusal_why) ->
                why_label = refusal_why

                record_pending_deactivation(
                  primary_row.group_id,
                  primary_row.conversation_id,
                  primary_row.device_id,
                  slot,
                  entry,
                  why_label
                )

                case deactivate_dropped_slot(
                       primary_row.group_id,
                       primary_row.conversation_id,
                       entry,
                       primary_row.device_id
                     ) do
                  :ok ->
                    _ =
                      notice(
                        primary_row.group_id,
                        primary_row.conversation_id,
                        primary_row.agent_id,
                        "slot-refused:#{slot}",
                        "Secondary session slot #{slot} was refused by the station (#{why_label}) and deactivated; remaining sessions continue."
                      )

                    {:cont,
                     {:ok, [{slot, entry, :refused, why_label} | done_entries], retry_updates,
                      needs_retry?}}

                  {:ok, :already_bound} ->
                    demoted_token = entry["demoted_binding_token"] || entry["demoted_session"]

                    if slot_has_active_binding?(
                         primary_row.group_id,
                         primary_row.conversation_id,
                         primary_row.device_id,
                         slot,
                         demoted_token
                       ) do
                      # Emit `:refused` (not `:bound`) so `remove_pending_multi_starts` checks
                      # active rows under `lock_device_tx`: skips orphan if active row IS this
                      # invite_id, and records orphan if an older binding A occupies the slot.
                      {:cont,
                       {:ok, [{slot, entry, :refused, why_label} | done_entries], retry_updates,
                        needs_retry?}}
                    else
                      attempts = (entry["attempts"] || 0) + 1

                      next_updates =
                        put_retry_update(retry_updates, slot, entry, %{
                          "attempts" => attempts,
                          "next_retry_at" => now_ms + secondary_retry_delay_ms(attempts),
                          "pending_deactivation" => true,
                          "refusal_reason" => why_label
                        })

                      {:cont, {:ok, done_entries, next_updates, needs_retry?}}
                    end

                  {:error, :superseded} ->
                    {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

                  {:error, _deact_err} ->
                    attempts = (entry["attempts"] || 0) + 1

                    next_updates =
                      put_retry_update(retry_updates, slot, entry, %{
                        "attempts" => attempts,
                        "next_retry_at" => now_ms + secondary_retry_delay_ms(attempts),
                        "pending_deactivation" => true,
                        "refusal_reason" => why_label
                      })

                    {:cont, {:ok, done_entries, next_updates, needs_retry?}}
                end

              true ->
                sec_answered =
                  case entry["answered"] do
                    n when is_integer(n) and n >= 0 -> n
                    _ -> 0
                  end

                invite_res =
                  case check_multi_session(
                         primary_row.tenant_id,
                         primary_row.group_id,
                         %{"device_id" => primary_row.device_id}
                       ) do
                    :ok ->
                      case mark_pending_dispatched(
                             primary_row.group_id,
                             primary_row.conversation_id,
                             primary_row.device_id,
                             slot,
                             resolved_invite_id
                           ) do
                        :ok ->
                          {Map.put(entry, "dispatched", true),
                           invite_with_run(%{
                             tenant_id: primary_row.tenant_id,
                             group_id: primary_row.group_id,
                             conversation_id: primary_row.conversation_id,
                             device_id: primary_row.device_id,
                             start: entry["start"],
                             answered: sec_answered,
                             slot: slot,
                             claim_token: resolved_invite_id,
                             invite_id: resolved_invite_id,
                             join: true,
                             multi_session: true
                           })}

                        {:error, reason}
                        when reason in [:pending_invite_not_found, :pending_deactivation] ->
                          {entry, {:error, {:dispatch_aborted, reason}}}

                        {:error, disp_err} ->
                          {entry, {:error, {:dispatch_mark_failed, disp_err}}}
                      end

                    {:error, :device_offline} ->
                      {entry, {:error, :device_offline}}

                    {:error, cap_err} ->
                      {entry, {:error, cap_err}}
                  end

                {entry, rpc_res} = invite_res

                case rpc_res do
                  {:error, {:dispatch_aborted, _reason}} ->
                    # Pending entry was already cleared, superseded, or locked for deactivation:
                    # cancel RPC without writing retry backoff.
                    {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

                  {:ok, {sec_session, used_run_id}} when is_binary(sec_session) ->
                    fenced_start =
                      if is_binary(used_run_id) and used_run_id != "",
                        do: Map.put(entry["start"], "connector_run_id", used_run_id),
                        else: entry["start"]

                    case register_slot_binding(%{
                           tenant_id: primary_row.tenant_id,
                           group_id: primary_row.group_id,
                           conversation_id: primary_row.conversation_id,
                           device_id: primary_row.device_id,
                           session: sec_session,
                           agent_id: entry["agent_id"] || primary_row.agent_id,
                           answered: sec_answered,
                           participant_id: entry["participant_id"],
                           expected_pending_invite_id: resolved_invite_id,
                           start: fenced_start,
                           give: false
                         }) do
                      :ok ->
                        {:cont,
                         {:ok, [{slot, entry, :bound} | done_entries], retry_updates,
                          needs_retry?}}

                      {:error, {:stale_slot_binding, :invite_superseded}} ->
                        # Stale snapshot A was already replaced or cleared in DB while RPC was in
                        # flight: durably record pending_orphan_leaves and fence-revoke with
                        # claim_token == resolved_invite_id (never nil)!
                        revoke_failed? =
                          case revoke_orphan_slot_session(
                                 primary_row.tenant_id,
                                 primary_row.group_id,
                                 primary_row.conversation_id,
                                 primary_row.device_id,
                                 slot,
                                 sec_session,
                                 used_run_id,
                                 resolved_invite_id
                               ) do
                            {:error, _} -> true
                            _ -> false
                          end

                        {:cont,
                         {:ok, done_entries, retry_updates, needs_retry? or revoke_failed?}}

                      {:error, {:stale_slot_binding, _}} ->
                        # Stale snapshot A was already replaced or cleared in DB: drop without
                        # writing retry_updates that could interfere with newer entry B.
                        {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

                      {:error, _} ->
                        attempts = (entry["attempts"] || 0) + 1

                        next_updates =
                          put_retry_update(retry_updates, slot, entry, %{
                            "attempts" => attempts,
                            "next_retry_at" => now_ms + secondary_retry_delay_ms(attempts)
                          })

                        {:cont, {:ok, done_entries, next_updates, needs_retry?}}
                    end

                  {:ok, :when_connected} ->
                    {:halt, {:partial, done_entries, retry_updates, :unreachable}}

                  {:error, :device_offline} ->
                    {:halt, {:partial, done_entries, retry_updates, :unreachable}}

                  {:error, reason} ->
                    cond do
                      no_active_primary_error?(reason) ->
                        Logger.warning(
                          "secondary slot #{slot} invite saw no_active_primary on Task #{primary_row.conversation_id}; triggering primary-first recovery without dropping slot"
                        )

                        {:halt, {:partial, done_entries, retry_updates, :needs_primary_recovery}}

                      permanent_slot_refusal?(reason) ->
                        why_label =
                          case reason do
                            {:station_refused, why} -> to_string(why)
                            :station_outdated -> "station_outdated"
                          end

                        record_pending_deactivation(
                          primary_row.group_id,
                          primary_row.conversation_id,
                          primary_row.device_id,
                          slot,
                          entry,
                          why_label
                        )

                        Logger.warning(
                          "a station permanently refused secondary slot #{slot} on Task #{primary_row.conversation_id} (#{why_label}); deactivating unbound participant before dropping from pending_multi_starts"
                        )

                        case deactivate_dropped_slot(
                               primary_row.group_id,
                               primary_row.conversation_id,
                               entry,
                               primary_row.device_id
                             ) do
                          {:ok, :already_bound} ->
                            demoted_token =
                              entry["demoted_binding_token"] || entry["demoted_session"]

                            if slot_has_active_binding?(
                                 primary_row.group_id,
                                 primary_row.conversation_id,
                                 primary_row.device_id,
                                 slot,
                                 demoted_token
                               ) do
                              # Emit `:refused` (not `:bound`) so `remove_pending_multi_starts` checks
                              # active rows under `lock_device_tx`: skips orphan if active row IS this
                              # invite_id, and records orphan if an older binding A occupies the slot.
                              {:cont,
                               {:ok, [{slot, entry, :refused, reason} | done_entries],
                                retry_updates, needs_retry?}}
                            else
                              attempts = (entry["attempts"] || 0) + 1

                              next_updates =
                                put_retry_update(retry_updates, slot, entry, %{
                                  "attempts" => attempts,
                                  "next_retry_at" => now_ms + secondary_retry_delay_ms(attempts),
                                  "pending_deactivation" => true,
                                  "refusal_reason" => why_label
                                })

                              {:cont, {:ok, done_entries, next_updates, needs_retry?}}
                            end

                          :ok ->
                            _ =
                              notice(
                                primary_row.group_id,
                                primary_row.conversation_id,
                                primary_row.agent_id,
                                "slot-refused:#{slot}",
                                "Secondary session slot #{slot} was refused by the station (#{why_label}) and deactivated; remaining sessions continue."
                              )

                            {:cont,
                             {:ok, [{slot, entry, :refused, reason} | done_entries],
                              retry_updates, needs_retry?}}

                          {:error, :superseded} ->
                            {:cont, {:ok, done_entries, retry_updates, needs_retry?}}

                          {:error, _deact_err} ->
                            attempts = (entry["attempts"] || 0) + 1

                            next_updates =
                              put_retry_update(retry_updates, slot, entry, %{
                                "attempts" => attempts,
                                "next_retry_at" => now_ms + secondary_retry_delay_ms(attempts),
                                "pending_deactivation" => true,
                                "refusal_reason" => why_label
                              })

                            {:cont, {:ok, done_entries, next_updates, needs_retry?}}
                        end

                      true ->
                        attempts = (entry["attempts"] || 0) + 1

                        next_updates =
                          put_retry_update(retry_updates, slot, entry, %{
                            "attempts" => attempts,
                            "next_retry_at" => now_ms + secondary_retry_delay_ms(attempts)
                          })

                        {:cont, {:ok, done_entries, next_updates, needs_retry?}}
                    end
                end
            end
        end
      end)

    case result do
      {:ok, done_entries, retry_updates, needs_retry?} ->
        backoff_res =
          if map_size(retry_updates) > 0 do
            case task_sessions().update_pending_multi_starts_backoff(
                   primary_row.group_id,
                   primary_row.conversation_id,
                   primary_row.device_id,
                   retry_updates
                 ) do
              :ok ->
                :ok

              {:error, bo_err} ->
                Logger.warning(
                  "failed to persist secondary retry backoff on Task #{primary_row.conversation_id}: #{inspect(bo_err)}"
                )

                {:error, bo_err}
            end
          else
            :ok
          end

        done_targets = Enum.map(done_entries, &done_entry_remove_target/1)

        case remove_pending_starts(
               primary_row.group_id,
               primary_row.conversation_id,
               primary_row.device_id,
               done_targets,
               []
             ) do
          {:ok, removed} ->
            Enum.each(done_entries, fn item ->
              {slot, entry} = done_entry_slot_and_entry(item)

              clear_pending_deactivation(
                primary_row.group_id,
                primary_row.conversation_id,
                primary_row.device_id,
                slot,
                entry
              )
            end)

            cond do
              backoff_res != :ok -> backoff_res
              needs_retry? -> {:error, :pending_invite_id_retry}
              removed > 0 -> :resumed
              true -> :ok
            end

          {:error, _} = rm_err ->
            rm_err
        end

      {:partial, done_entries, retry_updates, err} ->
        if map_size(retry_updates) > 0 do
          case task_sessions().update_pending_multi_starts_backoff(
                 primary_row.group_id,
                 primary_row.conversation_id,
                 primary_row.device_id,
                 retry_updates
               ) do
            :ok ->
              :ok

            {:error, bo_err} ->
              Logger.warning(
                "failed to persist partial secondary retry backoff on Task #{primary_row.conversation_id}: #{inspect(bo_err)}"
              )
          end
        end

        done_targets = Enum.map(done_entries, &done_entry_remove_target/1)

        if done_targets != [] do
          case remove_pending_starts(
                 primary_row.group_id,
                 primary_row.conversation_id,
                 primary_row.device_id,
                 done_targets,
                 []
               ) do
            {:ok, _} ->
              Enum.each(done_entries, fn item ->
                {slot, entry} = done_entry_slot_and_entry(item)

                clear_pending_deactivation(
                  primary_row.group_id,
                  primary_row.conversation_id,
                  primary_row.device_id,
                  slot,
                  entry
                )
              end)

            {:error, rm_err} ->
              Logger.warning(
                "failed to remove partial done pending_multi_starts on Task #{primary_row.conversation_id}: #{inspect(rm_err)}"
              )
          end
        end

        err
    end
  end

  defp done_entry_remove_target({slot, entry, :refused, reason}) do
    invite_id = entry["invite_id"]

    cond do
      is_binary(invite_id) and invite_id != "" and
          reason in [:station_outdated, {:error, :station_outdated}, "station_outdated"] ->
        {slot, invite_id, :record_orphan_if_dispatched}

      is_binary(invite_id) and invite_id != "" ->
        {slot, invite_id, :record_orphan}

      true ->
        pending_remove_target(slot, invite_id)
    end
  end

  defp done_entry_remove_target({slot, entry, :bound}),
    do: pending_remove_target(slot, entry["invite_id"])

  defp done_entry_remove_target({slot, entry}),
    do: pending_remove_target(slot, entry["invite_id"])

  defp done_entry_slot_and_entry({slot, entry, :refused, _reason}), do: {slot, entry}
  defp done_entry_slot_and_entry({slot, entry, :bound}), do: {slot, entry}
  defp done_entry_slot_and_entry({slot, entry}), do: {slot, entry}

  defp deactivate_dropped_slot(group_id, conversation_id, entry, device_id) do
    pid = entry["participant_id"] || get_in(entry, ["start", "participant_id"])
    stale_token = entry["demoted_binding_token"] || entry["demoted_session"]
    slot = entry["slot"] || get_in(entry, ["start", "slot"])
    expected_invite_id = entry["invite_id"]

    verify_unbound_fun =
      slot_verify_unbound_fun(group_id, conversation_id, device_id, slot, expected_invite_id)

    cond do
      is_binary(pid) and pid != "" ->
        call_deactivate_unbound_participant(
          group_id,
          conversation_id,
          pid,
          stale_token,
          verify_unbound_fun
        )

      is_binary(entry["slot"]) and entry["slot"] != "" and
          function_exported?(conversations(), :participants, 2) ->
        case conversations().participants(group_id, conversation_id) do
          {:ok, list} when is_list(list) ->
            case Enum.find(
                   list,
                   &(&1["actor_type"] == "agent" and &1["role_label"] == "worker" and
                       &1["target_key"] == entry["slot"] and &1["state"] != "inactive")
                 ) do
              %{"participant_id" => found_pid} ->
                call_deactivate_unbound_participant(
                  group_id,
                  conversation_id,
                  found_pid,
                  stale_token,
                  verify_unbound_fun
                )

              _ ->
                :ok
            end

          {:error, :not_found} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        :ok
    end
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc false
  def verify_slot_unbound(
        group_id,
        conversation_id,
        device_id,
        slot,
        stale_tok,
        expected_invite_id
      )
      when is_binary(device_id) and device_id != "" do
    check_fun = fn ->
      case StationTaskSessions.of_task(group_id, conversation_id) do
        {:ok, rows} ->
          live =
            Enum.find(rows, fn r ->
              not StationTaskSessions.awaited?(r) and r.device_id == device_id and
                (get_in(r.start || %{}, ["slot"]) || "lead") == slot and
                (is_nil(stale_tok) or stale_tok == "" or
                   (get_in(r.start || %{}, ["binding_token"]) || r.session) != stale_tok)
            end)

          cond do
            live != nil ->
              {:bound, get_in(live.start || %{}, ["binding_token"]) || live.session}

            SalixStore.CodingSandboxes.device?(device_id) ->
              tenant_id = SalixStore.Ids.tenant_id_from_group!(group_id)

              try do
                case SalixStore.CodingSandboxes.get_by_device(tenant_id, device_id) do
                  {:ok, w} ->
                    by_slot = get_in(w.spec, ["pending_secondaries", "by_slot", slot]) || %{}
                    cur_start = Enum.find(List.wrap(w.spec["starts"]), &(&1["slot"] == slot))

                    req_ids =
                      Map.keys(by_slot["request_seqs"] || %{}) ++
                        List.wrap(by_slot["request_ids"])

                    has_newer_req? =
                      by_slot["pending_deactivation"] != true and
                        (Enum.any?(req_ids, fn id ->
                           is_binary(id) and id != "" and id != expected_invite_id
                         end) or
                           (is_map(cur_start) and is_binary(cur_start["invite_id"]) and
                              cur_start["invite_id"] != "" and
                              cur_start["invite_id"] != expected_invite_id))

                    if has_newer_req?, do: {:abort, :superseded}, else: :unbound

                  {:error, :not_found} ->
                    :unbound
                end
              rescue
                _ -> :unknown
              end

            is_binary(expected_invite_id) and expected_invite_id != "" ->
              primary_row =
                rows
                |> Enum.filter(&(&1.device_id == device_id))
                |> Enum.sort_by(fn r ->
                  is_prim =
                    case get_in(r.start || %{}, ["is_primary"]) do
                      v when is_boolean(v) -> v
                      _ -> (get_in(r.start || %{}, ["slot"]) || "lead") == "lead"
                    end

                  {if(is_prim, do: 0, else: 1), r.session}
                end)
                |> List.first()

              cur_pending =
                if primary_row do
                  primary_row.start
                  |> Map.get("pending_multi_starts", [])
                  |> List.wrap()
                  |> Enum.find(&(&1["slot"] == slot))
                else
                  nil
                end

              if is_map(cur_pending) and is_binary(cur_pending["invite_id"]) and
                   cur_pending["invite_id"] != "" and
                   cur_pending["invite_id"] != expected_invite_id do
                {:abort, :superseded}
              else
                :unbound
              end

            true ->
              :unbound
          end

        {:error, _} ->
          :unknown
      end
    end

    case StationTaskSessions.with_device_lock(group_id, conversation_id, device_id, fn ->
           {:ok, check_fun.()}
         end) do
      {:ok, res} -> res
      {:error, _} -> :unknown
    end
  end

  defp verify_pending_entry_live(group_id, conversation_id, device_id, slot, entry) do
    expected_id = entry["invite_id"]

    case StationTaskSessions.of_task(group_id, conversation_id) do
      {:ok, rows} ->
        primary_row =
          rows
          |> Enum.filter(&(&1.device_id == device_id))
          |> Enum.sort_by(fn r ->
            is_prim =
              case get_in(r.start || %{}, ["is_primary"]) do
                v when is_boolean(v) -> v
                _ -> (get_in(r.start || %{}, ["slot"]) || "lead") == "lead"
              end

            {if(is_prim, do: 0, else: 1), r.session}
          end)
          |> List.first()

        cur =
          if primary_row do
            primary_row.start
            |> Map.get("pending_multi_starts", [])
            |> List.wrap()
            |> Enum.find(&(&1["slot"] == slot))
          else
            nil
          end

        cond do
          is_map(cur) and cur["invite_id"] == expected_id -> {:ok, cur}
          is_map(cur) -> {:error, {:entry_changed, cur}}
          true -> {:error, :not_found}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def slot_verify_unbound_fun(
        group_id,
        conversation_id,
        device_id,
        slot,
        expected_invite_id \\ nil
      ) do
    fn stale_tok ->
      check_fun = fn ->
        case StationTaskSessions.of_task(group_id, conversation_id) do
          {:ok, rows} ->
            live =
              Enum.find(rows, fn r ->
                not StationTaskSessions.awaited?(r) and
                  (is_nil(device_id) or r.device_id == device_id) and
                  (is_nil(slot) or (get_in(r.start || %{}, ["slot"]) || "lead") == slot) and
                  (is_nil(stale_tok) or stale_tok == "" or
                     (get_in(r.start || %{}, ["binding_token"]) || r.session) != stale_tok)
              end)

            cond do
              live != nil ->
                {:bound, get_in(live.start || %{}, ["binding_token"]) || live.session}

              is_binary(expected_invite_id) and expected_invite_id != "" and
                is_binary(device_id) and device_id != "" and is_binary(slot) and slot != "" ->
                primary_row =
                  rows
                  |> Enum.filter(&(&1.device_id == device_id))
                  |> Enum.sort_by(fn r ->
                    is_prim =
                      case get_in(r.start || %{}, ["is_primary"]) do
                        v when is_boolean(v) -> v
                        _ -> (get_in(r.start || %{}, ["slot"]) || "lead") == "lead"
                      end

                    {if(is_prim, do: 0, else: 1), r.session}
                  end)
                  |> List.first()

                cur_pending =
                  if primary_row do
                    primary_row.start
                    |> Map.get("pending_multi_starts", [])
                    |> List.wrap()
                    |> Enum.find(&(&1["slot"] == slot))
                  else
                    nil
                  end

                if is_map(cur_pending) and cur_pending["invite_id"] == expected_invite_id do
                  :unbound
                else
                  {:abort, :superseded}
                end

              true ->
                :unbound
            end

          {:error, _} ->
            :unknown
        end
      end

      if is_binary(expected_invite_id) and expected_invite_id != "" and
           is_binary(device_id) and device_id != "" do
        case StationTaskSessions.with_device_lock(group_id, conversation_id, device_id, fn ->
               {:ok, check_fun.()}
             end) do
          {:ok, res} -> res
          {:error, _} -> :unknown
        end
      else
        check_fun.()
      end
    end
  end

  defp call_deactivate_unbound_participant(
         group_id,
         conversation_id,
         participant_id,
         expected_stale_session,
         verify_unbound_fun
       ) do
    res =
      cond do
        function_exported?(conversations(), :deactivate_unbound_task_participant, 5) ->
          conversations().deactivate_unbound_task_participant(
            group_id,
            conversation_id,
            participant_id,
            expected_stale_session,
            verify_unbound_fun
          )

        function_exported?(conversations(), :deactivate_unbound_task_participant, 4) ->
          conversations().deactivate_unbound_task_participant(
            group_id,
            conversation_id,
            participant_id,
            expected_stale_session
          )

        function_exported?(conversations(), :deactivate_unbound_task_participant, 3) ->
          conversations().deactivate_unbound_task_participant(
            group_id,
            conversation_id,
            participant_id
          )

        function_exported?(conversations(), :deactivate_participant, 3) ->
          conversations().deactivate_participant(group_id, conversation_id, participant_id)

        true ->
          :ok
      end

    case res do
      {:ok, :already_bound} -> {:ok, :already_bound}
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp has_unconfirmed_claims?(rows) when is_list(rows) do
    Enum.any?(rows, &row_needs_claim_confirm?/1)
  end

  defp confirmed_claims_for(rows) when is_list(rows) do
    for r <- rows,
        row_needs_claim_confirm?(r) do
      %{"slot" => slot_of(r), "session" => r.session, "claim_token" => r.start["claim_token"]}
    end
  end

  defp put(rows, tenant, group, conversation, device, {sent, answered}, [], invited_again, opts) do
    if has_unconfirmed_claims?(rows) do
      routing_rows = Keyword.get(opts, :routing_rows, rows)

      with {:ok, routing} <- multi_session_routing(routing_rows, group, conversation, []) do
        do_put(
          rows,
          tenant,
          group,
          conversation,
          device,
          {sent, answered},
          [],
          invited_again,
          routing,
          Keyword.put(opts, :quiet_confirm?, true)
        )
      end
    else
      :ok
    end
  end

  defp put(
         rows,
         tenant,
         group,
         conversation,
         device,
         {sent, answered},
         messages,
         invited_again,
         opts
       ) do
    routing_rows = Keyword.get(opts, :routing_rows, rows)

    with {:ok, routing} <- multi_session_routing(routing_rows, group, conversation, messages) do
      do_put(
        rows,
        tenant,
        group,
        conversation,
        device,
        {sent, answered},
        messages,
        invited_again,
        routing,
        Keyword.put(opts, :quiet_confirm?, false)
      )
    end
  end

  defp do_put(
         rows,
         tenant,
         group,
         conversation,
         device,
         {sent, answered},
         messages,
         invited_again,
         routing,
         opts
       ) do
    routing_rows = Keyword.get(opts, :routing_rows, rows)
    through = Enum.reduce(messages, sent, &max(&1["seq"], &2))
    session_watermarks = Enum.map(rows, &{&1.session, &1.sent})
    snapshot_sessions = Enum.map(rows, & &1.session)

    # On multi-session Tasks, pass the conservative lower bound `min(answered)` at
    # the thread level alongside exact per-slot `answered_by_slot` across all active
    # `routing_rows` so one busy or unconfirmed slot's unconsumed messages are never
    # wiped by another slot's higher `answered`.
    thread_answered =
      if routing.multi? do
        routing_rows |> Enum.map(&(&1.answered || 0)) |> Enum.min(fn -> 0 end)
      else
        answered
      end

    needs_multi_session? = multi_session_snapshot?(routing_rows) or routing.multi?

    # On single-session Tasks, omit messages explicitly invisible to the sole active
    # worker (`visible_to_slots == []`) so neither their body nor attachments reach a
    # legacy single-session Station, while keeping the full `through` watermark.
    rendered_messages =
      messages
      |> Enum.map(&message(&1, device, routing))
      |> then(fn list ->
        if needs_multi_session? do
          list
        else
          Enum.reject(list, &(&1["visible_to_slots"] == []))
        end
      end)
      |> named(tenant, group)

    # `answered`: with all that the station is given, through which Message its
    # Sessions answered the Task already. It hands none of those to a Session.
    confirmed_claims = confirmed_claims_for(rows)

    params =
      %{
        "task" => conversation,
        "messages" => rendered_messages,
        "through" => through
      }
      |> put_answered(thread_answered)
      |> put_multi_routing(routing_rows, routing)
      |> put_links(group, conversation)
      |> then(fn p ->
        if confirmed_claims != [], do: Map.put(p, "confirmed_claims", confirmed_claims), else: p
      end)

    # Capture connection generation (`run_id`) and capabilities atomically BEFORE
    # `task.put` so a reconnect during the RPC cannot have its reset `sent` overwritten
    # by a stale put and legacy stations never receive multi-session payloads.
    pinned_run_id = Keyword.get(opts, :pinned_run_id)

    case admitted_run_with_caps(tenant, group, device) do
      {:error, :device_offline} ->
        :unreachable

      {:error, reason} ->
        {:error, reason}

      {:ok, run_id, caps} ->
        cond do
          is_binary(pinned_run_id) and run_id != pinned_run_id ->
            # Independent pagination pinned to an earlier generation: stop immediately
            # without sending stale-cursor messages to the new connection.
            :stale

          needs_multi_session? and not SalixStore.StationReadiness.multi_session_ready?(caps) ->
            # Legacy/incompatible station lacks `multi_session_tasks`: never claim `run_id`,
            # never send a multi-session `task.put` payload, never advance watermarks, and
            # never delete healthy bindings.
            Logger.warning(
              "skipping multi-session task.put for station without multi_session_tasks capability: group=#{group} task=#{conversation} device=#{device}"
            )

            :unreachable

          true ->
            # Claim `connector_run_id` on any snapshot rows joined while offline (empty run_id)
            # before sending `task.put`, so strict `connector_run_id = $run_id` fencing holds.
            _ =
              StationTaskSessions.claim_run_id(
                group,
                conversation,
                device,
                snapshot_sessions,
                run_id
              )

            send_put(
              rows,
              tenant,
              group,
              conversation,
              device,
              answered,
              through,
              session_watermarks,
              snapshot_sessions,
              params,
              run_id,
              invited_again,
              needs_multi_session?,
              opts
            )
        end
    end
  end

  defp multi_session_snapshot?(rows) when is_list(rows) do
    length(rows) > 1 or
      Enum.any?(rows, fn r ->
        not primary_row?(r) or List.wrap(get_in(r.start || %{}, ["pending_multi_starts"])) != []
      end)
  end

  defp handle_missing_slots(
         rows,
         present_rows,
         missing_rows,
         group,
         conversation,
         device,
         answered,
         run_id,
         invited_again
       ) do
    primary_missing? =
      Enum.any?(missing_rows, &primary_row?/1) or not Enum.any?(present_rows, &primary_row?/1)

    if primary_missing? do
      if invited_again do
        {:error, :unknown_after_invite}
      else
        old_primary_run_id = primary_persisted_run_id(rows)

        case invite_again_all(rows, group, conversation, device, answered, old_primary_run_id) do
          :ok -> give_now(group, conversation, device, true)
          :stale -> :ok
          other -> other
        end
      end
    else
      case StationTaskSessions.demote_missing_secondaries(
             group,
             conversation,
             device,
             missing_rows,
             run_id
           ) do
        :ok ->
          give_now(group, conversation, device, invited_again)

        {:error, :stale} ->
          :ok

        {:error, :primary_missing} ->
          if invited_again do
            {:error, :unknown_after_invite}
          else
            old_primary_run_id = primary_persisted_run_id(rows)

            case invite_again_all(rows, group, conversation, device, answered, old_primary_run_id) do
              :ok -> give_now(group, conversation, device, true)
              :stale -> :ok
              other -> other
            end
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp mark_claims_confirmed(group, conversation, device, sessions, expected_run_id) do
    mod = task_sessions()

    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, :mark_claims_confirmed, 5) ->
        mod.mark_claims_confirmed(group, conversation, device, sessions, expected_run_id)

      Code.ensure_loaded?(mod) and function_exported?(mod, :mark_claims_confirmed, 4) ->
        mod.mark_claims_confirmed(group, conversation, device, sessions)

      true ->
        StationTaskSessions.mark_claims_confirmed(
          group,
          conversation,
          device,
          sessions,
          expected_run_id
        )
    end
  end

  defp mark_claims_unconfirmed(group, conversation, device, sessions, expected_run_id) do
    if sessions == [] do
      :ok
    else
      mod = task_sessions()

      cond do
        Code.ensure_loaded?(mod) and function_exported?(mod, :mark_claims_unconfirmed, 5) ->
          mod.mark_claims_unconfirmed(group, conversation, device, sessions, expected_run_id)

        Code.ensure_loaded?(mod) and function_exported?(mod, :mark_claims_unconfirmed, 4) ->
          mod.mark_claims_unconfirmed(group, conversation, device, sessions)

        true ->
          StationTaskSessions.mark_claims_unconfirmed(
            group,
            conversation,
            device,
            sessions,
            expected_run_id
          )
      end
    end
  end

  defp row_has_claim_token?(r) do
    token = get_in(r.start || %{}, ["claim_token"])
    is_binary(token) and token != ""
  end

  defp row_needs_claim_confirm?(r) do
    row_has_claim_token?(r) and get_in(r.start || %{}, ["claim_confirmed"]) != true
  end

  defp apply_present_slots_ack(
         rows,
         present_slots,
         tenant,
         group,
         conversation,
         device,
         answered,
         through,
         run_id,
         invited_again,
         opts
       ) do
    committed_slots = Keyword.get(opts, :committed_slots)
    accepted_claims = Keyword.get(opts, :accepted_claims)
    quiet_confirm? = Keyword.get(opts, :quiet_confirm?, false)
    allow_recurse? = Keyword.get(opts, :allow_recurse?, true)

    present_set =
      MapSet.new(present_slots, fn s -> {s["slot"] || "lead", s["session"]} end)

    committed_set =
      if is_list(committed_slots) do
        MapSet.new(committed_slots, fn s -> {s["slot"] || "lead", s["session"]} end)
      else
        nil
      end

    accepted_claim_set =
      if is_list(accepted_claims) do
        accepted_claims
        |> Enum.filter(fn c ->
          is_map(c) and is_binary(c["slot"]) and c["slot"] != "" and
            is_binary(c["session"]) and c["session"] != "" and
            is_binary(c["claim_token"]) and c["claim_token"] != ""
        end)
        |> MapSet.new(fn c -> {c["slot"], c["session"], c["claim_token"]} end)
      else
        nil
      end

    {present_rows, missing_rows} =
      Enum.split_with(rows, &MapSet.member?(present_set, {slot_of(&1), &1.session}))

    {confirmed_present_rows, unconfirmed_present_rows} =
      Enum.split_with(present_rows, fn r ->
        if row_needs_claim_confirm?(r) do
          # Unconfirmed claims ALWAYS require exact `{slot, session, claim_token}` triple proof
          # in ACK `confirmed_claims` (NEVER falling back to slot-level `committed_slots`).
          is_list(accepted_claims) and
            MapSet.member?(
              accepted_claim_set,
              {slot_of(r), r.session, r.start["claim_token"]}
            )
        else
          if is_list(committed_slots) do
            # Station's explicit `committed_slots` negation ALWAYS overrides local `claim_confirmed: true`!
            MapSet.member?(committed_set, {slot_of(r), r.session})
          else
            # Compatibility fallback without explicit `committed_slots` (e.g. `task.status` fallback):
            # preserve already-confirmed rows.
            true
          end
        end
      end)

    # Reset local `claim_confirmed` to false ONLY when Station explicitly excluded the row
    # from `committed_slots`, so the next `do_put` automatically re-sends its `confirmed_claims`.
    to_unconfirm =
      if is_list(committed_slots) do
        Enum.filter(unconfirmed_present_rows, fn r ->
          row_has_claim_token?(r) and get_in(r.start || %{}, ["claim_confirmed"]) == true
        end)
      else
        []
      end

    # Guard `rebind_run_id`, `mark_claims_unconfirmed`, `sent_sessions`, and `mark_claims_confirmed`
    # under the same `admitted_run == {:ok, ^run_id}` check + SQL `connector_run_id = $run_id` fence
    # so a delayed ACK from an earlier run can never mutate a newer generation's rows.
    {sent_res, unconfirm_res, confirm_res} =
      case admitted_run(tenant, group, device) do
        {:ok, ^run_id} ->
          Enum.each(present_rows, fn r ->
            old_run = get_in(r.start || %{}, ["connector_run_id"])

            if is_binary(old_run) and old_run != "" and old_run != run_id do
              _ =
                StationTaskSessions.rebind_run_id(
                  group,
                  conversation,
                  device,
                  r.session,
                  old_run,
                  run_id
                )
            end
          end)

          unconf =
            mark_claims_unconfirmed(
              group,
              conversation,
              device,
              Enum.map(to_unconfirm, & &1.session),
              run_id
            )

          sent =
            if confirmed_present_rows != [] do
              StationTaskSessions.sent_sessions(
                group,
                conversation,
                device,
                Enum.map(confirmed_present_rows, &{&1.session, &1.sent}),
                through,
                run_id
              )
            else
              :ok
            end

          conf =
            if sent == :ok and confirmed_present_rows != [] do
              mark_claims_confirmed(
                group,
                conversation,
                device,
                Enum.map(confirmed_present_rows, & &1.session),
                run_id
              )
            else
              :ok
            end

          {sent, unconf, conf}

        _changed ->
          {:stale, :ok, :ok}
      end

    cond do
      match?({:error, _}, unconfirm_res) ->
        unconfirm_res

      match?({:error, _}, confirm_res) ->
        confirm_res

      # Only enter `handle_missing_slots` when `sent_res == :ok` AND `run_id` is STILL
      # the admitted generation; a stale generation's absence receipt must NEVER demote!
      missing_rows != [] and sent_res == :ok and
          admitted_run(tenant, group, device) == {:ok, run_id} ->
        all_rows = Keyword.get(opts, :routing_rows, rows)

        all_present_rows =
          Enum.filter(all_rows, &MapSet.member?(present_set, {slot_of(&1), &1.session}))

        handle_missing_slots(
          all_rows,
          all_present_rows,
          missing_rows,
          group,
          conversation,
          device,
          answered,
          run_id,
          invited_again
        )

      unconfirmed_present_rows != [] and sent_res == :ok ->
        # If healthy confirmed rows advanced on this page (and raw query wasn't empty),
        # drain their remaining pages independently before returning `:retry_pending` so
        # one unconfirmed slot never stalls healthy slots at page 1, while preserving
        # full-task `routing_rows`, pinning to `run_id`, and stopping immediately on `:stale`.
        if allow_recurse? and not quiet_confirm? and confirmed_present_rows != [] do
          advanced_confirmed =
            Enum.map(confirmed_present_rows, &%{&1 | sent: max(&1.sent, through)})

          case drain_confirmed_rows_pages(
                 advanced_confirmed,
                 rows,
                 group,
                 conversation,
                 device,
                 invited_again,
                 run_id
               ) do
            :stale -> :ok
            res when res in [:ok, {:ok, :retry_pending}] -> {:ok, :retry_pending}
            other -> other
          end
        else
          {:ok, :retry_pending}
        end

      quiet_confirm? and sent_res == :ok ->
        :ok

      not allow_recurse? and sent_res == :ok ->
        :ok

      sent_res == :ok ->
        give_now(group, conversation, device, invited_again)

      sent_res == :stale ->
        if allow_recurse?, do: :ok, else: :stale

      true ->
        sent_res
    end
  end

  defp reconcile_put_without_present_slots(
         rows,
         tenant,
         group,
         conversation,
         device,
         answered,
         through,
         _snapshot_sessions,
         run_id,
         invited_again,
         opts
       ) do
    ask_row = pick_ask_row(rows, nil)
    status_params = %{"task" => conversation, "session" => ask_row.session, "all" => true}

    case connector().request(run_id, "task.status", status_params, timeout: @status_timeout_ms) do
      {:ok, %{"slots" => raw_slots}} when is_list(raw_slots) ->
        apply_present_slots_ack(
          rows,
          raw_slots,
          tenant,
          group,
          conversation,
          device,
          answered,
          through,
          run_id,
          invited_again,
          Keyword.put(opts, :committed_slots, nil)
        )

      {:ok, %{"unknown" => true}} ->
        if invited_again do
          {:error, :unknown_after_invite}
        else
          all_rows = Keyword.get(opts, :routing_rows, rows)
          old_primary_run_id = primary_persisted_run_id(all_rows)

          case invite_again_all(
                 all_rows,
                 group,
                 conversation,
                 device,
                 answered,
                 old_primary_run_id
               ) do
            :ok -> give_now(group, conversation, device, true)
            :stale -> :ok
            other -> other
          end
        end

      {:ok, %{"state" => "unknown"}} ->
        if invited_again do
          {:error, :unknown_after_invite}
        else
          all_rows = Keyword.get(opts, :routing_rows, rows)
          old_primary_run_id = primary_persisted_run_id(all_rows)

          case invite_again_all(
                 all_rows,
                 group,
                 conversation,
                 device,
                 answered,
                 old_primary_run_id
               ) do
            :ok -> give_now(group, conversation, device, true)
            :stale -> :ok
            other -> other
          end
        end

      {:ok, %{"gone" => true}} ->
        # Single-session `task.status` reporting `gone` does NOT prove the entire multi-session
        # Task left the station; preserve all watermarks & bindings until `task.put` itself proves `gone`.
        :unreachable

      {:ok, %{"state" => "gone"}} ->
        :unreachable

      _ ->
        # Without per-slot proof on a multi-session Task, NEVER advance `sent`.
        :unreachable
    end
  end

  defp send_put(
         rows,
         tenant,
         group,
         conversation,
         device,
         answered,
         through,
         session_watermarks,
         snapshot_sessions,
         params,
         run_id,
         invited_again,
         needs_multi_session?,
         opts
       ) do
    sent_confirmed_claims? = Map.has_key?(params, "confirmed_claims")
    quiet_confirm? = Keyword.get(opts, :quiet_confirm?, false)
    allow_recurse? = Keyword.get(opts, :allow_recurse?, true)
    routing_rows = Keyword.get(opts, :routing_rows, rows)

    case connector().request(run_id, "task.put", params, timeout: @put_timeout_ms) do
      # Still unknown once invited again: not answering as it should, given again later.
      {:ok, %{"unknown" => true}} when invited_again ->
        {:error, :unknown_after_invite}

      {:ok, %{"unknown" => true}} ->
        old_primary_run_id = primary_persisted_run_id(routing_rows)

        case invite_again_all(
               routing_rows,
               group,
               conversation,
               device,
               answered,
               old_primary_run_id
             ) do
          :ok -> give_now(group, conversation, device, true)
          :stale -> :ok
          other -> other
        end

      {:ok, %{"gone" => true}} ->
        # Explicit `gone`: thread exists on station with 0 active sessions -> clean up, NEVER revive!
        Logger.info(
          "station no longer takes part in a Task, it said: group=#{group} task=#{conversation} device=#{device}"
        )

        StationTaskSessions.leave_sessions(
          group,
          conversation,
          device,
          Enum.map(routing_rows, & &1.session),
          run_id
        )

      {:ok, %{"present_slots" => present_slots} = answer} when is_list(present_slots) ->
        station_activity(group, device)

        apply_present_slots_ack(
          rows,
          present_slots,
          tenant,
          group,
          conversation,
          device,
          answered,
          through,
          run_id,
          invited_again,
          committed_slots: Map.get(answer, "committed_slots"),
          accepted_claims: Map.get(answer, "confirmed_claims"),
          quiet_confirm?: quiet_confirm?,
          allow_recurse?: allow_recurse?,
          routing_rows: routing_rows
        )

      {:ok, _answer} ->
        station_activity(group, device)

        cond do
          needs_multi_session? ->
            # Multi-session request WITHOUT `present_slots`: NEVER settle `sent_sessions`
            # directly; require per-slot proof via `task.status {all: true}` on `run_id`.
            reconcile_put_without_present_slots(
              rows,
              tenant,
              group,
              conversation,
              device,
              answered,
              through,
              snapshot_sessions,
              run_id,
              invited_again,
              quiet_confirm?: quiet_confirm?,
              allow_recurse?: allow_recurse?,
              routing_rows: routing_rows
            )

          sent_confirmed_claims? ->
            # Single-session request that sent `confirmed_claims` without `present_slots`/`committed_slots`
            # proof: NEVER advance `sent` or mark `claim_confirmed: true` without Station proof!
            {:ok, :retry_pending}

          true ->
            # Confirmed legacy single-session primary with no `pending_multi_starts` and no pending claim.
            case admitted_run(tenant, group, device) do
              {:ok, ^run_id} ->
                Enum.each(rows, fn r ->
                  old_run = get_in(r.start || %{}, ["connector_run_id"])

                  if is_binary(old_run) and old_run != "" and old_run != run_id do
                    _ =
                      StationTaskSessions.rebind_run_id(
                        group,
                        conversation,
                        device,
                        r.session,
                        old_run,
                        run_id
                      )
                  end
                end)

                case StationTaskSessions.sent_sessions(
                       group,
                       conversation,
                       device,
                       session_watermarks,
                       through,
                       run_id
                     ) do
                  :ok ->
                    case mark_claims_confirmed(
                           group,
                           conversation,
                           device,
                           snapshot_sessions,
                           run_id
                         ) do
                      :ok ->
                        if quiet_confirm? or not allow_recurse?,
                          do: :ok,
                          else: give_now(group, conversation, device, invited_again)

                      {:error, _} = err ->
                        err
                    end

                  :stale ->
                    if allow_recurse?, do: :ok, else: :stale

                  {:error, _} = err ->
                    err
                end

              _changed ->
                if allow_recurse?, do: :unreachable, else: :stale
            end
        end

      {:error, :disconnected} ->
        :unreachable

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp multi_session_routing(rows, group, conversation, messages) do
    case fetch_participants(group, conversation) do
      {:ok, participants} when is_list(participants) ->
        {:ok, build_multi_session_routing(rows, participants)}

      {:error, reason} ->
        has_restricted? =
          Enum.any?(messages, &SalixIM.ConversationMessage.explicit_visibility_restriction?/1)

        if length(rows) > 1 or has_restricted? do
          {:error, {:participants_unavailable, reason}}
        else
          {:ok,
           %{
             multi?: false,
             pid_to_slot: %{},
             primary_slot: "lead",
             active_workers: [],
             roster: nil
           }}
        end
    end
  end

  defp build_multi_session_routing(rows, participants) do
    active_workers =
      Enum.filter(participants, fn p ->
        p["actor_type"] == "agent" and p["role_label"] == "worker" and p["state"] != "inactive"
      end)

    multi? = length(rows) > 1 or length(active_workers) > 1

    if multi? do
      pid_to_slot =
        Enum.reduce(rows, %{}, fn row, acc ->
          slot = slot_of(row)
          pid = get_in(row.start || %{}, ["participant_id"])

          if is_binary(pid) and pid != "" do
            Map.put(acc, pid, slot)
          else
            # Match strictly by slot -> target_key; never fall back a secondary slot to primary!
            matched =
              if primary_row?(row) do
                Enum.find(
                  active_workers,
                  &(&1["agent_id"] == row.agent_id and
                      SalixIM.TaskSessionSlots.primary_worker?(&1))
                )
              else
                Enum.find(
                  active_workers,
                  &(&1["agent_id"] == row.agent_id and &1["target_key"] == slot)
                )
              end

            case matched do
              %{"participant_id" => p_id} -> Map.put(acc, p_id, slot)
              _ -> acc
            end
          end
        end)

      primary_slot =
        case Enum.find(rows, &primary_row?/1) do
          nil -> "lead"
          r -> slot_of(r)
        end

      roster_source =
        if length(active_workers) >= length(rows) and active_workers != [] do
          Enum.map(active_workers, fn p ->
            primary? = SalixIM.TaskSessionSlots.primary_worker?(p)
            slot = SalixIM.TaskSessionSlots.worker_slot(p) || "lead"
            label = SalixIM.TaskSessionSlots.worker_label(p)
            role_desc = get_in(p, ["payload", "role_instructions"])

            %{
              "slot" => slot,
              "primary" => primary?
            }
            |> put_present("label", label)
            |> put_present("role", role_desc)
            |> put_present("participant_id", p["participant_id"])
          end)
        else
          Enum.map(rows, fn row ->
            slot = slot_of(row)
            pid = get_in(row.start || %{}, ["participant_id"])
            p = Enum.find(active_workers, &(&1["participant_id"] == pid))

            label =
              (p && SalixIM.TaskSessionSlots.worker_label(p)) ||
                get_in(row.start || %{}, ["label"])

            role_desc =
              (p && get_in(p, ["payload", "role_instructions"])) ||
                get_in(row.start || %{}, ["role"])

            %{
              "slot" => slot,
              "primary" => primary_row?(row)
            }
            |> put_present("label", label)
            |> put_present("role", role_desc)
            |> put_present("participant_id", pid)
          end)
        end

      %{
        multi?: true,
        pid_to_slot: pid_to_slot,
        primary_slot: primary_slot,
        active_workers: active_workers,
        roster: roster_source
      }
    else
      %{
        multi?: false,
        pid_to_slot: %{},
        primary_slot: "lead",
        active_workers: active_workers,
        roster: nil
      }
    end
  end

  defp put_multi_routing(params, rows, %{multi?: true, roster: roster}) do
    answered_by_slot =
      Map.new(rows, fn row ->
        {slot_of(row), row.answered || 0}
      end)

    params
    |> Map.put("roster", roster)
    |> Map.put("answered_by_slot", answered_by_slot)
  end

  defp put_multi_routing(params, _rows, _routing), do: params

  # What kind of station `device` is: the Group's Cloud VM, a Task's sandbox,
  # or a person's device.
  defp place_of(group, device) do
    cond do
      device == SalixStore.RuntimeIds.cloud_vm_device_id(group) -> :cloud_vm
      SalixStore.CodingSandboxes.device?(device) -> :sandbox
      true -> :device
    end
  end

  # The station has no thread of the Task (disk loss / restart): re-invite
  # primary first and atomically swap primary + delete ONLY exact snapshot
  # stale secondaries + persist `pending_multi_starts` (with each secondary's
  # preserved `answered` watermark) in a SINGLE DB transaction via
  # `recover_device_primary/6`, then invite secondaries via `invite_secondary_list/3`.
  defp invite_again_all(rows, group, conversation, device, fallback_answered, run_id) do
    [primary_row | secondary_rows] =
      rows
      |> Enum.sort_by(fn r -> if primary_row?(r), do: 0, else: 1 end)

    multi? = secondary_rows != []

    binding_lifecycle_keys = [
      "connector_run_id",
      "binding_token",
      "claim_token",
      "claim_confirmed",
      "invite_id",
      "committed_invite_ids"
    ]

    primary_start = Map.drop(start_of(primary_row), binding_lifecycle_keys)
    primary_slot = slot_of(primary_row)
    primary_answered = primary_row.answered || fallback_answered
    stale_secondary_sessions = Enum.map(secondary_rows, & &1.session)

    secondary_entries =
      Enum.map(secondary_rows, fn r ->
        %{
          "slot" => slot_of(r),
          "is_primary" => false,
          "agent_id" => r.agent_id,
          "answered" => r.answered || 0,
          "invite_id" => SalixStore.Ids.new_session_id(),
          "demoted_session" => r.session,
          "demoted_binding_token" => get_in(r.start || %{}, ["binding_token"]) || r.session,
          "participant_id" => get_in(r.start || %{}, ["participant_id"]),
          "start" => Map.drop(start_of(r), binding_lifecycle_keys)
        }
      end)

    case invite_with_run(%{
           tenant_id: primary_row.tenant_id,
           group_id: group,
           conversation_id: conversation,
           device_id: device,
           start: primary_start,
           answered: primary_answered,
           slot: primary_slot,
           join: false,
           multi_session: multi?
         }) do
      {:ok, {primary_session, used_run_id}} when is_binary(primary_session) ->
        if primary_session in stale_secondary_sessions do
          Logger.warning(
            "station returned an existing secondary session #{primary_session} for primary recovery on Task #{conversation}; refusing recovery"
          )

          {:error, :primary_collided_with_secondary}
        else
          Logger.info(
            "a station that lost a Task was invited to it again: group=#{group} task=#{conversation} device=#{device} slot=#{primary_slot} session=#{primary_session}"
          )

          SystemsRuntime.Telemetry.execute(
            [:salix_web, :station_task, :lost_thread],
            %{},
            %{kind: place_of(group, device)}
          )

          primary_start_with_pending =
            if secondary_entries == [],
              do: Map.delete(primary_start, "pending_multi_starts"),
              else: Map.put(primary_start, "pending_multi_starts", secondary_entries)

          case StationTaskSessions.recover_device_primary(
                 primary_row,
                 primary_session,
                 used_run_id,
                 primary_start_with_pending,
                 primary_answered,
                 stale_secondary_sessions,
                 run_id
               ) do
            {:ok, _status, committed_pending} ->
              if committed_pending != [] do
                new_primary_row = %{
                  primary_row
                  | session: primary_session,
                    start: Map.put(primary_start, "pending_multi_starts", committed_pending)
                }

                case invite_secondary_list(new_primary_row, committed_pending) do
                  :resumed -> :ok
                  :ok -> :ok
                  :needs_primary_recovery -> {:error, :needs_primary_recovery}
                  other -> other
                end
              else
                :ok
              end

            {:error, :stale} ->
              :stale

            {:error, _} = err ->
              err
          end
        end

      {:ok, :when_connected} ->
        :unreachable

      {:error, :device_offline} ->
        :unreachable

      {:error, _} = error ->
        error
    end
  end

  # What the station was first invited with (kept with its Session; for those
  # invited before it was kept, `SalixWeb.Migrations.StationTaskStarts` kept
  # it). None kept (or a map containing only `connector_run_id`): the Task's
  # Worker asks, and the station runs its default runtime and model.
  defp start_of(%{start: %{} = start, agent_id: agent_id}) do
    if Map.delete(start, "connector_run_id") == %{} do
      SalixIM.TaskConversationInput.station_start(agent_id, nil)
    else
      start
    end
  end

  defp start_of(%{start: %{} = start}), do: start

  defp start_of(%{agent_id: agent_id}),
    do: SalixIM.TaskConversationInput.station_start(agent_id, nil)

  # Through which Message the Sessions of the station `device` answered the
  # Task already. Kept with them as their posts arrive (`post/2`); for those
  # from before it was kept, the Task is read for it once, and it is kept.
  defp answered(rows, group, conversation, device) do
    kept = rows |> Enum.map(&(&1.answered || 0)) |> Enum.max()

    if Enum.any?(rows, &is_nil(&1.answered)) do
      with {:ok, read} <- read_answered(group, conversation, device, 0, 0),
           :ok <- StationTaskSessions.answered(group, conversation, device, max(read, kept)),
           do: {:ok, max(read, kept)}
    else
      {:ok, kept}
    end
  end

  # The seq of the last Message a Session of the station `device` ended a turn
  # with in the Task (it declared all_done or need_help); 0 when none did.
  # Messages are kept by seq alone, so the Task is read from its start, a part
  # at a time as it is given.
  defp read_answered(group, conversation, device, after_seq, last) do
    case conversations().messages_after(group, conversation, after_seq, @put_limit) do
      {:ok, []} ->
        {:ok, last}

      {:ok, messages} ->
        through = Enum.reduce(messages, after_seq, &max(&1["seq"], &2))

        last =
          Enum.reduce(messages, last, fn message, last ->
            metadata = message["metadata"] || %{}

            if message["actor_type"] == "agent" and metadata["device_id"] == device and
                 is_binary(metadata["session"]) and metadata["declared"] in @ended_turn,
               do: max(message["seq"], last),
               else: last
          end)

        read_answered(group, conversation, device, through, last)

      {:error, _} = error ->
        error
    end
  end

  # A Message as the station is given it. `author.session`: the Session of
  # that station that posted it, one taking part now or one a Session of it
  # took the place of since (it lost the Task and was invited again): the
  # station keeps it as its Session's own, with what it declared.
  defp message(message, device, routing) do
    metadata = message["metadata"] || %{}

    author =
      case message do
        %{"actor_type" => "agent", "agent_id" => agent_id} ->
          own = metadata["device_id"] == device and is_binary(metadata["session"])

          if own,
            do: %{"kind" => "agent", "id" => agent_id, "session" => metadata["session"]},
            else: %{"kind" => "agent", "id" => agent_id}

        %{"actor_type" => "user", "user_id" => user_id} when is_binary(user_id) ->
          %{"kind" => "person", "id" => user_id}

        _ ->
          %{"kind" => "ember", "id" => message["actor_type"] || "salix"}
      end

    %{
      "seq" => message["seq"],
      "author" => author,
      "text" => message_text(message),
      "declared" => metadata["declared"],
      "at" => message["created_at"]
    }
    |> put_present("id", message["message_id"])
    |> put_files(message)
    |> put_milestones(message["content"])
    |> put_deliver_to_slots(metadata, routing)
    |> put_visible_to_slots(message, routing)
  end

  defp put_deliver_to_slots(
         given,
         metadata,
         %{multi?: true, pid_to_slot: pid_to_slot, primary_slot: primary_slot}
       ) do
    case metadata["wake_targets"] do
      targets when is_list(targets) ->
        slots =
          targets
          |> Enum.map(&Map.get(pid_to_slot, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        Map.put(given, "deliver_to_slots", slots)

      _ ->
        # Legacy message without `wake_targets` on a Task that later became
        # multi-session: route exclusively to primary, never broadcast to all slots.
        Map.put(given, "deliver_to_slots", [primary_slot || "lead"])
    end
  end

  defp put_deliver_to_slots(given, _metadata, _routing), do: given

  # Distinguishes truly public messages from explicitly restricted ones via the
  # single source of truth `ConversationMessage.explicit_visibility_restriction?/1`.
  # Runs on BOTH single-session and multi-session Tasks so a restricted message
  # written while a Task has 1 slot still records `visible_to_slots` and cannot
  # leak when a 2nd slot joins later.
  defp put_visible_to_slots(given, message, %{active_workers: [_ | _] = workers} = routing) do
    cond do
      SalixIM.ConversationMessage.explicit_visibility_restriction?(message) ->
        visible_slots =
          workers
          |> Enum.filter(fn p ->
            pid = p["participant_id"]
            is_binary(pid) and pid != "" and SalixIM.ConversationMessage.visible_to?(pid, message)
          end)
          |> Enum.map(&(SalixIM.TaskSessionSlots.worker_slot(&1) || "lead"))
          |> Enum.uniq()

        Map.put(given, "visible_to_slots", visible_slots)

      routing.multi? ->
        all_slots =
          workers
          |> Enum.map(&(SalixIM.TaskSessionSlots.worker_slot(&1) || "lead"))
          |> Enum.uniq()

        visible_slots =
          workers
          |> Enum.filter(fn p ->
            pid = p["participant_id"]
            is_binary(pid) and pid != "" and SalixIM.ConversationMessage.visible_to?(pid, message)
          end)
          |> Enum.map(&(SalixIM.TaskSessionSlots.worker_slot(&1) || "lead"))
          |> Enum.uniq()

        if length(visible_slots) < length(all_slots) do
          Map.put(given, "visible_to_slots", visible_slots)
        else
          given
        end

      true ->
        given
    end
  end

  defp put_visible_to_slots(given, _message, _routing), do: given

  # Who said each Message, by name and email, for a station that shows its
  # people (a still.fail station's Comma connect): each member asked once a put.
  defp named(messages, tenant, group) do
    people =
      for %{"author" => %{"kind" => "person", "id" => id}} <- messages,
          uniq: true,
          into: %{},
          do: {id, StationMembers.member(tenant, group, id)}

    Enum.map(messages, fn
      %{"author" => %{"kind" => "person", "id" => id} = author} = m ->
        case people[id] do
          {:ok, person} ->
            known =
              for {k, v} <- Map.take(person, ["name", "email"]),
                  is_binary(v),
                  into: %{},
                  do: {k, v}

            %{m | "author" => Map.merge(author, known)}

          :none ->
            m
        end

      m ->
        m
    end)
  end

  # Both sources are owner-bound. User content and metadata alone grant no read.
  defp file_source(%{"actor_type" => "agent", "agent_id" => agent_id, "content" => content})
       when is_binary(agent_id) and agent_id != "" and is_list(content),
       do: {agent_id, content}

  defp file_source(%{
         "actor_type" => "user",
         "owner_uploads" => %{"agent_id" => agent_id, "files" => files}
       })
       when is_binary(agent_id) and agent_id != "" and is_list(files),
       do: {agent_id, files}

  defp file_source(_message), do: {nil, []}

  # The runtime receives its local paths with the downloaded attachments.
  # Do not tell it that the Router's upload paths exist in its sandbox.
  defp message_text(%{"actor_type" => "user"} = message) do
    {_source, files} = file_source(message)

    Enum.reduce(files, text(message["content"]), fn file, words ->
      String.replace(
        words,
        "(workspace file: #{file["path"]})",
        "(attached file: #{file["file_name"]})"
      )
    end)
  end

  defp message_text(message), do: text(message["content"])

  defp put_files(given, message) do
    {_source, content} = file_source(message)

    files =
      content
      |> Enum.with_index()
      |> Enum.flat_map(fn {block, index} ->
        case file_block(block) do
          {:ok, size} ->
            [
              %{
                "index" => index,
                "name" => SalixIM.ConversationAttachments.file_name(block),
                "size" => size
              }
            ]

          :error ->
            []
        end
      end)

    if files == [], do: given, else: Map.put(given, "files", files)
  end

  defp file_block(%{"type" => type, "blob_ref" => %{"size" => size}})
       when type in @file_types and is_integer(size) and size >= 0,
       do: {:ok, size}

  defp file_block(_block), do: :error

  @doc """
  `task.file` from the device of `view`: a part of a file of a Message of the
  Task its Session takes part in, at most #{@file_part} bytes from `offset`
  (base64), with the file's name and size; `missing` when the Message brings
  no such file.
  """
  def file(view, params) when is_map(params) do
    with {:ok, row} <- taking_part(view, params),
         id when is_binary(id) and id != "" <- params["id"],
         index when is_integer(index) and index >= 0 <- params["index"],
         offset when is_integer(offset) and offset >= 0 <- params["offset"] do
      case conversations().message(view.group_id, row.conversation_id, id) do
        {:ok, message} ->
          {agent_id, content} = file_source(message)
          block = Enum.at(content, index)

          with {:ok, size} <- file_block(block),
               {:ok, data} <-
                 conversations().read_part(agent_id, block["blob_ref"], offset, @file_part) do
            {:ok,
             %{
               "name" => SalixIM.ConversationAttachments.file_name(block),
               "size" => size,
               "offset" => offset,
               "data" => Base.encode64(data)
             }}
          else
            :error -> {:ok, %{"missing" => "no such file"}}
            {:error, _} = error -> error
          end

        {:error, reason}
        when reason == :not_found or
               (is_tuple(reason) and elem(reason, 0) in [:not_found, :bad_request]) ->
          {:ok, %{"missing" => "no such Message"}}

        {:error, _} = error ->
          error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def file(_view, _params), do: {:error, :bad_request}

  defp put_milestones(given, content) when is_list(content) do
    case for(
           %{"type" => "milestone", "title" => title} when is_binary(title) <- content,
           do: title
         ) do
      [] -> given
      titles -> Map.put(given, "milestones", titles)
    end
  end

  defp put_milestones(given, _content), do: given

  @doc "`task.post` from the device of `view`: a Message of its Session, once per `key`; its seq."
  def post(view, params) when is_map(params) do
    milestones = milestones_given(params["milestones"])

    with {:ok, row} <- taking_part(view, params),
         {:ok, files} <- files_given(params["files"]),
         text when is_binary(text) and (text != "" or milestones != [] or files != []) <-
           params["text"],
         key when is_binary(key) and key != "" and byte_size(key) <= 128 <- params["key"],
         {:ok, participant_id} <- worker(view.group_id, row),
         {:ok, file_blocks} <- stage_files(view, row, key, files) do
      declared = if params["declared"] in @declared, do: params["declared"]

      # A post that ends a turn: its Session answered what it had been delivered
      # (`answered_through_seq`, including explicit `0`; `nil` for legacy stations).
      answered_through_seq =
        case params["answered_through_seq"] do
          n when is_integer(n) and n >= 0 -> n
          _ -> nil
        end

      attrs = %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => row.agent_id,
        "participant_id" => participant_id,
        "content" => content(text, milestones, file_blocks) |> asking(params["question"]),
        "client_request_id" => "station-task:" <> digest([view.device_id, row.session, key]),
        "metadata" =>
          %{"kind" => "station_task", "device_id" => view.device_id, "session" => row.session}
          |> put_present("declared", declared)
          |> then(
            &if(is_integer(answered_through_seq),
              do: Map.put(&1, "answered_through_seq", answered_through_seq),
              else: &1
            )
          )
          |> put_cannot_start(params["cannot_start"])
      }

      with {:ok, _answered} <- answered([row], view.group_id, row.conversation_id, view.device_id),
           {:ok, %{"seq" => seq}} <-
             conversations().append(view.group_id, row.conversation_id, row.agent_id, attrs) do
        # Appended, the Message is the station's work whether or not its turn ends well.
        station_activity(view.group_id, view.device_id)

        with :ok <- ended_turn(view, row, declared, seq, answered_through_seq),
             do: {:ok, %{"seq" => seq}}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :bad_request}
    end
  end

  def post(_view, _params), do: {:error, :bad_request}

  # The station's word that its Session's turn did not start (`cannot_start`,
  # why): the Message is a `task_run_blocked` one, which clients show with a way
  # to run the Task on another model (`SalixIM.TaskRun`).
  defp put_cannot_start(metadata, %{"error" => error}) when is_binary(error) and error != "",
    do:
      Map.merge(metadata, %{
        "message_type" => "task_run_blocked",
        "task_run_blocked" => %{"error" => String.slice(error, 0, @last_failure_chars)}
      })

  defp put_cannot_start(metadata, _cannot_start), do: metadata

  # The files a post names (`index`, `name`, `size` each): at most
  # #{@max_post_files}, and #{@max_post_bytes} bytes together.
  defp files_given(nil), do: {:ok, []}

  defp files_given(files) when is_list(files) and length(files) <= @max_post_files do
    given =
      Enum.map(files, fn
        %{"index" => index, "name" => name, "size" => size}
        when is_integer(index) and index >= 0 and is_binary(name) and is_integer(size) and
               size >= 0 ->
          case Path.basename(name) do
            base when base in ["", ".", ".."] or byte_size(base) > 255 -> nil
            base -> %{index: index, name: base, size: size}
          end

        _file ->
          nil
      end)

    cond do
      Enum.any?(given, &is_nil/1) ->
        {:error, :bad_request}

      given |> Enum.map(& &1.size) |> Enum.sum() > @max_post_bytes ->
        {:error, {:bad_request, "the files of one post are at most 1 GiB together"}}

      true ->
        {:ok, given}
    end
  end

  defp files_given(_files), do: {:error, :bad_request}

  # Reads each file the post names from the station (`task.posted_file`), a
  # part at a time, into a blob of the Task's Worker, and places it in the
  # Worker's VFS: the Message names them by path, as a Worker inside Salix
  # attaches its files. One that cannot be read fails the post, and the
  # station's Session is told.
  defp stage_files(_view, _row, _key, []), do: {:ok, []}

  defp stage_files(view, row, key, files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, blocks} ->
      case stage_file(view, row, key, file) do
        {:ok, block} -> {:cont, {:ok, blocks ++ [block]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stage_file(view, row, key, file) do
    path =
      "/uploads/tasks/#{row.conversation_id}/#{digest([row.session, key])}/#{file.index}-#{file.name}"

    state = conversations().blob_init(row.agent_id)

    with {:ok, state} <- pull(view, row, key, file, 0, state),
         {:ok, ref} <- conversations().blob_finish(state),
         :ok <- conversations().place(row.agent_id, path, ref) do
      # String keys, as the Message is read back from the store.
      blob_ref = Map.new(ref, fn {key, value} -> {to_string(key), value} end)
      {:ok, %{"type" => "file", "path" => path, "file_name" => file.name, "blob_ref" => blob_ref}}
    else
      {:error, reason, state} ->
        conversations().blob_abort(state)
        {:error, reason}

      {:error, _} = error ->
        error
    end
  end

  defp pull(_view, _row, _key, %{size: size}, offset, state) when offset >= size,
    do: {:ok, state}

  defp pull(view, row, key, file, offset, state) do
    with {:ok, part} <- pull_part(view, row, key, file, offset),
         {:ok, state} <- conversations().blob_step(state, part) do
      pull(view, row, key, file, offset + byte_size(part), state)
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # One part of a file the station's Session names, from `offset`
  # (`task.posted_file`).
  defp pull_part(view, row, key, file, offset) do
    asked = %{
      "task" => row.conversation_id,
      "session" => row.session,
      "key" => key,
      "index" => file.index,
      "offset" => offset
    }

    with {:ok, %{"data" => data}} when is_binary(data) <-
           connector().request(view.connector_run_id, "task.posted_file", asked,
             timeout: @status_timeout_ms
           ),
         {:ok, part} when part != "" and offset + byte_size(part) <= file.size <-
           Base.decode64(data) do
      {:ok, part}
    else
      {:ok, %{"missing" => why}} -> {:error, {:bad_request, "#{file.name}: #{why}"}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, {:bad_request, "#{file.name} did not come as it was named"}}
    end
  end

  @doc """
  `task.app_deploy` from the device of `view`: its Session deploys a preview
  Version of the app its Task builds (`mini_app`). Only the station of the
  Task's current sandbox may, over that sandbox generation's connection.
  The files the request names (#{inspect(Map.keys(@app_files))}) are read
  from the station a part at a time into temp files on this node, each
  within its size, for the app's owner (`SalixWeb.MiniAppDeploys.deploy/2`).
  The Version is written into the Task as a `mini_app` Message of its
  Worker, once per `key`: a deploy asked again with its key makes no second
  Version and no second Message.

  Answers the Version (`app_id`, `version`, `state`, `name`, `summary`), or
  `{"error": "invalid", "errors": [...]}`, or `{"error": reason, "message"}`.
  A request from a station that has no such authority is an error.
  """
  def app_deploy(view, params) when is_map(params) do
    with {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row),
         {:ok, task} <- conversations().task(view.group_id, row.conversation_id) do
      with {:ok, app_id} <- task_app(task, params["app_id"]),
           {:ok, deploy} <- deploy_given(params),
           {:ok, files} <- app_files_given(params["files"]) do
        deploy_app(view, row, task, app_id, deploy, files)
      else
        {:refused, result} -> {:ok, result}
      end
    end
  end

  def app_deploy(_view, _params), do: {:error, :bad_request}

  @doc """
  `task.app_logs` from the device of `view`: recent backend log lines of the
  app its Task builds (or of its Version `version`), with the authority of
  `app_deploy/2`.
  """
  def app_logs(view, params) when is_map(params) do
    version = params["version"]

    with true <- is_nil(version) or (is_integer(version) and version > 0),
         {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row),
         {:ok, task} <- conversations().task(view.group_id, row.conversation_id) do
      case task_app(task, params["app_id"]) do
        {:ok, app_id} ->
          case SalixWeb.MiniAppDeploys.logs(%{group_id: view.group_id, app_id: app_id}, version) do
            {:ok, lines} when is_list(lines) -> {:ok, %{"lines" => lines}}
            {:error, reason} -> {:ok, app_error(reason)}
          end

        {:refused, result} ->
          {:ok, result}
      end
    else
      false -> {:error, :bad_request}
      {:error, _} = error -> error
    end
  end

  def app_logs(_view, _params), do: {:error, :bad_request}

  @doc """
  `task.tools` from the device of `view`: the Salix tools its Session may call
  with `task.tool_call` (`SalixAgent.StationToolCalls.tools/1`), each with its
  name, description and input schema. Only the station of the Task's current
  sandbox may ask, over that sandbox generation's connection.
  """
  def tools(view, params) when is_map(params) do
    with {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row) do
      {:ok, %{"tools" => SalixAgent.StationToolCalls.tools(tool_ref(view, row))}}
    end
  end

  def tools(_view, _params), do: {:error, :bad_request}

  @doc """
  `task.tool_call` from the device of `view`: its Session calls Salix tool
  `tool` with `args` as the Task's Worker
  (`SalixAgent.StationToolCalls.call/3`), with the authority of `tools/2`.

  Answers the tool's result (`tool`, `error`, `content`, `truncated` when cut),
  or `{"error": reason, "message"}` when the call is not made: arguments too
  large, too many calls in flight, no requester. A request from a
  station that has no such authority is an error.
  """
  def tool_call(view, params) when is_map(params) do
    tool = params["tool"]
    args = params["args"] || %{}

    with true <- is_binary(tool) and tool != "" and is_map(args),
         {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row) do
      case SalixAgent.StationToolCalls.call(tool_ref(view, row), tool, args) do
        {:ok, result} -> {:ok, result}
        {:refused, error, message} -> {:ok, refusal(error, message)}
      end
    else
      false -> {:error, :bad_request}
      {:error, _} = error -> error
    end
  end

  def tool_call(_view, _params), do: {:error, :bad_request}

  @doc """
  `task.login_keep`: the files of a CLI login finished in this sandbox, kept for
  the Task's person as a credential of theirs (`SalixWeb.OAuthFlow.keep_login/5`).
  It is no tool call, so what is kept reaches no agent and no tool archive.
  """
  def login_keep(view, %{"program" => program, "archive" => archive} = params)
      when is_binary(program) and is_binary(archive) do
    with {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row),
         :ok <- allow_station_login(view.group_id),
         owner when is_binary(owner) <- login_owner(view, row) || {:error, :no_requester},
         {:ok, _kept} <-
           SalixWeb.OAuthFlow.keep_login(view.tenant_id, view.group_id, owner, program, archive) do
      {:ok, %{"kept" => true}}
    end
  end

  def login_keep(_view, _params), do: {:error, :bad_request}

  @doc "`task.login_restore`: what `login_keep/2` kept of `program` for the Task's person, if anything."
  def login_restore(view, %{"program" => program} = params) when is_binary(program) do
    with {:ok, row} <- taking_part(view, params),
         :ok <- sandbox_authority(view, row),
         :ok <- allow_station_login(view.group_id),
         owner when is_binary(owner) <- login_owner(view, row) || {:error, :no_requester} do
      case SalixWeb.OAuthFlow.kept_login(view.tenant_id, view.group_id, owner, program) do
        {:ok, archive} -> {:ok, %{"archive" => archive}}
        :none -> {:ok, %{}}
      end
    end
  end

  def login_restore(_view, _params), do: {:error, :bad_request}

  defp allow_station_login(group_id) do
    case Salix.Control.Groups.get(group_id) do
      {:ok, %{"purpose" => "collaboration"}} -> {:error, :forbidden}
      _ -> :ok
    end
  end

  defp login_owner(view, row),
    do:
      SalixAgent.OAuthCredentials.acting_for(%{
        trusted_origin: SalixAgent.StationToolCalls.origin_of(tool_ref(view, row))
      })

  # The call acts for the person whose Task it is (`owner_user_id`, else the
  # provider user who asked for it in a Slack or Feishu chat, `ifc_requester`),
  # under the Task conversation's own IFC label (`SalixIM.IFC.Ingress`).
  defp tool_ref(view, row) do
    requester =
      case conversations().owner(view.group_id, row.conversation_id) do
        {:ok, owner} when is_binary(owner) and owner != "" -> owner
        _ -> nil
      end

    principal =
      with nil <- requester,
           {:ok, task} <- conversations().task(view.group_id, row.conversation_id),
           principal when is_binary(principal) <-
             get_in(task, ["source_refs", "ifc_requester"]) do
        principal
      else
        _ -> nil
      end

    label =
      case SalixIM.IFC.Ingress.conversation_block(%{
             "conversation_id" => row.conversation_id,
             "conversation_kind" => "agent_task"
           }) do
        %{"label" => label} when is_list(label) -> label
        _ -> nil
      end

    %{
      tenant_id: view.tenant_id,
      group_id: view.group_id,
      agent_id: row.agent_id,
      conversation_id: row.conversation_id,
      device_id: view.device_id,
      session: row.session,
      requester: requester,
      principal: principal,
      label: label
    }
  end

  # The station of the Task's own sandbox, over the connection of its current
  # Workload generation: a sandbox that was replaced has no authority
  # (`SalixEnv.StationConnection`), nor has any other station.
  defp sandbox_authority(view, row) do
    if view[:device_id] == SalixStore.CodingSandboxes.device_id(row.conversation_id) do
      case SalixEnv.StationConnection.authorize(view) do
        {:ok, %{"owner" => "coding_task"}} -> :ok
        {:ok, _other} -> {:error, :not_a_sandbox}
        {:error, _} = error -> error
      end
    else
      {:error, :not_a_sandbox}
    end
  end

  # The app the Task builds, which must be the one the Session names.
  defp task_app(%{"mini_app" => %{"app_id" => app_id}}, app_id) when is_binary(app_id),
    do: {:ok, app_id}

  defp task_app(%{"mini_app" => %{"app_id" => _other}}, _app_id),
    do:
      {:refused, refusal("app_mismatch", "this Task builds another app; deploy its app_id only")}

  defp task_app(_task, _app_id),
    do: {:refused, refusal("not_an_app_task", "this Task builds no app, so it cannot deploy one")}

  defp deploy_given(params) do
    key = params["key"]
    commit = params["commit"]
    notes = params["notes"]

    cond do
      not (is_binary(key) and key != "" and byte_size(key) <= 128) ->
        {:refused, refusal("bad_request", "key must be 1 to 128 bytes")}

      not (is_binary(commit) and Regex.match?(~r/\A[0-9a-f]{40}\z/, commit)) ->
        {:refused, refusal("bad_request", "commit must be a full commit SHA")}

      not (is_nil(notes) or (is_binary(notes) and String.length(notes) <= @max_notes_chars)) ->
        {:refused, refusal("bad_request", "notes are at most #{@max_notes_chars} characters")}

      true ->
        {:ok, %{key: key, commit: commit, notes: notes}}
    end
  end

  # The files of a deploy, by name: each at most once, within its size; the
  # manifest, the bundle and the source archive are required. Checked before
  # a byte is read.
  defp app_files_given(files) do
    with {:ok, given} <- files_given(files) do
      roles =
        Enum.map(given, fn file ->
          case Map.fetch(@app_files, file.name) do
            {:ok, {role, max}} when file.size <= max -> {:ok, role, file}
            {:ok, {_role, max}} -> {:too_big, "#{file.name} is larger than #{max} bytes"}
            :error -> {:unknown, "#{file.name} is not a file of a deploy"}
          end
        end)

      names = Enum.map(given, & &1.name)
      problem = Enum.find(roles, &(elem(&1, 0) in [:too_big, :unknown]))

      cond do
        problem ->
          {:refused, refusal("invalid", elem(problem, 1))}

        length(names) != length(Enum.uniq(names)) ->
          {:refused, refusal("invalid", "each file of a deploy is named once")}

        not Enum.all?(~w(comma-app.json bundle.tar source.tar.gz), &(&1 in names)) ->
          {:refused,
           refusal("invalid", "a deploy needs comma-app.json, bundle.tar and source.tar.gz")}

        true ->
          {:ok, Map.new(roles, fn {:ok, role, file} -> {role, file} end)}
      end
    else
      {:error, {:bad_request, message}} -> {:refused, refusal("invalid", message)}
      {:error, _reason} -> {:refused, refusal("invalid", "files must be [{index, name, size}]")}
    end
  end

  defp deploy_app(view, row, task, app_id, deploy, files) do
    dir = Path.join(System.tmp_dir!(), "salix-app-deploy-" <> random_name())

    try do
      with :ok <- File.mkdir_p(dir),
           {:ok, staged} <- stage_app_files(view, row, deploy.key, files, dir),
           {:ok, manifest} <- File.read(staged.manifest),
           # The pull took a while: the sandbox is still the Task's current one.
           :ok <- sandbox_authority(view, row) do
        ctx = %{
          tenant_id: view.tenant_id,
          group_id: view.group_id,
          conversation_id: row.conversation_id,
          agent_id: row.agent_id,
          app_id: app_id,
          key: deploy.key,
          commit: deploy.commit,
          notes: deploy.notes,
          branch: get_in(task, ["repo", "branch"]),
          repo: Map.take(task["repo"] || %{}, ["owner", "name"])
        }

        given =
          staged
          |> Map.delete(:manifest)
          |> Map.new(fn {role, path} -> {role, %{path: path}} end)
          |> Map.put(:manifest, manifest)

        case SalixWeb.MiniAppDeploys.deploy(ctx, given) do
          {:ok, %{} = version} ->
            with {:ok, _message} <- append_app_message(view, row, deploy.key, version),
                 do: {:ok, Map.take(version, ~w(app_id version state name summary))}

          {:error, {:invalid, errors}} when is_list(errors) ->
            {:ok, %{"error" => "invalid", "errors" => errors}}

          {:error, reason} ->
            {:ok, app_error(reason)}
        end
      else
        {:error, {:bad_request, message}} -> {:ok, refusal("file_unreadable", message)}
        {:error, _} = error -> error
      end
    after
      File.rm_rf(dir)
    end
  end

  # Each file, read from the station into a temp file of its own: the path
  # by role (the manifest's too, read back once whole).
  defp stage_app_files(view, row, key, files, dir) do
    Enum.reduce_while(files, {:ok, %{}}, fn {role, file}, {:ok, staged} ->
      path = Path.join(dir, Atom.to_string(role))

      case stage_app_file(view, row, key, file, path) do
        :ok -> {:cont, {:ok, Map.put(staged, role, path)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp stage_app_file(view, row, key, file, path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, io} ->
        try do
          write_parts(view, row, key, file, 0, io)
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:app_file_not_staged, reason}}
    end
  end

  defp write_parts(_view, _row, _key, %{size: size}, offset, _io) when offset >= size, do: :ok

  defp write_parts(view, row, key, file, offset, io) do
    with {:ok, part} <- pull_part(view, row, key, file, offset),
         :ok <- :file.write(io, part) do
      write_parts(view, row, key, file, offset + byte_size(part), io)
    end
  end

  # The Version in the Task, as its Worker wrote it, once per key: its summary
  # is the Message's text, and the `mini_app` block lets clients open it. The
  # Session it came from keeps it as its own (`message/2`).
  defp append_app_message(view, row, key, %{
         "app_id" => app_id,
         "version" => version,
         "name" => name,
         "summary" => summary
       }) do
    with {:ok, participant_id} <- worker(view.group_id, row) do
      conversations().append(view.group_id, row.conversation_id, row.agent_id, %{
        "kind" => "message",
        "actor_type" => "agent",
        "agent_id" => row.agent_id,
        "participant_id" => participant_id,
        "content" => [
          %{"type" => "text", "text" => summary},
          %{
            "type" => "mini_app",
            "version" => 1,
            "app_id" => app_id,
            "app_version" => version,
            "name" => name,
            "summary" => summary
          }
        ],
        "client_request_id" =>
          "station-app-deploy:" <> digest([view.device_id, row.session, key]),
        "metadata" => %{
          "kind" => "mini_app_deploy",
          "device_id" => view.device_id,
          "session" => row.session
        }
      })
    end
  end

  defp append_app_message(_view, _row, _key, version),
    do: {:error, {:bad_app_version, Map.keys(version)}}

  defp refusal(error, message), do: %{"error" => error, "message" => message}

  defp app_error(:mini_apps_unavailable),
    do: refusal("mini_apps_unavailable", "apps are not set up here")

  defp app_error(reason) when is_atom(reason),
    do: refusal(Atom.to_string(reason), String.replace(Atom.to_string(reason), "_", " "))

  defp app_error({reason, message}) when is_atom(reason) and is_binary(message),
    do: refusal(Atom.to_string(reason), message)

  defp app_error(reason), do: refusal("failed", inspect(reason))

  defp random_name, do: Base.url_encode64(SystemsRuntime.Proc.random_bytes(12), padding: false)

  # The titles a station gave (`chat_post` milestones); the Conversation checks them.
  defp milestones_given(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp milestones_given(_list), do: []

  # A question the Session asks with its post (a still.fail station's card) is
  # Comma's question card (`SalixIM.ConversationQuestion`); one that is not a
  # valid card leaves the words alone.
  defp asking(content, %{} = question) do
    blocks = if is_binary(content), do: [%{"type" => "text", "text" => content}], else: content

    case SalixIM.ConversationQuestion.normalize_agent_content(
           blocks ++ [Map.put(question, "type", "question")]
         ) do
      {:ok, asked} -> asked
      {:error, _} -> content
    end
  end

  defp asking(content, _question), do: content

  defp content(text, [], []), do: truncate(text)

  defp content(text, milestones, files) do
    blocks = Enum.map(milestones, &%{"type" => "milestone", "title" => &1})
    text = if text == "", do: [], else: [%{"type" => "text", "text" => truncate(text)}]
    blocks ++ text ++ files
  end

  # A coding Task goes into review with it:
  # - Single-session path unchanged (`ConversationServer.coding_turn_ended/3`).
  # - Multi-session path: when the primary session declares `all_done`/`need_help`,
  #   record `pending_review` atomically and let `StationTaskWatch` settle
  #   `ready_for_review` asynchronously once ALL active sessions are idle + pending == 0.
  defp ended_turn(view, row, declared, seq, answered_through_seq) when declared in @ended_turn do
    through =
      if is_integer(answered_through_seq),
        do: answered_through_seq,
        else: min(row.sent || 0, seq)

    with :ok <-
           StationTaskSessions.ended_turn(
             view.group_id,
             row.conversation_id,
             view.device_id,
             row.session,
             seq,
             through
           ) do
      # What the turn left in a coding Task's sandbox is read now, for its panel.
      if SalixStore.CodingSandboxes.device?(view.device_id),
        do: SalixWeb.CodingSandboxes.turn_ended(view.group_id, row.conversation_id)

      # Multi-session coding Tasks commit `metadata["pending_review"]` atomically
      # inside `ConversationActor.do_append_group_conversation_message` when the
      # primary session's terminal post is inserted (never on replay), so no
      # separate `record_coding_pending_review` RPC is needed here.
      if multi_session_task?(view.group_id, row.conversation_id) do
        :ok
      else
        with {:ok, false} <- unanswered?(view.group_id, row, seq),
             {:ok, _status} <- conversations().turn_ended(view.group_id, row.conversation_id, seq) do
          :ok
        else
          {:ok, true} -> :ok
          {:error, _} = error -> error
        end
      end
    end
  end

  defp ended_turn(_view, _row, _declared, _seq, _answered_through_seq), do: :ok

  defp multi_session_task?(group, conversation) do
    rows_multi? =
      case StationTaskSessions.of_task(group, conversation) do
        {:ok, rows} ->
          rows |> Enum.reject(&StationTaskSessions.awaited?/1) |> length() > 1

        _ ->
          false
      end

    rows_multi? or
      case fetch_participants(group, conversation) do
        {:ok, list} when is_list(list) ->
          Enum.count(list, fn p ->
            p["actor_type"] == "agent" and p["role_label"] == "worker" and
              p["state"] != "inactive"
          end) > 1

        _ ->
          false
      end
  end

  # Whether a Message for the Session (one not its Worker's) is in the Task
  # between what the Session had been given and the post `seq`. A page that
  # does not reach `seq` counts as one.
  defp unanswered?(group, row, seq) do
    with {:ok, messages} <-
           conversations().messages_after(group, row.conversation_id, row.sent, @put_limit) do
      before = Enum.filter(messages, &(&1["seq"] < seq))

      {:ok,
       (length(messages) == @put_limit and Enum.all?(messages, &(&1["seq"] < seq))) or
         Enum.any?(
           before,
           &(&1["kind"] == "message" and
               not (&1["actor_type"] == "agent" and &1["agent_id"] == row.agent_id))
         )}
    end
  end

  defp put_answered(params, answered) when answered > 0, do: Map.put(params, "answered", answered)
  defp put_answered(params, _answered), do: params

  # Where a person opens the Task in the product (`SalixWeb.TaskLinks`), for
  # the station to show with its thread: given with each invite and each put,
  # so a station that took part before has them with its next Messages.
  defp put_links(params, group, conversation) do
    case SalixWeb.TaskLinks.links(group, conversation) do
      %{} = links when map_size(links) > 0 -> Map.put(params, "links", links)
      _none -> params
    end
  end

  # The Session of the asking device that takes part in the Task.
  # Explicitly excludes `awaited?` placeholder rows.
  defp taking_part(%{tenant_id: tenant, group_id: group, device_id: device}, %{
         "task" => task,
         "session" => session
       })
       when is_binary(task) and is_binary(session) do
    case StationTaskSessions.of_task(group, task) do
      {:ok, rows} ->
        Enum.find_value(rows, {:error, :not_taking_part}, fn row ->
          if not StationTaskSessions.awaited?(row) and row.tenant_id == tenant and
               row.device_id == device and row.session == session,
             do: {:ok, row}
        end)

      _ ->
        {:error, :not_taking_part}
    end
  end

  defp taking_part(_view, _params), do: {:error, :not_taking_part}

  # The Task's Worker participant who authors what this Session writes:
  # prefers explicit `row.start["participant_id"]` validated against active
  # participants; when absent on a legacy row, matches `slot_of(row)` strictly
  # against `target_key` (never falling back a secondary slot to primary).
  defp worker(group, row) do
    with {:ok, participants} <- fetch_participants(group, row.conversation_id) do
      explicit_pid = get_in(row, [:start, "participant_id"])

      found =
        if is_binary(explicit_pid) and explicit_pid != "" do
          Enum.find(
            participants,
            &(&1["actor_type"] == "agent" and &1["participant_id"] == explicit_pid and
                &1["role_label"] == "worker")
          )
        else
          workers =
            Enum.filter(
              participants,
              &(&1["actor_type"] == "agent" and &1["agent_id"] == row.agent_id and
                  &1["role_label"] == "worker")
            )

          if primary_row?(row) do
            Enum.find(workers, &SalixIM.TaskSessionSlots.primary_worker?/1) || List.first(workers)
          else
            slot = slot_of(row)
            Enum.find(workers, &(&1["target_key"] == slot))
          end
        end

      case found do
        %{"participant_id" => id} -> {:ok, id}
        nil -> {:error, :not_taking_part}
      end
    end
  end

  defp admitted_run(tenant, group, device) do
    with {:ok, run, _caps} <- admitted_run_with_caps(tenant, group, device),
         do: {:ok, run}
  end

  defp admitted_run_with_caps(tenant, group, device) do
    with {:ok, %{"status" => "connected", "connector_run_id" => run} = current}
         when is_binary(run) <-
           SalixEnv.Registry.get_device(tenant, group, device),
         {:ok, _owner} <-
           SalixEnv.StationConnection.authorize(
             SalixStore.ComputeStation.connection(tenant, group, current)
           ) do
      {:ok, run, get_in(current, ["meta", "capabilities"]) || %{}}
    else
      {:error, :not_found} -> {:error, :device_offline}
      {:error, _} = error -> error
      _ -> {:error, :device_offline}
    end
  end

  defp online_run(tenant, group, device) do
    case SalixEnv.Registry.get_device(tenant, group, device) do
      {:ok, %{"status" => "connected", "connector_run_id" => run_id}}
      when is_binary(run_id) and run_id != "" ->
        run_id

      _ ->
        nil
    end
  end

  defp reason(reason) when is_binary(reason), do: reason
  defp reason(reason), do: inspect(reason)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp digest(parts) do
    :crypto.hash(:sha256, Enum.join(parts, "\n"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp truncate(text) when byte_size(text) <= @max_text_bytes, do: text

  defp truncate(text) do
    text
    |> binary_part(0, @max_text_bytes)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      %{type: "text", text: text} when is_binary(text) -> [text]
      text when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  defp text(_content), do: ""

  # A station that posts or takes a Task Message is at work: the Group's Cloud
  # VM, when the station is its, counts it toward its idle clock.
  defp station_activity(group, device),
    do: SalixWeb.ComputeProviders.Cloudflare.mark_station_activity(group, device)

  @doc false
  def conversations_module, do: conversations()

  defp conversations, do: config(:conversations, __MODULE__.Conversations)
  defp connector, do: config(:connector, SalixEnv.Connector.Live)
  defp task_sessions, do: config(:task_sessions, StationTaskSessions)

  defp config(key, default),
    do: Keyword.get(SystemsRuntime.get_env(:salix_web, :station_tasks, []), key, default)

  defmodule Conversations do
    @moduledoc "The Task as `SalixWeb.StationTasks` reads and writes it."

    def append(group_id, conversation_id, agent_id, attrs),
      do:
        SalixIM.ConversationServer.append_group_conversation_agent_message(
          group_id,
          conversation_id,
          agent_id,
          attrs
        )

    def turn_ended(group_id, conversation_id, seq),
      do: SalixIM.ConversationServer.coding_turn_ended(group_id, conversation_id, seq)

    def record_coding_pending_review(group_id, conversation_id, seq),
      do: SalixIM.ConversationServer.record_coding_pending_review(group_id, conversation_id, seq)

    def deactivate_participant(group_id, conversation_id, participant_id),
      do:
        SalixIM.ConversationServer.deactivate_group_conversation_participant(
          group_id,
          conversation_id,
          participant_id
        )

    def deactivate_unbound_task_participant(
          group_id,
          conversation_id,
          participant_id,
          expected_stale_session \\ nil,
          verify_unbound_fun \\ nil
        ),
        do:
          SalixIM.ConversationServer.deactivate_unbound_task_participant(
            group_id,
            conversation_id,
            participant_id,
            expected_stale_session,
            verify_unbound_fun
          )

    def reserve_task_participant_session(group_id, conversation_id, participant_id, reserve_fun),
      do:
        SalixIM.ConversationServer.reserve_task_participant_session(
          group_id,
          conversation_id,
          participant_id,
          reserve_fun
        )

    def messages_after(group_id, conversation_id, after_seq, limit),
      do:
        SalixIM.Conversations.list_group_conversation_messages(group_id, conversation_id,
          after_seq: after_seq,
          limit: limit
        )

    def last(group_id, conversation_id) do
      case SalixIM.Conversations.list_group_conversation_message_page(group_id, conversation_id,
             limit: 1
           ) do
        {:ok, %{"messages" => [message]}} -> {:ok, message}
        {:ok, _none} -> {:error, :not_found}
        {:error, _} = error -> error
      end
    end

    def recent(group_id, conversation_id, limit) do
      with {:ok, %{"messages" => messages}} <-
             SalixIM.Conversations.list_group_conversation_message_page(
               group_id,
               conversation_id,
               limit: limit
             ),
           do: {:ok, messages}
    end

    def message(group_id, conversation_id, message_id),
      do:
        SalixIM.Conversations.get_group_conversation_message(
          group_id,
          conversation_id,
          message_id
        )

    def read_part(agent_id, ref, offset, length),
      do: SalixStore.Blob.read_range(agent_id, ref, offset, length)

    def blob_init(agent_id), do: SalixStore.Blob.put_stream_init(agent_id)
    def blob_step(state, chunk), do: SalixStore.Blob.put_stream_step(state, chunk)
    def blob_finish(state), do: SalixStore.Blob.put_stream_finish(state)
    def blob_abort(state), do: SalixStore.Blob.put_stream_abort(state)

    def place(agent_id, path, ref) do
      case SalixIM.Ports.AgentWorkspace.put_ref(agent_id, path, ref) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end

    def owner(group_id, conversation_id) do
      case SalixIM.Conversations.get_group_conversation(group_id, conversation_id) do
        {:ok, %{"owner_user_id" => owner}} when is_binary(owner) and owner != "" -> {:ok, owner}
        {:ok, _conversation} -> {:error, :no_owner}
        error -> error
      end
    end

    def task(group_id, conversation_id),
      do: SalixIM.Conversations.get_group_conversation(group_id, conversation_id)

    def status(group_id, conversation_id) do
      with {:ok, %{"status" => status}} <-
             SalixIM.Conversations.get_group_conversation(group_id, conversation_id),
           do: {:ok, status}
    end

    def participants(group_id, conversation_id) do
      case SalixIM.Conversations.list_group_conversation_participants(group_id, conversation_id) do
        {:ok, %{"participants" => participants}} -> {:ok, participants}
        {:ok, participants} when is_list(participants) -> {:ok, participants}
        error -> error
      end
    end
  end
end
