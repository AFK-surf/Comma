defmodule Salix.Bindings.LarkMeetingTest do
  @moduledoc """
  Google Meet meetings and calendar notices for a Lark connect, at the
  bindings: who may ask the Router to join, whose name an action item gets,
  and what a Lark chat is told when a calendar meeting starts.
  """
  use SystemsClock.Case, async: false

  alias Salix.Bindings.{AgentMeeting, MeetingCalendarNotifier, MeetingOwnerAttribution}
  alias Salix.Control
  alias SalixAgent.AgentControl
  alias SalixStore.{CasRecord, Keys}

  defmodule Resolver do
    def resolve(_state, _items),
      do: SystemsRuntime.fetch_env!(:salix_web, :lark_meeting_test_owner_result)
  end

  defmodule RecordingLarkDirectDelivery do
    @moduledoc false
    @behaviour SalixIM.Ports.LarkDirectDelivery

    use Agent

    def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def records, do: Agent.get(__MODULE__, &Enum.reverse/1)

    @impl true
    def post_text(connect, target, text, mentions, operation_ref) do
      record = %{
        "connect_id" => connect["connect_id"],
        "target" => target,
        "text" => text,
        "mentions" => mentions,
        "operation_ref" => operation_ref
      }

      Agent.update(__MODULE__, &[record | &1])
      {:ok, %{"operation_ref" => operation_ref}}
    end

    @impl true
    def post_file(_agent_id, _connect, _target, _path, _blob_ref, _operation_ref),
      do: {:error, :not_expected}
  end

  setup do
    SalixAgent.TestSupport.stop_all_agents()

    previous = %{
      s3: SystemsRuntime.get_env(:salix_store, :s3_backend),
      driver: SystemsRuntime.get_env(:salix_meet, :runtime_driver),
      delivery: SystemsRuntime.get_env(:salix_im, :lark_direct_delivery_mod),
      resolver: SystemsRuntime.get_env(:salix_web, :meeting_lark_owner_resolver_mod),
      attribution: SystemsRuntime.get_env(:salix_meet, :meeting_owner_attribution_enabled)
    }

    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.delete_env(:salix_meet, :runtime_driver)

    if SystemsRuntime.Proc.whereis(SalixStore.S3.Fake),
      do: SalixStore.S3.Fake.reset(),
      else: start_supervised!(SalixStore.S3.Fake)

    assert {:ok, %{"tenant_id" => tenant_id}} =
             Control.create_tenant(%{"name" => "Lark meeting tenant"})

    assert {:ok, %{"group_id" => group_id}} =
             Control.create_group(%{"name" => "Lark meeting group"}, tenant_id)

    assert {:ok, %{"agent_id" => router_id}} =
             AgentControl.create(
               %{"group_id" => group_id, "name" => "Router", "role" => "router"},
               tenant_id
             )

    assert {:ok, _group} =
             Control.update_group(group_id, %{"router_agent_id" => router_id}, tenant_id)

    on_exit(fn ->
      SalixAgent.TestSupport.stop_all_agents()
      restore_env(:salix_store, :s3_backend, previous.s3)
      restore_env(:salix_meet, :runtime_driver, previous.driver)
      restore_env(:salix_im, :lark_direct_delivery_mod, previous.delivery)
      restore_env(:salix_web, :meeting_lark_owner_resolver_mod, previous.resolver)
      restore_env(:salix_meet, :meeting_owner_attribution_enabled, previous.attribution)
      SystemsRuntime.delete_env(:salix_web, :lark_meeting_test_owner_result)
    end)

    {:ok, tenant_id: tenant_id, group_id: group_id, router_id: router_id}
  end

  describe "meeting.join" do
    test "a person's Lark message reaches the Lark meeting provider", ctx do
      connect_id = seed_connect(ctx, "lark-direct-human")
      source_message_id = "im_provider:lark:#{connect_id}:om_direct_human"

      # No meeting runtime is configured here: the refusal comes from the
      # provider, after the source was accepted.
      assert {:error, :meeting_runtime_not_configured} =
               AgentMeeting.join(
                 ctx.group_id,
                 %{},
                 tool_context(ctx, source_message_id, connect_id, "user", "ou_direct_human")
               )
    end

    test "a message an app sent cannot ask the Router to join", ctx do
      connect_id = seed_connect(ctx, "lark-app-direct")
      source_message_id = "im_provider:lark:#{connect_id}:om_app_direct"

      assert {:error, :router_current_human_request_required} =
               AgentMeeting.join(
                 ctx.group_id,
                 %{},
                 tool_context(ctx, source_message_id, connect_id, "app", "cli_untrusted_relay")
               )

      # Nor can a Worker, whatever the source.
      human = tool_context(ctx, source_message_id, connect_id, "user", "ou_direct_human")

      assert {:error, :router_current_human_request_required} =
               AgentMeeting.join(ctx.group_id, %{}, Map.put(human, "role", "worker"))
    end
  end

  describe "action-item owners" do
    test "only an identity the Lark resolver gave is put on an action item" do
      SystemsRuntime.put_env(:salix_web, :meeting_lark_owner_resolver_mod, Resolver)
      SystemsRuntime.put_env(:salix_meet, :meeting_owner_attribution_enabled, true)

      alice = %{"provider" => "lark", "user_id" => "ou_alice", "display_name" => "Alice"}
      SystemsRuntime.put_env(:salix_web, :lark_meeting_test_owner_result, {:ok, %{0 => alice}})

      state = %{
        "provider" => "lark",
        "group_id" => "grp_test",
        "connect_id" => "lark_test",
        "delivery" => %{"attempt_count" => 1}
      }

      summary = %{
        "action_items" => [
          %{"description" => "Ship", "owner" => "Alice"},
          %{"description" => "Review", "owner" => "Bob"}
        ]
      }

      assert {:ok, enriched} =
               MeetingOwnerAttribution.attribute(state, summary, %{"transcript" => ""})

      assert get_in(enriched, ["action_items", Access.at(0), "owner_provider_identity"]) == alice
      refute get_in(enriched, ["action_items", Access.at(1), "owner_provider_identity"])

      # The snapshot keeps the identity as a Lark one, and gives it to nobody else.
      snapshot = SalixMeet.OwnerAttributionSnapshot.build(summary, enriched, completed_at: 1)

      assert SalixMeet.OwnerAttributionSnapshot.provider_identities_for(snapshot, summary, "lark") ==
               %{0 => alice}

      assert SalixMeet.OwnerAttributionSnapshot.provider_identities_for(
               snapshot,
               summary,
               "feishu"
             ) == %{}

      # A Lark failure is retried within the bound, then left unresolved.
      SystemsRuntime.put_env(
        :salix_web,
        :lark_meeting_test_owner_result,
        {:error, {:provider_owner_lookup, :timeout}}
      )

      assert {:error, {:provider_owner_lookup, :timeout}} =
               MeetingOwnerAttribution.attribute(state, summary, %{"transcript" => ""})

      assert :skip =
               MeetingOwnerAttribution.attribute(
                 put_in(state, ["delivery", "attempt_count"], 3),
                 summary,
                 %{"transcript" => ""}
               )
    end
  end

  describe "calendar start notice" do
    test "a Lark chat gets one notice per occurrence, and no Router Conversation", ctx do
      start_supervised!(RecordingLarkDirectDelivery)
      SystemsRuntime.put_env(:salix_im, :lark_direct_delivery_mod, RecordingLarkDirectDelivery)
      connect_id = seed_connect(ctx, "lark-calendar")

      target = %{
        "provider" => "lark",
        "mode" => "notify",
        "tenant_id" => ctx.tenant_id,
        "group_id" => ctx.group_id,
        "connect_id" => connect_id,
        "chat_id" => "oc_calendar",
        "mentions" => %{
          "mode" => "users",
          "users" => [%{"user_id" => "ou_alice", "name" => "Alice"}]
        }
      }

      event = %{
        "event_id" => "evt-calendar-1",
        "title" => "Project sync",
        "start_time" => "2026-07-20T10:00:00+08:00",
        "time_zone" => "Asia/Shanghai",
        "meet_url" => "https://meet.google.com/abc-defg-hij"
      }

      assert {:ok, :queued} = MeetingCalendarNotifier.notify(target, event, "occurrence-1")

      assert [record] = RecordingLarkDirectDelivery.records()
      assert record["connect_id"] == connect_id
      assert record["operation_ref"] == "calendar-notify:occurrence-1"
      assert record["target"] == %{"chat_id" => "oc_calendar", "chat_type" => "group"}
      assert record["mentions"] == target["mentions"]

      assert record["text"] ==
               "📅 Project sync\nTime: 2026-07-20T10:00:00+08:00 (Asia/Shanghai)\n" <>
                 "Google Meet: https://meet.google.com/abc-defg-hij"

      assert SalixIM.RouterConversationProjection.get_group_router_conversation(ctx.group_id) ==
               {:error, :not_found}

      # A target without its chat, or of a connect that is not Lark, sends nothing.
      assert {:error, :calendar_notification_invalid_target} =
               MeetingCalendarNotifier.notify(Map.put(target, "chat_id", ""), event, "o-2")

      assert {:error, _reason} =
               MeetingCalendarNotifier.notify(
                 Map.put(target, "connect_id", "lark-unknown"),
                 event,
                 "o-3"
               )

      assert length(RecordingLarkDirectDelivery.records()) == 1
    end
  end

  defp seed_connect(ctx, connect_id) do
    assert {:ok, _connect} =
             CasRecord.create(Keys.ctl_im_connect(ctx.group_id, connect_id), %{
               "tenant_id" => ctx.tenant_id,
               "group_id" => ctx.group_id,
               "connect_id" => connect_id,
               "provider" => "lark",
               "status" => "connected"
             })

    connect_id
  end

  defp tool_context(ctx, source_message_id, connect_id, sender_type, sender_open_id) do
    %{
      "agent_id" => ctx.router_id,
      "group_id" => ctx.group_id,
      "role" => "router",
      "source_message_id" => source_message_id,
      "trusted_origin" => %{
        "provider" => "lark",
        "agent_group_id" => ctx.group_id,
        "source_actor_type" => "provider_user",
        "source_message_id" => source_message_id,
        "source_text" => "join https://meet.google.com/abc-defg-hij",
        "provider_context" => %{
          "connect_id" => connect_id,
          "chat_id" => "oc_direct",
          "chat_type" => "group",
          "message_id" => "om_direct",
          "sender_type" => sender_type,
          "sender_open_id" => sender_open_id
        }
      }
    }
  end

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
