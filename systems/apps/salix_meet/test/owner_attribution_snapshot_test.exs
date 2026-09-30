defmodule SalixMeet.OwnerAttributionSnapshotTest do
  use ExUnit.Case, async: true

  alias SalixMeet.OwnerAttributionSnapshot, as: Snapshot

  test "sanitizes reserved string and atom keys recursively" do
    summary = %{
      :owner_attribution_done => true,
      :title => :sync,
      "action_items" => [
        %{
          :owner_slack_id => "UFORGED",
          "owner" => "Alice",
          "nested" => %{"owner_attribution_done" => true, :owner_slack_id => "UOTHER"}
        }
      ],
      "owner_slack_id" => "UTOP"
    }

    assert Snapshot.sanitize_summary(summary) == %{
             "title" => "sync",
             "action_items" => [
               %{"owner" => "Alice", "nested" => %{}}
             ]
           }
  end

  test "fingerprint is stable across map construction and key order" do
    left = %{
      "z" => [%{"b" => 2, "a" => 1}],
      "a" => %{"second" => false, "first" => nil}
    }

    right =
      [
        {"a", Map.new([{"first", nil}, {"second", false}])},
        {"z", [Map.new([{"a", 1}, {"b", 2}])]}
      ]
      |> Map.new()

    assert Snapshot.fingerprint(left) == Snapshot.fingerprint(right)
    assert Snapshot.fingerprint(left) =~ ~r/\Asha256:[0-9a-f]{64}\z/
  end

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

  test "legacy Slack snapshots remain valid during rolling deployment" do
    item = %{"description" => "Ship", "owner" => "Alice"}
    summary = %{"action_items" => [item]}

    legacy = %{
      "version" => 1,
      "status" => "complete",
      "summary" => summary,
      "summary_fingerprint" => Snapshot.fingerprint(summary),
      "items" => %{
        "0" => %{"item_fingerprint" => Snapshot.fingerprint(item), "slack_id" => "U123"}
      },
      "outcome" => "resolved",
      "completed_at" => 1
    }

    assert Snapshot.complete?(legacy)
    assert Snapshot.slack_ids_for(legacy, summary) == %{0 => "U123"}

    assert {:ok, upgraded} =
             Snapshot.fetch_from_delivery(%{"owner_attribution" => legacy})

    assert upgraded["version"] == 2
    assert Snapshot.slack_ids_for(upgraded, summary) == %{0 => "U123"}
  end

  test "v2 writes keep a complete v1 mirror and new readers prefer immutable v2" do
    item = %{"description" => "Ship", "owner" => "Alice"}
    summary = %{"action_items" => [item]}
    v2 = Snapshot.build(summary, %{"action_items" => [Map.put(item, "owner_slack_id", "U1")]})

    delivery = Snapshot.put_in_delivery(%{}, v2)
    legacy = delivery["owner_attribution"]

    assert Snapshot.complete?(legacy)
    assert legacy["version"] == 1
    assert legacy["items"]["0"]["slack_id"] == "U1"
    assert Snapshot.rolling_storage_complete?(delivery)
    assert {:ok, ^v2} = Snapshot.fetch_from_delivery(delivery)

    # A legacy pod recognizes the mirror and therefore preserves U1 during a
    # reclaim instead of replacing it with a fresh U2 attribution.
    legacy_candidate =
      legacy
      |> put_in(["items", "0", "slack_id"], "U2")

    delivery_after_legacy_reclaim =
      if Snapshot.complete?(legacy),
        do: delivery,
        else: Map.put(delivery, "owner_attribution", legacy_candidate)

    assert {:ok, ^v2} = Snapshot.fetch_from_delivery(delivery_after_legacy_reclaim)
  end

  test "Feishu v2 keeps an unresolved legacy mirror and unsupported future versions are fenced" do
    item = %{"description" => "Ship", "owner" => "Alice"}
    summary = %{"action_items" => [item]}

    enriched =
      put_in(summary, ["action_items", Access.at(0), "owner_provider_identity"], %{
        "provider" => "feishu",
        "user_id" => "ou_alice",
        "display_name" => "Alice"
      })

    v2 = Snapshot.build(summary, enriched, completed_at: 10)
    delivery = Snapshot.put_in_delivery(%{}, v2)

    assert delivery["owner_attribution"]["version"] == 1
    assert delivery["owner_attribution"]["items"] == %{}
    assert delivery["owner_attribution"]["outcome"] == "unresolved"
    assert {:ok, ^v2} = Snapshot.fetch_from_delivery(delivery)

    assert {:error, {:unsupported_owner_attribution_version, 3}} =
             Snapshot.fetch_from_delivery(%{
               "owner_attribution_v2" => Map.put(v2, "version", 3),
               "owner_attribution" => delivery["owner_attribution"]
             })
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

  test "a full-summary change invalidates an otherwise unchanged item" do
    item = %{"description" => "Ship", "owner" => "Alice"}
    summary = %{"title" => "Sync", "action_items" => [item]}
    enriched = put_in(summary, ["action_items", Access.at(0), "owner_slack_id"], "W123")
    snapshot = Snapshot.build(summary, enriched, completed_at: 1)
    changed = Map.put(summary, "title", "Different meeting")

    assert Snapshot.slack_id_for(snapshot, changed, 0, item) == nil
  end

  test "invalid ids produce a completed unresolved snapshot" do
    item = %{"description" => "Ship", "owner" => "Alice"}
    summary = %{"action_items" => [item]}

    for invalid <- ["", "U1><@U2", "B123", "u123", 123, nil] do
      enriched = %{"action_items" => [Map.put(item, "owner_slack_id", invalid)]}
      snapshot = Snapshot.build(summary, enriched, completed_at: 1)

      assert snapshot["items"] == %{}
      assert snapshot["outcome"] == "unresolved"
      assert Snapshot.complete?(snapshot)
      assert Snapshot.slack_id_for(snapshot, summary, 0, item) == nil
    end
  end

  test "an id already present in runtime-owned source data is never promoted" do
    forged = %{
      "owner_attribution_done" => true,
      "action_items" => [
        %{"description" => "Ship", "owner" => "Alice", "owner_slack_id" => "UFORGED"}
      ]
    }

    snapshot = Snapshot.build(forged, forged, completed_at: 1)

    assert snapshot["items"] == %{}
    assert snapshot["outcome"] == "unresolved"
  end

  test "complete? rejects unsupported or malformed envelopes" do
    refute Snapshot.complete?(nil)
    refute Snapshot.complete?(%{"version" => 2, "status" => "complete", "items" => %{}})

    refute Snapshot.complete?(%{
             "version" => 1,
             "status" => "complete",
             "summary_fingerprint" => "sha256:not-a-digest",
             "items" => %{}
           })

    summary = %{"action_items" => [%{"description" => "Ship", "owner" => "Alice"}]}
    snapshot = Snapshot.build(summary, summary, completed_at: 1)
    refute Snapshot.complete?(put_in(snapshot, ["summary", "title"], "tampered"))
  end
end
