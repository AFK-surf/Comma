defmodule SalixIFC.CodecTest do
  use ExUnit.Case, async: true

  alias SalixIFC.{Codec, Facts, Label, Policy, Principal}

  @atoms [
    :public,
    :agent_private,
    {:space, "T0ABC"},
    {:scope, "T0ABC", "C123"},
    {:tag, "finance"},
    {:conversation, "conv_1"},
    {:group, "grp_1"},
    {:task, "conv_2"}
  ]

  @principals [
    :system,
    {:provider_user, "T0ABC", "U123"},
    {:comma_user, "user_1"},
    {:agent, "agent_1"},
    {:schedule, "sched_1", {:provider_user, "T0ABC", "U123"}},
    {:schedule, "sched_1", {:schedule, "sched_2", :system}},
    {:api_key, "gak_1", {:comma_user, "user_1"}},
    {:api_key, "gak_1", :system}
  ]

  describe "atoms" do
    test "round-trip every shape" do
      for atom <- @atoms do
        encoded = Codec.encode_atom!(atom)
        assert {:ok, ^atom} = Codec.decode_atom(encoded)
      end
    end

    test "refuse an id that would break the grammar" do
      assert Codec.encode_atom({:tag, "a|b"}) == :error
      assert Codec.encode_atom({:scope, "w|1", "C1"}) == :error
      assert Codec.encode_atom({:space, ""}) == :error
      assert Codec.encode_atom({:nonsense, "x"}) == :error
    end

    test "decode refuses malformed input" do
      assert Codec.decode_atom("scope|w1") == :error
      assert Codec.decode_atom("scope|w1|C1|extra") == :error
      assert Codec.decode_atom("space|") == :error
      assert Codec.decode_atom("public|x") == :error
      assert Codec.decode_atom(nil) == :error
      assert Codec.decode_atom(42) == :error
    end
  end

  describe "labels" do
    test "round-trip and normalize" do
      label = Label.new([{:space, "w"}, {:scope, "w", "C1"}, :public])
      assert {:ok, decoded} = Codec.decode_label(Codec.encode_label(label))
      assert Label.equal?(decoded, label)
    end

    test "empty list is bottom" do
      assert {:ok, label} = Codec.decode_label([])
      assert Label.public?(label)
    end

    test "one unreadable atom makes the whole label unreadable" do
      assert Codec.decode_label(["space|w", "nonsense"]) == :error
      assert Codec.decode_label("space|w") == :error
    end

    test "the fallback arity keeps a caller total" do
      fallback = Label.new([:agent_private])
      assert Label.equal?(Codec.decode_label(["bad"], fallback), fallback)
      assert Label.equal?(Codec.decode_label(["public"], fallback), Label.bottom())
    end
  end

  describe "principals" do
    test "round-trip every shape, nesting included" do
      for principal <- @principals do
        encoded = Codec.encode_principal!(principal)
        assert {:ok, ^principal} = Codec.decode_principal(encoded)
      end
    end

    test "refuse ids that would break the grammar" do
      assert Codec.encode_principal({:provider_user, "w", "U|1"}) == :error
      assert Codec.encode_principal({:schedule, "s|1", :system}) == :error
      assert Codec.encode_principal({:bft_member, "x"}) == :error
    end

    test "decode refuses malformed input" do
      assert Codec.decode_principal("provider_user|w") == :error
      assert Codec.decode_principal("schedule|s1|nonsense") == :error
      assert Codec.decode_principal(nil) == :error
    end
  end

  describe "facts" do
    test "decode the resolver's wire shape" do
      facts =
        Codec.decode_facts(%{
          "scopes" => %{
            "scope|w|C1" => %{"kind" => "room", "within" => "space|w"},
            "scope|w|D1" => %{"kind" => "direct", "within" => "space|w"},
            "scope|w|S1" => %{"kind" => "shared", "within" => nil}
          },
          "membership" => %{
            "scope|w|C1" => %{"members" => ["provider_user|w|U1"], "revision" => 7},
            "scope|w|D1" => "unknown"
          },
          "placements" => %{
            "provider_user|w|U1" => %{"w" => "internal"},
            "provider_user|w|G1" => %{"w" => "external"}
          },
          "receipts" => [
            %{
              "id" => "r1",
              "requester" => "provider_user|w|U1",
              "sources" => ["scope|w|D1"],
              "destination" => ["scope|w|C1"],
              "expires_at" => 100
            }
          ],
          "policy" => %{
            "declassification" => "receipt_only",
            "sealed_atoms" => ["tag|legal"],
            "external_principals" => "deny",
            "public_egress" => "deny"
          },
          "now" => 50
        })

      assert Facts.scope_kind(facts, {:scope, "w", "C1"}) == :room
      assert Facts.within(facts, {:scope, "w", "C1"}) == {:space, "w"}
      assert Facts.scope_kind(facts, {:scope, "w", "S1"}) == :shared
      assert Facts.within(facts, {:scope, "w", "S1"}) == nil
      assert Facts.revision(facts, {:scope, "w", "C1"}) == 7
      assert Facts.member?(facts, {:provider_user, "w", "U1"}, {:scope, "w", "C1"})
      assert Facts.membership(facts, {:scope, "w", "D1"}) == :unknown
      assert Facts.placement(facts, {:provider_user, "w", "U1"}, "w") == :internal
      assert Facts.external?(facts, {:provider_user, "w", "G1"})
      assert facts.policy.declassification == :receipt_only
      assert facts.policy.sealed_atoms == MapSet.new([{:tag, "legal"}])
      assert facts.policy.external_principals == :deny
      assert facts.policy.public_egress == :deny
      assert facts.now == 50
      assert [receipt] = Enum.to_list(facts.receipts)
      assert receipt.id == "r1"
      assert receipt.expires_at == 100
    end

    test "unreadable rows are dropped, never guessed" do
      facts =
        Codec.decode_facts(%{
          "scopes" => %{"nonsense" => %{"kind" => "room"}, "scope|w|C1" => %{"kind" => "haunted"}},
          "membership" => %{"scope|w|C1" => %{"members" => ["nonsense"], "revision" => 1}},
          "placements" => %{"provider_user|w|U1" => %{"w" => "maybe"}},
          "receipts" => [%{"id" => "r1", "requester" => "nonsense"}],
          "policy" => %{"declassification" => "anything_goes"},
          "now" => -1
        })

      assert facts.scopes == %{}
      assert Facts.member?(facts, {:provider_user, "w", "U1"}, {:scope, "w", "C1"}) == false
      assert facts.placements == %{}
      assert Enum.empty?(facts.receipts)
      assert facts.policy.declassification == :in_place_and_receipt
      assert facts.now == 0
    end

    test "a non-map decodes to empty facts" do
      assert Codec.decode_facts(nil) == Facts.new()
    end

    test "policies round-trip" do
      policy =
        Policy.new(
          declassification: :none,
          sealed_atoms: [{:scope, "w", "C1"}],
          external_principals: :as_internal,
          public_egress: :allow_public_sources_only
        )

      assert policy |> Codec.encode_policy() |> Codec.decode_policy() == policy
    end
  end

  describe "decisions" do
    test "an allow archives clauses and revisions, never content" do
      items = [
        %SalixIFC.Item{
          ref: "src:q-1",
          label: Label.new([{:scope, "w", "C1"}]),
          integrity: :command,
          principal: {:provider_user, "w", "U1"}
        }
      ]

      facts =
        Facts.new(
          scopes: %{{:scope, "w", "C1"} => %{kind: :room, within: {:space, "w"}}},
          membership: %{{:scope, "w", "C1"} => {:members, [{:provider_user, "w", "U1"}], 3}}
        )

      effect = %SalixIFC.Effect{
        destination: Label.new([{:scope, "w", "C1"}]),
        writers: :any,
        request: "src:q-1",
        sources: ["src:q-1"]
      }

      activation = %SalixIFC.Activation{
        requester: {:provider_user, "w", "U1"},
        source_scope: Label.new([{:scope, "w", "C1"}]),
        consumed_refs: MapSet.new(["src:q-1"])
      }

      assert {:allow, _} = decision = SalixIFC.decide(effect, activation, items, facts)

      assert Codec.encode_decision(decision) == %{
               "outcome" => "allow",
               "request" => "src:q-1",
               "requester" => "provider_user|w|U1",
               "destination" => ["scope|w|C1"],
               "sources" => [%{"ref" => "src:q-1", "clause" => "flow"}],
               "membership_revisions" => [%{"atom" => "scope|w|C1", "revision" => 3}]
             }
    end

    test "a receipt clause carries its id" do
      assert Codec.encode_admitted_source({"src:q-1", {:receipt, "r1"}}) == %{
               "ref" => "src:q-1",
               "clause" => "receipt",
               "receipt_id" => "r1"
             }
    end

    test "a deny archives the clause, the ref and atom kinds only" do
      reason = %SalixIFC.Reason{clause: :flow_denied, ref: "src:q-2", detail: [:scope, :tag]}

      assert Codec.encode_decision({:deny, reason}) == %{
               "outcome" => "deny",
               "clause" => "flow_denied",
               "ref" => "src:q-2",
               "detail" => ["scope", "tag"],
               "source_failures" => []
             }
    end
  end

  test "keys used for membership comparison unwrap schedules" do
    key = Principal.key({:schedule, "s1", {:provider_user, "w", "U1"}})
    assert Codec.encode_principal!(key) == "provider_user|w|U1"
  end

  test "an inbound API key acts as, and is keyed by, its creator" do
    api_key = {:api_key, "gak_1", {:comma_user, "u1"}}
    assert Principal.valid?(api_key)
    assert Principal.authority(api_key) == {:comma_user, "u1"}
    assert Codec.encode_principal!(Principal.key(api_key)) == "comma_user|u1"
    assert Codec.encode_principal!(api_key) == "api_key|gak_1|comma_user|u1"
    assert Codec.decode_principal("api_key|gak_1|comma_user|u1") == {:ok, api_key}
    assert Codec.encode_principal({:api_key, "gak|1", :system}) == :error
    assert Codec.decode_principal("api_key|gak_1|nonsense") == :error
  end
end
