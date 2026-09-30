defmodule SalixMeet.Ports.Copilot do
  @moduledoc false

  @callback maybe_speak(String.t()) :: :ok

  def maybe_speak(meeting_id), do: impl().maybe_speak(meeting_id)

  defp impl do
    Application.get_env(:salix_meet, :copilot_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.Copilot

    @impl true
    def maybe_speak(_meeting_id), do: :ok
  end
end
