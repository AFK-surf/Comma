defmodule SalixSignalProto.CallMedia do
  @moduledoc """
  Fixed wire constants of 1:1 call media (CRS-13).

  A 1:1 call exchanges no SDP. Every value that SDP would negotiate is a fixed
  constant of the protocol (CRS-13 section 1), listed here. The media modules
  under `SalixSignalProto.CallMedia` use them:

    * `Keys`: SRTP master keys from the offer and answer key exchange (section 4)
    * `Srtp`: AEAD_AES_256_GCM SRTP and SRTCP (section 5; RFC 7714)
    * `Rtp`: RTP packet layout (section 6; RFC 3550)
    * `Rtcp`: sender and receiver reports with SDES CNAME (section 10)
    * `Control`: the in-band control channel, "RTP data" (section 9)

  `role` is `:caller` (sent the offer) or `:callee` (sent the answer).
  """

  @type role :: :caller | :callee

  @doc "Opus payload type (CRS-13 section 6.1)."
  def opus_payload_type, do: 102

  @doc "RTP clock rate of the Opus payload type (RFC 7587)."
  def opus_clock_rate, do: 48_000

  @doc "Payload type of the in-band control channel (CRS-13 section 9.1)."
  def rtp_data_payload_type, do: 101

  @doc "SSRC of the in-band control channel, the same in both directions."
  def rtp_data_ssrc, do: 13

  @doc "RTCP CNAME of every stream of both sides (CRS-13 section 6.1)."
  def cname, do: "CNAMECNAMECNAME!"

  @doc "Audio SSRC that `role` sends with (CRS-13 section 6.1)."
  @spec audio_ssrc(role()) :: 1002 | 2002
  def audio_ssrc(:caller), do: 1002
  def audio_ssrc(:callee), do: 2002

  @doc "Audio SSRC that the peer of `role` sends with."
  @spec peer_audio_ssrc(role()) :: 1002 | 2002
  def peer_audio_ssrc(:caller), do: audio_ssrc(:callee)
  def peer_audio_ssrc(:callee), do: audio_ssrc(:caller)

  @doc "The other role."
  @spec peer_role(role()) :: role()
  def peer_role(:caller), do: :callee
  def peer_role(:callee), do: :caller
end
