defmodule SalixAgent.ExternalSessionRecords do
  @moduledoc """
  External-session record log: the `{agent_id, session_id}` layer over
  `SalixStore.SegmentLog`.

  This module owns only what is external-specific — the segment prefix, the ULID
  id space, the record shape, and the redelivery-identity rule for
  `runtime.event` records. The segment protocol itself (segment naming, CAS
  append, rollover, content-settled idempotency, backward paging) lives in the
  primitive.
  """

  alias SalixStore.{Keys, SegmentLog, ULID}

  @type cache :: SegmentLog.cache()

  @spec load(String.t(), String.t()) :: {:ok, cache()} | {:error, term()}
  def load(agent_id, session_id), do: SegmentLog.load(opts(agent_id, session_id))

  @spec append(String.t(), String.t(), cache(), [map()]) ::
          {:ok, cache(), [:committed | :duplicate]} | {:error, term()}
  def append(agent_id, session_id, %SegmentLog{} = cache, records) when is_list(records),
    do: SegmentLog.append(cache, records, opts(agent_id, session_id))

  @spec settle_replay(String.t(), String.t(), cache(), [map()]) ::
          {:ok, cache(), [:committed | :duplicate | {:error, term()}]} | {:error, term()}
  def settle_replay(agent_id, session_id, %SegmentLog{} = cache, records)
      when is_list(records),
      do: SegmentLog.settle_replay(cache, records, opts(agent_id, session_id))

  @spec fetch(String.t(), String.t(), cache(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(agent_id, session_id, %SegmentLog{} = cache, record_id),
    do: SegmentLog.fetch(cache, record_id, opts(agent_id, session_id))

  @spec tail(String.t(), String.t(), cache(), pos_integer(), String.t() | nil) ::
          {:ok, [map()], boolean(), String.t() | nil} | {:error, term()}
  def tail(agent_id, session_id, %SegmentLog{} = cache, limit, before)
      when is_integer(limit) and limit > 0,
      do: SegmentLog.tail(cache, limit, before, opts(agent_id, session_id))

  @spec bounded_tail(
          String.t(),
          String.t(),
          cache(),
          pos_integer(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, [map()], boolean()} | {:error, term()}
  def bounded_tail(
        agent_id,
        session_id,
        %SegmentLog{} = cache,
        limit,
        max_segments,
        max_raw_bytes
      ) do
    SegmentLog.bounded_tail(
      cache,
      limit,
      max_segments,
      max_raw_bytes,
      opts(agent_id, session_id)
    )
  end

  @spec all(String.t(), String.t(), cache()) :: {:ok, [map()]} | {:error, term()}
  def all(agent_id, session_id, %SegmentLog{} = cache),
    do: SegmentLog.all(cache, opts(agent_id, session_id))

  defp opts(agent_id, session_id) do
    [
      prefix: Keys.agent_external_runtime_session_segments_prefix(agent_id, session_id),
      decode_id: &decode_id/1,
      record_id: &record_id/1,
      validate: &validate_record(&1, agent_id, session_id),
      same_record?: &same_record?/2,
      parse_cursor: &parse_cursor/1,
      stale_error: :stale_external_session_segment,
      conflict_error: :external_session_record_conflict,
      decode_error: :invalid_external_session_segment
    ]
  end

  defp decode_id(name), do: if(ULID.valid?(name), do: {:ok, name}, else: :error)

  defp record_id(record), do: record["id"]

  defp parse_cursor(before), do: if(before in [nil, ""], do: nil, else: to_string(before))

  # A reconnect replays connector events under a new connector_run_id: the same
  # logical event must settle as a duplicate rather than a conflict, so that field
  # is excluded from the identity comparison for runtime events.
  defp same_record?(
         %{"type" => "runtime.event", "data" => existing_data} = existing,
         %{"type" => "runtime.event", "data" => record_data} = record
       )
       when is_map(existing_data) and is_map(record_data) do
    Map.put(existing, "data", Map.delete(existing_data, "connector_run_id")) ==
      Map.put(record, "data", Map.delete(record_data, "connector_run_id"))
  end

  defp same_record?(existing, record), do: existing == record

  defp validate_record(record, agent_id, session_id) do
    cond do
      not ULID.valid?(record["id"]) -> {:error, :invalid_external_session_record_id}
      record["agent_id"] != agent_id -> {:error, :session_agent_id_mismatch}
      record["session_id"] != session_id -> {:error, :session_id_mismatch}
      not is_binary(record["type"]) -> {:error, :invalid_external_session_record_type}
      not is_map(record["data"]) -> {:error, :invalid_external_session_record_data}
      true -> :ok
    end
  end
end
