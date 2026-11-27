defmodule SalixIM.TaskFeedTest do
  @moduledoc """
  Tests for the incremental Task Feed projection (`SalixIM.TaskFeed` and
  `SalixStore.TaskFeed`) running inside `SalixIM.ConversationPGStore`
  transactions against Postgres.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationMessage, ConversationPGStore, TaskFeed}
  alias SalixStore.{Ids, Loops, Repo}
  alias SalixStore.TaskFeed, as: Store

  setup do
    SalixStore.RepoTestSetup.exclusively(fn ->
      Repo.query!("TRUNCATE salix_conversations, salix_task_feed_entries, agent_loops CASCADE")
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    agent = Ids.new_agent_id(group)
    %{tenant: tenant, group: group, agent: agent}
  end

  test "merges multiple milestones in one round in-place, deduplicates, caps at 20, and backfills standalone milestone with later outcome",
       ctx do
    {scope, _rev} = create_task!(ctx.group, "调研竞品定价", origin: "comma", at: 1_795_194_000_000)

    # Standalone milestone 1
    append!(
      scope,
      agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "抓取定价页"}], 1_795_194_100_000)
    )

    assert {:ok, %{"entries" => [entry]}} = TaskFeed.list_group(ctx.group)
    assert entry["cluster_key"] == "brief"
    assert entry["trigger_kind"] == "brief"
    assert entry["trigger_text"] == nil
    assert entry["milestone_count"] == 1

    assert [%{"title" => "抓取定价页", "at" => 1_795_194_100_000, "message_id" => nil}] =
             entry["milestones"]

    assert entry["outcome_message_id"] == nil
    assert entry["outcome_text"] == nil

    # Standalone milestone 2 (same round -> upserted in place, same entry id)
    entry_id = entry["id"]

    append!(
      scope,
      agent_msg(
        ctx.agent,
        [
          %{"type" => "milestone", "title" => "整理价格对比表"},
          %{"type" => "milestone", "title" => "整理价格对比表"}
        ],
        1_795_194_200_000
      )
    )

    assert {:ok, %{"entries" => [entry2]}} = TaskFeed.list_group(ctx.group)
    assert entry2["id"] == entry_id
    assert entry2["milestone_count"] == 2
    assert Enum.map(entry2["milestones"], & &1["title"]) == ["抓取定价页", "整理价格对比表"]

    # Subsequent visible Agent reply backfills outcome_text, media (<=4), and files (<=3)
    reply =
      append!(
        scope,
        agent_msg(
          ctx.agent,
          [
            %{
              "type" => "text",
              "text" => "## 核心结论\n\n- **方案 A** 比 [竞品B](https://example.com) 低 `20%`。"
            },
            image_block("img_1.png", "att_1", 1200, 800),
            Map.delete(image_block("img_2.png", "att_2", 640, 480), "mime_type"),
            image_block("img_3.png", "att_3", 800, 600),
            image_block("img_4.png", "att_4", 900, 500),
            image_block("img_5.png", "att_5", 100, 100),
            file_block("pricing.md", "text/markdown"),
            file_block("sheet.csv", "text/csv"),
            file_block("deck.pdf", "application/pdf"),
            file_block("extra.txt", "text/plain")
          ],
          1_795_194_300_000
        )
      )

    assert {:ok, %{"entries" => [entry3]}} = TaskFeed.list_group(ctx.group)
    assert entry3["id"] == entry_id
    assert entry3["outcome_message_id"] == reply["message_id"]
    assert entry3["outcome_text"] == "核心结论 方案 A 比 竞品B 低 20%。"

    # Both earlier standalone milestones now point to the visible outcome message
    assert Enum.all?(entry3["milestones"], fn m ->
             m["message_id"] == reply["message_id"] and
               Map.keys(m) |> Enum.sort() == ["at", "message_id", "title"]
           end)

    assert length(entry3["media"]) == 4

    assert hd(entry3["media"]) == %{
             "attachment_id" => "att_1",
             "mime_type" => "image/png",
             "width" => 1200,
             "height" => 800,
             "filename" => "img_1.png"
           }

    assert Enum.at(entry3["media"], 1)["mime_type"] == "image/*"

    assert length(entry3["files"]) == 3

    assert hd(entry3["files"]) == %{
             "name" => "pricing.md",
             "mime_type" => "text/markdown"
           }

    assert entry3["occurred_at"] == 1_795_194_300_000

    # Adding 20 more milestones caps displayed milestones at 20 while milestone_count keeps total (22)
    for i <- 1..20 do
      append!(
        scope,
        agent_msg(
          ctx.agent,
          [%{"type" => "milestone", "title" => "步骤 #{i}"}],
          1_795_194_300_000 + i * 1_000
        )
      )
    end

    assert {:ok, %{"entries" => [entry4]}} = TaskFeed.list_group(ctx.group)
    assert entry4["milestone_count"] == 22
    assert length(entry4["milestones"]) == 20
    assert hd(entry4["milestones"])["title"] == "步骤 1"
    assert List.last(entry4["milestones"])["title"] == "步骤 20"
  end

  test "follow-up starts a new cluster while idle Loop wakes emit zero feed noise", ctx do
    {scope, _rev} = create_task!(ctx.group, "PR 巡检", at: 1_795_194_000_000)

    # Idle loop wake with no milestone and no visible outcome -> zero entries
    append!(scope, loop_wake_msg(1_795_194_100_000))
    assert {:ok, %{"entries" => []}} = TaskFeed.list_group(ctx.group)

    # Second loop wake with milestone + result -> creates run:<seq> entry
    wake2 = append!(scope, loop_wake_msg(1_795_194_200_000))

    append!(
      scope,
      agent_msg(
        ctx.agent,
        [
          %{"type" => "milestone", "title" => "发现新评论"},
          %{"type" => "text", "text" => "已回复评论并更新补丁"}
        ],
        1_795_194_250_000
      )
    )

    # User follow-up starts a brand new cluster
    follow_up =
      append!(
        scope,
        user_msg("请再补充性能基准测试\n第二行不进入截断标题", 1_795_194_300_000)
      )

    # Before agent responds to follow-up, no empty follow-up entry is created
    assert {:ok, %{"entries" => [only_run]}} = TaskFeed.list_group(ctx.group)
    assert only_run["cluster_key"] == "run:#{wake2["seq"]}"
    assert only_run["trigger_kind"] == "run"
    assert only_run["is_loop"] == true

    # Agent adds milestone for follow-up -> creates follow_up:<msg_id> entry;
    # list_group returns only the latest cluster per Task and never leaks older clusters across pages.
    append!(
      scope,
      agent_msg(
        ctx.agent,
        [%{"type" => "milestone", "title" => "跑完基准测试"}],
        1_795_194_400_000
      )
    )

    assert {:ok, %{"entries" => [latest], "has_more" => false, "next_cursor" => nil}} =
             TaskFeed.list_group(ctx.group)

    assert latest["cluster_key"] == "follow_up:#{follow_up["message_id"]}"
    assert latest["trigger_kind"] == "follow_up"
    assert latest["trigger_text"] == "请再补充性能基准测试"

    # Both clusters remain stored in the projection table.
    assert %{rows: [[2]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_task_feed_entries WHERE group_id = $1 AND conversation_id = $2",
               [ctx.group, scope.conversation_id]
             )

    # Second task with older timestamp verifies keyset cursor stays outside DISTINCT ON:
    # page 2 must return task2, never task1's older run:<seq> cluster.
    {scope2, _} = create_task!(ctx.group, "另一项任务", at: 1_795_194_050_000)

    append!(
      scope2,
      agent_msg(
        ctx.agent,
        [%{"type" => "milestone", "title" => "完成巡检"}],
        1_795_194_150_000
      )
    )

    assert {:ok, %{"entries" => [p1], "has_more" => true, "next_cursor" => cursor}} =
             TaskFeed.list_group(ctx.group, limit: 1)

    assert p1["conversation_id"] == scope.conversation_id
    assert p1["cluster_key"] == "follow_up:#{follow_up["message_id"]}"

    assert {:ok, %{"entries" => [p2], "has_more" => false, "next_cursor" => nil}} =
             TaskFeed.list_group(ctx.group, limit: 1, cursor: cursor)

    assert p2["conversation_id"] == scope2.conversation_id
  end

  test "visible Agent reply without milestones materializes while active and updates in-place on ready_for_review",
       ctx do
    {scope, _rev} = create_task!(ctx.group, "简单总结任务", at: 1_795_194_000_000)

    # Empty brief alone does not create a feed entry
    assert {:ok, %{"entries" => []}} = TaskFeed.list_group(ctx.group)

    reply =
      append!(
        scope,
        agent_msg(ctx.agent, [%{"type" => "text", "text" => "总结完成：共 3 项改动。"}], 1_795_194_100_000)
      )

    # Visible Agent reply materializes immediately even while still active
    assert {:ok, %{"entries" => [active_entry]}} = TaskFeed.list_group(ctx.group)
    assert active_entry["task_status"] == "active"
    assert active_entry["review_version"] == nil
    assert active_entry["milestone_count"] == 0
    assert active_entry["milestones"] == []
    assert active_entry["outcome_message_id"] == reply["message_id"]
    assert active_entry["outcome_text"] == "总结完成：共 3 项改动。"

    # Transition to ready_for_review updates task_status and review_version in place
    update_task!(scope, fn rec ->
      rec
      |> Map.put("status", "ready_for_review")
      |> Map.put("updated_at", 1_795_194_200_000)
    end)

    assert {:ok, %{"entries" => [entry]}} = TaskFeed.list_group(ctx.group)
    assert entry["id"] == active_entry["id"]
    assert entry["task_status"] == "ready_for_review"
    assert entry["review_version"] == 1_795_194_200_000
    assert entry["milestone_count"] == 0
    assert entry["milestones"] == []
    assert entry["outcome_message_id"] == reply["message_id"]
    assert entry["outcome_text"] == "总结完成：共 3 项改动。"
  end

  test "metadata sync, archive/unarchive, soft/hard delete, attention filter (including failed loop), and non-task skip",
       ctx do
    # Non-agent_task (user_chat) must be ignored completely
    chat_scope = ConversationPGStore.new(ctx.group, Ids.new_conversation_id())

    {:ok, :inserted, _rec, _msg, _rev} =
      ConversationPGStore.create_with_message(
        chat_scope,
        %{
          "agent_group_id" => ctx.group,
          "conversation_id" => chat_scope.conversation_id,
          "kind" => "user_chat",
          "status" => "active",
          "title" => "Home"
        },
        agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "不该进流"}], 1_795_194_050_000)
      )

    assert {:ok, %{"entries" => []}} = TaskFeed.list_group(ctx.group)

    # Task A: active -> archived -> unarchived -> soft deleted -> hard deleted
    {scope_a, _} = create_task!(ctx.group, "任务 A", at: 1_795_194_000_000)

    append!(
      scope_a,
      agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "A1"}], 1_795_194_100_000)
    )

    # Task B: ready_for_review (attention = true)
    {scope_b, _} = create_task!(ctx.group, "任务 B", at: 1_795_194_000_000)

    append!(
      scope_b,
      agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "B1"}], 1_795_194_200_000)
    )

    update_task!(scope_b, fn rec ->
      rec
      |> Map.put("status", "ready_for_review")
      |> Map.put("title", "任务 B (已改名)")
      |> Map.put("updated_at", 1_795_194_250_000)
    end)

    # Task C: active Loop task whose Loop failed (attention = true)
    {scope_c, _} = create_task!(ctx.group, "循环任务 C", at: 1_795_194_000_000)
    append!(scope_c, loop_wake_msg(1_795_194_260_000))

    append!(
      scope_c,
      agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "C1"}], 1_795_194_300_000)
    )

    {:ok, loop} =
      Loops.put_task_request(%{
        "id" => Ids.new_loop_id(),
        "tenant_id" => ctx.tenant,
        "group_id" => ctx.group,
        "agent_id" => ctx.agent,
        "task_conversation_id" => scope_c.conversation_id,
        "trigger" => %{"every_minutes" => 30},
        "status" => "pending",
        "created_at" => 1_795_194_000_000,
        "updated_at" => 1_795_194_000_000
      })

    {:ok, _failed_loop} =
      Loops.update(loop["id"], fn rec ->
        {:ok, Map.merge(rec, %{"status" => "failed", "updated_at" => 1_795_194_350_000})}
      end)

    # Attention filter returns only B (ready_for_review) and C (failed loop), not active A
    assert {:ok, %{"entries" => attention_entries}} =
             TaskFeed.list_group(ctx.group, attention: true)

    assert Enum.map(attention_entries, & &1["conversation_id"]) == [
             scope_c.conversation_id,
             scope_b.conversation_id
           ]

    assert Enum.find(attention_entries, &(&1["conversation_id"] == scope_b.conversation_id))[
             "task_title"
           ] == "任务 B (已改名)"

    assert Enum.find(attention_entries, &(&1["conversation_id"] == scope_c.conversation_id))[
             "loop_kind"
           ] == "every_minutes"

    # Archiving Task A hides it immediately; unarchiving restores it
    update_task!(scope_a, fn rec ->
      rec
      |> Map.put("status", "archived")
      |> Map.put("archived_from_status", "completed")
      |> Map.put("archived_at", 1_795_194_400_000)
      |> Map.put("updated_at", 1_795_194_400_000)
    end)

    assert {:ok, %{"entries" => visible}} = TaskFeed.list_group(ctx.group)
    refute Enum.any?(visible, &(&1["conversation_id"] == scope_a.conversation_id))

    update_task!(scope_a, fn rec ->
      rec
      |> Map.put("status", "completed")
      |> Map.drop(["archived_from_status", "archived_at"])
      |> Map.put("updated_at", 1_795_194_450_000)
    end)

    assert {:ok, %{"entries" => restored}} = TaskFeed.list_group(ctx.group)
    assert Enum.any?(restored, &(&1["conversation_id"] == scope_a.conversation_id))

    # Soft delete hides Task A immediately
    update_task!(scope_a, fn rec -> Map.put(rec, "deleted_at", 1_795_194_500_000) end)
    assert {:ok, %{"entries" => after_soft_delete}} = TaskFeed.list_group(ctx.group)
    refute Enum.any?(after_soft_delete, &(&1["conversation_id"] == scope_a.conversation_id))

    # Hard delete removes rows from salix_task_feed_entries
    Store.delete_conversation!(ctx.group, scope_a.conversation_id)

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_task_feed_entries WHERE group_id = $1 AND conversation_id = $2",
               [ctx.group, scope_a.conversation_id]
             )
  end

  test "keyset pagination traverses entries without gaps or duplicates even with identical timestamps",
       ctx do
    # Create 5 tasks with shared and distinct timestamps to verify (occurred_at, id) tie-break
    timestamps = [
      1_795_195_000_000,
      1_795_195_000_000,
      1_795_194_900_000,
      1_795_194_900_000,
      1_795_194_800_000
    ]

    for {ts, idx} <- Enum.with_index(timestamps, 1) do
      {scope, _} = create_task!(ctx.group, "Task #{idx}", at: ts - 100)

      append!(
        scope,
        agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "M#{idx}"}], ts)
      )
    end

    assert {:ok, %{"entries" => all, "has_more" => false, "next_cursor" => nil}} =
             TaskFeed.list_group(ctx.group, limit: 10)

    assert length(all) == 5

    # Paginate with limit: 2 across all pages
    {collected, pages} = collect_pages(ctx.group, 2, nil, [], 0)
    assert pages == 3
    assert Enum.map(collected, & &1["id"]) == Enum.map(all, & &1["id"])
    assert length(Enum.uniq_by(collected, & &1["id"])) == 5
  end

  test "historical backfill projects milestones, milestone-less statuses, follow-ups, skips noise/non-tasks/deleted, and marks archived",
       ctx do
    on_exit(fn ->
      Repo.query!(
        "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ('task_feed_v1', now(), '{\"phase\":\"complete\"}') ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence"
      )
    end)

    # 1. Completed task with milestone + reply
    {scope_m, _} = create_task!(ctx.group, "里程碑任务", at: 1_795_196_000_000)

    append!(
      scope_m,
      agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "已完成调研"}], 1_795_196_010_000)
    )

    append!(
      scope_m,
      agent_msg(ctx.agent, [%{"type" => "text", "text" => "里程碑结论"}], 1_795_196_020_000)
    )

    update_task!(
      scope_m,
      &Map.merge(&1, %{"status" => "completed", "updated_at" => 1_795_196_030_000})
    )

    # 2. Milestone-less tasks across statuses: completed, ready_for_review, escalated, failed, active
    status_scopes =
      for {status, idx} <-
            Enum.with_index(~w(completed ready_for_review escalated failed active), 1) do
        base_at = 1_795_196_100_000 + idx * 10_000
        {scope, _} = create_task!(ctx.group, "无里程碑 #{status}", at: base_at)

        label = String.replace(status, "_", "-")

        append!(
          scope,
          agent_msg(ctx.agent, [%{"type" => "text", "text" => "回复 #{label}"}], base_at + 1_000)
        )

        if status != "active" do
          update_task!(
            scope,
            &Map.merge(&1, %{"status" => status, "updated_at" => base_at + 2_000})
          )
        end

        {status, label, scope}
      end

    # 3. Multi-turn follow-up task
    {scope_fu, _} = create_task!(ctx.group, "多轮追问任务", at: 1_795_196_200_000)

    append!(
      scope_fu,
      agent_msg(ctx.agent, [%{"type" => "text", "text" => "第一轮答复"}], 1_795_196_210_000)
    )

    fu_msg = append!(scope_fu, user_msg("请补充第二轮", 1_795_196_220_000))

    append!(
      scope_fu,
      agent_msg(ctx.agent, [%{"type" => "text", "text" => "第二轮答复"}], 1_795_196_230_000)
    )

    # 4. Idle Loop wake (zero feed noise)
    {scope_idle_loop, _} = create_task!(ctx.group, "空转巡检", at: 1_795_196_300_000)
    append!(scope_idle_loop, loop_wake_msg(1_795_196_310_000))

    # 5. Archived task (backfilled with archived = true, hidden from default list_group)
    {scope_archived, _} = create_task!(ctx.group, "已归档任务", at: 1_795_196_400_000)

    append!(
      scope_archived,
      agent_msg(ctx.agent, [%{"type" => "text", "text" => "归档前回复"}], 1_795_196_410_000)
    )

    update_task!(
      scope_archived,
      &Map.merge(&1, %{"status" => "archived", "updated_at" => 1_795_196_420_000})
    )

    # 6. Soft-deleted task (ignored by backfill)
    {scope_deleted, _} = create_task!(ctx.group, "已删除任务", at: 1_795_196_500_000)

    append!(
      scope_deleted,
      agent_msg(ctx.agent, [%{"type" => "text", "text" => "删除前回复"}], 1_795_196_510_000)
    )

    update_task!(scope_deleted, &Map.put(&1, "deleted_at", 1_795_196_520_000))

    # 7. Non-task user_chat (ignored by backfill)
    chat_scope = ConversationPGStore.new(ctx.group, Ids.new_conversation_id())

    {:ok, :inserted, _rec, _msg, _rev} =
      ConversationPGStore.create_with_message(
        chat_scope,
        %{
          "agent_group_id" => ctx.group,
          "conversation_id" => chat_scope.conversation_id,
          "kind" => "user_chat",
          "status" => "active",
          "title" => "普通对话"
        },
        agent_msg(ctx.agent, [%{"type" => "milestone", "title" => "不应回填"}], 1_795_196_600_000)
      )

    # Simulate pre-rollout state: empty projection table and no task_feed_v1 marker
    Repo.query!("TRUNCATE salix_task_feed_entries")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'task_feed_v1'")

    refute Store.ready?()
    assert {:ok, :closed} = TaskFeed.backfill_page()
    # Feed stays readable (never {:error, :indexing}) while backfill is pending
    assert {:ok, %{"entries" => []}} = TaskFeed.list_group(ctx.group)

    assert {:ok, :opened} = TaskFeed.open_after_rollout("test-release")
    assert {:ok, :indexing} = TaskFeed.open_after_rollout("test-release")
    assert {:ok, %{done: true}} = drain_backfill!()

    assert Store.ready?()
    assert {:ok, :ready} = TaskFeed.open_after_rollout("test-release")
    assert {:ok, :complete} = TaskFeed.backfill_page()

    assert %{rows: [[%{"phase" => "complete"}]]} =
             Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name = 'task_feed_v1'")

    assert {:ok, %{"entries" => entries}} = TaskFeed.list_group(ctx.group, limit: 50)
    by_conv = Enum.group_by(entries, & &1["conversation_id"])

    # Milestone task
    assert [m_entry] = by_conv[scope_m.conversation_id]
    assert m_entry["milestone_count"] == 1
    assert m_entry["outcome_text"] == "里程碑结论"
    assert m_entry["task_status"] == "completed"

    # All 5 milestone-less statuses materialized
    for {status, label, scope} <- status_scopes do
      assert [entry] = by_conv[scope.conversation_id]
      assert entry["task_status"] == status
      assert entry["milestone_count"] == 0
      assert entry["outcome_text"] == "回复 #{label}"
    end

    # Multi-turn follow-up projected both clusters, while list_group exposes only the newest one per Task
    assert [fu_latest] = by_conv[scope_fu.conversation_id]
    assert fu_latest["cluster_key"] == "follow_up:#{fu_msg["message_id"]}"
    assert fu_latest["trigger_text"] == "请补充第二轮"
    assert fu_latest["outcome_text"] == "第二轮答复"

    assert %{rows: fu_rows} =
             Repo.query!(
               "SELECT cluster_key, outcome_text FROM salix_task_feed_entries WHERE group_id = $1 AND conversation_id = $2 ORDER BY occurred_at ASC",
               [ctx.group, scope_fu.conversation_id]
             )

    assert fu_rows == [
             ["brief", "第一轮答复"],
             ["follow_up:#{fu_msg["message_id"]}", "第二轮答复"]
           ]

    # Idle loop wake, archived, deleted, and user_chat do not appear in default feed
    refute Map.has_key?(by_conv, scope_idle_loop.conversation_id)
    refute Map.has_key?(by_conv, scope_archived.conversation_id)
    refute Map.has_key?(by_conv, scope_deleted.conversation_id)
    refute Map.has_key?(by_conv, chat_scope.conversation_id)

    # Archived task was projected with archived = true
    assert %{rows: [[true]]} =
             Repo.query!(
               "SELECT archived FROM salix_task_feed_entries WHERE group_id = $1 AND conversation_id = $2",
               [ctx.group, scope_archived.conversation_id]
             )

    # Deleted task and user_chat have zero projection rows
    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM salix_task_feed_entries WHERE group_id = $1 AND conversation_id = ANY($2)",
               [ctx.group, [scope_deleted.conversation_id, chat_scope.conversation_id]]
             )
  end

  test "replaying index_task_feed on a task with >20 milestones is strictly idempotent", ctx do
    {scope, _} = create_task!(ctx.group, "超长里程碑任务", at: 1_795_197_000_000)

    for i <- 1..25 do
      append!(
        scope,
        agent_msg(
          ctx.agent,
          [%{"type" => "milestone", "title" => "步骤 #{i}"}],
          1_795_197_000_000 + i * 1_000
        )
      )
    end

    assert {:ok, %{"entries" => [before_replay]}} = TaskFeed.list_group(ctx.group)
    assert before_replay["milestone_count"] == 25
    assert length(before_replay["milestones"]) == 20
    assert hd(before_replay["milestones"])["title"] == "步骤 6"
    assert List.last(before_replay["milestones"])["title"] == "步骤 25"

    assert {:ok, messages} = ConversationPGStore.messages(scope, 1, 26, 26)
    assert {:ok, _cluster} = ConversationPGStore.index_task_feed(scope, messages, nil)
    assert {:ok, _cluster} = ConversationPGStore.index_task_feed(scope, messages, nil)

    assert {:ok, %{"entries" => [after_replay]}} = TaskFeed.list_group(ctx.group)
    assert after_replay["milestone_count"] == 25
    assert length(after_replay["milestones"]) == 20

    assert Enum.map(after_replay["milestones"], & &1["title"]) ==
             Enum.map(before_replay["milestones"], & &1["title"])
  end

  defp drain_backfill!(attempts \\ 20)
  defp drain_backfill!(0), do: raise("backfill did not finish within 20 pages")

  defp drain_backfill!(attempts) do
    case TaskFeed.backfill_page() do
      {:ok, %{done: true} = result} -> {:ok, result}
      {:ok, :complete} -> {:ok, %{done: true}}
      {:ok, %{done: false}} -> drain_backfill!(attempts - 1)
    end
  end

  defp collect_pages(group_id, limit, cursor, acc, pages) do
    opts = if cursor, do: [limit: limit, cursor: cursor], else: [limit: limit]

    assert {:ok, %{"entries" => entries, "has_more" => has_more, "next_cursor" => next}} =
             TaskFeed.list_group(group_id, opts)

    next_acc = acc ++ entries

    if has_more do
      assert is_binary(next)
      collect_pages(group_id, limit, next, next_acc, pages + 1)
    else
      assert next == nil
      {next_acc, pages + 1}
    end
  end

  defp create_task!(group_id, title, opts) do
    at = Keyword.get(opts, :at, 1_795_194_000_000)
    origin = Keyword.get(opts, :origin)
    scope = ConversationPGStore.new(group_id, Ids.new_conversation_id())

    metadata =
      if origin, do: %{"origin" => %{"provider" => origin}}, else: %{}

    record = %{
      "agent_group_id" => group_id,
      "conversation_id" => scope.conversation_id,
      "kind" => "agent_task",
      "status" => "active",
      "title" => title,
      "metadata" => metadata,
      "created_at" => at,
      "updated_at" => at
    }

    brief =
      ConversationMessage.build(
        %{
          "kind" => "message",
          "content" => [%{"type" => "text", "text" => "Brief for #{title}"}],
          "metadata" => %{"message_type" => "task_command"}
        },
        %{"actor_type" => "user", "user_id" => "usr_1"},
        at
      )

    {:ok, :inserted, _rec, _msg, rev} =
      ConversationPGStore.create_with_message(scope, record, brief)

    {scope, rev}
  end

  defp append!(scope, message) do
    {:ok, _rec, rev} = ConversationPGStore.read(scope)
    {:ok, :inserted, _rec, inserted, _next} = ConversationPGStore.append(scope, rev, message)
    inserted
  end

  defp update_task!(scope, fun) do
    {:ok, _rec, rev} = ConversationPGStore.read(scope)
    {:ok, _prev, updated, _next} = ConversationPGStore.update(scope, rev, fun)
    updated
  end

  defp agent_msg(agent_id, content, at) do
    ConversationMessage.build(
      %{"kind" => "message", "content" => content},
      %{"actor_type" => "agent", "agent_id" => agent_id},
      at
    )
  end

  defp user_msg(text, at) do
    ConversationMessage.build(
      %{"kind" => "message", "content" => [%{"type" => "text", "text" => text}]},
      %{"actor_type" => "user", "user_id" => "usr_1"},
      at
    )
  end

  defp loop_wake_msg(at) do
    ConversationMessage.build(
      %{
        "kind" => "message",
        "content" => [%{"type" => "text", "text" => "loop wake"}],
        agent_input: %{"trusted_origin" => %{"provider" => "loop"}}
      },
      %{"actor_type" => "system"},
      at
    )
  end

  defp image_block(filename, attachment_id, width, height) do
    %{
      "type" => "image",
      "attachment_id" => attachment_id,
      "file_name" => filename,
      "mime_type" => "image/png",
      "width" => width,
      "height" => height,
      "blob_ref" => %{
        "uuid" => String.duplicate("1", 32),
        "hash" => String.duplicate("a", 64),
        "size" => 2_048
      }
    }
  end

  defp file_block(filename, mime_type) do
    %{
      "type" => "file",
      "file_name" => filename,
      "mime_type" => mime_type,
      "blob_ref" => %{
        "uuid" => String.duplicate("2", 32),
        "hash" => String.duplicate("b", 64),
        "size" => 1_024
      }
    }
  end
end
