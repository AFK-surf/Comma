defmodule SalixMeet.OwnerAttributionSnapshotTest do
  use SystemsClock.Case, async: true

  alias SalixMeet.OwnerAttributionSnapshot, as: Snapshot

  test "build copies only same-index valid resolved ids" do
    summary = %{
      "title" => "Weekly Sync",
      "action_items" => [
        %{"description" => "Ship", "owner" => "Alice"},
        %{"description" => "Review", "owner" => "Bob"}
      ]
    }

    enriched = %{
      "title" => "Weekly Sync",
      "action_items" => [
        %{"description" => "Ship", "owner" => "Alice", "owner_slack_id" => "U123"},
        %{"description" => "Review", "owner" => "Bob", "owner_slack_id" => "invalid"}
      ]
    }

    snapshot = Snapshot.build(summary, enriched, completed_at: 123)

    assert snapshot == %{
             "version" => 2,
             "status" => "complete",
             "summary" => summary,
             "summary_fingerprint" => Snapshot.fingerprint(summary),
             "items" => %{
               "0" => %{
                 "item_fingerprint" =>
                   Snapshot.fingerprint(%{"description" => "Ship", "owner" => "Alice"}),
                 "provider" => "slack",
                 "user_id" => "U123",
                 "display_name" => ""
               }
             },
             "outcome" => "resolved",
             "completed_at" => 123
           }

    assert Snapshot.complete?(snapshot)
    assert Snapshot.bound_summary(snapshot, %{"title" => "late runtime update"}) == summary
    assert Snapshot.slack_ids_for(snapshot, summary) == %{0 => "U123"}
    assert Snapshot.slack_id_for(snapshot, summary, 0, hd(summary["action_items"])) == "U123"
    assert Snapshot.slack_id_for(snapshot, summary, 1, Enum.at(summary["action_items"], 1)) == nil
  end

  test "build stores a validated Feishu identity and rejects forged source fields" do
    item = %{"description" => "Ship", "owner" => "Alice"}
    summary = %{"action_items" => [item]}

    enriched =
      put_in(summary, ["action_items", Access.at(0), "owner_provider_identity"], %{
        "provider" => "feishu",
        "user_id" => "ou_alice",
        "display_name" => "Alice"
      })

    snapshot = Snapshot.build(summary, enriched, completed_at: 9)

    assert Snapshot.provider_identities_for(snapshot, summary, "feishu") == %{
             0 => %{
               "provider" => "feishu",
               "user_id" => "ou_alice",
               "display_name" => "Alice"
             }
           }

    forged =
      put_in(summary, ["action_items", Access.at(0), "owner_provider_identity"], %{
        "provider" => "feishu",
        "user_id" => "ou_victim",
        "display_name" => "Victim"
      })

    assert Snapshot.build(forged, forged, completed_at: 10)["items"] == %{}
  end

  test "changed or reordered action items cannot reuse an attribution" do
    first = %{"description" => "Ship", "owner" => "Alice"}
    second = %{"description" => "Review", "owner" => "Bob"}
    summary = %{"title" => "Sync", "action_items" => [first, second]}

    enriched = %{
      "title" => "Sync",
      "action_items" => [Map.put(first, "owner_slack_id", "U1"), second]
    }

    snapshot = Snapshot.build(summary, enriched, completed_at: 1)

    changed = %{
      "title" => "Sync",
      "action_items" => [%{"description" => "Ship now", "owner" => "Alice"}, second]
    }

    reordered = %{"title" => "Sync", "action_items" => [second, first]}

    assert Snapshot.slack_id_for(snapshot, changed, 0, hd(changed["action_items"])) == nil
    assert Snapshot.slack_ids_for(snapshot, changed) == %{}

    assert Snapshot.slack_id_for(snapshot, reordered, 1, Enum.at(reordered["action_items"], 1)) ==
             nil

    reordered_enriched = %{
      "title" => "Sync",
      "action_items" => [second, Map.put(first, "owner_slack_id", "U1")]
    }

    assert Snapshot.build(summary, reordered_enriched, completed_at: 2)["items"] == %{}
  end
end
