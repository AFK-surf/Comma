defmodule SalixIM.TriageProductDecisionTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.{ExpressionContext, ProductDecision}

  @source_refs ["source://run/s001", "source://run/s002"]
  @principal_refs ["principal://run/self", "principal://run/p001"]

  test "Unicode product text uses the provider character limits without accepting malformed or oversized output" do
    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "The investigation continues.",
        "source_refs" => [hd(@source_refs)]
      },
      "context_candidates" => [
        %{
          "kind" => "project_fact",
          "subject" => String.duplicate("🧭", 160),
          "value" => String.duplicate("字", 2000),
          "confidence" => "explicit",
          "source_refs" => [hd(@source_refs)]
        }
      ],
      "delegations" => [
        %{"task" => "Read the original trace", "source_refs" => [hd(@source_refs)]}
      ],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert :ok = ProductDecision.validate(decision, @source_refs, @principal_refs)

    for {path, limit} <- [
          {["communication", "text"], 4000},
          {["context_candidates", Access.at(0), "subject"], 160},
          {["context_candidates", Access.at(0), "value"], 2000},
          {["delegations", Access.at(0), "task"], 2000}
        ] do
      assert :ok =
               ProductDecision.validate(
                 put_in(decision, path, String.duplicate("字", limit)),
                 @source_refs,
                 @principal_refs
               )

      for invalid <- [String.duplicate("字", limit + 1), <<255>>, "  "] do
        assert {:error, :invalid_triage_product_decision} =
                 ProductDecision.validate(
                   put_in(decision, path, invalid),
                   @source_refs,
                   @principal_refs
                 )
      end
    end

    # Combining characters count individually, as JSON Schema requires.
    invalid =
      put_in(
        decision,
        ["context_candidates", Access.at(0), "subject"],
        String.duplicate("e\u0301", 81)
      )

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate(invalid, @source_refs, @principal_refs)
  end

  test "factual assessment retains source closure without coupling communication and investigation" do
    assessment = %{
      "requested_outcome" => "Explain the supplied screenshot",
      "available_evidence" => "The source includes an image attachment",
      "unread_source_refs" => [hd(@source_refs)],
      "unavailable_input" => ""
    }

    decision = %{
      "schema" => ProductDecision.schema(),
      "assessment" => assessment,
      "communication" => %{
        "kind" => "reply",
        "text" => "I will read the supplied image.",
        "source_refs" => [hd(@source_refs)]
      },
      "companion_reaction" => nil,
      "context_candidates" => [],
      "delegations" => [
        %{
          "task" => "Read the original image and answer the question",
          "worker_ref" => List.last(@source_refs),
          "source_refs" => [hd(@source_refs)]
        }
      ],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert :ok = ProductDecision.validate(decision, @source_refs, @principal_refs)

    # The provider's maxLength counts Unicode code points, including Chinese
    # and supplementary-plane characters, rather than UTF-8 bytes.
    for text <- [String.duplicate("字", 1200), String.duplicate("🧭", 1200)] do
      assert :ok =
               ProductDecision.validate(
                 put_in(decision, ["assessment", "available_evidence"], text),
                 @source_refs,
                 @principal_refs
               )
    end

    assert :ok =
             ProductDecision.validate(
               Map.delete(decision, "assessment"),
               @source_refs,
               @principal_refs
             )

    silence = %{
      "kind" => "silence",
      "reason" => "insufficient_evidence",
      "source_refs" => [hd(@source_refs)]
    }

    assert :ok =
             ProductDecision.validate(
               %{decision | "communication" => silence},
               @source_refs,
               @principal_refs
             )

    for invalid <- [
          nil,
          Map.put(assessment, "unread_source_refs", ["source://invented"]),
          Map.put(assessment, "unread_source_refs", List.duplicate(hd(@source_refs), 9)),
          Map.put(assessment, "available_evidence", String.duplicate("字", 1201)),
          Map.put(assessment, "available_evidence", String.duplicate("e\u0301", 601)),
          Map.put(assessment, "available_evidence", <<255>>),
          Map.put(assessment, "permission", "publish"),
          Map.delete(assessment, "requested_outcome")
        ] do
      assert {:error, :invalid_triage_product_decision} =
               ProductDecision.validate(
                 %{decision | "assessment" => invalid},
                 @source_refs,
                 @principal_refs
               )
    end
  end

  test "reminder delivery is a closed resolution basis, never a generic context field" do
    candidate = %{
      "kind" => "follow_up_resolution",
      "subject" => "reminder",
      "value" => "The requested reminder",
      "confidence" => "explicit",
      "source_refs" => @source_refs,
      "resolution_basis" => "reminder_delivery"
    }

    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "Your reminder",
        "source_refs" => @source_refs
      },
      "context_candidates" => [candidate],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert :ok = ProductDecision.validate(decision, @source_refs, @principal_refs)

    for invalid <- [
          Map.put(candidate, "resolution_basis", "guess"),
          Map.put(candidate, "kind", "project_fact")
        ] do
      assert {:error, :invalid_triage_product_decision} =
               ProductDecision.validate(
                 %{decision | "context_candidates" => [invalid]},
                 @source_refs,
                 @principal_refs
               )
    end
  end

  test "knowledge scope is closed and only applies to facts and decisions" do
    candidate = %{
      "kind" => "decision",
      "subject" => "workflow",
      "value" => "Use regression tests",
      "confidence" => "explicit",
      "source_refs" => @source_refs
    }

    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "silence",
        "reason" => "already_answered",
        "source_refs" => @source_refs
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    for scope <- ["person", "project"] do
      scoped = Map.put(candidate, "knowledge_scope", scope)

      assert :ok =
               ProductDecision.validate(
                 %{decision | "context_candidates" => [scoped]},
                 @source_refs,
                 @principal_refs
               )
    end

    for invalid <- [
          Map.put(candidate, "knowledge_scope", "organization"),
          Map.put(candidate, "knowledge_scope", "unattributed"),
          Map.merge(candidate, %{
            "kind" => "follow_up",
            "knowledge_scope" => "person",
            "recheck_after_hours" => 24
          })
        ] do
      assert {:error, :invalid_triage_product_decision} =
               ProductDecision.validate(
                 %{decision | "context_candidates" => [invalid]},
                 @source_refs,
                 @principal_refs
               )
    end
  end

  test "follow-up reuse must select a cited source and cannot attach to a fact" do
    ref = "source://run/s001"

    candidate = %{
      "kind" => "follow_up",
      "subject" => "pending trace",
      "value" => "inspect trace",
      "confidence" => "explicit",
      "source_refs" => [ref],
      "follow_up_ref" => ref,
      "follow_up_basis" => "agent_owned",
      "recheck_after_hours" => 2
    }

    assert ProductDecision.valid_context_candidates?([candidate], [ref])

    assert ProductDecision.valid_context_candidates?(
             [Map.put(candidate, "follow_up_action", "update")],
             [ref]
           )

    assert ProductDecision.valid_context_candidates?(
             [candidate |> Map.delete("follow_up_ref") |> Map.put("follow_up_action", "create")],
             [ref]
           )

    refute ProductDecision.valid_context_candidates?(
             [Map.put(candidate, "follow_up_action", "create")],
             [ref]
           )

    refute ProductDecision.valid_context_candidates?(
             [candidate |> Map.delete("follow_up_ref") |> Map.put("follow_up_action", "update")],
             [ref]
           )

    refute ProductDecision.valid_context_candidates?(
             [Map.put(candidate, "follow_up_ref", "source://run/uncited")],
             [ref]
           )

    refute ProductDecision.valid_context_candidates?([Map.put(candidate, "follow_up_ref", nil)], [
             ref
           ])

    fact =
      candidate
      |> Map.drop(~w(follow_up_basis recheck_after_hours))
      |> Map.put("kind", "project_fact")

    refute ProductDecision.valid_context_candidates?([fact], [ref])
  end

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

  test "silence remains a product outcome while explicit context can still be collected" do
    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "silence",
        "reason" => "already_answered",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [
        %{
          "kind" => "decision",
          "subject" => "atlas-login-owner",
          "value" => "Kim owns the Atlas login follow-up",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s001", "source://run/s002"]
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

  test "a bounded standard emoji reaction is a source-backed communication outcome" do
    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reaction",
        "emoji" => "tada",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert :ok = ProductDecision.validate(decision, @source_refs, @principal_refs)

    assert {:error, :invalid_triage_product_decision} =
             decision
             |> put_in(["communication", "emoji"], "custom_emoji_not_in_catalog")
             |> ProductDecision.validate(@source_refs, @principal_refs)

    assert {:error, :invalid_triage_product_decision} =
             decision
             |> put_in(["communication", "source_refs"], [])
             |> ProductDecision.validate(@source_refs, @principal_refs)

    assert {:error, :invalid_triage_product_decision} =
             decision
             |> put_in(["communication", "source_refs"], @source_refs)
             |> ProductDecision.validate(@source_refs, @principal_refs)
  end

  test "a reply may carry one independently source-backed companion reaction" do
    decision = %{
      "schema" => ProductDecision.schema(),
      "communication" => %{
        "kind" => "reply",
        "text" => "我来继续跟进。",
        "source_refs" => ["source://run/s001"]
      },
      "companion_reaction" => %{
        "kind" => "reaction",
        "emoji" => "eyes",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert :ok = ProductDecision.validate(decision, @source_refs, @principal_refs)

    assert {:error, :invalid_triage_product_decision} =
             decision
             |> put_in(["communication"], %{
               "kind" => "reaction",
               "emoji" => "tada",
               "source_refs" => ["source://run/s001"]
             })
             |> ProductDecision.validate(@source_refs, @principal_refs)
  end

  test "v2 accepts a custom companion reaction only from the frozen expression context" do
    {:ok, expression_context} =
      ExpressionContext.build("social", {:ok, %{"party_parrot" => "provider-owned-url"}})

    decision = %{
      "schema" => ProductDecision.schema(),
      "communication" => %{
        "kind" => "reply",
        "text" => "Ship it.",
        "source_refs" => ["source://run/s001"]
      },
      "companion_reaction" => %{
        "kind" => "reaction",
        "emoji" => "party_parrot",
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
             ProductDecision.validate(
               decision,
               @source_refs,
               @principal_refs,
               expression_context
             )

    assert {:error, :invalid_triage_product_decision} =
             decision
             |> put_in(["companion_reaction", "emoji"], "invented_custom")
             |> ProductDecision.validate(
               @source_refs,
               @principal_refs,
               expression_context
             )
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

  test "a CH-admitted directed agent target crosses the human command-lane boundary" do
    target = %{
      "decision_target" => %{
        "source_ref" => "source://run/s002",
        "syntactic_addressee" => "self"
      },
      "messages" => [
        %{"source_ref" => "source://run/s001", "actor_kind" => "human"},
        %{"source_ref" => "source://run/s002", "actor_kind" => "agent"}
      ]
    }

    assert ProductDecision.target_route(target, "clickhouse_etl") == "none"
    assert ProductDecision.target_route(target, "periodic_patrol") == "self"
    assert ProductDecision.target_route(target, "scheduled_recheck") == "self"

    assert target
           |> put_in(["messages", Access.at(1), "actor_kind"], "human")
           |> ProductDecision.target_route("clickhouse_etl") == "self"

    assert target
           |> put_in(["decision_target", "syntactic_addressee"], "mixed")
           |> ProductDecision.target_route("clickhouse_etl") == "none"
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

  test "silence explanations are bounded, source-checked, and optional for retained records" do
    base = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "silence",
        "reason" => "already_answered",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [],
      "delegations" => [],
      "identity_interpretation" => %{"topic" => "none", "referenced_principal_refs" => []}
    }

    assert :ok = ProductDecision.validate(base, @source_refs, @principal_refs)

    explained =
      put_in(
        base,
        ["communication", "explanation"],
        "The requested rollout status was answered in the thread: staging is healthy."
      )

    assert :ok = ProductDecision.validate(explained, @source_refs, @principal_refs)

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate(
               put_in(explained, ["communication", "explanation"], String.duplicate("x", 1001)),
               @source_refs,
               @principal_refs
             )

    assert {:error, :invalid_triage_product_decision} =
             ProductDecision.validate(
               put_in(explained, ["communication", "source_refs"], ["source://run/unknown"]),
               @source_refs,
               @principal_refs
             )
  end
end
