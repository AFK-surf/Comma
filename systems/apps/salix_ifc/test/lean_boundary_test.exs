defmodule SalixIFC.LeanBoundaryTest do
  use ExUnit.Case, async: true
  alias SalixIFC.{Activation, Effect, Facts, Item, Label, Policy, Reason, Receipt}

  defp input do
    label = Label.new([{:tag, "private"}])
    user = {:comma_user, "u"}

    {%Effect{destination: label, request: "req", writers: :any},
     %Activation{requester: user, source_scope: label, consumed_refs: MapSet.new(["req"])},
     [%Item{ref: "req", label: label, integrity: :command, principal: user}], %Facts{}}
  end

  test "malformed records and runtime identities cannot authorize an effect" do
    {effect, activation, items, facts} = input()
    assert {:allow, _} = SalixIFC.decide(effect, activation, items, facts)

    for bad_facts <- [
          %{facts | policy: %Policy{declassification: :unrecognized}},
          %{facts | membership: %{{:tag, "private"} => {:members, MapSet.new(), -1}}},
          %{facts | now: -1},
          Map.put(facts, :unused, %URI{}),
          Map.put(facts, :unused, self()),
          Map.put(facts, :unused, fn -> true end)
        ] do
      assert {:deny, %Reason{clause: :invalid_input}} =
               SalixIFC.decide(effect, activation, items, bad_facts)
    end

    invalid_label = %Label{atoms: %{__struct__: MapSet, map: %{:public => true}}}

    assert {:deny, %Reason{clause: :invalid_input}} =
             SalixIFC.decide(%{effect | destination: invalid_label}, activation, items, facts)
  end

  test "an expired receipt and an unreadable source cannot declassify" do
    {effect, activation, [request], facts} = input()
    destination = Label.new([{:tag, "destination"}])
    effect = %{effect | destination: destination, sources: ["req"]}

    receipt = %Receipt{
      id: "r",
      requester: activation.requester,
      sources: request.label,
      destination: destination,
      expires_at: 10
    }

    facts = %{
      facts
      | now: 10,
        policy: %Policy{declassification: :receipt_only},
        receipts: MapSet.new([receipt]),
        membership: %{{:tag, "private"} => {:members, MapSet.new([activation.requester]), 1}}
    }

    assert {:deny, _} = SalixIFC.decide(effect, activation, [request], facts)

    assert {:allow, %{sources: [{"req", {:receipt, "r"}}]}} =
             SalixIFC.decide(effect, activation, [request], %{facts | now: 9})

    assert {:deny, _} =
             SalixIFC.decide(effect, activation, [request], %{facts | now: 9, membership: %{}})
  end

  test "constructors do not invoke custom enumerable protocols" do
    for constructor <- [&Label.new/1, &Facts.new/1, &Policy.new/1] do
      assert_raise ArgumentError, fn -> constructor.(%URI{}) end
    end
  end

  test "malformed helper arguments cannot become a public label or read permission" do
    for bad <- [%{}, %Label{atoms: %{}}, %Label{atoms: MapSet.new([:unknown_audience])}] do
      assert_raise ArgumentError, fn -> Label.join(bad, Label.bottom()) end
      assert_raise ArgumentError, fn -> SalixIFC.reader?(:system, bad, %Facts{}) end

      assert_raise ArgumentError, fn ->
        SalixIFC.readers_subset?(Label.bottom(), bad, %Facts{})
      end
    end
  end

  test "the IFC domain crosses the same ETF entry point as Session" do
    {effect, activation, items, facts} = input()

    assert {:ok, {:ok, decision}} =
             SalixVerifiedKernel.invoke(:ifc, :decide, {effect, activation, items, facts})

    assert decision == SalixIFC.decide(effect, activation, items, facts)
    assert {:deny, %Reason{clause: :invalid_input}} = SalixIFC.decide(nil, nil, nil, nil)
  end
end
