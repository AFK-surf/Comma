defmodule BridgeForTeams.DailyBriefChatSettingsTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, Memberships, Orgs, Projects, Repo}
  alias BridgeForTeams.DailyBrief.{ChatSettings, Delivery}
  alias BridgeForTeams.Schema.DailyBriefMember

  setup do
    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    group = "grp-chat-#{suffix}"
    {:ok, org} = Orgs.create_org(%{"name" => "Chat #{suffix}", "slug" => "brief-chat-#{suffix}"})

    [admin, member] =
      for {name, role} <- [{"ada", "admin"}, {"bo", "member"}] do
        {:ok, user} =
          Accounts.create_user(%{
            "email" => "#{name}-chat-#{suffix}@example.test",
            "name" => name
          })

        {:ok, _} = Memberships.put_org_member(org.id, user.id, role)

        {:ok, member} =
          DailyBrief.put_member(%{
            org_id: org.id,
            user_id: user.id,
            slack_workspace_id: "T1",
            slack_user_id: "U#{String.upcase(name)}1",
            timezone: "Asia/Shanghai",
            deliver_at: ~T[09:00:00]
          })

        member
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Chat", "slug" => "brief-chat-#{suffix}"},
        creator_user_id: admin.user_id
      )

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
      set: [salix_group_id: group]
    )

    {:ok, settings} =
      DailyBrief.put_settings(org.id, %{
        project_id: project.id,
        slack_connect_id: "imc_chat",
        enabled: true
      })

    %{group: group, settings: settings, admin: admin, member: member}
  end

  test "a member moves their own brief", ctx do
    assert {:ok, %{"brief" => "mine", "time" => "08:30", "timezone" => "Asia/Shanghai"}} =
             ChatSettings.set_time(ctx.group, origin(ctx.group, "UBO1"), "mine", "08:30")

    assert Repo.get!(DailyBriefMember, ctx.member.id).deliver_at == ~T[08:30:00]
    assert Repo.get!(DailyBriefMember, ctx.admin.id).deliver_at == ~T[09:00:00]
  end

  test "only an owner or admin moves the team brief", ctx do
    assert {:error, :owner_or_admin_required} =
             ChatSettings.set_time(ctx.group, origin(ctx.group, "UBO1"), "team", "10:00")

    assert {:ok, %{"brief" => "team", "time" => "10:00"}} =
             ChatSettings.set_time(ctx.group, origin(ctx.group, "UADA1"), "team", "10:00")

    assert DailyBrief.get_settings(ctx.settings.org_id).team_post_at == ~T[10:00:00]
  end

  test "the requester comes from the signed Slack origin of this Swarm only", ctx do
    assert {:error, :daily_brief_requires_slack_request} =
             ChatSettings.set_time(ctx.group, origin("grp-other", "UADA1"), "team", "10:00")

    assert {:error, :daily_brief_requires_slack_request} =
             ChatSettings.set_time(
               ctx.group,
               %{origin(ctx.group, "UADA1") | "source_actor_type" => "agent"},
               "team",
               "10:00"
             )

    assert {:error, :not_a_brief_member} =
             ChatSettings.set_time(ctx.group, origin(ctx.group, "UNOBODY1"), "mine", "08:00")

    assert {:error, :invalid_time} =
             ChatSettings.set_time(ctx.group, origin(ctx.group, "UBO1"), "mine", "25:00")

    # Only through the bot that sends the brief, and in its Slack workspace.
    other_bot =
      put_in(origin(ctx.group, "UADA1"), ["provider_context", "connect_id"], "imc_other")

    assert {:error, :daily_brief_not_set_up} =
             ChatSettings.set_time(ctx.group, other_bot, "team", "10:00")

    other_workspace =
      put_in(origin(ctx.group, "UADA1"), ["provider_context", "workspace_id"], "T2")

    assert {:error, :not_a_brief_member} =
             ChatSettings.set_time(ctx.group, other_workspace, "team", "10:00")
  end

  test "a brief already sent today is not sent again at the later time", ctx do
    # 10:00 in Shanghai; today's 09:00 brief went out.
    :ok = SystemsClock.manual(epoch: ~U[2026-10-23 02:00:00.000000Z])
    on_exit(&SystemsClock.reset/0)

    {:ok, _} =
      ctx.member
      |> Ecto.Changeset.change(brief_claimed_at: ~U[2026-10-23 01:00:00.000000Z])
      |> Repo.update()

    {:ok, _} = ChatSettings.set_time(ctx.group, origin(ctx.group, "UBO1"), "mine", "11:00")
    member = Repo.get!(DailyBriefMember, ctx.member.id)

    refute Delivery.due?(ctx.settings, member, ~U[2026-10-23 03:00:01.000000Z])
    assert Delivery.due?(ctx.settings, member, ~U[2026-10-26 03:00:01.000000Z])
  end

  defp origin(group, user_id),
    do: %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "agent_group_id" => group,
      "provider_context" => %{
        "connect_id" => "imc_chat",
        "workspace_id" => "T1",
        "user_id" => user_id
      }
    }
end
