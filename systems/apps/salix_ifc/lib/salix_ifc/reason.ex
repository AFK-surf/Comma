defmodule SalixIFC.Reason do
  @moduledoc """
  The first clause, ref, and detail describe why the effect failed.
  `source_failures` lists every failed source in the current check stage, in source order.
  Each entry contains a clause, ref, and detail. It contains no source content.
  Request and writer failures have an empty source list.

  Clauses:

      :invalid_input                malformed effect, activation, items or facts
      :duplicate_item_ref           two items share a ref
      :unknown_request_ref          request ref not in items
      :request_not_command          request item is data
      :request_outside_activation   request ref not consumed by this activation
      :request_without_principal    command item has no principal
      :request_principal_mismatch   request principal differs from the activation's
      :unknown_source_ref           a cited source ref is not in items
      :public_egress_denied         policy forbids this public destination
      :external_principal_denied    external requester outside its own thread
      :writers_unknown              destination writer authority unresolved
      :writer_not_authorized        requester may not write to the destination
      :sealed                       a source atom is sealed and the flow needs declassification
      :membership_unknown           a needed membership fact is unknown
      :flow_denied                  no admitting clause for a source
  """

  @enforce_keys [:clause]
  defstruct [:clause, ref: nil, detail: nil, source_failures: []]

  @type clause ::
          :invalid_input
          | :duplicate_item_ref
          | :unknown_request_ref
          | :request_not_command
          | :request_outside_activation
          | :request_without_principal
          | :request_principal_mismatch
          | :unknown_source_ref
          | :public_egress_denied
          | :external_principal_denied
          | :writers_unknown
          | :writer_not_authorized
          | :sealed
          | :membership_unknown
          | :flow_denied

  @type t :: %__MODULE__{
          clause: clause,
          ref: binary | nil,
          detail: term,
          source_failures: [t()]
        }
end
