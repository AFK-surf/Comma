defmodule SalixIFCTest do
  use ExUnit.Case, async: true

  alias SalixIFC.{Activation, Effect, Evidence, Facts, Item, Label, Policy, Reason, Receipt}

  describe "receipt transfer continuation" do
    defp transfer_evidence(sources) do
      %Evidence{
        request: "request",
        requester: :system,
        destination: Label.bottom(),
        sources: sources,
        membership_revisions: []
      }
    end

    test "claims each used receipt once in first-use order before completion" do
      evidence =
        transfer_evidence([
          {"one", {:receipt, "b"}},
          {"two", :flow},
          {"three", {:receipt, "a"}},
          {"four", {:receipt, "b"}}
        ])

      assert {:consume, "b", cursor} = SalixIFC.transfer_start(evidence)
      assert {:consume, "a", cursor} = SalixIFC.transfer_resume(cursor, {:ok, true})
      assert :ok = SalixIFC.transfer_resume(cursor, {:ok, true})
      assert :ok = SalixIFC.transfer_start(transfer_evidence([{"one", :flow}]))
    end

    test "a failed claim cannot advance to the remaining receipt" do
      evidence = transfer_evidence([{"one", {:receipt, "a"}}, {"two", {:receipt, "b"}}])
      assert {:consume, "a", cursor} = SalixIFC.transfer_start(evidence)
      assert {:error, :receipt_already_used} = SalixIFC.transfer_resume(cursor, {:ok, false})
      assert {:error, :receipt_unavailable} = SalixIFC.transfer_resume(cursor, {:error, :timeout})
      assert {:error, :receipt_unavailable} = SalixIFC.transfer_resume(cursor, :unexpected)
    end

    test "invalid continuations cannot report completion" do
      assert {:error, :invalid_input} = SalixIFC.transfer_resume(:invalid, {:ok, true})
      assert {:error, :invalid_input} = SalixIFC.transfer_resume([123], {:ok, true})
    end
  end

  # One Slack connect "w": a and b are full members, g is a guest. #legal is a
  # private room with only a; #sc is a Slack Connect room with a and g; D_a is
  # a's DM with the bot; public rooms are labelled as the space itself.
  @w "w"
  @a {:provider_user, @w, "a"}
  @b {:provider_user, @w, "b"}
  @c {:provider_user, @w, "c"}
  @g {:provider_user, @w, "g"}

  @space Label.new([{:space, @w}])
  @legal Label.new([{:scope, @w, "legal"}])
  @shared Label.new([{:scope, @w, "sc"}])
  @dm_a Label.new([{:scope, @w, "D_a"}])
  @finance Label.new([{:scope, @w, "finance"}, {:tag, "finance"}])
  @group Label.new([{:group, "grp"}])
  @task Label.new([{:task, "t1"}])
  @public Label.bottom()

  defp facts(overrides \\ []) do
    base = [
      scopes: %{
        {:scope, @w, "legal"} => [kind: :room, within: {:space, @w}],
        {:scope, @w, "finance"} => [kind: :room, within: {:space, @w}],
        {:scope, @w, "sc"} => [kind: :shared],
        {:scope, @w, "D_a"} => [kind: :direct, within: {:space, @w}]
      },
      membership: %{
        {:space, @w} => {:members, [@a, @b, @c], 11},
        {:scope, @w, "legal"} => {:members, [@a], 7},
        {:scope, @w, "finance"} => {:members, [@a, @b, @c], 5},
        {:tag, "finance"} => {:members, [@a, @b], 2},
        {:scope, @w, "sc"} => {:members, [@a, @g], 3},
        {:scope, @w, "D_a"} => {:members, [@a], 1},
        {:task, "t1"} => {:members, [@a], 1}
      },
      placements: %{
        @a => %{@w => :internal},
        @b => %{@w => :internal},
        @c => %{@w => :internal},
        @g => %{@w => :external}
      },
      now: 100
    ]

    Facts.new(Keyword.merge(base, overrides))
  end

  defp item(ref, label, integrity \\ :data, principal \\ nil),
    do: %Item{ref: ref, label: label, integrity: integrity, principal: principal}

  defp activation(requester, scope, refs),
    do: %Activation{requester: requester, source_scope: scope, consumed_refs: MapSet.new(refs)}

  defp effect(destination, request, opts \\ []) do
    %Effect{
      destination: destination,
      request: request,
      writers: Keyword.get(opts, :writers, :any),
      sources: Keyword.get(opts, :sources, :context)
    }
  end

  defp assert_allow({:allow, %Evidence{} = evidence}), do: evidence
  defp assert_deny({:deny, %Reason{clause: clause}}, expected), do: assert(clause == expected)

  describe "complete source rejection" do
    test "reports mixed failures once per source and admits a revised answer with only safe sources" do
      items = [
        item("q", @space, :command, @b),
        item("legal", @legal),
        item("finance", @finance),
        item("unknown", Label.new([{:tag, "unknown"}])),
        item("safe", @public)
      ]

      act = activation(@b, @space, ["q"])
      facts = facts(policy: Policy.new(sealed_atoms: [{:tag, "finance"}]))

      for sources <- [:context, ["legal", "safe", "finance", "unknown", "legal"]] do
        assert {:deny, %Reason{source_failures: failures} = reason} =
                 SalixIFC.decide(effect(@space, "q", sources: sources), act, items, facts)

        assert Enum.map(failures, &{&1.ref, &1.clause}) ==
                 [{"legal", :flow_denied}, {"finance", :sealed}, {"unknown", :membership_unknown}]

        assert reason.ref == "legal"
        assert Enum.all?(failures, &(&1.source_failures == []))
        encoded = SalixIFC.Codec.encode_decision({:deny, reason})

        assert Enum.map(encoded["source_failures"], & &1["ref"]) == [
                 "legal",
                 "finance",
                 "unknown"
               ]
      end

      assert {:allow, _} =
               SalixIFC.decide(effect(@space, "q", sources: ["q", "safe"]), act, items, facts)
    end

    test "public egress lists every non-public source" do
      items = [item("q", @space, :command, @b), item("legal", @legal), item("safe", @public)]

      assert {:deny, %Reason{source_failures: failures}} =
               SalixIFC.decide(
                 effect(@public, "q"),
                 activation(@b, @space, ["q"]),
                 items,
                 facts(policy: Policy.new(public_egress: :deny))
               )

      assert Enum.map(failures, &{&1.ref, &1.clause}) ==
               [{"q", :public_egress_denied}, {"legal", :public_egress_denied}]
    end

    test "lists all unknown refs without duplicates and preserves request validation" do
      items = [item("q", @space, :command, @b)]
      effect = effect(@space, "q", sources: ["missing-1", "q", "missing-2", "missing-1"])

      assert {:deny, %Reason{source_failures: failures}} =
               SalixIFC.decide(effect, activation(@b, @space, ["q"]), items, facts())

      assert Enum.map(failures, &{&1.ref, &1.clause}) ==
               [{"missing-1", :unknown_source_ref}, {"missing-2", :unknown_source_ref}]

      assert {:deny, %Reason{clause: :request_outside_activation, source_failures: []}} =
               SalixIFC.decide(effect, activation(@b, @space, []), items, facts())
    end
  end

  describe "T1: private room content asked about in a public room" do
    setup do
      %{items: [item("q", @space, :command, @b), item("hit", @legal)]}
    end

    test "an undeclared reply fails closed while a private hit is in context; declaring the request alone passes",
         %{items: items} do
      act = activation(@b, @space, ["q"])
      assert_deny(SalixIFC.decide(effect(@space, "q"), act, items, facts()), :flow_denied)

      evidence =
        assert_allow(SalixIFC.decide(effect(@space, "q", sources: ["q"]), act, items, facts()))

      assert evidence.sources == [{"q", :flow}]
    end

    test "citing the private hit explicitly is denied for a non-member", %{items: items} do
      act = activation(@b, @space, ["q"])

      assert {:deny, %Reason{clause: :flow_denied, ref: "hit", detail: [:scope]}} =
               SalixIFC.decide(effect(@space, "q", sources: ["hit"]), act, items, facts())
    end

    test "a member answering in place declassifies by choosing where to ask" do
      items = [item("q", @space, :command, @a), item("hit", @legal)]
      act = activation(@a, @space, ["q"])

      evidence =
        assert_allow(SalixIFC.decide(effect(@space, "q", sources: ["hit"]), act, items, facts()))

      assert {"hit", :in_place} in evidence.sources
      assert {{:scope, @w, "legal"}, 7} in evidence.membership_revisions
    end

    test "a sealed room never leaves its audience, even in place" do
      items = [item("q", @space, :command, @a), item("hit", @legal)]
      act = activation(@a, @space, ["q"])
      facts = facts(policy: [sealed_atoms: [{:scope, @w, "legal"}]])

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["hit"]), act, items, facts),
        :sealed
      )
    end

    test "answering inside the private room itself is pure flow" do
      items = [item("q", @legal, :command, @a), item("hit", @legal)]
      act = activation(@a, @legal, ["q"])
      evidence = assert_allow(SalixIFC.decide(effect(@legal, "q"), act, items, facts()))
      assert evidence.sources == [{"q", :flow}, {"hit", :flow}]
    end

    test "space-level content flows into any room within the space without membership" do
      items = [item("q", @legal, :command, @a), item("announce", @space)]
      act = activation(@a, @legal, ["q"])
      bare = facts(membership: %{})

      evidence =
        assert_allow(
          SalixIFC.decide(effect(@legal, "q", sources: ["announce"]), act, items, bare)
        )

      assert evidence.sources == [{"announce", :flow}]
    end
  end

  describe "T2: one user's DM asked about by another user" do
    setup do
      %{items: [item("dm", @dm_a, :command, @a), item("q", @space, :command, @b)]}
    end

    test "B's undeclared reply fails closed because A's DM is in context; declaring only B's message passes",
         %{items: items} do
      act = activation(@b, @space, ["q"])
      assert_deny(SalixIFC.decide(effect(@space, "q"), act, items, facts()), :flow_denied)

      evidence =
        assert_allow(SalixIFC.decide(effect(@space, "q", sources: ["q"]), act, items, facts()))

      assert evidence.sources == [{"q", :flow}]
    end

    test "citing the DM explicitly is denied", %{items: items} do
      act = activation(@b, @space, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["dm"]), act, items, facts()),
        :flow_denied
      )
    end

    test "A replying in A's own DM sees B's public message and both are pure flow", %{
      items: items
    } do
      act = activation(@a, @dm_a, ["dm"])
      evidence = assert_allow(SalixIFC.decide(effect(@dm_a, "dm"), act, items, facts()))
      assert evidence.sources == [{"dm", :flow}, {"q", :flow}]
    end

    test "a direct source flows nowhere else even when the destination's members are unknown", %{
      items: items
    } do
      act = activation(@a, @dm_a, ["dm"])
      sparse = facts(membership: %{{:scope, @w, "D_a"} => {:members, [@a], 1}})

      assert_deny(
        SalixIFC.decide(effect(@legal, "dm", sources: ["dm"]), act, items, sparse),
        :flow_denied
      )
    end

    test "A relaying the DM to a public room needs a receipt", %{items: items} do
      act = activation(@a, @dm_a, ["dm"])
      relay = effect(@space, "dm", sources: ["dm"])
      assert_deny(SalixIFC.decide(relay, act, items, facts()), :flow_denied)

      receipt = %Receipt{
        id: "r1",
        requester: @a,
        sources: @dm_a,
        destination: @space,
        expires_at: 200
      }

      evidence = assert_allow(SalixIFC.decide(relay, act, items, facts(receipts: [receipt])))
      assert evidence.sources == [{"dm", {:receipt, "r1"}}]

      assert_deny(
        SalixIFC.decide(relay, act, items, facts(receipts: [receipt], now: 200)),
        :flow_denied
      )
    end

    test "a receipt held by someone else does not help", %{items: items} do
      act = activation(@a, @dm_a, ["dm"])
      receipt = %Receipt{id: "r1", requester: @b, sources: @dm_a, destination: @space}

      assert_deny(
        SalixIFC.decide(
          effect(@space, "dm", sources: ["dm"]),
          act,
          items,
          facts(receipts: [receipt])
        ),
        :flow_denied
      )
    end
  end

  describe "T3: external principals" do
    setup do
      %{
        items: [
          item("q", @shared, :command, @g),
          item("internal", @space),
          item("thread", @shared)
        ]
      }
    end

    test "a guest may answer in its own thread from that thread's content", %{items: items} do
      act = activation(@g, @shared, ["q"])
      assert_deny(SalixIFC.decide(effect(@shared, "q"), act, items, facts()), :flow_denied)

      evidence =
        assert_allow(
          SalixIFC.decide(effect(@shared, "q", sources: ["q", "thread"]), act, items, facts())
        )

      assert evidence.sources == [{"q", :flow}, {"thread", :flow}]
    end

    test "a guest cannot write anywhere else", %{items: items} do
      act = activation(@g, @shared, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "q"), act, items, facts()),
        :external_principal_denied
      )
    end

    test "a guest cannot carry space content into the shared room", %{items: items} do
      act = activation(@g, @shared, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@shared, "q", sources: ["internal"]), act, items, facts()),
        :flow_denied
      )
    end

    test "policy can refuse external principals entirely", %{items: items} do
      act = activation(@g, @shared, ["q"])
      facts = facts(policy: [external_principals: :deny])

      assert_deny(
        SalixIFC.decide(effect(@shared, "q"), act, items, facts),
        :external_principal_denied
      )
    end

    test "an operator placement override makes a full member external", %{items: items} do
      act = activation(@b, @shared, ["q"])
      items = [item("q", @shared, :command, @b) | tl(items)]
      demoted = facts(placements: %{@b => %{@w => :external}})

      assert_deny(
        SalixIFC.decide(effect(@space, "q"), act, items, demoted),
        :external_principal_denied
      )
    end
  end

  describe "T4: request integrity" do
    test "a data item cannot be a request" do
      items = [item("q", @space, :command, @b), item("page", @public)]
      act = activation(@b, @space, ["q", "page"])

      assert_deny(
        SalixIFC.decide(effect(@space, "page"), act, items, facts()),
        :request_not_command
      )
    end

    test "a command outside the activation cannot be a request" do
      items = [item("old", @space, :command, @b), item("q", @space, :command, @b)]
      act = activation(@b, @space, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "old"), act, items, facts()),
        :request_outside_activation
      )
    end

    test "a request by a different principal than the activation's is refused" do
      items = [item("q", @space, :command, @a)]
      act = activation(@b, @space, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "q"), act, items, facts()),
        :request_principal_mismatch
      )
    end

    test "unknown request or source refs are refused" do
      items = [item("q", @space, :command, @b)]
      act = activation(@b, @space, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "nope"), act, items, facts()),
        :unknown_request_ref
      )

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["nope"]), act, items, facts()),
        :unknown_source_ref
      )
    end
  end

  describe "T5: memory writes" do
    test "a DM fact cannot enter group memory without a receipt, and membership gaps fail closed" do
      items = [item("dm", @dm_a, :command, @a), item("note", @legal)]
      act = activation(@a, @dm_a, ["dm"])
      write = effect(@group, "dm", sources: ["dm"])

      assert_deny(SalixIFC.decide(write, act, items, facts()), :flow_denied)

      relay = effect(@group, "dm", sources: ["note"])
      assert_deny(SalixIFC.decide(relay, act, items, facts()), :membership_unknown)

      known =
        facts(
          membership: %{
            {:group, "grp"} => {:members, [@a, @b, @c], 2},
            {:scope, @w, "D_a"} => {:members, [@a], 1}
          }
        )

      assert_deny(SalixIFC.decide(write, act, items, known), :flow_denied)

      receipt = %Receipt{id: "r", requester: @a, sources: @dm_a, destination: @group}
      evidence = assert_allow(SalixIFC.decide(write, act, items, facts(receipts: [receipt])))
      assert evidence.sources == [{"dm", {:receipt, "r"}}]
    end

    test "trust_requester_instruction lets a readable source cross scopes on the requester's command" do
      items = [item("dm", @dm_a, :command, @a)]
      act = activation(@a, @dm_a, ["dm"])
      facts = facts(policy: [declassification: :trust_requester_instruction])
      evidence = assert_allow(SalixIFC.decide(effect(@group, "dm"), act, items, facts))
      assert evidence.sources == [{"dm", :instruction}]
    end
  end

  describe "T6: public egress" do
    setup do
      %{
        items: [item("q", @space, :command, @a), item("page", @public)],
        act: activation(@a, @space, ["q"])
      }
    end

    test "public sources may be published", %{items: items, act: act} do
      evidence =
        assert_allow(
          SalixIFC.decide(effect(@public, "q", sources: ["page"]), act, items, facts())
        )

      assert evidence.sources == [{"page", :flow}]
    end

    test "space content needs a receipt to go public", %{items: items, act: act} do
      publish = effect(@public, "q")
      assert_deny(SalixIFC.decide(publish, act, items, facts()), :flow_denied)

      receipt = %Receipt{id: "r", requester: @a, sources: @space, destination: @public}
      evidence = assert_allow(SalixIFC.decide(publish, act, items, facts(receipts: [receipt])))
      assert {"q", {:receipt, "r"}} in evidence.sources
    end

    test "policy can forbid public egress of non-public content outright", %{
      items: items,
      act: act
    } do
      receipt = %Receipt{id: "r", requester: @a, sources: @space, destination: @public}
      facts = facts(receipts: [receipt], policy: [public_egress: :deny])
      assert_deny(SalixIFC.decide(effect(@public, "q"), act, items, facts), :public_egress_denied)
    end
  end

  describe "T7: Task delegation and report-back" do
    test "delegating a DM request to a Task shared only with its requester is pure flow" do
      items = [item("dm", @dm_a, :command, @a)]
      act = activation(@a, @dm_a, ["dm"])
      evidence = assert_allow(SalixIFC.decide(effect(@task, "dm"), act, items, facts()))
      assert evidence.sources == [{"dm", :flow}]
    end

    test "delegating it to a Task shared with someone else needs a receipt" do
      items = [item("dm", @dm_a, :command, @a)]
      act = activation(@a, @dm_a, ["dm"])

      wider =
        facts(
          membership: %{
            {:task, "t1"} => {:members, [@a, @b], 2},
            {:scope, @w, "D_a"} => {:members, [@a], 1}
          }
        )

      assert_deny(SalixIFC.decide(effect(@task, "dm"), act, items, wider), :flow_denied)
    end

    test "a Task result labelled with its DM provenance reports back to that DM by flow" do
      items = [item("dm", @dm_a, :command, @a), item("report", Label.join(@task, @dm_a))]
      act = activation(@a, @dm_a, ["dm"])
      evidence = assert_allow(SalixIFC.decide(effect(@dm_a, "dm"), act, items, facts()))
      assert evidence.sources == [{"dm", :flow}, {"report", :flow}]
    end

    test "another user cannot pull that Task result into a room" do
      items = [item("q", @space, :command, @b), item("report", Label.join(@task, @dm_a))]
      act = activation(@b, @space, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["report"]), act, items, facts()),
        :flow_denied
      )
    end
  end

  describe "T8: schedules act with their creator's authority under current membership" do
    setup do
      schedule = {:schedule, "s1", @a}
      %{items: [item("fire", @legal, :command, schedule), item("dm", @dm_a)], schedule: schedule}
    end

    test "the creator's DM content may be posted where the schedule was declared, in place",
         ctx do
      act = activation(ctx.schedule, @legal, ["fire"])

      evidence =
        assert_allow(
          SalixIFC.decide(
            effect(@legal, "fire", writers: MapSet.new([@a]), sources: ["dm"]),
            act,
            ctx.items,
            facts()
          )
        )

      assert evidence.requester == @a
      # #legal's only member is a, who reads the DM, so this is pure flow.
      assert {"dm", :flow} in evidence.sources
    end

    test "a creator who left the room can no longer post there", ctx do
      act = activation(ctx.schedule, @legal, ["fire"])

      assert_deny(
        SalixIFC.decide(effect(@legal, "fire", writers: MapSet.new()), act, ctx.items, facts()),
        :writer_not_authorized
      )

      assert_deny(
        SalixIFC.decide(effect(@legal, "fire", writers: :unknown), act, ctx.items, facts()),
        :writers_unknown
      )
    end
  end

  describe "operator-configured tags: room classifications and user clearances" do
    # #finance is a room every member can join, but the operator tagged it
    # `finance`; only a and b are cleared. c is a full member of the space.
    setup do
      %{items: [item("q", @space, :command, @c), item("num", @finance)]}
    end

    test "an uncleared member cannot see or cite tagged content", %{items: items} do
      act = activation(@c, @space, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["num"]), act, items, facts()),
        :flow_denied
      )
    end

    test "a cleared member sees it, and may answer in place", %{items: items} do
      items = [item("q", @space, :command, @b) | tl(items)]
      act = activation(@b, @space, ["q"])

      evidence =
        assert_allow(SalixIFC.decide(effect(@space, "q", sources: ["num"]), act, items, facts()))

      assert evidence.sources == [{"num", :in_place}]
    end

    test "tagged content flows by itself into another room carrying the same tag" do
      other = Label.new([{:scope, @w, "finance-eu"}, {:tag, "finance"}])
      items = [item("q", @finance, :command, @a), item("num", @finance)]
      act = activation(@a, @finance, ["q"])

      evidence =
        assert_allow(SalixIFC.decide(effect(other, "q", sources: ["num"]), act, items, facts()))

      assert evidence.sources == [{"num", :flow}]
    end

    test "tagged content flows into a DM only with a cleared counterpart" do
      dm_b = Label.new([{:scope, @w, "D_b"}])
      dm_c = Label.new([{:scope, @w, "D_c"}])
      items = [item("q", @finance, :command, @a), item("num", @finance)]
      act = activation(@a, @finance, ["q"])

      facts =
        facts(
          membership: %{
            {:scope, @w, "D_b"} => {:members, [@b], 1},
            {:scope, @w, "D_c"} => {:members, [@c], 1},
            {:tag, "finance"} => {:members, [@a, @b], 2},
            {:scope, @w, "finance"} => {:members, [@a, @b, @c], 5}
          }
        )

      assert {:allow, _} = SalixIFC.decide(effect(dm_b, "q", sources: ["num"]), act, items, facts)

      assert_deny(
        SalixIFC.decide(effect(dm_c, "q", sources: ["num"]), act, items, facts),
        :flow_denied
      )
    end

    test "a sealed tag never leaves, even for cleared members answering in place" do
      items = [item("q", @space, :command, @b), item("num", @finance)]
      act = activation(@b, @space, ["q"])
      sealed = facts(policy: [sealed_atoms: [{:tag, "finance"}]])

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["num"]), act, items, sealed),
        :sealed
      )
    end
  end

  describe "provider neutrality: the same kernel over a Feishu connect" do
    # Feishu tenant "fs": p2p chat with u1 is direct; an internal group is a
    # room within the tenant; an external group is shared.
    @fs "fs"
    @u1 {:provider_user, @fs, "ou_1"}
    @u2 {:provider_user, @fs, "ou_2"}
    @tenant Label.new([{:space, @fs}])
    @p2p Label.new([{:scope, @fs, "oc_p2p_u1"}])
    @grp Label.new([{:scope, @fs, "oc_group"}])
    @ext Label.new([{:scope, @fs, "oc_external"}])

    defp feishu_facts do
      Facts.new(
        scopes: %{
          {:scope, @fs, "oc_p2p_u1"} => [kind: :direct, within: {:space, @fs}],
          {:scope, @fs, "oc_group"} => [kind: :room, within: {:space, @fs}],
          {:scope, @fs, "oc_external"} => [kind: :shared]
        },
        membership: %{
          {:scope, @fs, "oc_p2p_u1"} => {:members, [@u1], 1},
          {:scope, @fs, "oc_group"} => {:members, [@u1, @u2], 1}
        },
        placements: %{@u1 => %{@fs => :internal}, @u2 => %{@fs => :internal}}
      )
    end

    test "a p2p chat stays private and tenant content flows into the group" do
      items = [
        item("p", @p2p, :command, @u1),
        item("q", @grp, :command, @u2),
        item("news", @tenant)
      ]

      act = activation(@u2, @grp, ["q"])

      assert_deny(SalixIFC.decide(effect(@grp, "q"), act, items, feishu_facts()), :flow_denied)

      evidence =
        assert_allow(
          SalixIFC.decide(effect(@grp, "q", sources: ["q", "news"]), act, items, feishu_facts())
        )

      assert evidence.sources == [{"q", :flow}, {"news", :flow}]

      assert_deny(
        SalixIFC.decide(effect(@grp, "q", sources: ["p"]), act, items, feishu_facts()),
        :flow_denied
      )
    end

    test "group content does not reach the external group without membership proof" do
      items = [item("q", @grp, :command, @u1), item("plan", @grp)]
      act = activation(@u1, @grp, ["q"])

      assert_deny(
        SalixIFC.decide(effect(@ext, "q", sources: ["plan"]), act, items, feishu_facts()),
        :membership_unknown
      )
    end
  end

  describe "fence subsumption and agent-private destinations" do
    test "destination equal to the source scope with same-scope sources is always flow" do
      items = [item("q", @legal, :command, @a), item("t", @legal), item("u", @legal)]
      act = activation(@a, @legal, ["q"])
      evidence = assert_allow(SalixIFC.decide(effect(@legal, "q"), act, items, facts()))
      assert Enum.all?(evidence.sources, &match?({_, :flow}, &1))
    end

    test "writing to an agent-private file is pure flow from anything" do
      items = [item("q", @legal, :command, @a), item("dm", @dm_a)]
      act = activation(@a, @legal, ["q"])

      evidence =
        assert_allow(
          SalixIFC.decide(
            effect(Label.new([:agent_private]), "q", sources: ["dm"]),
            act,
            items,
            facts()
          )
        )

      assert evidence.sources == [{"dm", :flow}]
    end
  end

  describe "input validation" do
    test "trusted empty sources stay empty after private context has been seen" do
      act = activation(@a, @space, ["q"])
      items = [item("secret", Label.new([:agent_private])), item("q", @space, :command, @a)]

      assert_deny(SalixIFC.decide(effect(@public, "q"), act, items, facts()), :flow_denied)

      for _ <- 1..2 do
        evidence =
          assert_allow(SalixIFC.decide(effect(@public, "q", sources: []), act, items, facts()))

        assert evidence.sources == []
      end
    end

    test "declared refs retain first occurrence order and unknown refs fail closed" do
      act = activation(@a, @space, ["q"])
      items = [item("a", @space), item("q", @space, :command, @a), item("b", @space)]

      evidence =
        assert_allow(
          SalixIFC.decide(effect(@space, "q", sources: ["b", "a", "b"]), act, items, facts())
        )

      assert evidence.sources == [{"b", :flow}, {"a", :flow}]

      assert_allow(SalixIFC.decide(effect(@space, "q"), act, items, facts()))
      |> then(&assert(&1.sources == [{"q", :flow}, {"a", :flow}, {"b", :flow}]))

      assert_deny(
        SalixIFC.decide(effect(@space, "q", sources: ["missing"]), act, items, facts()),
        :unknown_source_ref
      )
    end

    test "receipt search skips invalid grants and retains binary id order" do
      act = activation(@a, @space, ["q"])
      items = [item("q", @space, :command, @a), item("dm", @dm_a)]

      receipts =
        for id <- ["z", "aa", "b"] do
          %Receipt{id: id, requester: @a, sources: @dm_a, destination: @space}
        end

      expired = %Receipt{
        id: "a",
        requester: @a,
        sources: @dm_a,
        destination: @space,
        expires_at: 1
      }

      for grants <- [receipts, Enum.reverse(receipts)] do
        evidence =
          assert_allow(
            SalixIFC.decide(
              effect(@space, "q", sources: ["dm"]),
              act,
              items,
              facts(receipts: [expired | grants], policy: [declassification: :receipt_only])
            )
          )

        assert evidence.sources == [{"dm", {:receipt, "aa"}}]
      end
    end

    test "duplicate refs are refused" do
      items = [item("q", @legal, :command, @a), item("q", @legal)]
      act = activation(@a, @legal, ["q"])
      assert_deny(SalixIFC.decide(effect(@legal, "q"), act, items, facts()), :duplicate_item_ref)
    end

    test "duplicate diagnostics identify the first repeated occurrence" do
      items = Enum.map(["a", "b", "b", "a"], &item(&1, @legal, :command, @a))
      act = activation(@a, @legal, ["a"])

      assert {:deny, %Reason{clause: :duplicate_item_ref, ref: "b"}} =
               SalixIFC.decide(effect(@legal, "a"), act, items, facts())
    end

    test "malformed inputs deny instead of raising" do
      act = activation(@a, @legal, ["q"])
      assert {:deny, %Reason{clause: :invalid_input}} = SalixIFC.decide(%{}, act, [], facts())

      assert {:deny, %Reason{clause: :invalid_input, detail: :effect}} =
               SalixIFC.decide(
                 %Effect{destination: @legal, request: "q", writers: :nope},
                 act,
                 [],
                 facts()
               )

      assert {:deny, %Reason{clause: :invalid_input, detail: :items}} =
               SalixIFC.decide(
                 effect(@legal, "q"),
                 act,
                 [item("q", @legal, :command, :nobody)],
                 facts()
               )
    end

    test "a scope cycle in the facts still terminates" do
      looped =
        Facts.new(
          scopes: %{
            {:scope, @w, "x"} => [kind: :room, within: {:scope, @w, "y"}],
            {:scope, @w, "y"} => [kind: :room, within: {:scope, @w, "x"}]
          }
        )

      assert SalixIFC.atom_subset?({:scope, @w, "x"}, {:scope, @w, "z"}, looped) == :unknown
    end
  end

  describe "compaction" do
    test "compaction label is the join; the empty summary is public" do
      assert SalixIFC.compaction_label([]) == Label.bottom()

      joined =
        SalixIFC.compaction_label([item("a", @legal), item("b", @dm_a), item("c", @public)])

      assert Label.atoms(joined) == Enum.sort([{:scope, @w, "legal"}, {:scope, @w, "D_a"}])
    end
  end

  describe "labels, facts and policy" do
    test "normalization drops public unless alone and rejects invalid atoms" do
      assert Label.new([]) == Label.bottom()
      assert Label.atoms(Label.new([:public, {:tag, "x"}])) == [{:tag, "x"}]
      assert Label.public?(Label.new([:public]))
      assert_raise ArgumentError, fn -> Label.new([{:dm, @w}]) end
    end

    test "facts and policy validate their inputs" do
      assert %Policy{} = Policy.new(declassification: :receipt_only)
      assert_raise ArgumentError, fn -> Policy.new(declassification: :maybe) end
      assert_raise ArgumentError, fn -> Facts.new(now: -1) end

      assert_raise ArgumentError, fn ->
        Facts.new(scopes: %{{:scope, @w, "x"} => [kind: :channel]})
      end

      assert Facts.external?(facts(), @g)
      refute Facts.external?(facts(), :system)
    end
  end
end
