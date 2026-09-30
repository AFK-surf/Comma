defmodule SalixSignalProto.GroupCall.Messages do
  @moduledoc """
  Group-call messages (CRS-14 sections 9 to 11).

  ## Over Signal messages

  Media keys, leave notices and rings travel in the opaque payload of a
  call message (CRS-12 sections 3.7 and 5.4):

    * `media_key/4` and `leaving/2` build the encoded call message of a
      device-to-device message (section 9.1, 10.3), urgency droppable.
    * `ring/3` builds a ring or its cancellation, urgency 1 (section 11).
    * `decode_opaque/1` reads the opaque call message: `{:device, map}`,
      `{:ring, map}` or `{:ring_response, map}`, examining the ring
      intention first, then the ring response, then the device message.

  ## Through the SFU

    * `heartbeat/1`, `leaving_via_sfu/0`: device-to-device messages that are
      frame-encrypted and sent as RTP data (sections 10.1 to 10.3).
      `decode_device_data/1` reads received ones.
    * `video_request/1`, `leave_sfu/0`, `ack/1`: device-to-SFU messages
      (sections 10.4 to 10.6), sent in plain RTP data on SSRC 1.
    * `decode_sfu/1`: an SFU-to-device message, with `peek_info/1` for the
      device-joined-or-left notification (section 10.7).
  """

  alias SalixSignalProto.CallSignaling
  alias SalixSignalProto.GroupCall.Wire

  @ring_types %{0 => :ring, 1 => :cancelled}
  @ring_response_types %{0 => :ringing, 1 => :accepted, 2 => :declined, 3 => :busy}

  # -- Over Signal messages ----------------------------------------------------

  @doc """
  The call message that carries this device's media send key `{counter,
  secret}` for the call in group `group_id` (32 bytes), with the sender's
  own `demux_id` (section 9.1).
  """
  @spec media_key(binary(), 0..255, <<_::256>>, non_neg_integer()) :: binary()
  def media_key(<<_::binary-32>> = group_id, counter, <<_::binary-32>> = secret, demux_id)
      when counter in 0..255 do
    device_call_message(%Wire.DeviceToDevice{
      group_id: group_id,
      media_key: %Wire.MediaKey{ratchet_counter: counter, secret: secret, demux_id: demux_id}
    })
  end

  @doc "The call message that announces this device leaving (section 10.3 step 2)."
  @spec leaving(binary(), non_neg_integer()) :: binary()
  def leaving(<<_::binary-32>> = group_id, demux_id) do
    device_call_message(%Wire.DeviceToDevice{
      group_id: group_id,
      leaving: %Wire.Leaving{demux_id: demux_id}
    })
  end

  defp device_call_message(device) do
    opaque = Wire.OpaqueCallMessage.encode(%Wire.OpaqueCallMessage{device_message: device})
    CallSignaling.encode({:opaque, opaque, :droppable})
  end

  @doc """
  The call message of a ring (`:ring`) or its cancellation (`:cancelled`)
  for group `group_id` (section 11). Urgency 1: handle immediately.
  """
  @spec ring(binary(), :ring | :cancelled, integer()) :: binary()
  def ring(<<_::binary-32>> = group_id, type, ring_id) when type in [:ring, :cancelled] do
    number = if type == :ring, do: 0, else: 1

    opaque =
      Wire.OpaqueCallMessage.encode(%Wire.OpaqueCallMessage{
        ring_intention: %Wire.RingIntention{group_id: group_id, type: number, ring_id: ring_id}
      })

    CallSignaling.encode({:opaque, opaque, :immediate})
  end

  @doc """
  Reads the data of an opaque call payload (CRS-12 section 5.4).

    * `{:device, %{group_id, media_key, leaving}}`: `media_key` is
      `%{counter, secret, demux_id}` or nil; a key with a counter above 255,
      a secret that is not 32 bytes or no demux ID is left out (section
      9.1). `leaving` is the leaving device's demux ID or nil.
    * `{:ring, %{group_id, type, ring_id}}`: `type` is `:ring`,
      `:cancelled` or an unknown number.
    * `{:ring_response, %{group_id, type, ring_id}}`: `type` is `:ringing`,
      `:accepted`, `:declined`, `:busy` or an unknown number.
  """
  @spec decode_opaque(binary()) ::
          {:ok, {:device | :ring | :ring_response, map()}} | {:error, :invalid}
  def decode_opaque(data) when is_binary(data) do
    case safe_decode(Wire.OpaqueCallMessage, data) do
      {:ok, %Wire.OpaqueCallMessage{ring_intention: %Wire.RingIntention{} = ring}} ->
        ring_fields(ring, @ring_types, :ring)

      {:ok, %Wire.OpaqueCallMessage{ring_response: %Wire.RingResponse{} = response}} ->
        ring_fields(response, @ring_response_types, :ring_response)

      {:ok, %Wire.OpaqueCallMessage{device_message: %Wire.DeviceToDevice{} = device}} ->
        {:ok, {:device, device_fields(device)}}

      _ ->
        {:error, :invalid}
    end
  end

  defp ring_fields(%{group_id: gid, type: type, ring_id: id}, types, kind)
       when is_binary(gid) and is_integer(id) do
    {:ok, {kind, %{group_id: gid, type: Map.get(types, type || 0, type), ring_id: id}}}
  end

  defp ring_fields(_message, _types, _kind), do: {:error, :invalid}

  defp device_fields(%Wire.DeviceToDevice{} = device) do
    %{
      group_id: device.group_id,
      media_key: media_key_fields(device.media_key),
      leaving: leaving_fields(device.leaving)
    }
  end

  defp media_key_fields(%Wire.MediaKey{
         ratchet_counter: counter,
         secret: <<_::binary-32>> = secret,
         demux_id: demux
       })
       when is_integer(demux) do
    counter = counter || 0
    if counter in 0..255, do: %{counter: counter, secret: secret, demux_id: demux}
  end

  defp media_key_fields(_key), do: nil

  defp leaving_fields(%Wire.Leaving{demux_id: demux}) when is_integer(demux), do: demux
  defp leaving_fields(_leaving), do: nil

  # -- Device to device, through the SFU ---------------------------------------

  @doc """
  A heartbeat (section 10.2). An audio-only device reports video muted.
  Options: `audio_muted` (default false).
  """
  @spec heartbeat(keyword()) :: binary()
  def heartbeat(opts \\ []) do
    Wire.DeviceToDevice.encode(%Wire.DeviceToDevice{
      heartbeat: %Wire.Heartbeat{
        audio_muted: Keyword.get(opts, :audio_muted, false),
        video_muted: true
      }
    })
  end

  @doc "The leaving message sent through the SFU, with no demux ID (section 10.3 step 1)."
  @spec leaving_via_sfu() :: binary()
  def leaving_via_sfu,
    do: Wire.DeviceToDevice.encode(%Wire.DeviceToDevice{leaving: %Wire.Leaving{}})

  @doc """
  Reads a decrypted device-to-device message received through the SFU:
  `{:heartbeat, %{audio_muted, video_muted}}`, `:leaving`, `{:reaction,
  emoji}`, `{:remote_mute, demux_id}` or `:other`.
  """
  @spec decode_device_data(binary()) :: {:ok, term()} | {:error, :invalid}
  def decode_device_data(bytes) when is_binary(bytes) do
    case safe_decode(Wire.DeviceToDevice, bytes) do
      {:ok, %Wire.DeviceToDevice{heartbeat: %Wire.Heartbeat{} = beat}} ->
        {:ok,
         {:heartbeat,
          %{audio_muted: beat.audio_muted == true, video_muted: beat.video_muted == true}}}

      {:ok, %Wire.DeviceToDevice{leaving: %Wire.Leaving{}}} ->
        {:ok, :leaving}

      {:ok, %Wire.DeviceToDevice{reaction: %Wire.Reaction{value: value}}}
      when is_binary(value) and byte_size(value) <= 256 ->
        {:ok, {:reaction, value}}

      {:ok,
       %Wire.DeviceToDevice{remote_mute_request: %Wire.RemoteMuteRequest{target_demux_id: id}}}
      when is_integer(id) ->
        {:ok, {:remote_mute, id}}

      {:ok, _other} ->
        {:ok, :other}

      :error ->
        {:error, :invalid}
    end
  end

  # -- Device to SFU -----------------------------------------------------------

  @doc """
  A video request for no video (section 10.5): height 0 for every remote
  demux ID and for the active speaker.
  """
  @spec video_request([non_neg_integer()]) :: binary()
  def video_request(demux_ids) do
    Wire.DeviceToSfu.encode(%Wire.DeviceToSfu{
      video_request: %Wire.VideoRequest{
        requests: Enum.map(demux_ids, &%Wire.VideoRequestEntry{height: 0, demux_id: &1}),
        active_speaker_height: 0
      }
    })
  end

  @doc "The device-to-SFU leave message (section 10.4, field 2)."
  @spec leave_sfu() :: binary()
  def leave_sfu, do: Wire.DeviceToSfu.encode(%Wire.DeviceToSfu{leave: %Wire.Empty{}})

  @doc """
  A pure acknowledgement (section 10.6): the next reliable sequence number
  this device expects from the SFU.
  """
  @spec ack(pos_integer()) :: binary()
  def ack(next) when is_integer(next) and next > 0 do
    Wire.DeviceToSfu.encode(%Wire.DeviceToSfu{reliability: %Wire.ReliabilityHeader{ack: next}})
  end

  # -- SFU to device -----------------------------------------------------------

  @doc "Decodes an SFU-to-device message."
  @spec decode_sfu(binary()) :: {:ok, struct()} | {:error, :invalid}
  def decode_sfu(bytes) when is_binary(bytes) do
    case safe_decode(Wire.SfuToDevice, bytes) do
      {:ok, message} -> {:ok, message}
      :error -> {:error, :invalid}
    end
  end

  @doc """
  The peek carried by a device-joined-or-left notification (section 10.7),
  in the shape of `SalixSignalProto.GroupCall.Sfu.decode_peek/2`. Returns
  `:repeek` when the notification has no peek info or a device entry
  without a demux ID: the client then peeks over HTTP.
  """
  @spec peek_info(struct()) :: {:ok, map()} | :repeek
  def peek_info(%Wire.SfuToDevice{
        device_joined_or_left: %Wire.DeviceJoinedOrLeft{peek_info: %Wire.PeekInfo{} = info}
      }) do
    with {:ok, devices} <- peek_devices(info.devices),
         {:ok, pending} <- peek_devices(info.pending_devices) do
      {:ok,
       %{
         era_id: info.era_id,
         max_devices: info.max_devices,
         creator: info.creator,
         devices: devices,
         pending: pending
       }}
    end
  end

  def peek_info(_message), do: :repeek

  defp peek_devices(devices) do
    if Enum.all?(devices, &is_integer(&1.demux_id)) do
      {:ok,
       Enum.map(devices, fn device ->
         %{
           demux_id: device.demux_id,
           opaque_user_id: device.opaque_user_id,
           requires_svc: device.requires_svc == true
         }
       end)}
    else
      :repeek
    end
  end

  defp safe_decode(module, bytes) do
    {:ok, module.decode(bytes)}
  rescue
    _ -> :error
  end
end
