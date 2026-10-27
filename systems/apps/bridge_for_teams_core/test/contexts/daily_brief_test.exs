defmodule BridgeForTeams.DailyBriefTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Orgs, Projects, Repo}
  alias BridgeForTeams.Schema.DailyBriefRun

  @now ~U[2026-10-23 01:00:00.000000Z]

  setup do
    :ok = SystemsClock.manual(epoch: @now)
    on_exit(&SystemsClock.reset/0)
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Brief #{suffix}", "slug" => "brief-#{suffix}"})

    {:ok, user} =
      Accounts.create_user(%{"email" => "alice-#{suffix}@example.test", "name" => "alice"})

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Brief", "slug" => "brief-#{suffix}"},
        creator_user_id: user.id
      )

    {:ok, member} =
      DailyBrief.put_member(%{
        org_id: org.id,
        user_id: user.id,
        slack_workspace_id: "T1",
        slack_user_id: "UALICE#{suffix}"
      })

    %{org: org, project: project, member: member}
  end

  test "the hourly worker deletes briefs that outlived the organization's period", ctx do
    {:ok, _} =
      DailyBrief.put_settings(ctx.org.id, %{
        project_id: ctx.project.id,
        slack_connect_id: "imc_brief",
        retention_days: 7
      })

    old = brief(ctx)
    SystemsClock.advance(86_400_000)
    fresh = brief(ctx)

    # The hourly worker runs until just before day 8: day 0 is past 7 days,
    # day 1 is not.
    start_supervised!({BridgeForTeams.DailyBrief.Retention, interval_ms: 3_600_000})
    SystemsClock.await_timers()
    SystemsClock.advance(7 * 86_400_000 - 2 * 3_600_000)
    SystemsClock.settle(until: fn -> is_nil(Repo.get(DailyBriefRun, old.id)) end)

    assert Repo.get(DailyBriefRun, fresh.id)
  end

  defp brief(ctx) do
    now = SystemsClock.utc_now()

    Repo.insert!(%DailyBriefRun{
      org_id: ctx.org.id,
      project_id: ctx.project.id,
      member_id: ctx.member.id,
      kind: "personal_brief",
      window_after: DateTime.add(now, -86_400),
      window_before: now,
      status: "completed",
      notes: %{"brief" => "今天很安静。"}
    })
  end
end
