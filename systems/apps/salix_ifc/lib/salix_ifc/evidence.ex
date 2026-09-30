defmodule SalixIFC.Evidence do
  @moduledoc """
  Why an effect was allowed. Plain data for the caller to archive verbatim.

  * `sources` — `{ref, clause}` per admitted source; clause is `:flow`,
    `:in_place`, `:instruction`, or `{:receipt, receipt_id}`.
  * `membership_revisions` — `{atom, revision}` for every known membership
    entry consulted, sorted, so the archive records the snapshot.
  """

  alias SalixIFC.{Atom, Label, Principal}

  @enforce_keys [:request, :requester, :destination, :sources, :membership_revisions]
  defstruct [:request, :requester, :destination, :sources, :membership_revisions]

  @type clause :: :flow | :in_place | :instruction | {:receipt, binary}
  @type t :: %__MODULE__{
          request: binary,
          requester: Principal.key(),
          destination: Label.t(),
          sources: [{binary, clause}],
          membership_revisions: [{Atom.t(), non_neg_integer}]
        }
end
