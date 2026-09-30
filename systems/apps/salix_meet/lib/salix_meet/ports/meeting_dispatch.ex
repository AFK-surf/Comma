defmodule SalixMeet.Ports.MeetingDispatch do
  @moduledoc """
  Port from the meeting runtime driver to a connector-hosted meeting runtime.

  The composition host selects a connected environment that advertises the
  meeting runtime capability and dispatches the join over the connector bridge.
  """

  @callback join(map()) :: {:ok, map()} | :ok | {:error, term()}

  @doc """
  Command the joined bot to post a chat message into the live meeting.

  `payload` carries `"meeting_id"`, `"group_id"` (used to resolve the current
  connector env), `"message_id"` (stable across retries), and `"text"`.
  """
  @callback send_chat(map()) :: {:ok, map()} | :ok | {:error, term()}

  @doc """
  Three-valued live-session read: does the runtime that owns the bot report a
  live session for this meeting?

  `payload` carries `"meeting_id"` and `"group_id"` (plus the fields the
  runtime policy needs, mirroring `send_chat/1`). The answer is `:live`
  (runtime confirms an active bot session), `:none` (runtime confirms there is
  none), or `:unavailable` (the runtime could not be asked or did not give a
  well-formed answer). Callers must treat `:unavailable` as fail-closed —
  never as either definite answer.
  """
  @callback session_status(map()) :: {:ok, :live | :none | :unavailable} | {:error, term()}

  def join(payload), do: impl().join(payload)

  def send_chat(payload), do: impl().send_chat(payload)

  def session_status(payload), do: impl().session_status(payload)

  defp impl do
    Application.get_env(:salix_meet, :meeting_dispatch_mod, __MODULE__.None)
  end

  defmodule None do
    @moduledoc false
    @behaviour SalixMeet.Ports.MeetingDispatch

    @impl true
    def join(_payload), do: {:error, :meeting_dispatch_not_configured}

    @impl true
    def send_chat(_payload), do: {:error, :meeting_dispatch_not_configured}

    @impl true
    def session_status(_payload), do: {:ok, :unavailable}
  end
end
