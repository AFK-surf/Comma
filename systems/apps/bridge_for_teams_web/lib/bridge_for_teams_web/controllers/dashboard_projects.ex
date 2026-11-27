defmodule BridgeForTeamsWeb.DashboardProjects do
  @moduledoc """
  Builds the Agent Swarms page payload and manages organization departments and
  Agent Swarm creation for `DashboardAPIController`.

  The list holds the Agent Swarms the caller can see (all of them for owners
  and admins, the granted ones for members), one page of 50 grouped by
  department (departments by name, then Swarms without one), filtered in the
  same query. `department_counts` and `unassigned_count` count every matching
  Swarm of each group, also those on later pages. Organization owners and admins also receive the full
  department and active-Swarm catalog so they can group Swarms into departments
  and configure cross-Swarm conversation search grants.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{Departments, InformationFlow, Projects}
  alias BridgeForTeamsWeb.Dashboard.CoreComponents

  @admin_org_roles ~w(owner admin)

  @doc "One page of Agent Swarms, department rows, and viewer capabilities."
  def page(org, user, params, org_role \\ "member") do
    can_manage = org_role in @admin_org_roles

    page =
      Projects.page_projects_for_user(org.id, user.id,
        query: params["query"],
        after: params["cursor"]
      )

    departments = Departments.list_departments(org.id)
    dept_by_id = Map.new(departments, &{&1.id, &1})

    counts = %{
      "department_counts" => page.department_counts,
      "unassigned_count" => page.unassigned_count
    }

    if can_manage do
      catalog = Departments.list_org_project_catalog(org.id)
      proj_by_id = Map.new(catalog, &{&1.id, &1})
      ifc_on = InformationFlow.ifc_on_project_ids(org, catalog)
      grants = Departments.list_search_grants(org.id)
      grants_by_subj = Enum.group_by(grants, &{&1.subject_kind, &1.subject_id})

      %{
        "viewer" => %{
          "can_create" => Projects.can_create_project?(org.id, user.id),
          "can_manage_departments" => true
        },
        "departments" =>
          Enum.map(departments, fn dept ->
            targets =
              grants_by_subj
              |> Map.get({"department", dept.id}, [])
              |> serialize_targets("department", dept.id, dept_by_id, proj_by_id)

            %{
              "id" => dept.id,
              "name" => dept.name,
              "targets" => targets
            }
          end),
        "catalog_swarms" =>
          Enum.map(catalog, fn proj ->
            %{
              "id" => proj.id,
              "name" => proj.name,
              "department_id" => proj.department_id,
              "ifc_on" => MapSet.member?(ifc_on, proj.id)
            }
          end),
        "projects" =>
          Enum.map(page.entries, fn project ->
            extra =
              grants_by_subj
              |> Map.get({"project", project.id}, [])
              |> serialize_targets("project", project.id, dept_by_id, proj_by_id)

            public_project(project, dept_by_id, extra)
          end),
        "next_cursor" => page.next_cursor
      }
      |> Map.merge(counts)
    else
      # Only departments that hold a Swarm this member sees (on any page).
      visible_dept_ids = page.department_counts |> Map.keys() |> MapSet.new()

      %{
        "viewer" => %{
          "can_create" => Projects.can_create_project?(org.id, user.id),
          "can_manage_departments" => false
        },
        "departments" =>
          departments
          |> Enum.filter(&MapSet.member?(visible_dept_ids, &1.id))
          |> Enum.map(&%{"id" => &1.id, "name" => &1.name, "targets" => []}),
        "catalog_swarms" => [],
        "projects" => Enum.map(page.entries, &public_project(&1, dept_by_id, [])),
        "next_cursor" => page.next_cursor
      }
      |> Map.merge(counts)
    end
  end

  @doc "Create an Agent Swarm from `name`, `slug` and optional `department_id`."
  def create(org, user, params) do
    attrs = Map.take(params, ~w(name slug department_id))

    if Projects.can_create_project?(org.id, user.id) do
      case Projects.create_project(org.id, attrs,
             creator_user_id: user.id,
             actor_label: actor_label(user)
           ) do
        {:ok, project} ->
          dept_by_id =
            org.id
            |> Departments.list_departments()
            |> Map.new(&{&1.id, &1})

          {:ok, public_project(project, dept_by_id, [])}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, 422, "invalid_project", gettext("Couldn't create the Agent Swarm."),
           %{
             "fields" =>
               Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
           }}

        {:error, :department_forbidden} ->
          {:error, 403, "forbidden",
           gettext("Only organization owners and admins can assign a department."), %{}}

        {:error, :invalid_department} ->
          {:error, 422, "invalid_department", gettext("Choose an existing department."),
           %{"fields" => %{"department_id" => [gettext("is invalid")]}}}

        {:error, :effective_target_limit_exceeded} ->
          effective_target_limit_error()

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

  @doc """
  Create a department (with optional initial `targets`) and answer the refreshed
  page, filtered by the caller's `query`.
  """
  def create_department(org, user, params) do
    attrs = Map.take(params, ~w(name targets))

    case Departments.create_department(org.id, attrs, audit_opts(user)) do
      {:ok, _dept} ->
        {:ok, refreshed_page(org, user, params)}

      {:error, %Ecto.Changeset{} = changeset} ->
        department_changeset_error(changeset, gettext("Could not create the department."))

      {:error, :invalid_targets} ->
        invalid_targets_error()

      {:error, :department_limit_reached} ->
        {:error, 422, "department_limit_reached",
         gettext("An organization can have at most %{count} departments.",
           count: Departments.max_departments()
         ), %{}}

      {:error, :effective_target_limit_exceeded} ->
        effective_target_limit_error()

      {:error, _reason} ->
        {:error, 503, "write_failed", gettext("Could not create the department."), %{}}
    end
  end

  @doc "Update a department's name and/or `targets`, answering the refreshed page."
  def update_department(org, user, department_id, params) do
    attrs = Map.take(params, ~w(name targets))

    case Departments.update_department(org.id, department_id, attrs, audit_opts(user)) do
      {:ok, _dept} ->
        {:ok, refreshed_page(org, user, params)}

      {:error, :effective_target_limit_exceeded} ->
        effective_target_limit_error()

      {:error, :not_found} ->
        department_not_found()

      {:error, %Ecto.Changeset{} = changeset} ->
        department_changeset_error(changeset, gettext("Could not update the department."))

      {:error, :invalid_targets} ->
        invalid_targets_error()

      {:error, _reason} ->
        {:error, 503, "write_failed", gettext("Could not update the department."), %{}}
    end
  end

  @doc "Delete a department (unassigning its Swarms) and answer the refreshed page."
  def delete_department(org, user, department_id, params \\ %{}) do
    case Departments.delete_department(org.id, department_id, audit_opts(user)) do
      :ok ->
        {:ok, refreshed_page(org, user, params)}

      {:error, :not_found} ->
        department_not_found()

      {:error, _reason} ->
        {:error, 503, "write_failed", gettext("Could not delete the department."), %{}}
    end
  end

  @doc false
  def serialize_targets(grants, subject_kind, subject_id, dept_by_id, proj_by_id) do
    grants
    |> Enum.flat_map(fn grant ->
      cond do
        grant.target_kind == "all_departments" ->
          [%{"kind" => "all_departments", "id" => grant.org_id, "name" => "All departments"}]

        subject_kind == "department" and grant.target_kind == "department" and
            grant.target_id == subject_id ->
          case Map.get(dept_by_id, grant.target_id) do
            %{name: name} -> [%{"kind" => "self", "id" => subject_id, "name" => name}]
            nil -> []
          end

        grant.target_kind == "department" ->
          case Map.get(dept_by_id, grant.target_id) do
            %{id: id, name: name} -> [%{"kind" => "department", "id" => id, "name" => name}]
            nil -> []
          end

        grant.target_kind == "project" ->
          case Map.get(proj_by_id, grant.target_id) do
            %{id: id, name: name} -> [%{"kind" => "project", "id" => id, "name" => name}]
            nil -> []
          end

        true ->
          []
      end
    end)
    |> Enum.sort_by(fn
      %{"kind" => "all_departments"} -> 0
      %{"kind" => "self"} -> 1
      %{"kind" => "department"} -> 2
      %{"kind" => "project"} -> 3
      _ -> 4
    end)
  end

  defp department_changeset_error(changeset, message) do
    {:error, 422, "invalid_department", message,
     %{
       "fields" => Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
     }}
  end

  # The first page again after a department write, keeping the caller's filter.
  defp refreshed_page(org, user, params),
    do: page(org, user, Map.take(params, ~w(query)), "admin")

  @doc false
  def effective_target_limit_error,
    do:
      {:error, 422, "effective_target_limit_exceeded",
       gettext(
         "An Agent Swarm can search at most %{count} other Agent Swarms. Remove some departments or Agent Swarms and try again.",
         count: Departments.max_effective_targets()
       ), %{}}

  defp department_not_found,
    do: {:error, 404, "department_not_found", gettext("Department not found."), %{}}

  defp invalid_targets_error,
    do:
      {:error, 422, "invalid_targets",
       gettext("Choose existing departments or Agent Swarms in this organization."), %{}}

  # Every caller here is an org member, so the only refusal is an ordinary
  # member whose one Agent Swarm already exists.
  defp quota_reached,
    do:
      {:error, 403, "project_quota_reached",
       gettext("Org members can create only one Agent Swarm; you have already created yours."),
       %{}}

  defp public_project(project, dept_by_id, extra_targets) do
    dept_name =
      case project.department_id && Map.get(dept_by_id, project.department_id) do
        %{name: name} -> name
        _ -> nil
      end

    %{
      "id" => project.id,
      "name" => project.name,
      "slug" => project.slug,
      "salix_group_id" => project.salix_group_id,
      "status" => project.status,
      "created_at" => project.created_at,
      "department_id" => project.department_id,
      "department_name" => dept_name,
      "extra_targets" => extra_targets
    }
  end

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user) do
    cond do
      present?(user.email) -> String.trim(user.email)
      present?(user.name) -> String.trim(user.name)
      true -> user.id
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
