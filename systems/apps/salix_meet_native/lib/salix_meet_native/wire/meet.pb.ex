defmodule SalixMeetNative.Wire.MeetingIdentifierKind do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.MeetingIdentifierKind",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MEETING_IDENTIFIER_KIND_UNSPECIFIED, 0
  field :MEETING_IDENTIFIER_KIND_SPACE_SHORT_ID, 3
end

defmodule SalixMeetNative.Wire.DeviceJoinState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.DeviceJoinState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :DEVICE_JOIN_STATE_UNSPECIFIED, 0
  field :DEVICE_JOIN_STATE_JOINED, 1
  field :DEVICE_JOIN_STATE_HIDDEN, 2
  field :DEVICE_JOIN_STATE_KNOCKING, 3
  field :DEVICE_JOIN_STATE_DENIED, 4
  field :DEVICE_JOIN_STATE_LOBBY, 5
  field :DEVICE_JOIN_STATE_LEFT, 6
  field :DEVICE_JOIN_STATE_EJECTED, 7
  field :DEVICE_JOIN_STATE_ERROR, 8
  field :DEVICE_JOIN_STATE_MISSING_PREREQUISITES, 9
  field :DEVICE_JOIN_STATE_RINGING, 10
  field :DEVICE_JOIN_STATE_DENIED_FULL, 11
  field :DEVICE_JOIN_STATE_WAITING, 13
  field :DEVICE_JOIN_STATE_MISSING_CSE_KEY, 14
  field :DEVICE_JOIN_STATE_MISSING_THIRD_PARTY_AUTHENTICATION, 15
end

defmodule SalixMeetNative.Wire.ParticipationMode do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.ParticipationMode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :PARTICIPATION_MODE_UNSPECIFIED, 0
  field :PARTICIPATION_MODE_DEFAULT, 1
  field :PARTICIPATION_MODE_COMPANION, 2
end

defmodule SalixMeetNative.Wire.MediaCaptureType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.MediaCaptureType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MEDIA_CAPTURE_TYPE_UNSPECIFIED, 0
  field :MEDIA_CAPTURE_TYPE_CAMERA_MIC, 1
  field :MEDIA_CAPTURE_TYPE_SCREENCAST_PRESENT, 2
  field :MEDIA_CAPTURE_TYPE_HDMI_PRESENT, 3
  field :MEDIA_CAPTURE_TYPE_WHITEBOARD_PRESENT, 4
  field :MEDIA_CAPTURE_TYPE_CAMERA_PRESENT, 5
  field :MEDIA_CAPTURE_TYPE_UNRECOGNIZED, 6
end

defmodule SalixMeetNative.Wire.MediaType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.MediaType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MEDIA_TYPE_UNSPECIFIED, 0
  field :MEDIA_TYPE_AUDIO, 1
  field :MEDIA_TYPE_VIDEO, 2
end

defmodule SalixMeetNative.Wire.IceTransportType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.IceTransportType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ICE_TRANSPORT_TYPE_UNSPECIFIED, 0
  field :ICE_TRANSPORT_TYPE_UDP, 1
  field :ICE_TRANSPORT_TYPE_UDP_ALTERNATE, 2
  field :ICE_TRANSPORT_TYPE_TCP, 3
end

defmodule SalixMeetNative.Wire.ChatDeliveryScope do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.ChatDeliveryScope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :CHAT_DELIVERY_SCOPE_UNSPECIFIED, 0
  field :CHAT_DELIVERY_SCOPE_MEETING, 1
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeatType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeatType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :MEDIA_SESSION_HEARTBEAT_TYPE_UNSPECIFIED, 0
  field :MEDIA_SESSION_HEARTBEAT_TYPE_ACK, 1
  field :MEDIA_SESSION_HEARTBEAT_TYPE_KEEPALIVE, 2
  field :MEDIA_SESSION_HEARTBEAT_TYPE_CLIENT_KEEPALIVE, 4
end

defmodule SalixMeetNative.Wire.ResolveMeetingSpaceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ResolveMeetingSpaceRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :meeting_code, 1, type: :string, json_name: "meetingCode"
  field :guest_mode, 6, type: :uint64, json_name: "guestMode"
end

defmodule SalixMeetNative.Wire.ResolveMeetingSpaceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ResolveMeetingSpaceResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
end

defmodule SalixMeetNative.Wire.GetMeetingSpaceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.GetMeetingSpaceRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
end

defmodule SalixMeetNative.Wire.GetMeetingSpaceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.GetMeetingSpaceResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
  field :meeting_code, 2, type: :string, json_name: "meetingCode"
end

