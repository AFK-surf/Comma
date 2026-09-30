defmodule SalixIFC.Policy do
  @moduledoc """
  The Group policy knobs the kernel consults. Resolver-side knobs (how public
  channels are labelled, what audience a Task gets) do not appear here because
  they shape the facts, not the decision.

  * `declassification` — which human declassification forms are admitted:
    `:in_place_and_receipt` (default), `:receipt_only`,
    `:trust_requester_instruction`, `:none`.
  * `sealed_atoms` — atoms whose content never leaves its own audience, even
    in place or with a receipt.
  * `external_principals` — `:own_thread_only` (default), `:deny`,
    `:as_internal`.
  * `public_egress` — for destinations that are `{:public}`: `:receipt`
    (default), `:deny`, `:allow_public_sources_only`.
  """

  alias SalixIFC.Atom

  defstruct declassification: :in_place_and_receipt,
            sealed_atoms: MapSet.new(),
            external_principals: :own_thread_only,
            public_egress: :receipt

  @type declassification ::
          :in_place_and_receipt | :receipt_only | :trust_requester_instruction | :none
  @type external_principals :: :own_thread_only | :deny | :as_internal
  @type public_egress :: :receipt | :deny | :allow_public_sources_only

  @type t :: %__MODULE__{
          declassification: declassification,
          sealed_atoms: MapSet.t(Atom.t()),
          external_principals: external_principals,
          public_egress: public_egress
        }

  @declassification [:in_place_and_receipt, :receipt_only, :trust_requester_instruction, :none]
  @external_principals [:own_thread_only, :deny, :as_internal]
  @public_egress [:receipt, :deny, :allow_public_sources_only]

  @doc "Builds a validated policy from keyword or map overrides."
  @spec new(keyword | map) :: t
  def new(overrides \\ []) do
    policy = struct!(__MODULE__, Map.new(SalixIFC.Native.entries(overrides)))

    unless policy.declassification in @declassification,
      do: raise(ArgumentError, "invalid declassification #{inspect(policy.declassification)}")

    unless policy.external_principals in @external_principals,
      do:
        raise(ArgumentError, "invalid external_principals #{inspect(policy.external_principals)}")

    unless policy.public_egress in @public_egress,
      do: raise(ArgumentError, "invalid public_egress #{inspect(policy.public_egress)}")

    sealed = MapSet.new(SalixIFC.Native.list(policy.sealed_atoms))

    unless Enum.all?(sealed, &Atom.valid?/1),
      do: raise(ArgumentError, "invalid sealed atom in #{inspect(Enum.to_list(sealed))}")

    %{policy | sealed_atoms: sealed}
  end

  def in_place_allowed?(policy), do: SalixIFC.Native.call(:policy_in_place, {policy})
  def receipt_allowed?(policy), do: SalixIFC.Native.call(:policy_receipt, {policy})
  def instruction_allowed?(policy), do: SalixIFC.Native.call(:policy_instruction, {policy})
end
