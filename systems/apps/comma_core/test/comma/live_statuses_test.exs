defmodule Comma.LiveStatusesTest.Salix do
  def resolve_workspace_scope(workspace), do: {:ok, workspace}
end

defmodule Comma.LiveStatusesTest do
  use SystemsClock.Case, async: false
  use SystemsClock.Test, scope: ["Elixir.Comma"], epoch: ~U[2026-11-20 12:00:00Z]

  import Ecto.Query

  alias Comma.{Accounts, LiveStatuses, Repo}
  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.LiveStatuses.{Status, Target}
  alias Comma.Notifications.APNs
  alias SalixStore.Ids

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)

    prior_apns = SystemsRuntime.get_env(:comma_core, :apns)
    prior_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    {_, pem} = JOSE.JWK.to_pem(JOSE.JWK.generate_key({:ec, "P-256"}))
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      headers = Map.new(conn.req_headers)
      send(test_pid, {:apns_request, conn.request_path, headers, decoded})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
    end

    SystemsRuntime.put_env(:comma_core, :apns,
      plug: plug,
      profiles: %{
        "production" => [
          team_id: "TESTTEAM",
          key_id: "TESTKEY",
          private_key: pem,
          allowed_bundle_ids: ["surf.comma.ios"]
        ]
      }
    )

    SystemsRuntime.put_env(:comma_core, :salix_client, __MODULE__.Salix)

    unless SystemsRuntime.Proc.whereis(APNs.ProviderToken),
      do: start_supervised!(APNs.ProviderToken)

    on_exit(fn ->
      SystemsRuntime.put_env(:comma_core, :apns, prior_apns)
      SystemsRuntime.put_env(:comma_core, :salix_client, prior_client)
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "live-status-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    {:ok, session} =
      Accounts.create_session(user["id"], client_kind: "ios", client_platform: "ios")

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_live_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "live-status-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "live-status-test",
        name: "Live Status Workspace",
        status: "active"
      })

    Repo.insert!(%WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user["id"],
      role: "owner",
      status: "active"
    })

    %{user: user, session: session, workspace: workspace, group_id: group}
  end

  test "enforces max 5 active live statuses per group and allows updating existing keys", ctx do
    for idx <- 1..5 do
      assert {:ok, item} =
               LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
                 "key" => "item-#{idx}",
                 "category" => "progress",
                 "title" => "Task #{idx}"
               })

      assert item["key"] == "item-#{idx}"
    end

    assert {:error, :live_activity_limit_reached} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "item-6",
               "category" => "progress",
               "title" => "Overflow"
             })

    # Updating an existing active key succeeds
    assert {:ok, updated} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "item-1",
               "category" => "progress",
               "title" => "Task 1 Updated",
               "progress" => 0.5
             })

    assert updated["title"] == "Task 1 Updated"
    assert updated["progress"] == 0.5
    assert length(LiveStatuses.list_active(ctx.group_id)) == 5

    # Ending one frees a slot
    assert {:ok, ended} =
             LiveStatuses.end_status(ctx.group_id, %{
               "key" => "item-5",
               "outcome" => "done",
               "title" => "Task 5 Done"
             })

    assert ended["status"] == "done"

    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "item-6",
               "category" => "timer",
               "title" => "Now fits"
             })
  end

  test "push-to-start, live_activity update, alert dedup, and end delivery", ctx do
    eta = DateTime.add(SystemsClock.utc_now(), 600, :second)

    assert {:ok, _} =
             LiveStatuses.upsert(
               ctx.workspace.id,
               ctx.group_id,
               %{
                 "key" => "ride:didi-8821",
                 "category" => "car",
                 "title" => "司机正赶来",
                 "subtitle" => "京A·88888 白色 Model Y",
                 "compact_label" => "3分",
                 "eta_at" => DateTime.to_iso8601(eta),
                 "step" => %{"current" => 1, "total" => 3, "label" => "接驾中"},
                 "detail_left" => "京A·88888",
                 "detail_right" => "张师傅",
                 "alert" => %{"title" => "已接单", "body" => "张师傅正在赶来"}
               },
               conversation_id: "cnv_ride_1"
             )

    pts_token = String.duplicate("a", 64)

    assert {:ok, %{"id" => pts_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "push_to_start", %{
               "token" => pts_token,
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "zh-Hans",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_schema" => "live_status_v1"
             })

    assert :delivered = LiveStatuses.deliver(pts_id, "ride:didi-8821")

    assert_received {:apns_request, "/3/device/" <> ^pts_token, headers, payload}
    assert headers["apns-topic"] == "surf.comma.ios.push-type.liveactivity"
    assert headers["apns-push-type"] == "liveactivity"
    assert headers["apns-priority"] == "10"

    aps = payload["aps"]
    assert aps["event"] == "start"
    assert aps["attributes-type"] == "LiveStatusAttributes"
    assert aps["input-push-token"] == 1
    assert aps["attributes"]["accountID"] == ctx.user["id"]
    assert aps["attributes"]["workspaceID"] == ctx.workspace.id
    assert aps["attributes"]["groupID"] == ctx.group_id
    assert aps["attributes"]["liveKey"] == "ride:didi-8821"
    assert aps["attributes"]["conversationID"] == "cnv_ride_1"
    assert is_integer(aps["attributes"]["startedAtEpochSeconds"])
    assert aps["content-state"]["category"] == "car"
    assert aps["content-state"]["title"] == "司机正赶来"
    assert aps["content-state"]["compactLabel"] == "3分"
    assert aps["content-state"]["stepCurrent"] == 1
    assert aps["content-state"]["stepTotal"] == 3
    assert aps["alert"] == %{"title" => "已接单", "body" => "张师傅正在赶来"}
    assert is_float(aps["relevance-score"])
    assert aps["relevance-score"] > 80.0 and aps["relevance-score"] < 85.0

    # Pending start prevents duplicate push-to-start for the same active instance
    assert :current = LiveStatuses.deliver(pts_id, "ride:didi-8821")
    refute_received {:apns_request, _, _, _}

    # Register live_activity update token; acknowledges pending_starts and seeds tracking from push-to-start
    la_token = String.duplicate("b", 64)

    assert {:ok, %{"id" => la_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "live_activity", %{
               "token" => la_token,
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "zh-Hans",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_id" => "act-ride-1",
               "live_key" => "ride:didi-8821",
               "activity_schema" => "live_status_v1"
             })

    assert Repo.get!(Target, pts_id).pending_starts == %{}

    # Unchanged since push-to-start -> no redundant APNs update
    assert :current = LiveStatuses.deliver(la_id, "ride:didi-8821")
    refute_received {:apns_request, _, _, _}

    # Update with new alert triggers priority 10 with alert once clock advances past start second
    SystemsClock.advance(1_000)

    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "ride:didi-8821",
               "category" => "car",
               "status" => "attention",
               "title" => "司机已到达上车点",
               "alert" => %{"title" => "司机已到达", "body" => "京A·88888 在北门等候"}
             })

    assert :delivered = LiveStatuses.deliver(la_id, "ride:didi-8821")
    assert_received {:apns_request, "/3/device/" <> ^la_token, alert_headers, alert_payload}
    assert alert_headers["apns-priority"] == "10"
    assert alert_payload["aps"]["timestamp"] > aps["timestamp"]
    assert alert_payload["aps"]["relevance-score"] == 90.0
    assert alert_payload["aps"]["alert"] == %{"title" => "司机已到达", "body" => "京A·88888 在北门等候"}

    # Ending sends event=end with dismissal-date and removes live_activity target
    SystemsClock.advance(1_000)

    assert {:ok, _} =
             LiveStatuses.end_status(ctx.group_id, %{
               "key" => "ride:didi-8821",
               "outcome" => "done",
               "title" => "已到达目的地",
               "dismiss_after_seconds" => 20
             })

    assert :delivered = LiveStatuses.deliver(la_id, "ride:didi-8821")
    assert_received {:apns_request, "/3/device/" <> ^la_token, _end_headers, end_payload}
    assert end_payload["aps"]["event"] == "end"
    assert end_payload["aps"]["relevance-score"] == 10.0
    assert end_payload["aps"]["timestamp"] > alert_payload["aps"]["timestamp"]
    assert end_payload["aps"]["dismissal-date"] == end_payload["aps"]["timestamp"] + 20
    assert end_payload["aps"]["content-state"]["status"] == "done"
    assert Repo.get(Target, la_id) == nil
  end

  test "enforces strict APNs timestamp monotonicity with worker snooze and skips redundant post-start update",
       ctx do
    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "delivery:meituan-99",
               "category" => "delivery",
               "title" => "骑手已取餐"
             })

    pts_token = String.duplicate("1", 64)

    assert {:ok, %{"id" => pts_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "push_to_start", %{
               "token" => pts_token,
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "zh-Hans",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_schema" => "live_status_v1"
             })

    assert :delivered = LiveStatuses.deliver(pts_id, "delivery:meituan-99")
    assert_received {:apns_request, "/3/device/" <> ^pts_token, _, start_payload}
    start_ts = start_payload["aps"]["timestamp"]

    la_token = String.duplicate("2", 64)

    assert {:ok, %{"id" => la_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "live_activity", %{
               "token" => la_token,
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "zh-Hans",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_id" => "act-delivery-99",
               "live_key" => "delivery:meituan-99",
               "activity_schema" => "live_status_v1"
             })

    # No change since push-to-start -> :current, no redundant APNs push
    assert :current = LiveStatuses.deliver(la_id, "delivery:meituan-99")
    refute_received {:apns_request, _, _, _}

    # Change in the same second -> :activity_update_busy, worker snoozes 1s
    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "delivery:meituan-99",
               "category" => "delivery",
               "title" => "距您 300 米"
             })

    assert {:error, :activity_update_busy} = LiveStatuses.deliver(la_id, "delivery:meituan-99")

    assert {:snooze, 1} =
             Comma.Workers.LiveStatusPush.perform(%Oban.Job{
               args: %{"target_id" => la_id, "live_key" => "delivery:meituan-99"}
             })

    refute_received {:apns_request, _, _, _}

    # Advancing 1s allows delivery with strictly greater timestamp
    SystemsClock.advance(1_000)

    assert :ok =
             Comma.Workers.LiveStatusPush.perform(%Oban.Job{
               args: %{"target_id" => la_id, "live_key" => "delivery:meituan-99"}
             })

    assert_received {:apns_request, "/3/device/" <> ^la_token, upd_headers, upd_payload}
    assert upd_headers["apns-priority"] == "5"
    assert upd_payload["aps"]["event"] == "update"
    assert upd_payload["aps"]["timestamp"] == start_ts + 1
    refute Map.has_key?(upd_payload["aps"], "alert")

    # Same-second end also snoozes until timestamp strictly advances
    assert {:ok, _} =
             LiveStatuses.end_status(ctx.group_id, %{
               "key" => "delivery:meituan-99",
               "outcome" => "done",
               "title" => "已送达"
             })

    assert {:error, :activity_update_busy} = LiveStatuses.deliver(la_id, "delivery:meituan-99")
    SystemsClock.advance(1_000)
    assert :delivered = LiveStatuses.deliver(la_id, "delivery:meituan-99")
    assert_received {:apns_request, "/3/device/" <> ^la_token, _, end_payload}
    assert end_payload["aps"]["event"] == "end"
    assert end_payload["aps"]["timestamp"] == start_ts + 2
  end

  test "dismissal suppresses current instance but allows restart after end", ctx do
    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "order:luckin-1",
               "category" => "order",
               "title" => "制作中"
             })

    assert {:ok, %{"id" => pts_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "push_to_start", %{
               "token" => String.duplicate("c", 64),
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "en-US",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_schema" => "live_status_v1"
             })

    assert {:ok, %{"id" => la_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "live_activity", %{
               "token" => String.duplicate("d", 64),
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "en-US",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_id" => "act-order-1",
               "live_key" => "order:luckin-1",
               "activity_schema" => "live_status_v1"
             })

    assert :ok = LiveStatuses.unregister(ctx.session, la_id, "dismissed")
    assert Repo.get(Target, la_id) == nil

    # Same active instance stays suppressed
    assert :current = LiveStatuses.deliver(pts_id, "order:luckin-1")
    refute_received {:apns_request, _, _, _}

    # End and restart with a newer started_at clears suppression
    assert {:ok, _} = LiveStatuses.end_status(ctx.group_id, %{"key" => "order:luckin-1"})
    SystemsClock.advance(5_000)

    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "order:luckin-1",
               "category" => "order",
               "title" => "新订单制作中"
             })

    assert :delivered = LiveStatuses.deliver(pts_id, "order:luckin-1")
    assert_received {:apns_request, _, _, %{"aps" => %{"event" => "start"}}}
  end

  test "expiry ends active target and revoked session removes target without APNs send", ctx do
    assert {:ok, _} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "timer:pomodoro",
               "category" => "timer",
               "title" => "Focus",
               "ttl_minutes" => 5
             })

    assert {:ok, %{"id" => la_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "live_activity", %{
               "token" => String.duplicate("e", 64),
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "en-US",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_id" => "act-timer-1",
               "live_key" => "timer:pomodoro",
               "activity_schema" => "live_status_v1"
             })

    SystemsClock.advance(6 * 60 * 1_000)
    assert LiveStatuses.list_active(ctx.group_id) == []
    assert :delivered = LiveStatuses.deliver(la_id, "timer:pomodoro")
    assert_received {:apns_request, _, _, %{"aps" => %{"event" => "end"}}}
    assert Repo.get(Target, la_id) == nil

    # Revoked session removes target without sending APNs
    assert {:ok, %{"id" => pts_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "push_to_start", %{
               "token" => String.duplicate("f", 64),
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "en-US",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_schema" => "live_status_v1"
             })

    assert :ok = Accounts.revoke_session_token(ctx.session["token"])
    assert :obsolete = LiveStatuses.deliver(pts_id, nil)
    refute_received {:apns_request, _, _, _}
    assert Repo.get(Target, pts_id) == nil
    assert Repo.aggregate(from(s in Status, where: s.group_id == ^ctx.group_id), :count) == 1
  end

  test "schedules expiry fanout Oban job, sends APNs end on expiry, clears pending_starts, and prunes old rows",
       ctx do
    assert {:ok, item} =
             LiveStatuses.upsert(ctx.workspace.id, ctx.group_id, %{
               "key" => "timer:ttl-auto-end",
               "category" => "timer",
               "title" => "Laundry",
               "ttl_minutes" => 5
             })

    expires_unix = item["expires_epoch_seconds"]
    assert is_integer(item["started_at_epoch_seconds"])
    assert is_nil(item["dismiss_at_epoch_seconds"])

    # Verify scheduled expiry Oban job if Comma.Oban is running in test env
    if Oban.whereis(Comma.Oban) do
      expiry_job =
        Repo.one(
          from(j in Oban.Job,
            where:
              j.worker == "Comma.Workers.LiveStatusPushFanout" and
                fragment("?->>'group_id' = ?", j.args, ^ctx.group_id) and
                fragment("?->>'live_key' = ?", j.args, "timer:ttl-auto-end") and
                fragment("(?->>'expires_at_unix')::bigint = ?", j.args, ^expires_unix),
            order_by: [desc: j.id],
            limit: 1
          )
        )

      assert expiry_job != nil
      assert DateTime.to_unix(expiry_job.scheduled_at) == expires_unix
    end

    pts_token = String.duplicate("7", 64)
    la_token = String.duplicate("8", 64)

    assert {:ok, %{"id" => pts_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "push_to_start", %{
               "token" => pts_token,
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "en-US",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_schema" => "live_status_v1"
             })

    assert :delivered = LiveStatuses.deliver(pts_id, nil)

    assert_received {:apns_request, "/3/device/" <> ^pts_token, _,
                     %{"aps" => %{"event" => "start"}}}

    assert Map.has_key?(Repo.get!(Target, pts_id).pending_starts, "timer:ttl-auto-end")

    assert {:ok, %{"id" => la_id}} =
             LiveStatuses.register(ctx.user, ctx.session, "live_activity", %{
               "token" => la_token,
               "environment" => "production",
               "bundle_id" => "surf.comma.ios",
               "locale" => "en-US",
               "workspace_id" => ctx.workspace.id,
               "group_id" => ctx.group_id,
               "activity_id" => "act-ttl-1",
               "live_key" => "timer:ttl-auto-end",
               "activity_schema" => "live_status_v1"
             })

    # Seed a stale pending_start entry to verify push_to_start(nil) cleans it on expiry
    Repo.update_all(from(t in Target, where: t.id == ^pts_id),
      set: [pending_starts: %{"timer:ttl-auto-end" => %{"started_at_unix" => 1}}]
    )

    # Busy lease snoozes 2s
    Repo.update_all(from(t in Target, where: t.id == ^la_id),
      set: [delivery_lease_until: DateTime.add(SystemsClock.utc_now(), 60, :second)]
    )

    assert {:snooze, 2} =
             Comma.Workers.LiveStatusPush.perform(%Oban.Job{
               args: %{"target_id" => la_id, "live_key" => "timer:ttl-auto-end"}
             })

    Repo.update_all(from(t in Target, where: t.id == ^la_id), set: [delivery_lease_until: nil])

    # Advance past TTL and run expiry fanout + delivery
    SystemsClock.advance(6 * 60 * 1_000)

    if Oban.whereis(Comma.Oban) do
      assert :ok =
               Comma.Workers.LiveStatusPushFanout.perform(%Oban.Job{
                 args: %{
                   "group_id" => ctx.group_id,
                   "live_key" => "timer:ttl-auto-end",
                   "cursor" => nil,
                   "expires_at_unix" => expires_unix
                 }
               })
    end

    assert :delivered = LiveStatuses.deliver(la_id, "timer:ttl-auto-end")
    assert_received {:apns_request, "/3/device/" <> ^la_token, _, %{"aps" => %{"event" => "end"}}}
    assert Repo.get(Target, la_id) == nil

    assert :current = LiveStatuses.deliver(pts_id, nil)
    assert Repo.get!(Target, pts_id).pending_starts == %{}

    # Prune keeps rows < 24h old and removes rows > 24h old
    assert LiveStatuses.prune_old_statuses(ctx.group_id) == 0
    SystemsClock.advance(25 * 60 * 60 * 1_000)
    assert LiveStatuses.prune_old_statuses(ctx.group_id) == 1
    assert Repo.aggregate(from(s in Status, where: s.group_id == ^ctx.group_id), :count) == 0
  end

  test "relevance_score ranks attention > short ETA > long ETA > active without ETA > terminal and stays below 100.0" do
    now = ~U[2026-11-20 12:00:00Z]

    attention_eta =
      LiveStatuses.relevance_score(
        %Status{status: "attention", eta_at: DateTime.add(now, 300, :second)},
        now
      )

    attention_plain = LiveStatuses.relevance_score(%Status{status: "attention", eta_at: nil}, now)

    active_12m =
      LiveStatuses.relevance_score(
        %Status{status: "active", eta_at: DateTime.add(now, 12 * 60, :second)},
        now
      )

    active_28m =
      LiveStatuses.relevance_score(
        %Status{status: "active", eta_at: DateTime.add(now, 28 * 60, :second)},
        now
      )

    active_2h =
      LiveStatuses.relevance_score(
        %Status{status: "active", eta_at: DateTime.add(now, 2 * 3600, :second)},
        now
      )

    active_no_eta = LiveStatuses.relevance_score(%Status{status: "active", eta_at: nil}, now)
    done_score = LiveStatuses.relevance_score(%Status{status: "done", eta_at: nil}, now)
    cancelled_score = LiveStatuses.relevance_score(%Status{status: "cancelled", eta_at: nil}, now)
    failed_score = LiveStatuses.relevance_score(%Status{status: "failed", eta_at: nil}, now)

    assert attention_eta > attention_plain
    assert attention_plain == 90.0
    assert attention_eta <= 95.0
    assert attention_eta < 100.0

    assert attention_plain > active_12m
    assert active_12m == 81.0
    assert active_12m > active_28m
    assert active_28m == 75.7
    assert active_28m > active_2h
    assert active_2h == 45.0
    assert active_2h > active_no_eta
    assert active_no_eta == 40.0
    assert active_no_eta > done_score
    assert done_score == 10.0
    assert cancelled_score == 10.0
    assert failed_score == 10.0
  end
end
