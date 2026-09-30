defmodule SalixSignalProto.CallSignaling do
  @moduledoc """
  1:1 call signaling (CRS-12): the call message codec and the wire-visible
  rules of the call flow.

  A call message is field 3 of the Signal content message (CRS-05 section
  6.3). It carries exactly one kind of payload (CRS-12 section 3.1):

    * `{:offer, %{call_id, media_type, parameters}}`
    * `{:answer, %{call_id, parameters}}`
    * `{:ice, call_id, [candidate]}`: one or more ICE updates, where a
      candidate is `{:added, "candidate:..."}` or
      `{:removed, {ip_tuple, port}}` (section 5.3)
    * `{:hangup, call_id, type, device_id | nil}` (section 3.6)
    * `{:busy, call_id}`
    * `{:opaque, data, urgency}`: group-call material (CRS-14), passed on
      unparsed

  `parameters` are the connection parameters of section 5.2 as
  `%{public_key, ice_ufrag, ice_pwd}` plus the optional video codec lists
  and bitrate.

  The rules are pure functions: `message_age/2` and `offer_expired?/1`
  (sections 6.1 and 10), `for_device?/2` (the destination filter of section
  3.1), `classify_offer/3` and `glare/2` (section 8), `caller_reaction/3`
  and `callee_reaction/3` (section 7.3) and `urgent?/1` (section 6).
  """

  alias SalixSignalProto.CallSignaling.Wire

  @max_offer_age_s 60
  @setup_timeout_ms 60_000
  @send_deadline_ms 15_000
  @max_call_id 0xFFFFFFFFFFFFFFFF

  # Video codec numbers (CRS-12 section 5.2.1).
  @vp8 8
  @vp9 9

  # Hangup types (CRS-12 section 3.6.1).
  @hangup_types %{
    normal: 0,
    accepted_elsewhere: 1,
    declined_elsewhere: 2,
    busy_elsewhere: 3,
    needs_permission: 4
  }

  # The placeholder candidate of a removal payload (CRS-12 section 5.3.2).
  @removal_placeholder "candidate:FAKE 1 tcp 0 127.0.0.1 0 typ host"

  @type call_id :: 0..0xFFFFFFFFFFFFFFFF
  @type hangup_type ::
          :normal
          | :accepted_elsewhere
          | :declined_elsewhere
          | :busy_elsewhere
          | :needs_permission
  @type parameters :: %{
          required(:public_key) => <<_::256>>,
          required(:ice_ufrag) => String.t(),
          required(:ice_pwd) => String.t(),
          optional(:max_bitrate_bps) => non_neg_integer() | nil,
          optional(:receive_video_codecs) => [atom() | integer()],
          optional(:encode_video_codecs) => [atom() | integer()],
          optional(:decode_video_codecs) => [atom() | integer()]
        }
  @type candidate :: {:added, String.t()} | {:removed, {:inet.ip_address(), 0..65_535}}
  @type payload ::
          {:offer, %{call_id: call_id(), media_type: :audio | :video, parameters: parameters()}}
          | {:answer, %{call_id: call_id(), parameters: parameters()}}
          | {:ice, call_id(), [candidate()]}
          | {:hangup, call_id(), hangup_type() | integer(), pos_integer() | nil}
          | {:busy, call_id()}
          | {:opaque, binary(), :droppable | :immediate | integer()}
  @type message :: %{payload: payload(), destination_device_id: pos_integer() | nil}

  # -- Constants ---------------------------------------------------------------

  @doc "Maximum age of a received offer, in seconds (CRS-12 section 10)."
  def max_offer_age_s, do: @max_offer_age_s

  @doc "Time from call start after which an unaccepted call ends (CRS-12 section 10)."
  def setup_timeout_ms, do: @setup_timeout_ms

  @doc "Time after which a signaling send counts as failed (CRS-12 section 10)."
  def send_deadline_ms, do: @send_deadline_ms

  @doc "The wire number of a hangup type (CRS-12 section 3.6.1)."
  @spec hangup_type_number(hangup_type()) :: 0..4
  def hangup_type_number(type), do: Map.fetch!(@hangup_types, type)

  @doc "A fresh call ID: uniformly random, unsigned 64 bits (CRS-12 section 4)."
  @spec new_call_id() :: call_id()
  def new_call_id do
    <<id::unsigned-64>> = :crypto.strong_rand_bytes(8)
    id
  end

  # -- Encoding ----------------------------------------------------------------

  @doc """
  Encodes a call message. `payload` is one of the payload terms in the
  module doc. `opts`: `destination_device_id` (targeted message; absent
  means broadcast). An offer's `media_type` defaults to `:audio`.
  """
  @spec encode(payload(), keyword()) :: binary()
  def encode(payload, opts \\ []) do
    fields =
      payload
      |> wire_payload()
      |> Map.put(:destination_device_id, opts[:destination_device_id])

    Wire.CallMessage |> struct(fields) |> Wire.CallMessage.encode()
  end

  @doc """
  Wraps an encoded call message as a content message with only field 3 set
  (CRS-05 section 5). The caller pads and encrypts it like any content.
  """
  @spec to_content(binary()) :: binary()
  def to_content(call_message) when is_binary(call_message),
    do: <<0x1A>> <> varint(byte_size(call_message)) <> call_message

  defp varint(n) when n < 0x80, do: <<n>>
  defp varint(n), do: <<0x80 + Bitwise.band(n, 0x7F)>> <> varint(Bitwise.bsr(n, 7))

  defp wire_payload({:offer, %{call_id: id, parameters: params} = offer}) do
    media = if Map.get(offer, :media_type, :audio) == :video, do: 1, else: 0
    %{offer: %Wire.Offer{call_id: id, media_type: media, opaque: encode_wrapper(params)}}
  end

  defp wire_payload({:answer, %{call_id: id, parameters: params}}),
    do: %{answer: %Wire.Answer{call_id: id, opaque: encode_wrapper(params)}}

  defp wire_payload({:ice, id, [_ | _] = candidates}) do
    updates =
      Enum.map(candidates, &%Wire.IceUpdate{call_id: id, opaque: encode_candidate(&1)})

    %{ice_updates: updates}
  end

  defp wire_payload({:hangup, id, type, device_id}) do
    type = if is_atom(type), do: hangup_type_number(type), else: type
    %{hangup: %Wire.Hangup{call_id: id, type: type, device_id: device_id}}
  end

  defp wire_payload({:busy, id}), do: %{busy: %Wire.Busy{call_id: id}}

  defp wire_payload({:opaque, data, urgency}) do
    urgency =
      case urgency do
        :droppable -> 0
        :immediate -> 1
        n when is_integer(n) -> n
      end

    %{opaque: %Wire.Opaque{data: data, urgency: urgency}}
  end

  @doc """
  Encodes the offer or answer opaque: the wrapper with the connection
  parameters in field 4 (CRS-12 sections 5.1 and 5.2).
  """
  @spec encode_wrapper(parameters()) :: binary()
  def encode_wrapper(%{public_key: <<_::binary-32>> = key, ice_ufrag: ufrag, ice_pwd: pwd} = p) do
    params = %Wire.ConnectionParameters{
      public_key: key,
      ice_ufrag: ufrag,
      ice_pwd: pwd,
      receive_video_codecs: codecs(p[:receive_video_codecs]),
      max_bitrate_bps: p[:max_bitrate_bps],
      encode_video_codecs: codecs(p[:encode_video_codecs]),
      decode_video_codecs: codecs(p[:decode_video_codecs])
    }

    Wire.OfferAnswerWrapper.encode(%Wire.OfferAnswerWrapper{connection_parameters: params})
  end

  defp codecs(nil), do: []
  defp codecs(list), do: Enum.map(list, &%Wire.VideoCodec{codec: codec_number(&1)})

  defp codec_number(:vp8), do: @vp8
  defp codec_number(:vp9), do: @vp9
  defp codec_number(n) when is_integer(n), do: n

  @doc "Encodes the ICE update opaque for one candidate (CRS-12 section 5.3)."
  @spec encode_candidate(candidate()) :: binary()
  def encode_candidate({:added, "candidate:" <> _ = candidate}) do
    Wire.IceCandidate.encode(%Wire.IceCandidate{
      added: %Wire.AddedCandidate{candidate: candidate}
    })
  end

  def encode_candidate({:removed, {ip, port}}) when port in 0..65_535 do
    Wire.IceCandidate.encode(%Wire.IceCandidate{
      added: %Wire.AddedCandidate{candidate: @removal_placeholder},
      removed: %Wire.SocketAddress{ip: ip_bytes(ip), port: port}
    })
  end

  defp ip_bytes({a, b, c, d}), do: <<a, b, c, d>>

  defp ip_bytes({_, _, _, _, _, _, _, _} = ip),
    do: for(w <- Tuple.to_list(ip), into: <<>>, do: <<w::16>>)

  # -- Decoding ----------------------------------------------------------------

  @doc """
  Decodes a call message.

  Payloads are taken in the receive order of CRS-12 section 3.1 (offer,
  answer, ICE updates, hangup, busy, opaque); the first valid one is the
  message's payload. A payload that a receiver ignores does not count:
  an offer or answer without a call ID or opaque, ICE updates of which none
  has an opaque, and an opaque without data (sections 3.2, 3.4, 3.7).

  Returns `{:error, :malformed}` when the bytes do not parse, and
  `{:error, :empty}` when no payload remains. The connection parameters
  inside an offer or answer are decoded by `decode_parameters/1`; an offer or
  answer whose wrapper fails there is returned as
  `{:error, {:invalid_offer | :invalid_answer, call_id}}`: the receiver
  ends that call (CRS-12 section 5.1, CRS-13 section 3).
  """
  @spec decode(binary()) ::
          {:ok, message()}
          | {:error, :malformed | :empty | {:invalid_offer | :invalid_answer, call_id()}}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, wire} <- safe_decode(Wire.CallMessage, bytes) do
      destination =
        if wire.destination_device_id in [nil, 0], do: nil, else: wire.destination_device_id

      case payload(wire) do
        {:ok, payload} -> {:ok, %{payload: payload, destination_device_id: destination}}
        {:error, _} = error -> error
      end
    end
  end

  defp payload(wire) do
    [
      fn -> offer(wire.offer) end,
      fn -> answer(wire.answer) end,
      fn -> ice(wire.ice_updates) end,
      fn -> hangup(wire.hangup) end,
      fn -> busy(wire.busy) end,
      fn -> opaque(wire.opaque) end
    ]
    |> Enum.find_value({:error, :empty}, fn step ->
      case step.() do
        nil -> nil
        result -> result
      end
    end)
  end

  defp offer(%Wire.Offer{call_id: id, opaque: opaque} = offer)
       when is_integer(id) and is_binary(opaque) do
    case decode_parameters(opaque) do
      {:ok, params} ->
        media = if offer.media_type == 1, do: :video, else: :audio
        {:ok, {:offer, %{call_id: id, media_type: media, parameters: params}}}

      {:error, _} ->
        {:error, {:invalid_offer, id}}
    end
  end

  defp offer(_offer), do: nil

  defp answer(%Wire.Answer{call_id: id, opaque: opaque})
       when is_integer(id) and is_binary(opaque) do
    case decode_parameters(opaque) do
      {:ok, params} -> {:ok, {:answer, %{call_id: id, parameters: params}}}
      {:error, _} -> {:error, {:invalid_answer, id}}
    end
  end

  defp answer(_answer), do: nil

  # All ICE updates of one message carry the call ID of the first one
  # (CRS-12 section 3.4). Updates without an opaque, and opaques that do
  # not decode to a candidate, are skipped.
  defp ice([%Wire.IceUpdate{call_id: id} | _] = updates) when is_integer(id) do
    candidates =
      updates
      |> Enum.map(& &1.opaque)
      |> Enum.reject(&is_nil/1)
      |> Enum.flat_map(fn opaque ->
        case decode_candidate(opaque) do
          {:ok, candidate} -> [candidate]
          {:error, _} -> []
        end
      end)

    if candidates == [], do: nil, else: {:ok, {:ice, id, candidates}}
  end

  defp ice(_updates), do: nil

  # CRS-12 section 3.6: a hangup without its type (field 2) may be read as
  # type 0 or dropped; Comma reads it as type 0, as Desktop and iOS do. Deployed
  # senders always encode the type, and so does `encode/1`.
  defp hangup(%Wire.Hangup{call_id: id} = hangup) when is_integer(id) do
    device = if hangup.device_id in [nil, 0], do: nil, else: hangup.device_id
    {:ok, {:hangup, id, hangup_type(hangup.type || 0), device}}
  end

  defp hangup(_hangup), do: nil

  defp busy(%Wire.Busy{call_id: id}) when is_integer(id), do: {:ok, {:busy, id}}
  defp busy(_busy), do: nil

  defp opaque(%Wire.Opaque{data: data} = opaque) when is_binary(data) do
    urgency =
      case opaque.urgency || 0 do
        0 -> :droppable
        1 -> :immediate
        n -> n
      end

    {:ok, {:opaque, data, urgency}}
  end

  defp opaque(_opaque), do: nil

  defp hangup_type(number) do
    Enum.find_value(@hangup_types, number, fn {name, n} -> if n == number, do: name end)
  end

  @doc """
  Decodes the offer or answer opaque (CRS-12 sections 5.1 and 5.2).

  The wrapper must have field 4, and the parameters a 32-byte public key and
  ICE credentials that pass the remote credential checks of CRS-13 section
  3: a ufrag of 4 to 256 and a password of 22 to 256 characters, each an
  ASCII letter or digit, `+`, `/`, or one of `-`, `=`, `#`, `_`, which Signal
  clients also accept. Otherwise the result is `{:error,
  :unsupported_version}` (no field 4: an older protocol version) or
  `{:error, :invalid_parameters}`. Video codec entries become `:vp8`, `:vp9`
  or their number when unknown.
  """
  @spec decode_parameters(binary()) ::
          {:ok, parameters()} | {:error, :unsupported_version | :invalid_parameters}
  def decode_parameters(opaque) when is_binary(opaque) do
    case safe_decode(Wire.OfferAnswerWrapper, opaque) do
      {:ok, %Wire.OfferAnswerWrapper{connection_parameters: %Wire.ConnectionParameters{} = p}} ->
        if valid_parameters?(p), do: {:ok, parameters(p)}, else: {:error, :invalid_parameters}

      _ ->
        {:error, :unsupported_version}
    end
  end

  defp valid_parameters?(%Wire.ConnectionParameters{public_key: <<_::binary-32>>} = p),
    do: ice_credential?(p.ice_ufrag, 4) and ice_credential?(p.ice_pwd, 22)

  defp valid_parameters?(_params), do: false

  defp ice_credential?(value, min) when is_binary(value) and byte_size(value) in min..256//1,
    do: value |> :binary.bin_to_list() |> Enum.all?(&ice_char?/1)

  defp ice_credential?(_value, _min), do: false

  defp ice_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true
  defp ice_char?(c), do: c in ~c"+/-=#_"

  defp parameters(p) do
    %{
      public_key: p.public_key,
      ice_ufrag: p.ice_ufrag,
      ice_pwd: p.ice_pwd,
      max_bitrate_bps: p.max_bitrate_bps,
      receive_video_codecs: codec_names(p.receive_video_codecs),
      encode_video_codecs: codec_names(p.encode_video_codecs),
      decode_video_codecs: codec_names(p.decode_video_codecs)
    }
  end

  defp codec_names(entries) do
    Enum.flat_map(entries, fn
      %Wire.VideoCodec{codec: @vp8} -> [:vp8]
      %Wire.VideoCodec{codec: @vp9} -> [:vp9]
      %Wire.VideoCodec{codec: n} when is_integer(n) -> [n]
      _ -> []
    end)
  end

  @doc """
  Decodes the ICE update opaque (CRS-12 section 5.3). A payload with field
  3 is a removal, whatever field 2 holds; the address must have 4 or 16 IP
  bytes and a port up to 65535. Otherwise field 2 must hold a candidate
  string.
  """
  @spec decode_candidate(binary()) :: {:ok, candidate()} | {:error, :invalid_candidate}
  def decode_candidate(opaque) when is_binary(opaque) do
    case safe_decode(Wire.IceCandidate, opaque) do
      {:ok, %Wire.IceCandidate{removed: %Wire.SocketAddress{} = address}} ->
        removal(address)

      {:ok, %Wire.IceCandidate{added: %Wire.AddedCandidate{candidate: c}}} when is_binary(c) ->
        {:ok, {:added, c}}

      _ ->
        {:error, :invalid_candidate}
    end
  end

  defp removal(%Wire.SocketAddress{ip: ip, port: port})
       when is_integer(port) and port <= 65_535 do
    case ip do
      <<a, b, c, d>> ->
        {:ok, {:removed, {{a, b, c, d}, port}}}

      <<_::binary-16>> ->
        words = for <<w::16 <- ip>>, do: w
        {:ok, {:removed, {List.to_tuple(words), port}}}

      _ ->
        {:error, :invalid_candidate}
    end
  end

  defp removal(_address), do: {:error, :invalid_candidate}

  defp safe_decode(module, bytes) do
    {:ok, module.decode(bytes)}
  rescue
    _ -> {:error, :malformed}
  end

  # -- Parameters for an audio-only peer ----------------------------------------

  @doc """
  Connection parameters for an audio-only peer: the key and ICE credentials
  plus VP8 in all three codec lists, so that both media layouts negotiate
  (CRS-12 section 5.2, recommendation), and `max_bitrate_bps`.
  """
  @spec audio_only_parameters(map(), non_neg_integer()) :: parameters()
  def audio_only_parameters(%{public_key: key, ice_ufrag: ufrag, ice_pwd: pwd}, max_bitrate_bps) do
    %{
      public_key: key,
      ice_ufrag: ufrag,
      ice_pwd: pwd,
      receive_video_codecs: [:vp8],
      max_bitrate_bps: max_bitrate_bps,
      encode_video_codecs: [:vp8],
      decode_video_codecs: [:vp8]
    }
  end

  # -- Rules -------------------------------------------------------------------

  @doc """
  True when a receiving device with `own_device_id` processes the message:
  the destination device is absent, zero, or its own (CRS-12 section 3.1).
  """
  @spec for_device?(message(), pos_integer()) :: boolean()
  def for_device?(%{destination_device_id: nil}, _own), do: true
  def for_device?(%{destination_device_id: id}, own), do: id == own

  @doc """
  Age of a received signaling message in whole seconds (CRS-12 section 6.1):
  delivery time (the `X-Signal-Timestamp` of the delivering request) minus
  the envelope server timestamp, floored. 0 when either is missing or the
  delivery time is not later.
  """
  @spec message_age(integer() | nil, integer() | nil) :: non_neg_integer()
  def message_age(delivery_ms, server_ms)
      when is_integer(delivery_ms) and is_integer(server_ms) and delivery_ms > server_ms,
      do: div(delivery_ms - server_ms, 1000)

  def message_age(_delivery_ms, _server_ms), do: 0

  @doc "True when an offer of this age is expired (CRS-12 section 10)."
  @spec offer_expired?(non_neg_integer()) :: boolean()
  def offer_expired?(age_s), do: age_s > @max_offer_age_s

  @doc """
  The urgent flag of the send request for a payload: true for an offer, a
  hangup and an opaque with urgency 1 (CRS-12 section 6, recommendation).
  """
  @spec urgent?(payload()) :: boolean()
  def urgent?({:offer, _}), do: true
  def urgent?({:hangup, _, _, _}), do: true
  def urgent?({:opaque, _, :immediate}), do: true
  def urgent?(_payload), do: false

  @doc """
  Classifies an offer from `offering_device` against this device's existing
  1:1 call with the same account (CRS-12 section 8). `existing` is nil or
  `%{call_id, connected_device, connected_and_accepted}`, where
  `connected_device` is the peer device the existing call is connected to
  (nil while it is not connected to one).

  Returns:

    * `:ring`: answer the offer
    * `:busy`: send busy for the offer, keep the existing call
    * `:recall`: end the existing call without a hangup, then ring
    * `:ignore`: glare, the existing call wins; send nothing
    * `:replace`: glare, the incoming call wins; end the existing call with
      hangup type 0, then ring
    * `:both_lose`: glare with equal call IDs; end the existing call with
      hangup type 0 and send busy for the offer

  A call with a different account, or a group call, is decided by the
  caller of this function: CRS-12 answers busy.
  """
  @spec classify_offer(map() | nil, call_id(), pos_integer()) ::
          :ring | :busy | :recall | :ignore | :replace | :both_lose
  def classify_offer(nil, _incoming_call_id, _offering_device), do: :ring

  def classify_offer(%{connected_and_accepted: true, connected_device: device}, _id, device),
    do: :recall

  def classify_offer(%{connected_device: device}, _id, offering)
      when is_integer(device) and device != offering,
      do: :busy

  def classify_offer(%{connected_and_accepted: true}, _id, _offering), do: :busy

  def classify_offer(%{call_id: existing}, incoming, _offering), do: glare(existing, incoming)

  @doc """
  The glare tie-break of CRS-12 section 8: call IDs compare as unsigned
  64-bit integers. Returns `:ignore` (existing wins), `:replace` (incoming
  wins) or `:both_lose`.
  """
  @spec glare(call_id(), call_id()) :: :ignore | :replace | :both_lose
  def glare(existing, incoming)
      when existing in 0..@max_call_id//1 and incoming in 0..@max_call_id//1 do
    cond do
      existing > incoming -> :ignore
      existing < incoming -> :replace
      true -> :both_lose
    end
  end

  @doc """
  The caller's reaction to a hangup or busy from callee device `device`
  (CRS-12 sections 7.3 and 8). `call` is
  `%{accepted: boolean, connected_device: device | nil}`.

  `event` is `{:hangup, type, device_id}` (the hangup's own device field is
  unused here) or `:busy`. Returns:

    * `:ignore`: an unexpected combination (types 1 to 3 from a callee), or
      a message from a device other than the connected one
    * `:end`: end the call and send nothing (the connected callee hung up)
    * `{:end, {:hangup, type, device}}`: end the call and broadcast this
      hangup, also in-band to the other devices
  """
  @spec caller_reaction(
          map(),
          {:hangup, hangup_type() | integer(), term()} | :busy,
          pos_integer()
        ) ::
          :ignore | :end | {:end, {:hangup, hangup_type(), pos_integer()}}
  def caller_reaction(%{connected_device: connected}, _event, device)
      when is_integer(connected) and connected != device,
      do: :ignore

  def caller_reaction(_call, {:hangup, type, _}, _device)
      when type in [:accepted_elsewhere, :declined_elsewhere, :busy_elsewhere],
      do: :ignore

  def caller_reaction(_call, {:hangup, type, _}, _device) when not is_atom(type), do: :ignore

  def caller_reaction(_call, :busy, device), do: {:end, {:hangup, :busy_elsewhere, device}}

  def caller_reaction(_call, {:hangup, :needs_permission, _}, device),
    do: {:end, {:hangup, :needs_permission, device}}

  def caller_reaction(%{accepted: false}, {:hangup, :normal, _}, device),
    do: {:end, {:hangup, :declined_elsewhere, device}}

  def caller_reaction(%{accepted: true}, {:hangup, :normal, _}, _device), do: :end

  @doc """
  The callee's reaction to a hangup from the caller (CRS-12 sections 7.1 and
  7.3). Type 0 ends the call. Types 1 to 3 end it unless the hangup's device
  field is this device. Type 4 and unknown types are ignored. The callee
  sends nothing in any case. Returns `:end` or `:ignore`.
  """
  @spec callee_reaction(hangup_type() | integer(), pos_integer() | nil, pos_integer()) ::
          :end | :ignore
  def callee_reaction(:normal, _device, _own), do: :end

  def callee_reaction(type, device, own)
      when type in [:accepted_elsewhere, :declined_elsewhere, :busy_elsewhere],
      do: if(device == own, do: :ignore, else: :end)

  def callee_reaction(_type, _device, _own), do: :ignore
end
