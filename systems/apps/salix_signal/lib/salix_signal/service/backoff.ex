defmodule SalixSignal.Service.Backoff do
  @moduledoc """
  Reconnect and retry delays: exponential backoff with jitter, bounded by a
  cap, and never shorter than a server `Retry-After` (CRS-01 section 12).

  The delay for attempt `n` (0-based) is drawn uniformly from
  `[d / 2, d]`, where `d = min(max_ms, base_ms * 2^n)`.
  """

  alias SalixSignal.Service.Response

  @default_base_ms 1_000
  @default_max_ms 300_000

  @type opts :: [base_ms: pos_integer(), max_ms: pos_integer()]

  @doc "The delay before attempt `attempt`. `random` in `[0, 1)` picks the jitter."
  @spec delay_ms(non_neg_integer(), opts(), float()) :: non_neg_integer()
  def delay_ms(attempt, opts \\ [], random \\ :rand.uniform())
      when is_integer(attempt) and attempt >= 0 do
    base = Keyword.get(opts, :base_ms, @default_base_ms)
    max = Keyword.get(opts, :max_ms, @default_max_ms)
    # Bound the exponent so the product stays small before the cap applies.
    ceiling = min(max, base * Integer.pow(2, min(attempt, 32)))
    half = div(ceiling, 2)
    half + trunc((ceiling - half) * random)
  end

  @doc """
  Raises `delay_ms` to at least `retry_after` seconds when one is given. The
  server wait counts for at most `SalixSignal.Service.Response.max_retry_after_s/0`.
  """
  @spec honor_retry_after(non_neg_integer(), non_neg_integer() | nil) :: non_neg_integer()
  def honor_retry_after(delay_ms, nil), do: delay_ms

  def honor_retry_after(delay_ms, seconds),
    do: max(delay_ms, min(seconds, Response.max_retry_after_s()) * 1_000)
end
