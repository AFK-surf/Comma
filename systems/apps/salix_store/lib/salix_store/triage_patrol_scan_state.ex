defmodule SalixStore.TriagePatrolScanState do
  @moduledoc """
  Versioned durable scan state for one bounded ClickHouse patrol pass.

  A pass pins the ClickHouse tail it intends to reach. Partial pages advance
  only `page_after`; the committed watermark changes only when that fixed tail
  has been exhausted. Every new pass starts from an inclusive bounded overlap
  before the committed watermark so late-visible rows can still be observed.
  """

  @schema "comma.triage-clickhouse-scan-state.v2"
  @cursor_keys ~w(ingest_at message_ts_us version)
  @pass_keys ~w(lower_bound page_after tail)
  @state_keys ~w(committed floor pass schema)
  @millisecond_utc ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/

  @type cursor :: %{
          required(String.t()) => String.t() | non_neg_integer()
        }

  @spec initial(cursor()) :: {:ok, map()} | {:error, :invalid}
  def initial(cursor) do
    if valid_cursor?(cursor) do
      {:ok, %{"schema" => @schema, "committed" => cursor, "floor" => cursor, "pass" => nil}}
    else
      {:error, :invalid}
    end
  end

  @doc "Pins a new pass tail, or returns the already-active pass unchanged."
  @spec start_pass(map(), cursor(), non_neg_integer()) :: {:ok, map()} | {:error, :invalid}
  def start_pass(state, tail, overlap_ms)
      when is_map(state) and is_map(tail) and is_integer(overlap_ms) and overlap_ms >= 0 do
    with true <- valid?(state),
         true <- valid_cursor?(tail) do
      case state["pass"] do
        nil ->
          if compare_cursor(tail, state["committed"]) in [:eq, :gt] do
            lower_bound =
              max_cursor(rewind(state["committed"], overlap_ms), state["floor"])

            {:ok,
             Map.put(state, "pass", %{
               "lower_bound" => lower_bound,
               "page_after" =>
                 if(compare_cursor(lower_bound, state["floor"]) == :eq,
                   do: state["floor"],
                   else: nil
                 ),
               "tail" => tail
             })}
          else
            {:error, :invalid}
          end

        _active ->
          {:ok, state}
      end
    else
      false -> {:error, :invalid}
    end
  end

  def start_pass(_state, _tail, _overlap_ms), do: {:error, :invalid}

  @doc "Returns the exact bounded read window for the active pass."
  @spec window(map()) :: {:ok, map()} | {:error, :invalid}
  def window(state) when is_map(state) do
    if valid?(state) and is_map(state["pass"]), do: {:ok, state["pass"]}, else: {:error, :invalid}
  end

  def window(_state), do: {:error, :invalid}

  @doc "Checkpoints a partial page or commits the captured tail after the final page."
  @spec advance(map(), map()) :: {:ok, map()} | {:error, :invalid}
  def advance(state, %{next_cursor: next_cursor, has_more?: has_more?})
      when is_map(state) and is_boolean(has_more?) do
    with true <- valid?(state),
         %{} = pass <- state["pass"],
         true <- valid_page_cursor?(next_cursor, pass, has_more?) do
      if has_more? do
        {:ok, put_in(state, ["pass", "page_after"], next_cursor)}
      else
        {:ok, %{state | "committed" => pass["tail"], "pass" => nil}}
      end
    else
      _invalid -> {:error, :invalid}
    end
  end

  def advance(_state, _page), do: {:error, :invalid}

  @doc "Cursor used only for human-readable progress, never incremental correctness."
  @spec progress_cursor(map()) :: {:ok, cursor()} | {:error, :invalid}
  def progress_cursor(state) when is_map(state) do
    if valid?(state) do
      cursor = get_in(state, ["pass", "page_after"]) || state["committed"]
      {:ok, cursor}
    else
      {:error, :invalid}
    end
  end

  def progress_cursor(_state), do: {:error, :invalid}

  @spec valid?(term()) :: boolean()
  def valid?(state) when is_map(state) do
    exact_keys?(state, @state_keys) and state["schema"] == @schema and
      valid_cursor?(state["floor"]) and valid_cursor?(state["committed"]) and
      compare_cursor(state["floor"], state["committed"]) in [:lt, :eq] and
      valid_pass?(state["pass"], state["committed"], state["floor"])
  end

  def valid?(_state), do: false

  defp valid_pass?(nil, _committed, _floor), do: true

  defp valid_pass?(pass, committed, floor) when is_map(pass) do
    exact_keys?(pass, @pass_keys) and valid_cursor?(pass["lower_bound"]) and
      valid_cursor?(pass["tail"]) and valid_optional_cursor?(pass["page_after"]) and
      compare_cursor(floor, pass["lower_bound"]) in [:lt, :eq] and
      compare_cursor(pass["lower_bound"], committed) in [:lt, :eq] and
      compare_cursor(committed, pass["tail"]) in [:lt, :eq] and
      valid_page_after?(pass["page_after"], pass)
  end

  defp valid_pass?(_pass, _committed, _floor), do: false

  defp valid_page_after?(nil, _pass), do: true

  defp valid_page_after?(cursor, pass) do
    compare_cursor(cursor, pass["lower_bound"]) in [:eq, :gt] and
      compare_cursor(cursor, pass["tail"]) in [:lt, :eq]
  end

  defp valid_page_cursor?(cursor, pass, true) do
    valid_cursor?(cursor) and after_read_position?(cursor, pass) and
      compare_cursor(cursor, pass["tail"]) in [:lt, :eq]
  end

  defp valid_page_cursor?(nil, _pass, false), do: true

  defp valid_page_cursor?(cursor, pass, false) do
    valid_cursor?(cursor) and after_read_position?(cursor, pass) and
      compare_cursor(cursor, pass["tail"]) in [:lt, :eq]
  end

  defp after_read_position?(cursor, %{"page_after" => nil, "lower_bound" => lower}),
    do: compare_cursor(cursor, lower) in [:eq, :gt]

  defp after_read_position?(cursor, %{"page_after" => after_cursor}),
    do: compare_cursor(cursor, after_cursor) == :gt

  defp rewind(cursor, overlap_ms) do
    {:ok, instant, 0} = DateTime.from_iso8601(cursor["ingest_at"])
    rewound_ms = max(DateTime.to_unix(instant, :millisecond) - overlap_ms, 0)
    {:ok, boundary} = DateTime.from_unix(rewound_ms, :millisecond)

    %{
      "ingest_at" => DateTime.to_iso8601(boundary),
      "message_ts_us" => 0,
      "version" => 0
    }
  end

  defp compare_cursor(left, right) do
    left_key = cursor_key(left)
    right_key = cursor_key(right)

    cond do
      left_key < right_key -> :lt
      left_key > right_key -> :gt
      true -> :eq
    end
  end

  defp max_cursor(left, right) do
    if compare_cursor(left, right) == :lt, do: right, else: left
  end

  defp cursor_key(cursor) do
    {:ok, instant, 0} = DateTime.from_iso8601(cursor["ingest_at"])
    {DateTime.to_unix(instant, :millisecond), cursor["message_ts_us"], cursor["version"]}
  end

  defp valid_optional_cursor?(nil), do: true
  defp valid_optional_cursor?(cursor), do: valid_cursor?(cursor)

  defp valid_cursor?(cursor) when is_map(cursor) do
    exact_keys?(cursor, @cursor_keys) and is_binary(cursor["ingest_at"]) and
      Regex.match?(@millisecond_utc, cursor["ingest_at"]) and
      match?({:ok, _, 0}, DateTime.from_iso8601(cursor["ingest_at"])) and
      Enum.all?(~w(message_ts_us version), &(is_integer(cursor[&1]) and cursor[&1] >= 0))
  end

  defp valid_cursor?(_cursor), do: false

  defp exact_keys?(value, keys), do: Enum.sort(Map.keys(value)) == Enum.sort(keys)
end
