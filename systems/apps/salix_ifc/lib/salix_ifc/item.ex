defmodule SalixIFC.Item do
  @moduledoc """
  One labelled transcript item: a staged input or a tool result (or one
  element of a list result).

  * `ref` — the stable source reference the model cites (`src:…`).
  * `label` — confidentiality label assigned by the resolver.
  * `integrity` — `:command` for an admitted input from a provider/product principal, a
    Schedule, or the system; `:data` for everything else. Only `:command`
    items can be a request.
  * `principal` — the principal who authored a `:command` item; `nil` for
    data.
  """

  alias SalixIFC.{Label, Principal}

  @enforce_keys [:ref, :label, :integrity]
  defstruct [:ref, :label, :integrity, principal: nil]

  @type t :: %__MODULE__{
          ref: binary,
          label: Label.t(),
          integrity: :command | :data,
          principal: Principal.t() | nil
        }

  def valid?(value), do: SalixIFC.Native.call(:item_valid, {value})
end
