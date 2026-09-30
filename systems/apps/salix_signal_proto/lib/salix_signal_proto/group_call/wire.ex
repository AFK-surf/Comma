defmodule SalixSignalProto.GroupCall.Wire do
  @moduledoc false
  # Protocol-buffer schemas of group calls (CRS-14 sections 4.1, 9.1, 10 and
  # 11, and the opaque call message of CRS-12 section 5.4). Field names are
  # neutral names for the CRS labels. Messages are declared proto2 so that a
  # value that Comma sets, including zero or false, is on the wire; a decoder
  # reads an absent field as nil. Enumerations are plain integers so that an
  # unknown value never fails the parse. Fields that Comma neither sends nor
  # reads (raised hands, statistics, admin actions, call-link state and
  # endorsements) are not declared: a decoder skips them.

  defmodule TokenResponse do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:token, 1, optional: true, type: :string)
  end

  defmodule MediaKey do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:ratchet_counter, 1, optional: true, type: :uint32)
    field(:secret, 2, optional: true, type: :bytes)
    field(:demux_id, 3, optional: true, type: :uint32)
  end

  defmodule Heartbeat do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:audio_muted, 1, optional: true, type: :bool)
    field(:video_muted, 2, optional: true, type: :bool)
    field(:presenting, 3, optional: true, type: :bool)
    field(:sharing_screen, 4, optional: true, type: :bool)
    field(:muted_by_demux_id, 5, optional: true, type: :uint32)
  end

  defmodule Leaving do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:demux_id, 1, optional: true, type: :uint32)
  end

  defmodule Reaction do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:value, 1, optional: true, type: :string)
  end

  defmodule RemoteMuteRequest do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:target_demux_id, 1, optional: true, type: :uint32)
  end

  defmodule DeviceToDevice do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:group_id, 1, optional: true, type: :bytes)
    field(:media_key, 2, optional: true, type: SalixSignalProto.GroupCall.Wire.MediaKey)
    field(:heartbeat, 3, optional: true, type: SalixSignalProto.GroupCall.Wire.Heartbeat)
    field(:leaving, 4, optional: true, type: SalixSignalProto.GroupCall.Wire.Leaving)
    field(:reaction, 5, optional: true, type: SalixSignalProto.GroupCall.Wire.Reaction)

    field(:remote_mute_request, 6,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.RemoteMuteRequest
    )
  end

  defmodule ReliabilityHeader do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:seqnum, 1, optional: true, type: :uint64)
    field(:ack, 2, optional: true, type: :uint64)
    field(:fragment_count, 3, optional: true, type: :uint32)
  end

  defmodule VideoRequestEntry do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:height, 2, optional: true, type: :uint32)
    field(:demux_id, 3, optional: true, type: :fixed32)
  end

  defmodule VideoRequest do
    @moduledoc false
    use Protobuf, syntax: :proto2

    field(:requests, 1,
      repeated: true,
      type: SalixSignalProto.GroupCall.Wire.VideoRequestEntry
    )

    field(:max_kbps, 3, optional: true, type: :uint32)
    field(:active_speaker_height, 4, optional: true, type: :uint32)
  end

  defmodule Empty do
    @moduledoc false
    use Protobuf, syntax: :proto2
  end

  defmodule DeviceToSfu do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:video_request, 1, optional: true, type: SalixSignalProto.GroupCall.Wire.VideoRequest)
    field(:leave, 2, optional: true, type: SalixSignalProto.GroupCall.Wire.Empty)

    field(:reliability, 8,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.ReliabilityHeader
    )

    field(:fragment, 9, optional: true, type: :bytes)
  end

  defmodule PeekDevice do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:demux_id, 1, optional: true, type: :fixed32)
    field(:opaque_user_id, 2, optional: true, type: :string)
    field(:requires_svc, 3, optional: true, type: :bool)
  end

  defmodule PeekInfo do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:era_id, 1, optional: true, type: :string)
    field(:max_devices, 2, optional: true, type: :uint32)
    field(:creator, 3, optional: true, type: :string)
    field(:devices, 4, repeated: true, type: SalixSignalProto.GroupCall.Wire.PeekDevice)
    field(:pending_devices, 5, repeated: true, type: SalixSignalProto.GroupCall.Wire.PeekDevice)
  end

  defmodule SfuVideoRequest do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:height, 1, optional: true, type: :uint32)
  end

  defmodule Speaker do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:demux_id, 2, optional: true, type: :fixed32)
  end

  defmodule DeviceJoinedOrLeft do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:peek_info, 1, optional: true, type: SalixSignalProto.GroupCall.Wire.PeekInfo)
  end

  defmodule CurrentDevices do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:demux_ids_with_video, 1, repeated: true, type: :uint32)
    field(:all_demux_ids, 2, repeated: true, type: :fixed32)
    field(:allocated_heights, 3, repeated: true, type: :uint32)
  end

  defmodule SfuToDevice do
    @moduledoc false
    use Protobuf, syntax: :proto2

    field(:video_request, 2,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.SfuVideoRequest
    )

    field(:speaker, 4, optional: true, type: SalixSignalProto.GroupCall.Wire.Speaker)

    field(:device_joined_or_left, 6,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.DeviceJoinedOrLeft
    )

    field(:current_devices, 7,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.CurrentDevices
    )

    field(:removed, 9, optional: true, type: SalixSignalProto.GroupCall.Wire.Empty)

    field(:reliability, 11,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.ReliabilityHeader
    )

    field(:fragment, 12, optional: true, type: :bytes)
  end

  defmodule RingIntention do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:group_id, 1, optional: true, type: :bytes)
    field(:type, 2, optional: true, type: :int32)
    field(:ring_id, 3, optional: true, type: :sfixed64)
  end

  defmodule RingResponse do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:group_id, 1, optional: true, type: :bytes)
    field(:type, 2, optional: true, type: :int32)
    field(:ring_id, 3, optional: true, type: :sfixed64)
  end

  defmodule OpaqueCallMessage do
    @moduledoc false
    use Protobuf, syntax: :proto2

    field(:device_message, 1,
      optional: true,
      type: SalixSignalProto.GroupCall.Wire.DeviceToDevice
    )

    field(:ring_intention, 2, optional: true, type: SalixSignalProto.GroupCall.Wire.RingIntention)
    field(:ring_response, 3, optional: true, type: SalixSignalProto.GroupCall.Wire.RingResponse)
  end
end
