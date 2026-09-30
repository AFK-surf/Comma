defmodule Salix.Bindings.MeetingOwnerAttributionFeishuTest do
  use ExUnit.Case, async: false

  alias Salix.Bindings.{FeishuMeetingOwnerResolver, MeetingOwnerAttribution}
  alias SalixMeet.{Delivery, OwnerAttributionSnapshot, Store}

  defmodule Resolver do
    def resolve(_state, _items) do
      Application.fetch_env!(:salix_web, :meeting_owner_attribution_feishu_test_result)
    end
  end

  defmodule RaisingResolver do
    def resolve(state, items) do
      FeishuMeetingOwnerResolver.resolve(state, items,
        connect: %{"bot_open_id" => "ou_bot"},
        fetch_page: fn _token -> raise "provider crashed" end
      )
    end
  end

  defmodule BlankBotResolver do
    def resolve_with_roster(state, items) do
      Salix.Bindings.FeishuMeetingOwnerResolver.resolve_with_roster(state, items,
        connect: %{"bot_open_id" => ""},
        fetch_page: fn _token -> raise "roster must not be read without a verified bot id" end
      )
    end
  end

  setup do
    # These fixtures exercise the retained synchronous adapter / downstream
    # publication contract. Router-owned generation has dedicated integration tests.
    previous_router_summary = Application.get_env(:salix_meet, :router_summary_mod)
    Application.delete_env(:salix_meet, :router_summary_mod)

    on_exit(fn ->
      if previous_router_summary,
        do: Application.put_env(:salix_meet, :router_summary_mod, previous_router_summary),
        else: Application.delete_env(:salix_meet, :router_summary_mod)
    end)

    previous_resolver =
      Application.get_env(:salix_web, :meeting_feishu_owner_resolver_mod)

    previous_result =
      Application.get_env(:salix_web, :meeting_owner_attribution_feishu_test_result)

    previous_enabled =
      Application.get_env(:salix_meet, :meeting_owner_attribution_enabled)

    previous_attribution =
      Application.get_env(:salix_meet, :owner_attribution_mod)

    previous_s3 = Application.get_env(:salix_store, :s3_backend)

    Application.put_env(:salix_web, :meeting_feishu_owner_resolver_mod, Resolver)
    Application.put_env(:salix_meet, :meeting_owner_attribution_enabled, true)
    Application.put_env(:salix_meet, :owner_attribution_mod, MeetingOwnerAttribution)
    Application.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    start_supervised!(SalixStore.S3.Fake)
    SalixStore.S3.Fake.reset()

    on_exit(fn ->
      restore_env(
        :salix_web,
        :meeting_feishu_owner_resolver_mod,
        previous_resolver
      )

      restore_env(
        :salix_web,
        :meeting_owner_attribution_feishu_test_result,
        previous_result
      )

      restore_env(:salix_meet, :meeting_owner_attribution_enabled, previous_enabled)
      restore_env(:salix_meet, :owner_attribution_mod, previous_attribution)
      restore_env(:salix_store, :s3_backend, previous_s3)
    end)

    :ok
  end

  test "copies only resolver-owned Feishu identities into the enriched summary" do
    Application.put_env(:salix_web, :meeting_owner_attribution_feishu_test_result, {
      :ok,
      %{
        0 => %{
          "provider" => "feishu",
          "user_id" => "ou_alice",
          "display_name" => "Alice"
        }
      }
    })

    assert {:ok, enriched} =
             MeetingOwnerAttribution.attribute(state(1), summary(), %{"transcript" => ""})

    assert get_in(enriched, ["action_items", Access.at(0), "owner_provider_identity"]) == %{
             "provider" => "feishu",
             "user_id" => "ou_alice",
             "display_name" => "Alice"
           }

    refute get_in(enriched, ["action_items", Access.at(1), "owner_provider_identity"])
  end

  test "retries provider failures twice then completes unresolved on the third delivery attempt" do
    Application.put_env(
      :salix_web,
      :meeting_owner_attribution_feishu_test_result,
      {:error, {:provider_owner_lookup, :temporary}}
    )

    assert {:error, {:provider_owner_lookup, :temporary}} =
             MeetingOwnerAttribution.attribute(state(1), summary(), %{"transcript" => ""})

    assert :skip =
             MeetingOwnerAttribution.attribute(state(3), summary(), %{"transcript" => ""})
  end

  test "a raising roster lookup survives delivery and becomes unresolved on attempt three" do
    Application.put_env(:salix_web, :meeting_feishu_owner_resolver_mod, RaisingResolver)

    meeting_id = "mtg-feishu-owner-crash-#{System.unique_integer([:positive])}"

    initial_state =
      state(0)
      |> Map.merge(%{
        "meeting_id" => meeting_id,
        "status" => "done",
        "summary" => summary(),
        "feishu_ref" => %{"chat_type" => "group", "chat_id" => "oc_test"}
      })

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: initial_state)

    for attempt <- 1..3 do
      assert {:ok, doc, _etag, claim} =
               Store.claim_delivery(meeting_id, "owner-crash-#{attempt}", now: attempt * 1_000)

      claimed_state = doc["state"]
      assert get_in(claimed_state, ["delivery", "attempt_count"]) == attempt

      if attempt < 3 do
        assert {:error, {:provider_owner_lookup, {:lookup_crash, {:exception, RuntimeError}}}} =
                 Delivery.prepare_summary_for_delivery(meeting_id, claimed_state, claim)

        assert {:ok, _failed, _etag} =
                 Store.fail_delivery_retrying(meeting_id, claim, "lookup crash",
                   now: attempt * 1_000 + 1
                 )
      else
        assert {:ok, prepared} =
                 Delivery.prepare_summary_for_delivery(meeting_id, claimed_state, claim)

        assert prepared == summary()
      end
    end

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    snapshot = get_in(persisted, ["state", "delivery", "owner_attribution_v2"])
    assert snapshot["status"] == "complete"
    assert snapshot["outcome"] == "unresolved"
    assert snapshot["items"] == %{}
  end

  test "blank group bot identity cannot enter the publication snapshot or activation allowlist" do
    Application.put_env(:salix_web, :meeting_feishu_owner_resolver_mod, BlankBotResolver)

    meeting_id = "mtg-feishu-blank-bot-#{System.unique_integer([:positive])}"

    initial_state =
      state(0)
      |> Map.merge(%{
        "meeting_id" => meeting_id,
        "status" => "done",
        "summary" => summary(),
        "feishu_ref" => %{"chat_type" => "group", "chat_id" => "oc_test"}
      })

    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: initial_state)

    assert {:ok, doc, _etag, claim} =
             Store.claim_delivery(meeting_id, "blank-bot-worker", now: 1_000)

    assert {:ok, prepared} =
             Delivery.prepare_summary_for_delivery(meeting_id, doc["state"], claim)

    refute Enum.any?(prepared["action_items"], &Map.has_key?(&1, "owner_provider_identity"))

    assert {:ok, persisted, _etag} = Store.get(meeting_id)
    snapshot = OwnerAttributionSnapshot.current(persisted["state"])

    assert OwnerAttributionSnapshot.complete?(snapshot)
    assert snapshot["items"] == %{}
    assert OwnerAttributionSnapshot.provider_identities_for(snapshot, prepared, "feishu") == %{}
  end

  defp state(attempt_count) do
    %{
      "provider" => "feishu",
      "group_id" => "grp_test",
      "connect_id" => "feishu_test",
      "delivery" => %{"attempt_count" => attempt_count}
    }
  end

  defp summary do
    %{
      "action_items" => [
        %{"description" => "Ship", "owner" => "Alice"},
        %{"description" => "Review", "owner" => "Bob"}
      ]
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
