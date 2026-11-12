defmodule SalixAgent.InternalSessionStore.ImportTargets do
  @moduledoc false

  alias SalixAgent.InternalSession
  alias SalixAgent.InternalSession.State
  alias SalixAgent.InternalSessionStore.PGCodec
  alias SalixStore.{ArchiveLog, PGAuthorityImport, Repo, S3, SealedSegments}

  # The offline importer needs only these calls, not model context or accepted inputs.
  # A release location selects bytes; only the scoped owner record can establish
  # a terminal result. Missing evidence leaves the source unresolved and does not
  # prove that the Session never accepted a result elsewhere in its cold history.
  def read(agent, session, ids, budget, opts \\ []) when length(ids) <= 1000 do
    limit = min(budget.remaining_bytes, min(budget.max_object_bytes, budget.max_inflated_bytes))

    case Repo.query!(
           """
           SELECT octet_length(control_payload),
                  CASE WHEN octet_length(control_payload)<=$3 THEN control_payload END
           FROM salix_sessions WHERE agent_id=$1 AND session_id=$2
             AND birth_kind='internal' AND deleted_at IS NULL AND control_payload IS NOT NULL
           """,
           [agent, session, limit]
         ).rows do
      [] ->
        {:ok, Map.new(ids, &{&1, :unknown}), budget}

      [[bytes, payload]] when is_binary(payload) ->
        budget = %{budget | remaining_bytes: budget.remaining_bytes - bytes}
        control = PGCodec.decode(payload)
        calls = owner_targets(control["async_tool_calls"], ids)
        refs = owner_targets(control["async_result_refs"], ids)
        seqs = for {_id, %{"record_seq" => seq}} <- calls, do: seq
        missing = Enum.reject(ids, &(Map.has_key?(calls, &1) or Map.has_key?(refs, &1)))

        with {:ok, hot, budget} <- hot_records(agent, session, seqs, missing, budget),
             locations = cold_locations(agent, session, missing, hot, opts),
             {:ok, records, budget} <-
               cold_records(
                 agent,
                 session,
                 seqs ++ Map.values(locations),
                 hot,
                 budget,
                 &located_records(&1, hot, seqs, locations)
               ) do
          by_seq = Map.new(records, &{&1["seq"], &1})

          calls =
            Map.new(calls, fn
              {id, %{"record_seq" => seq, "pending" => pending}} ->
                record = by_seq[seq]

                call =
                  case record do
                    %{"kind" => "async_result"} -> Map.merge(record, pending)
                    _ -> :unresolved
                  end

                {id, call}

              entry ->
                entry
            end)

          state =
            InternalSession.open(%State{
              async_tool_calls: calls,
              async_result_refs: refs,
              async_results: records
            })

          {:ok, Map.new(ids, &{&1, InternalSession.query(state, :completion_target, &1)}), budget}
        end

      _ ->
        {:error, :completion_target_byte_limit}
    end
  rescue
    _ in [ArgumentError, BadMapError, KeyError, MatchError, Jason.DecodeError] ->
      {:error, :invalid_completion_target}

    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error, error}
  end

  defp owner_targets(nil, _ids), do: %{}
  defp owner_targets(targets, ids) when is_map(targets), do: Map.take(targets, ids)
  defp owner_targets(_, _), do: raise(ArgumentError, "invalid completion target owner")

  defp cold_locations(agent, session, missing, hot, opts) do
    locations = Keyword.get(opts, :cold_result_locations, %{})
    state = InternalSession.open(%State{async_results: hot})

    Map.new(
      for id <- missing,
          InternalSession.query(state, :completion_target, id) == :unknown,
          seq = locations[{agent, session, id}],
          is_integer(seq) and seq > 0,
          do: {id, seq}
    )
  end

  defp located_records(records, hot, seqs, locations) do
    indexed = MapSet.new(seqs ++ Enum.map(hot, & &1["seq"]))

    Enum.filter(records, fn record ->
      MapSet.member?(indexed, record["seq"]) or
        (locations[record["tool_call_id"]] == record["seq"] and terminal_record?(record))
    end)
  end

  defp terminal_record?(record) do
    id = record["tool_call_id"]
    state = InternalSession.open(%State{async_tool_calls: %{id => record}})
    InternalSession.query(state, :completion_target, id) == :already_resolved
  end

  defp hot_records(_agent, _session, [], [], budget), do: {:ok, [], budget}

  defp hot_records(agent, session, seqs, ids, budget) do
    rows =
      Repo.query!(
        """
        WITH selected AS (
          SELECT seq FROM salix_session_records
          WHERE agent_id=$1 AND session_id=$2 AND seq=ANY($3)
          UNION
          SELECT seq FROM salix_session_records
          WHERE agent_id=$1 AND session_id=$2 AND kind IN ('async_result','tool_result')
            AND record_id=ANY($4)
        )
        SELECT seq,kind,octet_length(payload),
               CASE WHEN sum(octet_length(payload)) OVER (ORDER BY seq)<=$5
                      AND octet_length(payload)<=$6 THEN payload END
        FROM selected JOIN salix_session_records USING (seq)
        WHERE agent_id=$1 AND session_id=$2 ORDER BY seq
        """,
        [
          agent,
          session,
          seqs,
          Enum.map(ids, &PGCodec.identity/1),
          budget.remaining_bytes,
          min(budget.max_object_bytes, budget.max_inflated_bytes)
        ]
      ).rows

    if Enum.any?(rows, fn [_, _, _, payload] -> is_nil(payload) end) do
      {:error, :completion_target_byte_limit}
    else
      records =
        for [seq, kind, _, payload] <- rows, kind in ["async_result", "tool_result"] do
          {:async_results, record} =
            PGCodec.record_row(%{"seq" => seq, "kind" => kind, "payload" => payload})

          Map.put(record, "kind", kind)
        end

      bytes = Enum.reduce(rows, 0, fn [_, _, size, _], total -> total + size end)
      {:ok, records, %{budget | remaining_bytes: budget.remaining_bytes - bytes}}
    end
  end

  defp cold_records(agent, session, seqs, records, budget, select) do
    missing = Enum.reject(seqs, &Enum.any?(records, fn record -> record["seq"] == &1 end))

    spans =
      if missing == [],
        do: [],
        else:
          Repo.query!(
            """
            SELECT DISTINCT a.* FROM unnest($3::bigint[]) wanted(seq)
            CROSS JOIN LATERAL (
              SELECT * FROM salix_session_archives WHERE agent_id=$1 AND session_id=$2
                AND first_seq<=wanted.seq AND last_seq>=wanted.seq ORDER BY first_seq DESC LIMIT 1
            ) a
            """,
            [agent, session, missing]
          )
          |> then(fn result ->
            Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
          end)

    Enum.reduce_while(spans, {:ok, records, budget}, fn span, {:ok, records, budget} ->
      before = budget.remaining_bytes

      case read_span(span, budget) do
        {:ok, fetched, budget} ->
          selected =
            for %{seq: seq, kind: "async_result", data: data} <- fetched,
                seq in missing,
                do: data |> Map.put("seq", seq) |> Map.put("kind", "async_result")

          selected = select.(selected)
          # The full decoded window is temporary. Charge the greater of its
          # wire bytes and the selected records that remain until resolution.
          retained = byte_size(PGCodec.encode(selected))
          extra = max(retained - (before - budget.remaining_bytes), 0)

          if extra <= budget.remaining_bytes,
            do:
              {:cont,
               {:ok, records ++ selected,
                %{budget | remaining_bytes: budget.remaining_bytes - extra}}},
            else: {:halt, {:error, :completion_target_byte_limit}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp read_span(%{"encoding" => "etf.zst", "object_key" => key} = span, budget) do
    with {:ok, %{value: records}, fetched} <- PGAuthorityImport.read_snapshot(key, budget),
         :ok <- SealedSegments.validate(records),
         :ok <- span_bounds(records, span) do
      {:ok, records, fetched}
    end
  end

  defp read_span(
         %{
           "encoding" => "jsonl",
           "object_key" => key,
           "byte_offset" => offset,
           "byte_length" => length
         } = span,
         budget
       )
       when is_integer(offset) and offset >= 0 and is_integer(length) and length > 0 do
    if length <=
         min(budget.remaining_bytes, min(budget.max_object_bytes, budget.max_inflated_bytes)) do
      with {:ok, %{body: bytes}} <-
             PGAuthorityImport.with_io(budget, fn -> S3.get(key, range: {offset, length}) end),
           records = PGAuthorityImport.with_decode(budget, fn -> ArchiveLog.decode!(bytes) end),
           :ok <- jsonl_bounds(records, span) do
        {:ok, records,
         %{
           budget
           | remaining_bytes: budget.remaining_bytes - byte_size(bytes),
             objects: budget.objects + 1,
             wire_bytes: budget.wire_bytes + byte_size(bytes),
             inflated_bytes: budget.inflated_bytes + byte_size(bytes)
         }}
      end
    else
      {:error, :completion_target_byte_limit}
    end
  end

  defp read_span(_, _), do: {:error, :invalid_completion_target_archive}

  defp jsonl_bounds(records, span) do
    seqs = Enum.map(records, & &1.seq)

    if {Enum.min(seqs, fn -> nil end), Enum.max(seqs, fn -> nil end)} ==
         {span["first_seq"], span["last_seq"]},
       do: :ok,
       else: {:error, :invalid_completion_target_archive}
  end

  defp span_bounds([first | _] = records, span) do
    if first.seq == span["first_seq"] and List.last(records).seq == span["last_seq"] and
         ArchiveLog.message_count(records) == span["message_count"],
       do: :ok,
       else: {:error, :invalid_completion_target_archive}
  end

  defp span_bounds(_, _), do: {:error, :invalid_completion_target_archive}
end