defmodule SalixMeetNative.Wire.MeetingIdentifier do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingIdentifier",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :identifier_kind, 1,
    type: SalixMeetNative.Wire.MeetingIdentifierKind,
    json_name: "identifierKind",
    enum: true

  field :space_id, 2, type: :string, json_name: "spaceId"
end

defmodule SalixMeetNative.Wire.CreateMeetingDeviceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateMeetingDeviceRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
  field :device, 2, type: SalixMeetNative.Wire.MeetingDevice
end

defmodule SalixMeetNative.Wire.CreateMeetingDeviceResponse do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateMeetingDeviceResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :device, 1, type: SalixMeetNative.Wire.MeetingDevice
end

defmodule SalixMeetNative.Wire.BulkUpdateMeetingDevicesRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.BulkUpdateMeetingDevicesRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
  field :device_name, 2, type: :string, json_name: "deviceName"
  field :patch, 3, type: SalixMeetNative.Wire.MeetingDevice
  field :update_mask, 4, type: SalixMeetNative.Wire.FieldMask, json_name: "updateMask"
end

defmodule SalixMeetNative.Wire.UpdateMeetingDeviceRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.UpdateMeetingDeviceRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :device, 1, type: SalixMeetNative.Wire.MeetingDevice
  field :update_mask, 2, type: SalixMeetNative.Wire.FieldMask, json_name: "updateMask"
end

defmodule SalixMeetNative.Wire.CreateHandRaiseRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateHandRaiseRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
  field :request, 2, type: SalixMeetNative.Wire.Empty
end

defmodule SalixMeetNative.Wire.CreateHandRaiseResponse do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateHandRaiseResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hand_raise, 1, type: :string, json_name: "handRaise"
end

defmodule SalixMeetNative.Wire.DeleteHandRaiseRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DeleteHandRaiseRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hand_raise, 1, type: :string, json_name: "handRaise"
end

defmodule SalixMeetNative.Wire.FieldMask do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.FieldMask",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :paths, 1, repeated: true, type: :string
end

defmodule SalixMeetNative.Wire.Empty do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.Empty",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule SalixMeetNative.Wire.MeetingDevice do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingDevice",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :display_name, 2, type: :string, json_name: "displayName"
  field :avatar_url, 3, type: :string, json_name: "avatarUrl"

  field :join_state, 4,
    type: SalixMeetNative.Wire.DeviceJoinState,
    json_name: "joinState",
    enum: true

  field :joined_flag, 5, type: :uint64, json_name: "joinedFlag"
  field :guest, 8, type: :uint64
  field :client_type, 11, type: :uint64, json_name: "clientType"
  field :anonymous, 15, type: :uint64

  field :device_capability_versions, 18,
    repeated: true,
    type: :uint64,
    json_name: "deviceCapabilityVersions"

  field :pstn, 20, type: SalixMeetNative.Wire.PSTNInfo
  field :cloud_session_id, 22, type: :string, json_name: "cloudSessionId"

  field :participation_mode, 25,
    type: SalixMeetNative.Wire.ParticipationMode,
    json_name: "participationMode",
    enum: true

  field :first_name, 29, type: :string, json_name: "firstName"

  field :media_capture_type, 38,
    type: SalixMeetNative.Wire.MediaCaptureType,
    json_name: "mediaCaptureType",
    enum: true

  field :advertised_capability_ids, 39,
    repeated: true,
    type: :uint64,
    json_name: "advertisedCapabilityIds"

  field :ack_requirements, 41,
    repeated: true,
    type: SalixMeetNative.Wire.AckRequirement,
    json_name: "ackRequirements"

  field :pronouns, 44, repeated: true, type: :string
  field :meeting_role, 46, type: :uint64, json_name: "meetingRole"
end

defmodule SalixMeetNative.Wire.AckRequirement do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.AckRequirement",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :operation, 1, type: :uint64
  field :state, 2, type: :uint64
end

defmodule SalixMeetNative.Wire.PSTNInfo do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.PSTNInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :phone, 1, type: :string
  field :pin, 5, type: :string
end

defmodule SalixMeetNative.Wire.SyncMeetingSpaceCollectionsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.SyncMeetingSpaceCollectionsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string

  field :meeting_space_cursor, 2,
    type: SalixMeetNative.Wire.CollectionCursor,
    json_name: "meetingSpaceCursor"

  field :devices_cursor, 3,
    type: SalixMeetNative.Wire.CollectionCursor,
    json_name: "devicesCursor"
end

defmodule SalixMeetNative.Wire.CollectionCursor do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CollectionCursor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :version, 1, type: :uint64
end

