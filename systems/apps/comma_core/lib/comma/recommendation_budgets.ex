defmodule Comma.RecommendationBudgets do
  @moduledoc false

  @max_sources 12
  @max_source_concurrency 4
  @source_read_timeout_ms 10_000
  @source_collection_timeout_ms 30_000
  # One wall-clock budget covers queue wait, source reads and model completion.
  @run_hard_cap_seconds 480

  def max_sources, do: @max_sources
  def max_source_concurrency, do: @max_source_concurrency
  def source_read_timeout_ms, do: @source_read_timeout_ms
  def source_collection_timeout_ms, do: @source_collection_timeout_ms
  def run_hard_cap_seconds, do: @run_hard_cap_seconds

  def valid? do
    source_waves = ceil_div(@max_sources, @max_source_concurrency)

    source_waves * @source_read_timeout_ms <= @source_collection_timeout_ms and
      @source_collection_timeout_ms < @run_hard_cap_seconds * 1_000
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end
