defmodule SalixStore.Timers do
  @moduledoc """
  Durable one-shot timer notification markers.

  Timer records are indexed by minute bucket so the cluster timer singleton can
  sweep due work without scanning the whole store. The bucket is only a time
  index; each timer record carries its own `timer_id`, delivery source id, and
  payload.
  """

  alias SalixStore.{Ids, Keys, S3}

  @type timer_record :: %{optional(String.t()) => term()}

  # One probe page is enough to see the oldest buckets, and the per-pass bucket
  # cap keeps a long backlog from turning one catch-up into an unbounded sweep:
  # each pass clears what it takes, so the next pass sees the next oldest.
  @default_stranded_probe_keys 200
  @default_stranded_limit 10

  @doc "Register a one-shot timer notification."
  @spec register(map()) :: :ok | {:error, term()}
  def register(attrs) when is_map(attrs) do
    attrs = stringify(attrs)

    with {:ok, timer_id} <- required_string(attrs, "timer_id"),
         {:ok, agent_id} <- required_string(attrs, "agent_id"),
         {:ok, session_id} <- required_string(attrs, "session_id"),
         true <- Ids.valid_session_id?(session_id),
         {:ok, kind} <- required_string(attrs, "kind"),
         {:ok, deadline_ms} <- required_integer(attrs, "deadline_ms"),
         {:ok, source_message_id} <- required_string(attrs, "source_message_id"),
         {:ok, payload} <- required_map(attrs, "payload") do
      bucket = minute_bucket(deadline_ms)

      record = %{
        "timer_id" => timer_id,
        "kind" => kind,
        "agent_id" => agent_id,
        "session_id" => session_id,
        "deadline_ms" => deadline_ms,
        "source_message_id" => source_message_id,
        "payload" => payload
      }

      case S3.put(Keys.timer(agent_id, session_id, timer_id, bucket), Jason.encode!(record)) do
        {:ok, _} -> :ok
        other -> other
      end
    else
      false -> {:error, {:invalid_timer, "session_id is invalid"}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Due timer notification records in a minute bucket.

  `:limit` bounds the read: at most that many objects are listed and hydrated,
  so a caller working through a backlog can cap what one pass costs it. Without
  it the whole bucket is read, which is what the firing tick wants — it sweeps
  the same few buckets every few seconds and must not leave part of a due
  minute for later.
  """
  @spec sweep(integer(), integer(), keyword()) :: {:ok, [timer_record()]} | {:error, term()}
  def sweep(minute_bucket, now_ms \\ System.system_time(:millisecond), opts \\ []) do
    case list_bucket(minute_bucket, Keyword.get(opts, :limit)) do
      {:ok, objs} ->
        due =
          objs
          |> Enum.flat_map(&hydrate/1)
          |> Enum.filter(fn record ->
            deadline = record["deadline_ms"]
            is_integer(deadline) and deadline <= now_ms
          end)

        {:ok, due}

      other ->
        other
    end
  end

  defp list_bucket(minute_bucket, nil), do: S3.list_all(Keys.timer_minute_prefix(minute_bucket))

  defp list_bucket(minute_bucket, limit) when is_integer(limit) and limit > 0 do
    case S3.list(Keys.timer_minute_prefix(minute_bucket), max_keys: limit) do
      {:ok, %{objects: objects}} -> {:ok, Enum.take(objects, limit)}
      other -> other
    end
  end

  defp list_bucket(_minute_bucket, _limit), do: {:ok, []}

  @doc """
  Bucket numbers still present in the store that are older than
  `before_bucket`, oldest first and at most `:limit` of them.

  One bounded, delimited LIST: every key under a bucket collapses into that
  bucket's common prefix, so the page size bounds the work no matter how many
  markers a bucket holds. Bucket segments are same-width decimal minutes for
  any clock this system will see, so the store's lexicographic key order is
  their numeric order and the first page holds the oldest buckets — the only
  ones that can be stranded. Nothing here is durable state, which is the point:
  the sweeper's catch-up needs no cursor to resume, because the store itself
  says what is left.
  """
  @spec stranded_buckets(integer(), keyword()) :: {:ok, [integer()]} | {:error, term()}
  def stranded_buckets(before_bucket, opts \\ []) when is_integer(before_bucket) do
    probe_keys = Keyword.get(opts, :probe_keys, @default_stranded_probe_keys)
    limit = Keyword.get(opts, :limit, @default_stranded_limit)
    after_cursor = Keyword.get(opts, :after)

    case S3.list(Keys.timers_prefix(),
           delimiter: "/",
           max_keys: probe_keys,
           start_after: after_cursor
         ) do
      {:ok, %{common_prefixes: prefixes}} ->
        {:ok,
         prefixes
         |> Enum.flat_map(&bucket_from_prefix/1)
         |> Enum.filter(&(&1 < before_bucket))
         |> Enum.sort()
         |> Enum.take(limit)}

      {:error, _} = error ->
        error
    end
  end

  @doc "Clear a fired timer marker."
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(key), do: S3.delete(key)

  @doc "Minute bucket integer for a unix-ms timestamp."
  def minute_bucket(ms), do: div(div(ms, 1000), 60)

  @doc """
  A `:after` cursor that sits past every marker in `minute_bucket` and before
  the next bucket.

  Replacing the trailing slash with its next byte is the same StartAfter trick
  the conversation page listing uses: it clears the bucket's own objects
  without stepping over the bucket after it, and it also handles
  S3-compatible backends that re-emit a CommonPrefix equal to StartAfter.
  """
  @spec bucket_cursor(integer()) :: String.t()
  def bucket_cursor(minute_bucket) when is_integer(minute_bucket),
    do: String.replace_suffix(Keys.timer_minute_prefix(minute_bucket), "/", "0")

  defp bucket_from_prefix(prefix) do
    prefix
    |> String.replace_prefix(Keys.timers_prefix(), "")
    |> String.replace_suffix("/", "")
    |> Integer.parse()
    |> case do
      {bucket, ""} -> [bucket]
      _other -> []
    end
  end

  defp hydrate(%{key: key}) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, record} when is_map(record) ->
            [Map.put(record, "key", key)]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp required_string(attrs, key) do
    case attrs[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_timer, "#{key} is required"}}
    end
  end

  defp required_integer(attrs, key) do
    case attrs[key] do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_timer, "#{key} must be an integer"}}
    end
  end

  defp required_map(attrs, key) do
    case attrs[key] do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, {:invalid_timer, "#{key} must be a map"}}
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
