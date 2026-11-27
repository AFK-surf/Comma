defmodule SalixIM.Triage.Investigation do
  @moduledoc """
  Product-owned initial investigation in a canonical Task.

  A protected grant selects an immutable Triage delegation. Public completion
  is a Task Message addressed only to its result participant. The Conversation
  log preserves the accepted result across process loss.
  """

  alias SalixIM.{ConversationServer, Conversations, GroupDirectory, ProviderConnects}
  alias SalixIM.Ports.TriageDelegation
  alias SalixIM.Provider.Util

  alias SalixIM.Triage.{
    ClickHouseReader,
    ProductDecision,
    ProductObligation,
    SlackEffectAdapter,
    StillfailCoordination
  }

  alias SalixStore.{StationTaskIndex, TriageProductRuntime}

  @grant "triage_investigation"
  @result "triage_investigation_result"
  @snapshot "triage_investigation_source"
  @retry "triage_investigation_retry"
  @state "triage_investigation_state"
  @sink_role "triage_result"
  @channel_context_before_limit 10
  @channel_context_after_limit 5
  @channel_context_text_max_bytes 300
  @stillfail_coordination_limit 200
  @status_or_help_re ~r/(?:\b(?:status|update|progress|blocked|stuck|landed|merged)\b|land yet|进展|进度|卡住|合了吗|合并了吗|修好了吗|好了没|怎么样了)/iu

  def grant_key, do: @grant
  def result_key, do: @result
  def snapshot_key, do: @snapshot
  def retry_key, do: @retry
  def state_key, do: @state

  def task?(conversation), do: is_map(get_in(conversation, ["source_refs", @grant]))

  def sink?(participant),
    do: participant["actor_type"] == "provider" and participant["role_label"] == @sink_role

  def creation(group_id, router_id, worker_id, attrs) do
    case get_in(attrs, ["source_refs", @grant]) do
      nil ->
        {:ok, nil}

      grant ->
        with {:ok, original} <- original(grant),
             true <- grant["worker_agent_id"] == worker_id,
             true <-
               get_in(original.payload, ["product_identity", "project_salix_group_id"]) ==
                 group_id,
             true <- attrs["client_request_id"] == request_id(original),
             true <- plain_schedule?(attrs["schedule"]),
             true <- original.delegation["worker_ref"] == "comma-agent://" <> worker_id,
             :ok <- TriageDelegation.authorize_target(original, router_id, worker_id) do
          {:ok, original}
        else
          {:error, reason} when reason in [:unavailable, :timeout] -> {:error, reason}
          {:error, reason, true} -> {:error, reason}
          _ -> denied()
        end
    end
  end

  defp plain_schedule?(nil), do: true
  defp plain_schedule?(%{"schedule_id" => nil}), do: true
  defp plain_schedule?(_), do: false

  def result_participants(nil, _now), do: []

  def result_participants(original, now) do
    [
      %{
        "actor_type" => "provider",
        "provider" => "slack",
        "role_label" => @sink_role,
        "target_key" => request_id(original),
        "state" => "active",
        "notification_filter" => %{"messages" => "mentioned", "statuses" => "none"},
        "payload" => Map.take(original.payload["target"], ~w(connect_id channel_id thread_ts)),
        "created_at" => now,
        "updated_at" => now
      }
    ]
  end

  def original(grant) when is_map(grant) do
    TriageProductRuntime.fetch_delegation(
      grant["namespace_key"],
      grant["obligation_id"],
      grant["index"]
    )
  end

  def original(_), do: denied()

  def authorize(group_id, agent_id, conversation_id) do
    with {:ok, conversation} <- Conversations.get_group_conversation(group_id, conversation_id),
         %{} = grant <- get_in(conversation, ["source_refs", @grant]),
         true <-
           grant["worker_agent_id"] == agent_id and
             conversation["task_worker_agent_id"] == agent_id,
         {:ok, original} <- original(grant),
         {:ok, %{"conversation_id" => ^conversation_id}} <-
           ConversationServer.lookup_task_create_request(group_id, request_id(original)),
         router_id <- get_in(original.payload, ["product_identity", "salix_agent_id"]),
         :ok <- TriageDelegation.authorize_target(original, router_id, agent_id) do
      {:ok, conversation, original}
    else
      {:error, reason} when reason in [:unavailable, :timeout] -> {:error, reason}
      {:error, reason, true} -> {:error, reason}
      _ -> denied()
    end
  end

  def context(scope) do
    ctx = SalixIM.Provider.current_tool_context()
    origin = ctx["trusted_origin"] || %{}
    grant = origin["triage_investigation"] || List.first(List.wrap(ctx["triage_scopes"]))

    with true <- is_map(grant),
         true <- grant["agent_id"] == scope.agent_id and grant["session_id"] == ctx["session_id"] do
      SalixIM.Triage.InvestigationAuthority.validate(scope.group_id, grant)
    else
      _ -> denied()
    end
  end

  def read_memory(scope, params) do
    with {:ok, _conversation, original} <- context(scope),
         true <- Enum.all?(Map.keys(params), &(&1 in ~w(path start_line num_lines))),
         true <- is_binary(params["path"]) and String.trim(params["path"]) != "",
         true <-
           Enum.all?(~w(start_line num_lines), fn key ->
             not Map.has_key?(params, key) or is_integer(params[key])
           end) do
      router_id = get_in(original.payload, ["product_identity", "salix_agent_id"])
      SalixAgent.Tools.Memory.read_workspace_file(router_id, params)
    else
      false -> {:error, :invalid_memory_read}
      error -> error
    end
  end

  def read_context(scope) do
    with {:ok, _conversation, original} <- context(scope),
         {:ok, group_atom} <- SalixIFC.Codec.encode_atom({:group, scope.group_id}) do
      {:ok,
       %{
         "entries" => original.payload["context_sources"] || [],
         "__ifc__" => %{"label" => [group_atom]}
       }}
    end
  end

  def read_source(scope) do
    with {:ok, conversation, original} <- context(scope),
         {:ok, group} <- GroupDirectory.get_group(scope.group_id),
         target <- original.payload["target"],
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             scope.group_id,
             target["connect_id"],
             "slack"
           ),
         channel_scope <- %{
           "tenant_id" => group["tenant_id"],
           "workspace_id" => target["workspace_id"],
           "channel_id" => target["channel_id"]
         },
         {:ok, page} <-
           ClickHouseReader.impl().read_thread(
             channel_scope,
             target["thread_ts"],
             limit: 200,
             max_bytes: 1_048_576
           ),
         true <- page.complete? == true and valid_source_messages?(page.messages),
         messages <- Enum.map(page.messages, &classify_source_actor(&1, connect)),
         snapshot <- source_snapshot(original.payload, messages),
         {:ok, %{status: :fresh}} <- SlackEffectAdapter.Freshness.check(%{payload: snapshot}, []),
         {:ok, result} <-
           ConversationServer.record_triage_source(
             scope.group_id,
             conversation["conversation_id"],
             scope.agent_id,
             snapshot
           ) do
      response = %{
        "source_snapshot" => result["message_id"],
        "messages" => source_messages(original.payload, messages),
        "expression_context" => original.payload["expression_context"],
        "__ifc__" => SalixIM.IFC.ReadLabels.for_scope(connect, target["channel_id"])
      }

      response =
        case read_channel_context(channel_scope, target["thread_ts"], connect) do
          nil -> response
          channel_context -> Map.put(response, "channel_context", channel_context)
        end

      response =
        case read_stillfail_coordination(scope.group_id, target, messages, connect) do
          nil -> response
          coordination -> Map.put(response, "stillfail_coordination", coordination)
        end

      {:ok, response}
    else
      false -> {:error, :triage_source_incomplete}
      {:ok, %{status: :stale}} -> {:error, :triage_source_stale}
      error -> error
    end
  end

  defp read_stillfail_coordination(group_id, target, messages, connect) do
    case StationTaskIndex.page_group(group_id,
           source: "stillfail",
           limit: @stillfail_coordination_limit
         ) do
      {[], _more?} ->
        nil

      {rows, _more?} when is_list(rows) ->
        source_texts = Enum.map(messages, & &1["text"])
        asks? = asks_status_or_help?(messages, connect)
        result = StillfailCoordination.evaluate(rows, target, source_texts, asks?)

        if result.disposition == :no_overlap do
          nil
        else
          %{"disposition" => Atom.to_string(result.disposition)}
          |> Util.put_present("card_kind", result.card_kind)
          |> put_positive_int("recommended_recheck_hours", result.recommended_recheck_hours)
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp asks_status_or_help?(messages, connect) do
    bot_mention =
      case connect["bot_user_id"] do
        id when is_binary(id) and id != "" -> "<@#{id}>"
        _ -> nil
      end

    Enum.any?(messages, fn msg ->
      msg["actor_kind"] == "human" and is_binary(msg["text"]) and
        ((is_binary(bot_mention) and String.contains?(msg["text"], bot_mention)) or
           Regex.match?(@status_or_help_re, msg["text"]))
    end)
  end

  defp put_positive_int(map, key, value) when is_integer(value) and value > 0,
    do: Map.put(map, key, value)

  defp put_positive_int(map, _key, _value), do: map

  defp read_channel_context(channel_scope, thread_ts, connect) do
    reader = ClickHouseReader.impl()

    if is_atom(reader) and function_exported?(reader, :history, 2) do
      before_msgs =
        read_channel_window(
          reader,
          channel_scope,
          thread_ts,
          connect,
          latest: thread_ts,
          inclusive: false,
          limit: @channel_context_before_limit
        )

      after_msgs =
        read_channel_window(
          reader,
          channel_scope,
          thread_ts,
          connect,
          oldest: thread_ts,
          inclusive: false,
          limit: @channel_context_after_limit
        )

      if before_msgs != [] or after_msgs != [] do
        %{"before" => before_msgs, "after" => after_msgs}
      else
        nil
      end
    else
      nil
    end
  end

  defp read_channel_window(reader, channel_scope, thread_ts, connect, opts) do
    case reader.history(channel_scope, opts) do
      {:ok, %{messages: messages}} when is_list(messages) ->
        messages
        |> Enum.filter(fn msg ->
          is_map(msg) and (msg["ts"] || msg["message_ts"]) != thread_ts
        end)
        |> Enum.reverse()
        |> Enum.map(&project_channel_context_message(&1, connect))

      _ ->
        []
    end
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  defp project_channel_context_message(msg, connect) do
    text =
      if is_binary(msg["text"]),
        do: Util.truncate_utf8(msg["text"], @channel_context_text_max_bytes),
        else: ""

    %{
      "actor_kind" => channel_context_actor_kind(msg, connect),
      "text" => text
    }
    |> Util.put_present("ts", msg["ts"] || msg["message_ts"])
    |> Util.put_present("thread_ts", msg["thread_ts"])
    |> Util.put_present("user", msg["user"])
    |> Util.put_present("bot_id", msg["bot_id"])
    |> Util.put_present("subtype", msg["subtype"])
    |> put_positive_reply_count(msg["reply_count"])
  end

  defp channel_context_actor_kind(msg, connect) do
    raw = %{
      "user" => msg["user"] || if(msg["actor_kind"] == "user", do: msg["actor_id"]),
      "bot_id" => msg["bot_id"] || if(msg["actor_kind"] == "bot", do: msg["actor_id"]),
      "is_bot" => msg["is_bot"] == true or msg["actor_kind"] in ["bot", "app"],
      "bot_profile_name" => msg["bot_profile_name"],
      "bot_profile" => msg["bot_profile"],
      "subtype" => msg["subtype"]
    }

    SalixIM.Triage.IdentityContract.actor_kind(raw, connect)
  end

  defp put_positive_reply_count(map, count) when is_integer(count) and count > 0,
    do: Map.put(map, "reply_count", count)

  defp put_positive_reply_count(map, _count), do: map

  defp classify_source_actor(row, connect) do
    # The mirror stores provider kinds (user/bot/app), not Triage's classified
    # human/agent identity. Classify provider fields under this installation;
    # never turn an arbitrary declared actor_kind into a personal owner.
    raw = %{
      "user" => if(row["actor_kind"] == "user", do: row["actor_id"]),
      "bot_id" => if(row["actor_kind"] == "bot", do: row["actor_id"]),
      "is_bot" => row["actor_kind"] in ["bot", "app"],
      "subtype" => row["subtype"]
    }

    Map.put(row, "actor_kind", SalixIM.Triage.IdentityContract.actor_kind(raw, connect))
  end

  defp valid_source_messages?(messages)
       when is_list(messages) and messages != [] and length(messages) <= 200 do
    Enum.all?(messages, fn row ->
      is_map(row) and is_integer(row["version"]) and is_integer(row["message_ts_us"]) and
        is_binary(row["message_ts"])
    end)
  end

  defp valid_source_messages?(_), do: false

  defp source_messages(payload, messages) do
    target = payload["target"]

    Enum.map(messages, fn row ->
      Map.put(
        row,
        "source_ref",
        "slack://#{target["workspace_id"]}/#{target["channel_id"]}/#{target["thread_ts"]}/#{row["message_ts"]}"
      )
    end)
  end

  defp valid_completion_source?(
         %{"communication" => %{"kind" => "reaction", "emoji" => emoji}} = payload
       ),
       do:
         match?({:ok, _}, SlackEffectAdapter.reaction_target(payload)) and
           SlackEffectAdapter.validate_reaction_authority(payload, emoji) == :ok

  defp valid_completion_source?(_), do: true

  defp source_snapshot(payload, messages) do
    timestamps = Enum.map(messages, & &1["message_ts"]) |> Enum.uniq()

    versions =
      Enum.map(messages, fn message ->
        %{
          "message_ts" => message["message_ts"],
          "message_ts_us" => message["message_ts_us"],
          "observed_version" => message["version"]
        }
      end)

    payload
    |> Map.drop(~w(source_window reaction_authority ordinary_worker_assignment))
    |> Map.put("target_cutoff", %{"event_message_timestamps" => timestamps})
    |> Map.put("source_authority", versions)
    |> Map.put("source_messages", messages)
    |> Map.put("context_candidates", [])
    |> Map.put("delegations", [])
  end

  def complete(scope, params) do
    with {:ok, conversation, _original} <- context(scope),
         :ok <- validate_completion_params(params),
         true <- valid_decision?(params["decision"]),
         {:ok, source} <-
           Conversations.get_group_conversation_message(
             scope.group_id,
             conversation["conversation_id"],
             params["source_snapshot"]
           ),
         %{"worker_agent_id" => worker_id, "payload" => snapshot} <-
           get_in(source, ["metadata", @snapshot]),
         true <- worker_id == scope.agent_id,
         {:ok, payload} <- completion_payload(snapshot, params["decision"]),
         true <- valid_completion_source?(payload),
         {:ok, %{status: :fresh}} <- SlackEffectAdapter.Freshness.check(%{payload: payload}, []),
         {:ok, result} <-
           ConversationServer.complete_triage_investigation(
             scope.group_id,
             conversation["conversation_id"],
             scope.agent_id,
             params["source_snapshot"],
             params["decision"]
           ) do
      {:ok,
       Map.merge(result, %{
         "accepted" => true,
         "delivery_status" => "pending",
         "next_action" =>
           "The public result is durably queued. End this investigation turn; code owns delivery and status."
       })}
    else
      {:ok, %{status: :stale}} -> {:error, :triage_source_changed_read_again}
      false -> {:error, :invalid_triage_completion}
      nil -> {:error, :invalid_triage_source_snapshot}
      error -> error
    end
  end

  defp validate_completion_params(
         %{"source_snapshot" => snapshot, "decision" => decision} = params
       )
       when map_size(params) == 2 and is_binary(snapshot) and is_map(decision) do
    if String.trim(snapshot) != "" do
      validate_decision_params(decision)
    else
      {:error,
       "invalid_triage_completion: expected params with exact keys source_snapshot (non-empty string) and decision (object)"}
    end
  end

  defp validate_completion_params(_params) do
    {:error,
     "invalid_triage_completion: expected params with exact keys source_snapshot (non-empty string) and decision (object)"}
  end

  defp validate_decision_params(%{"context_candidates" => candidates} = decision) do
    if is_list(candidates) and length(candidates) <= 3 do
      validate_decision_kind(Map.delete(decision, "context_candidates"))
    else
      {:error,
       "invalid_triage_completion: decision.context_candidates must be an array of at most 3 items"}
    end
  end

  defp validate_decision_params(decision), do: validate_decision_kind(decision)

  defp validate_decision_kind(%{"kind" => "reply"} = decision) do
    case decision do
      %{"kind" => "reply", "text" => text, "source_refs" => refs}
      when map_size(decision) == 3 and is_binary(text) ->
        if String.trim(text) != "" and byte_size(text) <= 16_000 and valid_refs?(refs) do
          :ok
        else
          reply_decision_error()
        end

      _ ->
        reply_decision_error()
    end
  end

  defp validate_decision_kind(%{"kind" => "reaction"} = decision) do
    case decision do
      %{"kind" => "reaction", "emoji" => emoji, "source_refs" => [_] = refs}
      when map_size(decision) == 3 and is_binary(emoji) ->
        if Regex.match?(~r/\A[a-z0-9][a-z0-9_+\-]{0,63}\z/, emoji) and valid_refs?(refs) do
          :ok
        else
          reaction_decision_error()
        end

      _ ->
        reaction_decision_error()
    end
  end

  defp validate_decision_kind(%{"kind" => "silence"} = decision) do
    with :ok <- validate_silence_reason_code(decision),
         trimmed <- Map.delete(decision, "reason_code") do
      case trimmed do
        %{"kind" => "silence", "reason" => reason, "source_refs" => refs}
        when map_size(trimmed) == 3 and is_binary(reason) ->
          if String.trim(reason) != "" and byte_size(reason) <= 2000 and valid_refs?(refs) do
            :ok
          else
            silence_decision_error()
          end

        _ ->
          silence_decision_error()
      end
    end
  end

  defp validate_decision_kind(_decision) do
    {:error,
     "invalid_triage_completion: decision.kind must be one of reply, reaction, or silence"}
  end

  defp validate_silence_reason_code(%{"reason_code" => code}) do
    if code in ~w(already_handled no_useful_addition insufficient_evidence) do
      :ok
    else
      {:error,
       "invalid_triage_completion: silence decision reason_code must be one of already_handled, no_useful_addition, or insufficient_evidence"}
    end
  end

  defp validate_silence_reason_code(_decision), do: :ok

  defp reply_decision_error do
    {:error,
     "invalid_triage_completion: reply decision requires exact keys kind, text (1..16000 bytes), and source_refs (array of strings); optional context_candidates only (no reason or reason_code)"}
  end

  defp reaction_decision_error do
    {:error,
     "invalid_triage_completion: reaction decision requires exact keys kind, emoji (canonical name), and source_refs (array of exactly 1 ref); optional context_candidates only"}
  end

  defp silence_decision_error do
    {:error,
     "invalid_triage_completion: silence decision requires exact keys kind, reason (1..2000 bytes), and source_refs (array of strings); optional reason_code (already_handled|no_useful_addition|insufficient_evidence) and context_candidates only"}
  end

  def valid_decision?(%{"context_candidates" => candidates} = decision) do
    is_list(candidates) and length(candidates) <= 3 and
      valid_decision?(Map.delete(decision, "context_candidates"))
  end

  def valid_decision?(%{"kind" => "silence", "reason_code" => code} = decision) do
    code in ~w(already_handled no_useful_addition insufficient_evidence) and
      valid_decision?(Map.delete(decision, "reason_code"))
  end

  def valid_decision?(%{"kind" => "reply", "text" => text, "source_refs" => refs} = decision),
    do:
      map_size(decision) == 3 and is_binary(text) and String.trim(text) != "" and
        byte_size(text) <= 16_000 and valid_refs?(refs)

  def valid_decision?(
        %{"kind" => "reaction", "emoji" => emoji, "source_refs" => [_] = refs} = decision
      ),
      do:
        map_size(decision) == 3 and is_binary(emoji) and
          Regex.match?(~r/\A[a-z0-9][a-z0-9_+\-]{0,63}\z/, emoji) and valid_refs?(refs)

  def valid_decision?(
        %{"kind" => "silence", "reason" => reason, "source_refs" => refs} = decision
      ),
      do:
        map_size(decision) == 3 and is_binary(reason) and String.trim(reason) != "" and
          byte_size(reason) <= 2000 and valid_refs?(refs)

  def valid_decision?(_), do: false

  defp valid_refs?(refs),
    do:
      is_list(refs) and length(refs) <= 20 and
        Enum.all?(refs, &(is_binary(&1) and byte_size(&1) in 1..2048))

  defp completion_payload(snapshot, decision) do
    candidates = Map.get(decision, "context_candidates", [])
    messages = source_messages(snapshot, snapshot["source_messages"] || [])
    refs = Enum.map(messages ++ (snapshot["context_sources"] || []), & &1["source_ref"])

    recheck_refs =
      case snapshot do
        %{"recheck_context_refs" => refs} -> refs
        %{"recheck_event_ids" => [_ | _]} -> [nil]
        _ -> []
      end

    with true <- ProductDecision.valid_context_candidates?(candidates, refs),
         {:ok, candidates} <-
           ProductObligation.bind_recheck_context(
             candidates,
             recheck_refs,
             refs
           ) do
      raw_bundle = %{
        "raw_context" => %{"slack_context" => %{"messages" => messages}},
        "source_authority" => snapshot["target"],
        "product_identity" => snapshot["product_identity"]
      }

      {:ok,
       snapshot
       |> Map.put("communication", Map.delete(decision, "context_candidates"))
       |> Map.put(
         "context_candidates",
         ProductObligation.attribute_context(candidates, raw_bundle)
       )
       |> put_completion_reaction_authority()}
    else
      _ -> {:error, :invalid_triage_context_candidates}
    end
  end

  defp put_completion_reaction_authority(
         %{"communication" => %{"kind" => "reaction"}, "expression_context" => context} = payload
       )
       when is_map(context), do: Map.put(payload, "reaction_authority", context)

  defp put_completion_reaction_authority(payload), do: payload

  # The token is an in-process owner instruction, removed before Message
  # validation/storage. No JSON API or generic append can mint this struct.
  defmodule OwnerCommand do
    @moduledoc false
    defstruct []
  end

  def protect_append(attrs, conversation, memberships) do
    {owner, attrs} = Map.pop(attrs, :triage_owner_command)
    metadata = attrs["metadata"] || %{}
    sink_ids = memberships |> Enum.filter(fn {_, p} -> sink?(p) end) |> Enum.map(&elem(&1, 0))

    targets =
      Enum.flat_map([attrs["mentions"], attrs["delivery_filter"]], fn
        %{"participant_ids" => ids} when is_list(ids) -> ids
        _ -> []
      end)

    protected =
      Map.has_key?(metadata, @result) or Map.has_key?(metadata, @snapshot) or
        Map.has_key?(metadata, @retry) or
        Enum.any?(targets, &(&1 in sink_ids))

    if protected and not (task?(conversation) and match?(%OwnerCommand{}, owner)),
      do: {:error, {:bad_request, "Triage completion is product-owned"}},
      else: {:ok, attrs}
  end

  def source_message(conversation, worker_id, snapshot) do
    if get_in(conversation, ["source_refs", @grant, "worker_agent_id"]) == worker_id do
      {:ok,
       %{
         :triage_owner_command => %OwnerCommand{},
         "actor_type" => "agent",
         "agent_id" => worker_id,
         "content" => "Current source snapshot read for this investigation.",
         "delivery_filter" => %{"participant_ids" => []},
         "metadata" => %{@snapshot => %{"worker_agent_id" => worker_id, "payload" => snapshot}}
       }}
    else
      denied()
    end
  end

  def completion_message(conversation, memberships, worker_id, source, decision) do
    with true <- get_in(conversation, ["source_refs", @grant, "worker_agent_id"]) == worker_id,
         true <- valid_decision?(decision),
         %{"worker_agent_id" => ^worker_id, "payload" => snapshot} <-
           get_in(source, ["metadata", @snapshot]),
         {sink_id, _} <- Enum.find(memberships, fn {_, p} -> sink?(p) end),
         {:ok, completed} <- completion_payload(snapshot, decision) do
      payload =
        completed
        |> Map.put("task_conversation_id", conversation["conversation_id"])
        |> Map.put("task_source_snapshot", source["message_id"])

      if valid_completion_source?(payload) do
        {:ok,
         %{
           :triage_owner_command => %OwnerCommand{},
           "actor_type" => "agent",
           "agent_id" => worker_id,
           "client_request_id" => "triage-completion:" <> source["message_id"],
           "content" =>
             decision["text"] || decision["reason"] || "Reaction: #{decision["emoji"]}",
           "mentions" => %{"participant_ids" => [sink_id]},
           "delivery_filter" => %{"participant_ids" => [sink_id]},
           "metadata" => %{
             @result => %{
               "worker_agent_id" => worker_id,
               "source_snapshot" => source["message_id"],
               "payload" => payload
             }
           }
         }}
      else
        {:error, :invalid_triage_completion_source}
      end
    else
      _ -> denied()
    end
  end

  def delivery?(rec),
    do:
      get_in(rec, ["message_metadata", @result]) != nil and
        rec["participant_role_label"] == @sink_role

  def worker_assignment?(rec) do
    grant = get_in(rec, ["conversation_source_refs", @grant])

    is_map(grant) and rec["participant_agent_id"] == grant["worker_agent_id"] and
      (rec["message_seq"] == 1 or is_map(get_in(rec, ["message_metadata", @retry])))
  end

  # An exhausted transport does not prove rejection: a lost acknowledgement
  # may hide accepted work. Escalation leaves the grant and completion state
  # intact, so a late Worker result can still finish this same investigation.
  def escalate_command_delivery(conversation, participant, rec) do
    current_grant = get_in(conversation, ["source_refs", @grant])

    if task?(conversation) and worker_assignment?(rec) and
         conversation["status"] == "active" and
         conversation["conversation_id"] == rec["conversation_id"] and
         conversation["agent_group_id"] == rec["agent_group_id"] and
         current_grant == get_in(rec, ["conversation_source_refs", @grant]) and
         conversation["task_worker_agent_id"] == rec["participant_agent_id"] and
         participant["state"] == "active" and
         participant["agent_id"] == rec["participant_agent_id"] and
         get_in(participant, ["payload", "session_id"]) ==
           get_in(rec, ["participant_payload", "session_id"]) and
         conversation["message_tail_seq"] == rec["message_seq"] do
      lifecycle = get_in(conversation, ["metadata", @state]) || %{}

      conversation
      |> put_lifecycle(
        Map.put(lifecycle, "delivery_error", %{
          "message_id" => rec["message_id"],
          "reason" => "Worker command delivery was not confirmed."
        })
      )
      |> Map.put("status", "escalated")
    else
      conversation
    end
  end

  # The initial Worker Participant already owns durable command delivery.
  # Repair its Router locator before waking Worker, without a fresh-create gate.
  def prepare_worker_delivery(rec, origin) do
    grant = get_in(rec, ["conversation_source_refs", @grant])

    cond do
      not worker_assignment?(rec) ->
        :ok

      not is_map(origin["triage_investigation"]) ->
        {:error, :triage_assignment_authority_unavailable, true}

      true ->
        with {:ok, original} <- original(grant) do
          if get_in(original.payload, ["communication", "kind"]) == "reply" do
            with {:ok, {:delivered, receipt}} <- SlackEffectAdapter.Reply.lookup(original, []),
                 :ok <-
                   SalixIM.Triage.RouterContextProjection.deliver_participation(
                     %{
                       original
                       | payload:
                           Map.put(
                             original.payload,
                             "task_conversation_id",
                             rec["conversation_id"]
                           )
                     },
                     %{"channel" => receipt.channel_id, "ts" => receipt.message_ts}
                   ) do
              :ok
            else
              _ -> {:error, :triage_task_context_unavailable, true}
            end
          else
            :ok
          end
        else
          _ -> {:error, :triage_assignment_authority_unavailable, true}
        end
    end
  end

  def deliver(rec) do
    with %{"payload" => payload} <- get_in(rec, ["message_metadata", @result]),
         operation when is_binary(operation) <- rec["operation_ref"],
         claim <- %{
           obligation_id: operation_id(operation),
           claim_token: to_string(rec["delivery_claim_revision"]),
           payload: payload
         },
         {:ok, effect} <- apply_completion(claim) do
      case settle(rec, effect) do
        :ok -> {:ok, effect}
        _ -> {:error, :triage_completion_unavailable, true}
      end
    else
      {:error, reason, retryable?} = error ->
        if not retryable? or (rec["attempts"] || 0) >= 2 do
          case settle(rec, %{outcome: :failed, reason: reason}) do
            :ok -> error
            _ -> {:error, :triage_completion_unavailable, true}
          end
        else
          error
        end

      error ->
        error
    end
  end

  defp apply_completion(%{payload: %{"communication" => %{"kind" => "silence"}}} = claim) do
    # Silence has no provider receipt to recover. Its context is still a new
    # write, so both initial delivery and recovery must recheck the source.
    case SlackEffectAdapter.Freshness.check(claim, []) do
      {:ok, %{status: :fresh}} ->
        SlackEffectAdapter.apply(claim)

      {:ok, %{status: :stale, reason: reason}} ->
        {:ok, %{outcome: :stale, reason: reason, external_writes: 0}}

      error ->
        error
    end
  end

  defp apply_completion(claim), do: SlackEffectAdapter.apply(claim)

  def verify(rec) do
    with %{"payload" => payload} <- get_in(rec, ["message_metadata", @result]) do
      claim = %{obligation_id: operation_id(rec["operation_ref"]), payload: payload}

      case get_in(payload, ["communication", "kind"]) do
        "reply" ->
          case SlackEffectAdapter.Reply.lookup(claim, []) do
            {:ok, {:delivered, result}} -> verified(rec, result)
            {:ok, :not_delivered} -> {:missing, :provider_delivery_not_found}
            error -> {:unknown, error}
          end

        "reaction" ->
          with {:ok, timestamp} <- SlackEffectAdapter.reaction_target(payload),
               {:ok, presence} <-
                 SlackEffectAdapter.Reaction.lookup(
                   claim,
                   timestamp,
                   payload["communication"]["emoji"],
                   []
                 ) do
            case presence do
              :present -> verified(rec, %{already_reacted: true})
              :missing -> {:missing, :provider_delivery_not_found}
            end
          else
            error -> {:unknown, error}
          end

        "silence" ->
          case deliver(rec) do
            {:ok, result} -> {:ok, result}
            error -> {:unknown, error}
          end

        _ ->
          {:unknown, :invalid_triage_completion}
      end
    else
      _ -> {:unknown, :invalid_triage_completion}
    end
  end

  defp verified(rec, result) do
    case settle(rec, %{outcome: :applied}) do
      :ok -> {:ok, result}
      error -> {:unknown, error}
    end
  end

  # This is a namespace encoding of the Message/Participant receipt identity for the
  # existing product-effect store. It is an idempotency key, not verification.
  def operation_id(operation) when is_binary(operation),
    do: "triage-product-" <> SalixStore.Crypto.hex(operation)

  def join_task(%{payload: payload}) do
    case payload["task_conversation_id"] do
      nil ->
        :ok

      task_id ->
        case ConversationServer.join_triage_investigation(
               get_in(payload, ["product_identity", "project_salix_group_id"]),
               task_id,
               payload["task_source_snapshot"]
             ) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  def join_cursor(conversation, source_id, result_seq) do
    lifecycle = get_in(conversation, ["metadata", @state]) || %{}

    if task?(conversation) and lifecycle["current_source"] == source_id do
      cursor = lifecycle["joined_cursor"] || result_seq

      put_lifecycle(conversation, Map.put(lifecycle, "joined_cursor", cursor))
    else
      denied()
    end
  end

  defp settle(rec, effect) do
    result = get_in(rec, ["message_metadata", @result])
    group_id = get_in(result, ["payload", "product_identity", "project_salix_group_id"])

    with :ok <-
           TriageProductRuntime.settle_investigation_context(
             result["payload"],
             operation_id(rec["operation_ref"]),
             effect
           ),
         :ok <- join_after_prior_reply(result["payload"], effect) do
      case ConversationServer.settle_triage_investigation(
             group_id,
             rec["conversation_id"],
             result["source_snapshot"],
             effect
           ) do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp join_after_prior_reply(payload, %{outcome: outcome}) when outcome in [:applied, :failed] do
    subscriptions = SalixStore.SlackTriageThreadSubscriptions

    with {:ok, scope} <-
           subscriptions.product_scope(payload["target"], payload["product_identity"]) do
      case subscriptions.status(scope) do
        {:ok, :active} -> join_task(%{payload: payload})
        {:error, :not_found} -> :ok
        _ -> {:error, :triage_continuation_unavailable}
      end
    end
  end

  defp join_after_prior_reply(_, _), do: :ok

  def reserve_completion(conversation, source_id, decision) do
    state = get_in(conversation, ["metadata", @state]) || %{}

    cond do
      not task?(conversation) ->
        denied()

      state["state"] == "completed" and state["current_source"] == source_id ->
        conversation

      state["state"] in ["completed", "failed"] ->
        {:error, :triage_investigation_finished}

      state["state"] == "pending" and state["current_source"] != source_id ->
        {:error, :triage_completion_pending}

      source_id in List.wrap(state["settled_sources"]) ->
        {:error, :triage_source_changed_read_again}

      state["state"] == "pending" and state["pending_decision"] != decision ->
        {:error, :triage_completion_conflict}

      state["state"] == "pending" ->
        conversation

      true ->
        lifecycle =
          state
          |> Map.put("state", "pending")
          |> Map.put("current_source", source_id)
          |> Map.put("pending_decision", decision)
          |> Map.update("attempts", 1, &(&1 + 1))

        put_lifecycle(conversation, lifecycle)
    end
  end

  def settle_completion(conversation, source_id, effect) do
    state = get_in(conversation, ["metadata", @state]) || %{}
    settled = List.wrap(state["settled_sources"])

    cond do
      not task?(conversation) ->
        denied()

      source_id in settled ->
        conversation

      state["state"] != "pending" or state["current_source"] != source_id ->
        {:error, :triage_completion_mismatch}

      true ->
        stale = effect[:outcome] == :stale

        outcome_atom =
          case effect[:outcome] do
            :failed -> :failed
            :stale -> :stale
            _ -> :applied
          end

        next =
          outcome_atom
          |> SalixVerifiedKernel.Proactive.settle_investigation_outcome(state["attempts"] || 0)
          |> Atom.to_string()

        state =
          state
          |> Map.put("state", next)
          |> Map.delete("pending_decision")
          |> Map.delete("delivery_error")
          |> Map.put("settled_sources", settled ++ [source_id])
          |> Map.put("reason", if(stale, do: "Source changed before publication", else: nil))

        conversation
        |> put_lifecycle(state)
        |> Map.put(
          "status",
          case next do
            "completed" -> "ready_for_review"
            "failed" -> "failed"
            _ -> "active"
          end
        )
    end
  end

  def retry_message(conversation, memberships, source_id) do
    lifecycle = get_in(conversation, ["metadata", @state]) || %{}

    if lifecycle["state"] == "retry" and lifecycle["current_source"] == source_id do
      worker_id = conversation["task_worker_agent_id"]
      {participant_id, _} = Enum.find(memberships, fn {_, p} -> p["agent_id"] == worker_id end)

      {:ok,
       %{
         :triage_owner_command => %OwnerCommand{},
         "actor_type" => "system",
         "client_request_id" => "triage-retry:" <> source_id,
         "content" =>
           "The Slack source changed before a new result could be published. Continue this same investigation: call internal.triage.read_source, incorporate the new messages, and submit the revised public decision through internal.triage.complete. Keep private evidence in this Task. This is a bounded retry of the original product assignment.",
         "mentions" => %{"participant_ids" => [participant_id]},
         "delivery_filter" => %{"participant_ids" => [participant_id]},
         "metadata" => %{
           @retry => %{"source_snapshot" => source_id, "worker_agent_id" => worker_id}
         }
       }}
    else
      :none
    end
  end

  defp put_lifecycle(conversation, state),
    do:
      Map.update(conversation, "metadata", %{@state => state}, &Map.put(&1 || %{}, @state, state))

  def protect_update(conversation, updates) do
    if Map.has_key?(updates, "metadata") and
         get_in(updates, ["metadata", @state]) != get_in(conversation, ["metadata", @state]),
       do: {:error, {:bad_request, "Triage lifecycle is product-owned"}},
       else: :ok
  end

  defp request_id(original), do: "triage-delegation:#{original.obligation_id}:#{original.index}"
  defp denied, do: {:error, :triage_investigation_not_authorized}
end
