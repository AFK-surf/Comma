defmodule SalixIM.TaskFilesTest do
  @moduledoc """
  The Task file index (`SalixIM.TaskFiles`): rows commit with their Message in
  the Conversation source transaction, follow the Task's title and life, and
  reads wait for the backfill of earlier Messages. The Router reads them with
  `internal.list_task_files`. The database is the test's; nothing is faked.
  """
  use SystemsClock.Case, async: false

  alias SalixIM.{ConversationMessage, ConversationPGStore, TaskFiles}
  alias SalixStore.{Ids, Repo}

  setup do
    SalixStore.RepoTestSetup.exclusively(fn ->
      Repo.query!("TRUNCATE salix_conversations, salix_task_files CASCADE")
    end)

    on_exit(fn ->
      Repo.query!(
        "INSERT INTO salix_cutover_markers (name, completed_at, evidence) VALUES ('task_files_v1', now(), '{\"phase\":\"complete\"}') ON CONFLICT (name) DO UPDATE SET evidence = EXCLUDED.evidence"
      )
    end)

    tenant = Ids.new_tenant_id()
    group = Ids.new_group_id(tenant)
    %{group: group, tenant: tenant, agent: Ids.new_agent_id(group)}
  end

  test "an Agent's attached files are indexed with its Message, newest first", ctx do
    task = task!(ctx.group, "Quarterly report")

    append!(task, agent(ctx.agent, [file("draft.md", 1), %{"type" => "text", "text" => "Draft"}]))

    append!(
      task,
      agent(ctx.agent, [
        image("chart.png", 2),
        file("report.pdf", 3),
        %{"type" => "file", "file_name" => "pending.pdf"}
      ])
    )

    # A person's upload and an internal delivery are not the Task's output.
    append!(task, message(%{"actor_type" => "user", "user_id" => "usr"}, [file("brief.pdf", 4)]))

    append!(
      task,
      message(%{"actor_type" => "agent", "agent_id" => ctx.agent}, [file("note.pdf", 5)], %{
        "kind" => "app_event"
      })
    )

    assert {:ok, %{"files" => files, "next_cursor" => nil}} =
             TaskFiles.list_task(ctx.group, task.conversation_id)

    assert Enum.map(files, &{&1["file_name"], &1["type"], &1["seq"], &1["index"]}) == [
             {"report.pdf", "file", 2, 1},
             {"chart.png", "image", 2, 0},
             {"draft.md", "file", 1, 0}
           ]

    assert Enum.all?(files, &(&1["task_title"] == "Quarterly report"))
    assert {:ok, %{"files" => ^files}} = TaskFiles.list_group(ctx.group)

    assert {:ok, %{"files" => [%{"file_name" => "report.pdf"}]}} =
             TaskFiles.search(ctx.group, "REPORT", conversation_id: task.conversation_id)

    assert {:ok, %{"files" => []}} = TaskFiles.list_group(Ids.new_group_id(ctx.tenant))
  end

  test "files take the Task's new title and leave with the Task", ctx do
    task = task!(ctx.group, "Before")
    other = task!(ctx.group, "Other")
    append!(task, agent(ctx.agent, [file("a.csv", 1)]))
    append!(other, agent(ctx.agent, [file("b.csv", 2)]))

    assert {:ok, _, _, _} =
             ConversationPGStore.update(task, revision(task), &Map.put(&1, "title", "After"))

    assert {:ok, %{"files" => [%{"task_title" => "After"}]}} =
             TaskFiles.list_task(ctx.group, task.conversation_id)

    Repo.query!(
      "UPDATE salix_conversations SET deleted_at = now() WHERE group_id = $1 AND conversation_id = $2",
      [ctx.group, task.conversation_id]
    )

    assert {:ok, %{"files" => [%{"file_name" => "b.csv"}]}} = TaskFiles.list_group(ctx.group)
  end

  test "reads wait until every Pod's backfill indexes the Messages of earlier releases", ctx do
    tasks = for n <- 1..26, do: task!(ctx.group, "Task #{n}")
    Enum.each(tasks, &append!(&1, agent(ctx.agent, [file("out.txt", 1)])))

    # An earlier release appended these without rows, and has not opened the backfill.
    Repo.query!("TRUNCATE salix_task_files")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'task_files_v1'")

    assert {:error, :indexing} = TaskFiles.list_group(ctx.group)
    assert {:ok, :closed} = TaskFiles.backfill_page()

    assert {:ok, :opened} = TaskFiles.open_after_rollout("release-test")
    assert {:ok, :indexing} = TaskFiles.open_after_rollout("release-test")
    assert {:error, :indexing} = TaskFiles.list_group(ctx.group)

    # A page holds 25 Tasks; the next resumes where the marker says.
    assert {:ok, %{processed: 25, done: false}} = TaskFiles.backfill_page()
    assert {:ok, %{processed: 1, done: true}} = TaskFiles.backfill_page()
    assert {:ok, :complete} = TaskFiles.backfill_page()
    assert {:ok, :ready} = TaskFiles.open_after_rollout("release-test")

    assert {:ok, %{"files" => files}} = TaskFiles.list_group(ctx.group, limit: 200)
    assert length(files) == 26
  end

  test "a Message whose archived body is lost does not stop the backfill", ctx do
    task = task!(ctx.group, "Lost")
    for n <- 1..3, do: append!(task, agent(ctx.agent, [file("part-#{n}.txt", n)]))
    later = task!(ctx.group, "Later")
    append!(later, agent(ctx.agent, [file("later.txt", 4)]))

    # The second Message's archive segment is gone: no retry can read it.
    Repo.query!(
      "UPDATE salix_conversation_messages SET archive_first_seq = seq, payload = NULL WHERE group_id = $1 AND conversation_id = $2 AND seq = 2",
      [ctx.group, task.conversation_id]
    )

    reopen_backfill!()

    assert {:ok, %{processed: 3, done: true}} = TaskFiles.backfill_page()

    assert %{rows: [[%{"phase" => "complete", "skipped" => 1}]]} =
             Repo.query!(
               "SELECT evidence FROM salix_cutover_markers WHERE name = 'task_files_v1'"
             )

    assert {:ok, %{"files" => files}} = TaskFiles.list_group(ctx.group)
    assert Enum.sort(Enum.map(files, & &1["file_name"])) == ~w(later.txt part-1.txt part-3.txt)
  end

  test "the next Task starts at its first Message when the backfill's Task is deleted", ctx do
    [first, second] =
      Enum.sort_by([task!(ctx.group, "One"), task!(ctx.group, "Two")], & &1.conversation_id)

    for n <- 1..3, do: append!(first, agent(ctx.agent, [file("first-#{n}.txt", n)]))
    append!(second, agent(ctx.agent, [file("second.txt", 4)]))

    # A page stopped after the third Message of the first Task, which is then deleted.
    reopen_backfill!()

    Repo.query!(
      "UPDATE salix_cutover_markers SET evidence = $1 WHERE name = 'task_files_v1'",
      [
        %{
          "phase" => "running",
          "processed" => 3,
          "position" => %{
            "group_id" => ctx.group,
            "conversation_id" => first.conversation_id,
            "after_seq" => 3
          }
        }
      ]
    )

    Repo.query!(
      "UPDATE salix_conversations SET deleted_at = now() WHERE group_id = $1 AND conversation_id = $2",
      [ctx.group, first.conversation_id]
    )

    assert {:ok, %{processed: 1, done: true}} = TaskFiles.backfill_page()

    assert {:ok, %{"files" => [%{"file_name" => "second.txt"}]}} =
             TaskFiles.list_group(ctx.group)
  end

  test "the backfill does not index a deleted Task or a Conversation that is not a Task", ctx do
    deleted = task!(ctx.group, "Deleted")
    append!(deleted, agent(ctx.agent, [file("gone.txt", 1)]))
    gone = messages(deleted)

    Repo.query!(
      "UPDATE salix_conversations SET deleted_at = now() WHERE group_id = $1 AND conversation_id = $2",
      [ctx.group, deleted.conversation_id]
    )

    chat = ConversationPGStore.new(ctx.group, Ids.new_conversation_id())
    assert {:ok, :inserted, _, 1} = ConversationPGStore.create(chat, %{"kind" => "user_chat"})
    append!(chat, agent(ctx.agent, [file("chat.txt", 2)]))

    Repo.query!("TRUNCATE salix_task_files")
    assert :ok = ConversationPGStore.index_task_files(deleted, gone)
    assert :ok = ConversationPGStore.index_task_files(chat, messages(chat))
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM salix_task_files")
  end

  describe "internal.list_task_files" do
    test "the Router lists a Task's files, searches names and pages the Group", ctx do
      task = task!(ctx.group, "Export")
      append!(task, agent(ctx.agent, [file("rows.csv", 1), image("plot.png", 2)]))

      assert {:ok, %{"files" => [%{"file_name" => "plot.png"}, _], "count" => 2} = listed} =
               router(ctx, %{"conversation_id" => task.conversation_id})

      assert listed["next_action"] =~ "internal.read_conversation"

      assert {:ok, %{"files" => [%{"file_name" => "rows.csv"}], "count" => 1}} =
               router(ctx, %{"query" => "rows"})

      assert {:ok, %{"files" => [_], "next_cursor" => cursor}} = router(ctx, %{"limit" => 1})

      assert {:ok, %{"files" => [%{"file_name" => "rows.csv"}]} = last} =
               router(ctx, %{"limit" => 1, "cursor" => cursor})

      refute Map.has_key?(last, "next_cursor")
    end

    test "a Worker may not list files; bad parameters and an unfinished backfill are errors",
         ctx do
      assert {:error, "operation is not authorized for this agent role"} =
               call(ctx, "worker", %{})

      assert {:error, _} = router(ctx, %{"limit" => 0})
      assert {:error, _} = router(ctx, %{"path" => "/"})
      assert {:error, "cursor, limit or query is invalid"} = router(ctx, %{"cursor" => "x"})

      Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'task_files_v1'")
      assert {:error, message} = router(ctx, %{})
      assert message =~ "still being indexed"
    end
  end

  defp router(ctx, params), do: call(ctx, "router", params)

  defp call(ctx, role, params) do
    SalixIM.Provider.Internal.call(
      %{agent: %{"role" => role}, tenant_id: ctx.tenant, group_id: ctx.group},
      "internal.list_task_files",
      params
    )
  end

  defp task!(group, title) do
    scope = ConversationPGStore.new(group, Ids.new_conversation_id())

    assert {:ok, :inserted, _, 1} =
             ConversationPGStore.create(scope, %{"kind" => "agent_task", "title" => title})

    scope
  end

  # An earlier release appended the Messages without rows; the release opens the backfill.
  defp reopen_backfill! do
    Repo.query!("TRUNCATE salix_task_files")
    Repo.query!("DELETE FROM salix_cutover_markers WHERE name = 'task_files_v1'")
    assert {:ok, :opened} = TaskFiles.open_after_rollout("release-test")
  end

  defp append!(scope, message) do
    assert {:ok, :inserted, _, _, _} = ConversationPGStore.append(scope, revision(scope), message)
  end

  defp revision(scope) do
    {:ok, _record, revision} = ConversationPGStore.read(scope)
    revision
  end

  defp messages(scope) do
    {:ok, messages} = ConversationPGStore.messages(scope, 1, 100, 100)
    messages
  end

  defp agent(agent_id, content),
    do: message(%{"actor_type" => "agent", "agent_id" => agent_id}, content)

  defp message(owner, content, attrs \\ %{}) do
    ConversationMessage.build(
      Map.merge(%{"kind" => "message", "content" => content}, attrs),
      owner,
      SystemsClock.system_time(:millisecond)
    )
  end

  defp file(name, n), do: %{"type" => "file", "file_name" => name, "blob_ref" => blob(n)}

  defp image(name, n),
    do: %{
      "type" => "image",
      "file_name" => name,
      "mime_type" => "image/png",
      "blob_ref" => blob(n)
    }

  defp blob(n), do: %{"uuid" => "blob-#{n}", "hash" => "sha256:#{n}", "size" => n * 100}
end
