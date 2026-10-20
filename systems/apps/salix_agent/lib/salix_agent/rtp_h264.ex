defmodule SalixAgent.RtpH264 do
  @moduledoc """
  The first complete H.264 key frame in an RTP stream (RFC 6184), as an Annex
  B byte stream with its parameter sets, for `SalixAgent.RtspSnapshot`.

  Packets pass through a reorder window of `@window` packets ordered by
  sequence number, from the first packet received (RTP interleaved on the
  RTSP connection arrives in order; the window absorbs what does not). A packet that is still missing when the window is full is
  lost: the access unit it belonged to is dropped, and assembly resumes after
  the next marker bit (the end of an access unit). An access unit is complete
  at its marker bit; it is returned when it holds an IDR slice (NAL type 5).
  Single NAL unit packets, STAP-A (24) and FU-A (28) are supported; an FU-A
  must run from its start to its end fragment without a gap. Parameter sets
  (SPS 7, PPS 8) come from the stream or, before it sends them, from the SDP
  `sprop-parameter-sets`.
  """

  import Bitwise

  @window 64
  @max_unit_bytes 2 * 1024 * 1024
  @start_code <<0, 0, 0, 1>>

  defstruct next: nil,
            held: %{},
            # Assembling an access unit: false after a loss until a marker.
            synced: true,
            unit: [],
            unit_bytes: 0,
            fragment: nil,
            fragment_bytes: 0,
            sps: nil,
            pps: nil

  @type t :: %__MODULE__{}

  @doc "A depacketizer with the SDP's parameter sets (NAL units without start codes)."
  @spec new([binary()]) :: t()
  def new(parameter_sets \\ []) do
    Enum.reduce(parameter_sets, %__MODULE__{}, &remember/2)
  end

  @doc """
  Add one RTP packet. Returns `{:frame, annex_b}` for the first complete key
  frame, `{:more, state}` otherwise, or `{:error, :oversized}`.
  """
  @spec push(t(), binary()) :: {:frame, binary()} | {:more, t()} | {:error, :oversized}
  def push(state, packet) do
    case rtp(packet) do
      {:ok, seq, marker, payload} -> receive_packet(state, seq, {marker, payload})
      :error -> {:more, state}
    end
  end

  defp rtp(
         <<2::2, padding::1, extension::1, csrcs::4, marker::1, _pt::7, seq::16, _ts::32,
           _ssrc::32, rest::binary>>
       ) do
    skip = csrcs * 4

    with <<_::binary-size(^skip), rest::binary>> <- rest,
         {:ok, rest} <- skip_extension(extension, rest),
         {:ok, payload} <- strip_padding(padding, rest) do
      {:ok, seq, marker == 1, payload}
    else
      _ -> :error
    end
  end

  defp rtp(_packet), do: :error

  defp skip_extension(0, rest), do: {:ok, rest}

  defp skip_extension(1, <<_profile::16, words::16, rest::binary>>)
       when byte_size(rest) >= words * 4,
       do: {:ok, binary_part(rest, words * 4, byte_size(rest) - words * 4)}

  defp skip_extension(_extension, _rest), do: :error

  defp strip_padding(0, rest), do: {:ok, rest}

  defp strip_padding(1, rest) when byte_size(rest) > 0 do
    count = :binary.last(rest)

    if count <= byte_size(rest),
      do: {:ok, binary_part(rest, 0, byte_size(rest) - count)},
      else: :error
  end

  defp strip_padding(_padding, _rest), do: :error

  # The reorder window, by 16-bit sequence distance from the next expected.
  defp receive_packet(%{next: nil} = state, seq, packet),
    do: receive_packet(%{state | next: seq}, seq, packet)

  defp receive_packet(state, seq, packet) do
    if distance(state.next, seq) >= 0x8000 do
      # Behind the window: a duplicate or a packet already given up for lost.
      {:more, state}
    else
      release(%{state | held: Map.put(state.held, seq, packet)})
    end
  end

  defp release(%{next: next, held: held} = state) do
    case Map.pop(held, next) do
      {nil, _held} when map_size(held) > @window ->
        # The next packet is lost: skip to the nearest held one.
        skip = Enum.min_by(Map.keys(held), &distance(next, &1))
        release(lost(%{state | next: skip}))

      {nil, _held} ->
        {:more, state}

      {{marker, payload}, held} ->
        state = %{state | held: held, next: band(next + 1, 0xFFFF)}

        case assemble(state, marker, payload) do
          {:more, state} -> release(state)
          other -> other
        end
    end
  end

  defp distance(from, to), do: band(to - from, 0xFFFF)

  defp lost(state),
    do: %{state | synced: false, unit: [], unit_bytes: 0, fragment: nil, fragment_bytes: 0}

  # Packets in order. Outside an access unit's start, wait for a marker.
  defp assemble(%{synced: false} = state, marker, _payload),
    do: {:more, if(marker, do: %{state | synced: true}, else: state)}

  defp assemble(state, marker, payload) do
    with {:ok, state} <- payload(state, payload) do
      cond do
        state.unit_bytes > @max_unit_bytes -> {:error, :oversized}
        marker -> end_of_unit(state)
        true -> {:more, state}
      end
    else
      :broken -> {:more, lost(state) |> then(&if(marker, do: %{&1 | synced: true}, else: &1))}
      {:error, :oversized} = error -> error
    end
  end

  # FU-A: a fragmented NAL unit.
  defp payload(state, <<indicator, start::1, stop::1, _reserved::1, type::5, data::binary>>)
       when band(indicator, 0x1F) == 28 do
    header = bor(band(indicator, 0xE0), type)

    case {start, state.fragment} do
      {1, nil} ->
        append_fragment(state, [<<header>>, data], byte_size(data) + 1, stop)

      {0, fragment} when fragment != nil ->
        append_fragment(state, data, byte_size(data), stop)

      _gap ->
        :broken
    end
  end

  defp payload(%{fragment: fragment}, _payload) when fragment != nil, do: :broken

  # STAP-A: several NAL units, each with a 16-bit size.
  defp payload(state, <<indicator, rest::binary>>) when band(indicator, 0x1F) == 24,
    do: aggregate(state, rest)

  defp payload(state, <<header, _::binary>> = nal) when band(header, 0x1F) in 1..23,
    do: {:ok, add_nal(state, nal)}

  defp payload(_state, _payload), do: :broken

  defp append_fragment(state, data, bytes, stop) do
    fragment_bytes = state.fragment_bytes + bytes

    # Reserve the Annex B start code as well as the unfinished NAL. Check
    # before retaining each fragment, including fragments without an end bit.
    if state.unit_bytes + 4 + fragment_bytes > @max_unit_bytes do
      {:error, :oversized}
    else
      fragment = [state.fragment || [], data]
      fragment_end(%{state | fragment: fragment, fragment_bytes: fragment_bytes}, stop)
    end
  end

  defp fragment_end(state, 0), do: {:ok, state}

  defp fragment_end(state, 1),
    do:
      {:ok,
       add_nal(%{state | fragment: nil, fragment_bytes: 0}, IO.iodata_to_binary(state.fragment))}

  defp aggregate(state, ""), do: {:ok, state}

  defp aggregate(state, <<size::16, nal::binary-size(size), rest::binary>>) when size > 0,
    do: aggregate(add_nal(state, nal), rest)

  defp aggregate(_state, _rest), do: :broken

  defp add_nal(state, nal) do
    state = remember(nal, state)

    %{
      state
      | unit: [state.unit, @start_code, nal],
        unit_bytes: state.unit_bytes + byte_size(nal) + 4
    }
  end

  defp remember(<<header, _::binary>> = nal, state) do
    case band(header, 0x1F) do
      7 -> %{state | sps: nal}
      8 -> %{state | pps: nal}
      _other -> state
    end
  end

  defp remember(_nal, state), do: state

  defp end_of_unit(%{fragment: fragment} = state) when fragment != nil,
    do: {:more, %{lost(state) | synced: true}}

  defp end_of_unit(state) do
    unit = IO.iodata_to_binary(state.unit)

    if (key_frame?(unit) and state.sps) && state.pps do
      {:frame, IO.iodata_to_binary([@start_code, state.sps, @start_code, state.pps, unit])}
    else
      {:more, %{state | unit: [], unit_bytes: 0}}
    end
  end

  defp key_frame?(unit) do
    unit
    |> :binary.split(@start_code, [:global])
    |> Enum.any?(fn
      <<header, _::binary>> -> band(header, 0x1F) == 5
      _ -> false
    end)
  end
end
