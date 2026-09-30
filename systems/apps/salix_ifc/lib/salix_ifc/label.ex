defmodule SalixIFC.Label do
  @moduledoc """
  A confidentiality label: a set of audience atoms whose readers are the
  intersection of the atoms' readers. More atoms means fewer readers, so the
  lattice order is set inclusion and the join is set union.

  Normal form: `:public` is the identity of the intersection, so it is kept
  only when it is the sole atom. The empty set is represented as `{:public}`,
  the bottom of the lattice.
  """

  alias SalixIFC.Atom

  @enforce_keys [:atoms]
  defstruct [:atoms]

  @type t :: %__MODULE__{atoms: MapSet.t(Atom.t())}

  @doc "Build a label from a list or canonical MapSet of audience atoms."
  def new(atoms) do
    values = SalixIFC.Native.list(atoms)
    unless Enum.all?(values, &Atom.valid?/1), do: raise(ArgumentError, "invalid audience atom")
    SalixIFC.Native.call(:label_new, {values})
  end

  def bottom(), do: SalixIFC.Native.call(:label_bottom, {})
  def join(left, right), do: SalixIFC.Native.call(:label_join, {left, right})
  def join_all(labels), do: SalixIFC.Native.call(:label_join_all, {labels})
  def public?(label), do: SalixIFC.Native.call(:label_public, {label})
  def no_human_readers?(label), do: SalixIFC.Native.call(:label_no_human, {label})
  def runtime_only?(label), do: SalixIFC.Native.call(:label_runtime_only, {label})

  def restricted_at_least?(destination, source),
    do: SalixIFC.Native.call(:label_restricted, {destination, source})

  def equal?(left, right), do: SalixIFC.Native.call(:label_equal, {left, right})
  def atoms(label), do: SalixIFC.Native.call(:label_atoms, {label})
end
