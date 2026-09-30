defmodule SalixIM.Triage.AddressingEvidence do
  @moduledoc """
  Closed v2 addressing evidence shared by receipt and sealed-event readers.

  Addressing is durable source evidence, not a conclusion reconstructed from
  `fast_path`. A directed event names exactly one connect; ambient messages
  never carry that field. Callback and ClickHouse provenance prove the source
  differently, while trigger and fast-path remain redundant cross-checks that
  make corrupted or partially upgraded records fail closed.
  """

  @event_base_keys ~w(
    event_id connect_generation message_ts actor_id actor_kind text event_type
    addressing_kind trigger_kind fast_path bucket endpoint_provenance source_mode
  )
  @event_directed_keys ["addressed_connect" | @event_base_keys]

  @doc "Validates the closed field combination without claiming recipient authority."
  @spec validate_shape_only(map()) :: :ok | {:error, :invalid_addressing_evidence}
  def validate_shape_only(event) when is_map(event) do
    expected_connect = Map.get(event, "addressed_connect")

    if exact_event_keys?(event) and event["actor_kind"] in ["human", "agent"] and
         valid_combination?(event, expected_connect),
       do: :ok,
       else: {:error, :invalid_addressing_evidence}
  end

  def validate_shape_only(_event), do: {:error, :invalid_addressing_evidence}

  @spec validate(map(), String.t()) :: :ok | {:error, :invalid_addressing_evidence}
  def validate(event, connect_id) when is_map(event) and is_binary(connect_id) do
    valid? =
      validate_shape_only(event) == :ok and valid_combination?(event, connect_id)

    if valid?, do: :ok, else: {:error, :invalid_addressing_evidence}
  end

  def validate(_event, _connect_id), do: {:error, :invalid_addressing_evidence}

  defp exact_event_keys?(
         %{
           "source_mode" => "scheduled_recheck",
           "recheck_context_ref" => "triage-context://" <> entry_id
         } = event
       ) do
    canonical_nonblank?(entry_id) and byte_size(entry_id) <= 256 and
      exact_event_keys?(Map.delete(event, "recheck_context_ref"))
  end

  defp exact_event_keys?(%{"addressing_kind" => "directed"} = event),
    do: exact_keys?(event, @event_directed_keys)

  defp exact_event_keys?(%{"addressing_kind" => "ambient"} = event),
    do: exact_keys?(event, @event_base_keys)

  defp exact_event_keys?(_event), do: false

  defp channel_debounce?(event) do
    event["source_mode"] == "clickhouse_etl" and
      get_in(event, ["bucket", "scope_kind"]) == "channel"
  end

  defp valid_combination?(event, connect_id) do
    case {event["addressing_kind"], event["event_type"], event["trigger_kind"]} do
      {"directed", event_type, "mention"} when event_type in ["message", "app_mention"] ->
        canonical_nonblank?(event["addressed_connect"]) and
          event["addressed_connect"] == connect_id and event["fast_path"] == true and
          directed_source_evidence?(event)

      {"ambient", "message", "question_heuristic"} ->
        event["actor_kind"] == "human" and direct_question?(event["text"]) and
          not mentions_evidence_bot?(event) and event["fast_path"] == true

      {"ambient", "message", "none"} ->
        (channel_debounce?(event) or
           not (event["actor_kind"] == "human" and direct_question?(event["text"]))) and
          not mentions_evidence_bot?(event) and event["fast_path"] == false

      _invalid ->
        false
    end
  end

  defp directed_source_evidence?(%{"event_type" => "app_mention"}), do: true

  defp directed_source_evidence?(%{
         "event_type" => "message",
         "actor_kind" => "agent",
         "source_mode" => "clickhouse_etl",
         "endpoint_provenance" => %{
           "schema" => "comma.slack-clickhouse-etl-provenance.v1"
         }
       }),
       do: true

  defp directed_source_evidence?(%{"event_type" => "message"} = event),
    do: mentions_evidence_bot?(event)

  defp directed_source_evidence?(_event), do: false

  defp mentions_evidence_bot?(event) do
    bot_user_id = get_in(event, ["endpoint_provenance", "fast_path_bot_user_id"])

    canonical_nonblank?(bot_user_id) and is_binary(event["text"]) and
      String.contains?(event["text"], "<@#{bot_user_id}>")
  end

  defp exact_keys?(value, expected) when is_map(value),
    do: Map.keys(value) |> Enum.sort() == Enum.sort(expected)

  defp canonical_nonblank?(value),
    do:
      is_binary(value) and value != "" and value == String.trim(value) and
        not String.contains?(value, ["\n", "\r", "\0"])

  defp direct_question?(text) when is_binary(text), do: String.ends_with?(text, ["?", "？"])
  defp direct_question?(_text), do: false
end
