defmodule SalixMeetNative.Device do
  @moduledoc false

  alias SalixMeetNative.Codec
  alias SalixMeetNative.Rpc
  alias SalixMeetNative.Sync
  alias SalixMeetNative.Wire

  @spec method(String.t()) :: :create | :update
  def method(url) do
    if String.contains?(url, "/UpdateMeetingDevice"), do: :update, else: :create
  end

  @spec bind_media_session(:create | :update, binary(), String.t()) :: {:ok, binary()} | :error
  def bind_media_session(:update, body, msid) do
    case Codec.decode(Wire.UpdateMeetingDeviceRequest, body) do
      {:ok, %Wire.UpdateMeetingDeviceRequest{device: %Wire.MeetingDevice{} = device} = req} ->
        {:ok, Codec.encode(%{req | device: %{device | cloud_session_id: msid}})}

      _ ->
        :error
    end
  end

  def bind_media_session(:create, body, msid) do
    case Codec.decode(Wire.CreateMeetingDeviceRequest, body) do
      {:ok, %Wire.CreateMeetingDeviceRequest{device: %Wire.MeetingDevice{} = device} = req} ->
        {:ok, Codec.encode(%{req | device: %{device | cloud_session_id: msid}})}

      _ ->
        :error
    end
  end

  @spec space(:create | :update, binary()) :: String.t() | nil
  def space(:update, body) do
    with {:ok, %Wire.UpdateMeetingDeviceRequest{device: %Wire.MeetingDevice{name: name}}} <-
           Codec.decode(Wire.UpdateMeetingDeviceRequest, body),
         [space, _] <- String.split(name, "/devices/", parts: 2),
         true <- space != "" do
      space
    else
      _ -> nil
    end
  end

  def space(:create, body) do
    case Codec.decode(Wire.CreateMeetingDeviceRequest, body) do
      {:ok, %Wire.CreateMeetingDeviceRequest{space: space}} when space != "" -> space
      _ -> nil
    end
  end

  @spec decode_registered(binary()) :: {:ok, Wire.MeetingDevice.t()} | :error
  def decode_registered(body) do
    case Codec.decode_rpc_response(Wire.MeetingDevice, body) do
      {:ok, %Wire.MeetingDevice{name: name} = device} when name != "" -> {:ok, device}
      _ -> :error
    end
  end

  @advertised_capability_ids [
    3,
    17,
    2,
    12,
    20,
    18,
    4,
    10,
    5,
    21,
    22,
    15,
    16,
    1,
    6,
    9,
    28,
    27,
    23,
    24,
    26,
    29,
    30,
    31,
    36,
    34,
    33,
    35
  ]

  @doc "Synthesize the native CreateMeetingDevice body (no display_name; authenticated account)."
  def create_body(space, cloud_session_id) do
    Codec.encode(%Wire.CreateMeetingDeviceRequest{
      space: space,
      device: %Wire.MeetingDevice{
        join_state: :DEVICE_JOIN_STATE_JOINED,
        cloud_session_id: cloud_session_id,
        participation_mode: :PARTICIPATION_MODE_DEFAULT,
        media_capture_type: :MEDIA_CAPTURE_TYPE_CAMERA_MIC,
        device_capability_versions: [4],
        advertised_capability_ids: @advertised_capability_ids
      }
    })
  end

  def ack_operation_body(device, op) do
    Codec.encode(%Wire.UpdateMeetingDeviceRequest{
      device: %Wire.MeetingDevice{
        name: device,
        ack_requirements: [%Wire.AckRequirement{operation: op, state: 2}]
      }
    })
  end

  def mark_joined_body(device, cloud_session_id) do
    Codec.encode(%Wire.UpdateMeetingDeviceRequest{
      device: %Wire.MeetingDevice{
        name: device,
        join_state: :DEVICE_JOIN_STATE_JOINED,
        cloud_session_id: cloud_session_id,
        participation_mode: :PARTICIPATION_MODE_DEFAULT,
        media_capture_type: :MEDIA_CAPTURE_TYPE_CAMERA_MIC
      },
      update_mask: %Wire.FieldMask{
        paths: ["cloud_session_id", "join_state", "media_capture_type", "participation_mode"]
      }
    })
  end

  def mark_left_body(device) do
    Codec.encode(%Wire.UpdateMeetingDeviceRequest{
      device: %Wire.MeetingDevice{name: device, join_state: :DEVICE_JOIN_STATE_LEFT},
      update_mask: %Wire.FieldMask{paths: ["join_state"]}
    })
  end

  def create_hand_raise_body(space),
    do: Codec.encode(%Wire.CreateHandRaiseRequest{space: space, request: %Wire.Empty{}})

  def delete_hand_raise_body(hand_raise),
    do: Codec.encode(%Wire.DeleteHandRaiseRequest{hand_raise: hand_raise})

  def bulk_admit_body(space, device) do
    Codec.encode(%Wire.BulkUpdateMeetingDevicesRequest{
      space: space,
      device_name: device,
      patch: %Wire.MeetingDevice{join_state: :DEVICE_JOIN_STATE_JOINED},
      update_mask: %Wire.FieldMask{paths: ["join_state"]}
    })
  end

  def acknowledge_operation(rpc, device, op),
    do: update_own(rpc, ack_operation_body(device, op))

  def mark_joined(rpc, device, cloud_session_id),
    do: update_own(rpc, mark_joined_body(device, cloud_session_id))

  def mark_left(rpc, device, opts \\ []), do: update_own(rpc, mark_left_body(device), opts)

  def create_hand_raise(%{space: space} = rpc) do
    case call(rpc, "MeetingHandRaiseService", "CreateHandRaise", create_hand_raise_body(space)) do
      {:ok, 200, body, _headers} ->
        case Codec.decode_rpc_response(Wire.CreateHandRaiseResponse, body) do
          {:ok, %Wire.CreateHandRaiseResponse{hand_raise: hand_raise}} -> {:ok, hand_raise}
          :error -> {:ok, ""}
        end

      {:ok, status, _body, _headers} ->
        {:error, {:status, status}}

      {:error, _} = error ->
        error
    end
  end

  def delete_hand_raise(rpc, hand_raise),
    do:
      status(
        call(
          rpc,
          "MeetingHandRaiseService",
          "DeleteHandRaise",
          delete_hand_raise_body(hand_raise)
        )
      )

  @spec pending_acks(map(), String.t()) ::
          {:ok, [non_neg_integer()], atom() | integer() | nil} | {:error, term()}
  def pending_acks(%{space: space} = rpc, device) do
    case call(
           rpc,
           "MeetingSpaceService",
           "SyncMeetingSpaceCollections",
           Sync.encode_request(space, %{})
         ) do
      {:ok, 200, body, _headers} ->
        devices =
          for %{collection: :devices, resources: resources} <- Sync.parse_response(body),
              raw <- resources,
              {:ok, %Wire.MeetingDevice{name: ^device} = d} <- [
                Codec.decode(Wire.MeetingDevice, raw)
              ],
              do: d

        pending = for d <- devices, r <- d.ack_requirements, r.state == 1, do: r.operation
        join_state = devices |> List.last() |> then(&(&1 && &1.join_state))
        {:ok, pending, join_state}

      {:ok, status, _body, _headers} ->
        {:error, {:status, status}}

      {:error, _} = error ->
        error
    end
  end

  defp update_own(rpc, body, opts \\ []),
    do: status(call(rpc, "MeetingDeviceService", "UpdateMeetingDevice", body, opts))

  # Derived (post-registration) calls: handoff replays through the captured cookie client;
  # native synthesizes meet.google.com $rpc with the account Bearer.
  defp call(rpc, service, method, body, opts \\ [])

  defp call(%Rpc.Client{} = client, service, method, body, opts),
    do: Rpc.call(client, service, method, body, opts)

  defp call(%{bearer: _} = rpc, service, method, body, opts),
    do: Rpc.call_meet(method, service, body, {:bearer, rpc.bearer}, rpc_ctx(rpc), opts)

  defp rpc_ctx(rpc),
    do: %{
      token: rpc.token,
      identifier: rpc.identifier,
      compass: rpc.compass,
      debugid: rpc.debugid
    }

  defp status({:ok, 200, _body, _headers}), do: :ok
  defp status({:ok, status, _body, _headers}), do: {:error, {:status, status}}
  defp status({:error, _} = error), do: error
end
