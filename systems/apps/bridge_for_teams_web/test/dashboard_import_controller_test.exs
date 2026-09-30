defmodule BridgeForTeamsWeb.DashboardImportControllerTest do
  use BridgeForTeamsWeb.DashboardCase, async: false

  import Ecto.Query

  alias BridgeForTeams.Auth
  alias BridgeForTeams.Auth.Sessions
  alias BridgeForTeams.CLI.Login, as: CLILogin
  alias BridgeForTeams.{Agents, Memberships, Repo, WorkspaceItems}
  alias BridgeForTeams.Schema.DashboardImportToken
  alias BridgeForTeamsWeb.DashboardEndpoint

  setup do
    %{user: user, org: org} = org_with_owner_fixture(org: %{slug: "acme", name: "Acme"})

    {:ok, project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Board",
        "slug" => "board"
      })

    [_agent | _] = Agents.list_agents(project.id)
    drain_reconcile!()

    token = cli_token(user, org)

    %{org: org, project: project, user: user, token: token}
  end

  defp cli_token(user, org) do
    {:ok, %{token: token, session: session}} = Sessions.create(user, device: "bft-cli")
    {:ok, _grants} = CLILogin.grant_cli_session_orgs(session, [org.id], user.id)
    token
  end

  defp drain_reconcile! do
    case BridgeForTeams.Salix.Reconciler.drain_once() do
      {:ok, 0} -> :ok
      {:ok, _count} -> drain_reconcile!()
    end
  end

  defp import_path(org, project), do: "/v1/orgs/#{org}/projects/#{project}/dashboard/import"

  defp document(items, extra \\ %{}) do
    Map.merge(%{"format" => "bft.myspace.import", "version" => 1, "items" => items}, extra)
  end

  defp post_import(path, token, body) do
    conn =
      :post
      |> build_conn(path, Jason.encode!(body))
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn

    DashboardEndpoint.call(conn, [])
  end

  test "401 when unauthenticated", %{org: org, project: project} do
    conn = post_import(import_path(org.slug, project.slug), nil, document([]))
    assert conn.status == 401
  end

  test "403 when the caller is not authorized for the org", %{org: org, project: project} do
    stranger = user_fixture(email: "stranger@example.com")
    # A CLI session with no grant for this org: the org-grant check denies it.
    {:ok, %{token: token}} = Sessions.create(stranger, device: "bft-cli")

    conn = post_import(import_path(org.slug, project.slug), token, document([]))
    assert conn.status == 403
  end

  test "happy path imports cards and returns counts", %{
    org: org,
    project: project,
    user: user,
    token: token
  } do
    body =
      document([
        %{
          "external_id" => "mock-1",
          "category" => "email_drafts",
          "title" => "Re: Q3 vendor renewal",
          "status" => "ready_for_review",
          "messages" => [
            %{"role" => "user", "text" => "Draft a reply"},
            %{"role" => "agent", "text" => "Done."}
          ]
        }
      ])

    conn = post_import(import_path(org.slug, project.slug), token, body)

    assert conn.status == 200
    assert %{"ok" => true, "data" => data} = Jason.decode!(conn.resp_body)
    assert data["mode"] == "dashboard_import"
    assert data["created"] == 1
    assert data["messages_appended"] == 2
    assert [%{"external_id" => "mock-1", "conversation_id" => conv_id}] = data["items"]
    assert is_binary(conv_id)

    [card] =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id)
      |> Enum.filter(&(&1.external_source == WorkspaceItems.mock_import_source()))

    assert card.source_refs["import_id"] == "mock-1"
  end

  test "422 for an invalid document", %{org: org, project: project, token: token} do
    body = document([%{"external_id" => "mock-1", "category" => "nope", "title" => "x"}])

    conn = post_import(import_path(org.slug, project.slug), token, body)

    assert conn.status == 422

    assert %{"ok" => false, "error" => %{"code" => "validation_failed", "details" => details}} =
             Jason.decode!(conn.resp_body)

    assert [%{"external_id" => "mock-1", "errors" => errors}] = details["errors"]
    assert "category is not allowed" in errors
  end

  test "user_email requires the caller to be an org owner/admin", %{org: org, project: project} do
    # Caller is only an org member but a project admin: passes project write,
    # but importing into another member's board needs org owner/admin.
    caller = user_fixture(email: "project-admin@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, caller.id, "member")
    {:ok, _} = Memberships.put_project_member(project.id, caller.id, "admin")
    token = cli_token(caller, org)

    other = user_fixture(email: "teammate@example.com")
    {:ok, _} = Memberships.put_org_member(org.id, other.id, "member")

    body =
      document([%{"external_id" => "m1", "category" => "general", "title" => "x"}], %{
        "user_email" => "teammate@example.com"
      })

    conn = post_import(import_path(org.slug, project.slug), token, body)
    assert conn.status == 403
    assert %{"ok" => false, "error" => %{"code" => "forbidden"}} = Jason.decode!(conn.resp_body)
  end

  test "imports with a valid import token and no CLI session", %{
    org: org,
    project: project,
    user: user
  } do
    {:ok, %{token: import_token}} = Auth.create_import_token(user, org, project)

    # The board legitimately contains projection-owned singleton rows while an
    # import runs. Keep that coexistence deterministic instead of depending on
    # the background projection worker winning a race in the full suite.
    assert {:ok, [_projection]} =
             WorkspaceItems.upsert_projected_items(project, user.id, [
               %{
                 "title" => "Workspace metrics",
                 "category" => "metrics",
                 "status" => "in_progress",
                 "source" => "projection",
                 "external_source" => "dashboard_projection",
                 "external_id" => "metrics"
               }
             ])

    body = document([%{"external_id" => "mock-1", "category" => "general", "title" => "Card"}])

    conn = post_import(import_path(org.slug, project.slug), import_token, body)

    assert conn.status == 200
    assert %{"ok" => true, "data" => %{"created" => 1}} = Jason.decode!(conn.resp_body)

    [card] =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id)
      |> Enum.filter(&(&1.external_source == WorkspaceItems.mock_import_source()))

    assert card.external_id == "mock-1"
  end

  test "403 when the import token is for a different project", %{
    org: org,
    project: project,
    user: user
  } do
    {:ok, other_project} =
      BridgeForTeams.TestSupport.CanonicalAgentClient.create_provisioned_project(org.id, %{
        "name" => "Other",
        "slug" => "other"
      })

    {:ok, %{token: import_token}} = Auth.create_import_token(user, org, other_project)

    conn = post_import(import_path(org.slug, project.slug), import_token, document([]))

    assert conn.status == 403
    assert %{"ok" => false, "error" => %{"code" => "forbidden"}} = Jason.decode!(conn.resp_body)
  end

  test "401 when the import token has expired", %{org: org, project: project, user: user} do
    {:ok, %{token: import_token, import_token: record}} =
      Auth.create_import_token(user, org, project)

    # Force expiry in the past.
    record
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -60, :second))
    |> Repo.update!()

    conn = post_import(import_path(org.slug, project.slug), import_token, document([]))
    assert conn.status == 401
  end

  test "the CLI-session path still works with no flag", %{
    org: org,
    project: project,
    user: user,
    token: token
  } do
    body = document([%{"external_id" => "cli-1", "category" => "general", "title" => "Card"}])

    conn = post_import(import_path(org.slug, project.slug), token, body)

    assert conn.status == 200
    assert %{"ok" => true, "data" => %{"created" => 1}} = Jason.decode!(conn.resp_body)

    [card] =
      user.id
      |> WorkspaceItems.list_tasks(project_id: project.id)
      |> Enum.filter(&(&1.external_source == WorkspaceItems.mock_import_source()))

    assert card.external_id == "cli-1"
  end

  test "the endpoint exists with no dashboard_import flag configured", %{
    org: org,
    project: project,
    token: token
  } do
    refute Application.get_env(:bridge_for_teams_web, :dashboard_import)

    conn = post_import(import_path(org.slug, project.slug), token, document([]))
    # Not a 404: the route is always mounted now that the gate is gone.
    assert conn.status == 200
  end

  test "revoked import tokens (single active per user+project) are rejected", %{
    org: org,
    project: project,
    user: user
  } do
    {:ok, %{token: first_token}} = Auth.create_import_token(user, org, project)
    # Minting again revokes the first token.
    {:ok, %{token: _second_token}} = Auth.create_import_token(user, org, project)

    assert Repo.aggregate(
             from(t in DashboardImportToken,
               where:
                 t.user_id == ^user.id and t.project_id == ^project.id and is_nil(t.revoked_at)
             ),
             :count,
             :id
           ) == 1

    conn = post_import(import_path(org.slug, project.slug), first_token, document([]))
    assert conn.status == 401
  end
end
