defmodule SalixMeet.RuntimeEvents do
  @moduledoc false

  require Logger

  alias SalixMeet.{Outcome, OwnerAttributionSnapshot}
  alias SalixMeet.Ports.AgentRuntime
  alias SalixMeet.Store
  alias SalixStore.Crypto

  @terminal_statuses ~w(done failed cancelled)
  @max_streamed_artifacts 2
  @max_streamed_artifact_bytes 30 * 1024 * 1024
  @max_streamed_event_bytes 32 * 1024 * 1024
  @terminal_source_errors ~w(artifact_count_limit artifact_event_size_limit unavailable)

  def terminal_statuses, do: @terminal_statuses

  def artifact_root(meeting_id), do: "/meetings/" <> meeting_id

  def prepare(meeting_agent, event, origin_env_id \\ nil)
      when is_map(meeting_agent) and is_map(event) do
    event = stringify(event)

    case event["type"] do
      "meeting_runtime_update" ->
        prepare_runtime_update(meeting_agent, event, origin_env_id, :fresh)

      "joiner_event" ->
        prepare_joiner_event(event)

      _ ->
        {:ok, empty_prepared(event)}
    end
  end

  @doc false
  def recover(meeting_agent, event) when is_map(meeting_agent) and is_map(event) do
    event = stringify(event)

    case event["type"] do
      "meeting_runtime_update" -> prepare_runtime_update(meeting_agent, event, nil, :replay)
      "joiner_event" -> prepare_joiner_event(event)
      _ -> {:ok, empty_prepared(event)}
    end
  end

  @doc false
  def apply(%{meeting_id: ""}, _source_id), do: :ok
  def apply(%{update: update}, _source_id) when update == %{}, do: :ok

  def apply(%{meeting_id: meeting_id, update: update} = prepared, source_id)
      when is_binary(meeting_id) and is_binary(source_id) and source_id != "" do
    with {:ok, doc, _etag} <-
           Store.update_state_retrying(
             meeting_id,
             &merge_runtime_state(&1, update, source_id, meeting_id)
           ),
         :ok <-
           maybe_notify_joiner_status(
             meeting_id,
             doc["state"] || %{},
             prepared[:notify_event]
           ) do
      :ok
    end
  end

  @doc false
  def cleanup_prepared(%{vfs_events: events}), do: rollback_prepared_artifacts(events)
  def cleanup_prepared(_prepared), do: :ok

  defp prepare_runtime_update(meeting_agent, event, origin_env_id, mode) do
    meeting_id = trim(event["meeting_id"])

    if meeting_id == "" do
      {:ok, empty_prepared(event)}
    else
      with {:ok, current, _} <- Store.get(meeting_id),
           state = current["state"] || %{},
           root = trim(state["artifact_root"]) |> blank_default(artifact_root(meeting_id)),
           {:ok, artifacts, vfs_events} <-
             runtime_artifacts(
               mode,
               meeting_agent,
               root,
               event["artifacts"],
               origin_env_id,
               meeting_id
             ) do
        update = runtime_state_update(event, artifacts, root)

        {:ok,
         %{
           event: event,
           vfs_events: vfs_events,
           meeting_id: meeting_id,
           update: update,
           notify_event: nil
         }}
      end
    end
  end

  defp prepare_joiner_event(%{"meeting_id" => ""} = event),
    do: {:ok, empty_prepared(event)}

  defp prepare_joiner_event(event) do
    meeting_id = trim(event["meeting_id"])
    joiner = stringify(event["joiner_event"] || event)

    update =
      case joiner["type"] do
        "status" ->
          joiner_status_update(joiner)

        "caption" ->
          %{"captions" => [caption_record(joiner)]}

        "chat_message" ->
          %{"chats" => [chat_record(joiner, "incoming")]}

        "chat_sent" ->
          %{"chats" => [chat_record(joiner, "outgoing")]}

        # An admitted-removal observation does not authorize result delivery.
        # The final runtime update settles the result; see meeting-admission-outcomes.md.
        "meeting_ended" ->
          %{"status" => "processing", "left_at" => parse_timestamp(joiner["timestamp"])}
          |> with_reason(joiner)

        _ ->
          %{}
      end

    if meeting_id == "" or update == %{} do
      {:ok, empty_prepared(event)}
    else
      {:ok,
       %{
         event: event,
         vfs_events: [],
         meeting_id: meeting_id,
         update: update,
         notify_event: joiner
       }}
    end
  end

  defp empty_prepared(event) do
    %{event: event, vfs_events: [], meeting_id: "", update: %{}, notify_event: nil}
  end

  defp maybe_notify_joiner_status(_meeting_id, _state, nil), do: :ok

  defp maybe_notify_joiner_status(meeting_id, state, event),
    do: notify_joiner_status(meeting_id, state, event)

  defp notify_joiner_status(meeting_id, state, event) do
    case if(notify_current_status?(state, event), do: joiner_status_notification_key(event)) do
      nil ->
        :ok

      key ->
        if get_in(state, ["joiner_status_notifications", key]) == "queued" do
          :ok
        else
          with :ok <- enqueue_joiner_status(meeting_id, state, event),
               {:ok, _doc, _etag} <-
                 Store.update_state_retrying(
                   meeting_id,
                   &checkpoint_joiner_status_notification(&1, key)
                 ) do
            :ok
          end
        end
    end
  end

  defp enqueue_joiner_status(meeting_id, state, event) do
    case SalixMeet.Ports.MeetingStatusNotifier.notify(meeting_id, state, event) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "meeting status notification failed meeting=#{meeting_id}: #{inspect(reason)}"
        )

        {:error, {:meeting_status_notification_failed, reason}}
    end
  rescue
    exception ->
      Logger.warning(
        "meeting status notification failed meeting=#{meeting_id}: #{Exception.message(exception)}"
      )

      {:error, {:meeting_status_notification_failed, {:exception, Exception.message(exception)}}}
  catch
    kind, reason ->
      Logger.warning(
        "meeting status notification failed meeting=#{meeting_id}: #{inspect({kind, reason})}"
      )

      {:error, {:meeting_status_notification_failed, {kind, reason}}}
  end

  # Once admission has explicitly ended, only matching error/leave notices apply.
  defp notify_current_status?(state, event) do
    not Outcome.no_retry?(state["reason_code"]) or
      event["status"] == "left" or
      (event["status"] == "error" and event["reason_code"] == state["reason_code"])
  end

  defp with_reason(%{"status" => status} = update, event)
       when status in ~w(failed processing done cancelled) do
    case Outcome.normalize(event["reason_code"]) do
      nil -> update
      code -> Map.put(update, "reason_code", code)
    end
  end

  defp with_reason(update, _event), do: update

  defp joiner_status_notification_key(%{"type" => "status", "status" => status})
       when status in ~w(waiting_room in_meeting left error),
       do: status

  defp joiner_status_notification_key(_event), do: nil

  defp checkpoint_joiner_status_notification(state, key) do
    notifications = stringify(state["joiner_status_notifications"] || %{})
    Map.put(state, "joiner_status_notifications", Map.put(notifications, key, "queued"))
  end

  defp joiner_status_update(event) do
    case trim(event["status"]) do
      "waiting_room" -> %{"join_requested_at" => now()}
      "in_meeting" -> %{"status" => "active", "joined_at" => parse_timestamp(event["timestamp"])}
      "left" -> %{"status" => "processing", "left_at" => parse_timestamp(event["timestamp"])}
      "error" -> %{"status" => "failed", "error" => trim(event["message"])}
      _ -> %{}
    end
    |> with_reason(event)
  end

  defp runtime_state_update(event, artifacts, root) do
    %{
      "status" => present(event["status"]),
      "error" => present(event["error"]),
      "summary" => sanitized_summary_or_nil(event["summary"]),
      "summary_status" => present(event["summary_status"]),
      "summary_error" => present(event["summary_error"]),
      "transcript_source" => present(event["transcript_source"]),
      "artifact_root" => root,
      "artifacts" => if(map_size(artifacts) > 0, do: artifacts, else: nil),
      "captions" => list_or_nil(event["captions"]),
      "chats" => list_or_nil(event["chats"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
    |> with_reason(event)
  end

  defp merge_runtime_state(state, update, source_id, meeting_id) do
    state = stringify(state || %{})
    event_key = Crypto.hex(source_id)
    {state, update} = demote_join_failure(state, stringify(update))
    {state, update} = apply_terminal_valve(state, update, event_key, meeting_id)
    # Removal is observed before result processing finishes. Late admission
    # cannot reopen recording or erase that reason while artifacts are settling.
    update =
      if Outcome.no_retry?(state["reason_code"]) do
        update = Map.delete(update, "reason_code")
        if update["status"] == "active", do: Map.drop(update, ~w(status joined_at)), else: update
      else
        update
      end

    # A successful retry retires the previous attempt's timeout reason.
    state = if update["status"] == "active", do: Map.delete(state, "reason_code"), else: state

    state
    |> merge_simple(
      update,
      ~w(status error reason_code summary summary_status summary_error transcript_source artifact_root joined_at left_at)
    )
    |> merge_artifacts(update["artifacts"])
    |> append_list("captions", update["captions"], event_key)
    |> append_list("chats", update["chats"], event_key)
  end

  # A runtime "failed" that arrives before the bot ever joined is a failed join
  # *attempt*, not a failed meeting: the token factory crashed, the lobby timed
  # out, the runtime died. The dispatch record takes the failure so the join
  # retry (`Store.join_retry_candidate?/2`, gated by the runtime liveness read)
  # can try again while the meeting is still running. The meeting itself goes
  # terminal only when the attempt budget is exhausted or the meeting is over —
  # the same two conditions `JoinDispatch` already applies to dispatch-time
  # failures — so a late join still produces a recorded meeting instead of a
  # "record incomplete" notice on the first hiccup.
  #
  # Two boundaries of this rule:
  #
  # * It applies only to calendar-autojoin-owned meetings. They are the only
  #   ones with a durable retry owner (the autojoin sweep); a manual Slack
  #   meeting demoted here would sit in `joining` with nobody to re-drive it,
  #   and the provider would keep answering `already_active`. Manual meetings
  #   therefore keep the terminal-on-failure behaviour.
  # * It is idempotent across the runtime's two failure faces. meet-native
  #   posts a joiner `status=error` first and the `meeting_runtime_update
  #   status=failed` terminal after it; the second must not undo the first.
  #   An attempt that is already `failed` (or is being re-claimed as
  #   `dispatching`) stays a non-terminal attempt; only the dispatch record
  #   of a `dispatched` attempt is rewritten.
  defp demote_join_failure(state, %{"status" => "failed"} = update) do
    dispatch = stringify(state["join_dispatch"] || %{})

    demotable? =
      not Outcome.no_retry?(update["reason_code"]) and
        not Outcome.no_retry?(state["reason_code"]) and
        calendar_owned?(state) and is_nil(state["joined_at"]) and
        dispatch["status"] in ["dispatched", "failed", "dispatching"] and
        join_window_open?(state) and
        Store.join_attempts(dispatch) < Store.join_max_attempts()

    cond do
      not demotable? ->
        {state, update}

      dispatch["status"] == "dispatched" ->
        failed =
          Map.merge(dispatch, %{
            "status" => "failed",
            "last_error" => update["error"] || state["error"] || "runtime failure before join",
            "completed_at" => now()
          })

        {Map.put(state, "join_dispatch", failed), Map.drop(update, ["status"])}

      true ->
        # Already recorded as a failed attempt (or owned by an in-flight
        # re-claim under its generation fence): keep the meeting non-terminal
        # and leave the dispatch record to its owner.
        {state, Map.drop(update, ["status"])}
    end
  end

  defp demote_join_failure(state, update), do: {state, update}

  # Manual Slack meetings carry a bare string here ("message"/"thread");
  # calendar-autojoin meetings carry the structured source map.
  defp calendar_owned?(%{"source" => %{"kind" => "calendar"}}), do: true
  defp calendar_owned?(_state), do: false

  defp join_window_open?(state) do
    case state["end_at"] do
      end_at when is_integer(end_at) -> System.system_time(:second) < end_at
      _ -> false
    end
  end

  # Terminal one-way valve: done/failed/cancelled is final for status, reason,
  # summary and admission evidence. Late callbacks cannot rewrite these fields;
  # rejected values are preserved under `late_runtime_status` for operator
  # recovery instead of being merged. Everything else in the update (error,
  # artifacts, captions, chats, leave timestamps) still merges through the normal,
  # already idempotent paths.
  defp apply_terminal_valve(state, update, event_key, meeting_id) do
    if state["status"] in @terminal_statuses do
      rejected =
        update
        |> Map.take(~w(status summary))
        |> Enum.reject(fn {key, value} -> value == state[key] end)
        |> Map.new()

      state =
        if map_size(rejected) > 0 do
          Logger.warning(
            "meeting terminal valve rejected late runtime write meeting=#{meeting_id} " <>
              "terminal_status=#{state["status"]} late_status=#{rejected["status"] || "-"} " <>
              "late_summary=#{is_map(rejected["summary"])}"
          )

          Salix.Telemetry.emit_operation(
            "salix_meet",
            "meeting_runtime_late_event",
            "system",
            "rejected",
            0
          )

          Map.put(state, "late_runtime_status", late_runtime_record(rejected, event_key))
        else
          state
        end

      {state, Map.drop(update, ~w(status summary reason_code joined_at))}
    else
      {state, update}
    end
  end

  defp late_runtime_record(rejected, event_key) do
    %{
      "status" => rejected["status"],
      "summary" => rejected["summary"],
      "received_at" => now(),
      "runtime_event_id" => event_key
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp merge_simple(state, update, keys) do
    Enum.reduce(keys, state, fn key, acc ->
      case Map.fetch(update, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp merge_artifacts(state, nil), do: state

  defp merge_artifacts(state, artifacts) do
    Map.update(state, "artifacts", artifacts, &Map.merge(&1 || %{}, artifacts))
  end

  defp append_list(state, _key, nil, _event_key), do: state

  defp append_list(state, key, values, event_key) when is_list(values) do
    existing = Enum.map(List.wrap(state[key]), &stringify/1)

    existing_refs =
      existing
      |> Enum.map(&{&1["runtime_event_id"], &1["runtime_event_index"]})
      |> MapSet.new()

    additions =
      values
      |> Enum.map(&stringify/1)
      |> Enum.with_index()
      |> Enum.reject(fn {_value, index} ->
        MapSet.member?(existing_refs, {event_key, index})
      end)
      |> Enum.map(fn {value, index} ->
        value
        |> Map.put("runtime_event_id", event_key)
        |> Map.put("runtime_event_index", index)
      end)

    Map.put(state, key, existing ++ additions)
  end

  defp runtime_artifacts(:fresh, meeting_agent, root, artifacts, origin_env_id, meeting_id),
    do: prepare_artifacts(meeting_agent, root, artifacts, origin_env_id, meeting_id)

  defp runtime_artifacts(:replay, meeting_agent, root, artifacts, _origin_env_id, meeting_id),
    do: recover_artifacts(meeting_agent, root, artifacts, meeting_id)

  defp recover_artifacts(meeting_agent, root, artifacts, meeting_id) do
    with {:ok, plans} <- admit_artifact_batch(root, artifacts, meeting_id) do
      plans
      |> Enum.reduce_while({:ok, %{}}, fn plan, {:ok, acc} ->
        case AgentRuntime.stat_workspace(meeting_agent["meeting_agent_id"], plan.path) do
          {:ok, _entry} ->
            {:cont,
             {:ok,
              Map.merge(
                acc,
                artifact_meta(plan.kind, plan.path, plan.filename, plan.artifact)
              )}}

          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {:artifact_recovery_failed, plan.path, reason}}}
        end
      end)
      |> case do
        {:ok, recovered} -> {:ok, recovered, []}
        {:error, _} = error -> error
      end
    end
  end

  defp prepare_artifacts(meeting_agent, root, artifacts, origin_env_id, meeting_id) do
    case admit_artifact_batch(root, artifacts, meeting_id) do
      {:ok, plans} ->
        Enum.reduce_while(plans, {:ok, %{}, []}, fn plan, {:ok, acc, events} ->
          case safe_write_artifact(meeting_agent, plan, origin_env_id, meeting_id) do
            {:ok, nil} ->
              {:cont, {:ok, acc, events}}

            {:ok, event, meta} ->
              {:cont, {:ok, Map.merge(acc, meta), events ++ [event]}}

            {:error, reason} ->
              if streamed_artifact?(plan.artifact) do
                case rollback_prepared_artifacts(events) do
                  :ok ->
                    {:halt, {:error, {:artifact_ingest_failed, plan.kind, reason}}}

                  {:error, rollback_reason} ->
                    {:halt,
                     {:error,
                      {:artifact_ingest_rollback_failed, plan.kind, reason, rollback_reason}}}
                end
              else
                Logger.warning(
                  "meeting inline artifact dropped (agent=#{meeting_agent["meeting_agent_id"]} " <>
                    "kind=#{plan.kind}): #{inspect(reason)}"
                )

                {:cont, {:ok, acc, events}}
              end
          end
        end)

      {:error, _reason} = error ->
        Salix.Telemetry.emit_operation(
          "salix_meet",
          "meeting_artifact",
          "system",
          "rejected",
          0
        )

        error
    end
  end

  defp rollback_prepared_artifacts(events) do
    failures =
      events
      |> Enum.reverse()
      |> Enum.reduce([], fn event, failures ->
        case AgentRuntime.discard_prepared_workspace_write(event) do
          :ok -> failures
          {:error, reason} -> [reason | failures]
        end
      end)

    case failures do
      [] -> :ok
      reasons -> {:error, {:prepared_artifact_cleanup_failed, Enum.reverse(reasons)}}
    end
  end

  defp validate_streamed_artifact_bounds(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, 0, 0}, fn
      artifact, {:ok, count, total} when is_map(artifact) ->
        artifact = stringify(artifact)

        if trim(artifact["source_ref"]) == "" do
          {:cont, {:ok, count, total}}
        else
          size = artifact["source_size"]

          cond do
            count >= @max_streamed_artifacts ->
              {:halt, {:error, :artifact_count_limit}}

            not is_integer(size) or size < 0 or size > @max_streamed_artifact_bytes ->
              {:halt, {:error, :artifact_size_limit}}

            total + size > @max_streamed_event_bytes ->
              {:halt, {:error, :artifact_event_size_limit}}

            true ->
              {:cont, {:ok, count + 1, total + size}}
          end
        end

      _malformed, _acc ->
        {:halt, {:error, :artifact_envelope_invalid}}
    end)
    |> case do
      {:ok, _count, _total} -> :ok
      {:error, _} = error -> error
    end
  end

  defp streamed_artifact?(artifact),
    do: trim(artifact["source_ref"]) != "" or trim(artifact["src_path"]) != ""

  defp admit_artifact_batch(root, artifacts, meeting_id) do
    artifacts = List.wrap(artifacts)
    expected_root = artifact_root(meeting_id)

    with {:ok, material_artifacts} <- normalize_artifact_entries(artifacts),
         :ok <- validate_streamed_artifact_bounds(material_artifacts),
         :ok <- validate_artifact_root(root, expected_root) do
      material_artifacts
      |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, fn artifact,
                                                                     {:ok, plans, paths, kinds} ->
        artifact = stringify(artifact)
        kind = trim(artifact["kind"])
        filename = artifact_filename(kind, artifact["filename"])

        with :ok <- validate_artifact_filename(filename),
             path = Path.join(expected_root, filename),
             :ok <- validate_artifact_path(path, expected_root),
             false <- MapSet.member?(paths, path),
             false <- MapSet.member?(kinds, kind) do
          plan = %{artifact: artifact, kind: kind, filename: filename, path: path}

          {:cont, {:ok, [plan | plans], MapSet.put(paths, path), MapSet.put(kinds, kind)}}
        else
          true -> {:halt, {:error, :artifact_batch_conflict}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, plans, _paths, _kinds} -> {:ok, Enum.reverse(plans)}
        {:error, _} = error -> error
      end
    end
  end

  # Connector-declared source failures are terminal metadata, not VFS
  # material. Accept only the exact fail-closed shape the Connector produces;
  # a source_error may never be used to bypass admission for a live payload.
  defp normalize_artifact_entries(artifacts) do
    artifacts
    |> Enum.reduce_while({:ok, []}, fn
      artifact, {:ok, material} when is_map(artifact) ->
        artifact = stringify(artifact)

        case terminal_artifact_state(artifact) do
          :material -> {:cont, {:ok, [artifact | material]}}
          :terminal_skipped -> {:cont, {:ok, material}}
          {:error, _} = error -> {:halt, error}
        end

      _malformed, _acc ->
        {:halt, {:error, :artifact_envelope_invalid}}
    end)
    |> case do
      {:ok, material} -> {:ok, Enum.reverse(material)}
      {:error, _} = error -> error
    end
  end

  defp terminal_artifact_state(artifact) do
    source_error = trim(artifact["source_error"])

    cond do
      source_error == "" ->
        :material

      source_error not in @terminal_source_errors ->
        {:error, :artifact_source_error_invalid}

      artifact_payload_source?(artifact) ->
        {:error, :artifact_source_error_invalid}

      true ->
        :terminal_skipped
    end
  end

  defp artifact_payload_source?(artifact) do
    trim(artifact["source_ref"]) != "" or
      trim(artifact["src_path"]) != "" or
      Map.has_key?(artifact, "data") or
      Map.has_key?(artifact, "data_b64")
  end

  defp validate_artifact_root(root, root), do: :ok
  defp validate_artifact_root(_root, _expected_root), do: {:error, :artifact_root_invalid}

  defp validate_artifact_filename(filename) when is_binary(filename) do
    if filename != "" and filename not in [".", ".."] and
         not String.contains?(filename, ["/", "\\"]) do
      :ok
    else
      {:error, :artifact_path_invalid}
    end
  end

  defp validate_artifact_filename(_filename), do: {:error, :artifact_path_invalid}

  defp validate_artifact_path(path, root) do
    if Path.dirname(path) == root and Path.expand(path) == path do
      :ok
    else
      {:error, :artifact_path_invalid}
    end
  end

  defp safe_write_artifact(meeting_agent, plan, origin_env_id, meeting_id) do
    write_artifact(meeting_agent, plan, origin_env_id, meeting_id)
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp write_artifact(meeting_agent, plan, origin_env_id, meeting_id) do
    %{artifact: artifact, kind: kind, filename: filename, path: path} = plan
    agent_id = meeting_agent["meeting_agent_id"]
    meta = artifact_meta(kind, path, filename, artifact)

    source_ref = trim(artifact["source_ref"])
    source_size = artifact["source_size"]
    src_path = trim(artifact["src_path"])

    cond do
      source_ref != "" ->
        case trim(origin_env_id) do
          "" ->
            {:error, :no_origin_env}

          env_id ->
            agent_id
            |> AgentRuntime.stream_meeting_artifact_write(
              env_id,
              path,
              meeting_id,
              source_ref,
              source_size
            )
            |> with_meta(meta)
        end

      src_path == "" ->
        case decode_artifact(artifact) do
          {:ok, nil} ->
            {:ok, nil}

          {:ok, data} ->
            with_meta(AgentRuntime.prepare_workspace_write(agent_id, path, data), meta)

          {:error, _} = err ->
            err
        end

      true ->
        case trim(origin_env_id) do
          "" ->
            {:error, :no_origin_env}

          env_id ->
            agent_id
            |> AgentRuntime.stream_workspace_write(env_id, path, src_path)
            |> with_meta(meta)
        end
    end
  end

  defp with_meta({:ok, event}, meta), do: {:ok, event, meta}
  defp with_meta({:error, _} = err, _meta), do: err

  defp artifact_meta(kind, path, filename, artifact) do
    %{
      kind => %{
        "path" => path,
        "filename" => filename,
        "content_type" => blank_default(trim(artifact["content_type"]), content_type(kind))
      }
    }
  end

  defp decode_artifact(%{"data_b64" => data}) when is_binary(data) and data != "" do
    case Base.decode64(data) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_artifact_data}
    end
  end

  defp decode_artifact(%{"data" => data}) when is_binary(data), do: {:ok, data}
  defp decode_artifact(_artifact), do: {:ok, nil}

  defp artifact_filename("transcript", filename) do
    case trim(filename) do
      "" -> "transcript.txt"
      "transcript" -> "transcript.txt"
      name -> name
    end
  end

  defp artifact_filename("audio", filename) do
    case trim(filename) do
      "" -> "audio.mp3"
      "audio" -> "audio.mp3"
      name -> name
    end
  end

  defp artifact_filename("summary", _filename), do: "summary.json"
  defp artifact_filename(kind, filename), do: blank_default(trim(filename), kind <> ".bin")

  defp content_type("transcript"), do: "text/plain; charset=utf-8"
  defp content_type("audio"), do: "audio/mpeg"
  defp content_type("summary"), do: "application/json"
  defp content_type(_kind), do: "application/octet-stream"

  defp caption_record(event) do
    %{
      "speaker" => blank_default(trim(event["speaker"]), "Unknown"),
      "text" => trim(event["text"]),
      "timestamp" => parse_timestamp(event["timestamp"]),
      "source" => blank_default(trim(event["source"]), "live_caption")
    }
  end

  defp chat_record(event, direction) do
    %{
      "direction" => direction,
      "sender" => trim(event["sender"]),
      "text" => trim(event["text"]),
      "timestamp" => parse_timestamp(event["timestamp"]),
      "message_id" => trim(event["message_id"]),
      "delivery_state" => trim(event["delivery_state"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp parse_timestamp(value) when is_integer(value), do: value

  defp parse_timestamp(value) do
    value = trim(value)

    cond do
      value == "" ->
        now()

      match?({_, ""}, Integer.parse(value)) ->
        {int, ""} = Integer.parse(value)
        int

      true ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _} -> DateTime.to_unix(dt)
          _ -> now()
        end
    end
  end

  defp now, do: System.system_time(:second)

  defp sanitized_summary_or_nil(value) when is_map(value),
    do: OwnerAttributionSnapshot.sanitize_summary(value)

  defp sanitized_summary_or_nil(_value), do: nil

  defp list_or_nil(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp list_or_nil(_value), do: nil

  defp present(value) do
    case trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
