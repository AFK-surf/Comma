# Protocol-buffer schemas of contact discovery (CRS-11 §5.1 and §6). Field
# numbers and wire types are the CRS tables; field names are the CRS
# descriptive names. All messages are proto3.

defmodule SalixSignalProto.ContactDiscovery.Lookup.Wire.Request do
  @moduledoc false
  # CRS-11 §6.1. Fields 5 and 8 are reserved.
  use Protobuf, syntax: :proto3

  field(:aci_access_keys, 1, type: :bytes)
  field(:previous_numbers, 2, type: :bytes)
  field(:new_numbers, 3, type: :bytes)
  field(:discarded_numbers, 4, type: :bytes)
  field(:token, 6, type: :bytes)
  field(:token_ack, 7, type: :bool)
end

defmodule SalixSignalProto.ContactDiscovery.Lookup.Wire.Response do
  @moduledoc false
  # CRS-11 §6.2. Field 2 is reserved.
  use Protobuf, syntax: :proto3

  field(:records, 1, type: :bytes)
  field(:token, 3, type: :bytes)
  field(:permits_used, 4, type: :int32)
end

defmodule SalixSignalProto.ContactDiscovery.Attestation.Wire do
  @moduledoc false
  # CRS-11 §5.1. Clients ignore field 1 and use the attested `pk` claim.
  use Protobuf, syntax: :proto3

  field(:public_key, 1, type: :bytes)
  field(:evidence, 2, type: :bytes)
  field(:endorsements, 3, type: :bytes)
end

defmodule SalixSignalProto.ContactDiscovery.Attestation.AnyMessage do
  @moduledoc false
  # A message with no known fields: decoding checks only that the bytes are
  # a well-formed protobuf message (CRS-11 §5.3 step 12).
  use Protobuf, syntax: :proto3
end
