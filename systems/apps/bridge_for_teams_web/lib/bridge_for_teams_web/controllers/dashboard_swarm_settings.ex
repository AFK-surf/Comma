defmodule BridgeForTeamsWeb.DashboardSwarmSettings do
  @moduledoc """
  Builds the Agent Swarm Settings page payload and applies its writes for
  `DashboardAPIController`: rename, archive and the Access list (explicit
  swarm grants; grant, change role, remove).

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

  alias BridgeForTeams.{Accounts, Memberships, ProjectIMConnects, Projects, Schedules}
  alias BridgeForTeamsWeb.Dashboard.CoreComponents

  @access_roles ~w(admin user)
  @access_limit 100

  @doc "The Settings payload: identity, runtime ids and the Access list."
  def page(org, project, role) do
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
       "access" => access_page(project, 0)
     }}
  end

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
  def rename(org, user, project, role, params) do
    with :ok <-
           authorize(
             role,
             fn -> record_project_denied(project, user, "project.renamed") end,
             gettext("Only Agent Swarm admins can rename this Agent Swarm.")
           ) do
      name = params |> Map.get("name") |> to_text()

      case Projects.rename_project(project, name, audit_opts(user)) do
        {:ok, renamed} ->
          page(org, renamed, role)

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
  def grant(org, user, project, role, params) do
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
          after_access_write(org, user, project)
        else
          {:error, _reason} -> write_failed(gettext("Could not update access."))
        end
      end
    end
  end

  @doc "Change one grant's role."
  def change_role(org, user, project, role, target_user_id, params) do
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
        {:ok, _membership} -> after_access_write(org, user, project)
        {:error, _reason} -> write_failed(gettext("Could not update access role."))
      end
    end
  end

  @doc "Remove one grant."
  def remove(org, user, project, role, target_user_id) do
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
        :ok -> after_access_write(org, user, project)
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
  defp after_access_write(org, user, project) do
    case Memberships.project_role(project.id, user.id) do
      {:ok, role} ->
        page(org, project, role)

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
    do: [actor_user_id: user.id, actor_label: actor_label(user), request_id: Ecto.UUID.generate()]

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
