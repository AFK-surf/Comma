# Protocol-buffer schemas of sealed sender (CRS-06). Field names are the CRS
# descriptive names. Text fields are bytes; the certificate codecs check them.

defmodule SalixSignalProto.SealedSender.Wire.Signed do
  @moduledoc false
  # Outer form of both certificates (CRS-06 §3.1, §3.2): the certificate
  # body bytes and a signature over exactly those bytes.
  use Protobuf, syntax: :proto2

  field(:body, 1, optional: true, type: :bytes)
  field(:signature, 2, optional: true, type: :bytes)
end

defmodule SalixSignalProto.SealedSender.Wire.ServerCertificateBody do
  @moduledoc false
  # CRS-06 §3.1.
  use Protobuf, syntax: :proto2

  field(:key_id, 1, optional: true, type: :uint32)
  field(:server_public, 2, optional: true, type: :bytes)
end

defmodule SalixSignalProto.SealedSender.Wire.SenderCertificateBody do
  @moduledoc false
  # CRS-06 §3.2. Exactly one of 5 and 8, and exactly one of 6 and 7.
  use Protobuf, syntax: :proto2

  field(:sender_e164, 1, optional: true, type: :bytes)
  field(:sender_device, 2, optional: true, type: :uint32)
  field(:expiration, 3, optional: true, type: :fixed64)
  field(:identity_key, 4, optional: true, type: :bytes)
  field(:signer, 5, optional: true, type: :bytes)
  field(:sender_aci_string, 6, optional: true, type: :bytes)
  field(:sender_aci, 7, optional: true, type: :bytes)
  field(:signer_key_id, 8, optional: true, type: :uint32)
end

defmodule SalixSignalProto.SealedSender.Wire.InnerMessage do
  @moduledoc false
  # The sealed inner message (CRS-06 §5).
  use Protobuf, syntax: :proto2

  field(:inner_type, 1, optional: true, type: :uint32)
  field(:sender_certificate, 2, optional: true, type: :bytes)
  field(:inner_content, 3, optional: true, type: :bytes)
  field(:content_hint, 4, optional: true, type: :uint32)
  field(:group_id, 5, optional: true, type: :bytes)
end

defmodule SalixSignalProto.SealedSender.Wire.V1 do
  @moduledoc false
  # The protocol-buffer part of a sealed sender v1 message (CRS-06 §7.1).
  use Protobuf, syntax: :proto2

  field(:ephemeral_public, 1, optional: true, type: :bytes)
  field(:encrypted_static, 2, optional: true, type: :bytes)
  field(:encrypted_message, 3, optional: true, type: :bytes)
end
