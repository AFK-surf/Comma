defmodule BridgeForTeams.DailyBriefDashboardTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{Dashboard, Delivery}
  alias BridgeForTeams.Schema.DailyBriefRun

  # 10:00 in Shanghai.
  # A Thursday, so the next day is a workday too.
  @now ~U[2026-10-22 02:00:00.000000Z]

  setup do
    :ok = SystemsClock.manual(epoch: @now)
    on_exit(&SystemsClock.reset/0)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    {:ok, org} = Orgs.create_org(%{"name" => "Dash #{suffix}", "slug" => "brief-dash-#{suffix}"})

    [alice, bob] =
      for {name, at} <- [{"alice", ~T[09:00:00]}, {"bob", ~T[11:30:00]}] do
        {:ok, user} =
          Accounts.create_user(%{
            "email" => "#{name}-dash-#{suffix}@example.test",
            "name" => name
          })

        {:ok, _} = Memberships.put_org_member(org.id, user.id, "member")

        {:ok, member} =
          DailyBrief.put_member(%{
            org_id: org.id,
            user_id: user.id,
            slack_workspace_id: "T1",
            slack_user_id: "U#{String.upcase(name)}1",
            timezone: "Asia/Shanghai",
            deliver_at: at
          })

        member
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Dash", "slug" => "brief-dash-#{suffix}"},
        creator_user_id: alice.user_id
      )

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        slack_connect_id: "imc_dash",
        enabled: true
      })

    %{settings: settings, alice: alice, bob: bob}
  end

  test "today and runs show states and codes, never a provider's text", ctx do
    run(ctx, "team_brief", nil, "completed", input_tokens: 900, output_tokens: 100)
    run(ctx, "personal_brief", ctx.alice, "completed")

    run(ctx, "personal_brief", ctx.bob, "failed", error: ~s({:model_error, "客户 A 的报价是 3 万"}))

    today = Dashboard.today(ctx.settings, @now)
    assert %{"status" => "completed"} = today["team_pass"]
    assert %{"sent" => 1, "failed" => 1, "pending" => 0, "members" => 2} = today
    # Bob's 11:30 in Shanghai comes before Alice's next 09:00.
    assert today["next_brief_at"] == ~U[2026-10-22 03:30:00Z]
    # From Friday noon, the next brief is Monday's; with Monday off, Tuesday's.
    friday = Dashboard.today(ctx.settings, ~U[2026-10-23 04:00:00Z])
    assert friday["next_brief_at"] == ~U[2026-10-26 01:00:00Z]
    off = %{ctx.settings | off_days: [~D[2026-10-26]]}

    assert Dashboard.today(off, ~U[2026-10-23 04:00:00Z])["next_brief_at"] ==
             ~U[2026-10-27 01:00:00Z]

    runs = Dashboard.runs(ctx.settings)
    assert length(runs) == 3
    failed = Enum.find(runs, &(&1["status"] == "failed"))
    assert failed["error"] == "model_error"
    assert failed["retryable"]
    assert failed["member"] == "bob"
    refute inspect(runs) =~ "报价"
  end

  test "a request sends one brief now and keeps the member's next time", ctx do
    # Alice's brief went out at 09:00 today.
    {:ok, alice} =
      ctx.alice
      |> Ecto.Changeset.change(brief_claimed_at: DateTime.add(@now, -3_600))
      |> Repo.update()

    claimed = fn at -> Enum.map(Delivery.claim_due(at, 5), fn {_, m} -> m.id end) end
    refute alice.id in claimed.(@now)

    {:ok, _} = Delivery.request(alice, @now)
    assert alice.id in claimed.(@now)
    refute alice.id in claimed.(@now)

    # Tomorrow's 09:00 brief is still due at 09:00.
    assert alice.id in claimed.(DateTime.add(@now, 23 * 3_600))
  end

  test "a requested brief Slack did not take is tried again without moving the next", ctx do
    {:ok, alice} =
      ctx.alice
      |> Ecto.Changeset.change(brief_claimed_at: DateTime.add(@now, -3_600))
      |> Repo.update()

    claimed = fn at -> Enum.map(Delivery.claim_due(at, 5), fn {_, m} -> m.id end) end
    {:ok, _} = Delivery.request(alice, @now)
    assert [{_, claimed_alice}] = Delivery.claim_due(@now, 5)
    Delivery.release_claim(ctx.settings, claimed_alice, @now)

    refute alice.id in claimed.(DateTime.add(@now, 1_800))
    assert alice.id in claimed.(DateTime.add(@now, 3_660))
    refute alice.id in claimed.(DateTime.add(@now, 20 * 3_600))
    assert alice.id in claimed.(DateTime.add(@now, 23 * 3_600))
  end

  test "a request is not held back by members whose time has not come", ctx do
    # Ten members claimed yesterday, due again only at 11:30.
    for index <- 1..10 do
      {:ok, user} =
        Accounts.create_user(%{"email" => "late-#{index}-#{ctx.alice.id}@example.test"})

      {:ok, member} =
        DailyBrief.put_member(%{
          org_id: ctx.settings.org_id,
          user_id: user.id,
          slack_workspace_id: "T1",
          slack_user_id: "ULATE#{index}",
          timezone: "Asia/Shanghai",
          deliver_at: ~T[11:30:00]
        })

      member
      |> Ecto.Changeset.change(brief_claimed_at: DateTime.add(@now, -21 * 3_600))
      |> Repo.update!()
    end

    {:ok, alice} =
      ctx.alice
      |> Ecto.Changeset.change(brief_claimed_at: DateTime.add(@now, -3_600))
      |> Repo.update()

    {:ok, _} = Delivery.request(alice, @now)
    assert [{_, %{id: id}}] = Delivery.claim_due(@now, 1)
    assert id == alice.id
  end

  defp run(ctx, kind, member, status, attrs \\ []) do
    Repo.insert!(
      struct(
        %DailyBriefRun{
          org_id: ctx.settings.org_id,
          project_id: ctx.settings.project_id,
          member_id: member && member.id,
          kind: kind,
          window_after: DateTime.add(@now, -86_400),
          window_before: @now,
          status: status
        },
        attrs
      )
    )
  end
end
