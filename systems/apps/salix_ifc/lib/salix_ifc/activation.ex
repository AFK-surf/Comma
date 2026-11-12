defmodule SalixIFC.Activation do
  @moduledoc """
  What one effect is decided under: a single requester acting from a single
  source scope. An activation holding several inputs of one thread gives each
  effect the input it declares (`SalixAgent.IFC.Context.with_request/2`).

  * `requester` — the principal of the activation's source.
  * `source_scope` — the label of the place the request came from; the
    default destination of an in-place answer.
  * `consumed_refs` — refs of the `:command` items this activation consumed
    or still holds pending. Only these may be cited as a request.
  """

  alias SalixIFC.{Label, Principal}

  @enforce_keys [:requester, :source_scope]
  defstruct [:requester, :source_scope, consumed_refs: MapSet.new()]

  @type t :: %__MODULE__{
          requester: Principal.t(),
          source_scope: Label.t(),
          consumed_refs: MapSet.t(binary)
        }

  def valid?(value), do: SalixIFC.Native.call(:activation_valid, {value})
end
