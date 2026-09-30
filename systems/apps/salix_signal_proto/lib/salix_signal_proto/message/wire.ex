# Protocol-buffer schemas of the server envelope and the content messages
# (CRS-05). Field numbers and wire types are the CRS tables; field names are
# the CRS descriptive names. proto2 keeps explicit presence: a set zero is
# emitted, and an absent field decodes as nil.
#
# Text fields are declared as bytes, so a field that is not valid UTF-8 does
# not make the whole message unreadable; validation checks UTF-8 where CRS-05
# requires it. Enumerations are plain varints, so an unrecognized value never
# fails a parse (CRS-05 §2). Messages that Comma only passes through or
# discards (sync, story, sender key distribution, call messages) stay bytes.
# Attachment pointers use the one pointer codec,
# SalixSignalProto.Attachment.Pointer (CRS-05 §5.6, CRS-10).

defmodule SalixSignalProto.Message.Wire.Envelope do
  @moduledoc false
  # CRS-05 §3.1. Fields 2, 3 and 6 are retired and skipped as unknown fields.
  use Protobuf, syntax: :proto2

  field(:kind, 1, optional: true, type: :uint64)
  field(:client_timestamp, 5, optional: true, type: :uint64)
  field(:source_device, 7, optional: true, type: :uint64)
  field(:payload, 8, optional: true, type: :bytes)
  field(:server_guid_string, 9, optional: true, type: :bytes)
  field(:server_timestamp, 10, optional: true, type: :uint64)
  field(:source_service_id_string, 11, optional: true, type: :bytes)
  field(:ephemeral, 12, optional: true, type: :bool)
  field(:destination_service_id_string, 13, optional: true, type: :bytes)
  field(:urgent, 14, optional: true, type: :bool)
  field(:updated_pni_string, 15, optional: true, type: :bytes)
  field(:story, 16, optional: true, type: :bool)
  field(:spam_report_token, 17, optional: true, type: :bytes)
  field(:service_internal, 18, optional: true, type: :bytes)
  field(:source_service_id, 19, optional: true, type: :bytes)
  field(:destination_service_id, 20, optional: true, type: :bytes)
  field(:server_guid, 21, optional: true, type: :bytes)
  field(:updated_pni, 22, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.BodyRange do
  @moduledoc false
  # CRS-05 §5.4. Fields 3, 4 and 5 are mutually exclusive.
  use Protobuf, syntax: :proto2

  field(:start, 1, optional: true, type: :uint64)
  field(:length, 2, optional: true, type: :uint64)
  field(:mention_aci_string, 3, optional: true, type: :bytes)
  field(:style, 4, optional: true, type: :uint64)
  field(:mention_aci, 5, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.QuotedAttachment do
  @moduledoc false
  # CRS-05 §5.4, quote field 4.
  use Protobuf, syntax: :proto2

  field(:content_type, 1, optional: true, type: :bytes)
  field(:file_name, 2, optional: true, type: :bytes)
  field(:thumbnail, 3, optional: true, type: SalixSignalProto.Attachment.Pointer)
end

defmodule SalixSignalProto.Message.Wire.Quote do
  @moduledoc false
  # CRS-05 §5.4. Field 2 is retired.
  use Protobuf, syntax: :proto2

  field(:quoted_message_timestamp, 1, optional: true, type: :uint64)
  field(:text, 3, optional: true, type: :bytes)
  field(:attachments, 4, repeated: true, type: SalixSignalProto.Message.Wire.QuotedAttachment)
  field(:author_aci_string, 5, optional: true, type: :bytes)
  field(:body_ranges, 6, repeated: true, type: SalixSignalProto.Message.Wire.BodyRange)
  field(:kind, 7, optional: true, type: :uint64)
  field(:author_aci, 8, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.Reaction do
  @moduledoc false
  # CRS-05 §5.5. Field 3 is retired.
  use Protobuf, syntax: :proto2

  field(:emoji, 1, optional: true, type: :bytes)
  field(:remove, 2, optional: true, type: :bool)
  field(:target_author_aci_string, 4, optional: true, type: :bytes)
  field(:target_message_timestamp, 5, optional: true, type: :uint64)
  field(:target_author_aci, 6, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.RemoteDelete do
  @moduledoc false
  # CRS-05 §5.5.
  use Protobuf, syntax: :proto2

  field(:target_message_timestamp, 1, optional: true, type: :uint64)
end

defmodule SalixSignalProto.Message.Wire.GroupContext do
  @moduledoc false
  # CRS-05 §5.7 (group v2 context).
  use Protobuf, syntax: :proto2

  field(:master_key, 1, optional: true, type: :bytes)
  field(:revision, 2, optional: true, type: :uint64)
  field(:group_change, 3, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.LinkPreview do
  @moduledoc false
  # CRS-05 §5.9.
  use Protobuf, syntax: :proto2

  field(:url, 1, optional: true, type: :bytes)
  field(:title, 2, optional: true, type: :bytes)
  field(:image, 3, optional: true, type: SalixSignalProto.Attachment.Pointer)
  field(:description, 4, optional: true, type: :bytes)
  field(:date, 5, optional: true, type: :uint64)
end

defmodule SalixSignalProto.Message.Wire.Sticker do
  @moduledoc false
  # CRS-05 §5.9.
  use Protobuf, syntax: :proto2

  field(:pack_id, 1, optional: true, type: :bytes)
  field(:pack_key, 2, optional: true, type: :bytes)
  field(:sticker_id, 3, optional: true, type: :uint64)
  field(:data, 4, optional: true, type: SalixSignalProto.Attachment.Pointer)
  field(:emoji, 5, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.GroupCallUpdate do
  @moduledoc false
  # CRS-05 §5.1, data message field 19.
  use Protobuf, syntax: :proto2

  field(:era_id, 1, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.StoryContext do
  @moduledoc false
  # CRS-05 §5.1, data message field 21.
  use Protobuf, syntax: :proto2

  field(:author_aci_string, 1, optional: true, type: :bytes)
  field(:sent_timestamp, 2, optional: true, type: :uint64)
  field(:author_aci, 3, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.AdminDelete do
  @moduledoc false
  # CRS-05 §5.1, data message field 29.
  use Protobuf, syntax: :proto2

  field(:target_author_aci, 1, optional: true, type: :bytes)
  field(:target_timestamp, 2, optional: true, type: :uint64)
end

defmodule SalixSignalProto.Message.Wire.DataMessage do
  @moduledoc false
  # CRS-05 §5.1. Field 3 (group v1 context) is retired.
  use Protobuf, syntax: :proto2

  alias SalixSignalProto.Message.Wire

  field(:body, 1, optional: true, type: :bytes)
  field(:attachments, 2, repeated: true, type: SalixSignalProto.Attachment.Pointer)
  field(:flags, 4, optional: true, type: :uint64)
  field(:expire_timer, 5, optional: true, type: :uint64)
  field(:profile_key, 6, optional: true, type: :bytes)
  field(:timestamp, 7, optional: true, type: :uint64)
  field(:quote, 8, optional: true, type: Wire.Quote)
  field(:contacts, 9, repeated: true, type: :bytes)
  field(:previews, 10, repeated: true, type: Wire.LinkPreview)
  field(:sticker, 11, optional: true, type: Wire.Sticker)
  field(:required_protocol_version, 12, optional: true, type: :uint64)
  field(:view_once, 14, optional: true, type: :bool)
  field(:group_v2, 15, optional: true, type: Wire.GroupContext)
  field(:reaction, 16, optional: true, type: Wire.Reaction)
  field(:remote_delete, 17, optional: true, type: Wire.RemoteDelete)
  field(:body_ranges, 18, repeated: true, type: Wire.BodyRange)
  field(:group_call_update, 19, optional: true, type: Wire.GroupCallUpdate)
  field(:payment, 20, optional: true, type: :bytes)
  field(:story_context, 21, optional: true, type: Wire.StoryContext)
  field(:gift_badge, 22, optional: true, type: :bytes)
  field(:expire_timer_version, 23, optional: true, type: :uint64)
  field(:poll_create, 24, optional: true, type: :bytes)
  field(:poll_terminate, 25, optional: true, type: :bytes)
  field(:poll_vote, 26, optional: true, type: :bytes)
  field(:pin_message, 27, optional: true, type: :bytes)
  field(:unpin_message, 28, optional: true, type: :bytes)
  field(:admin_delete, 29, optional: true, type: Wire.AdminDelete)
end

defmodule SalixSignalProto.Message.Wire.EditMessage do
  @moduledoc false
  # CRS-05 §5.8.
  use Protobuf, syntax: :proto2

  field(:original_message_timestamp, 1, optional: true, type: :uint64)
  field(:data_message, 2, optional: true, type: SalixSignalProto.Message.Wire.DataMessage)
end

defmodule SalixSignalProto.Message.Wire.ReceiptMessage do
  @moduledoc false
  # CRS-05 §6.1. Repeated scalars are unpacked; the decoder also accepts the
  # packed form.
  use Protobuf, syntax: :proto2

  field(:kind, 1, optional: true, type: :uint64)
  field(:timestamps, 2, repeated: true, type: :uint64)
end

defmodule SalixSignalProto.Message.Wire.TypingMessage do
  @moduledoc false
  # CRS-05 §6.2.
  use Protobuf, syntax: :proto2

  field(:timestamp, 1, optional: true, type: :uint64)
  field(:action, 2, optional: true, type: :uint64)
  field(:group_id, 3, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.NullMessage do
  @moduledoc false
  # CRS-05 §6.5.
  use Protobuf, syntax: :proto2

  field(:padding, 1, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.PniSignatureMessage do
  @moduledoc false
  # CRS-05 §6.7.
  use Protobuf, syntax: :proto2

  field(:pni, 1, optional: true, type: :bytes)
  field(:signature, 2, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Message.Wire.DecryptionErrorMessage do
  @moduledoc false
  # CRS-05 §7. Encoders emit fields 1, 2, 3 in that order.
  use Protobuf, syntax: :proto2

  field(:ratchet_key, 1, optional: true, type: :bytes)
  field(:timestamp, 2, optional: true, type: :uint64)
  field(:device_id, 3, optional: true, type: :uint64)
end

defmodule SalixSignalProto.Message.Wire.Content do
  @moduledoc false
  # CRS-05 §5, the content container. Fields 2, 3, 7, 8 and 9 keep their
  # bytes: Comma discards sync and story messages, and the call message
  # (CRS-12, SalixSignalProto.CallSignaling), the sender key distribution
  # (CRS-09) and the decryption error message (§7) have their own codecs.
  use Protobuf, syntax: :proto2

  alias SalixSignalProto.Message.Wire

  field(:data_message, 1, optional: true, type: Wire.DataMessage)
  field(:sync_message, 2, optional: true, type: :bytes)
  field(:call_message, 3, optional: true, type: :bytes)
  field(:null_message, 4, optional: true, type: Wire.NullMessage)
  field(:receipt_message, 5, optional: true, type: Wire.ReceiptMessage)
  field(:typing_message, 6, optional: true, type: Wire.TypingMessage)
  field(:sender_key_distribution, 7, optional: true, type: :bytes)
  field(:decryption_error, 8, optional: true, type: :bytes)
  field(:story_message, 9, optional: true, type: :bytes)
  field(:pni_signature, 10, optional: true, type: Wire.PniSignatureMessage)
  field(:edit_message, 11, optional: true, type: Wire.EditMessage)
end
