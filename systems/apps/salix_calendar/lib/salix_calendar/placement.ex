defmodule SalixCalendar.Placement do
  @moduledoc "Placement seam for Calendar owner actors."

  @callback ensure_started(String.t(), String.t(), keyword()) ::
              {:ok, pid()} | {:error, term()}
  @callback ensure_source_started(String.t(), String.t(), String.t(), keyword()) ::
              {:ok, pid()} | {:error, term()}

  def ensure_started(group_id, calendar_id, opts \\ []),
    do: impl().ensure_started(group_id, calendar_id, opts)

  def ensure_source_started(group_id, calendar_id, source_id, opts \\ []),
    do: impl().ensure_source_started(group_id, calendar_id, source_id, opts)

  defp impl,
    do: Application.get_env(:salix_calendar, :placement, SalixCalendar.Fleet)
end
