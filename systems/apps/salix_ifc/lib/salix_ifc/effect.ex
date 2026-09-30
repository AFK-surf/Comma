defmodule SalixIFC.Effect do
  @moduledoc """
  One outgoing effect as seen by the kernel.

  * `destination` — the audience the effect writes to, resolved by Salix from
    the effect's parameters, never from the model.
  * `writers` — the principal keys allowed to cause a write to that
    destination, `:any` when the destination has no writer authority (an
    agent-private file), or `:unknown` when the resolver could not tell.
  * `request` — the ref of the `:command` item the effect acts on.
  * `sources` — refs of the items the content depends on, or `:context` for
    the whole visible context of the activation.
  """

  alias SalixIFC.{Label, Principal}

  @enforce_keys [:destination, :request]
  defstruct [:destination, :request, writers: :unknown, sources: :context]

  @type t :: %__MODULE__{
          destination: Label.t(),
          writers: MapSet.t(Principal.key()) | :any | :unknown,
          request: binary,
          sources: [binary] | :context
        }

  def valid?(value), do: SalixIFC.Native.call(:effect_valid, {value})
end
