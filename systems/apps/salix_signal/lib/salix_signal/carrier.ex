defmodule SalixSignal.Carrier do
  @moduledoc """
  The Signal carrier of the voice call core (`salix_voice`, PLAN
  "Workstream A" and C10).

  A Signal call reaches the Router like a phone call: the signaling layer
  binds the caller to a Group (CRS-12 plus the Signal IM Connect), then
  `admit/2` admits a `SalixVoice.CallActor` with carrier `:signal` and makes
  the call's media connection its carrier socket. Audio is PCM16 mono at
  24 kHz both ways: `SalixSignal.CallMedia.Connection` decodes and encodes
  Opus and sends RTP.

  This carrier has no WebSocket frames, so it does not implement the
  `SalixVoice.Carrier` frame codec; the connection process exchanges the
  `{:voice_carrier, ...}` and `{:voice_call, ...}` messages directly.
  """

  alias SalixSignal.CallMedia.Connection

  @doc """
  Admits a voice call for a Signal media connection and attaches the
  connection to it. `attrs`: `tenant_id`, `group_id`, `connect_id`,
  `caller_aci` (the caller's ACI string), `signal_call_id` (the CRS-12 call
  ID) and optional `display_name`.

  Returns the voice call ID, or the admission error of `SalixVoice.admit/1`.
  """
  @spec admit(pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def admit(connection, attrs) when is_pid(connection) and is_map(attrs) do
    admission = %{
      carrier: :signal,
      tenant_id: attrs.tenant_id,
      group_id: attrs.group_id,
      connect_id: attrs.connect_id,
      caller: %{"kind" => "signal", "value" => attrs.caller_aci},
      carrier_call_id: carrier_call_id(attrs.caller_aci, attrs.signal_call_id),
      audio_format: :pcm16_24k,
      display_name: attrs[:display_name]
    }

    with {:ok, %{call_id: call_id}} <- SalixVoice.admit(admission),
         {:ok, _info} <- Connection.attach_call(connection, call_id) do
      {:ok, call_id}
    end
  end

  @doc """
  Admits a voice call for a joined Signal group call (CRS-14) and makes the
  group-call session its carrier socket: the session mixes every speaker
  into the one stream the call hears. `attrs`: `tenant_id`, `group_id`,
  `connect_id`, `signal_group_id` (the 32-byte Groups v2 group
  identifier), `era_id` and optional `display_name`.

  The caller identity is the Signal group, `%{"kind" => "signal_group",
  "value" => base64url group identifier}`.
  """
  @spec admit_group_call(pid(), map()) :: {:ok, String.t()} | {:error, term()}
  def admit_group_call(session, attrs) when is_pid(session) and is_map(attrs) do
    group = Base.url_encode64(attrs.signal_group_id, padding: false)

    admission = %{
      carrier: :signal,
      tenant_id: attrs.tenant_id,
      group_id: attrs.group_id,
      connect_id: attrs.connect_id,
      caller: %{"kind" => "signal_group", "value" => group},
      carrier_call_id: "group:#{group}:#{attrs.era_id}",
      audio_format: :pcm16_24k,
      display_name: attrs[:display_name]
    }

    with {:ok, %{call_id: call_id}} <- SalixVoice.admit(admission),
         {:ok, _info} <- SalixSignal.GroupCall.Session.attach_call(session, call_id) do
      {:ok, call_id}
    end
  end

  @doc """
  The carrier call ID of a Signal call: the caller's ACI and the CRS-12
  call ID. The caller picks the call ID, so the ACI scopes it.
  """
  @spec carrier_call_id(String.t(), non_neg_integer()) :: String.t()
  def carrier_call_id(caller_aci, signal_call_id),
    do: "#{caller_aci}:#{signal_call_id}"
end
