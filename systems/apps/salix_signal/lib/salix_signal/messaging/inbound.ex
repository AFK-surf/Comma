defmodule SalixSignal.Messaging.Inbound do
  @moduledoc """
  The admitted outcome of one received envelope, as the pipeline stores it
  in the same commit as the session advance (`SalixSignal.Messaging.Store`).

  Consumers such as the Signal provider (layer C12) read admitted items from
  the store. The pipeline's events only notify them; an item is durable
  before its envelope is acknowledged.

  | Field | Meaning |
  | --- | --- |
  | `guid` | the envelope's server GUID (CRS-05 §3.1) |
  | `outcome` | `:message`, `:server_receipt`, `:failed`, `:unsupported` or `:drop` (`SalixSignalProto.Receive`) |
  | `reason` | why the outcome is not `:message`, or nil |
  | `sender`, `sender_device` | the authenticated sender as an ACI string and device ID, when known |
  | `destination` | `:aci` or `:pni` |
  | `sealed?` | the envelope used sealed sender |
  | `timestamp`, `server_timestamp` | the envelope client and server timestamps |
  | `content_kind` | the main field of the content container (`SalixSignalProto.Message.Content`) |
  | `content` | the serialized content container of a `:message`, or nil |
  | `content_hint`, `group_id` | from the sealed inner message |
  """

  defstruct [
    :guid,
    :outcome,
    :reason,
    :sender,
    :sender_device,
    :destination,
    :timestamp,
    :server_timestamp,
    :content_kind,
    :content,
    sealed?: false,
    content_hint: 0,
    group_id: nil
  ]

  @type t :: %__MODULE__{}
end