defmodule SalixMeetNative.Wire.SyncMeetingSpaceCollectionsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.SyncMeetingSpaceCollectionsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :meeting_space, 1, type: SalixMeetNative.Wire.SyncCollection, json_name: "meetingSpace"
  field :devices, 2, type: SalixMeetNative.Wire.SyncCollection
end

defmodule SalixMeetNative.Wire.SyncCollection do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.SyncCollection",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :synced, 1, type: SalixMeetNative.Wire.SyncCollectionState
  field :changed, 2, type: SalixMeetNative.Wire.SyncCollectionState
end

defmodule SalixMeetNative.Wire.SyncCollectionState do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.SyncCollectionState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :cursor, 1, type: SalixMeetNative.Wire.CollectionCursor
  field :resource_messages, 2, repeated: true, type: :bytes, json_name: "resourceMessages"
end

defmodule SalixMeetNative.Wire.MeetingSpaceResource do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingSpaceResource",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :space, 1, type: :string
  field :code, 2, type: :string
  field :url, 3, type: :string
  field :details, 6, type: SalixMeetNative.Wire.MeetingSpaceDetails
end

defmodule SalixMeetNative.Wire.MeetingSpaceDetails do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingSpaceDetails",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :host, 16, type: SalixMeetNative.Wire.HostInfo
end

defmodule SalixMeetNative.Wire.HostInfo do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.HostInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :display_name, 1, type: :string, json_name: "displayName"
end

defmodule SalixMeetNative.Wire.CollectionsFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CollectionsFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.CollectionsEnvelope
end

defmodule SalixMeetNative.Wire.CollectionsEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CollectionsEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :container, 2, type: SalixMeetNative.Wire.CollectionsContainer
end

defmodule SalixMeetNative.Wire.CollectionsContainer do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CollectionsContainer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :media_streams, 3, type: SalixMeetNative.Wire.CollectionBlock, json_name: "mediaStreams"
  field :interactions, 13, type: SalixMeetNative.Wire.InteractionCollections
end

defmodule SalixMeetNative.Wire.CollectionBlock do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CollectionBlock",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :cursor, 1, type: SalixMeetNative.Wire.CollectionCursor

  field :added_resource_messages, 2,
    repeated: true,
    type: :bytes,
    json_name: "addedResourceMessages"

  field :removed_resource_names, 3,
    repeated: true,
    type: :string,
    json_name: "removedResourceNames"
end

defmodule SalixMeetNative.Wire.InteractionCollections do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.InteractionCollections",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :roster, 1, type: SalixMeetNative.Wire.CollectionBlock
  field :chat, 4, type: SalixMeetNative.Wire.CollectionBlock
  field :hand_raises, 12, type: SalixMeetNative.Wire.CollectionBlock, json_name: "handRaises"
  field :counters, 17, type: SalixMeetNative.Wire.CollectionBlock
end

defmodule SalixMeetNative.Wire.MediaStreamResource do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaStreamResource",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :media_type, 2, type: SalixMeetNative.Wire.MediaType, json_name: "mediaType", enum: true
  field :stream_id, 4, type: :string, json_name: "streamId"
  field :device, 6, type: :string
  field :fid_group, 8, type: SalixMeetNative.Wire.SsrcGroup, json_name: "fidGroup"
  field :stream_state, 9, type: SalixMeetNative.Wire.MediaStreamState, json_name: "streamState"
  field :toggle, 10, type: SalixMeetNative.Wire.StreamToggle
  field :video_stream_marker, 11, type: :uint64, json_name: "videoStreamMarker"
  field :stream_flags, 14, type: :uint64, json_name: "streamFlags"
end

defmodule SalixMeetNative.Wire.SsrcGroup do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.SsrcGroup",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ssrc, 1, repeated: true, type: :uint64, packed: false, deprecated: false
  field :semantics, 2, repeated: true, type: SalixMeetNative.Wire.SsrcSemantics
end

defmodule SalixMeetNative.Wire.SsrcSemantics do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.SsrcSemantics",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :ssrc, 2, repeated: true, type: :uint64, packed: false, deprecated: false
end

defmodule SalixMeetNative.Wire.MediaStreamState do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaStreamState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :audio_stream_marker, 2, type: :uint64, json_name: "audioStreamMarker"
  field :dimensions, 8, type: SalixMeetNative.Wire.VideoDimensions
end

defmodule SalixMeetNative.Wire.VideoDimensions do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.VideoDimensions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :width, 1, type: :uint64
  field :height, 2, type: :uint64
  field :aspect_ratio, 3, type: SalixMeetNative.Wire.AspectRatio, json_name: "aspectRatio"
