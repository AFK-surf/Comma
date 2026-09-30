defmodule SalixStore.SegmentLog do
  @moduledoc """
  An append-only record log stored as a directory of bounded JSONL segments.

  One log is a set of S3 objects under `:prefix`, each holding a newline-terminated
  JSONL list of records sorted ascending by record id. **A segment object's
  basename is the id of the first (lowest) record it contains** — that name is the
  only index. There is no manifest object, no per-id directory and no database row;
  a domain that needs derived indexes (segment_index / seq_index / by_id) is the
  conversation shape, which this module deliberately does not serve (see
  `docs/storage-search.md`).

  ## Layout

      <prefix><encode_id(first_record_id)><suffix>

  ## Invariants (maintained by the write path; reads trust them and never verify)

    * I1 — records inside a segment are strictly ascending by id.
    * I2 — a segment's name is its minimum record id.
    * I3 — segments partition the id space: `Si` owns `[Si.first, S(i+1).first)`.

  I3 holds only while the caller's cache is fresh. This module takes no lease and
  no lock: single-writer discipline belongs to the caller. A cache that has fallen
  behind S3 routes records into the wrong segment and silently breaks I3.

  ## The id-type contract (why there is no comparator option)

  `:decode_id` and `:record_id` MUST yield the same type, and that type's Erlang
  term order MUST equal its logical order. Fixed-width ULID binaries and integers
  both satisfy this. Mixing them (binary segment names against integer record ids)
  makes every comparison silently constant: each record would open its own segment
  and `tail/4` would always come back empty. Segment names must therefore be
  fixed-width, so a LIST's lexical order matches id order.

  ## Idempotency

  Writes settle by content, not by acknowledgement: a failed PUT is followed by one
  GET, and a byte-exact match is reported as `:duplicate`. Same id with the same
  content is a duplicate; same id with different content is `:conflict_error` — a
  hard error, never a silent overwrite. Segments are created create-once
  (`if_none_match: "*"`) and grown by CAS (`if_match:`). Sealed segments are never
  rewritten here.

  ## Ordered tail batching

  A validated, strictly ordered suffix newer than the caller cache's `last_id`
  is assembled per segment in memory. Each affected existing tail segment uses
  one GET plus one conditional PUT; each new segment uses one create-only PUT.
  Replay inputs settle already-existing and genuinely missing records with one
  GET plus at most one conditional PUT per affected segment through
  `settle_replay/3`. Independent replay segments, including deterministic
  create-only chunks older than the current first segment, settle with fixed
  concurrency; records inside one segment remain one ordered read/modify/write.
  A partial batch write makes the old cache stale, so its caller must reload before
  retrying rather than appending the same ids twice. This bounded segment
  partition is modeled in
  `tla/salix/ExternalRuntimeEventSegmentPartitions.tla`.

  An exact-id recovery read uses the segment-name index to select one object and
  performs at most one GET; it never scans the whole log.

  ## Options

  Required: `:prefix`, `:decode_id`, `:record_id`, `:validate`, `:parse_cursor`.
  Optional: `:suffix` (`".jsonl"`), `:encode_id` (identity), `:same_record?`
  (`==`), `:max_records` (256), `:max_bytes` (524288), `:stale_error`,
  `:conflict_error`, `:decode_error`.
  """

  alias SalixStore.{BoundedJsonl, S3}

  @default_suffix ".jsonl"
  @default_max_records 256
  @default_max_bytes 524_288
  @replay_segment_concurrency 4

  defstruct segments: [], last_id: nil

  @type id :: term()
  @type entry :: map()
  @type segment :: %{key: String.t(), first: id()}
  @type t :: %__MODULE__{segments: [segment()], last_id: id() | nil}
  @type cache :: t()
  @type status :: :committed | :duplicate
  @type settlement_status :: status() | {:error, term()}
  @type opts :: keyword()

  @doc """
  Build the segment cache for one log: one paged LIST plus one GET of the newest
  segment (to recover `last_id`). Errors propagate untouched.
  """
  @spec load(opts()) :: {:ok, cache()} | {:error, term()}
  def load(opts) do
    with {:ok, segments} <- list_segments(opts),
         {:ok, last_id} <- last_id(segments, opts) do
      {:ok, %__MODULE__{segments: segments, last_id: last_id}}
    end
  end

  @doc """
  Append records in the given order, returning the updated cache and one status
  per record (positionally aligned). The first error halts and is returned as-is.
  """
  @spec append(cache(), [entry()], opts()) ::
          {:ok, cache(), [status()]} | {:error, term()}
  def append(%__MODULE__{} = cache, records, opts) when is_list(records) do
    if ordered_tail?(cache, records, opts) do
      append_tail(cache, records, opts)
    else
      append_one_by_one(cache, records, opts)
    end
  end

  @doc """
  Settle replay records against the current log.

  Records are returned positionally as `:committed`, `:duplicate`, or an error.
  Each affected existing segment is read once and, when it contains missing
  records, rewritten once with every missing record merged in order. This keeps
  both acknowledgement-loss replay and a genuinely missing bounded backfill
  inside the exact owner's storage-operation budget.

  Modeled in `tla/salix/ExternalRuntimeEventBatch.tla`.
  """
  @spec settle_replay(cache(), [entry()], opts()) ::
          {:ok, cache(), [settlement_status()]} | {:error, term()}
  def settle_replay(%__MODULE__{} = cache, records, opts)
      when is_list(records) and records != [] do
    get_id = fetch_opt!(opts, :record_id)
    validate = fetch_opt!(opts, :validate)

    {groups, results} =
      records
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}}, fn {record, index}, {groups, results} ->
        case validate.(record) do
          :ok ->
            case locate_segment(cache.segments, get_id.(record)) do
              nil ->
                {Map.update(groups, nil, [{index, record}], &[{index, record} | &1]), results}

              segment ->
                {Map.update(groups, segment, [{index, record}], &[{index, record} | &1]), results}
            end

          {:error, _} = error ->
            {groups, Map.put(results, index, error)}
        end
      end)

    groups
    |> Enum.sort_by(fn
      {nil, _entries} -> {0, nil}
      {segment, _entries} -> {1, segment.first}
    end)
    |> settle_replay_groups(cache, opts)
    |> Enum.reduce({cache, results}, fn {next, entries, statuses}, {cache, results} ->
      {merge_settlement_cache(cache, next), put_entry_results(results, entries, statuses)}
    end)
    |> then(fn {cache, results} ->
      statuses =
        records
        |> Enum.with_index()
        |> Enum.map(fn {_record, index} -> Map.fetch!(results, index) end)

      {:ok, cache, statuses}
    end)
  end

  def settle_replay(%__MODULE__{} = cache, [], _opts), do: {:ok, cache, []}

  @doc "Read one exact record from the segment index, with at most one object GET."
  @spec fetch(cache(), id(), opts()) :: {:ok, entry()} | {:error, term()}
  def fetch(%__MODULE__{segments: segments}, id, opts) do
    get_id = fetch_opt!(opts, :record_id)

    with %{key: key} <- locate_segment(segments, id),
         {:ok, records} <- read_segment(key, opts),
         %{} = record <- Enum.find(records, &(get_id.(&1) == id)) do
      {:ok, record}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp settle_replay_groups(groups, cache, opts) do
    context = SystemsObservability.Context.capture()

    groups
    |> Enum.flat_map(&partition_replay_group(&1, opts))
    |> Task.async_stream(
      fn group ->
        SystemsObservability.Context.run(context, fn ->
          settle_replay_group(cache, group, opts)
        end)
      end,
      max_concurrency: @replay_segment_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
    end)
  end

  defp partition_replay_group({nil, entries}, opts) do
    entries = Enum.sort_by(entries, &elem(&1, 0))
    partition_new_segment_entries(entries, Enum.map(entries, &elem(&1, 1)), opts)
  end

  defp partition_replay_group(group, _opts), do: [group]

  defp partition_new_segment_entries([], [], _opts), do: []

  defp partition_new_segment_entries(entries, records, opts) do
    {chunk, rest} = take_tail_segment([], records, opts)
    {chunk_entries, remaining_entries} = Enum.split(entries, length(chunk))

    [{nil, chunk_entries} | partition_new_segment_entries(remaining_entries, rest, opts)]
  end

  defp settle_replay_group(cache, {nil, entries}, opts) do
    entries = Enum.sort_by(entries, &elem(&1, 0))

    {:ok, next, statuses} =
      settle_new_tail_segments(cache, Enum.map(entries, &elem(&1, 1)), opts)

    {%{next | last_id: max_id(cache.last_id, next.last_id)}, entries, statuses}
  end

  defp settle_replay_group(cache, {segment, entries}, opts) do
    entries = Enum.sort_by(entries, &elem(&1, 0))
    {:ok, next, statuses} = settle_replay_segment(cache, segment, entries, opts)
    {next, entries, statuses}
  end

  defp merge_settlement_cache(cache, next) do
    segments =
      (cache.segments ++ next.segments)
      |> Map.new(&{&1.first, &1})
      |> Map.values()
      |> Enum.sort_by(& &1.first)

    %{cache | segments: segments, last_id: max_id(cache.last_id, next.last_id)}
  end

  defp settle_replay_segment(cache, segment, entries, opts) do
    get_id = fetch_opt!(opts, :record_id)
    same_record? = Keyword.get(opts, :same_record?, &Kernel.==/2)
    entries = Enum.sort_by(entries, &elem(&1, 0))

    with {:ok, %{body: body, etag: etag}} <- S3.get(segment.key),
         {:ok, existing_records} <- decode(body, opts) do
      {updated, inserted, statuses} =
        Enum.reduce(entries, {existing_records, [], %{}}, fn {entry_index, record},
                                                             {current, inserted, statuses} ->
          id = get_id.(record)
          index = insertion_index(current, id, get_id)
          existing = Enum.at(current, index)

          cond do
            not is_map(existing) or get_id.(existing) != id ->
              {List.insert_at(current, index, record), [{entry_index, record} | inserted],
               statuses}

            same_record?.(existing, record) ->
              {current, inserted, Map.put(statuses, entry_index, :duplicate)}

            true ->
              {current, inserted, Map.put(statuses, entry_index, {:error, conflict_error(opts)})}
          end
        end)

      case inserted do
        [] ->
          {:ok, cache, entry_statuses(entries, statuses)}

        [_ | _] ->
          case put_exact(segment.key, encode(updated), if_match: etag) do
            {:ok, status} ->
              statuses =
                Enum.reduce(inserted, statuses, fn {entry_index, _record}, statuses ->
                  Map.put(statuses, entry_index, status)
                end)

              cache =
                Enum.reduce(inserted, cache, fn {_entry_index, record}, cache ->
                  %{cache | last_id: max_id(cache.last_id, get_id.(record))}
                end)

              {:ok, cache, entry_statuses(entries, statuses)}

            {:error, reason} ->
              statuses =
                Enum.reduce(inserted, statuses, fn {entry_index, _record}, statuses ->
                  Map.put(statuses, entry_index, {:error, reason})
                end)

              {:ok, cache, entry_statuses(entries, statuses)}
          end
      end
    else
      {:error, reason} ->
        {:ok, cache, List.duplicate({:error, reason}, length(entries))}
    end
  end

  defp entry_statuses(entries, statuses),
    do: Enum.map(entries, fn {index, _record} -> Map.fetch!(statuses, index) end)

  defp put_entry_results(results, entries, statuses) do
    Enum.zip(entries, statuses)
    |> Enum.reduce(results, fn {{index, _record}, status}, results ->
      Map.put(results, index, status)
    end)
  end

  defp append_one_by_one(cache, records, opts) do
    Enum.reduce_while(records, {:ok, cache, []}, fn record, {:ok, cache, statuses} ->
      case append_one(cache, record, opts) do
        {:ok, cache, status} -> {:cont, {:ok, cache, [status | statuses]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cache, statuses} -> {:ok, cache, Enum.reverse(statuses)}
      {:error, _} = error -> error
    end
  end

  defp ordered_tail?(_cache, [], _opts), do: false

  defp ordered_tail?(cache, records, opts) do
    get_id = fetch_opt!(opts, :record_id)
    validate = fetch_opt!(opts, :validate)
    ids = Enum.map(records, get_id)

    Enum.all?(records, &(validate.(&1) == :ok)) and
      ids == Enum.sort(ids) and
      MapSet.size(MapSet.new(ids)) == length(ids) and
      (is_nil(cache.last_id) or hd(ids) > cache.last_id)
  end

  # A normal forward append owns an ordered suffix of the log. Build each
  # affected segment in memory, then issue one conditional object write for
  # that segment instead of one GET/PUT pair per record. Replay backfills use
  # settle_replay/3 to preserve the same per-segment bound. Direct generic
  # retries keep conservative record-at-a-time settlement. The external runtime
  # use of this boundary is modeled in
  # tla/salix/ExternalRuntimeEventBatch.tla.
  defp append_tail(%__MODULE__{segments: []} = cache, records, opts),
    do: append_new_tail_segments(cache, records, opts)

  defp append_tail(cache, records, opts) do
    segment = List.last(cache.segments)
    get_id = fetch_opt!(opts, :record_id)

    with {:ok, %{body: body, etag: etag}} <- S3.get(segment.key),
         {:ok, existing} <- decode(body, opts),
         true <- get_id.(hd(records)) > get_id.(List.last(existing)) do
      {current, rest} = take_tail_segment(existing, records, opts)
      added = length(current) - length(existing)

      with {:ok, cache, status} <-
             put_tail_segment(cache, segment, current, etag, added, opts),
           {:ok, cache, statuses} <- append_new_tail_segments(cache, rest, opts) do
        {:ok, cache, List.duplicate(status, added) ++ statuses}
      end
    else
      false -> {:error, stale_error(opts)}
      {:error, _} = error -> error
    end
  end

  defp take_tail_segment(existing, records, opts) do
    Enum.reduce_while(records, {existing, []}, fn record, {current, _rest} ->
      if rollover?(current, encode(current), opts) do
        {:halt, {current, Enum.drop(records, length(current) - length(existing))}}
      else
        {:cont, {current ++ [record], []}}
      end
    end)
  end

  defp put_tail_segment(cache, _segment, _records, _etag, 0, _opts),
    do: {:ok, cache, :committed}

  defp put_tail_segment(cache, segment, records, etag, _added, opts) do
    case put_exact(segment.key, encode(records), if_match: etag) do
      {:ok, status} ->
        {:ok,
         %{
           cache
           | last_id: max_id(cache.last_id, fetch_opt!(opts, :record_id).(List.last(records)))
         }, status}

      {:error, :precondition_failed} ->
        {:error, stale_error(opts)}

      {:error, _} = error ->
        error
    end
  end

  defp append_new_tail_segments(cache, [], _opts), do: {:ok, cache, []}

  defp append_new_tail_segments(cache, records, opts) do
    case put_new_tail_segment(cache, records, opts) do
      {:ok, cache, statuses, rest} ->
        with {:ok, cache, remaining_statuses} <- append_new_tail_segments(cache, rest, opts) do
          {:ok, cache, statuses ++ remaining_statuses}
        end

      {:error, reason, _count, _rest} ->
        {:error, reason}
    end
  end

  defp settle_new_tail_segments(cache, [], _opts), do: {:ok, cache, []}

  defp settle_new_tail_segments(cache, records, opts) do
    case put_new_tail_segment(cache, records, opts) do
      {:ok, cache, statuses, rest} ->
        {:ok, cache, remaining_statuses} = settle_new_tail_segments(cache, rest, opts)
        {:ok, cache, statuses ++ remaining_statuses}

      {:error, reason, count, rest} ->
        {:ok, cache, remaining_statuses} = settle_new_tail_segments(cache, rest, opts)
        {:ok, cache, List.duplicate({:error, reason}, count) ++ remaining_statuses}
    end
  end

  defp put_new_tail_segment(cache, records, opts) do
    {chunk, rest} = take_tail_segment([], records, opts)
    first = hd(chunk)
    get_id = fetch_opt!(opts, :record_id)
    id = get_id.(first)
    key = segment_key(id, opts)

    case put_exact(key, encode(chunk), if_none_match: "*") do
      {:ok, status} ->
        segment = %{key: key, first: id}

        cache = %{
          cache
          | segments: Enum.sort_by([segment | cache.segments], & &1.first),
            last_id: max_id(cache.last_id, get_id.(List.last(chunk)))
        }

        {:ok, cache, List.duplicate(status, length(chunk)), rest}

      {:error, :precondition_failed} ->
        {:error, stale_error(opts), length(chunk), rest}

      {:error, reason} ->
        {:error, reason, length(chunk), rest}
    end
  end

  @doc """
  Read the newest `limit` records older than the `before` cursor, walking segments
  from newest to oldest and skipping whole segments that start at or after the
  cursor. Returns `{:ok, records, has_more?, next_before}`; the cursor bound is
  exclusive, so consecutive pages neither repeat nor skip a record.
  """
  @spec tail(cache(), pos_integer(), term(), opts()) ::
          {:ok, [entry()], boolean(), id() | nil} | {:error, term()}
  def tail(%__MODULE__{segments: segments}, limit, before, opts)
      when is_integer(limit) and limit > 0 do
    get_id = fetch_opt!(opts, :record_id)
    before = fetch_opt!(opts, :parse_cursor).(before)

    segments
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, records} ->
      if before && segment.first >= before do
        {:cont, {:ok, records}}
      else
        case read_segment(segment.key, opts) do
          {:ok, segment_records} ->
            eligible =
              if before,
                do: Enum.filter(segment_records, &(get_id.(&1) < before)),
                else: segment_records

            combined = eligible ++ records

            if length(combined) > limit do
              {:halt, {:ok, Enum.take(combined, -limit), true}}
            else
              {:cont, {:ok, combined}}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end
    end)
    |> case do
      {:ok, records} ->
        {:ok, records, false, nil}

      {:ok, records, has_more} ->
        next_before = if has_more and records != [], do: get_id.(hd(records))
        {:ok, records, has_more, next_before}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Read a fixed-watermark tail without exceeding the supplied storage budget.

  The cache's `last_id` is the inclusive watermark. Each selected object is
  HEADed before a range GET, so one oversized segment is rejected before its
  body is loaded. `truncated?` is true when older records exist outside the
  record, segment, or raw-byte budget.
  """
  @spec bounded_tail(cache(), pos_integer(), pos_integer(), pos_integer(), opts()) ::
          {:ok, [entry()], boolean()} | {:error, term()}
  def bounded_tail(
        %__MODULE__{segments: segments, last_id: watermark},
        limit,
        max_segments,
        max_raw_bytes,
        opts
      )
      when is_integer(limit) and limit > 0 and is_integer(max_segments) and
             max_segments > 0 and is_integer(max_raw_bytes) and max_raw_bytes > 0 do
    get_id = fetch_opt!(opts, :record_id)

    segments
    |> Enum.reverse()
    |> bounded_tail_segments(
      watermark,
      limit,
      max_segments,
      max_raw_bytes,
      get_id,
      opts,
      [],
      0,
      0
    )
  end

  @doc "Read every record, oldest first. One GET per segment; the first read error halts."
  @spec all(cache(), opts()) :: {:ok, [entry()]} | {:error, term()}
  def all(%__MODULE__{segments: segments}, opts) do
    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, records} ->
      case read_segment(segment.key, opts) do
        {:ok, segment_records} -> {:cont, {:ok, records ++ segment_records}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp append_one(cache, record, opts) do
    with :ok <- fetch_opt!(opts, :validate).(record) do
      id = fetch_opt!(opts, :record_id).(record)

      case locate_segment(cache.segments, id) do
        nil -> create_segment(cache, record, opts)
        segment -> insert_record(cache, segment, record, opts)
      end
    end
  end

  defp create_segment(cache, record, opts) do
    id = fetch_opt!(opts, :record_id).(record)
    key = segment_key(id, opts)

    case put_exact(key, encode([record]), if_none_match: "*") do
      {:ok, status} ->
        segment = %{key: key, first: id}

        segments =
          [segment | cache.segments] |> Enum.uniq_by(& &1.key) |> Enum.sort_by(& &1.first)

        {:ok, %{cache | segments: segments, last_id: max_id(cache.last_id, id)}, status}

      {:error, :precondition_failed} ->
        {:error, stale_error(opts)}

      {:error, _} = error ->
        error
    end
  end

  defp insert_record(cache, segment, record, opts) do
    get_id = fetch_opt!(opts, :record_id)
    same_record? = Keyword.get(opts, :same_record?, &Kernel.==/2)
    id = get_id.(record)

    with {:ok, %{body: body, etag: etag}} <- S3.get(segment.key),
         {:ok, records} <- decode(body, opts) do
      index = insertion_index(records, id, get_id)
      existing = Enum.at(records, index)

      if is_map(existing) and get_id.(existing) == id do
        if same_record?.(existing, record),
          do: {:ok, %{cache | last_id: max_id(cache.last_id, id)}, :duplicate},
          else: {:error, conflict_error(opts)}
      else
        if index == length(records) and rollover?(records, body, opts) do
          create_segment(cache, record, opts)
        else
          updated = List.insert_at(records, index, record)

          case put_exact(segment.key, encode(updated), if_match: etag) do
            {:ok, _} ->
              {:ok, %{cache | last_id: max_id(cache.last_id, id)}, :committed}

            {:error, :precondition_failed} ->
              {:error, stale_error(opts)}

            {:error, _} = error ->
              error
          end
        end
      end
    end
  end

  defp list_segments(opts) do
    prefix = fetch_opt!(opts, :prefix)
    suffix = suffix(opts)
    decode_id = fetch_opt!(opts, :decode_id)

    with {:ok, objects} <- S3.list_all(prefix) do
      {:ok,
       objects
       |> Enum.filter(&String.ends_with?(&1.key, suffix))
       |> Enum.flat_map(fn object ->
         name =
           object.key |> String.replace_prefix(prefix, "") |> String.trim_trailing(suffix)

         case decode_id.(name) do
           {:ok, id} -> [%{key: object.key, first: id}]
           :error -> []
         end
       end)
       |> Enum.sort_by(& &1.first)}
    end
  end

  defp last_id([], _opts), do: {:ok, nil}

  defp last_id(segments, opts) do
    get_id = fetch_opt!(opts, :record_id)

    with {:ok, records} <-
           segments |> List.last() |> Map.fetch!(:key) |> read_segment(opts) do
      {:ok, records |> List.last() |> then(&(&1 && get_id.(&1)))}
    end
  end

  defp locate_segment(segments, id) do
    segments
    |> Enum.reverse()
    |> Enum.find(&(&1.first <= id))
  end

  defp insertion_index(records, id, get_id) do
    records
    |> List.to_tuple()
    |> insertion_index(id, 0, length(records), get_id)
  end

  defp insertion_index(_records, _id, low, low, _get_id), do: low

  defp insertion_index(records, id, low, high, get_id) do
    middle = div(low + high, 2)

    if get_id.(elem(records, middle)) < id,
      do: insertion_index(records, id, middle + 1, high, get_id),
      else: insertion_index(records, id, low, middle, get_id)
  end

  defp read_segment(key, opts) do
    with {:ok, %{body: body}} <- S3.get(key), do: decode(body, opts)
  end

  defp bounded_tail_segments(
         [],
         _watermark,
         _limit,
         _max_segments,
         _max_raw_bytes,
         _get_id,
         _opts,
         records,
         _segment_count,
         _raw_bytes
       ),
       do: {:ok, records, false}

  defp bounded_tail_segments(
         remaining,
         _watermark,
         _limit,
         max_segments,
         _max_raw_bytes,
         _get_id,
         _opts,
         records,
         max_segments,
         _raw_bytes
       )
       when remaining != [],
       do: {:ok, records, true}

  defp bounded_tail_segments(
         [%{key: key} | rest],
         watermark,
         limit,
         max_segments,
         max_raw_bytes,
         get_id,
         opts,
         records,
         segment_count,
         raw_bytes
       ) do
    with {:ok, %{size: size}} when is_integer(size) and size >= 0 <- S3.head(key) do
      cond do
        size > max_raw_bytes ->
          {:error, :bounded_segment_too_large}

        raw_bytes + size > max_raw_bytes ->
          {:ok, records, true}

        size == 0 ->
          {:error, decode_error(opts)}

        true ->
          case S3.get(key, range: {0, size}) do
            {:ok, %{body: body}} when byte_size(body) == size ->
              with {:ok, segment_records} <- decode(body, opts) do
                eligible =
                  if watermark,
                    do: Enum.filter(segment_records, &(get_id.(&1) <= watermark)),
                    else: []

                combined = eligible ++ records

                if length(combined) > limit do
                  {:ok, Enum.take(combined, -limit), true}
                else
                  bounded_tail_segments(
                    rest,
                    watermark,
                    limit,
                    max_segments,
                    max_raw_bytes,
                    get_id,
                    opts,
                    combined,
                    segment_count + 1,
                    raw_bytes + size
                  )
                end
              end

            {:ok, _oversized_or_invalid} ->
              {:error, :bounded_segment_changed}

            {:error, _} = error ->
              error
          end
      end
    else
      {:error, _} = error -> error
      _invalid -> {:error, :bounded_segment_metadata_invalid}
    end
  end

  # Settle by content: any PUT failure is followed by one GET, and a byte-exact
  # match counts as an already-landed write.
  defp put_exact(key, body, put_opts) do
    case S3.put(key, body, put_opts) do
      {:ok, _} ->
        {:ok, :committed}

      {:error, _} = error ->
        if match?({:ok, %{body: ^body}}, S3.get(key)), do: {:ok, :duplicate}, else: error
    end
  end

  defp rollover?(records, body, opts) do
    length(records) >= Keyword.get(opts, :max_records, @default_max_records) or
      byte_size(body) >= Keyword.get(opts, :max_bytes, @default_max_bytes)
  end

  defp segment_key(id, opts) do
    encode_id = Keyword.get(opts, :encode_id, & &1)
    fetch_opt!(opts, :prefix) <> encode_id.(id) <> suffix(opts)
  end

  # Not BoundedJsonl.encode/1: that one emits "\n" for an empty list where this
  # protocol emits "". The byte image is compared by put_exact, so the encoder is
  # part of the contract.
  defp encode(records), do: Enum.map_join(records, "", &(Jason.encode!(&1) <> "\n"))

  defp decode(body, opts), do: BoundedJsonl.decode_strict(body, decode_error(opts))

  defp max_id(nil, right), do: right
  defp max_id(left, right), do: max(left, right)

  defp suffix(opts), do: Keyword.get(opts, :suffix, @default_suffix)
  defp stale_error(opts), do: Keyword.get(opts, :stale_error, :stale_segment)
  defp conflict_error(opts), do: Keyword.get(opts, :conflict_error, :record_conflict)
  defp decode_error(opts), do: Keyword.get(opts, :decode_error, :invalid_segment)

  defp fetch_opt!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "SalixStore.SegmentLog requires the #{inspect(key)} option"
    end
  end
end
