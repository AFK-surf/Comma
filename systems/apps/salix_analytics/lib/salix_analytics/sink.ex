defmodule SalixAnalytics.Sink do
  @moduledoc """
  Analytics sink contract for flattened event rows. Sinks MUST be idempotent:
  callers may retry a batch after a crash, so the same `(agent, seq, type,
  message_id)` row may be inserted more than once and the sink is responsible
  for collapsing duplicates. `SalixAnalytics.Sink.ClickHouse` relies on
  `ReplacingMergeTree`-style dedup on the per-row `dedup` key this module
  mints, and `SalixAnalytics.Sink.Memory` dedups in-process on the same key.

  `dedup_key/1` is the single source of truth for what "the same row" means, so
  every backend agrees on identity regardless of how the rows are physically
  stored.
  """

  @typedoc "A flattened analytics event annotated with `_agent`/`_seq`."
  @type row :: %{optional(String.t()) => term()}

  @doc """
  Insert a batch of rows. Returns `{:ok, count}` where `count` is the number of
  rows handed to the backend (NOT the number physically retained after dedup —
  dedup is the backend's job and may be eventually consistent in ClickHouse).
  """
  @callback insert([row()]) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc """
  Stable per-row dedup key. Identity is `(agent, seq, type, message_id)`.
  Events without a `message_id` fall back to their type.
  """
  @spec dedup_key(row()) :: String.t()
  def dedup_key(row) when is_map(row) do
    agent = row["_agent"] || ""
    seq = row["_seq"] || 0
    type = row["type"] || row["kind"] || ""
    mid = row["message_id"]

    parts =
      case mid do
        nil -> [agent, seq, type]
        _ -> [agent, seq, type, mid]
      end

    parts
    |> Enum.map_join("|", &to_string/1)
  end
end
