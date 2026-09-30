defmodule SalixIM.TriageProductObligationTest do
  use ExUnit.Case, async: false

  alias SalixIM.Triage.{
    ExpressionContext,
    ProductDecision,
    ProductObligation,
    RehearsalSlackReaction
  }

  alias SalixIM.Triage.RunFence.AuthorizedProductEffects

  test "a scheduled recheck retains its identity unless it explicitly creates a distinct goal" do
    context_ref = "triage-context://pending-work"

    candidate = %{
      "kind" => "follow_up",
      "subject" => "a rewritten title",
      "value" => "new evidence, same pending work",
      "confidence" => "explicit",
      "source_refs" => ["source://run/s001"],
      "follow_up_basis" => "agent_owned",
      "recheck_after_hours" => 2
    }

    authorization =
      authorization()
      |> put_in([Access.key(:alias_map), "sources", context_ref], "source://run/s003")
      |> put_in([Access.key(:raw_bundle), "sealed_events"], [
        %{
          "source_mode" => "scheduled_recheck",
          "event_id" => "recheck:current",
          "recheck_context_ref" => context_ref
        }
      ])
      |> put_in([Access.key(:fence), "terminal", "decision", "context_candidates"], [candidate])

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert [updated] = obligation["context_candidates"]
    assert updated["follow_up_ref"] == context_ref
    assert context_ref in updated["source_refs"]
    assert ProductObligation.valid?(obligation)

    independent =
      put_in(authorization, [Access.key(:fence), "terminal", "decision", "context_candidates"], [
        Map.put(candidate, "follow_up_action", "create")
      ])

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", independent)

    assert [created] = obligation["context_candidates"]
    refute Map.has_key?(created, "follow_up_ref")
    assert ProductObligation.valid?(obligation)

    # Missing or ambiguous receipt identity must not fall back to creating work.
    for events <- [
          [%{"source_mode" => "scheduled_recheck", "event_id" => "recheck:legacy"}],
          [
            %{
              "source_mode" => "scheduled_recheck",
              "event_id" => "recheck:one",
              "recheck_context_ref" => context_ref
            },
            %{
              "source_mode" => "scheduled_recheck",
              "event_id" => "recheck:two",
              "recheck_context_ref" => "triage-context://another"
            }
          ]
        ] do
      invalid = put_in(authorization, [Access.key(:raw_bundle), "sealed_events"], events)

      assert {:error, :invalid_triage_product_obligation} =
               ProductObligation.prepare("triage-shadow", "triage/fence.json", invalid)
    end
  end

  test "follow-up identity restores a context alias and rejects an ordinary evidence alias" do
    ref = "source://run/s003"
    context_ref = "triage-context://pending-trace"

    candidate = %{
      "kind" => "follow_up",
      "subject" => "trace pending",
      "value" => "inspect trace",
      "confidence" => "explicit",
      "source_refs" => ["source://run/s001", ref],
      "follow_up_ref" => ref,
      "follow_up_basis" => "agent_owned",
      "recheck_after_hours" => 2
    }

    authorization =
      authorization()
      |> put_in([Access.key(:alias_map), "sources", context_ref], ref)
      |> put_in([Access.key(:fence), "terminal", "decision", "context_candidates"], [candidate])

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert [restored] = obligation["context_candidates"]
    assert restored["follow_up_ref"] == context_ref
    assert context_ref in restored["source_refs"]
    assert ProductObligation.valid?(obligation)

    invalid =
      put_in(authorization, [Access.key(:fence), "terminal", "decision", "context_candidates"], [
        Map.put(candidate, "follow_up_ref", "source://run/s001")
      ])

    assert {:error, :invalid_triage_product_obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", invalid)
  end

  test "only the domain assignment proof marks ordinary intake, never a model-selected Worker" do
    authorization =
      selected_worker_authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "communication"],
        SalixIM.Triage.WorkerSelection.pending_communication()
      )
      |> put_in([Access.key(:fence), "terminal", "decision", "context_candidates"], [])
      |> put_in([Access.key(:fence), "terminal", "decision", "companion_reaction"], nil)

    assert {:ok, legacy} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    refute ProductObligation.ordinary_worker_assignment?(legacy)

    authorization =
      put_in(authorization, [Access.key(:fence), "terminal", "evaluator"], %{
        "schema" => "comma.triage-worker-assignment.v1"
      })

    assert {:ok, ordinary} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(ordinary)
    assert ProductObligation.ordinary_worker_assignment?(ordinary)
    refute ordinary["obligation_id"] == legacy["obligation_id"]
    refute ProductObligation.valid?(Map.put(ordinary, "ordinary_worker_assignment", false))
  end

  test "a selected Worker withholds initial text and companion effects without losing sources" do
    authorization = selected_worker_authorization()

    assert {:ok, %{primary: primary, companion: nil}} =
             ProductObligation.prepare_all("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(primary)
    assert primary["communication"]["kind"] == "silence"
    assert primary["communication"]["source_refs"] == ["slack://T1/C1/100/101"]
    assert hd(primary["delegations"])["worker_ref"] == "comma-agent://worker-1"
    assert primary["context_candidates"] != []
    assert authorization.fence["terminal"]["decision"]["communication"]["kind"] == "reply"
  end

  test "withholding a selected Worker's initial reaction removes reaction-only authority" do
    {:ok, expression_context} =
      ExpressionContext.build("social", {:ok, %{"party_parrot" => "provider-owned-url"}})

    authorization =
      selected_worker_authorization()
      |> put_in([Access.key(:fence), "terminal", "decision", "communication"], %{
        "kind" => "reaction",
        "emoji" => "party_parrot",
        "source_refs" => ["source://run/s001"]
      })
      |> put_in([Access.key(:fence), "terminal", "decision", "companion_reaction"], nil)
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context", "expression_context"],
        expression_context
      )

    assert {:ok, %{primary: primary, companion: nil}} =
             ProductObligation.prepare_all("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(primary)
    assert primary["communication"]["kind"] == "silence"
    refute Map.has_key?(primary, "reaction_authority")
  end

  test "withheld companions still require valid source references and emoji authority" do
    for reaction <- [
          %{"kind" => "reaction", "emoji" => "eyes", "source_refs" => ["source://run/missing"]},
          %{
            "kind" => "reaction",
            "emoji" => "invented_custom",
            "source_refs" => ["source://run/s001"]
          }
        ] do
      authorization =
        put_in(
          selected_worker_authorization(),
          [Access.key(:fence), "terminal", "decision", "companion_reaction"],
          reaction
        )

      assert {:error, :invalid_triage_product_obligation} =
               ProductObligation.prepare_all("triage-shadow", "triage/fence.json", authorization)
    end
  end

  test "a scheduled delivery retains its initial reply even when it also selects a Worker" do
    authorization =
      selected_worker_authorization()
      |> put_in([Access.key(:raw_bundle), "sealed_events"], [
        %{"event_id" => "recheck:confirmed-reminder:1", "source_mode" => "scheduled_recheck"}
      ])
      |> put_in([Access.key(:fence), "terminal", "decision", "context_candidates"], [
        %{
          "kind" => "follow_up_resolution",
          "subject" => "Due reminder",
          "value" => "Deliver the confirmed reminder",
          "resolution_basis" => "reminder_delivery",
          "source_refs" => ["source://run/s002"]
        }
      ])

    assert {:ok, %{primary: primary, companion: companion}} =
             ProductObligation.prepare_all("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(primary)
    assert ProductObligation.valid?(companion)
    assert primary["communication"]["kind"] == "reply"
    assert primary["recheck_event_ids"] == ["recheck:confirmed-reminder:1"]
    assert hd(primary["context_candidates"])["resolution_basis"] == "reminder_delivery"
    assert hd(primary["delegations"])["worker_ref"] == "comma-agent://worker-1"
  end

  test "assessment-only references cannot change the effect payload or freshness authority" do
    messages =
      for ordinal <- 1..2 do
        %{
          "actor_id" => "U#{ordinal}",
          "actor_kind" => "human",
          "message_ts" => "10#{ordinal}.000001",
          "message_ts_us" => (100 + ordinal) * 1_000_000 + 1,
          "observed_version" => (200 + ordinal) * 1_000_000 + 2,
          "text" => "Source message #{ordinal}",
          "source_ref" => "slack://T1/C1/100/10#{ordinal}"
        }
      end

    authorization =
      authorization()
      |> update_in([Access.key(:fence), "terminal", "decision"], fn decision ->
        Map.merge(decision, %{
          "schema" => ProductDecision.schema(),
          "companion_reaction" => nil,
          "context_candidates" => []
        })
      end)
      |> put_in([Access.key(:raw_bundle), "raw_context", "slack_context"], %{
        "messages" => messages,
        "source_refs" => Enum.map(messages, & &1["source_ref"])
      })
      |> put_in([Access.key(:alias_map), "sources"], %{
        "slack://T1/C1/100/101" => "source://run/s001",
        "slack://T1/C1/100/102" => "source://run/s002"
      })

    assert {:ok, original} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assessed =
      put_in(authorization, [Access.key(:fence), "terminal", "decision", "assessment"], %{
        "requested_outcome" => "Check the release",
        "available_evidence" => "The original request is visible",
        "unread_source_refs" => ["source://run/s002"],
        "unavailable_input" => ""
      })

    assert :ok =
             ProductDecision.validate(
               assessed.fence["terminal"]["decision"],
               ["source://run/s001", "source://run/s002"],
               []
             )

    assert {:ok, ^original} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", assessed)

    assert Enum.map(original["source_authority"], & &1["message_ts"]) ==
             ["101.000001", "102.000001"]
  end

  test "one terminal restores source authority for reply, context and delegation" do
    authorization = authorization()

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(obligation)
    assert obligation["communication"]["source_refs"] == ["slack://T1/C1/100/101"]
    assert hd(obligation["context_candidates"])["source_refs"] == ["memory://P1/fact-1"]
    assert hd(obligation["delegations"])["source_refs"] == ["slack://T1/C1/100/101"]
    assert obligation["target"]["thread_ts"] == "100.000001"

    assert obligation["source_messages"] == [
             %{
               "actor_id" => "U_PENG",
               "actor_kind" => "human",
               "excerpt" => "Can you check the release?",
               "message_ts" => "101.000001"
             }
           ]

    assert String.starts_with?(obligation["obligation_id"], "triage-product-")
  end

  test "a source-specific silence explanation survives obligation preparation" do
    explanation = "The thread already confirms the requested release check completed."

    authorization =
      authorization()
      |> put_in([Access.key(:fence), "terminal", "decision", "communication"], %{
        "kind" => "silence",
        "reason" => "already_answered",
        "explanation" => explanation,
        "source_refs" => ["source://run/s001"]
      })

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert obligation["communication"]["explanation"] == explanation
    assert obligation["communication"]["source_refs"] == ["slack://T1/C1/100/101"]
  end

  test "an unmappable projected ref refuses the whole obligation" do
    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "communication", "source_refs"],
        ["source://run/missing"]
      )

    assert {:error, :invalid_triage_product_obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)
  end

  test "a personal preference keeps the original Slack author instead of becoming a team rule" do
    authorization =
      put_in(
        authorization(),
        [Access.key(:fence), "terminal", "decision", "context_candidates"],
        [
          %{
            "kind" => "decision",
            "subject" => "Codex 工作流",
            "value" => "我更喜欢先写实现再补测试",
            "confidence" => "explicit",
            "knowledge_scope" => "person",
            "source_refs" => ["source://run/s001"]
          }
        ]
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert [candidate] = obligation["context_candidates"]
    assert candidate["scope_owner"] == %{"kind" => "person", "id" => "slack-user://T1/U_PENG"}

    assert candidate["source_attribution"] == [
             %{
               "source_ref" => "slack://T1/C1/100/101",
               "actor_id" => "U_PENG",
               "message_ts" => "101.000001"
             }
           ]
  end

  test "a personal candidate without a human source cannot acquire a person owner" do
    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "context_candidates"],
        [
          %{
            "kind" => "decision",
            "subject" => "Codex workflow",
            "value" => "Prefer implementation first",
            "confidence" => "explicit",
            "knowledge_scope" => "person",
            "source_refs" => ["source://run/s001"]
          }
        ]
      )
      |> put_in(
        [
          Access.key(:raw_bundle),
          "raw_context",
          "slack_context",
          "messages",
          Access.at(0),
          "actor_kind"
        ],
        "agent"
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert [candidate] = obligation["context_candidates"]
    assert candidate["knowledge_scope"] == "unattributed"
    refute Map.has_key?(candidate, "scope_owner")
  end

  test "scheduled receipt identities survive materialization without including ordinary events" do
    authorization =
      put_in(authorization(), [Access.key(:raw_bundle), "sealed_events"], [
        %{"source_mode" => "scheduled_recheck", "event_id" => "recheck:current"},
        %{"source_mode" => "callback", "event_id" => "ordinary-event"}
      ])

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert obligation["recheck_event_ids"] == ["recheck:current"]
    assert ProductObligation.valid?(obligation)
    refute ProductObligation.valid?(Map.put(obligation, "recheck_event_ids", ["ordinary-event"]))
  end

  test "source file names use the existing bounded display sanitizer without changing source authority" do
    original = authorization()

    files =
      for index <- 1..13 do
        %{
          "name" =>
            if(index == 1,
              do: String.duplicate("会议", 260),
              else: "<@U_PENG> https://private.example.test/file transcript.txt"
            ),
          "mimetype" => "text/plain",
          "url_private" => "https://private.example.test/download",
          "id" => "F-PRIVATE-#{index}"
        }
      end

    authorization =
      put_in(
        original,
        [
          Access.key(:raw_bundle),
          "raw_context",
          "slack_context",
          "messages",
          Access.at(0),
          "file_attachments"
        ],
        SalixIM.Triage.FileAttachments.from_slack(files)
      )

    assert {:ok, old} = ProductObligation.prepare("triage-shadow", "triage/fence.json", original)

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(old)
    assert ProductObligation.valid?(obligation)
    assert obligation["source_authority"] == old["source_authority"]
    [source] = obligation["source_messages"]
    catalogue = source["file_attachments"]
    assert catalogue["total_count"] == 13
    assert catalogue["truncated"]
    assert length(catalogue["items"]) == 10
    assert hd(catalogue["items"])["name"] == String.duplicate("会议", 85)

    for source_text <- ["private.example.test", "U_PENG"] do
      assert Jason.encode!(catalogue) =~ source_text
    end

    refute Jason.encode!(catalogue) =~ "F-PRIVATE"
  end

  test "silence still retains the latest bounded source messages without cited effects" do
    messages =
      for ordinal <- 1..4 do
        %{
          "actor_id" => "U#{ordinal}",
          "actor_kind" => "human",
          "message_ts" => "10#{ordinal}.000001",
          "text" => "Source message #{ordinal}",
          "source_ref" => "slack://T1/C1/100/10#{ordinal}"
        }
      end

    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "communication"],
        %{
          "kind" => "silence",
          "reason" => "duplicate_activity",
          "source_refs" => []
        }
      )
      |> put_in([Access.key(:fence), "terminal", "decision", "context_candidates"], [])
      |> put_in([Access.key(:fence), "terminal", "decision", "delegations"], [])
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context"],
        %{
          "messages" => messages,
          "source_refs" => Enum.map(messages, & &1["source_ref"])
        }
      )
      |> put_in(
        [Access.key(:raw_bundle), "target_cutoff"],
        %{"event_message_timestamps" => Enum.map(messages, & &1["message_ts"])}
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert obligation["source_messages"] == [
             %{
               "actor_id" => "U2",
               "actor_kind" => "human",
               "excerpt" => "Source message 2",
               "message_ts" => "102.000001"
             },
             %{
               "actor_id" => "U3",
               "actor_kind" => "human",
               "excerpt" => "Source message 3",
               "message_ts" => "103.000001"
             },
             %{
               "actor_id" => "U4",
               "actor_kind" => "human",
               "excerpt" => "Source message 4",
               "message_ts" => "104.000001"
             }
           ]
  end

  test "an old cited source is retained beside the latest context for send-time freshness" do
    messages =
      for ordinal <- 1..5 do
        %{
          "actor_id" => "U#{ordinal}",
          "actor_kind" => "human",
          "message_ts" => "10#{ordinal}.000001",
          "message_ts_us" => (100 + ordinal) * 1_000_000 + 1,
          "observed_version" => (200 + ordinal) * 1_000_000 + 2,
          "text" => "Source message #{ordinal}",
          "source_ref" => "slack://T1/C1/100/10#{ordinal}"
        }
      end

    first_ref = hd(messages)["source_ref"]

    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "communication"],
        %{
          "kind" => "reply",
          "text" => "I found the original request.",
          "source_refs" => ["source://run/s001"]
        }
      )
      |> put_in([Access.key(:fence), "terminal", "decision", "context_candidates"], [])
      |> put_in([Access.key(:fence), "terminal", "decision", "delegations"], [])
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context"],
        %{"messages" => messages, "source_refs" => Enum.map(messages, & &1["source_ref"])}
      )
      |> put_in(
        [Access.key(:raw_bundle), "target_cutoff"],
        %{"event_message_timestamps" => Enum.map(messages, & &1["message_ts"])}
      )
      |> put_in(
        [Access.key(:alias_map), "sources"],
        %{first_ref => "source://run/s001"}
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert Enum.map(obligation["source_messages"], & &1["message_ts"]) ==
             ["101.000001", "104.000001", "105.000001"]

    assert hd(obligation["source_messages"])["observed_version"] == 201_000_002
  end

  test "four legal cited Slack sources keep complete freshness authority and bounded display" do
    messages =
      for ordinal <- 1..4 do
        %{
          "actor_id" => "U#{ordinal}",
          "actor_kind" => "human",
          "message_ts" => "10#{ordinal}.000001",
          "message_ts_us" => (100 + ordinal) * 1_000_000 + 1,
          "observed_version" => (200 + ordinal) * 1_000_000 + 2,
          "text" => "Source message #{ordinal}",
          "source_ref" => "slack://T1/C1/100/10#{ordinal}"
        }
      end

    projected_refs = for ordinal <- 1..4, do: "source://run/s00#{ordinal}"

    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "I combined the cited evidence.",
        "source_refs" => [Enum.at(projected_refs, 0)]
      },
      "context_candidates" =>
        for ordinal <- 2..4 do
          %{
            "kind" => "project_fact",
            "subject" => "fact #{ordinal}",
            "value" => "value #{ordinal}",
            "confidence" => "explicit",
            "source_refs" => [Enum.at(projected_refs, ordinal - 1)]
          }
        end,
      "delegations" => [],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    assert ProductDecision.validate(decision, projected_refs, []) == :ok

    aliases =
      messages
      |> Enum.zip(projected_refs)
      |> Map.new(fn {message, projected_ref} -> {message["source_ref"], projected_ref} end)

    authorization =
      authorization()
      |> put_in([Access.key(:fence), "terminal", "decision"], decision)
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context"],
        %{"messages" => messages, "source_refs" => Enum.map(messages, & &1["source_ref"])}
      )
      |> put_in(
        [Access.key(:raw_bundle), "target_cutoff"],
        %{"event_message_timestamps" => Enum.map(messages, & &1["message_ts"])}
      )
      |> put_in([Access.key(:alias_map), "sources"], aliases)

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(obligation)
    assert length(obligation["source_messages"]) == 3

    assert Enum.map(obligation["source_authority"], & &1["message_ts"]) ==
             Enum.map(messages, & &1["message_ts"])
  end

  test "one reaction restores its exact source authority" do
    authorization =
      put_in(
        authorization(),
        [Access.key(:fence), "terminal", "decision", "communication"],
        %{
          "kind" => "reaction",
          "emoji" => "eyes",
          "source_refs" => ["source://run/s001"]
        }
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(obligation)

    assert obligation["communication"] == %{
             "kind" => "reaction",
             "emoji" => "eyes",
             "source_refs" => ["slack://T1/C1/100/101"]
           }
  end

  test "CH context carries the immutable source version into send-time freshness" do
    authorization =
      authorization()
      |> update_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context", "messages", Access.at(0)],
        &Map.merge(&1, %{"message_ts_us" => 101_000_001, "observed_version" => 202_000_004})
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(obligation)

    assert [source] = obligation["source_messages"]
    assert source["message_ts_us"] == 101_000_001
    assert source["observed_version"] == 202_000_004
  end

  test "a reply and companion reaction become two independently executable obligations" do
    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "schema"],
        "comma.triage-product-decision.v2"
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "companion_reaction"],
        %{
          "kind" => "reaction",
          "emoji" => "eyes",
          "source_refs" => ["source://run/s001"]
        }
      )

    assert {:ok, %{primary: primary, companion: companion}} =
             ProductObligation.prepare_all(
               "triage-shadow",
               "triage/fence.json",
               authorization
             )

    assert ProductObligation.valid?(primary)
    assert ProductObligation.valid?(companion)
    assert primary["communication"]["kind"] == "reply"
    assert primary["context_candidates"] != []
    assert primary["delegations"] != []

    assert companion["communication"] == %{
             "kind" => "reaction",
             "emoji" => "eyes",
             "source_refs" => ["slack://T1/C1/100/101"]
           }

    assert companion["context_candidates"] == []
    assert companion["delegations"] == []
    assert companion["obligation_id"] != primary["obligation_id"]
  end

  test "a custom companion reaction freezes the exact workspace expression authority" do
    {:ok, expression_context} =
      ExpressionContext.build("social", {:ok, %{"party_parrot" => "provider-owned-url"}})

    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "schema"],
        "comma.triage-product-decision.v2"
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "companion_reaction"],
        %{
          "kind" => "reaction",
          "emoji" => "party_parrot",
          "source_refs" => ["source://run/s001"]
        }
      )
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context", "expression_context"],
        expression_context
      )

    assert {:ok, %{companion: companion}} =
             ProductObligation.prepare_all(
               "triage-shadow",
               "triage/fence.json",
               authorization
             )

    assert ProductObligation.valid?(companion)
    assert companion["communication"]["emoji"] == "party_parrot"
    assert companion["reaction_authority"] == expression_context

    refute ProductObligation.valid?(
             put_in(companion, ["communication", "emoji"], "invented_custom")
           )
  end

  test "a custom primary reaction freezes the exact workspace expression authority" do
    {:ok, expression_context} =
      ExpressionContext.build("social", {:ok, %{"party_parrot" => "provider-owned-url"}})

    authorization =
      authorization()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "schema"],
        "comma.triage-product-decision.v2"
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "companion_reaction"],
        nil
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "communication"],
        %{
          "kind" => "reaction",
          "emoji" => "party_parrot",
          "source_refs" => ["source://run/s001"]
        }
      )
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context", "expression_context"],
        expression_context
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(obligation)
    assert obligation["reaction_authority"] == expression_context

    assert {:error, :invalid_triage_product_obligation} =
             authorization
             |> put_in(
               [Access.key(:fence), "terminal", "decision", "communication", "emoji"],
               "invented_custom"
             )
             |> then(&ProductObligation.prepare("triage-shadow", "triage/fence.json", &1))
  end

  test "zero-write reaction rehearsal executes primary and companion obligations idempotently" do
    {:ok, expression_context} =
      ExpressionContext.build("social", {:ok, %{"party_parrot" => "provider-owned-url"}})

    primary_authorization =
      authorization()
      |> with_exact_reaction_source()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "schema"],
        "comma.triage-product-decision.v2"
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "companion_reaction"],
        nil
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "communication"],
        %{
          "kind" => "reaction",
          "emoji" => "party_parrot",
          "source_refs" => ["source://run/s001"]
        }
      )
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context", "expression_context"],
        expression_context
      )

    companion_authorization =
      authorization()
      |> with_exact_reaction_source()
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "schema"],
        "comma.triage-product-decision.v2"
      )
      |> put_in(
        [Access.key(:fence), "terminal", "decision", "companion_reaction"],
        %{
          "kind" => "reaction",
          "emoji" => "party_parrot",
          "source_refs" => ["source://run/s001"]
        }
      )
      |> put_in(
        [Access.key(:raw_bundle), "raw_context", "slack_context", "expression_context"],
        expression_context
      )

    assert {:ok, primary} =
             ProductObligation.prepare(
               "triage-shadow",
               "triage/primary-fence.json",
               primary_authorization
             )

    assert {:ok, %{companion: companion}} =
             ProductObligation.prepare_all(
               "triage-shadow",
               "triage/companion-fence.json",
               companion_authorization
             )

    assert primary["obligation_id"] != companion["obligation_id"]

    :ok = RehearsalSlackReaction.reset()
    on_exit(&RehearsalSlackReaction.reset/0)

    for obligation <- [primary, companion] do
      claim = %{obligation_id: obligation["obligation_id"], payload: obligation}
      emoji = obligation["communication"]["emoji"]

      assert {:ok, %{already_reacted: false}} =
               RehearsalSlackReaction.add(claim, "101.000001", emoji, [])

      assert {:ok, %{already_reacted: true}} =
               RehearsalSlackReaction.add(claim, "101.000001", emoji, [])
    end

    assert RehearsalSlackReaction.records()
           |> Enum.map(& &1["obligation_id"])
           |> Enum.uniq()
           |> length() == 2
  end

  test "a durable reaction obligation targets exactly one Slack source" do
    authorization =
      put_in(
        authorization(),
        [Access.key(:fence), "terminal", "decision", "communication"],
        %{
          "kind" => "reaction",
          "emoji" => "eyes",
          "source_refs" => ["source://run/s001", "source://run/s002"]
        }
      )

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    refute ProductObligation.valid?(obligation)
  end

  test "projects the closed effect identity from the richer sealed product identity" do
    authorization =
      update_in(authorization(), [Access.key(:raw_bundle), "product_identity"], fn identity ->
        Map.merge(identity, %{
          "project_status" => "active",
          "project_archived_at" => nil,
          "agent_project_id" => identity["project_id"],
          "agent_status" => "active",
          "agent_archived_at" => nil,
          "agent_role" => "router",
          "agent_name" => "BFT"
        })
      end)

    assert {:ok, obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)

    assert ProductObligation.valid?(obligation)

    assert obligation["product_identity"] == %{
             "project_id" => "project-1",
             "project_salix_group_id" => "group-1",
             "agent_id" => "agent-1",
             "salix_agent_id" => "agt1_shadow"
           }
  end

  test "the richer sealed identity still refuses a missing effect authority field" do
    authorization =
      update_in(authorization(), [Access.key(:raw_bundle), "product_identity"], fn identity ->
        identity
        |> Map.put("agent_role", "router")
        |> Map.delete("salix_agent_id")
      end)

    assert {:error, :invalid_triage_product_obligation} =
             ProductObligation.prepare("triage-shadow", "triage/fence.json", authorization)
  end

  defp selected_worker_authorization do
    authorization()
    |> put_in([Access.key(:fence), "terminal", "decision", "schema"], ProductDecision.schema())
    |> put_in([Access.key(:fence), "terminal", "decision", "companion_reaction"], %{
      "kind" => "reaction",
      "emoji" => "eyes",
      "source_refs" => ["source://run/s001"]
    })
    |> put_in(
      [Access.key(:fence), "terminal", "decision", "delegations", Access.at(0), "worker_ref"],
      "source://run/s003"
    )
    |> put_in([Access.key(:alias_map), "sources", "comma-agent://worker-1"], "source://run/s003")
    |> put_in([Access.key(:raw_bundle), "product_context"], %{
      "facts" => [
        %{"kind" => "available_investigation_worker", "source_ref" => "comma-agent://worker-1"}
      ]
    })
  end

  defp authorization do
    source1 = "slack://T1/C1/100/101"
    source2 = "memory://P1/fact-1"

    decision = %{
      "schema" => "comma.triage-product-decision.v1",
      "communication" => %{
        "kind" => "reply",
        "text" => "I found the answer.",
        "source_refs" => ["source://run/s001"]
      },
      "context_candidates" => [
        %{
          "kind" => "project_fact",
          "subject" => "release owner",
          "value" => "Peng owns the release gate",
          "confidence" => "explicit",
          "source_refs" => ["source://run/s002"]
        }
      ],
      "delegations" => [
        %{
          "task" => "Check the release manifest",
          "source_refs" => ["source://run/s001"]
        }
      ],
      "identity_interpretation" => %{
        "topic" => "none",
        "referenced_principal_refs" => []
      }
    }

    %AuthorizedProductEffects{
      run_id: "run-1",
      fence: %{
        "terminal" => %{
          "status" => "evaluated",
          "decision" => decision,
          "settled_at" => 1_787_900_000_000
        }
      },
      raw_bundle: %{
        "source_authority" => %{
          "connect_id" => "connect-1",
          "connect_generation" => "generation-1",
          "workspace_id" => "T1",
          "channel_id" => "C1",
          "thread_ts" => "100.000001"
        },
        "product_identity" => %{
          "project_id" => "project-1",
          "project_salix_group_id" => "group-1",
          "agent_id" => "agent-1",
          "salix_agent_id" => "agt1_shadow"
        },
        "raw_context" => %{
          "slack_context" => %{
            "messages" => [
              %{
                "actor_id" => "U_PENG",
                "actor_kind" => "human",
                "message_ts" => "101.000001",
                "text" => "Can you check the release?",
                "source_ref" => source1
              }
            ],
            "source_refs" => [source1]
          }
        },
        "target_cutoff" => %{"event_message_timestamps" => ["101.000001"]}
      },
      alias_map: %{
        "sources" => %{
          source1 => "source://run/s001",
          source2 => "source://run/s002"
        }
      }
    }
  end

  defp with_exact_reaction_source(authorization) do
    abbreviated = "slack://T1/C1/100/101"
    exact = "slack://T1/C1/100.000001/101.000001"

    authorization
    |> update_in([Access.key(:alias_map), "sources"], fn sources ->
      sources
      |> Map.delete(abbreviated)
      |> Map.put(exact, "source://run/s001")
    end)
    |> put_in(
      [
        Access.key(:raw_bundle),
        "raw_context",
        "slack_context",
        "messages",
        Access.at(0),
        "source_ref"
      ],
      exact
    )
    |> put_in(
      [Access.key(:raw_bundle), "raw_context", "slack_context", "source_refs"],
      [exact]
    )
  end
end