end

defmodule SalixMeetNative.Wire.AspectRatio do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.AspectRatio",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :min, 1, type: :float
  field :max, 2, type: :float
end

defmodule SalixMeetNative.Wire.StreamToggle do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.StreamToggle",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :state, 1, type: :uint64
end

defmodule SalixMeetNative.Wire.ChatMessage do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :string
  field :sender_device, 2, type: :string, json_name: "senderDevice"
  field :message_type, 3, type: :uint64, json_name: "messageType"
  field :created_at, 4, type: SalixMeetNative.Wire.Timestamp, json_name: "createdAt"
  field :text, 5, type: SalixMeetNative.Wire.ChatText
  field :actor, 8, type: SalixMeetNative.Wire.ChatActor
  field :reactions, 13, repeated: true, type: SalixMeetNative.Wire.ChatReaction
  field :attachments, 16, repeated: true, type: SalixMeetNative.Wire.ChatAttachment
end

defmodule SalixMeetNative.Wire.ChatReaction do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatReaction",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :emoji, 1, type: :string
  field :count, 2, type: :uint64
end

defmodule SalixMeetNative.Wire.ChatAttachment do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatAttachment",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :url, 1, type: :string
  field :mime, 2, type: :string
  field :thumbnail_url, 3, type: :string, json_name: "thumbnailUrl"
end

defmodule SalixMeetNative.Wire.ChatText do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatText",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :text, 1, type: :string
end

defmodule SalixMeetNative.Wire.ChatActor do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatActor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :name, 1, type: :string
  field :avatar_url, 2, type: :string, json_name: "avatarUrl"
end

defmodule SalixMeetNative.Wire.HandRaiseResource do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.HandRaiseResource",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :resource, 1, type: :string
  field :created_at, 2, type: SalixMeetNative.Wire.Timestamp, json_name: "createdAt"
  field :state, 3, type: :uint64
  field :device, 4, type: :string
end

defmodule SalixMeetNative.Wire.Timestamp do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.Timestamp",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :seconds, 1, type: :int64
  field :nanos, 2, type: :int32
end

defmodule SalixMeetNative.Wire.CaptionFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CaptionFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :segments, 1, repeated: true, type: SalixMeetNative.Wire.CaptionSegment
end

defmodule SalixMeetNative.Wire.CaptionSegment do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CaptionSegment",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :speaker, 1, type: :string
  field :segment, 2, type: :uint64
  field :revision, 3, type: :uint64
  field :final, 4, type: :bool
  field :text, 6, type: :string
  field :spoken_language, 8, type: :uint64, json_name: "spokenLanguage"
  field :display_language, 10, type: :uint64, json_name: "displayLanguage"
  field :start, 12, type: SalixMeetNative.Wire.Timestamp
  field :end, 13, type: SalixMeetNative.Wire.Timestamp
  field :caption_kind, 15, type: :uint64, json_name: "captionKind"
  field :dedup_state, 16, type: :uint64, json_name: "dedupState"
end

defmodule SalixMeetNative.Wire.ReactionFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 2, type: :bytes
end

defmodule SalixMeetNative.Wire.ReactionEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.ReactionEnvelope2
end

defmodule SalixMeetNative.Wire.ReactionEnvelope2 do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionEnvelope2",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :reaction, 1, type: SalixMeetNative.Wire.ReactionEvent
end

defmodule SalixMeetNative.Wire.ReactionEvent do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionEvent",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :emoji, 1, type: SalixMeetNative.Wire.ReactionEmoji
  field :target, 4, type: SalixMeetNative.Wire.ReactionTarget
  field :actor, 6, type: SalixMeetNative.Wire.ReactionActor
end

defmodule SalixMeetNative.Wire.ReactionEmoji do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionEmoji",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :emoji, 1, type: :string
end

defmodule SalixMeetNative.Wire.ReactionTarget do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionTarget",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :device, 1, type: :string
end

defmodule SalixMeetNative.Wire.ReactionActor do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionActor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :device, 1, type: :string
  field :name, 2, type: :string
end

defmodule SalixMeetNative.Wire.CreateMediaSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateMediaSessionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :wrapper, 1, type: SalixMeetNative.Wire.CreateMediaSessionWrapper
end

defmodule SalixMeetNative.Wire.CreateMediaSessionWrapper do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateMediaSessionWrapper",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :media_session, 1, type: :string, json_name: "mediaSession"
  field :offer, 3, type: SalixMeetNative.Wire.MediaSessionOffer
end

