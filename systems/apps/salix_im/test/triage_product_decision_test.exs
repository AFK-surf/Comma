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
end
