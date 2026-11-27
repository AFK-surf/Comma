defmodule BridgeForTeamsWeb.DashboardSwarmSettings do
  @moduledoc """
  Builds the Agent Swarm Settings page payload and applies its writes for
  `DashboardAPIController`: rename, the default Task model, the default place
  to run Tasks, archive and the Access list (explicit swarm grants; grant,
  change role, remove).

  Every swarm member reads; only swarm admins write. A refused write records a
  denied audit entry, as the LiveView page did. Archiving first checks that the
  swarm is quiet (no active IM connection, no schedule) and refuses when Salix
  cannot confirm it. The Access list pages 100 grants at a time; `next_cursor`
  continues it through `access/2`.

  Access writes answer the page with the caller's role read again, so a
  self-demotion drops the admin controls. A caller who can no longer see the
  swarm gets the swarms list address and a notice instead.
  """
  use Gettext, backend: BridgeForTeamsWeb.Gettext

  alias BridgeForTeams.{
    Accounts,
    Agents,
    Departments,
    InformationFlow,
    Memberships,
    Models,
    ProjectIMConnects,
    Projects,
    Schedules
  }

  alias BridgeForTeamsWeb.Dashboard.CoreComponents
  alias BridgeForTeamsWeb.DashboardProjects

  @access_roles ~w(admin user)
  @admin_org_roles ~w(owner admin)
  @access_limit 100
  @platform_task_model %{"kind" => "platform", "tier" => "worker"}

  @doc """
  The Settings payload: identity, runtime ids, department and cross-Swarm search
  grants, the default Task model, the default place to run Tasks and the Access
  list.
  """
  def page(org, project, role, org_role \\ "member") do
    {:ok,
     %{
       "project" => %{
         "id" => project.id,
         "name" => project.name,
         "slug" => project.slug,
         "status" => project.status,
         "role" => role,
         "runtime_id" => project.salix_group_id
       },
       "org_runtime_id" => org.salix_tenant_id,
       "cross_search" => cross_search(org, project, org_role),
       "task_model" => task_model(org, project),
       "task_place" => task_place(project),
       "access" => access_page(project, 0)
     }}
  end

  # Members who are not organization owners or admins see only their own
  # Swarm's department: no rules, departments or other Swarms of the org.
  defp cross_search(org, project, org_role) do
    if org_role in @admin_org_roles,
      do: admin_cross_search(org, project),
      else: member_cross_search(project)
  end

  defp member_cross_search(project) do
    dept_name =
      with id when is_binary(id) <- project.department_id,
           {:ok, dept} <- Departments.get_department(project.org_id, id) do
        dept.name
      else
        _ -> nil
      end

    %{
      "status" => "ok",
      "can_manage" => false,
      "department_id" => project.department_id,
      "department_name" => dept_name,
      "inherited_targets" => [],
      "explicit_targets" => [],
      "departments" => [],
      "catalog_swarms" => []
    }
  end

  defp admin_cross_search(org, project) do
    departments = Departments.list_departments(org.id)
    dept_by_id = Map.new(departments, &{&1.id, &1})
    catalog = Departments.list_org_project_catalog(org.id)
    proj_by_id = Map.new(catalog, &{&1.id, &1})
    ifc_on = InformationFlow.ifc_on_project_ids(org, catalog)
    grants = Departments.list_search_grants(org.id)
    grants_by_subj = Enum.group_by(grants, &{&1.subject_kind, &1.subject_id})

    dept_name =
      case project.department_id && Map.get(dept_by_id, project.department_id) do
        %{name: name} -> name
        _ -> nil
      end

    inherited =
      if project.department_id do
        grants_by_subj
        |> Map.get({"department", project.department_id}, [])
        |> DashboardProjects.serialize_targets(
          "department",
          project.department_id,
          dept_by_id,
          proj_by_id
        )
        |> Enum.reject(&(&1["kind"] == "project" and &1["id"] == project.id))
      else
        []
      end

    explicit =
      grants_by_subj
      |> Map.get({"project", project.id}, [])
      |> DashboardProjects.serialize_targets("project", project.id, dept_by_id, proj_by_id)

    %{
      "status" => "ok",
      "can_manage" => true,
      "department_id" => project.department_id,
      "department_name" => dept_name,
      "inherited_targets" => inherited,
      "explicit_targets" => explicit,
      "departments" => Enum.map(departments, &%{"id" => &1.id, "name" => &1.name}),
      "ifc_on" => MapSet.member?(ifc_on, project.id),
      "catalog_swarms" =>
        catalog
        |> Enum.reject(&(&1.id == project.id))
        |> Enum.map(
          &%{
            "id" => &1.id,
            "name" => &1.name,
            "department_id" => &1.department_id,
            "ifc_on" => MapSet.member?(ifc_on, &1.id)
          }
        )
    }
  end

  # The default Task model and its picker, listed as the Agent Configure form
  # lists models: "none set" (key "", choosing it clears the default: each Task
  # runs the org default Task model), a current choice the org no longer offers
  # or no enabled account serves (disabled), the platform model, then the
  # org's offered choices that an account serves, grouped by vendor. A Task
  # that names no model and runs a model no enabled account serves stops
  # (`model_unavailable`): `unserved` says so of the swarm's default, or of
  # the org default the swarm follows, and the label names it too.
  defp task_model(org, project) do
    case Projects.default_task_model(project) do
      {:ok, current} ->
        current = current && Models.normalize(current)
        catalog = Models.catalog()
        allowed = org_models(org, catalog)
        served = Models.servable(org)
        offered = Models.offered(org, catalog, served, &paid_label/1)
        platform = platform_row()

        unset = org_default_label(org, allowed, served)

        {label, current_rows} =
          cond do
            is_nil(current) ->
              {unset, []}

            current == @platform_task_model ->
              {platform["label"], []}

            Enum.any?(offered, &(&1["choice"] == current)) ->
              {Models.option(current, offered)["label"], []}

            true ->
              option = Models.option(current, allowed)

              {label, unavailable} =
                if Models.served?(current, served) or
                     not Models.allowed?(org, current, catalog),
                   do:
                     {option["label"],
                      gettext("%{model} (current; unavailable for selection)",
                        model: option["label"]
                      )},
                   else:
                     {unserved_label(option["label"]),
                      gettext("%{model} (current; no enabled account serves it)",
                        model: option["label"]
                      )}

              {label,
               [row(option["key"], current, unavailable, true, vendor_group(option["vendor"]))]}
          end

        %{
          "status" => "ok",
          "key" => if(current, do: Models.key(current), else: ""),
          "label" => label,
          "unserved" => not Models.served?(current || org.default_task_model, served),
          "models" =>
            [row("", nil, unset, false, gettext("Platform")) | current_rows] ++
              [platform | Enum.map(offered, &offered_row/1)]
        }

      {:error, _reason} ->
        %{
          "status" => "unavailable",
          "key" => "",
          "label" => nil,
          "unserved" => false,
          "models" => []
        }
    end
  end

  # A swarm without its own default Task model runs the org's
  # (`BridgeForTeams.Models.default_task_model/1`), else the platform model.
  defp org_default_label(org, allowed, served) do
    model =
      case org.default_task_model do
        %{} = choice ->
          label = Models.option(choice, allowed)["label"]
          if Models.served?(choice, served), do: label, else: unserved_label(label)

        nil ->
          case Models.platform_default("worker") do
            %{"label" => label} -> label
            nil -> gettext("Platform model")
          end
      end

    gettext("Organization default (%{model})", model: model)
  end

  defp unserved_label(model),
    do: gettext("%{model}; no enabled account serves it", model: model)

  defp paid_label(option),
    do: gettext("%{model} (pay-per-use)", model: option["label"])

  # Where a Task runs when the Router names no place, and its name: Salix
  # (also when none is set), the Cloud VM, or a station by its device's name.
  # Admins choose another from the Workers' place picker (`…/agents/targets`).
  defp task_place(project) do
    case Projects.default_task_place(project) do
      {:ok, place} ->
        place = place || %{"kind" => "salix"}
        %{"status" => "ok", "place" => place, "label" => place_label(project, place)}

      {:error, _reason} ->
        %{"status" => "unavailable", "place" => nil, "label" => nil}
    end
  end

  defp place_label(_project, %{"kind" => "cloud_vm"}), do: gettext("The Cloud VM")
  defp place_label(_project, %{"kind" => "sandbox"}), do: gettext("A sandbox")

  # The Group's own VM on its Agent VMM Host is stored as that Host's station
  # (`SalixWeb.Migrations.CloudVMCutover`); it keeps the Cloud VM's name.
  defp place_label(project, %{"kind" => "station", "device_id" => device_id}) do
    if device_id == SalixStore.RuntimeIds.cloud_vm_device_id(project.salix_group_id) do
      place_label(project, %{"kind" => "cloud_vm"})
    else
      {:ok, %{"stations" => stations}} = Agents.list_stations(project)

      case Enum.find(stations, &(&1["device_id"] == device_id)) do
        %{"name" => name} when is_binary(name) and name != "" -> name
        _gone -> device_id
      end
    end
  end

  defp place_label(_project, _salix), do: gettext("Salix")

  defp org_models(org, catalog) do
    case Models.allowed(org, catalog) do
      {:ok, options} -> options
      {:error, _reason} -> []
    end
  end

  defp platform_row do
    label =
      case Models.platform_default("worker") do
        %{"label" => model} -> gettext("Platform model (%{model})", model: model)
        nil -> gettext("Platform model")
      end

    row(
      Models.key(@platform_task_model),
      @platform_task_model,
      label,
      false,
      gettext("Platform")
    )
  end

  defp offered_row(option),
    do:
      row(option["key"], option["choice"], option["label"], false, vendor_group(option["vendor"]))

  defp row(key, choice, label, disabled, group),
    do: %{
      "key" => key,
      "choice" => choice,
      "label" => label,
      "disabled" => disabled,
      "group" => group
    }

  defp vendor_group(vendor), do: Models.vendor_label(vendor) || gettext("Other")

  @doc "One later page of the Access list; `cursor` is a previous `next_cursor`."
  def access(project, params) do
    case Integer.parse(to_text(params["cursor"])) do
      {offset, ""} when offset > 0 ->
        {:ok, access_page(project, offset)}

      _invalid ->
        {:error, 422, "invalid_cursor",
         gettext("This page of access grants is no longer available."), %{}}
    end
  end

  defp access_page(project, offset) do
    {:ok, access} =
      Memberships.list_project_members_bounded(project.id, @access_limit, offset: offset)

    %{
      "members" => Enum.map(access.members, &public_member/1),
      "truncated" => access.truncated,
      "next_cursor" =>
        if(access.truncated, do: Integer.to_string(offset + length(access.members)))
    }
  end

  @doc "Rename the swarm; the slug stays so existing addresses keep working."
  def rename(org, user, project, role, params, org_role \\ "member") do
    with :ok <-
           authorize(
             role,
             fn -> record_project_denied(project, user, "project.renamed") end,
             gettext("Only Agent Swarm admins can rename this Agent Swarm.")
           ) do
      name = params |> Map.get("name") |> to_text()

      case Projects.rename_project(project, name, audit_opts(user)) do
        {:ok, renamed} ->
          page(org, renamed, role, org_role)

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, 422, "invalid_project", gettext("Could not rename the Agent Swarm."),
           %{
             "fields" =>
               Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)
           }}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Could not rename the Agent Swarm."), %{}}
      end
    end
  end

  @doc "Assign or clear the Swarm's department (organization owners and admins only)."
  def set_department(org, user, project, role, org_role, params) do
    with :ok <-
           authorize_org_admin(
             org_role,
             fn -> record_project_denied(project, user, "project.department_changed") end,
             gettext("Only organization owners and admins can change the department.")
           ),
         :ok <- active(project) do
      case Departments.set_project_department(project, params["department_id"], audit_opts(user)) do
        {:ok, updated} ->
          page(org, updated, role, org_role)

        {:error, :invalid_department} ->
          {:error, 422, "invalid_department",
           gettext("Choose an existing department in this organization."), %{}}

        {:error, :project_archived} ->
          archived_not_found()

        {:error, :effective_target_limit_exceeded} ->
          DashboardProjects.effective_target_limit_error()

        {:error, _reason} ->
          write_failed(gettext("Could not update the department."))
      end
    end
  end

  @doc """
  Update explicit cross-Swarm search grants (and optional `department_id` in the
  same transaction). Restricted to organization owners and admins.
  """
  def set_search_grants(org, user, project, role, org_role, params) do
    with :ok <-
           authorize_org_admin(
             org_role,
             fn -> record_project_denied(project, user, "project.search_grants_updated") end,
             gettext(
               "Only organization owners and admins can change cross-Swarm search permissions."
             )
           ),
         :ok <- active(project) do
      attrs = Map.take(params, ~w(department_id targets))

      case Departments.update_project_cross_search(project, attrs, audit_opts(user)) do
        {:ok, updated} ->
          page(org, updated, role, org_role)

        {:error, :invalid_department} ->
          {:error, 422, "invalid_department",
           gettext("Choose an existing department in this organization."), %{}}

        {:error, :invalid_targets} ->
          {:error, 422, "invalid_targets",
           gettext("Choose existing departments or Agent Swarms in this organization."), %{}}

        {:error, :project_archived} ->
          archived_not_found()

        {:error, :effective_target_limit_exceeded} ->
          DashboardProjects.effective_target_limit_error()

        {:error, _reason} ->
          write_failed(gettext("Could not save cross-Swarm search permissions."))
      end
    end
  end

  @doc """
  Set the default Task model: `model` is the platform model or a model choice
  the org offers now. Answers the page.
  """
  def set_task_model(org, user, project, role, params, org_role \\ "member") do
    with :ok <-
           authorize(
             role,
             fn -> record_project_denied(project, user, "project.default_task_model_changed") end,
             gettext("Only Agent Swarm admins can change the default Task model.")
           ) do
      case Projects.set_default_task_model(project, params["model"], audit_opts(user)) do
        {:ok, _stored} ->
          page(org, project, role, org_role)

        {:error, reason} when reason in [:unavailable, :timeout, :unsupported] ->
          write_failed(gettext("Could not save the default Task model."))

        {:error, _refused} ->
          {:error, 422, "invalid_model", gettext("Choose a model from the list before saving."),
           %{}}
      end
    end
  end

  @doc """
  Set the default place to run Tasks: `place` is `{kind: salix}`,
  `{kind: sandbox}` where sandboxes are set up, `{kind: cloud_vm}` while the
  swarm's Cloud VM is on and the deployment has not retired it, or
  `{kind: station, device_id}` for
  one of its stations that takes Tasks. Answers the page.
  """
  def set_task_place(org, user, project, role, params, org_role \\ "member") do
    with :ok <-
           authorize(
             role,
             fn -> record_project_denied(project, user, "project.default_task_place_changed") end,
             gettext("Only Agent Swarm admins can change the default place to run Tasks.")
           ) do
      case Projects.set_default_task_place(project, params["place"], audit_opts(user)) do
        {:ok, _stored} ->
          page(org, project, role, org_role)

        {:error, reason} when reason in [:unavailable, :timeout, :unsupported] ->
          write_failed(gettext("Could not save the default place to run Tasks."))

        {:error, :cloud_vm_disabled} ->
          {:error, 422, "cloud_vm_disabled", gettext("No Cloud VM is set up for this swarm."),
           %{}}

        {:error, :cloud_vm_retired} ->
          {:error, 422, "cloud_vm_retired",
           gettext("The Cloud VM is retired here: a sandbox takes its place."), %{}}

        {:error, :sandbox_unavailable} ->
          {:error, 422, "sandbox_unavailable", gettext("Sandboxes are not set up here."), %{}}

        {:error, _refused} ->
          {:error, 422, "invalid_place",
           gettext("Choose Salix, a sandbox, the Cloud VM or a station that takes Tasks."), %{}}
      end
    end
  end

  @doc """
  Clear the default Task model: each Task that names no model runs its
  Worker's model again. Answers the page.
  """
  def clear_task_model(org, user, project, role, org_role \\ "member") do
    with :ok <-
           authorize(
             role,
             fn -> record_project_denied(project, user, "project.default_task_model_changed") end,
             gettext("Only Agent Swarm admins can change the default Task model.")
           ) do
      case Projects.clear_default_task_model(project, audit_opts(user)) do
        {:ok, nil} -> page(org, project, role, org_role)
        {:error, _reason} -> write_failed(gettext("Could not save the default Task model."))
      end
    end
  end

  @doc """
  Archive the swarm once it is quiet. Answers the swarms list address and the
  notice to show there.
  """
  def archive(org, user, project, role) do
    with :ok <-
           authorize(
             role,
             fn -> record_project_denied(project, user, "project.archived") end,
             gettext("Only Agent Swarm admins can archive this Agent Swarm.")
           ),
         :ok <- archival_blocker(org, project) do
      case Projects.archive_project(project, audit_opts(user)) do
        {:ok, _archived} ->
          {:ok,
           %{
             "redirect" => "/orgs/#{org.slug}/projects",
             "notice" => gettext("Agent Swarm \"%{name}\" archived.", name: project.name)
           }}

        {:error, _reason} ->
          {:error, 503, "write_failed", gettext("Could not archive the Agent Swarm."), %{}}
      end
    end
  end

  # Inbound IM traffic and recurring schedules would keep reaching an archived
  # swarm, so both must be gone first. If Salix cannot confirm either, refuse
  # rather than guess.
  defp archival_blocker(org, project) do
    with :ok <- im_connects_quiet(org, project), do: schedules_quiet(project)
  end

  defp im_connects_quiet(org, project) do
    case ProjectIMConnects.list_project_connects(org.id, project.id, nil) do
      {:ok, connects} ->
        if Enum.any?(connects, &is_nil(&1["disabled_at"])),
          do:
            blocked(
              gettext(
                "Disable every IM connection on the Integrations page before archiving this Agent Swarm."
              )
            ),
          else: :ok

      {:error, _reason} ->
        unverified()
    end
  end

  defp schedules_quiet(project) do
    case Schedules.list_project_schedules(project) do
      {:ok, []} ->
        :ok

      {:ok, _schedules} ->
        blocked(
          gettext(
            "Delete every schedule in the Scheduled view of Tasks before archiving this Agent Swarm."
          )
        )

      {:error, _reason} ->
        unverified()
    end
  end

  defp blocked(message), do: {:error, 409, "archive_blocked", message, %{}}

  defp unverified,
    do:
      {:error, 503, "runtime_unavailable",
       gettext("Couldn't verify the Agent Swarm state. Salix is unavailable — retry shortly."),
       %{}}

  @doc "Grant `email` (found or created) a role on the swarm."
  def grant(org, user, project, role, params, org_role \\ "member") do
    email = params |> Map.get("email") |> to_text() |> String.downcase()
    new_role = if params["role"] in @access_roles, do: params["role"], else: "user"

    with :ok <-
           authorize(
             role,
             fn ->
               record_member_denied(project, user, "project_member.granted", nil, %{
                 "attempted_email_configured" => email != "",
                 "attempted_role" => text_or_nil(params["role"]),
                 "surface" => "project_access"
               })
             end,
             access_denied()
           ) do
      if email == "" do
        {:error, 422, "invalid_email", gettext("Email can't be blank."),
         %{"fields" => %{"email" => [gettext("Email can't be blank.")]}}}
      else
        with {:ok, grantee} <- find_or_create_user(email),
             {:ok, _membership} <-
               Memberships.put_project_member(project.id, grantee.id, new_role, audit_opts(user)) do
          after_access_write(org, user, project, org_role)
        else
          {:error, _reason} -> write_failed(gettext("Could not update access."))
        end
      end
    end
  end

  @doc "Change one grant's role."
  def change_role(org, user, project, role, target_user_id, params, org_role \\ "member") do
    new_role = params["role"]

    with :ok <-
           authorize(
             role,
             fn ->
               record_member_denied(
                 project,
                 user,
                 "project_member.role_changed",
                 target_user_id,
                 %{"attempted_role" => text_or_nil(new_role), "surface" => "project_access"}
               )
             end,
             access_denied()
           ),
         :ok <- validate_role(new_role),
         {:ok, target} <- granted_member(project, target_user_id) do
      case Memberships.put_project_member(project.id, target, new_role, audit_opts(user)) do
        {:ok, _membership} -> after_access_write(org, user, project, org_role)
        {:error, _reason} -> write_failed(gettext("Could not update access role."))
      end
    end
  end

  @doc "Remove one grant."
  def remove(org, user, project, role, target_user_id, org_role \\ "member") do
    with :ok <-
           authorize(
             role,
             fn ->
               record_member_denied(project, user, "project_member.removed", target_user_id, %{
                 "surface" => "project_access"
               })
             end,
             access_denied()
           ),
         {:ok, target} <- granted_member(project, target_user_id) do
      case Memberships.remove_project_member(project.id, target, audit_opts(user)) do
        :ok -> after_access_write(org, user, project, org_role)
        {:error, :not_found} -> member_not_found()
        {:error, _reason} -> write_failed(gettext("Could not remove access."))
      end
    end
  end

  defp authorize("admin", _record_denied, _message), do: :ok

  defp authorize(_role, record_denied, message) do
    record_denied.()
    {:error, 403, "forbidden", message, %{}}
  end

  # An archived Swarm takes no department or search change: it answers as an
  # unknown Swarm.
  defp active(%{archived_at: nil}), do: :ok
  defp active(_archived), do: archived_not_found()

  defp archived_not_found,
    do: {:error, 404, "project_not_found", gettext("Agent Swarm not found."), %{}}

  defp authorize_org_admin(org_role, _record_denied, _message) when org_role in @admin_org_roles,
    do: :ok

  defp authorize_org_admin(_org_role, record_denied, message) do
    record_denied.()
    {:error, 403, "forbidden", message, %{}}
  end

  defp access_denied, do: gettext("Only Agent Swarm admins can manage access.")

  defp validate_role(role) when role in @access_roles, do: :ok

  defp validate_role(_role),
    do: {:error, 422, "invalid_role", gettext("Role must be admin or user."), %{}}

  # Only an existing grant on this swarm can change or go; anyone else is not
  # a member of the Access list.
  defp granted_member(project, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         {:ok, _role} <- Memberships.project_grant(project.id, user_id) do
      {:ok, user_id}
    else
      _missing -> member_not_found()
    end
  end

  defp member_not_found,
    do: {:error, 404, "member_not_found", gettext("Member not found."), %{}}

  # The caller's own grant may just have changed or gone.
  defp after_access_write(org, user, project, org_role) do
    case Memberships.project_role(project.id, user.id) do
      {:ok, role} ->
        page(org, project, role, org_role)

      {:error, :not_found} ->
        {:ok,
         %{
           "redirect" => "/orgs/#{org.slug}/projects",
           "notice" =>
             gettext("You no longer have access to Agent Swarm \"%{name}\".", name: project.name)
         }}
    end
  end

  defp record_project_denied(project, user, action) do
    _ =
      Projects.record_project_write_attempt(
        project,
        action,
        "denied",
        :forbidden,
        audit_opts(user)
      )

    :ok
  end

  defp record_member_denied(project, user, action, target_user_id, metadata) do
    target =
      case Ecto.UUID.cast(target_user_id) do
        {:ok, uuid} -> uuid
        :error -> nil
      end

    _ =
      Memberships.record_project_member_write_attempt(
        project.id,
        target,
        action,
        "denied",
        :forbidden,
        audit_opts(user),
        metadata: metadata
      )

    :ok
  end

  defp find_or_create_user(email) do
    case Accounts.get_user_by_email(email) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> Accounts.create_user(%{"email" => email})
    end
  end

  # `id` is the user's id; a `user_id` key would be redacted by `send_ok`.
  defp public_member(membership) do
    %{
      "id" => membership.user_id,
      "name" => text_or_nil(membership.user.name),
      "email" => text_or_nil(membership.user.email),
      "role" => membership.role,
      "granted_at" => membership.created_at
    }
  end

  defp write_failed(message), do: {:error, 503, "write_failed", message, %{}}

  defp audit_opts(user),
    do: [
      actor_user_id: user.id,
      actor_label: actor_label(user),
      request_id: SystemsRuntime.Proc.uuid()
    ]

  defp actor_label(user), do: text_or_nil(user.email) || text_or_nil(user.name) || user.id

  defp to_text(value) when is_binary(value), do: String.trim(value)
  defp to_text(_value), do: ""

  defp text_or_nil(value) do
    case to_text(value) do
      "" -> nil
      text -> text
    end
  end
end