defmodule SalixMeetNative.Wire.MediaSessionOffer do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionOffer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :dtls, 1, type: SalixMeetNative.Wire.DTLSTransport
  field :ice, 2, type: SalixMeetNative.Wire.ICETransport
  field :codecs, 3, repeated: true, type: SalixMeetNative.Wire.MediaCodec

  field :header_extensions, 4,
    repeated: true,
    type: SalixMeetNative.Wire.RTPHeaderExtension,
    json_name: "headerExtensions"

  field :bandwidth, 5, type: SalixMeetNative.Wire.BandwidthSettings
  field :mode, 7, type: SalixMeetNative.Wire.MediaSessionMode
  field :capabilities, 8, type: SalixMeetNative.Wire.MediaSessionCapabilitySet

  field :data_channels, 17,
    repeated: true,
    type: SalixMeetNative.Wire.DataChannelOffer,
    json_name: "dataChannels"

  field :transport_mode, 19,
    type: SalixMeetNative.Wire.MediaSessionMode,
    json_name: "transportMode"

  field :browser_profile, 36, proto3_optional: true, type: :uint64, json_name: "browserProfile"
  field :receiver_support, 42, proto3_optional: true, type: :uint64, json_name: "receiverSupport"
  field :streams_muted, 44, proto3_optional: true, type: :bool, json_name: "streamsMuted"
  field :gpu, 45, type: SalixMeetNative.Wire.GPUInfo

  field :video_processing, 46,
    type: SalixMeetNative.Wire.VideoProcessingConfig,
    json_name: "videoProcessing"

  field :media_receive_enabled, 50,
    proto3_optional: true,
    type: :uint64,
    json_name: "mediaReceiveEnabled"

  field :outbound_streams, 52,
    repeated: true,
    type: SalixMeetNative.Wire.OutboundStreamDescriptor,
    json_name: "outboundStreams"
end

defmodule SalixMeetNative.Wire.DTLSTransport do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DTLSTransport",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :fingerprint, 1, type: SalixMeetNative.Wire.Fingerprint
  field :setup_role, 2, type: :uint64, json_name: "setupRole"
  field :enabled, 3, proto3_optional: true, type: :uint64
end

defmodule SalixMeetNative.Wire.Fingerprint do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.Fingerprint",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :algorithm, 1, type: :string
  field :digest, 2, type: :string
end

defmodule SalixMeetNative.Wire.ICETransport do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ICETransport",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :username_fragment, 3, type: :string, json_name: "usernameFragment"
  field :password, 4, type: :string
end

defmodule SalixMeetNative.Wire.MediaCodec do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaCodec",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :payload_type, 1, proto3_optional: true, type: :uint64, json_name: "payloadType"
  field :name, 2, type: :string
  field :media_type, 3, type: SalixMeetNative.Wire.MediaType, json_name: "mediaType", enum: true
  field :clock_rate, 4, type: :uint64, json_name: "clockRate"
  field :channels, 5, type: :uint64
  field :parameters, 6, repeated: true, type: SalixMeetNative.Wire.CodecParameter

  field :rtcp_feedback, 8,
    repeated: true,
    type: SalixMeetNative.Wire.RtcpFeedback,
    json_name: "rtcpFeedback"

  field :goog_feedback, 9,
    repeated: true,
    type: SalixMeetNative.Wire.RtcpFeedback,
    json_name: "googFeedback"
end

defmodule SalixMeetNative.Wire.CodecParameter do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CodecParameter",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, proto3_optional: true, type: :string
  field :parameter_value, 2, proto3_optional: true, type: :string, json_name: "parameterValue"
end

defmodule SalixMeetNative.Wire.RtcpFeedback do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.RtcpFeedback",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :feedback_type, 1, proto3_optional: true, type: :uint64, json_name: "feedbackType"
end

defmodule SalixMeetNative.Wire.RTPHeaderExtension do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.RTPHeaderExtension",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :id, 1, type: :uint64
  field :uri, 2, type: :string
  field :media_type, 3, type: SalixMeetNative.Wire.MediaType, json_name: "mediaType", enum: true
  field :enabled, 4, proto3_optional: true, type: :uint64
end

defmodule SalixMeetNative.Wire.BandwidthSettings do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.BandwidthSettings",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :max_bitrate_kbps, 2, type: :uint64, json_name: "maxBitrateKbps"
  field :start_bitrate_kbps, 3, type: :uint64, json_name: "startBitrateKbps"
end

defmodule SalixMeetNative.Wire.MediaSessionMode do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionMode",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :mode, 1, type: :uint64
end

defmodule SalixMeetNative.Wire.MediaSessionCapabilitySet do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionCapabilitySet",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :audio, 1, type: :uint64
  field :video, 2, type: :uint64
