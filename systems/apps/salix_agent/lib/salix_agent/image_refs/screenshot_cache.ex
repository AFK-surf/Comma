defmodule SalixAgent.ImageRefs.ScreenshotCache do
  @moduledoc """
  A node-local cache of the device screenshots that request builds inline.

  Every request of a reply inlines each of the reply's screenshots again
  (`SalixAgent.ImageRefs`). Without this cache each build reads every one of
  them from the device, one after another, and the device deletes a screenshot
  15 minutes after capture. When one expires, the request changes where that
  image was, and the provider's prompt cache misses from there on, on every
  following request of the reply.

  A screenshot's content never changes: the connector names each capture with
  a fresh random name and creates the file exclusively. So an entry stays
  correct for as long as it is kept. Entries are keyed by agent, session,
  device, environment and file name, so a session reads only what it read
  itself.

  Only results that do not change are kept: a prepared image, and the note
  for an expired screenshot. A failure that can pass (an offline device, a
  timeout) is not kept, and the next build asks the device again.

  The table holds at most `max_bytes/0`. Past that, the least recently used
  entries go first, and a build that misses reads the device as it would
  without the cache. There is no timer: a finished reply's screenshots are no
  longer asked for, and newer entries push them out.
  """

  @table __MODULE__
  @order __MODULE__.Order
  @bytes_key :bytes
  @default_max_bytes 128 * 1024 * 1024
  # Per entry, so a key and its bookkeeping count against the budget.
  @entry_overhead 256

  @doc "Creates the cache tables. The application owns them."
  def create_table do
    SystemsRuntime.ETS.new(@table, [:named_table, :public, :set, read_concurrency: true])
    SystemsRuntime.ETS.new(@order, [:named_table, :public, :ordered_set])
    SystemsRuntime.ETS.insert(@table, {@bytes_key, 0})
  end

  @doc "The byte budget of the cache on this node."
  def max_bytes,
    do: SystemsRuntime.get_env(:salix_agent, :screenshot_cache_max_bytes, @default_max_bytes)

  @doc """
  The resolved result for `key`, from the cache or from `resolve`.

  `resolve` answers `{:ok, blocks}` or `{:error, reason}`. With no `key` (a
  caller that names no session) nothing is kept.
  """
  def fetch(nil, resolve), do: resolve.()

  def fetch(key, resolve) do
    case lookup(key) do
      {:ok, result} ->
        result

      :miss ->
        result = resolve.()
        if keep?(result), do: put(key, result)
        result
    end
  end

  @doc "The cache key of a device screenshot that `ctx` reads, or nil."
  def key(ctx, device_id, environment_id, path) do
    case {ctx_value(ctx, :agent_id), ctx_value(ctx, :session_id)} do
      {agent, session} when is_binary(agent) and is_binary(session) ->
        {agent, session, device_id, environment_id, path}

      _ ->
        nil
    end
  end

  defp keep?({:ok, _blocks}), do: true
  defp keep?({:error, :screenshot_expired}), do: true
  defp keep?(_result), do: false

  defp lookup(key) do
    case SystemsRuntime.ETS.lookup(@table, key) do
      [{^key, result, _bytes, order}] ->
        touch(key, order)
        {:ok, result}

      [] ->
        :miss
    end
  end

  # The entry becomes the most recently used. A race with an eviction can only
  # leave an order row that names nothing, which an eviction then skips.
  defp touch(key, old) do
    new = SystemsRuntime.Proc.unique_integer([:monotonic, :positive])

    if SystemsRuntime.ETS.update_element(@table, key, {4, new}) do
      SystemsRuntime.ETS.insert(@order, {new, key})
      SystemsRuntime.ETS.delete(@order, old)
    end
  end

  defp put(key, result) do
    bytes = size(result) + @entry_overhead

    if bytes <= div(max_bytes(), 4) do
      order = SystemsRuntime.Proc.unique_integer([:monotonic, :positive])

      if SystemsRuntime.ETS.insert_new(@table, {key, result, bytes, order}) do
        SystemsRuntime.ETS.insert(@order, {order, key})
        total = SystemsRuntime.ETS.update_counter(@table, @bytes_key, bytes)
        evict(total)
      end
    end

    :ok
  end

  defp evict(total) do
    if total > max_bytes() do
      case SystemsRuntime.ETS.first(@order) do
        :"$end_of_table" ->
          :ok

        order ->
          evict(remove(order) || current_bytes())
      end
    else
      :ok
    end
  end

  # Removes the oldest order row and its entry if the entry is still at that
  # order. Answers the new total, or nil when another caller took the row.
  defp remove(order) do
    case SystemsRuntime.ETS.take(@order, order) do
      [{^order, key}] ->
        case SystemsRuntime.ETS.lookup(@table, key) do
          [{^key, _result, bytes, ^order}] ->
            deleted =
              SystemsRuntime.ETS.select_delete(@table, [
                {{key, :_, :_, order}, [], [true]}
              ])

            if deleted == 1,
              do: SystemsRuntime.ETS.update_counter(@table, @bytes_key, -bytes),
              else: nil

          _ ->
            nil
        end

      [] ->
        nil
    end
  end

  defp current_bytes, do: SystemsRuntime.ETS.lookup_element(@table, @bytes_key, 2)

  defp size({:ok, blocks}), do: Enum.reduce(blocks, 0, &(block_size(&1) + &2))
  defp size({:error, _reason}), do: 0

  defp block_size(%{"image_url" => %{"url" => url}}) when is_binary(url), do: byte_size(url)
  defp block_size(%{"text" => text}) when is_binary(text), do: byte_size(text)
  defp block_size(_block), do: 0

  defp ctx_value(ctx, key) when is_map(ctx), do: ctx[key] || ctx[Atom.to_string(key)]
  defp ctx_value(_ctx, _key), do: nil
end
