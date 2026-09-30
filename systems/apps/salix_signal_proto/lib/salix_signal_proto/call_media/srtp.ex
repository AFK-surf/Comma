defmodule SalixSignalProto.CallMedia.Srtp do
  @moduledoc """
  SRTP and SRTCP with AEAD_AES_256_GCM (RFC 7714), the only protection
  profile of 1:1 call media (CRS-13 section 5).

  One context protects one direction of one call connection. `new/2` takes
  the 32-byte master key and 12-byte master salt from
  `SalixSignalProto.CallMedia.Keys` and derives the session keys once
  (key derivation rate 0, no MKI).

  Session keys come from AES_256_CM_PRF (RFC 6188, RFC 3711 section 4.3). The
  PRF takes a 112-bit salt; the 96-bit AEAD master salt fills its first 12
  bytes and the last 2 bytes are zero (CRS-13 section 5). A cross-check
  fixture made with libsrtp covers this step.

  A sending context tracks the rollover counter per SSRC and the SRTCP index.
  A receiving context estimates the packet index (RFC 3711 appendix A) and
  rejects replays per SSRC (RFC 3711 section 3.3.2) with a 1024-packet
  window, the receive window of Signal clients (CRS-13 section 5).
  Receive state changes only after authentication succeeds.

  A receiving context tracks at most `max_receive_streams/0` SSRCs for SRTP
  and as many for SRTCP. The sender chooses the SSRC of every packet it
  authenticates, so without a bound one peer could grow the receive state
  of a call without limit. A packet that would start a stream beyond the
  bound is refused with `{:error, :too_many_streams}`; known streams keep
  working. A 1:1 peer sends on at most four SSRCs (CRS-13 section 6.1), and
  the group-call SFU on SSRC 1 and a few per remote device (CRS-14 section
  7.1).

  Why this is not `ex_libsrtp`: the only profiles needed are two AEADs that
  OTP `:crypto` implements, and the library would add a C toolchain step and
  a native libsrtp built with GCM support to every build image. The RFC 7714
  test vectors and the libsrtp cross-check fixtures test this module.
  """

  import Bitwise

  alias SalixSignalProto.CallMedia.Rtp

  @tag_bytes 16
  @replay_window 1024
  @max_srtcp_index 0x7FFFFFFF
  @max_receive_streams 1024

  # `streams` and `rtcp_index` (the last SRTCP index sent) are sending state; `replay` and `rtcp_replay`
  # are receiving state, both keyed by SSRC.
  defstruct [
    :rtp_key,
    :rtp_salt,
    :rtcp_key,
    :rtcp_salt,
    streams: %{},
    rtcp_index: 0,
    replay: %{},
    rtcp_replay: %{}
  ]

  @type t :: %__MODULE__{}

  @doc "The most SSRCs a receiving context tracks, for SRTP and for SRTCP each."
  @spec max_receive_streams() :: pos_integer()
  def max_receive_streams, do: @max_receive_streams

  @doc """
  A context for master `key` (32 bytes for AEAD_AES_256_GCM, 16 bytes for
  AEAD_AES_128_GCM) and `salt` (12 bytes). The session keys have the size of
  the master key.
  """
  @spec new(<<_::256>> | <<_::128>>, <<_::96>>) :: t()
  def new(key, <<_::binary-12>> = salt) when byte_size(key) in [16, 32] do
    size = byte_size(key)

    %__MODULE__{
      rtp_key: prf(key, salt, 0x00, size),
      rtp_salt: prf(key, salt, 0x02, 12),
      rtcp_key: prf(key, salt, 0x03, size),
      rtcp_salt: prf(key, salt, 0x05, 12)
    }
  end

  @doc """
  Session key material for `label` (RFC 3711 section 4.3.1 with r = 0).
  Exposed for the key-derivation fixture.
  """
  @spec prf(<<_::256>> | <<_::128>>, <<_::96>>, 0..255, pos_integer()) :: binary()
  def prf(key, <<salt::binary-12>>, label, length) do
    <<head::binary-7, byte7, tail::binary-6>> = salt <> <<0, 0>>
    iv = <<head::binary, bxor(byte7, label), tail::binary, 0, 0>>
    cipher = if byte_size(key) == 16, do: :aes_128_ctr, else: :aes_256_ctr
    :crypto.crypto_one_time(cipher, key, iv, <<0::size(length * 8)>>, true)
  end

  # -- SRTP --------------------------------------------------------------------

  @doc """
  Protects one RTP packet. The rollover counter of its SSRC advances when the
  sequence number wraps.
  """
  @spec protect(t(), binary()) :: {:ok, binary(), t()} | {:error, :malformed}
  def protect(%__MODULE__{} = ctx, packet) when is_binary(packet) do
    with {:ok, size} <- Rtp.header_size(packet) do
      <<header::binary-size(^size), plaintext::binary>> = packet
      <<_::binary-2, seq::16, _ts::32, ssrc::32, _::binary>> = header

      roc =
        case ctx.streams do
          %{^ssrc => %{roc: roc, seq: last}} when seq < last and last - seq > 0x8000 -> roc + 1
          %{^ssrc => %{roc: roc}} -> roc
          _ -> 0
        end

      iv = rtp_iv(ctx.rtp_salt, ssrc, roc, seq)
      {cipher, tag} = seal(ctx.rtp_key, iv, plaintext, header)
      streams = Map.put(ctx.streams, ssrc, %{roc: roc, seq: seq})
      {:ok, header <> cipher <> tag, %{ctx | streams: streams}}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc """
  Verifies and decrypts one SRTP packet. Returns the plain RTP packet.
  """
  @spec unprotect(t(), binary()) ::
          {:ok, binary(), t()}
          | {:error, :malformed | :authentication | :replay | :too_many_streams}
  def unprotect(%__MODULE__{} = ctx, packet) when is_binary(packet) do
    with {:ok, size} <- Rtp.header_size(packet),
         true <- byte_size(packet) >= size + @tag_bytes do
      <<header::binary-size(^size), body::binary>> = packet
      <<_::binary-2, seq::16, _ts::32, ssrc::32, _::binary>> = header
      cipher_size = byte_size(body) - @tag_bytes
      <<cipher::binary-size(^cipher_size), tag::binary>> = body

      stream = Map.get(ctx.replay, ssrc)
      {roc, index} = estimate_index(stream, seq)

      with :ok <- stream_room(ctx.replay, stream),
           :ok <- replay_check(stream, index),
           {:ok, plaintext} <-
             open(ctx.rtp_key, rtp_iv(ctx.rtp_salt, ssrc, roc, seq), cipher, tag, header) do
        replay = Map.put(ctx.replay, ssrc, accept_index(stream, index))
        {:ok, header <> plaintext, %{ctx | replay: replay}}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  defp rtp_iv(salt, ssrc, roc, seq),
    do: :crypto.exor(<<0::16, ssrc::32, roc::32, seq::16>>, salt)

  # RFC 3711 appendix A: the packet index closest to the highest one seen.
  defp estimate_index(nil, seq), do: {0, seq}

  defp estimate_index(%{index: highest}, seq) do
    roc = highest >>> 16
    s_l = band(highest, 0xFFFF)

    v =
      cond do
        s_l < 0x8000 and seq - s_l > 0x8000 -> roc - 1
        s_l >= 0x8000 and s_l - 0x8000 > seq -> roc + 1
        true -> roc
      end

    # A packet from before the first rollover period (v = -1) gets a
    # negative index, which the replay check refuses.
    {v, v * 0x10000 + seq}
  end

  # -- SRTCP -------------------------------------------------------------------

  @doc """
  Protects one RTCP compound packet with encryption (E flag set). The first
  packet has SRTCP index 1 and each later one the next index, as libsrtp
  numbers them.
  """
  @spec protect_rtcp(t(), binary()) :: {:ok, binary(), t()} | {:error, :malformed | :exhausted}
  def protect_rtcp(%__MODULE__{rtcp_index: index}, _packet) when index >= @max_srtcp_index,
    do: {:error, :exhausted}

  def protect_rtcp(%__MODULE__{} = ctx, <<first::binary-4, ssrc::32, plaintext::binary>>) do
    index = ctx.rtcp_index + 1
    trailer = <<1::1, index::31>>
    header = <<first::binary, ssrc::32>>
    iv = rtcp_iv(ctx.rtcp_salt, ssrc, index)
    {cipher, tag} = seal(ctx.rtcp_key, iv, plaintext, header <> trailer)
    {:ok, header <> cipher <> tag <> trailer, %{ctx | rtcp_index: index}}
  end

  def protect_rtcp(_ctx, _packet), do: {:error, :malformed}

  @doc """
  Verifies and, when the E flag is set, decrypts one SRTCP packet. Returns
  the plain RTCP compound packet.
  """
  @spec unprotect_rtcp(t(), binary()) ::
          {:ok, binary(), t()}
          | {:error, :malformed | :authentication | :replay | :too_many_streams}
  def unprotect_rtcp(%__MODULE__{} = ctx, packet)
      when is_binary(packet) and byte_size(packet) >= 8 + @tag_bytes + 4 do
    body_size = byte_size(packet) - 8 - @tag_bytes - 4

    <<header::binary-8, body::binary-size(^body_size), tag::binary-16, e::1, index::31>> =
      packet

    <<_::binary-4, ssrc::32>> = header
    trailer = <<e::1, index::31>>
    iv = rtcp_iv(ctx.rtcp_salt, ssrc, index)
    replay = Map.get(ctx.rtcp_replay, ssrc)

    result =
      case e do
        1 ->
          open(ctx.rtcp_key, iv, body, tag, header <> trailer)

        0 ->
          # Not encrypted: the whole packet is associated data (RFC 7714 section 9.3).
          with {:ok, <<>>} <- open(ctx.rtcp_key, iv, <<>>, tag, header <> body <> trailer),
               do: {:ok, body}
      end

    with :ok <- stream_room(ctx.rtcp_replay, replay),
         :ok <- replay_check(replay, index),
         {:ok, plaintext} <- result do
      rtcp_replay = Map.put(ctx.rtcp_replay, ssrc, accept_index(replay, index))
      {:ok, header <> plaintext, %{ctx | rtcp_replay: rtcp_replay}}
    end
  end

  def unprotect_rtcp(_ctx, _packet), do: {:error, :malformed}

  defp rtcp_iv(salt, ssrc, index),
    do: :crypto.exor(<<0::16, ssrc::32, 0::16, 0::1, index::31>>, salt)

  # -- Shared ------------------------------------------------------------------

  defp seal(key, iv, plaintext, aad),
    do: :crypto.crypto_one_time_aead(gcm(key), key, iv, plaintext, aad, @tag_bytes, true)

  defp open(key, iv, cipher, tag, aad) do
    case :crypto.crypto_one_time_aead(gcm(key), key, iv, cipher, aad, tag, false) do
      :error -> {:error, :authentication}
      plaintext -> {:ok, plaintext}
    end
  end

  defp gcm(key) when byte_size(key) == 16, do: :aes_128_gcm
  defp gcm(_key), do: :aes_256_gcm

  # A packet of an unknown SSRC starts a stream only while there is room.
  defp stream_room(streams, nil) when map_size(streams) >= @max_receive_streams,
    do: {:error, :too_many_streams}

  defp stream_room(_streams, _stream), do: :ok

  # Replay state: the highest accepted index and a bitmask of the 1024 indexes
  # at and below it (bit 0 = highest).
  defp replay_check(_state, index) when index < 0, do: {:error, :replay}
  defp replay_check(nil, _index), do: :ok
  defp replay_check(%{index: highest}, index) when index > highest, do: :ok

  defp replay_check(%{index: highest, window: window}, index) do
    delta = highest - index

    cond do
      delta >= @replay_window -> {:error, :replay}
      band(window, 1 <<< delta) != 0 -> {:error, :replay}
      true -> :ok
    end
  end

  defp accept_index(nil, index), do: %{index: index, window: 1}

  defp accept_index(%{index: highest, window: window}, index) when index > highest do
    shift = index - highest
    mask = (1 <<< @replay_window) - 1
    window = if shift >= @replay_window, do: 1, else: band(window <<< shift ||| 1, mask)
    %{index: index, window: window}
  end

  defp accept_index(%{index: highest, window: window}, index),
    do: %{index: highest, window: window ||| 1 <<< (highest - index)}
end