end

defmodule SalixMeetNative.Wire.DataChannelOffer do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DataChannelOffer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :ordered, 2, proto3_optional: true, type: :uint64
  field :negotiated, 4, proto3_optional: true, type: :uint64
  field :protocol, 7, type: :bytes
end

defmodule SalixMeetNative.Wire.GPUInfo do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.GPUInfo",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :vendor_id, 1, type: :uint64, json_name: "vendorId"
  field :device_id, 2, type: :uint64, json_name: "deviceId"
  field :feature_level, 4, type: :uint64, json_name: "featureLevel"
  field :description, 6, type: :string
end

defmodule SalixMeetNative.Wire.VideoProcessingConfig do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.VideoProcessingConfig",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :option, 1, type: SalixMeetNative.Wire.VideoProcessingOption
end

defmodule SalixMeetNative.Wire.VideoProcessingOption do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.VideoProcessingOption",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :enabled, 5, proto3_optional: true, type: :uint64
  field :mode, 6, proto3_optional: true, type: :uint64
end

defmodule SalixMeetNative.Wire.OutboundStreamDescriptor do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundStreamDescriptor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :source, 1, type: SalixMeetNative.Wire.OutboundStreamSource
  field :direction, 2, type: :uint64
end

defmodule SalixMeetNative.Wire.OutboundStreamSource do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundStreamSource",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :resolution, 3, type: SalixMeetNative.Wire.OutboundVideoResolution
  field :layer_hints, 8, type: SalixMeetNative.Wire.OutboundLayerHints, json_name: "layerHints"
  field :rid, 9, type: SalixMeetNative.Wire.OutboundRid
end

defmodule SalixMeetNative.Wire.OutboundVideoResolution do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundVideoResolution",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :height, 1, type: :uint64
  field :width, 2, type: :uint64
  field :frame_rate, 3, type: :uint64, json_name: "frameRate"
end

defmodule SalixMeetNative.Wire.OutboundLayerHints do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundLayerHints",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :target_bitrate, 1, type: :uint64, json_name: "targetBitrate"
  field :min_bitrate, 2, type: :uint64, json_name: "minBitrate"
  field :range, 3, type: SalixMeetNative.Wire.OutboundLayerRange
end

defmodule SalixMeetNative.Wire.OutboundLayerRange do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundLayerRange",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :min, 1, type: :uint64
  field :max, 2, type: :uint64
end

defmodule SalixMeetNative.Wire.OutboundRid do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundRid",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :rid_value, 1, type: SalixMeetNative.Wire.OutboundRidValue, json_name: "ridValue"
end

defmodule SalixMeetNative.Wire.OutboundRidValue do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.OutboundRidValue",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :rid, 1, type: :string
end

defmodule SalixMeetNative.Wire.CreateMediaSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CreateMediaSessionResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :transport, 2, type: SalixMeetNative.Wire.MediaSessionTransport
end

defmodule SalixMeetNative.Wire.MediaSessionTransport do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionTransport",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :dtls, 1, type: SalixMeetNative.Wire.DTLSTransport
  field :ice, 2, type: SalixMeetNative.Wire.ICETransport
  field :candidates, 3, repeated: true, type: SalixMeetNative.Wire.ICECandidate

  field :accepted_codecs, 4,
    repeated: true,
    type: SalixMeetNative.Wire.MediaCodec,
    json_name: "acceptedCodecs"

  field :accepted_header_extensions, 5,
    repeated: true,
    type: SalixMeetNative.Wire.RTPHeaderExtension,
    json_name: "acceptedHeaderExtensions"

  field :ssrc_pool, 6, repeated: true, type: :uint64, json_name: "ssrcPool"
  field :selected_bundle, 7, proto3_optional: true, type: :uint64, json_name: "selectedBundle"

  field :transport_tag, 9,
    type: SalixMeetNative.Wire.MediaSessionTransportTag,
    json_name: "transportTag"

  field :downlink_pool_size, 11,
    proto3_optional: true,
    type: :uint64,
    json_name: "downlinkPoolSize"

  field :data_channels, 12,
    repeated: true,
    type: SalixMeetNative.Wire.DataChannelSpec,
    json_name: "dataChannels"

  field :transport_mode, 13,
    type: SalixMeetNative.Wire.MediaSessionMode,
    json_name: "transportMode"
end

defmodule SalixMeetNative.Wire.ICECandidate do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ICECandidate",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :transport_type, 1,
    type: SalixMeetNative.Wire.IceTransportType,
    json_name: "transportType",
    enum: true

  field :ip, 2, type: :string
  field :port, 3, type: :uint64
  field :priority, 4, type: :uint64
  field :component, 5, type: :uint64
