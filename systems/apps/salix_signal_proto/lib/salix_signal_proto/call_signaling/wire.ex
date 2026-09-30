defmodule SalixSignalProto.CallSignaling.Wire do
  @moduledoc false
  # Protocol-buffer schemas of 1:1 call signaling (CRS-12 sections 3 and 5).
  # All messages are proto2, so a set zero is emitted and an absent field
  # decodes as nil. Field names are the CRS labels. Enumerations are decoded
  # as plain integers so that an unknown value never fails the parse.
  # Reserved and retired field numbers are not declared: a decoder skips them
  # and an encoder never emits them.

  defmodule Offer do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:media_type, 3, optional: true, type: :int32)
    field(:opaque, 4, optional: true, type: :bytes)
  end

  defmodule Answer do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:opaque, 3, optional: true, type: :bytes)
  end

  defmodule IceUpdate do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:opaque, 5, optional: true, type: :bytes)
  end

  defmodule Busy do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
  end

  defmodule Hangup do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:call_id, 1, optional: true, type: :uint64)
    field(:type, 2, optional: true, type: :int32)
    field(:device_id, 3, optional: true, type: :uint32)
  end

  defmodule Opaque do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:data, 1, optional: true, type: :bytes)
    field(:urgency, 2, optional: true, type: :int32)
  end

  defmodule CallMessage do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:offer, 1, optional: true, type: SalixSignalProto.CallSignaling.Wire.Offer)
    field(:answer, 2, optional: true, type: SalixSignalProto.CallSignaling.Wire.Answer)
    field(:ice_updates, 3, repeated: true, type: SalixSignalProto.CallSignaling.Wire.IceUpdate)
    field(:busy, 5, optional: true, type: SalixSignalProto.CallSignaling.Wire.Busy)
    field(:hangup, 7, optional: true, type: SalixSignalProto.CallSignaling.Wire.Hangup)
    field(:destination_device_id, 9, optional: true, type: :uint32)
    field(:opaque, 10, optional: true, type: SalixSignalProto.CallSignaling.Wire.Opaque)
  end

  defmodule VideoCodec do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:codec, 1, optional: true, type: :int32)
  end

  defmodule ConnectionParameters do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:public_key, 1, optional: true, type: :bytes)
    field(:ice_ufrag, 2, optional: true, type: :string)
    field(:ice_pwd, 3, optional: true, type: :string)

    field(:receive_video_codecs, 4,
      repeated: true,
      type: SalixSignalProto.CallSignaling.Wire.VideoCodec
    )

    field(:max_bitrate_bps, 5, optional: true, type: :uint64)

    field(:encode_video_codecs, 6,
      repeated: true,
      type: SalixSignalProto.CallSignaling.Wire.VideoCodec
    )

    field(:decode_video_codecs, 7,
      repeated: true,
      type: SalixSignalProto.CallSignaling.Wire.VideoCodec
    )
  end

  # The offer and answer opaque (CRS-12 section 5.1). Fields 1 to 3 belong to
  # older protocol versions and are not declared.
  defmodule OfferAnswerWrapper do
    @moduledoc false
    use Protobuf, syntax: :proto2

    field(:connection_parameters, 4,
      optional: true,
      type: SalixSignalProto.CallSignaling.Wire.ConnectionParameters
    )
  end

  defmodule AddedCandidate do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:candidate, 1, optional: true, type: :string)
  end

  defmodule SocketAddress do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:ip, 1, optional: true, type: :bytes)
    field(:port, 2, optional: true, type: :uint32)
  end

  # The ICE update opaque (CRS-12 section 5.3). Field 1 is unused.
  defmodule IceCandidate do
    @moduledoc false
    use Protobuf, syntax: :proto2
    field(:added, 2, optional: true, type: SalixSignalProto.CallSignaling.Wire.AddedCandidate)
    field(:removed, 3, optional: true, type: SalixSignalProto.CallSignaling.Wire.SocketAddress)
  end
end
