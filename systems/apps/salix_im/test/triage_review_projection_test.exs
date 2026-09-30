defmodule SalixIM.TriageReviewProjectionTest do
  use ExUnit.Case, async: true

  alias SalixIM.Triage.ReviewProjection

  test "v3 projected review evidence preserves every valid decision without executable requests" do
    input = %{
      "schema" => "comma.triage-model-input.v3",
      "snapshot" => %{
        "source_authority" => %{
          "provider" => "slack",
          "workspace_ref" => "workspace://run/self",
          "bucket_ref" => "bucket://run/scope",
          "endpoint_ref" => "endpoint://run/self",
          "scope_kind" => "thread"
        }
      }
    }

    interpretation = %{
      "topic" => "none",
      "referenced_principal_refs" => []
    }

    decisions = [
      %{
        "action" => "silence",
        "source_refs" => [],
        "identity_interpretation" => interpretation
      },
      %{
        "action" => "reply",
        "text" => "@self is the project assistant.",
        "source_refs" => ["source://run/s001"],
        "identity_interpretation" => interpretation
      },
      %{
        "action" => "react",
        "reaction" => "eyes",
        "source_refs" => ["source://run/s001"],
        "identity_interpretation" => interpretation
      },
      %{
        "action" => "delegate",
        "task" => "Summarize the projected thread.",
        "source_refs" => ["source://run/s001"],
        "identity_interpretation" => interpretation
      },
      %{
        "action" => "remember",
        "fact" => "Atlas uses the reviewed release checklist.",
        "source_refs" => ["source://run/s001"],
        "identity_interpretation" => interpretation
      }
    ]

    Enum.each(decisions, fn decision ->
      assert {:ok, artifact} = ReviewProjection.slack(input, decision)
      assert artifact["schema"] == "comma.triage-review-artifact.v2"
      assert artifact["decision"] == decision
      assert artifact["proposed_slack_request"] == nil
      assert artifact["executed_actions"] == []

      assert artifact["target"] == %{
               "provider" => "slack",
               "workspace_ref" => "workspace://run/self",
               "bucket_ref" => "bucket://run/scope",
               "endpoint_ref" => "endpoint://run/self",
               "scope_kind" => "thread"
             }

      assert artifact["readback"] == %{
               "status" => "review_only_not_sent",
               "slack_writes" => 0,
               "worker_starts" => 0,
               "memory_writes" => 0
             }

      canonical_without_id =
        artifact
        |> Map.delete("artifact_id")
        |> SalixIM.Triage.CanonicalJSON.encode!()

      assert artifact["artifact_id"] ==
               "triage-review-" <> SalixIM.Triage.CanonicalJSON.sha256(canonical_without_id)
    end)
  end

  test "rejects a channel review target with more than six fractional timestamp digits" do
    input = %{
      "source_authority" => %{
        "workspace_id" => "T1",
        "channel_id" => "C1",
        "thread_ts" => "__channel__",
        "scope_kind" => "channel"
      },
      "events" => [
        %{
          "event_id" => "Ev-overprecise",
          "message_ts" => "200.1234567",
          "actor_id" => "U1",
          "text" => "Who owns Atlas?"
        }
      ]
    }

    assert {:error, :invalid_slack_timestamp} =
             ReviewProjection.slack(input, %{
               "action" => "reply",
               "text" => "Lin owns Atlas.",
               "source_refs" => ["meeting://atlas/action-item/0"]
             })
  end
end
