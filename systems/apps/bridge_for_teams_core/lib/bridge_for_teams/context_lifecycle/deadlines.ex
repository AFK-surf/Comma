defmodule BridgeForTeams.ContextLifecycle.Deadlines do
  @moduledoc false

  @default_processor_timeout_ms 120_000
  @default_headroom_ms 5_000

  @spec read_barrier_transaction_timeout_ms() :: pos_integer()
  def read_barrier_transaction_timeout_ms do
    processor_timeout_ms =
      sourced_context_bound(:processor_timeout_ms, @default_processor_timeout_ms)

    context_lifecycle_bound(
      :read_barrier_transaction_timeout_ms,
      processor_timeout_ms + @default_headroom_ms
    )
    |> max(processor_timeout_ms + @default_headroom_ms)
  end

  @spec lifecycle_request_transaction_timeout_ms() :: pos_integer()
  def lifecycle_request_transaction_timeout_ms do
    read_barrier_timeout_ms = read_barrier_transaction_timeout_ms()

    context_lifecycle_bound(
      :lifecycle_request_transaction_timeout_ms,
      read_barrier_timeout_ms + @default_headroom_ms
    )
    |> max(read_barrier_timeout_ms + @default_headroom_ms)
  end

  defp context_lifecycle_bound(key, default),
    do: bound(:context_lifecycle_bounds, key, default)

  defp sourced_context_bound(key, default), do: bound(:sourced_context_bounds, key, default)

  defp bound(config_key, key, default) do
    case Application.get_env(:bridge_for_teams_core, config_key, [])
         |> Keyword.get(key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> default
    end
  end
end
