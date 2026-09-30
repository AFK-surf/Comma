defmodule SalixSignalProto.CallMedia.Rtp do
  @moduledoc """
  RTP packets (RFC 3550 section 5.1) as 1:1 call media uses them (CRS-13
  section 6).

  `decode/1` accepts the full RTP header grammar: CSRCs, a header extension
  of any profile (a Signal client may put the transport-wide sequence number,
  ID 1, on audio) and padding. `encode/1` writes what Comma sends: no CSRCs, no
  extension and no padding unless the packet struct carries them.

  `header_size/1` gives the length of the part that SRTP authenticates but
  does not encrypt (RFC 7714 section 8.2).
  """

  import Bitwise

  defstruct marker: false,
            payload_type: 0,
            sequence_number: 0,
            timestamp: 0,
            ssrc: 0,
            csrcs: [],
            extension: nil,
            payload: <<>>,
            padding: 0

  @type t :: %__MODULE__{
          marker: boolean(),
          payload_type: 0..127,
          sequence_number: 0..65_535,
          timestamp: 0..4_294_967_295,
          ssrc: 0..4_294_967_295,
          csrcs: [0..4_294_967_295],
          extension: nil | {profile :: 0..65_535, data :: binary()},
          payload: binary(),
          padding: non_neg_integer()
        }

  @doc """
  Size in bytes of the RTP header of `packet`, including CSRCs and the header
  extension. Returns `:error` for a packet that is not version 2 or is shorter
  than its header.
  """
  @spec header_size(binary()) :: {:ok, pos_integer()} | :error
  def header_size(<<2::2, _p::1, x::1, cc::4, _m::1, _pt::7, _::binary-10, rest::binary>>) do
    csrc_bytes = cc * 4

    case {x, rest} do
      {0, <<_::binary-size(^csrc_bytes), _::binary>>} ->
        {:ok, 12 + csrc_bytes}

      {1, <<_::binary-size(^csrc_bytes), _profile::16, words::16, ext::binary>>}
      when byte_size(ext) >= words * 4 ->
        {:ok, 12 + csrc_bytes + 4 + words * 4}

      _ ->
        :error
    end
  end

  def header_size(_packet), do: :error

  @doc "Decodes an unprotected RTP packet."
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed}
  def decode(packet) when is_binary(packet) do
    with {:ok, size} <- header_size(packet),
         <<header::binary-size(^size), body::binary>> = packet,
         {:ok, payload, padding} <- strip_padding(header, body) do
      <<_v::2, _p::1, x::1, cc::4, m::1, pt::7, seq::16, ts::32, ssrc::32, rest::binary>> = header
      csrc_len = cc * 4
      <<csrc_bin::binary-size(^csrc_len), ext_bin::binary>> = rest

      extension =
        case {x, ext_bin} do
          {1, <<profile::16, _words::16, data::binary>>} -> {profile, data}
          _ -> nil
        end

      {:ok,
       %__MODULE__{
         marker: m == 1,
         payload_type: pt,
         sequence_number: seq,
         timestamp: ts,
         ssrc: ssrc,
         csrcs: for(<<csrc::32 <- csrc_bin>>, do: csrc),
         extension: extension,
         payload: payload,
         padding: padding
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  defp strip_padding(<<_::2, 0::1, _::bitstring>>, body), do: {:ok, body, 0}

  defp strip_padding(_header, body) when byte_size(body) > 0 do
    count = :binary.last(body)

    if count > 0 and count <= byte_size(body),
      do: {:ok, binary_part(body, 0, byte_size(body) - count), count},
      else: :error
  end

  defp strip_padding(_header, _body), do: :error

  @doc "Encodes an RTP packet."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = packet) do
    cc = length(packet.csrcs)
    x = if packet.extension, do: 1, else: 0
    p = if packet.padding > 0, do: 1, else: 0
    m = if packet.marker, do: 1, else: 0

    extension =
      case packet.extension do
        nil ->
          <<>>

        {profile, data} ->
          data = pad4(data)
          <<profile::16, div(byte_size(data), 4)::16, data::binary>>
      end

    padding =
      case packet.padding do
        0 -> <<>>
        n when n in 1..255 -> <<0::size((n - 1) * 8), n>>
      end

    IO.iodata_to_binary([
      <<2::2, p::1, x::1, cc::4, m::1, packet.payload_type::7,
        band(packet.sequence_number, 0xFFFF)::16, band(packet.timestamp, 0xFFFFFFFF)::32,
        packet.ssrc::32>>,
      for(csrc <- packet.csrcs, do: <<csrc::32>>),
      extension,
      packet.payload,
      padding
    ])
  end

  defp pad4(data) do
    case rem(byte_size(data), 4) do
      0 -> data
      r -> data <> <<0::size((4 - r) * 8)>>
    end
  end

  @doc """
  True when `packet` is RTCP rather than RTP on a multiplexed transport:
  the second byte is in 192..223 (RFC 5761 section 4).
  """
  @spec rtcp?(binary()) :: boolean()
  def rtcp?(<<2::2, _::6, type, _::binary>>) when type in 192..223, do: true
  def rtcp?(_packet), do: false

  @doc """
  True when `packet` starts like RTP or RTCP (first byte 128..191, RFC 7983
  section 7). STUN, DTLS and other traffic on the same 5-tuple is not.
  """
  @spec rtp_or_rtcp?(binary()) :: boolean()
  def rtp_or_rtcp?(<<first, _::binary>>) when first in 128..191, do: true
  def rtp_or_rtcp?(_packet), do: false
end
