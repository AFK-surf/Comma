defmodule SalixSignalProto.GroupCall do
  @moduledoc """
  Group calls (CRS-14): fixed constants and the small derivations that the
  calling server (SFU) client needs.

    * `authorization/1`: the SFU `Authorization` header from the membership
      token (section 4.2)
    * `opaque_user_id/1`: how the SFU names a member (section 5.3)
    * `srtp_keys/3`: the AEAD_AES_128_GCM master keys to and from the SFU
      (section 6.2)
    * `ring_id/1`: the ring ID of an era (section 11)
    * SSRC layout (section 7.1) and the audio-level header extension
      (section 7.3, RFC 6464)

  The other modules under `SalixSignalProto.GroupCall` are the HTTP bodies
  of the SFU API (`Sfu`), end-to-end frame encryption (`Frame`), the
  protocol-buffer messages (`Messages`) and the reliability layer on the
  SFU data stream (`Reliable`).
  """

  import Bitwise

  alias SalixSignalProto.Crypto.{Hkdf, X25519}

  @srtp_label "Signal_Group_Call_20211105_SignallingDH_SRTPKey_KDF"
  @okm_bytes 56

  @audio_payload_type 102
  @data_payload_type 101
  @sfu_ssrc 1
  @data_ssrc_offset 13
  @audio_level_extension_id 5
  @one_byte_extension_profile 0xBEDE

  # A frame-level level above this -dBov value counts as voice activity for
  # the V bit of the audio-level extension (RFC 6464 section 3). A plain
  # energy threshold; the bit is advisory.
  @voice_activity_level 50

  @type srtp_keys :: %{
          send: %{key: <<_::128>>, salt: <<_::96>>},
          receive: %{key: <<_::128>>, salt: <<_::96>>}
        }

  # -- Constants ---------------------------------------------------------------

  @doc "Opus payload type of group-call audio (CRS-14 section 7.1)."
  def audio_payload_type, do: @audio_payload_type

  @doc "Payload type of device-to-device and SFU data (CRS-14 section 7.1)."
  def data_payload_type, do: @data_payload_type

  @doc "SSRC of device-to-SFU and SFU-to-device data (CRS-14 section 7.1)."
  def sfu_ssrc, do: @sfu_ssrc

  @doc "One-byte header extension ID of the audio level (CRS-14 section 7.3)."
  def audio_level_extension_id, do: @audio_level_extension_id

  @doc "Interval of heartbeats through the SFU (CRS-14 section 10.2)."
  def heartbeat_interval_ms, do: 1_000

  @doc "How long the old send key stays in use after a rotation (CRS-14 section 9.3)."
  def rotation_delay_ms, do: 5_000

  @doc "Interval after which a client requests a new SFU token (CRS-14 section 4.2)."
  def token_refresh_ms, do: 24 * 60 * 60 * 1000

  @doc "Receive states kept per sender (CRS-14 section 8.3)."
  def max_receive_states, do: 5

  @doc "Age after which a received ring is ignored, in seconds (CRS-14 section 11)."
  def max_ring_age_s, do: 60

  @doc "Production and staging SFU base URLs (CRS-14 section 5.1)."
  def sfu_url(:production), do: "https://sfu.voip.signal.org"
  def sfu_url(:staging), do: "https://sfu.staging.voip.signal.org"

  # -- SSRC layout (section 7.1) -----------------------------------------------

  @doc "SSRC of the audio stream of the device with `demux_id`."
  @spec audio_ssrc(non_neg_integer()) :: non_neg_integer()
  def audio_ssrc(demux_id), do: demux_id

  @doc "SSRC of device-to-device data sent through the SFU by `demux_id`."
  @spec data_ssrc(non_neg_integer()) :: non_neg_integer()
  def data_ssrc(demux_id), do: bor(demux_id, @data_ssrc_offset)

  @doc """
  Classifies a received RTP stream: `:sfu` (SSRC 1), `{:audio, demux_id}`,
  `{:data, demux_id}` or `:other` (video and retransmission streams, which
  an audio-only client ignores).
  """
  @spec classify(non_neg_integer(), non_neg_integer()) ::
          :sfu | {:audio | :data, non_neg_integer()} | :other
  def classify(@sfu_ssrc, @data_payload_type), do: :sfu

  def classify(ssrc, @audio_payload_type) when band(ssrc, 15) == 0 and ssrc > 0,
    do: {:audio, ssrc}

  def classify(ssrc, @data_payload_type) when band(ssrc, 15) == @data_ssrc_offset,
    do: {:data, band(ssrc, bnot(15))}

  def classify(_ssrc, _payload_type), do: :other

  # -- Authorization (section 4.2) ---------------------------------------------

  @doc """
  The `Authorization` header of every SFU request: `Basic` and the base64 of
  `P ":" T`, where `T` is the token and `P` its part before the first `:`.
  A token without `:` is invalid.
  """
  @spec authorization(String.t()) :: {:ok, String.t()} | {:error, :invalid_token}
  def authorization(token) when is_binary(token) do
    case String.split(token, ":", parts: 2) do
      [prefix, _rest] -> {:ok, "Basic " <> Base.encode64(prefix <> ":" <> token)}
      _ -> {:error, :invalid_token}
    end
  end

  # -- Opaque user IDs (section 5.3) -------------------------------------------

  @doc """
  The SFU's name for a member: lowercase hex of SHA-256 over the member ID,
  the 65-byte UID ciphertext stored in group state (CRS-09a section 7.3).
  """
  @spec opaque_user_id(binary()) :: String.t()
  def opaque_user_id(member_id) when is_binary(member_id),
    do: :sha256 |> :crypto.hash(member_id) |> Base.encode16(case: :lower)

  # -- SRTP keys (section 6.2) -------------------------------------------------

  @doc "The HKDF label of the SFU SRTP key derivation."
  def srtp_label, do: @srtp_label

  @doc """
  The client's SRTP master keys: `send` protects media to the SFU and
  `receive` opens media from it. `client_private` is the join key's private
  half, `sfu_public` the SFU's `dhePublicKey`, and `extra` the bytes of
  `hkdfExtraInfo` (empty for group calls). An all-zero shared secret is
  rejected.
  """
  @spec srtp_keys(binary(), binary(), binary()) ::
          {:ok, srtp_keys()} | {:error, :invalid_public_key}
  def srtp_keys(client_private, sfu_public, extra \\ "") do
    with {:ok, okm} <- okm(client_private, sfu_public, extra) do
      <<send_key::binary-16, send_salt::binary-12, receive_key::binary-16,
        receive_salt::binary-12>> = okm

      {:ok,
       %{
         send: %{key: send_key, salt: send_salt},
         receive: %{key: receive_key, salt: receive_salt}
       }}
    end
  end

  @doc "The 56 bytes of HKDF output before the split. Exposed for vector tests."
  @spec okm(binary(), binary(), binary()) :: {:ok, <<_::448>>} | {:error, :invalid_public_key}
  def okm(<<_::binary-32>> = client_private, sfu_public, extra) when is_binary(extra) do
    case X25519.dh(client_private, sfu_public) do
      {:ok, <<0::256>>} -> {:error, :invalid_public_key}
      {:ok, shared} -> {:ok, Hkdf.derive(shared, <<0::256>>, [@srtp_label, extra], @okm_bytes)}
      {:error, _reason} -> {:error, :invalid_public_key}
    end
  end

  def okm(_client_private, _sfu_public, _extra), do: {:error, :invalid_public_key}

  # -- Rings (section 11) ------------------------------------------------------

  @doc """
  The ring ID of era `era_id`: an era ID of exactly 16 hexadecimal digits is
  read as a 64-bit value and reinterpreted as signed, with 0 becoming -1;
  any other era ID gives the first 8 bytes of its SHA-256, read as a
  little-endian signed integer.
  """
  @spec ring_id(String.t()) :: integer()
  def ring_id(era_id) when is_binary(era_id) do
    with 16 <- byte_size(era_id),
         true <- hex?(era_id) do
      <<id::signed-64>> = Base.decode16!(era_id, case: :mixed)
      if id == 0, do: -1, else: id
    else
      _ ->
        <<id::little-signed-64, _::binary>> = :crypto.hash(:sha256, era_id)
        id
    end
  end

  defp hex?(string), do: String.match?(string, ~r/\A[0-9a-fA-F]+\z/)

  # -- Audio level (section 7.3) -----------------------------------------------

  @doc """
  The audio level of PCM16 little-endian samples in -dBov (RFC 6464): 0 is
  full scale, 127 digital silence or quieter.
  """
  @spec audio_level(binary()) :: 0..127
  def audio_level(pcm) when is_binary(pcm) do
    {sum, count} =
      for <<sample::little-signed-16 <- pcm>>, reduce: {0, 0} do
        {sum, count} -> {sum + sample * sample, count + 1}
      end

    if sum == 0 do
      127
    else
      rms = :math.sqrt(sum / count) / 32_768
      (-20 * :math.log10(rms)) |> round() |> max(0) |> min(127)
    end
  end

  @doc """
  The RTP header extension of an audio packet: the one-byte form (RFC 8285)
  with the audio-level element (ID 5, RFC 6464) for `level`.
  """
  @spec audio_level_extension(0..127) :: {0xBEDE, binary()}
  def audio_level_extension(level) when level in 0..127 do
    voice = if level < @voice_activity_level, do: 1, else: 0
    {@one_byte_extension_profile, <<@audio_level_extension_id::4, 0::4, voice::1, level::7>>}
  end
end
