defmodule BridgeForTeamsWeb.Dashboard.SalixConversationControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  alias BridgeForTeams.Projects

  defmodule ResolveSalixClient do
    @moduledoc false

    def get_group_conversation(_group_id, "task-123"),
      do: {:ok, %{"conversation_id" => "task-123"}}

    def get_group_conversation(_group_id, _conversation_id), do: {:error, :not_found}
  end

  setup %{conn: conn} do
    previous_client = Application.get_env(:bridge_for_teams_core, :salix_client)

    on_exit(fn ->
      if previous_client do
        Application.put_env(:bridge_for_teams_core, :salix_client, previous_client)
      else
        Application.delete_env(:bridge_for_teams_core, :salix_client)
      end
    end)

    Application.put_env(:bridge_for_teams_core, :salix_client, ResolveSalixClient)

    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})
    {:ok, project} = Projects.create_project(org.id, %{"name" => "Support", "slug" => "support"})

    %{conn: log_in_user(conn, user), org: org, project: project}
  end

  test "resolves task link identities to the BFT task page", %{
    conn: conn,
    org: org,
    project: project
  } do
    conn =
      get(
        conn,
        "/tasks/#{org.salix_tenant_id}/#{project.salix_group_id}/task-123"
      )

    assert redirected_to(conn) ==
             "/orgs/#{org.slug}/projects/#{project.id}/tasks/task-123"
  end
end
