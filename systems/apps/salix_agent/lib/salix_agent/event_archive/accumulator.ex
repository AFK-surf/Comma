defmodule SalixAgent.EventArchive.Accumulator do
  @moduledoc """
  Captures streamed deltas so they can be archived with the response.

  Streamed content exists only as it passes the `on_delta` and
  `on_reasoning_delta` callbacks. Text deltas are recoverable from the terminal
  result, but **`:private_reasoning` deltas are not** — they never appear in
  it. Without this, the archive would be missing what the model actually
  produced, which is precisely the thing the archive exists to hold.

  Sealing every delta as its own item would multiply item count by ~100x for no
  audit value, so deltas accumulate here and seal once, alongside the response.

  ## One row per delta, never one growing row

  This runs on the delta path, ahead of every user-visible token, so its cost
  per delta must be constant in the accumulated size.

  The obvious shape — keep the accumulated text in one ETS cell and rebuild it
  per delta — is quadratic, because ETS copies the whole term on *both* lookup
  and insert. Measured at ~3.2s of loop CPU for a routine 40 KB response.
  Prepending to a flat list does not fix it either: the list spine is still
  copied whole, every time.

  So each delta gets its OWN row in an `ordered_set` keyed `{ref, index}`. Per
  delta that is two `update_counter` calls against a small fixed-size meta row
  plus one insert of the delta alone — all O(1) in the accumulated size.
  `drain/1` reads the range back in key order, which is already delta order.

  Both caps are load-bearing. The byte cap alone never bounded cost, because
  cost tracks delta *count*, which is unbounded independently of total size.

  ## Ownership and failure

  The tables are created by the application master (`SalixAgent.Application`)
  so they outlive any round. `create_table/0` is also called defensively; if it
  ever runs from a transient process, that process owns the table and the table
  dies with it — so every entry point tolerates a missing table and row rather
  than raising into the loop it is observing.
  """

  require Logger

  @meta __MODULE__.Meta
  @deltas __MODULE__.Deltas

  @max_capture_bytes 8 * 1024 * 1024
  @max_capture_deltas 50_000

  # A capture is only ever open for the duration of one provider call. Anything
  # older than this belongs to a call whose drain never ran — the process was
  # killed mid-stream, or the provider exited past every handler. Without a
  # sweep those rows retain up to 8 MiB of refc binary in a node-global table
  # forever, and provider timeouts and round cancellations are routine.
  @stale_after_ms 30 * 60 * 1000
  @sweep_every_ms 60 * 1000
  @sweep_key :__last_sweep__

  @type t :: reference() | nil

  @doc "Create the tables. Idempotent; called from the supervision root."
  @spec create_table() :: :ok
  def create_table do
    ensure(@meta, [:named_table, :public, :set, {:write_concurrency, true}])

    ensure(@deltas, [
      :named_table,
      :public,
      :ordered_set,
      {:write_concurrency, true},
      {:read_concurrency, true}
    ])

    :ok
  end

  defp ensure(name, opts) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, opts)
      _ -> :ok
    end
  rescue
    # Lost a creation race; the winner's table is the one we want anyway.
    ArgumentError -> :ok
  end

  @doc """
  Start accumulating. Returns `nil` when archiving is off, and every other
  function no-ops on `nil` — so a disabled archive costs one comparison per
  delta, not an ETS write.
  """
  @spec new() :: t()
  def new do
    if SalixAgent.EventArchive.enabled?() do
      key = make_ref()
      create_table()
      maybe_sweep()
      # {ref, bytes, count, truncated?, next_index, created_ms}
      :ets.insert(@meta, {key, 0, 0, false, 0, now_ms()})
      key
    else
      nil
    end
  rescue
    exception ->
      Logger.warning("event archive accumulator unavailable: #{Exception.message(exception)}")
      nil
  end

  @doc "Record a streamed text delta."
  @spec text(t(), term()) :: :ok
  def text(nil, _delta), do: :ok
  def text(key, delta) when is_binary(delta), do: put(key, :text, delta)
  def text(_key, _delta), do: :ok

  @doc """
  Record a streamed reasoning delta, preserving its visibility classification.

  Both `:public_summary` and `:private_reasoning` are captured. The recipient
  key is what contains private reasoning, not omission from the archive —
  omitting it would only mean nobody can audit it, including the people
  entitled to.
  """
  @spec reasoning(t(), term()) :: :ok
  def reasoning(nil, _delta), do: :ok

  def reasoning(key, %{visibility: visibility, text: text}) when is_binary(text),
    do: put(key, {:reasoning, label(visibility)}, text)

  def reasoning(key, %{visibility: visibility} = delta),
    do: put(key, {:reasoning, label(visibility)}, inspect(Map.drop(delta, [:__struct__])))

  def reasoning(key, delta) when is_binary(delta),
    do: put(key, {:reasoning, "unclassified"}, delta)

  def reasoning(_key, _delta), do: :ok

  # `to_string/1` on a non-atom raises Protocol.UndefinedError, and this runs
  # inside the provider's own streaming process where nothing would catch it.
  defp label(visibility) when is_atom(visibility), do: Atom.to_string(visibility)
  defp label(visibility) when is_binary(visibility), do: visibility
  defp label(visibility), do: inspect(visibility)

  defp put(key, kind, text) do
    size = byte_size(text)

    cond do
      :ets.update_counter(@meta, key, {3, 1}) > @max_capture_deltas ->
        mark_truncated(key)

      :ets.update_counter(@meta, key, {2, size}) > @max_capture_bytes ->
        mark_truncated(key)

      true ->
        index = :ets.update_counter(@meta, key, {5, 1})
        :ets.insert(@deltas, {{key, index}, kind, text})
        :ok
    end
  rescue
    # A missing row (already drained) or a missing table must never raise into
    # the streaming process.
    ArgumentError -> :ok
  end

  defp mark_truncated(key) do
    :ets.update_element(@meta, key, {4, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Take everything accumulated and free the rows.

  Returns `nil` when nothing streamed, so a non-streaming call archives no
  empty `deltas` key.
  """
  @spec drain(t()) :: map() | nil
  def drain(nil), do: nil

  def drain(key) do
    case :ets.take(@meta, key) do
      [{^key, _bytes, 0, _truncated, _next, _created}] ->
        discard(key)
        nil

      [{^key, bytes, count, truncated, _next, _created}] ->
        rows = take_rows(key)

        %{
          "text" =>
            rows
            |> Enum.filter(&match?({:text, _}, &1))
            |> Enum.map(&elem(&1, 1))
            |> IO.iodata_to_binary(),
          "reasoning" =>
            rows
            |> Enum.filter(&match?({{:reasoning, _}, _}, &1))
            |> Enum.map(fn {{:reasoning, visibility}, text} ->
              %{"visibility" => visibility, "text" => text}
            end),
          "delta_count" => count,
          "captured_bytes" => bytes,
          "truncated" => truncated
        }

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  # ordered_set returns the range in key order, which is delta order.
  defp take_rows(key) do
    rows = :ets.select(@deltas, [{{{key, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", :"$3"}}]}])
    discard(key)
    rows
  end

  defp discard(key) do
    :ets.match_delete(@deltas, {{key, :_}, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Delete captures older than the stale window. Returns how many were freed.

  Called opportunistically from `new/0` at most once a minute, so no extra
  process is needed and no supervision-tree entry is added for it.
  """
  @spec sweep() :: non_neg_integer()
  def sweep do
    cutoff = now_ms() - @stale_after_ms

    stale =
      :ets.select(@meta, [
        {{:"$1", :_, :_, :_, :_, :"$2"}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    Enum.each(stale, fn key ->
      :ets.delete(@meta, key)
      discard(key)
    end)

    if stale != [] do
      Logger.warning("event archive swept #{length(stale)} stale delta capture(s)")
    end

    length(stale)
  rescue
    ArgumentError -> 0
  end

  defp maybe_sweep do
    now = now_ms()

    last =
      case :ets.lookup(@meta, @sweep_key) do
        [{@sweep_key, at}] -> at
        [] -> 0
      end

    if now - last >= @sweep_every_ms do
      :ets.insert(@meta, {@sweep_key, now})
      sweep()
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp now_ms, do: System.system_time(:millisecond)

  @doc """
  Wrap an `:on_reasoning_delta` callback in `llm_opts` so reasoning is captured
  on its way to the real handler.

  Returns `llm_opts` untouched when there is no accumulator or no callback.
  """
  @spec wrap_reasoning(t(), keyword() | map()) :: keyword() | map()
  def wrap_reasoning(nil, llm_opts), do: llm_opts

  def wrap_reasoning(key, llm_opts) do
    case fetch_opt(llm_opts, :on_reasoning_delta) do
      callback when is_function(callback, 1) ->
        wrapped = fn delta ->
          reasoning(key, delta)
          callback.(delta)
        end

        put_opt(llm_opts, :on_reasoning_delta, wrapped)

      _ ->
        llm_opts
    end
  end

  defp fetch_opt(opts, key) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, key), else: nil
  end

  defp fetch_opt(opts, key) when is_map(opts),
    do: Map.get(opts, key) || Map.get(opts, to_string(key))

  defp fetch_opt(_opts, _key), do: nil

  defp put_opt(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp put_opt(opts, key, value) when is_map(opts), do: Map.put(opts, key, value)
end
