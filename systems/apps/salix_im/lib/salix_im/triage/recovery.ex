defmodule SalixIM.Triage.Recovery do
  @moduledoc """
  Bounded durable recovery scanning for Triage Runtime.

  A cursor owns lane rotation, continuation, failure backoff, and idle cadence.
  PostgreSQL returns one page of open fences or missing sealed generations.
  Completed history stays in storage. The test backend lists and reads at most
  `budget` records. Individual deleted or malformed records are counted and skipped,
  so one poison record cannot pin the cursor on the same page forever.
  """

  alias SalixStore.CasRecord

  @type lane :: :buckets | :fences
  @opaque cursor :: %{
            lane: lane(),
            continuation: binary() | nil,
            failures: non_neg_integer(),
            idle_ms: pos_integer()
          }

  @spec cursor(keyword()) :: cursor()
  def cursor(opts \\ []) do
    idle_ms = Keyword.get(opts, :idle_ms, 5_000)

    if is_integer(idle_ms) and idle_ms > 0 do
      %{lane: :buckets, continuation: nil, failures: 0, idle_ms: idle_ms}
    else
      raise ArgumentError, "recovery idle_ms must be a positive integer"
    end
  end

  @spec focus(cursor(), lane()) :: cursor()
  def focus(%{idle_ms: idle_ms}, lane) when lane in [:buckets, :fences],
    do: %{lane: lane, continuation: nil, failures: 0, idle_ms: idle_ms}

  @spec step(binary(), pos_integer(), cursor()) ::
          {:ok, lane(), [{binary(), map()}], cursor(), non_neg_integer(), non_neg_integer()}
          | {:error, cursor(), pos_integer()}
  def step(
        namespace,
        budget,
        %{
          lane: lane,
          continuation: continuation,
          failures: failures,
          idle_ms: idle_ms
        } = cursor
      )
      when is_binary(namespace) and namespace != "" and is_integer(budget) and budget > 0 and
             lane in [:buckets, :fences] and
             (is_binary(continuation) or is_nil(continuation)) and
             is_integer(failures) and failures >= 0 and is_integer(idle_ms) and idle_ms > 0 do
    opts =
      [max_keys: budget]
      |> maybe_put_cursor(continuation)

    with {:ok, records, next_continuation, record_errors} <-
           read_page(prefix(namespace, lane), opts, budget) do
      {next_cursor, next_delay_ms} = advance(cursor, next_continuation)

      {:ok, lane, records, next_cursor, next_delay_ms, record_errors}
    else
      _list_error_or_invalid_page -> failed(cursor)
    end
  end

  def step(_namespace, _budget, cursor) when is_map(cursor), do: failed(cursor)

  def step(_namespace, _budget, _cursor),
    do: {:error, cursor(), 100}

  defp read_page(prefix, opts, budget) do
    case SalixStore.TriageRecordStore.recovery_page(prefix, opts) do
      {:ok, %{records: records, next: next} = page}
      when is_list(records) and length(records) <= budget ->
        {:ok, records, next, Map.get(page, :record_errors, 0)}

      {:error, :unsupported} ->
        with {:ok, %{objects: objects, next: next}} <-
               SalixStore.TriageRecordStore.list(prefix, opts),
             true <- is_list(objects) and length(objects) <= budget do
          {records, errors} = fetch_records(objects)
          {:ok, records, next, errors}
        end

      error ->
        error
    end
  end

  defp fetch_records(objects) do
    objects
    |> Enum.reduce({[], 0}, fn
      %{key: key}, {records, errors} when is_binary(key) ->
        case CasRecord.get(key) do
          {:ok, record} when is_map(record) -> {[{key, record} | records], errors}
          {:error, _reason} -> {records, errors + 1}
        end

      _invalid_object, {records, errors} ->
        {records, errors + 1}
    end)
    |> then(fn {records, errors} -> {Enum.reverse(records), errors} end)
  end

  defp advance(cursor, next_continuation) when is_binary(next_continuation) do
    {%{cursor | continuation: next_continuation, failures: 0}, 0}
  end

  defp advance(%{lane: :buckets} = cursor, nil) do
    {%{cursor | lane: :fences, continuation: nil, failures: 0}, 0}
  end

  defp advance(%{lane: :fences, idle_ms: idle_ms} = cursor, nil) do
    {%{cursor | lane: :buckets, continuation: nil, failures: 0}, idle_ms}
  end

  defp failed(%{failures: failures, idle_ms: idle_ms} = cursor)
       when is_integer(failures) and failures >= 0 and is_integer(idle_ms) and idle_ms > 0 do
    next_failures = min(failures + 1, 8)
    delay = min(idle_ms, 100 * Integer.pow(2, min(next_failures - 1, 6)))
    {:error, %{cursor | failures: next_failures}, delay}
  end

  defp failed(_invalid_cursor), do: {:error, cursor(), 100}

  defp prefix(namespace, :buckets),
    do: SalixStore.TriageKeys.ctl_im_triage_buckets_prefix(namespace)

  defp prefix(namespace, :fences),
    do: SalixStore.TriageKeys.ctl_im_triage_bucket_seals_prefix(namespace)

  defp maybe_put_cursor(opts, nil), do: opts

  defp maybe_put_cursor(opts, continuation),
    do: Keyword.put(opts, :continuation_token, continuation)
end
