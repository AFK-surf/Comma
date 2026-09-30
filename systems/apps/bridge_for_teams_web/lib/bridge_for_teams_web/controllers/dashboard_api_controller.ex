defmodule BridgeForTeamsWeb.DashboardAPIController do
  @moduledoc """
  JSON API for the React dashboard (`clients/apps/bft`).

  The SPA is served same-origin, so these endpoints use the browser session
  (`:dashboard_api` pipeline). Every org-scoped action resolves the org and the
  caller's membership first. A caller who is not a member gets the same 404 as
  an unknown slug, so the endpoint does not reveal which orgs exist.
  """
  use BridgeForTeamsWeb.Dashboard, :controller
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  import BridgeForTeamsWeb.ProjectAPIResponse, only: [send_ok: 2, send_error: 5]

  alias BridgeForTeams.{Analytics, Environments, Memberships, Orgs, Projects}

  @admin_roles ~w(owner admin)

  def session(conn, _params) do
    user = conn.assigns.current_user
    send_ok(conn, %{"user" => public_user(user), "orgs" => public_orgs(user)})
  end

  def context(conn, %{"org" => slug}) do
    user = conn.assigns.current_user

    with {:ok, org, role} <- member_org(slug, user) do
      admin? = role in @admin_roles

      send_ok(conn, %{
        "user" => public_user(user),
        "orgs" => public_orgs(user),
        "org" => %{"slug" => org.slug, "name" => org.name, "role" => role},
        "capabilities" => %{
          "operations" => admin?,
          "triage" => admin?,
          "information_flow" => admin?,
          "meetings" => admin?,
          "settings" => admin?
        },
        "projects" =>
          org.id
          |> Projects.list_projects_for_user(user.id)
          |> Enum.map(&%{"id" => &1.id, "name" => &1.name})
      })
    else
      :not_found -> org_not_found(conn)
    end
  end

  def overview(conn, %{"org" => slug}) do
    user = conn.assigns.current_user

    with {:ok, org, _role} <- member_org(slug, user) do
      summary = Analytics.org_home_summary(org.id, user.id)
      runners = Environments.mac_mini_health_summary(org.id)
      projects = Enum.map(summary.project_usage_rows, &public_project_usage/1)

      send_ok(conn, %{
        "project_count" => summary.project_count,
        "used_project_count" => summary.used_project_count,
        "conversation_count" => summary.conversation_count,
        "token_totals" => summary.token_totals,
        "member_count" => Memberships.count_org_members(org.id),
        "runners" => %{"total" => runners.total, "online" => runners.online},
        "projects" => projects,
        "attention" => attention(org, summary.project_usage_rows, runners.unhealthy)
      })
    else
      :not_found -> org_not_found(conn)
    end
  end

  defp member_org(slug, user) do
    with {:ok, org} <- Orgs.get_org_by_slug(slug),
         {:ok, role} <- Memberships.org_role(org.id, user.id) do
      {:ok, org, role}
    else
      _ -> :not_found
    end
  end

  defp attention(org, usage_rows, runners) do
    failed_snapshots =
      for %{snapshot_status: :error} = row <- usage_rows do
        %{
          "id" => "usage-refresh-#{row.project_id}",
          "severity" => "warning",
          "title" => gettext("Usage for %{name} could not be refreshed", name: row.name),
          "detail" => gettext("The numbers shown may be out of date."),
          "href" => "/orgs/#{org.slug}/projects/#{row.project_id}"
        }
      end

    unhealthy_runners =
      for runner <- runners do
        %{
          "id" => "runner-#{runner.id}",
          "severity" => if(runner.effective_status == "offline", do: "error", else: "warning"),
          "title" => runner_title(runner),
          "detail" => gettext("Agents that run on it cannot start new work."),
          "href" => "/orgs/#{org.slug}/fin"
        }
      end

    unhealthy_runners ++ failed_snapshots
  end

  defp runner_title(%{effective_status: "degraded", name: name}),
    do: gettext("Runner %{name} is degraded", name: name)

  defp runner_title(%{name: name}), do: gettext("Runner %{name} is offline", name: name)

  defp public_project_usage(row) do
    %{
      "id" => row.project_id,
      "name" => row.name,
      "conversation_count" => row.conversation_count,
      "token_total" => row.token_usage.total,
      "status" => Atom.to_string(row.snapshot_status),
      "refreshed_at" => Map.get(row, :refreshed_at)
    }
  end

  defp public_user(user), do: %{"id" => user.id, "name" => user.name, "email" => user.email}

  defp public_orgs(user) do
    user.id
    |> Orgs.list_orgs_for_user()
    |> Enum.map(&%{"slug" => &1.slug, "name" => &1.name})
  end

  defp org_not_found(conn),
    do: send_error(conn, 404, "org_not_found", gettext("Organization not found."), %{})
end
