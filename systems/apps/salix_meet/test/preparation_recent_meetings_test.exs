defmodule SalixMeet.PreparationRecentMeetingsTest do
  use SystemsClock.Case, async: false

  alias SalixMeet.{PreparationRecentMeetings, Store}
  alias SalixStore.{Ids, MeetingGroupProjectionReadiness, MeetingGroupProjections, Repo, S3}

  @start_ms 1_800_000_000_000

  defmodule FailingS3 do
    def get(_key), do: {:error, :unavailable}
    def get(_key, _opts), do: {:error, :unavailable}
  end

  setup do
    start_supervised!(SalixStore.S3.Fake)
    Repo.query!("TRUNCATE meeting_group_projections")
    :ok = MeetingGroupProjections.mark_ready(%{"mode" => "test"})
    :ok = MeetingGroupProjectionReadiness.refresh()

    old_s3 = SystemsRuntime.get_env(:salix_store, :s3_backend)
    SystemsRuntime.put_env(:salix_store, :s3_backend, S3.Fake)

    on_exit(fn ->
      if is_nil(old_s3),
        do: SystemsRuntime.delete_env(:salix_store, :s3_backend),
        else: SystemsRuntime.put_env(:salix_store, :s3_backend, old_s3)

      MeetingGroupProjectionReadiness.refresh()
    end)

    tenant_id = Ids.new_tenant_id()
    group_id = Ids.new_group_id(tenant_id)

    {:ok, tenant_id: tenant_id, group_id: group_id}
  end

  test "lists only completed published Slack meetings in the authorized channel before current start",
       %{tenant_id: tenant_id, group_id: group_id} do
    seed_meeting!("mtg-allhands-prev", %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "connect_id" => "slack-conn-1",
      "title" => "AFK All-Hands Meeting",
      "status" => "done",
      "start_at" => div(@start_ms - :timer.hours(24 * 7), 1_000),
      "slack_ref" => %{"channel_id" => "CNOTICE", "thread_ts" => "1794884285.260109"},
      "delivery" => %{
        "status" => "published",
        "published_at" => div(@start_ms - :timer.hours(24 * 7), 1_000),
        "summary_message_ts" => "1794886185.862139",
        "artifacts" => %{
          "transcript" => %{"file_id" => "F0CJD96FA57"}
        }
      }
    })

    seed_meeting!("mtg-standup-yesterday", %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "connect_id" => "slack-conn-1",
      "title" => "Cue Team's Stand-up Meeting",
      "status" => "done",
      "start_at" => div(@start_ms - :timer.hours(24), 1_000),
      "slack_ref" => %{"channel_id" => "CNOTICE", "thread_ts" => "1795402700.530529"},
      "delivery" => %{
        "status" => "published",
        "published_at" => div(@start_ms - :timer.hours(24), 1_000),
        "summary_message_ts" => "1795404571.756239",
        "artifacts" => %{
          "transcript" => %{"file_id" => "F0CKWDTQPL3"}
        }
      }
    })

    seed_meeting!("mtg-other-channel", %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "connect_id" => "slack-conn-1",
      "title" => "Private 1:1",
      "status" => "done",
      "start_at" => div(@start_ms - :timer.hours(12), 1_000),
      "slack_ref" => %{"channel_id" => "DPRIVATE", "thread_ts" => "1795440000.000001"},
      "delivery" => %{"status" => "published", "published_at" => div(@start_ms, 1_000)}
    })

    seed_meeting!("mtg-unpublished", %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "connect_id" => "slack-conn-1",
      "title" => "In Progress",
      "status" => "active",
      "start_at" => div(@start_ms - :timer.hours(6), 1_000),
      "slack_ref" => %{"channel_id" => "CNOTICE", "thread_ts" => "1795460000.000001"},
      "delivery" => %{}
    })

    seed_meeting!("mtg-future", %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "connect_id" => "slack-conn-1",
      "title" => "Same Occurrence",
      "status" => "done",
      "start_at" => div(@start_ms, 1_000),
      "slack_ref" => %{"channel_id" => "CNOTICE", "thread_ts" => "1795489102.382789"},
      "delivery" => %{"status" => "published", "published_at" => div(@start_ms, 1_000)}
    })

    plan = %{"occurrence_ref" => %{"start_ms" => @start_ms}}

    scope = %{
      group_id: group_id,
      provider: "slack",
      connect_id: "slack-conn-1",
      channel_id: "CNOTICE"
    }

    result = PreparationRecentMeetings.list_for_scope(plan, scope)

    assert result["status"] == "complete"
    assert result["truncated"] == false

    assert Enum.map(result["meetings"], & &1["title"]) == [
             "Cue Team's Stand-up Meeting",
             "AFK All-Hands Meeting"
           ]

    [latest, prior] = result["meetings"]
    assert latest["channel"] == "CNOTICE"
    assert latest["thread_ts"] == "1795402700.530529"
    assert latest["summary_message_ts"] == "1795404571.756239"
    assert latest["transcript_file_id"] == "F0CKWDTQPL3"
    refute Map.has_key?(latest, "summary")

    assert prior["thread_ts"] == "1794884285.260109"
    assert prior["transcript_file_id"] == "F0CJD96FA57"
  end

  test "reports unavailable on object-store failure instead of complete empty", %{
    group_id: group_id
  } do
    :ok = MeetingGroupProjections.ensure(group_id, "mtg-store-down")

    SystemsRuntime.put_env(:salix_store, :s3_backend, FailingS3)

    plan = %{"occurrence_ref" => %{"start_ms" => @start_ms}}

    scope = %{
      group_id: group_id,
      provider: "slack",
      connect_id: "slack-conn-1",
      channel_id: "CNOTICE"
    }

    assert %{
             "status" => "unavailable",
             "reason" => "store_unavailable",
             "truncated" => true,
             "meetings" => []
           } = PreparationRecentMeetings.list_for_scope(plan, scope)
  end

  test "reports partial when matches exceed limit or scan cap hits, and paginates past other channels",
       %{tenant_id: tenant_id, group_id: group_id} do
    seed_meeting!("mtg-target-older", %{
      "tenant_id" => tenant_id,
      "group_id" => group_id,
      "provider" => "slack",
      "connect_id" => "slack-conn-1",
      "title" => "Target Channel Stand-up",
      "status" => "done",
      "start_at" => div(@start_ms - :timer.hours(48), 1_000),
      "slack_ref" => %{"channel_id" => "CTARGET", "thread_ts" => "1795300000.000001"},
      "delivery" => %{
        "status" => "published",
        "published_at" => div(@start_ms - :timer.hours(47), 1_000)
      }
    })

    Repo.query!(
      "UPDATE meeting_group_projections SET inserted_at = now() - interval '2 days' WHERE meeting_id = 'mtg-target-older'"
    )

    for i <- 1..10 do
      id = "mtg-other-#{String.pad_leading(Integer.to_string(i), 2, "0")}"

      seed_meeting!(id, %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => "slack",
        "connect_id" => "slack-conn-1",
        "title" => "Other Channel Sync #{i}",
        "status" => "done",
        "start_at" => div(@start_ms - :timer.hours(i), 1_000),
        "slack_ref" => %{"channel_id" => "COTHER", "thread_ts" => "1795400000.0000#{i}"},
        "delivery" => %{
          "status" => "published",
          "published_at" => div(@start_ms - :timer.hours(i), 1_000)
        }
      })
    end

    plan = %{"occurrence_ref" => %{"start_ms" => @start_ms}}

    target_scope = %{
      group_id: group_id,
      provider: "slack",
      connect_id: "slack-conn-1",
      channel_id: "CTARGET"
    }

    result =
      PreparationRecentMeetings.list_for_scope(plan, target_scope, page_size: 4, max_pages: 4)

    assert result["status"] == "complete"
    assert result["truncated"] == false
    assert [%{"title" => "Target Channel Stand-up"}] = result["meetings"]

    capped =
      PreparationRecentMeetings.list_for_scope(plan, target_scope, page_size: 4, max_pages: 2)

    assert capped["status"] == "partial"
    assert capped["truncated"] == true
    assert capped["meetings"] == []

    # Over-limit matches in one scan must report status: partial + truncated: true
    other_scope = %{target_scope | channel_id: "COTHER"}

    over_limit =
      PreparationRecentMeetings.list_for_scope(plan, other_scope, limit: 3, page_size: 20)

    assert over_limit["status"] == "partial"
    assert over_limit["truncated"] == true
    assert length(over_limit["meetings"]) == 3
  end

  test "halts cleanly when deadline is already exceeded", %{group_id: group_id} do
    plan = %{"occurrence_ref" => %{"start_ms" => @start_ms}}

    scope = %{
      group_id: group_id,
      provider: "slack",
      connect_id: "slack-conn-1",
      channel_id: "CNOTICE"
    }

    expired = SystemsClock.monotonic_time(:millisecond) - 1

    assert %{
             "status" => "unavailable",
             "reason" => "deadline_exceeded",
             "truncated" => true,
             "meetings" => []
           } = PreparationRecentMeetings.list_for_scope(plan, scope, deadline_at: expired)
  end

  test "Feishu and Lark emit omt_ thread_id only when valid and provide message_id + history_window for calendar auto-join",
       %{tenant_id: tenant_id, group_id: group_id} do
    start_s = div(@start_ms - :timer.hours(24), 1_000)

    for {provider, ref_key, chat_id} <- [
          {"feishu", "feishu_ref", "oc_feishu_notice"},
          {"lark", "lark_ref", "oc_lark_notice"}
        ] do
      seed_meeting!("mtg-#{provider}-autojoin", %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => provider,
        "connect_id" => "#{provider}-conn-1",
        "title" => "#{provider} Auto-join Stand-up",
        "status" => "done",
        "start_at" => start_s,
        "end_at" => start_s + 1_800,
        ref_key => %{
          "chat_id" => chat_id,
          "thread_id" => "",
          "root_message_id" => "",
          "trigger_message_id" => "om_trigger_#{provider}"
        },
        "delivery" => %{"status" => "published", "published_at" => start_s + 1_900}
      })

      seed_meeting!("mtg-#{provider}-thread", %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => provider,
        "connect_id" => "#{provider}-conn-1",
        "title" => "#{provider} Thread Review",
        "status" => "done",
        "start_at" => start_s - 3_600,
        ref_key => %{
          "chat_id" => chat_id,
          "thread_id" => "omt_thread_#{provider}",
          "root_message_id" => "om_root_#{provider}"
        },
        "delivery" => %{"status" => "published", "published_at" => start_s - 3_000}
      })

      seed_meeting!("mtg-#{provider}-msg-as-thread", %{
        "tenant_id" => tenant_id,
        "group_id" => group_id,
        "provider" => provider,
        "connect_id" => "#{provider}-conn-1",
        "title" => "#{provider} Root Msg Fallback",
        "status" => "done",
        "start_at" => start_s - 7_200,
        ref_key => %{
          "chat_id" => chat_id,
          "thread_id" => "om_not_a_thread",
          "root_message_id" => "om_not_a_thread"
        },
        "delivery" => %{"status" => "published", "published_at" => start_s - 6_600}
      })

      plan = %{"occurrence_ref" => %{"start_ms" => @start_ms}}

      scope = %{
        group_id: group_id,
        provider: provider,
        connect_id: "#{provider}-conn-1",
        channel_id: chat_id
      }

      %{"status" => "complete", "meetings" => [autojoin, threaded, msg_fallback]} =
        PreparationRecentMeetings.list_for_scope(plan, scope)

      assert autojoin["title"] == "#{provider} Auto-join Stand-up"
      assert autojoin["message_id"] == "om_trigger_#{provider}"
      refute Map.has_key?(autojoin, "thread_id")
      assert %{"start_time" => _, "end_time" => _} = autojoin["history_window"]

      assert threaded["title"] == "#{provider} Thread Review"
      assert threaded["thread_id"] == "omt_thread_#{provider}"
      refute Map.has_key?(threaded, "history_window")

      assert msg_fallback["title"] == "#{provider} Root Msg Fallback"
      assert msg_fallback["message_id"] == "om_not_a_thread"
      refute Map.has_key?(msg_fallback, "thread_id")
      assert %{"start_time" => _, "end_time" => _} = msg_fallback["history_window"]
    end
  end

  test "returns unavailable when projection is unsealed", %{group_id: group_id} do
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'meeting_group_projection_v1'")
    :ok = MeetingGroupProjectionReadiness.refresh()

    plan = %{"occurrence_ref" => %{"start_ms" => @start_ms}}

    scope = %{
      group_id: group_id,
      provider: "slack",
      connect_id: "slack-conn-1",
      channel_id: "CNOTICE"
    }

    assert %{
             "status" => "unavailable",
             "reason" => "projection_not_ready",
             "truncated" => true,
             "meetings" => []
           } = PreparationRecentMeetings.list_for_scope(plan, scope)
  end

  defp seed_meeting!(meeting_id, state) do
    assert {:ok, _doc, _etag} = Store.create_once(meeting_id, state: state, now: @start_ms)
  end
end
