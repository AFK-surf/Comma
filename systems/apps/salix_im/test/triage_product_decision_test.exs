defmodule SalixIM.TriageProductDecisionTest do
  use SystemsClock.Case, async: true

  alias SalixIM.Triage.{ExpressionContext, ProductDecision}

  @source_refs ["source://run/s001", "source://run/s002"]
  @principal_refs ["principal://run/self", "principal://run/p001"]

  test "one patrol decision can reply and independently collect durable context" do
    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "我来确认 owner，并在这里继续跟进。",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [
        %{
          "kind" => "follow_up",
          "subject" => "atlas-login-owner",
          "value" => "需要确认 Atlas 登录事故的 owner",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s001"],
          "recheck_after_hours" => 24
        }
      ],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert :ok = ProductDecision.validate(decision, @source_refs, @principal_refs)
  end

  test "v2 reactions must target the frozen latest source" do
    {:ok, expression_context} = ExpressionContext.build("project", {:ok, %{}})

    decision = %{
      "schema" => ProductDecision.schema(),
      "communication" => %{
        "kind" => "reply",
        "text" => "I will follow up.",
        "source_refs" => ["source://run/s001"]
      },
      "companion_reaction" => %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["source://run/s002"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert :ok =
             ProductDecision.validate_for_target(
               decision,
               @source_refs,
               @principal_refs,
               "none",
               "source://run/s002",
               expression_context
             )

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate_for_target(
               decision,
               @source_refs,
               @principal_refs,
               "none",
               "source://run/s001",
               expression_context
             )

    primary_reaction =
      decision
      |> Map.put("communication", %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["source://run/s001"]
      })
      |> Map.put("companion_reaction", nil)

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate_for_target(
               primary_reaction,
               @source_refs,
               @principal_refs,
               "none",
               "source://run/s002",
               expression_context
             )
  end

  test "periodic patrol leaves explicit recipients to their own routing lane" do
    reply = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "I will take this.",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert :ok =
             ProductDecision.validate_for_target(
               reply,
               @source_refs,
               @principal_refs,
               "none"
             )

    for addressee <- ~w(other self mixed) do
      assert {:error, :invalid_triage_product_decision} =
               ProductDecision.validate_for_target(
                 reply,
                 @source_refs,
                 @principal_refs,
                 addressee
               )
    end

    outside_authority =
      reply
      |> put_in(["communication"], %{
        "kind" => "silence",
        "reason" => "outside_authority",
        "source_refs" => ["source://run/s001"]
      })
      |> put_in(["context_candidates"], [
        %{
          "kind" => "project_fact",
          "subject" => "atlas-owner",
          "value" => "Kim owns the Atlas follow-up",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s001"]
        }
      ])

    assert :ok =
             ProductDecision.validate_for_target(
               outside_authority,
               @source_refs,
               @principal_refs,
               "other"
             )

    assert :ok =
             outside_authority
             |> put_in(["communication", "reason"], "duplicate")
             |> ProductDecision.validate_for_target(
               @source_refs,
               @principal_refs,
               "self"
             )

    provider_proposal =
      reply
      |> put_in(["context_candidates"], outside_authority["context_candidates"])
      |> put_in(["delegations"], [
        %{"task" => "Take over this request", "source_refs" => ["source://run/s001"]}
      ])

    assert %{
             "communication" => %{
               "kind" => "silence",
               "reason" => "outside_authority",
               "source_refs" => []
             },
             "context_candidates" => [_retained_context],
             "delegations" => []
           } = enforced = ProductDecision.enforce_target_boundary(provider_proposal, "other")

    assert :ok =
             ProductDecision.validate_for_target(
               enforced,
               @source_refs,
               @principal_refs,
               "other"
             )
  end

  test "source closure, bounds and context taxonomy fail closed" do
    base = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "I will follow up.",
        "source_refs" => ["source://run/not-observed"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate(base, @source_refs, @principal_refs)

    unknown_kind =
      put_in(base, ["communication"], %{
        "kind" => "silence",
        "reason" => "no_actionable_request",
        "source_refs" => []
      })
      |> put_in(["context_candidates"], [
        %{
          "kind" => "persona_memory",
          "subject" => "private-preference",
          "value" => "secret",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s001"]
        }
      ])

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate(unknown_kind, @source_refs, @principal_refs)
  end

  test "delegations must anchor to the current target thread or due scheduled recheck" do
    slack_context = %{
      "messages" => [
        %{"source_ref" => "source://run/s001", "thread_ref" => "thread://run/t001"},
        %{"source_ref" => "source://run/s002", "thread_ref" => "thread://run/t002"}
      ],
      "source_refs" => ["source://run/s001", "source://run/s002"],
      "decision_target" => %{"source_ref" => "source://run/s002"}
    }

    memory = %{
      "facts" => [
        %{
          "kind" => "retained_follow_up",
          "source_ref" => "source://run/s010",
          "text" =>
            "login-stuck: Check login flow\nFollow-up basis: unconfirmed. Next check at 100."
        },
        %{
          "kind" => "retained_follow_up",
          "source_ref" => "source://run/s011",
          "text" =>
            "due-check: Recheck deployment\nFollow-up basis: agent_owned. Next check at 200. This follow-up triggered the current scheduled recheck. Do not postpone this occurrence based on the next check time; it may already name a future retry."
        }
      ]
    }

    anchors = ProductDecision.delegation_anchor_refs(slack_context, memory, "periodic_patrol")
    assert anchors == ["source://run/s002"]

    mixed = %{
      "schema" => ProductDecision.schema(),
      "communication" => %{
        "kind" => "reply",
        "text" => "Checking the Tokyo mini order.",
        "source_refs" => ["source://run/s002"]
      },
      "context_candidates" => [],
      "delegations" => [
        %{"task" => "Check Tokyo mini quote", "source_refs" => ["source://run/s002"]},
        %{"task" => "Check unrelated login follow-up", "source_refs" => ["source://run/s010"]},
        %{"task" => "Check other thread in channel batch", "source_refs" => ["source://run/s001"]}
      ],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert {:error, :unanchored_delegation} =
             ProductDecision.validate_delegation_anchors(mixed, anchors)

    enforced = ProductDecision.enforce_delegation_anchors(mixed, anchors)
    assert enforced["communication"] == mixed["communication"]

    assert enforced["delegations"] == [
             %{"task" => "Check Tokyo mini quote", "source_refs" => ["source://run/s002"]}
           ]

    assert :ok = ProductDecision.validate_delegation_anchors(enforced, anchors)

    # Scheduled recheck allows the due follow-up ref that triggered this run, not unrelated follow-ups.
    recheck_anchors =
      ProductDecision.delegation_anchor_refs(slack_context, memory, "scheduled_recheck")

    assert Enum.sort(recheck_anchors) == ["source://run/s002", "source://run/s011"]

    recheck_decision = %{
      "delegations" => [
        %{"task" => "Verify due deployment follow-up", "source_refs" => ["source://run/s011"]}
      ]
    }

    assert :ok = ProductDecision.validate_delegation_anchors(recheck_decision, recheck_anchors)

    unrelated_recheck = %{
      "delegations" => [
        %{"task" => "Verify unrelated follow-up", "source_refs" => ["source://run/s010"]}
      ]
    }

    assert {:error, :unanchored_delegation} =
             ProductDecision.validate_delegation_anchors(unrelated_recheck, recheck_anchors)
  end
end