end

defmodule SalixMeetNative.Wire.DataChannelSpec do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DataChannelSpec",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :label, 1, type: :string
  field :ordered, 2, proto3_optional: true, type: :bool
  field :id, 3, type: :uint64
  field :negotiated, 4, proto3_optional: true, type: :uint64

  field :max_packet_life_time, 5,
    proto3_optional: true,
    type: :uint64,
    json_name: "maxPacketLifeTime"

  field :priority, 6, proto3_optional: true, type: :uint64
  field :protocol, 7, type: :bytes
end

defmodule SalixMeetNative.Wire.MediaSessionTransportTag do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionTransportTag",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :tag, 1, type: :bytes
end

defmodule SalixMeetNative.Wire.MediaSessionDCFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionDCFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.MediaSessionDCEnvelope
end

defmodule SalixMeetNative.Wire.MediaSessionDCEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionDCEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :request, 2, type: SalixMeetNative.Wire.MediaSessionUpdate
end

defmodule SalixMeetNative.Wire.MediaSessionUpdate do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionUpdate",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :request_id, 1, type: :uint64, json_name: "requestId"
  field :update, 3, type: SalixMeetNative.Wire.UpdateMediaSessionRequest
end

defmodule SalixMeetNative.Wire.UpdateMediaSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.UpdateMediaSessionRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :client_config, 1,
    type: SalixMeetNative.Wire.MediaSessionClientConfig,
    json_name: "clientConfig"

  field :update_mask, 2, type: SalixMeetNative.Wire.FieldMask, json_name: "updateMask"
end

defmodule SalixMeetNative.Wire.MediaSessionClientConfig do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionClientConfig",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :caption_config, 9, type: SalixMeetNative.Wire.CaptionConfig, json_name: "captionConfig"
end

defmodule SalixMeetNative.Wire.CaptionConfig do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.CaptionConfig",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :display_language, 1, type: :string, json_name: "displayLanguage"
  field :spoken_language, 2, type: :string, json_name: "spokenLanguage"
end

defmodule SalixMeetNative.Wire.DCRPCFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DCRPCFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :request_id, 1, type: :uint64, json_name: "requestId"

  field :subscribe_video_streams, 2,
    type: SalixMeetNative.Wire.DCRPCSubscribeVideoStreamsOp,
    json_name: "subscribeVideoStreams"

  field :refresh, 3, type: SalixMeetNative.Wire.DCRPCRefreshOp
end

defmodule SalixMeetNative.Wire.DCRPCEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DCRPCEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :frame, 1, type: SalixMeetNative.Wire.DCRPCFrame
end

defmodule SalixMeetNative.Wire.DCRPCSubscribeVideoStreamsOp do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DCRPCSubscribeVideoStreamsOp",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hotlane_client_context, 1, type: :bytes, json_name: "hotlaneClientContext"
  field :streams, 4, repeated: true, type: SalixMeetNative.Wire.VideoStreamSubscription
end

defmodule SalixMeetNative.Wire.DCRPCRefreshOp do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DCRPCRefreshOp",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :hotlane_client_context, 1, type: :bytes, json_name: "hotlaneClientContext"
  field :kind, 2, type: :uint64
  field :media_session_id, 3, type: :string, json_name: "mediaSessionId"
  field :counter, 5, type: SalixMeetNative.Wire.DCRPCRefreshCounter
end

defmodule SalixMeetNative.Wire.DCRPCRefreshCounter do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.DCRPCRefreshCounter",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :value, 1, type: :uint64
end

defmodule SalixMeetNative.Wire.VideoStreamSubscription do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.VideoStreamSubscription",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :subscribe, 1, type: :bool
  field :media_type, 2, type: SalixMeetNative.Wire.MediaType, json_name: "mediaType", enum: true
  field :media_session_id, 3, type: :string, json_name: "mediaSessionId"
  field :ssrc, 4, type: :string
  field :request_id, 5, type: :string, json_name: "requestId"
  field :device, 6, type: :string
  field :fid_group, 8, type: SalixMeetNative.Wire.SsrcGroup, json_name: "fidGroup"

  field :receive_options, 9,
    type: SalixMeetNative.Wire.VideoReceiveOptions,
    json_name: "receiveOptions"
end

defmodule SalixMeetNative.Wire.VideoReceiveOptions do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.VideoReceiveOptions",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :enabled, 2, type: :bool
  field :dimensions, 8, type: SalixMeetNative.Wire.VideoDimensions
