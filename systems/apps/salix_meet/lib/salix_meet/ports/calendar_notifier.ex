defmodule SalixMeet.Ports.CalendarNotifier do
  @moduledoc """
  Outbound notification port for a calendar enrollment in `mode=notify`.

  This is the start-time provider announcement for a known calendar event. It
  does not create a Task, start meeting research, or deliver input to Router.
  Implementations write the configured external IM target directly.
  """

  @callback notify(group :: map(), event :: map(), occurrence_id :: String.t()) ::
              {:ok, :queued | :exists} | {:error, term()}

  @spec notify(map(), map(), String.t()) :: {:ok, :queued | :exists} | {:error, term()}
  def notify(group, event, occurrence_id), do: impl().notify(group, event, occurrence_id)

  defp impl,
    do: Application.get_env(:salix_meet, :calendar_notifier_mod, __MODULE__.None)

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.CalendarNotifier

    @impl true
    def notify(_group, _event, _occurrence_id), do: {:error, :not_configured}
  end
end
