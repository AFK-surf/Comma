defmodule BridgeForTeamsWeb.DashboardProjects do
  @moduledoc """
  Builds the Agent Swarms page payload and creates Agent Swarms for
  `DashboardAPIController`.

  The list holds the Agent Swarms the caller can see (all of them for owners
  and admins, the granted ones for members), one page of 50 by name, filtered
  in the same query. A page costs a fixed number of queries however many Agent
  Swarms the org has; more pages load as the reader scrolls.

  Owners and admins create freely; an ordinary member creates one Agent Swarm
  per org (`Projects.can_create_project?/2`). A refused create records a denied
  audit entry, as the LiveView page did.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.Projects
  alias BridgeForTeamsWeb.Dashboard.CoreComponents

  @doc "One page of Agent Swarms and whether the caller may create one."
  def page(org, user, params) do
    page =
      Projects.page_projects_for_user(org.id, user.id,
        query: params["query"],
        after: params["cursor"]
      )

    %{
      "viewer" => %{"can_create" => Projects.can_create_project?(org.id, user.id)},
      "projects" => Enum.map(page.entries, &public_project/1),
      "next_cursor" => page.next_cursor
    }
  end

  @doc "Create an Agent Swarm from `name` and `slug`; a blank slug follows the name."
  def create(org, user, params) do
    attrs = Map.take(params, ~w(name slug))

    if Projects.can_create_project?(org.id, user.id) do
      case Projects.create_project(org.id, attrs,
             creator_user_id: user.id,
             actor_label: actor_label(user)
           ) do
        {:ok, project} ->
          {:ok, public_project(project)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, 422, "invalid_project", gettext("Couldn't create the Agent Swarm."),
           %{
             "fields" =>
               Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
           }}

        {:error, :project_quota_reached} ->
          quota_reached()

        {:error, _reason} ->
          {:error, 500, "write_failed",
           gettext("Could not create the Agent Swarm. Please try again."), %{}}
      end
    else
      _ =
        Projects.record_project_write_attempt(
          {:org, org.id},
          "project.created",
          "denied",
          :project_quota_reached,
          [actor_user_id: user.id, actor_label: actor_label(user)],
          metadata: %{
            "attempted_name_configured" => present?(attrs["name"]),
            "attempted_slug_configured" => present?(attrs["slug"]),
            "surface" => "project_index"
          }
        )

      quota_reached()
    end
  end

  # Every caller here is an org member, so the only refusal is an ordinary
  # member whose one Agent Swarm already exists.
  defp quota_reached,
    do:
      {:error, 403, "project_quota_reached",
       gettext("Org members can create only one Agent Swarm; you have already created yours."),
       %{}}

  defp public_project(project) do
    %{
      "id" => project.id,
      "name" => project.name,
      "slug" => project.slug,
      "salix_group_id" => project.salix_group_id,
      "status" => project.status,
      "created_at" => project.created_at
    }
  end

  defp actor_label(user) do
    cond do
      present?(user.email) -> String.trim(user.email)
      present?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
