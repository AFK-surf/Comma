defmodule SalixAnalytics do
  @moduledoc """
  Documentation for `SalixAnalytics`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> SalixAnalytics.hello()
      :world

  """
  def hello do
    :world
  end

  @doc "Readiness gate for typed billing/reporting usage tables."
  def typed_usage_ready? do
    if Application.get_env(:salix_analytics, :metering_enabled, false) do
      SalixAnalytics.Sink.ClickHouseTyped.readiness()
    else
      :ok
    end
  end

  @doc """
  Operator probe for the encrypted agent event archive's table layout.

  Answers `:ok` when the archive is not configured, so a deployment that has not
  opted in is not reported as broken over a table it never writes.

  This probes the LAYOUT, not existence. On a ReplacingMergeTree a wrong sorting
  key is not a failed query — it is the engine quietly merging away rows it
  believes are duplicates.

  It is deliberately NOT a `Comma.PodLifecycle` readiness gate: that module's
  readiness is documented as local and side-effect free, and this makes an HTTP
  call to ClickHouse. Enforcement lives where the damage would happen instead —
  `SalixAnalytics.EventArchive.Worker` runs the same probe before its first
  insert and refuses to write into a mismatched table. This function is for an
  operator or a test asking the question directly.
  """
  def event_archive_ready? do
    if SalixAnalytics.EventArchive.active?() do
      # Rejected recipients first: the archive is WRITING, so this is the
      # condition an operator is least likely to notice on their own and most
      # likely to discover at the moment they need to open an item.
      case SalixAnalytics.EventArchive.Recipients.problems() do
        [] -> SalixAnalytics.EventArchive.Sink.readiness()
        rejected -> {:error, {:archive_recipients_rejected, rejected}}
      end
    else
      :ok
    end
  end
end
