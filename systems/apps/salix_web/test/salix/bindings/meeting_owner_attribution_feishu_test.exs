defmodule Salix.Bindings.MeetingOwnerAttributionFeishuTest do
  use SystemsClock.Case, async: false

  alias Salix.Bindings.{FeishuMeetingOwnerResolver, MeetingOwnerAttribution}
  alias SalixMeet.{Delivery, OwnerAttributionSnapshot, Store}

  defmodule Resolver do
    def resolve(_state, _items) do
      SystemsRuntime.fetch_env!(:salix_web, :meeting_owner_attribution_feishu_test_result)
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
    previous_router_summary = SystemsRuntime.get_env(:salix_meet, :router_summary_mod)
    SystemsRuntime.delete_env(:salix_meet, :router_summary_mod)

    on_exit(fn ->
      if previous_router_summary,
        do: SystemsRuntime.put_env(:salix_meet, :router_summary_mod, previous_router_summary),
        else: SystemsRuntime.delete_env(:salix_meet, :router_summary_mod)
    end)

    previous_resolver =
      SystemsRuntime.get_env(:salix_web, :meeting_feishu_owner_resolver_mod)

    previous_result =
      SystemsRuntime.get_env(:salix_web, :meeting_owner_attribution_feishu_test_result)

    previous_enabled =
      SystemsRuntime.get_env(:salix_meet, :meeting_owner_attribution_enabled)

    previous_attribution =
      SystemsRuntime.get_env(:salix_meet, :owner_attribution_mod)

    previous_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)

    SystemsRuntime.put_env(:salix_web, :meeting_feishu_owner_resolver_mod, Resolver)
    SystemsRuntime.put_env(:salix_meet, :meeting_owner_attribution_enabled, true)
    SystemsRuntime.put_env(:salix_meet, :owner_attribution_mod, MeetingOwnerAttribution)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
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
    SystemsRuntime.put_env(:salix_web, :meeting_owner_attribution_feishu_test_result, {
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

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
