defmodule SalixIFC.Facts do
  @moduledoc """
  Everything the kernel is allowed to know beyond the effect, the activation
  and the items. Impure resolvers build this value; the kernel only reads it.

  * `scopes` — what each `{:scope, …}` atom is: its `kind` and the atom it
    is `within`. Kinds:
      * `:room` — a conversation whose readers are a subset of its parent
        space's members (a private channel, a Feishu internal group chat);
      * `:direct` — a one-to-one conversation with the bot; its readers are
        exactly its `membership` entry (normally one principal);
      * `:shared` — a conversation that admits members from outside the
        space (Slack Connect, a Feishu external group); it has no parent.
    A public room the operator wants treated as space-wide is simply
    labelled `{:space, connect}` by the resolver instead of getting a scope.
  * `membership` — for each atom the caller resolved, either
    `{:members, set_of_principal_keys, revision}` or `:unknown`. Absent atoms
    are `:unknown`. For `{:tag, name}` atoms this is the set of principals
    cleared for the tag. Revisions are echoed into evidence.
  * `placements` — for provider users, whether they are an `:internal` member
    or an `:external` guest of a connect's space. Absent means unknown.
  * `receipts` — declassification receipts; validity at `now` is decided here.
  * `policy` — the Group policy.
  * `now` — the caller's clock reading. The kernel never reads a clock.
  """

  alias SalixIFC.{Atom, Policy, Principal, Receipt}

  defstruct scopes: %{},
            membership: %{},
            placements: %{},
            receipts: MapSet.new(),
            policy: %Policy{},
            now: 0

  @type scope_kind :: :room | :direct | :shared
  @type scope_fact :: %{kind: scope_kind, within: Atom.t() | nil}
  @type membership_entry :: {:members, MapSet.t(Principal.key()), non_neg_integer} | :unknown
  @type placement :: :internal | :external
  @type t :: %__MODULE__{
          scopes: %{Atom.t() => scope_fact},
          membership: %{Atom.t() => membership_entry},
          placements: %{Principal.key() => %{Atom.connect() => placement}},
          receipts: MapSet.t(Receipt.t()),
          policy: Policy.t(),
          now: non_neg_integer
        }

  @scope_kinds [:room, :direct, :shared]

  @doc """
  Builds facts. Membership member sets and placement keys may be given as
  principals or keys; they are stored as keys.
  """
  @spec new(keyword | map) :: t
  def new(overrides \\ []) do
    overrides = Map.new(SalixIFC.Native.entries(overrides))

    scopes =
      overrides
      |> Map.get(:scopes, %{})
      |> SalixIFC.Native.entries()
      |> Map.new(fn {atom, fact} ->
        validate_atom!(atom)
        fact = Map.new(SalixIFC.Native.entries(fact))
        kind = Map.fetch!(fact, :kind)
        within = Map.get(fact, :within)

        unless kind in @scope_kinds,
          do: raise(ArgumentError, "invalid scope kind #{inspect(kind)}")

        unless is_nil(within) or Atom.valid?(within),
          do: raise(ArgumentError, "invalid within #{inspect(within)}")

        {atom, %{kind: kind, within: within}}
      end)

    membership =
      overrides
      |> Map.get(:membership, %{})
      |> SalixIFC.Native.entries()
      |> Map.new(fn
        {atom, :unknown} ->
          validate_atom!(atom)
          {atom, :unknown}

        {atom, {:members, members, revision}} when is_integer(revision) and revision >= 0 ->
          validate_atom!(atom)

          {atom,
           {:members, MapSet.new(SalixIFC.Native.list(members), &Principal.key/1), revision}}
      end)

    placements =
      overrides
      |> Map.get(:placements, %{})
      |> SalixIFC.Native.entries()
      |> Map.new(fn {principal, by_connect} ->
        unless Principal.valid?(principal),
          do: raise(ArgumentError, "invalid principal #{inspect(principal)}")

        by_connect =
          Map.new(SalixIFC.Native.entries(by_connect), fn {connect, placement}
                                                          when is_binary(connect) and
                                                                 placement in [
                                                                   :internal,
                                                                   :external
                                                                 ] ->
            {connect, placement}
          end)

        {Principal.key(principal), by_connect}
      end)

    receipts = overrides |> Map.get(:receipts, []) |> SalixIFC.Native.list() |> MapSet.new()

    unless Enum.all?(receipts, &match?(%Receipt{}, &1)),
      do: raise(ArgumentError, "receipts must be SalixIFC.Receipt structs")

    policy =
      case Map.get(overrides, :policy, %Policy{}) do
        %Policy{} = policy -> policy
        other -> Policy.new(other)
      end

    now = Map.get(overrides, :now, 0)

    unless is_integer(now) and now >= 0,
      do: raise(ArgumentError, "now must be a non-negative integer")

    %__MODULE__{
      scopes: scopes,
      membership: membership,
      placements: placements,
      receipts: receipts,
      policy: policy,
      now: now
    }
  end

  def scope_kind(facts, atom), do: SalixIFC.Native.call(:facts_scope_kind, {facts, atom})
  def within(facts, atom), do: SalixIFC.Native.call(:facts_within, {facts, atom})
  def membership(facts, atom), do: SalixIFC.Native.call(:facts_membership, {facts, atom})
  def member?(facts, key, atom), do: SalixIFC.Native.call(:facts_member, {facts, key, atom})
  def members(facts, atom), do: SalixIFC.Native.call(:facts_members, {facts, atom})
  def revision(facts, atom), do: SalixIFC.Native.call(:facts_revision, {facts, atom})

  def placement(facts, principal, connect),
    do: SalixIFC.Native.call(:facts_placement, {facts, principal, connect})

  def external?(facts, principal), do: SalixIFC.Native.call(:facts_external, {facts, principal})

  defp validate_atom!(atom) do
    unless Atom.valid?(atom), do: raise(ArgumentError, "invalid audience atom")
  end
end
