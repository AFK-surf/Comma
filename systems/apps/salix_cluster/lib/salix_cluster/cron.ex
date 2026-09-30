defmodule SalixCluster.Cron do
  @moduledoc """
  Wall-clock cron math for fixed-time schedules (`SalixCluster.Schedules`).

  A thin, deterministic wrapper over the `crontab` library (standard 5-field
  expressions) and the `tz` IANA database. All public functions take/return
  **unix milliseconds (UTC)** so callers never touch `NaiveDateTime`/zone
  conversion themselves — the schedules store stays in ms throughout.

  ## Timezone semantics

  Cron occurrences are wall-clock times in the schedule's `timezone` (default
  `"UTC"`). The flow is: anchor ms → UTC `DateTime` → shift into the target
  zone → `NaiveDateTime` → crontab occurrence (also naive wall-clock) → back to
  an absolute instant in the zone → unix ms. DST transitions make the back
  conversion non-unique:

    * `{:ambiguous, earlier, _later}` (fall-back hour) → the **earlier** instant.
    * `{:gap, _just_before, just_after}` (spring-forward gap, e.g. 02:30 on a US
      DST night never exists) → the instant **just after** the gap, so the fire
      still happens.

  Both choices are deterministic, which is what keeps concurrent sweepers in
  agreement (see `SalixCluster.Schedules`).

  ## Errors

  `parse/1` rejects malformed expressions at create time. `next_after_ms/3` /
  `latest_at_or_before_ms/3` return `{:error, :no_occurrence}` for parseable but
  unsatisfiable specs (e.g. `0 0 30 2 *`); the caller maps that to a far-future
  sentinel so a lease-gated sweep never raises.
  """

  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @type cron_expr :: Crontab.CronExpression.t()

  @doc """
  Parse a standard 5-field cron expression. Returns `{:error, :invalid_cron}`
  for anything crontab rejects.
  """
  @spec parse(String.t()) :: {:ok, cron_expr()} | {:error, :invalid_cron}
  def parse(expr) when is_binary(expr) do
    case Parser.parse(expr) do
      {:ok, %Crontab.CronExpression{} = ce} -> {:ok, ce}
      {:error, _reason} -> {:error, :invalid_cron}
    end
  rescue
    _ -> {:error, :invalid_cron}
  end

  def parse(_), do: {:error, :invalid_cron}

  @doc """
  First cron occurrence **strictly after** `anchor_ms`, in `tz`, as unix ms.
  """
  @spec next_after_ms(String.t(), integer(), String.t()) ::
          {:ok, integer()} | {:error, :invalid_cron | :no_occurrence | term()}
  def next_after_ms(expr, anchor_ms, tz) do
    with {:ok, ce} <- parse(expr),
         {:ok, anchor_naive} <- to_zoned_naive(anchor_ms, tz) do
      # Floor to the minute and step one minute forward so the occurrence is
      # strictly after the anchor (crontab returns occurrences at-or-after).
      from = anchor_naive |> floor_minute() |> NaiveDateTime.add(60, :second)

      case Scheduler.get_next_run_date(ce, from) do
        {:ok, naive} -> from_zoned_naive(naive, tz)
        {:error, _} -> {:error, :no_occurrence}
      end
    end
  end

  @doc """
  Latest cron occurrence at or before `now_ms`, in `tz`, as unix ms. Powers the
  skip-stale advance (move the anchor past missed windows without delivering).
  """
  @spec latest_at_or_before_ms(String.t(), integer(), String.t()) ::
          {:ok, integer()} | {:error, :invalid_cron | :no_occurrence | term()}
  def latest_at_or_before_ms(expr, now_ms, tz) do
    with {:ok, ce} <- parse(expr),
         {:ok, now_naive} <- to_zoned_naive(now_ms, tz) do
      case Scheduler.get_previous_run_date(ce, now_naive) do
        {:ok, naive} -> from_zoned_naive(naive, tz)
        {:error, _} -> {:error, :no_occurrence}
      end
    end
  end

  # ---- internal: zone conversion ----

  defp to_zoned_naive(ms, tz) do
    case ms |> DateTime.from_unix!(:millisecond) |> DateTime.shift_zone(tz) do
      {:ok, dt} -> {:ok, DateTime.to_naive(dt)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp from_zoned_naive(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> {:ok, DateTime.to_unix(dt, :millisecond)}
      # Fall-back hour: take the earlier of the two instants.
      {:ambiguous, earlier, _later} -> {:ok, DateTime.to_unix(earlier, :millisecond)}
      # Spring-forward gap: the wall-clock time doesn't exist; fire just after it.
      {:gap, _just_before, just_after} -> {:ok, DateTime.to_unix(just_after, :millisecond)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp floor_minute(naive), do: %{naive | second: 0, microsecond: {0, 0}}
end
