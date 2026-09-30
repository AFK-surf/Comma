defmodule SalixIFC do
  @moduledoc """
  Information-flow decisions executed by the statically linked Lean kernel.
  Inputs are explicit data. Resolvers, clocks, and durable receipt operations
  remain in the calling applications. Lean controls the receipt continuation.
  Unknown permission is not authorization.

  FORMAL-SPEC: VerifiedKernel.IFC.DecisionContract.Authorized,
  VerifiedKernel.IFC.SemanticRefinement.decideChecked_system,
  VerifiedKernel.IFC.TransferSystem.checked_transfer_dispatch.
  """
  alias SalixIFC.{Activation, Effect, Evidence, Facts, Item, Label, Principal, Reason}
  @type tri :: true | false | :unknown
  @type decision :: {:allow, Evidence.t()} | {:deny, Reason.t()}

  @spec decide(Effect.t(), Activation.t(), [Item.t()], Facts.t()) :: decision
  def decide(effect, activation, items, facts),
    do: SalixIFC.Native.call(:decide, {effect, activation, items, facts})

  @doc false
  def transfer_start(%Evidence{} = evidence),
    do: SalixIFC.Native.call(:transfer_start, {evidence})

  @doc false
  def transfer_resume(cursor, observation),
    do: SalixIFC.Native.call(:transfer_resume, {cursor, observation})

  @spec compaction_label([Item.t()]) :: Label.t()
  def compaction_label(items), do: SalixIFC.Native.call(:compaction_label, {items})

  @spec readers_subset?(Label.t(), Label.t(), Facts.t()) :: tri
  def readers_subset?(destination, source, facts),
    do: SalixIFC.Native.call(:readers_subset, {destination, source, facts})

  def atom_subset?(destination, source, facts),
    do: SalixIFC.Native.call(:atom_subset, {destination, source, facts})

  @spec reader?(Principal.t(), Label.t(), Facts.t()) :: tri
  def reader?(principal, label, facts),
    do: SalixIFC.Native.call(:reader, {principal, label, facts})

  def reader_atom?(principal, atom, facts),
    do: SalixIFC.Native.call(:reader_atom, {principal, atom, facts})
end
