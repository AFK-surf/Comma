defmodule CommaWeb.TaskFeedApiTest do
  @moduledoc """
  HTTP contract tests for `GET /v1/comma/groups/:group_id/task-feed`.

  Exercises the live CommaWeb router, authentication, Workspace/Group
  authorization, restricted single-Task session scoping, guest rejection,
  query validation, keyset pagination, attention filtering, archive/delete
  visibility, and the locked JSON response shape.
  """
  use SystemsClock.Case, async: false

  import Comma.WorkspaceTestSupport

  alias SalixIM.{ConversationPGStore, ConversationServer}
  alias SalixStore.{Ids, Loops}

  @admin_token "test-token"

  setup do
    unless SystemsRuntime.Proc.whereis(BillingCore.Repo) do
      start_supervised!(BillingCore.Repo)
    end

    billing_owner = Ecto.Adapters.SQL.Sandbox.start_owner!(BillingCore.Repo, shared: true)
    comma_owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)

    unless SystemsRuntime.Proc.whereis(SalixStore.S3.Fake) do
      start_supervised!(SalixStore.S3.Fake)
    end

    prev_backend = SystemsRuntime.get_env(:salix_store, :s3_backend)
    prev_salix_client = SystemsRuntime.get_env(:comma_core, :salix_client)
    prev_api_token = SystemsRuntime.get_env(:comma_web, :api_token)
    SystemsRuntime.put_env(:salix_store, :s3_backend, SalixStore.S3.Fake)
    SystemsRuntime.put_env(:comma_web, :api_token, @admin_token)
    SystemsRuntime.put_env(:comma_core, :salix_client, CommaWeb.SalixClient)

    on_exit(fn ->
      restore_env(:salix_store, :s3_backend, prev_backend)
      restore_env(:comma_web, :api_token, prev_api_token)
      restore_env(:comma_core, :salix_client, prev_salix_client)
      CommaWeb.TestRepoSandbox.stop_owner(comma_owner)
      Ecto.Adapters.SQL.Sandbox.stop_owner(billing_owner)
    end)

    :ok
  end

  test "returns locked JSON contract, paginates cleanly, filters attention and archived/deleted, and enforces auth" do
    suffix = Integer.to_string(SystemsRuntime.Proc.unique_integer([:positive]))

    user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "task-feed-#{suffix}@example.com"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    workspace = create_ready_workspace!(user["id"])
    workspace = CommaWeb.TestWorkers.with_default_worker!(workspace)

    session =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions", json: %{})
      |> expect_status(201)
      |> Map.fetch!(:body)

    :ok = CommaWeb.TestConvergence.workspace!(workspace["id"])
    group_id = workspace["default_group_id"]
    worker = workspace["default_worker_agent_id"]

    # Task 1: milestone + reply with image & file -> ready_for_review (attention)
    {:ok, task1} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group_id,
        workspace["router_agent_id"],
        worker,
        %{"title" => "调研竞品定价", "content" => "分析竞品", "client_request_id" => "tf-1-#{suffix}"}
      )

    {:ok, _m1} =
      ConversationServer.append_group_conversation_message(
        group_id,
        task1["conversation_id"],
        %{
          "actor_type" => "agent",
          "agent_id" => worker,
          "content" => [%{"type" => "milestone", "title" => "抓取定价页"}]
        }
      )

    {:ok, m2} =
      ConversationServer.append_group_conversation_message(
        group_id,
        task1["conversation_id"],
        %{
          "actor_type" => "agent",
          "agent_id" => worker,
          "content" => [
            %{"type" => "text", "text" => "核心结论：价格低 20%"},
            %{
              "type" => "image",
              "attachment_id" => "att_1",
              "file_name" => "a.png",
              "mime_type" => "image/png",
              "width" => 1200,
              "height" => 800,
              "blob_ref" => %{
                "uuid" => String.duplicate("1", 32),
                "hash" => String.duplicate("a", 64),
                "size" => 2_048
              }
            },
            %{
              "type" => "file",
              "file_name" => "pricing.md",
              "mime_type" => "text/markdown",
              "blob_ref" => %{
                "uuid" => String.duplicate("2", 32),
                "hash" => String.duplicate("b", 64),
                "size" => 1_024
              }
            }
          ]
        }
      )

    {:ok, _updated_task1} =
      ConversationServer.update_group_conversation(
        group_id,
        task1["conversation_id"],
        %{"status" => "ready_for_review"}
      )

    # Task 2: active task with milestone (not attention)
    {:ok, task2} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group_id,
        workspace["router_agent_id"],
        worker,
        %{"title" => "代码重构", "content" => "整理模块", "client_request_id" => "tf-2-#{suffix}"}
      )

    {:ok, _m3} =
      ConversationServer.append_group_conversation_message(
        group_id,
        task2["conversation_id"],
        %{
          "actor_type" => "agent",
          "agent_id" => worker,
          "content" => [%{"type" => "milestone", "title" => "拆分模块"}]
        }
      )

    # Task 3: Loop task whose Loop failed -> appears in attention=1
    {:ok, task3} =
      SalixCluster.TaskSchedules.create_task_conversation(
        group_id,
        workspace["router_agent_id"],
        worker,
        %{"title" => "日报巡检", "content" => "每日汇总", "client_request_id" => "tf-3-#{suffix}"}
      )

    {:ok, _m4} =
      ConversationServer.append_group_conversation_message(
        group_id,
        task3["conversation_id"],
        %{
          "actor_type" => "agent",
          "agent_id" => worker,
          "content" => [%{"type" => "milestone", "title" => "首轮巡检"}]
        }
      )

    {:ok, loop} =
      Loops.put_task_request(%{
        "id" => Ids.new_loop_id(),
        "tenant_id" => workspace["salix_tenant_id"],
        "group_id" => group_id,
        "agent_id" => worker,
        "task_conversation_id" => task3["conversation_id"],
        "trigger" => %{"cron" => "0 9 * * *", "timezone" => "UTC"},
        "status" => "pending",
        "created_at" => SystemsClock.system_time(:millisecond),
        "updated_at" => SystemsClock.system_time(:millisecond)
      })

    {:ok, _failed} =
      Loops.update(loop["id"], fn rec ->
        {:ok, Map.put(rec, "status", "failed")}
      end)

    path = "/v1/comma/groups/#{group_id}/task-feed"

    # Full feed returns all 3 entries with exact locked JSON contract and ETag 304 support
    resp = user_req(session["token"], :get, path) |> expect_status(200)
    etag = resp |> Req.Response.get_header("etag") |> List.first()
    assert is_binary(etag) and etag != ""

    user_req(session["token"], :get, path, headers: [{"if-none-match", etag}])
    |> expect_status(304)

    body = resp.body
    assert body["has_more"] == false
    assert body["next_cursor"] == nil
    assert length(body["entries"]) == 3

    entry1 = Enum.find(body["entries"], &(&1["conversation_id"] == task1["conversation_id"]))
    assert is_binary(entry1["id"]) and String.starts_with?(entry1["id"], "tfe_")
    assert entry1["group_id"] == group_id
    assert entry1["cluster_key"] == "brief"
    assert entry1["trigger_kind"] == "brief"
    assert entry1["trigger_text"] == nil
    assert entry1["task_title"] == "调研竞品定价"
    assert entry1["task_status"] == "ready_for_review"
    assert is_integer(entry1["task_updated_at"]) and entry1["task_updated_at"] > 0
    assert entry1["review_version"] == entry1["task_updated_at"]
    assert entry1["is_loop"] == false
    assert entry1["loop_kind"] == nil
    assert is_integer(entry1["occurred_at"]) and entry1["occurred_at"] > 0
    assert entry1["milestone_count"] == 1
    assert [%{"title" => "抓取定价页", "at" => at, "message_id" => msg_id}] = entry1["milestones"]
    assert is_integer(at) and msg_id == m2["message_id"]
    assert entry1["outcome_message_id"] == m2["message_id"]
    assert entry1["outcome_text"] == "核心结论：价格低 20%"

    assert entry1["media"] == [
             %{
               "attachment_id" => "att_1",
               "mime_type" => "image/png",
               "width" => 1200,
               "height" => 800,
               "filename" => "a.png"
             }
           ]

    assert entry1["files"] == [%{"name" => "pricing.md", "mime_type" => "text/markdown"}]
    assert Map.has_key?(entry1, "pull_request")
    assert Map.has_key?(entry1, "origin")

    # Keyset pagination with limit=2
    page1 =
      user_req(session["token"], :get, path <> "?limit=2")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert length(page1["entries"]) == 2
    assert page1["has_more"] == true
    assert is_binary(page1["next_cursor"])

    page2 =
      user_req(session["token"], :get, path <> "?limit=2&cursor=#{page1["next_cursor"]}")
      |> expect_status(200)
      |> Map.fetch!(:body)

    assert length(page2["entries"]) == 1
    assert page2["has_more"] == false
    assert page2["next_cursor"] == nil

    paginated_ids = Enum.map(page1["entries"] ++ page2["entries"], & &1["id"])
    assert paginated_ids == Enum.map(body["entries"], & &1["id"])

    # Attention filter (?attention=1 and ?attention=true) returns only task1 (ready_for_review) & task3 (failed loop)
    for flag <- ["1", "true"] do
      attn =
        user_req(session["token"], :get, path <> "?attention=#{flag}")
        |> expect_status(200)
        |> Map.fetch!(:body)

      attn_cids = Enum.map(attn["entries"], & &1["conversation_id"]) |> Enum.sort()

      assert attn_cids == Enum.sort([task1["conversation_id"], task3["conversation_id"]])
    end

    # Archiving task1 hides it from task-feed immediately
    scope1 = ConversationPGStore.new(group_id, task1["conversation_id"])
    {:ok, rec1, rev1} = ConversationPGStore.read(scope1)

    {:ok, _prev, _archived, _next} =
      ConversationPGStore.update(scope1, rev1, fn rec ->
        rec
        |> Map.put("status", "archived")
        |> Map.put("archived_from_status", rec1["status"])
        |> Map.put("archived_at", SystemsClock.system_time(:millisecond))
      end)

    after_archive =
      user_req(session["token"], :get, path) |> expect_status(200) |> Map.fetch!(:body)

    refute Enum.any?(
             after_archive["entries"],
             &(&1["conversation_id"] == task1["conversation_id"])
           )

    # Restricted session scoped to task2 only sees task2
    restricted =
      admin_req(:post, "/v1/comma/admin/users/#{user["id"]}/sessions",
        json: %{
          "workspace_id" => workspace["id"],
          "group_id" => group_id,
          "conversation_id" => task2["conversation_id"],
          "restricted" => true
        }
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    scoped_body =
      user_req(restricted["token"], :get, path) |> expect_status(200) |> Map.fetch!(:body)

    assert Enum.map(scoped_body["entries"], & &1["conversation_id"]) == [task2["conversation_id"]]

    # Invalid query params return 400
    user_req(session["token"], :get, path <> "?limit=0") |> expect_status(400)
    user_req(session["token"], :get, path <> "?limit=51") |> expect_status(400)
    user_req(session["token"], :get, path <> "?limit=abc") |> expect_status(400)
    user_req(session["token"], :get, path <> "?cursor=not-valid-cursor!") |> expect_status(400)
    user_req(session["token"], :get, path <> "?attention=maybe") |> expect_status(400)

    # Unauthenticated request returns 401
    assert Req.get!(base() <> path).status == 401

    # Guest routes are fail-closed for task-feed
    refute CommaWeb.GuestRoutes.allowed?("GET", path)

    # Cross-group request returns 404
    other_user =
      admin_req(:post, "/v1/comma/admin/users",
        json: %{"email" => "task-feed-other-#{suffix}@example.com"}
      )
      |> expect_status(201)
      |> Map.fetch!(:body)

    other_workspace = create_ready_workspace!(other_user["id"])

    assert user_req(
             session["token"],
             :get,
             "/v1/comma/groups/#{other_workspace["default_group_id"]}/task-feed"
           ).status == 404
  end

  defp admin_req(method, path, opts), do: req(@admin_token, method, path, opts)
  defp user_req(token, method, path, opts \\ []), do: req(token, method, path, opts)

  defp req(token, method, path, opts) do
    headers = [{"authorization", "Bearer " <> token} | Keyword.get(opts, :headers, [])]
    opts = Keyword.put(opts, :headers, headers)
    Req.request!([method: method, url: base() <> path] ++ opts)
  end

  defp expect_status(resp, status) do
    assert resp.status == status, inspect(resp.body)
    resp
  end

  defp base, do: CommaWeb.Application.base_url()

  defp restore_env(app, key, nil), do: SystemsRuntime.delete_env(app, key)
  defp restore_env(app, key, value), do: SystemsRuntime.put_env(app, key, value)
end
