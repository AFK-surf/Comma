defmodule SalixSignal do
  @moduledoc """
  Signal runtime (PLAN "Workstream C"): processes, storage and network on top
  of the pure protocol core in `SalixSignalProto`.

  The service client (CRS-01, CRS-15) is in `SalixSignal.Service.*`: the chat
  WebSocket in `SalixSignal.Service.Chat`, plain HTTPS in
  `SalixSignal.Service.Http`, and challenge answers in
  `SalixSignal.Service.Challenge`.

  The receive and send pipelines of an account (CRS-05, CRS-06, CRS-07) are
  in `SalixSignal.Messaging.Pipeline`, over a durable
  `SalixSignal.Messaging.Store`.

  The Groups v2 storage-service client (CRS-09b) is in `SalixSignal.Groups`.

  Contact discovery (CRS-11), phone number to service ID, is in
  `SalixSignal.ContactDiscovery`.

  1:1 call signaling (CRS-12) is in `SalixSignal.CallSignaling`. Call media
  (CRS-13) is in `SalixSignal.CallMedia`.
  """
end
