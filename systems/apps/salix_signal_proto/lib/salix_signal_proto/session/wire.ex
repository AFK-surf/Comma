defmodule SalixSignalProto.Session.Wire.DoubleRatchet do
  @moduledoc false
  # Protocol-buffer part of the double-ratchet message (CRS-04 §7.2). Field
  # names are the CRS names. proto2 keeps explicit presence, so a set zero is
  # emitted and an absent field decodes as nil.
  use Protobuf, syntax: :proto2

  field(:ratchet_public_key, 1, optional: true, type: :bytes)
  field(:message_number, 2, optional: true, type: :uint32)
  field(:previous_chain_length, 3, optional: true, type: :uint32)
  field(:encrypted_body, 4, optional: true, type: :bytes)
  field(:post_quantum_message, 5, optional: true, type: :bytes)
  field(:address_binding, 6, optional: true, type: :bytes)
end

defmodule SalixSignalProto.Session.Wire.PreKey do
  @moduledoc false
  # Protocol-buffer part of the pre-key message (CRS-04 §7.3).
  use Protobuf, syntax: :proto2

  field(:one_time_pre_key_id, 1, optional: true, type: :uint32)
  field(:initiator_ephemeral_key, 2, optional: true, type: :bytes)
  field(:initiator_identity_key, 3, optional: true, type: :bytes)
  field(:inner_message, 4, optional: true, type: :bytes)
  field(:registration_id, 5, optional: true, type: :uint32)
  field(:signed_pre_key_id, 6, optional: true, type: :uint32)
  field(:kem_pre_key_id, 7, optional: true, type: :uint32)
  field(:kem_ciphertext, 8, optional: true, type: :bytes)
end
