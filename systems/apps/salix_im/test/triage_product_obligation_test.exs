defmodule SalixIM.TriageProductObligationTest do
  use SystemsClock.Case, async: false

  alias SalixIM.Triage.{
    ExpressionContext,
    ProductDecision,
    ProductObligation,
    RehearsalSlackReaction
  }

  alias SalixIM.Triage.RunFence.AuthorizedProductEffects

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
end
