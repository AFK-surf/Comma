defmodule CommaWeb.TaskEndedAnalyticsTest do
  use SystemsClock.Case, async: false

  import Ecto.Query
  alias Comma.{Accounts, Repo}
  alias Comma.Data.Workspace
  alias CommaWeb.TaskEndedAnalytics
  alias SalixStore.Ids

  setup do
    owner = CommaWeb.TestRepoSandbox.start_owner!(:transaction)
    SalixAgent.TestSupport.configure_control_fixtures!()
    tenant = SalixAgent.TestSupport.new_tenant_id()
    group = Ids.new_group_id(tenant)
    SalixAgent.TestSupport.create_control_group!(group, %{"name" => "Task analytics"})
    on_exit(fn -> CommaWeb.TestRepoSandbox.stop_owner(owner) end)

    {:ok, user} =
      Accounts.create_user(%{
        "email" => "task-ended-#{SystemsRuntime.Proc.unique_integer([:positive])}@example.test"
      })

    workspace =
      Repo.insert!(%Workspace{
        id: "wsp_task_ended_#{SystemsRuntime.Proc.unique_integer([:positive])}",
        owner_user_id: user["id"],
        salix_tenant_id: tenant,
        salix_group_id: group,
        group_generation: "task-ended-test",
        salix_router_agent_id: Ids.new_agent_id(group),
        salix_worker_agent_id: Ids.new_agent_id(group),
        billing_owner_id: "task-ended-test",
        name: "Task analytics",
        status: "active"
      })

    Comma.AnalyticsTestSupport.setup_collector()
    |> Map.merge(%{tenant: tenant, group: group, user: user, workspace: workspace})
  end

  test "a coding Task's end is one event of its kinds and counts, without its repository",
       ctx do
    task = Ids.new_conversation_id()
    repo = %{"owner" => "acme", "name" => "secret-api", "branch" => "comma/secret"}

    {:ok, _workload} =
      SalixStore.CodingSandboxes.create(%{
        tenant_id: ctx.tenant,
        group_id: ctx.group,
        conversation_id: task,
        workspace: "comma:" <> ctx.group,
        repo: repo
      })

    SalixWeb.CodingSandboxes.remember(
      ctx.tenant,
      task,
      %{
        "usage" =>
          {:ok,
           %{
             "modelCalls" => 7,
             "inputTokens" => 12_000,
             "cachedTokens" => 9_000,
             "outputTokens" => 800,
             "model" => "gpt-5.5-codex"
           }},
        "changes" => {:ok, %{"files" => 2, "additions" => 12, "deletions" => 1}},
        "pull_request" =>
          {:ok, %{"state" => "merged", "title" => "Secret title", "url" => "https://x/pull/1"}}
      },
      SystemsClock.utc_now()
    )

    created_at = SystemsClock.system_time(:millisecond) - 90_000

    snapshot = %{
      "agent_group_id" => ctx.group,
      "conversation_id" => task,
      "title" => "Private title",
      "status" => "completed",
      "owner_user_id" => ctx.user["id"],
      "provider_status_version" => 4,
      "created_at" => created_at,
      "runs_on" => %{"kind" => "sandbox", "device_id" => "dev-sbx-" <> task},
      "repo" => repo
    }

    # Salix publishes the same status again after later Messages: one job.
    assert :ok = TaskEndedAnalytics.observe(snapshot)
    assert :ok = TaskEndedAnalytics.observe(snapshot)
    assert [job] = jobs()
    refute Jason.encode!(job.args) =~ "secret"
    assert job.args["task_kind"] == "coding"

    assert :ok = TaskEndedAnalytics.perform(job)
    assert [event] = Comma.AnalyticsTestSupport.collect(ctx.analytics_worker)

    assert event["event"] == "comma_task_ended"
    assert event["distinct_id"] == ctx.user["id"]
    ended_at = job.args["ended_at"]
    assert event["timestamp"] == DateTime.to_iso8601(DateTime.from_unix!(ended_at, :millisecond))

    assert %{
             "workspace_id" => workspace_id,
             "conversation_id" => ^task,
             "status" => "completed",
             "task_kind" => "coding",
             "duration_ms" => duration,
             "model_calls" => 7,
             "input_tokens" => 12_000,
             "cached_tokens" => 9_000,
             "output_tokens" => 800,
             "model" => "gpt-5.5-codex",
             "files_changed" => 2,
             "lines_added" => 12,
             "lines_deleted" => 1,
             "pull_request_state" => "merged"
           } = event["properties"]

    assert workspace_id == ctx.workspace.id
    assert duration == ended_at - created_at
    encoded = Jason.encode!(event)
    refute encoded =~ "secret"
    refute encoded =~ "Private title"
    refute encoded =~ "Secret title"

    # A new status version is a new end, such as after the Task was reopened.
    assert :ok = TaskEndedAnalytics.observe(%{snapshot | "provider_status_version" => 6})
    assert length(jobs()) == 2
  end

  test "a cloud Task's end has no sandbox facts; open and other products' Tasks queue nothing",
       ctx do
    task = Ids.new_conversation_id()

    snapshot = %{
      "agent_group_id" => ctx.group,
      "conversation_id" => task,
      "status" => "failed",
      "owner_user_id" => ctx.user["id"],
      "provider_status_version" => 2,
      "created_at" => SystemsClock.system_time(:millisecond)
    }

    assert :ok = TaskEndedAnalytics.observe(%{snapshot | "status" => "in_progress"})
    assert :ok = TaskEndedAnalytics.observe(Map.delete(snapshot, "owner_user_id"))
    assert jobs() == []

    assert :ok = TaskEndedAnalytics.observe(snapshot)
    assert [job] = jobs()
    assert :ok = TaskEndedAnalytics.perform(job)
    assert [event] = Comma.AnalyticsTestSupport.collect(ctx.analytics_worker)

    assert Map.take(event["properties"], ~w(status task_kind)) == %{
             "status" => "failed",
             "task_kind" => "cloud"
           }

    refute Map.has_key?(event["properties"], "input_tokens")

    other_group = Ids.new_group_id(ctx.tenant)
    assert :ok = TaskEndedAnalytics.observe(%{snapshot | "agent_group_id" => other_group})
    other = Enum.find(jobs(), &(&1.args["group_id"] == other_group))
    assert :ok = TaskEndedAnalytics.perform(other)
    # Nothing was queued: the queue holds only its sequence and drop counters.
    assert :ets.info(Comma.Analytics.Worker, :size) == 2
  end

  defp jobs do
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == "CommaWeb.TaskEndedAnalytics",
        order_by: job.id
      )
    )
  end
end
