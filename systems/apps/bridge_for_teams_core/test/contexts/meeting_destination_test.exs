defmodule BridgeForTeams.MeetingDestinationTest do
  use BridgeForTeams.DataCase, async: false

  alias BridgeForTeams.{Accounts, DailyBrief, MeetingDestination, Memberships, Orgs, Projects}

  # Salix: one Slack bot and two Lark bots; records each call.
  defmodule FakeSalix do
    def meeting_preparation(%{"action" => action} = request) do
      SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:salix, action, request})

      {:ok,
       %{
         "status" => if(action == "set_destination", do: "confirmed", else: "choice_needed"),
         "current" => nil,
         "options" => [
           %{"platform" => "slack", "connect_id" => "imc_slack", "name" => "Comma"},
           %{"platform" => "lark", "connect_id" => "imc_lark_a", "name" => "Bot A"},
           %{"platform" => "lark", "connect_id" => "imc_lark_b", "name" => "Bot B"}
         ]
       }}
    end
  end

  setup do
    previous = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, FakeSalix)
    on_exit(fn -> SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous) end)

    suffix = SystemsRuntime.Proc.unique_integer([:positive])
    group = "grp-dest-#{suffix}"
    {:ok, org} = Orgs.create_org(%{"name" => "Dest #{suffix}", "slug" => "dest-#{suffix}"})

    users =
      for {name, role} <- [{"ada", "admin"}, {"bo", "member"}] do
        {:ok, user} =
          Accounts.create_user(%{
            "email" => "#{name}-dest-#{suffix}@example.test",
            "name" => name
          })

        {:ok, _} = Memberships.put_org_member(org.id, user.id, role)

        {:ok, _member} =
          DailyBrief.put_member(%{
            org_id: org.id,
            user_id: user.id,
            slack_workspace_id: "T1",
            slack_user_id: "U#{String.upcase(name)}1",
            timezone: "Asia/Shanghai",
            deliver_at: ~T[09:00:00]
          })

        user
      end

    {:ok, project} =
      Projects.create_project(org.id, %{"name" => "Dest", "slug" => "dest-#{suffix}"},
        creator_user_id: hd(users).id
      )

    Repo.update_all(from(p in BridgeForTeams.Schema.Project, where: p.id == ^project.id),
      set: [salix_group_id: group]
    )

    %{group: group, org: org, users: users}
  end

  test "an organization admin sets the destination; the only bot of a platform is picked", ctx do
    assert {:ok, %{"status" => "confirmed"}} =
             MeetingDestination.set_destination(
               ctx.group,
               origin(ctx.group, "UADA1"),
               "slack",
               nil,
               "C42"
             )

    assert_received {:salix, "destination", _}

    assert_received {:salix, "set_destination",
                     %{"attrs" => %{"connect_id" => "imc_slack", "channel_id" => "C42"}}}
  end

  test "a platform with several bots needs a choice, and nothing is set", ctx do
    assert {:ok, %{"status" => "choice_needed", "options" => [_, _]}} =
             MeetingDestination.set_destination(
               ctx.group,
               origin(ctx.group, "UADA1"),
               "lark",
               nil,
               nil
             )

    refute_received {:salix, "set_destination", _}

    assert {:ok, %{"status" => "confirmed"}} =
             MeetingDestination.set_destination(
               ctx.group,
               origin(ctx.group, "UADA1"),
               "lark",
               "imc_lark_b",
               nil
             )

    assert_received {:salix, "set_destination", %{"attrs" => %{"connect_id" => "imc_lark_b"}}}
  end

  test "a member who is no admin, or a person with no binding, may read but not set", ctx do
    for user <- ["UBO1", "UNOBODY"] do
      assert {:error, :admin_required} =
               MeetingDestination.set_destination(
                 ctx.group,
                 origin(ctx.group, user),
                 "lark",
                 "imc_lark_a",
                 nil
               )

      assert {:ok, %{"status" => "choice_needed"}} =
               MeetingDestination.get_destination(ctx.group, origin(ctx.group, user))
    end

    refute_received {:salix, "set_destination", _}
  end

  test "a request signed for another Group reads nothing", ctx do
    assert {:error, :meeting_settings_requires_provider_request} =
             MeetingDestination.get_destination(ctx.group, origin("grp-other", "UADA1"))
  end

  test "a Lark sender signed in to the organization as its admin sets the destination", ctx do
    alias BridgeForTeams.Schema.{OrgSsoConnection, OrgSsoIdentity}

    {:ok, _} =
      Repo.insert(
        OrgSsoConnection.changeset(%OrgSsoConnection{}, %{
          org_id: ctx.org.id,
          provider: "lark",
          client_id: "cli_dest",
          client_secret: "secret"
        })
      )

    for {user, open_id} <- Enum.zip(ctx.users, ["ou_ada", "ou_bo"]) do
      {:ok, _} =
        Repo.insert(
          OrgSsoIdentity.changeset(%OrgSsoIdentity{}, %{
            org_id: ctx.org.id,
            user_id: user.id,
            provider: "lark",
            provider_subject_type: "open_id",
            provider_subject: open_id
          })
        )
    end

    {:ok, _} =
      SalixStore.CasRecord.create(SalixStore.Keys.ctl_im_connect(ctx.group, "imc_lark_a"), %{
        "tenant_id" => ctx.org.salix_tenant_id,
        "group_id" => ctx.group,
        "connect_id" => "imc_lark_a",
        "provider" => "lark",
        "app_id" => "cli_dest",
        "status" => "connected"
      })

    # A member who is no admin, and a sender nobody signed in as, may not.
    for open_id <- ["ou_bo", "ou_nobody"] do
      assert {:error, :admin_required} =
               MeetingDestination.set_destination(
                 ctx.group,
                 lark_origin(ctx.group, open_id),
                 "lark",
                 "imc_lark_a",
                 "oc_team"
               )
    end

    refute_received {:salix, "set_destination", _}

    assert {:ok, %{"status" => "confirmed"}} =
             MeetingDestination.set_destination(
               ctx.group,
               lark_origin(ctx.group, "ou_ada"),
               "lark",
               "imc_lark_a",
               "oc_team"
             )

    assert_received {:salix, "set_destination",
                     %{"attrs" => %{"connect_id" => "imc_lark_a", "channel_id" => "oc_team"}}}
  end

  defp lark_origin(group, open_id) do
    %{
      "provider" => "lark",
      "source_actor_type" => "provider_user",
      "agent_group_id" => group,
      "provider_context" => %{"sender_open_id" => open_id, "connect_id" => "imc_lark_a"}
    }
  end

  defp origin(group, user_id) do
    %{
      "provider" => "slack",
      "source_actor_type" => "provider_user",
      "agent_group_id" => group,
      "provider_context" => %{
        "user_id" => user_id,
        "connect_id" => "imc_slack",
        "workspace_id" => "T1"
      }
    }
  end
end
