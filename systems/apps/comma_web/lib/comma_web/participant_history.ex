defmodule CommaWeb.ParticipantHistory do
  @moduledoc """
  Read-only Participant-addressed execution history for full workspace sessions.

  The caller authorizes the Group and Conversation. The canonical Participant
  supplies its fixed Agent/Session target; no client-supplied runtime identity
  is accepted. One request reads one Participant and one page, never a list of
  Agents, Sessions or Conversations. Existing runtime readers own redaction and
  archive paging. This adapter changes no delivery or persistence protocol.
  """

  alias SalixAgent.{Control, Runtime}

  def read(workspace, conversation_id, participant_id, opts) do
    with {:ok, limit} <- limit(opts[:limit]),
         {:ok, %{"actor_type" => "agent", "agent_id" => agent_id, "payload" => payload}} <-
           SalixIM.Conversations.get_group_conversation_participant(
             workspace["default_group_id"],
             conversation_id,
             participant_id
           ),
         session_id when is_binary(session_id) <- payload["session_id"],
         {:ok, agent} <- Control.get_including_archived(agent_id, workspace["salix_tenant_id"]) do
      target = %{"conversation_id" => conversation_id, "participant_id" => participant_id}

      if opts[:stream] do
        {:ok, %{agent: agent, session_id: session_id, target: target}}
      else
        with {:ok, page} <- page(agent, session_id, limit, opts[:before]) do
          {:ok, Map.merge(page, target)}
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :not_found}
    end
  end

  @doc false
  def page(agent, session_id, limit, before) do
    if Control.runtime_kind(agent) == "external" do
      with {:ok, result} <-
             Runtime.session_records(agent, session_id, limit: limit, before: before) do
        {:ok,
         %{
           "records" => Enum.map(result["records"], &external_record/1),
           "has_more" => result["has_more"] == true,
           "next_before" => result["next_before"]
         }}
      end
    else
      with {:ok, scope} <- history_scope(before, limit),
           {:ok, result} <- Runtime.get_session_messages(agent, session_id, history: scope) do
        records = Enum.map(result["messages"], &internal_record/1)
        has_more = result["history_truncated"] == true and records != []

        {:ok,
         %{
           "records" => records,
           "has_more" => has_more,
           "next_before" => if(has_more, do: hd(records)["id"])
         }}
      end
    end
  end

  defp history_scope(nil, limit), do: {:ok, {:tail, limit}}

  defp history_scope(before, limit) when is_binary(before) and byte_size(before) <= 20 do
    case Integer.parse(before) do
      {seq, ""} when seq > 0 -> {:ok, {:before, seq, limit}}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp history_scope(_, _), do: {:error, :invalid_cursor}

  defp limit(nil), do: {:ok, 50}
  defp limit(value) when is_integer(value) and value in 1..50, do: {:ok, value}

  defp limit(value) when is_binary(value) and byte_size(value) <= 2 do
    case Integer.parse(value) do
      {n, ""} -> limit(n)
      _ -> {:error, :invalid_cursor}
    end
  end

  defp limit(_), do: {:error, :invalid_cursor}

  # Project execution content only: runtime source/billing/auth metadata never
  # becomes a second public Conversation Message or a client routing identity.
  defp internal_record(message) do
    %{
      "id" => to_string(message["seq"]),
      "kind" => message["role"] || "event",
      "content" =>
        Map.take(
          message,
          ~w(content reasoning reasoning_content tool_calls tool_call_id tool_name name input model input_tokens output_tokens cache_read_input_tokens cache_write_input_tokens is_error status duration_ms execution_timing error_class error_message type summary source reason no_wake elapsed_ms timeout_seconds)
        ),
      "created_at" => message["created_at"]
    }
    |> timeline_fields(message)
    |> input_source(message)
  end

  # Display-only, finite facts from the persisted ingress envelope. Never parse
  # user prose or infer a source from the Conversation used to open this view:
  # a Router Session can contain inputs from several unrelated destinations.
  # Keep principal refs, credentials and routing identities private.
  defp input_source(%{"kind" => "user"} = record, message) do
    origin = if is_map(message["trusted_origin"]), do: message["trusted_origin"], else: %{}
    context = if is_map(origin["provider_context"]), do: origin["provider_context"], else: %{}

    source =
      %{}
      |> source_field(
        "provider",
        origin["provider"],
        ~w(internal telegram slack feishu wechat imessage voice signal)
      )
      |> source_field(
        "actor_type",
        normalize_actor(origin["source_actor_type"]),
        ~w(user agent system)
      )
      |> source_field("conversation_kind", origin["conversation_kind"], ~w(user_chat agent_task))
      |> source_field("chat_type", context["chat_type"], ~w(private group supergroup channel))

    record = Map.put(record, "input_source", source)

    # Read the ingress-owned body, never remove apparent envelopes from prose.
    # This bounded display field does not replace the original debug content.
    case origin["source_text"] do
      body when is_binary(body) ->
        preview = String.slice(body, 0, 321)
        Map.put(record, "input_text", preview)

      _ ->
        record
    end
  end

  defp input_source(record, _message), do: record

  defp normalize_actor("provider_user"), do: "user"
  defp normalize_actor(actor), do: actor

  defp source_field(source, key, value, allowed) do
    if value in allowed, do: Map.put(source, key, value), else: source
  end

  defp external_record(record) do
    data = record["data"] || %{}

    %{
      "id" => record["id"],
      "kind" =>
        if(record["type"] == "message", do: data["role"] || "message", else: record["type"]),
      "content" =>
        Map.take(
          data,
          ~w(content reasoning reasoning_content tool_calls tool_call_id tool_name name input model input_tokens output_tokens cache_read_input_tokens cache_write_input_tokens arguments result error error_class error_message duration_ms execution_timing started_at completed_at progress cancel_reason is_error text message status state event type summary source reason no_wake elapsed_ms timeout_seconds)
        ),
      "created_at" => record["created_at"]
    }
    |> timeline_fields(data)
  end

  # Normalize runtime-specific storage at the API boundary. The client receives
  # one typed timing shape; it never decodes debug JSON to reconstruct clocks.
  defp timeline_fields(record, data) do
    decoded =
      if record["kind"] in ["runtime", "tool"], do: decode_object(data["content"]), else: %{}

    event = data["event"] || %{}
    data = data |> Map.merge(decoded) |> Map.merge(event)
    result = decode_object(data["result"])

    timing =
      data["execution_timing"] || result["execution_timing"] ||
        SalixAgent.ExecutionTiming.from_tool(result)

    execution =
      if timing do
        timing
        |> Map.take(
          ~w(started_at_ms first_token_at_ms observed_at_ms completed_at_ms duration_ms)
        )
        |> Map.put(
          "id",
          data["tool_call_id"] || result["id"] || data["request_id"] || data["operation_id"] ||
            record["id"]
        )
        |> Map.put("lane", if(record["kind"] == "assistant", do: "model", else: "tool"))
      end

    Map.merge(record, %{
      "timestamp_ms" => timestamp_ms(record["created_at"]),
      "execution" => execution
    })
  end

  defp decode_object(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = data} -> data
      _ -> %{}
    end
  end

  defp decode_object(%{} = value), do: value
  defp decode_object(_), do: %{}
  defp timestamp_ms(value) when is_integer(value) and value < 1_000_000_000_000, do: value * 1000
  defp timestamp_ms(value) when is_integer(value), do: value
  defp timestamp_ms(nil), do: nil

  defp timestamp_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> DateTime.to_unix(time, :millisecond)
      _ -> nil
    end
  end
end
