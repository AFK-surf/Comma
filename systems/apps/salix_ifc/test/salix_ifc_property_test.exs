defmodule SalixIFCPropertyTest do
  @moduledoc """
  Runtime laws not replaced by the executable Lean admission proofs.
  See docs/verification.md for the proof boundary.
  Codec and facade regressions remain in the boundary and codec suites.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias SalixIFC.{Activation, Effect, Evidence, Facts, Item, Label, Policy, Receipt}

  @w "w"
  @users ["u1", "u2", "u3"]

  # ---------------------------------------------------------------------------
  # Generators over a small finite universe
  # ---------------------------------------------------------------------------

  defp gen_atom do
    one_of([
      constant(:public),
      constant({:space, @w}),
      member_of(["c1", "c2", "s1", "d1", "d2", "d3"]) |> map(&{:scope, @w, &1}),
      member_of(["t1", "t2"]) |> map(&{:tag, &1}),
      constant({:conversation, "x"}),
      constant({:group, "g"}),
      constant({:task, "t"}),
      constant(:agent_private)
    ])
  end

  @scopes %{
    {:scope, @w, "c1"} => [kind: :room, within: {:space, @w}],
    {:scope, @w, "c2"} => [kind: :room, within: {:space, @w}],
    {:scope, @w, "s1"} => [kind: :shared],
    {:scope, @w, "d1"} => [kind: :direct, within: {:space, @w}],
    {:scope, @w, "d2"} => [kind: :direct, within: {:space, @w}],
    {:scope, @w, "d3"} => [kind: :direct, within: {:space, @w}]
  }

  defp gen_label, do: list_of(gen_atom(), max_length: 3) |> map(&Label.new/1)

  defp gen_provider_user do
    tuple({constant(:provider_user), constant(@w), member_of(@users)})
  end

  defp gen_base_principal do
    one_of([
      gen_provider_user(),
      constant({:comma_user, "cu"}),
      constant({:agent, "ag"}),
      constant(:system)
    ])
  end

  defp gen_principal do
    one_of([
      gen_base_principal(),
      tuple({constant(:schedule), constant("s"), gen_base_principal()}),
      tuple({constant(:api_key), constant("k"), gen_base_principal()})
    ])
  end

  defp gen_key, do: gen_base_principal() |> map(&SalixIFC.Principal.key/1)

  @membership_atoms [
    {:space, @w},
    {:scope, @w, "c1"},
    {:scope, @w, "c2"},
    {:scope, @w, "s1"},
    {:scope, @w, "d1"},
    {:scope, @w, "d2"},
    {:scope, @w, "d3"},
    {:tag, "t1"},
    {:tag, "t2"},
    {:conversation, "x"},
    {:group, "g"},
    {:task, "t"}
  ]

  defp gen_membership_entry do
    one_of([
      constant(:unknown),
      tuple({constant(:members), list_of(gen_key(), max_length: 4), integer(0..9)})
    ])
  end

  defp gen_membership do
    @membership_atoms
    |> Enum.map(fn atom -> {constant(atom), gen_membership_entry()} end)
    |> Enum.map(fn {a, e} -> tuple({a, e}) end)
    |> fixed_list()
    |> map(&Map.new/1)
  end

  defp gen_policy do
    gen all(
          declassification <-
            member_of([:in_place_and_receipt, :receipt_only, :trust_requester_instruction, :none]),
          sealed <- list_of(gen_atom(), max_length: 2),
          external <- member_of([:own_thread_only, :deny, :as_internal]),
          public_egress <- member_of([:receipt, :deny, :allow_public_sources_only])
        ) do
      Policy.new(
        declassification: declassification,
        sealed_atoms: Enum.reject(sealed, &(&1 in [:public, :agent_private])),
        external_principals: external,
        public_egress: public_egress
      )
    end
  end

  defp gen_receipt(requester) do
    gen all(
          id <- string(:alphanumeric, min_length: 1, max_length: 3),
          sources <- gen_label(),
          destination <- gen_label(),
          expires <- one_of([constant(:never), integer(0..20)])
        ) do
      %Receipt{
        id: id,
        requester: requester,
        sources: sources,
        destination: destination,
        expires_at: expires
      }
    end
  end

  defp gen_placements do
    @users
    |> Enum.map(fn u ->
      tuple({constant({:provider_user, @w, u}), member_of([:internal, :external, :unknown])})
    end)
    |> fixed_list()
    |> map(fn pairs ->
      for {p, placement} <- pairs, placement != :unknown, into: %{}, do: {p, %{@w => placement}}
    end)
  end

  defp gen_facts(requester) do
    gen all(
          membership <- gen_membership(),
          placements <- gen_placements(),
          receipts <- list_of(gen_receipt(requester), max_length: 3),
          policy <- gen_policy(),
          now <- integer(0..20)
        ) do
      Facts.new(
        scopes: @scopes,
        membership: membership,
        placements: placements,
        receipts: receipts,
        policy: policy,
        now: now
      )
    end
  end

  # A scenario: a valid activation with a request item present and consumed,
  # plus random data items and stray command items.
  #
  # `:sources` says whether the effect declares its sources explicitly, counts
  # the whole context, or is left to chance. Properties that only hold for one
  # of those *generate* it rather than filtering a general scenario for it: a
  # filter that discards half the generation space is what StreamData's
  # `FilterTooNarrowError` is warning about, and it made property 5 and
  # property 6 fail on unlucky seeds.
  defp gen_scenario(opts \\ []) do
    declaration = Keyword.get(opts, :sources, :either)

    gen all(
          requester <- gen_principal(),
          scope <- gen_label(),
          data_labels <- list_of(gen_label(), max_length: 4),
          stray <- list_of(tuple({gen_label(), gen_principal()}), max_length: 2),
          facts <- gen_facts(requester),
          destination <- gen_label(),
          writers <-
            one_of([
              constant(:any),
              constant(:unknown),
              constant(MapSet.new([SalixIFC.Principal.key(requester)]))
            ]),
          explicit <- gen_declaration(declaration)
        ) do
      request = %Item{ref: "req", label: scope, integrity: :command, principal: requester}

      data =
        data_labels
        |> Enum.with_index()
        |> Enum.map(fn {label, i} -> %Item{ref: "d#{i}", label: label, integrity: :data} end)

      strays =
        stray
        |> Enum.with_index()
        |> Enum.map(fn {{label, p}, i} ->
          %Item{ref: "s#{i}", label: label, integrity: :command, principal: p}
        end)

      items = [request | data ++ strays]

      sources = if explicit, do: Enum.map(data, & &1.ref), else: :context

      effect = %Effect{
        destination: destination,
        writers: writers,
        request: "req",
        sources: sources
      }

      activation = %Activation{
        requester: requester,
        source_scope: scope,
        consumed_refs: MapSet.new(["req"])
      }

      %{effect: effect, activation: activation, items: items, facts: facts, requester: requester}
    end
  end

  defp gen_declaration(:explicit), do: constant(true)
  defp gen_declaration(:context), do: constant(false)
  defp gen_declaration(:either), do: boolean()

  defp tighten(%Facts{} = facts) do
    unknowns = Map.new(facts.membership, fn {atom, _} -> {atom, :unknown} end)

    %Facts{
      facts
      | receipts: MapSet.new(),
        membership: unknowns,
        placements: Map.new(@users, &{{:provider_user, @w, &1}, %{@w => :external}}),
        policy:
          Policy.new(
            declassification: :none,
            sealed_atoms: @membership_atoms,
            external_principals: :deny,
            public_egress: :deny
          )
    }
  end

  defp concretize(%Facts{} = facts, seed_members) do
    membership =
      Map.new(facts.membership, fn
        {atom, :unknown} -> {atom, {:members, MapSet.new(seed_members), 0}}
        {atom, known} -> {atom, known}
      end)

    placements =
      Map.new(@users, fn u ->
        key = {:provider_user, @w, u}
        {key, Map.get(facts.placements, key, %{@w => :internal})}
      end)

    %Facts{facts | membership: membership, placements: placements}
  end

  # ---------------------------------------------------------------------------
  # Laws
  # ---------------------------------------------------------------------------

  property "2. an allow with explicit sources never rested on an unknown membership fact" do
    check all(
            s <- gen_scenario(sources: :explicit),
            members <- list_of(gen_key(), max_length: 3)
          ) do
      case SalixIFC.decide(s.effect, s.activation, s.items, s.facts) do
        {:allow, %Evidence{}} ->
          # More facts may change which clause admits a source (in-place may
          # become pure flow) but can never revoke the verdict.
          assert {:allow, %Evidence{}} =
                   SalixIFC.decide(s.effect, s.activation, s.items, concretize(s.facts, members))

        {:deny, _} ->
          :ok
      end
    end
  end

  property "3. join is a semilattice and readers(join(a, b)) = readers(a) ∩ readers(b)" do
    check all(
            a <- gen_label(),
            b <- gen_label(),
            c <- gen_label(),
            p <- gen_principal(),
            facts <- gen_facts(p)
          ) do
      assert Label.equal?(Label.join(a, b), Label.join(b, a))
      assert Label.equal?(Label.join(a, a), a)
      assert Label.equal?(Label.join(Label.join(a, b), c), Label.join(a, Label.join(b, c)))
      assert Label.equal?(Label.join(a, Label.bottom()), a)

      joined = SalixIFC.reader?(p, Label.join(a, b), facts)
      ra = SalixIFC.reader?(p, a, facts)
      rb = SalixIFC.reader?(p, b, facts)

      expected =
        cond do
          ra == false or rb == false -> false
          ra == :unknown or rb == :unknown -> :unknown
          true -> true
        end

      assert joined == expected
    end
  end

  property "4. a pure-flow allow survives restricting the destination further" do
    check all(
            s <- gen_scenario(),
            not Facts.external?(s.facts, s.requester),
            extra <- gen_label()
          ) do
      %Effect{} = base = s.effect
      effect = %Effect{base | writers: :any}

      case SalixIFC.decide(effect, s.activation, s.items, s.facts) do
        {:allow, %Evidence{sources: sources}} ->
          if Enum.all?(sources, &match?({_, :flow}, &1)) do
            restricted = %Effect{
              effect
              | destination: Label.join(effect.destination, extra),
                sources: Enum.map(sources, &elem(&1, 0))
            }

            assert {:allow, _} = SalixIFC.decide(restricted, s.activation, s.items, s.facts)
          end

        {:deny, _} ->
          :ok
      end
    end
  end

  property "5. tightening facts never turns a deny into an allow (explicit sources)" do
    check all(s <- gen_scenario(sources: :explicit)) do
      case SalixIFC.decide(s.effect, s.activation, s.items, s.facts) do
        {:deny, _} ->
          assert {:deny, _} = SalixIFC.decide(s.effect, s.activation, s.items, tighten(s.facts))

        {:allow, _} ->
          :ok
      end
    end
  end

  property "6. an undeclared effect counts every item in context, so a private item fails it closed" do
    check all(s <- gen_scenario(sources: :context)) do
      index = Map.new(s.items, &{&1.ref, &1})

      case SalixIFC.decide(s.effect, s.activation, s.items, s.facts) do
        {:allow, %Evidence{sources: sources}} ->
          # Every item in context was admitted, none skipped.
          assert Enum.map(sources, &elem(&1, 0)) |> Enum.sort() ==
                   index |> Map.keys() |> Enum.sort()

        {:deny, _} ->
          :ok
      end
    end
  end

  property "8. same-scope sources into the same scope always flow" do
    check all(
            requester <- gen_principal(),
            scope <- gen_label(),
            n <- integer(0..3),
            facts <- gen_facts(requester),
            not Facts.external?(facts, requester)
          ) do
      items =
        [%Item{ref: "req", label: scope, integrity: :command, principal: requester}] ++
          Enum.map(1..n//1, &%Item{ref: "d#{&1}", label: scope, integrity: :data})

      effect = %Effect{destination: scope, writers: :any, request: "req", sources: :context}

      activation = %Activation{
        requester: requester,
        source_scope: scope,
        consumed_refs: MapSet.new(["req"])
      }

      # public_egress :deny is the one policy that can refuse even this; it
      # applies only when the scope itself is public and nothing is private,
      # in which case the sources are public too and the check passes.
      assert {:allow, %Evidence{sources: sources}} =
               SalixIFC.decide(effect, activation, items, facts)

      assert Enum.all?(sources, &match?({_, :flow}, &1))
      assert length(sources) == n + 1
    end
  end

  property "9. compaction labels are at least as restricted as every input" do
    check all(labels <- list_of(gen_label(), max_length: 5)) do
      items =
        labels
        |> Enum.with_index()
        |> Enum.map(fn {l, i} -> %Item{ref: "i#{i}", label: l, integrity: :data} end)

      joined = SalixIFC.compaction_label(items)
      for l <- labels, do: assert(Label.restricted_at_least?(joined, l))
    end
  end
end
