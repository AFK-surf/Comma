defmodule SalixIFC.Receipt do
  @moduledoc """
  A human declassification receipt: `requester` confirmed that content
  labelled within `sources` may flow to `destination`. `expires_at` is an
  integer on the caller's clock or `:never`; validity is decided against the
  `now` the caller places in `SalixIFC.Facts`.
  """

  alias SalixIFC.{Label, Principal}

  @enforce_keys [:id, :requester, :sources, :destination]
  defstruct [:id, :requester, :sources, :destination, expires_at: :never]

  @type t :: %__MODULE__{
          id: binary,
          requester: Principal.t(),
          sources: Label.t(),
          destination: Label.t(),
          expires_at: non_neg_integer | :never
        }

  def valid_at?(receipt, now), do: SalixIFC.Native.call(:receipt_valid_at, {receipt, now})

  def covers?(receipt, requester, source, destination),
    do: SalixIFC.Native.call(:receipt_covers, {receipt, requester, source, destination})
end