end

defmodule SalixMeetNative.Wire.MeetMessagesFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetMessagesFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.MeetMessagesEnvelope
  field :received, 2, type: :bytes
end

defmodule SalixMeetNative.Wire.MeetMessagesEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetMessagesEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequenced, 1, type: SalixMeetNative.Wire.MeetMessagesSequenced
end

defmodule SalixMeetNative.Wire.MeetMessagesSequenced do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetMessagesSequenced",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequence, 1, type: :uint64
  field :chat, 3, type: SalixMeetNative.Wire.ChatSendBranch
  field :received, 4, type: SalixMeetNative.Wire.MeetMessagesReceivedBranch
end

defmodule SalixMeetNative.Wire.MeetMessagesReceivedBranch do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetMessagesReceivedBranch",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :message, 1, type: SalixMeetNative.Wire.ChatMessage
end

defmodule SalixMeetNative.Wire.ChatSendBranch do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatSendBranch",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :outer, 1, type: SalixMeetNative.Wire.ChatSendOuter
end

defmodule SalixMeetNative.Wire.ChatSendOuter do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatSendOuter",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :message, 2, type: SalixMeetNative.Wire.ChatSendMessage
end

defmodule SalixMeetNative.Wire.ChatSendMessage do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ChatSendMessage",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :send_time_millis, 3, type: :uint64, json_name: "sendTimeMillis"
  field :text, 5, type: SalixMeetNative.Wire.ChatText

  field :delivery_scope, 6,
    type: SalixMeetNative.Wire.ChatDeliveryScope,
    json_name: "deliveryScope",
    enum: true
end

defmodule SalixMeetNative.Wire.ReactionSendFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionSendFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.ReactionSendEnvelope
end

defmodule SalixMeetNative.Wire.ReactionSendEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionSendEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequenced, 1, type: SalixMeetNative.Wire.ReactionSendSequenced
end

defmodule SalixMeetNative.Wire.ReactionSendSequenced do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionSendSequenced",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequence, 1, type: :uint64
  field :reaction, 2, type: SalixMeetNative.Wire.ReactionSendBranch
end

defmodule SalixMeetNative.Wire.ReactionSendBranch do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.ReactionSendBranch",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :emoji, 1, type: SalixMeetNative.Wire.ReactionEmoji
end

defmodule SalixMeetNative.Wire.MeetingAgentHeartbeatFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingAgentHeartbeatFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.MeetingAgentHeartbeatEnvelope
end

defmodule SalixMeetNative.Wire.MeetingAgentHeartbeatEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingAgentHeartbeatEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :client_state, 1,
    type: SalixMeetNative.Wire.MeetingAgentClientState,
    json_name: "clientState"

  field :clock, 6, type: SalixMeetNative.Wire.MeetingAgentClock
end

defmodule SalixMeetNative.Wire.MeetingAgentClientState do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingAgentClientState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :connected, 2, type: :uint64
  field :nested, 3, type: SalixMeetNative.Wire.MeetingAgentNestedClientState
end

defmodule SalixMeetNative.Wire.MeetingAgentNestedClientState do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingAgentNestedClientState",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :connected, 2, type: :uint64
end

defmodule SalixMeetNative.Wire.MeetingAgentClock do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MeetingAgentClock",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :seconds, 1, type: :int64
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeatFrame do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeatFrame",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :envelope, 1, type: SalixMeetNative.Wire.MediaSessionHeartbeatEnvelope
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeatEnvelope do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeatEnvelope",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequenced, 1, type: SalixMeetNative.Wire.MediaSessionHeartbeat
  field :outbound, 2, type: SalixMeetNative.Wire.MediaSessionHeartbeatOutbound
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeat",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequence, 1, type: :uint64
  field :body, 3, type: SalixMeetNative.Wire.MediaSessionHeartbeatBody
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeatBody do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeatBody",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :heartbeat_type, 1,
    type: SalixMeetNative.Wire.MediaSessionHeartbeatType,
    json_name: "heartbeatType",
    enum: true
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeatOutbound do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeatOutbound",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sequence, 1, type: :uint64
  field :body, 2, type: SalixMeetNative.Wire.MediaSessionHeartbeatOutboundBody
end

defmodule SalixMeetNative.Wire.MediaSessionHeartbeatOutboundBody do
  @moduledoc false

  use Protobuf,
    full_name: "salix_meet_native.wire.MediaSessionHeartbeatOutboundBody",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :heartbeat_type, 1,
    type: SalixMeetNative.Wire.MediaSessionHeartbeatType,
    json_name: "heartbeatType",
    enum: true
end
