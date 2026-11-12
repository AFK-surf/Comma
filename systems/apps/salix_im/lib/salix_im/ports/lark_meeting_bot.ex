defmodule SalixIM.Ports.LarkMeetingBot do
  @moduledoc """
  The meeting product's answer to the events of a Lark app's bot in Lark video
  meetings (`vc.bot.meeting_invited_v1`, `vc.bot.meeting_ended_v1`).
  """

  @callback handle_event(connect :: map(), envelope :: map()) ::
              {:ok, atom()} | {:ignored, atom()} | {:error, term()}

  @spec handle_event(map(), map()) :: {:ok, atom()} | {:ignored, atom()} | {:error, term()}
  def handle_event(connect, envelope), do: impl().handle_event(connect, envelope)

  defp impl,
    do: SystemsRuntime.get_env(:salix_im, :lark_meeting_bot_mod, __MODULE__.Unconfigured)

  defmodule Unconfigured do
    @moduledoc false
    @behaviour SalixIM.Ports.LarkMeetingBot

    @impl true
    def handle_event(_connect, _envelope), do: {:ignored, :meeting_bot_not_configured}
  end
end
