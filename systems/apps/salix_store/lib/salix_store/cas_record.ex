defmodule SalixStore.CasRecord do
  @moduledoc "Small JSON-record CAS primitive for domain owners."

  alias SalixStore.{S3, TriageRecordStore}
  @attempts 8

  def get(key, invalid \\ :invalid_record, opts \\ []) do
    with {:ok, value, _etag} <- read(key, invalid, opts), do: {:ok, value}
  end

  @doc "Reads and decodes one JSON record without accepting a body above `max_bytes`."
  def get_bounded(key, max_bytes, invalid \\ :invalid_record)

  def get_bounded(key, max_bytes, invalid)
      when is_integer(max_bytes) and max_bytes > 0 do
    case bounded_store_get(key, max_bytes) do
      {:ok, %{body: body, size: size}} ->
        case Jason.decode(body) do
          {:ok, value} when is_map(value) -> {:ok, value, size}
          _invalid -> {:error, invalid, size}
        end

      {:error, :too_large} ->
        # The ranged compatibility read consumed at most one byte beyond the
        # budget. Charging the whole remaining budget makes callers stop and
        # keeps aggregate work bounded across subsequent records.
        {:error, :too_large, max_bytes}

      {:error, reason} ->
        {:error, reason, 0}
    end
  end

  def get_bounded(_key, _max_bytes, invalid), do: {:error, invalid, 0}

  @doc """
  Reads several Triage records in one call for callers that then consume them
  with `from_prefetch/3`. Returns an empty map when the backend cannot batch or
  the read fails, so every record falls back to `get_bounded/3`.
  """
  def prefetch_bounded([], _max_total_bytes), do: %{}

  def prefetch_bounded(keys, max_total_bytes) when is_list(keys) do
    if Enum.all?(keys, &TriageRecordStore.owned?/1) do
      case TriageRecordStore.get_bounded_many(keys, max_total_bytes) do
        {:ok, results} -> results
        _unsupported_or_failed -> %{}
      end
    else
      %{}
    end
  end

  @doc """
  The `get_bounded/3` result for `key` with `max_bytes`, taken from a
  `prefetch_bounded/2` map that was read with a total of at least `max_bytes`.
  A key the prefetch did not return is read now.
  """
  def from_prefetch(prefetched, key, max_bytes, invalid \\ :invalid_record)

  def from_prefetch(prefetched, key, max_bytes, invalid)
      when is_integer(max_bytes) and max_bytes > 0 do
    case Map.fetch(prefetched, key) do
      {:ok, {:ok, %{body: body, size: size}}} when size <= max_bytes ->
        case Jason.decode(body) do
          {:ok, value} when is_map(value) -> {:ok, value, size}
          _invalid -> {:error, invalid, size}
        end

      {:ok, {:ok, _too_large_for_remaining}} ->
        {:error, :too_large, max_bytes}

      {:ok, {:error, :too_large}} ->
        {:error, :too_large, max_bytes}

      {:ok, {:error, reason}} ->
        {:error, reason, 0}

      :error ->
        get_bounded(key, max_bytes, invalid)
    end
  end

  def from_prefetch(_prefetched, key, max_bytes, invalid),
    do: get_bounded(key, max_bytes, invalid)

  def create(key, value, opts \\ []) when is_map(value) do
    with :ok <- validate(value, opts[:validate]) do
      case store(key).put(key, Jason.encode!(value), if_none_match: "*") do
        {:ok, _result} -> {:ok, value}
        {:error, :precondition_failed} -> {:error, :exists}
        {:error, _} = error -> error
      end
    end
  end

  def ensure(key, build, opts \\ []) do
    update(
      key,
      fn
        nil -> build.()
        current -> {:unchanged, current}
      end,
      opts
    )
  end

  def update(key, fun, opts \\ []), do: update(key, fun, opts, opts[:attempts] || @attempts)
  defp update(_key, _fun, _opts, 0), do: {:error, :conflict}

  defp update(key, fun, opts, attempts) do
    invalid = opts[:invalid] || :invalid_record
    create? = opts[:create] != false

    with :ok <- guard(opts[:guard]) do
      case read(key, invalid, opts) do
        {:ok, current, etag} ->
          with :ok <- validate(current, opts[:validate]) do
            commit(key, current, etag, fun, opts, attempts)
          end

        {:error, :not_found} when create? ->
          commit(key, nil, :create, fun, opts, attempts)

        {:error, _} = error ->
          error
      end
    end
  end

  defp commit(key, current, etag, fun, opts, attempts) do
    case fun.(current) do
      {:unchanged, value} ->
        {:ok, value}

      {:error, _} = error ->
        error

      value when is_map(value) ->
        with :ok <- validate(value, opts[:validate]) do
          condition = if etag == :create, do: [if_none_match: "*"], else: [if_match: etag]

          case (opts[:store] || store(key)).put(key, Jason.encode!(value), condition) do
            {:ok, _} ->
              {:ok, value}

            {:error, :precondition_failed} ->
              update(key, fun, opts, attempts - 1)

            {:error, {:ambiguous, _}} ->
              case get(key, opts[:invalid] || :invalid_record, opts) do
                {:ok, ^value} -> {:ok, value}
                _ -> update(key, fun, opts, attempts - 1)
              end

            {:error, _} = error ->
              error
          end
        end

      _ ->
        {:error, opts[:invalid] || :invalid_record}
    end
  end

  defp read(key, invalid, opts) do
    with {:ok, %{body: body, etag: etag}} <- (opts[:store] || store(key)).get(key),
         {:ok, value} when is_map(value) <- Jason.decode(body) do
      {:ok, value, etag}
    else
      {:error, _} = error -> error
      _ -> {:error, invalid}
    end
  end

  defp bounded_store_get(key, max_bytes) do
    store = store(key)

    if function_exported?(store, :get_bounded, 2) do
      apply(store, :get_bounded, [key, max_bytes])
    else
      case store.get(key, range: {0, max_bytes + 1}) do
        {:ok, %{body: body} = result} when byte_size(body) <= max_bytes ->
          {:ok, Map.put(result, :size, byte_size(body))}

        {:ok, %{body: body}} when byte_size(body) > max_bytes ->
          {:error, :too_large}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp validate(_value, nil), do: :ok
  defp validate(value, fun), do: fun.(value)

  defp guard(nil), do: :ok
  defp guard(fun) when is_function(fun, 0), do: fun.()

  defp store(key) do
    if TriageRecordStore.owned?(key), do: TriageRecordStore, else: S3
  end
end
