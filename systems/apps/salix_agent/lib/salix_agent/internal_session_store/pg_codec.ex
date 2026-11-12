defmodule SalixAgent.InternalSessionStore.PGCodec do
  @moduledoc false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State

  @column_fields ~w(name hidden runtime_epoch storage_revision last_seq compacted_seq archived_through queue_ack_id next_queue_id next_message_id)

  # Archive records use string keys. Restore only Transcript's fixed runtime
  # fields; free metadata never becomes atoms while rebuilding cold context.
  @message_fields Map.new(
                    ~w(seq id role content accepted_input trusted_attachment_refs trusted_origin
                       source_message_id dedupe_key no_wake created_at delivered_at_ms input_time
                       execution_timing model input_tokens output_tokens cache_read_input_tokens
                       cache_write_input_tokens request_summary_sequence request_compacted_through
                       request_input_through turn_id round_id request_id trace_id tool_call_id
                       tool_calls do_not_send_to_llm provider_meta visible_reply_phase ifc
                       tool_name status duration_ms input output error_class error_message
                       guidance_reason diagnostic_visibility public_summary repair_outcome
                       visible_reply_origin started_at completed_at kind runtime_message_id type
                       summary content_kind source_refs source_tool_call_id wait_id reason
                       timeout_seconds deadline_ms source elapsed_ms overdue_ms tool_call_ids
                       failed_tool_calls pending_external_callback_tool_calls failed_llm_call
                       trusted_origins trusted_origin_source_message_ids result_seq)a,
                    &{Atom.to_string(&1), &1}
                  )

  def encode(value), do: :erlang.term_to_binary(value, [:deterministic, {:minor_version, 2}])
  def decode(value) when is_binary(value), do: :erlang.binary_to_term(value, [:safe])

  # Kernel deltas own these payloads, as with trusted snapshots in SalixStore.Codec.
  # Older records can contain atoms that the current binary has not loaded.
  defp decode_record(value) when is_binary(value), do: :erlang.binary_to_term(value)

  def identity(nil), do: nil
  def identity(value), do: encode(value)

  def timestamp(nil), do: nil
  def timestamp(value) when is_integer(value), do: DateTime.from_unix!(value, :second)

  def timestamp_ms(nil), do: nil
  def timestamp_ms(value) when is_integer(value), do: DateTime.from_unix!(value, :millisecond)

  def input(item) do
    {item["queue_id"], item["kind"], identity(item["dedupe_key"]),
     encode(Map.drop(item, ~w(queue_id kind dedupe_key)))}
  end

  def input_row(row) do
    row["payload"]
    |> decode()
    |> Map.merge(%{
      "queue_id" => row["queue_id"],
      "kind" => row["kind"],
      "dedupe_key" => if(row["dedupe_key"], do: decode(row["dedupe_key"]))
    })
  end

  def source_row(row) do
    {row["participant_id"],
     %{
       "participant_id" => row["participant_id"],
       "conversation_id" => row["conversation_id"],
       "generation" => row["generation"],
       "start_seq" => row["start_seq"],
       "seq" => row["seq"],
       "last_rejection" => if(row["last_rejection"], do: decode(row["last_rejection"]))
     }}
  end

  def record_row(%{"kind" => "message"} = row),
    do: {:messages, row["payload"] |> decode_record() |> Map.put(:seq, row["seq"])}

  def record_row(%{"kind" => "fact"} = row),
    do: {:events, row["payload"] |> decode_record() |> Map.put("seq", row["seq"])}

  def record_row(row),
    do: {:async_results, row["payload"] |> decode_record() |> Map.put("seq", row["seq"])}

  def message(row), do: row |> record_row() |> elem(1)

  def archived_message(%{seq: seq, data: body}),
    do: body |> runtime_message() |> Map.put(:seq, seq)

  def history_record(row),
    do: SalixStore.ArchiveLog.shape(row["kind"], row["seq"], decode_record(row["payload"]))

  # A read-only projection for the existing archive cut/adopt state machine.
  # It carries no business context, dedupe set or prior directory to publish.
  def archive_window(agent_id, session_id, through, ceiling, records) do
    collections = collections(records)

    %State{
      agent_id: agent_id,
      session_id: session_id,
      storage_format: 3,
      archived_through: through,
      last_seq: ceiling
    }
    |> Map.merge(collections)
    |> InternalSession.open()
  end

  defp collections(records) do
    Enum.reduce(records, %{messages: [], events: [], async_results: []}, fn record, acc ->
      {name, value} = record_row(record)
      Map.update!(acc, name, &[value | &1])
    end)
    |> Map.new(fn {name, items} -> {name, Enum.reverse(items)} end)
  end

  def state(row, context, inputs, sources, records, archives, cold_records \\ []) do
    compacted = row["compacted_seq"] || 0
    window = records ++ Enum.filter(cold_records, &(&1["seq"] > compacted))
    collections = collections(Enum.sort_by(window, & &1["seq"]))

    with {:ok, control} <- hydrate_calls(decode(row["control_payload"]), records ++ cold_records) do
      state =
        %State{}
        |> Map.merge(atom_fields(decode(context)))
        |> Map.merge(atom_fields(control))
        |> Map.merge(atom_fields(Map.take(row, @column_fields)))
        |> Map.merge(collections)
        |> Map.merge(%{
          agent_id: row["agent_id"],
          session_id: row["session_id"],
          created_at: unix(row["created_at"]),
          last_activity_at: unix(row["last_activity_at"]),
          input_queue: Enum.map(inputs, &input_row/1),
          conversation_sources: Map.new(sources, &source_row/1),
          archive_chunks:
            for(
              row <- archives,
              row["encoding"] == "jsonl",
              do: Enum.map(~w(first_seq last_seq message_count byte_offset byte_length), &row[&1])
            ),
          segment_catalog:
            archives
            |> Enum.filter(&(&1["encoding"] != "jsonl"))
            |> Enum.map(fn archive ->
              [
                archive["first_seq"],
                archive["last_seq"],
                archive["message_count"],
                archive["uncompressed_bytes"]
              ]
            end),
          archive_refs: Map.new(archives, &{&1["first_seq"], &1}),
          storage_format: 3
        })

      # Only live inputs populate the positive cache. SQL owns historical membership.
      keys =
        state.input_queue
        |> Enum.flat_map(fn item ->
          payload = item["payload"] || %{}
          [item["dedupe_key"], payload["source_message_id"], payload["runtime_message_id"]]
        end)
        |> Enum.reject(&(&1 in [nil, ""]))

      # `open/1` admits the state and `restore_pg/1` returns the restored
      # one. The admitted handle is not returned: release it now, or it
      # keeps its state resident until this process collects it.
      admitted = state |> Map.put(:input_dedupe, MapSet.new(keys)) |> InternalSession.open()
      restored = InternalSession.restore_pg(admitted)
      if restored != admitted, do: InternalSession.release(admitted)
      {:ok, restored}
    end
  end

  # The directory and hot rows are from one REPEATABLE READ view. Download
  # the logical context and live terminal references after that transaction ends.
  def hydrate_records(row, records, archives) do
    hot = MapSet.new(records, & &1["seq"])
    compacted = row["compacted_seq"] || 0
    archived = row["archived_through"] || 0

    needed =
      for {_key, %{"record_seq" => seq}} <-
            decode(row["control_payload"])["async_tool_calls"] || %{},
          not MapSet.member?(hot, seq),
          do: seq

    spans =
      Enum.filter(archives, fn span ->
        (span["last_seq"] > compacted and span["first_seq"] <= archived) or
          Enum.any?(needed, &(&1 >= span["first_seq"] and &1 <= span["last_seq"]))
      end)

    with :ok <- covers_context(archives, compacted + 1, archived),
         {:ok, fetched} <- SalixAgent.InternalSessionArchiveReader.read_descriptors(spans) do
      cold =
        for %{seq: seq} = record <- fetched,
            (seq > compacted and seq <= archived) or seq in needed,
            do: archive_row(record)

      {:ok, cold}
    end
  end

  defp archive_row(%{kind: kind, seq: seq, data: body}) do
    body = if kind == "message", do: runtime_message(body), else: body
    %{"seq" => seq, "kind" => kind, "payload" => encode(body)}
  end

  defp covers_context(_archives, first, last) when first > last, do: :ok

  defp covers_context(archives, first, last) do
    next =
      Enum.reduce_while(archives, first, fn span, next ->
        cond do
          next > last -> {:halt, next}
          span["last_seq"] < next -> {:cont, next}
          span["first_seq"] > next -> {:halt, next}
          true -> {:cont, span["last_seq"] + 1}
        end
      end)

    if next > last,
      do: :ok,
      else: {:error, {:archive_incomplete, %{missing_seq: next}}}
  end

  defp runtime_message(data),
    do: Map.new(data, fn {key, value} -> {Map.get(@message_fields, key, key), value} end)

  defp hydrate_calls(control, records) do
    by_seq = Map.new(records, &{&1["seq"], &1})

    Enum.reduce_while(control["async_tool_calls"] || %{}, {:ok, %{}}, fn
      {key, %{"record_seq" => seq, "pending" => pending}}, {:ok, calls} ->
        case by_seq[seq] do
          %{"kind" => "async_result", "payload" => payload} ->
            call = payload |> decode_record() |> Map.merge(pending) |> Map.put("seq", seq)
            {:cont, {:ok, Map.put(calls, key, call)}}

          _ ->
            {:halt, {:error, {:missing_session_record, seq}}}
        end

      {key, call}, {:ok, calls} ->
        {:cont, {:ok, Map.put(calls, key, call)}}
    end)
    |> case do
      {:ok, calls} -> {:ok, Map.put(control, "async_tool_calls", calls)}
      error -> error
    end
  end

  defp atom_fields(map),
    do: Map.new(map, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp unix(nil), do: nil
  defp unix(value), do: DateTime.to_unix(value, :second)
end
