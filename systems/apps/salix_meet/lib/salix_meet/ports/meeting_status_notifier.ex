defmodule SalixMeet.Ports.MeetingStatusNotifier do
  @moduledoc false

  @callback notify(String.t(), map(), map()) :: :ok | {:error, term()}

  @spec notify(String.t(), map(), map()) :: :ok | {:error, term()}
  def notify(meeting_id, state, event), do: impl().notify(meeting_id, state, event)

  defp impl,
    do:
      Application.get_env(
        :salix_meet,
        :meeting_status_notifier_mod,
        __MODULE__.None
      )

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.MeetingStatusNotifier

    @impl true
    def notify(_meeting_id, _state, _event), do: :ok
  end
end
