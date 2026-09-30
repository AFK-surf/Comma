defmodule BridgeForTeams.Memberships do
  @moduledoc """
  Membership & RBAC context (design §6, §7). Resolves `user → org_memberships →
  project_memberships` and enforces roles. Authorization happens here before any
  Salix-facing action.

  ## Role model

  Org roles (ranked): `owner` > `admin` > `member`.
  Project roles (ranked): `admin` > `user`.

  A user's *effective* project role is the higher of their explicit project
  grant and the role their org membership implies (org owner/admin ⇒ project
  admin; org member does not imply Agent Swarm access).
  """
  import Ecto.Query

  alias BridgeForTeams.{Observability, Projects, Repo}
  alias BridgeForTeams.Schema.{OrgMembership, OrgSsoIdentity, Project, ProjectMembership}

  @org_rank %{"owner" => 3, "admin" => 2, "member" => 1}
  @project_rank %{"admin" => 2, "user" => 1}

  @doc "Add or update a user's org membership/role."
  @spec put_org_member(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, OrgMembership.t()} | {:error, Ecto.Changeset.t()}
  def put_org_member(org_id, user_id, role, opts \\ []) do
    existing = Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id)
    old_role = existing && existing.role

    changeset =
      (existing || %OrgMembership{})
      |> OrgMembership.changeset(%{org_id: org_id, user_id: user_id, role: role})

    insert_or_update_with_optional_audit(
      changeset,
      opts,
      fn membership -> record_org_member_audit(org_id, user_id, existing, membership, opts) end,
      fn membership -> maybe_sync_org_owner_emails(org_id, old_role, membership.role) end
    )
  end

  @doc "Add or update a user's project membership/role."
  @spec put_project_member(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, ProjectMembership.t()} | {:error, Ecto.Changeset.t()}
  def put_project_member(project_id, user_id, role, opts \\ []) do
    existing = Repo.get_by(ProjectMembership, project_id: project_id, user_id: user_id)
    old_role = existing && existing.role

    changeset =
      (existing || %ProjectMembership{})
      |> ProjectMembership.changeset(%{project_id: project_id, user_id: user_id, role: role})

    insert_or_update_with_optional_audit(
      changeset,
      opts,
      fn membership ->
        record_project_member_audit(project_id, user_id, existing, membership, opts)
      end,
      fn membership -> maybe_sync_project_owner_emails(project_id, old_role, membership.role) end
    )
  end

  @doc "Fetch a user's org role, if any."
  @spec org_role(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, String.t()} | {:error, :not_found}
  def org_role(org_id, user_id) do
    case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
      nil -> {:error, :not_found}
      %{role: role} -> {:ok, role}
    end
  end

  @doc "Whether a user can manage at least one organization."
  @spec manages_any_org?(Ecto.UUID.t()) :: boolean()
  def manages_any_org?(user_id) do
    from(m in OrgMembership,
      where: m.user_id == ^user_id and m.role in ["owner", "admin"],
      select: true,
      limit: 1
    )
    |> Repo.exists?()
  end

  @doc """
  Fetch a user's effective project role (explicit project grant plus org
  owner/admin override). Returns the higher of the explicit project grant and
  the org-derived role.
  """
  @spec project_role(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, String.t()} | {:error, :not_found}
  def project_role(project_id, user_id) do
    explicit =
      case Repo.get_by(ProjectMembership, project_id: project_id, user_id: user_id) do
        nil -> nil
        %{role: role} -> role
      end

    derived = org_derived_project_role(project_id, user_id)

    case max_project_role(explicit, derived) do
      nil -> {:error, :not_found}
      role -> {:ok, role}
    end
  end

  @doc """
  Whether a user is authorized for `action` on `resource`. The single RBAC
  decision point used by the web Authorize plug (design §7).

  `resource` is a map carrying the scope and the minimum role required, e.g.:

      authorize(user_id, :manage, %{org_id: id, min_org_role: "admin"})
      authorize(user_id, :write, %{project_id: id, min_project_role: "admin"})

  Defaults: org actions require `member`; project reads require `user` and
  project writes require `admin`.
  """
  @spec authorize(Ecto.UUID.t(), atom(), map()) :: :ok | {:error, :forbidden}
  def authorize(user_id, action, resource) do
    cond do
      project_id = resource[:project_id] || resource["project_id"] ->
        min =
          resource[:min_project_role] ||
            resource["min_project_role"] ||
            default_project_min_role(action)

        check_project(project_id, user_id, min)

      org_id = resource[:org_id] || resource["org_id"] ->
        min = resource[:min_org_role] || resource["min_org_role"] || "member"
        check_org(org_id, user_id, min)

      true ->
        {:error, :forbidden}
    end
  end

  @doc """
  List an org's memberships with their `:user` and org-scoped SSO identities
  preloaded, ordered by org-role rank (owner first) then a stable user label.
  Used by the dashboard members page.
  """
  @spec list_org_members(Ecto.UUID.t()) :: [OrgMembership.t()]
  def list_org_members(org_id) do
    identity_query = from(i in OrgSsoIdentity, where: i.org_id == ^org_id)

    from(m in OrgMembership,
      where: m.org_id == ^org_id,
      join: u in assoc(m, :user),
      preload: [user: {u, org_sso_identities: ^identity_query}]
    )
    |> Repo.all()
    |> Enum.sort_by(fn m -> {-(@org_rank[m.role] || 0), user_sort_key(m.user)} end)
  end

  @doc """
  List explicit Agent Swarm ACL grants with their `:user` preloaded, ordered by
  project-role rank (admin first) then a stable user label.
  """
  @spec list_project_members(Ecto.UUID.t()) :: [ProjectMembership.t()]
  def list_project_members(project_id) do
    from(m in ProjectMembership,
      where: m.project_id == ^project_id,
      join: u in assoc(m, :user),
      preload: [user: u]
    )
    |> Repo.all()
    |> Enum.sort_by(fn m -> {-(@project_rank[m.role] || 0), user_sort_key(m.user)} end)
  end

  @doc "List a bounded, stable prefix of explicit Agent Swarm ACL grants with completeness."
  @spec list_project_members_bounded(Ecto.UUID.t(), 1..100) ::
          {:ok,
           %{
             members: [ProjectMembership.t()],
             completeness: :complete | :truncated,
             truncated: boolean()
           }}
  def list_project_members_bounded(project_id, limit)
      when is_integer(limit) and limit in 1..100 do
    members =
      from(m in ProjectMembership,
        where: m.project_id == ^project_id,
        join: u in assoc(m, :user),
        order_by: [asc: m.role, asc_nulls_last: u.email, asc_nulls_last: u.name, asc: u.id],
        limit: ^(limit + 1),
        preload: [user: u]
      )
      |> Repo.all()

    truncated = length(members) > limit

    {:ok,
     %{
       members: Enum.take(members, limit),
       completeness: if(truncated, do: :truncated, else: :complete),
       truncated: truncated
     }}
  end

  defp user_sort_key(user) do
    [
      user.email,
      user.name,
      user_identity_field(user, :mobile),
      user_identity_field(user, :provider_subject),
      user.id
    ]
    |> Enum.find_value("", fn value ->
      if present?(value), do: String.downcase(String.trim(value))
    end)
  end

  defp user_identity_field(user, field) do
    user
    |> loaded_sso_identities()
    |> Enum.find_value(&Map.get(&1, field))
  end

  defp loaded_sso_identities(%{org_sso_identities: identities}) when is_list(identities),
    do: identities

  defp loaded_sso_identities(_user), do: []

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "Count the org's owner memberships (used to guard demoting the last owner)."
  @spec count_org_owners(Ecto.UUID.t()) :: non_neg_integer()
  def count_org_owners(org_id) do
    from(m in OrgMembership, where: m.org_id == ^org_id and m.role == "owner")
    |> Repo.aggregate(:count, :id)
  end

  @doc "Remove an org membership."
  @spec remove_org_member(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def remove_org_member(org_id, user_id, opts \\ []) do
    if audit_enabled?(opts) do
      remove_org_member_with_audit(org_id, user_id, opts)
    else
      delete_org_member(org_id, user_id)
    end
  end

  defp delete_org_member(org_id, user_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
             nil ->
               Repo.rollback(:not_found)

             %OrgMembership{} = membership ->
               with {:ok, _deleted} <- Repo.delete(membership) do
                 :ok = maybe_sync_org_owner_emails(org_id, membership.role, nil)
                 :ok
               else
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove an explicit Agent Swarm ACL grant."
  @spec remove_project_member(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok | {:error, term()}
  def remove_project_member(project_id, user_id, opts \\ []) do
    if audit_enabled?(opts) do
      remove_project_member_with_audit(project_id, user_id, opts)
    else
      delete_project_member(project_id, user_id)
    end
  end

  defp delete_project_member(project_id, user_id) do
    case Repo.transaction(fn ->
           case Repo.get_by(ProjectMembership, project_id: project_id, user_id: user_id) do
             nil ->
               Repo.rollback(:not_found)

             %ProjectMembership{} = membership ->
               with {:ok, _deleted} <- Repo.delete(membership) do
                 :ok = maybe_sync_project_owner_emails(project_id, membership.role, nil)
                 :ok
               else
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Record a failed or denied Agent Swarm access write attempt without mutating grants."
  @spec record_project_member_write_attempt(
          Ecto.UUID.t(),
          Ecto.UUID.t() | nil,
          String.t(),
          String.t(),
          term(),
          keyword(),
          keyword()
        ) :: {:ok, term()} | {:error, term()}
  def record_project_member_write_attempt(
        project_id,
        target_user_id,
        action,
        result,
        reason,
        opts \\ [],
        extra \\ []
      )

  def record_project_member_write_attempt(
        project_id,
        target_user_id,
        action,
        result,
        reason,
        opts,
        extra
      ) do
    if audit_enabled?(opts) do
      case Repo.get(Project, project_id) do
        %Project{} = project ->
          Observability.record_audit(%{
            org_id: project.org_id,
            actor_user_id: Keyword.get(opts, :actor_user_id),
            actor_label: Keyword.get(opts, :actor_label),
            action: action,
            resource_type: "project_member",
            resource_id: target_user_id,
            resource_label: member_resource_label("project_member", target_user_id),
            result: result,
            reason_class: failure_reason_class(reason),
            request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
            metadata: member_attempt_metadata(project, target_user_id, reason, extra),
            redacted_diff: Keyword.get(extra, :redacted_diff, %{})
          })

        nil ->
          {:error, :project_not_found}
      end
    else
      {:ok, nil}
    end
  end

  # ---- internal ----

  # Membership writes run in a transaction so the audit row and the Salix
  # owner-email reconcile row (transactional outbox) commit atomically with
  # the membership itself.
  defp insert_or_update_with_optional_audit(changeset, opts, audit_fun, post_fun) do
    Repo.transaction(fn ->
      with {:ok, membership} <- Repo.insert_or_update(changeset),
           {:ok, _audit} <- maybe_audit(opts, audit_fun, membership) do
        :ok = post_fun.(membership)
        membership
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_audit(opts, audit_fun, membership) do
    if audit_enabled?(opts), do: audit_fun.(membership), else: {:ok, nil}
  end

  # The Salix group's owner_emails only changes when the project-admin set
  # does: an explicit project "admin" grant appearing/disappearing, or an org
  # owner/admin membership (implied admin on every swarm) changing.
  defp maybe_sync_project_owner_emails(project_id, old_role, new_role) do
    if old_role != new_role and "admin" in [old_role, new_role] do
      Projects.enqueue_owner_emails_sync(project_id)
    end

    :ok
  end

  defp maybe_sync_org_owner_emails(org_id, old_role, new_role) do
    if old_role != new_role and Enum.any?([old_role, new_role], &(&1 in ["owner", "admin"])) do
      Projects.enqueue_owner_emails_sync_for_org(org_id)
    end

    :ok
  end

  defp remove_org_member_with_audit(org_id, user_id, opts) do
    case Repo.transaction(fn ->
           case Repo.get_by(OrgMembership, org_id: org_id, user_id: user_id) do
             nil ->
               Repo.rollback(:not_found)

             %OrgMembership{} = membership ->
               with {:ok, _deleted} <- Repo.delete(membership),
                    {:ok, _audit} <-
                      record_removed_member_audit(
                        org_id,
                        user_id,
                        membership.role,
                        "org_member.removed",
                        "org_member",
                        opts
                      ) do
                 :ok = maybe_sync_org_owner_emails(org_id, membership.role, nil)
                 :ok
               else
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_project_member_with_audit(project_id, user_id, opts) do
    case Repo.transaction(fn ->
           case Repo.get_by(ProjectMembership, project_id: project_id, user_id: user_id) do
             nil ->
               Repo.rollback(:not_found)

             %ProjectMembership{} = membership ->
               with %Project{} = project <- Repo.get(Project, project_id),
                    {:ok, _deleted} <- Repo.delete(membership),
                    {:ok, _audit} <-
                      record_removed_member_audit(
                        project.org_id,
                        user_id,
                        membership.role,
                        "project_member.removed",
                        "project_member",
                        opts,
                        project
                      ) do
                 :ok = maybe_sync_project_owner_emails(project_id, membership.role, nil)
                 :ok
               else
                 nil -> Repo.rollback(:project_not_found)
                 {:error, reason} -> Repo.rollback(reason)
               end
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_org_member_audit(org_id, user_id, existing, membership, opts) do
    action = if existing, do: "org_member.role_changed", else: "org_member.granted"
    old_role = existing && existing.role

    Observability.record_audit(
      audit_attrs(org_id, action, "org_member", user_id, opts,
        resource_label: "Org member #{short_id(user_id)}",
        metadata: member_metadata(user_id, old_role, membership.role),
        redacted_diff: role_diff(old_role, membership.role)
      )
    )
  end

  defp record_project_member_audit(project_id, user_id, existing, membership, opts) do
    case Repo.get(Project, project_id) do
      %Project{} = project ->
        action = if existing, do: "project_member.role_changed", else: "project_member.granted"
        old_role = existing && existing.role

        Observability.record_audit(
          audit_attrs(project.org_id, action, "project_member", user_id, opts,
            resource_label: "Agent Swarm member #{short_id(user_id)}",
            metadata:
              member_metadata(user_id, old_role, membership.role)
              |> Map.put("project_id", project.id)
              |> Map.put("project_name", project.name),
            redacted_diff: role_diff(old_role, membership.role)
          )
        )

      nil ->
        {:error, :project_not_found}
    end
  end

  defp record_removed_member_audit(org_id, user_id, old_role, action, resource_type, opts) do
    Observability.record_audit(
      audit_attrs(org_id, action, resource_type, user_id, opts,
        resource_label: member_resource_label(resource_type, user_id),
        metadata: member_metadata(user_id, old_role, nil),
        redacted_diff: role_diff(old_role, nil)
      )
    )
  end

  defp record_removed_member_audit(
         org_id,
         user_id,
         old_role,
         action,
         resource_type,
         opts,
         %Project{} = project
       ) do
    Observability.record_audit(
      audit_attrs(org_id, action, resource_type, user_id, opts,
        resource_label: member_resource_label(resource_type, user_id),
        metadata:
          member_metadata(user_id, old_role, nil)
          |> Map.put("project_id", project.id)
          |> Map.put("project_name", project.name),
        redacted_diff: role_diff(old_role, nil)
      )
    )
  end

  defp audit_attrs(org_id, action, resource_type, resource_id, opts, extra) do
    %{
      org_id: org_id,
      actor_user_id: Keyword.get(opts, :actor_user_id),
      actor_label: Keyword.get(opts, :actor_label),
      action: action,
      resource_type: resource_type,
      resource_id: resource_id,
      resource_label: Keyword.fetch!(extra, :resource_label),
      result: "ok",
      request_id: Keyword.get(opts, :request_id, Ecto.UUID.generate()),
      metadata: Keyword.get(extra, :metadata, %{}),
      redacted_diff: Keyword.get(extra, :redacted_diff, %{})
    }
  end

  defp member_metadata(user_id, old_role, new_role) do
    %{
      "target_user_id" => user_id,
      "previous_role" => old_role,
      "new_role" => new_role
    }
  end

  defp role_diff(old_role, new_role) do
    %{"role" => %{"from" => old_role, "to" => new_role}}
  end

  defp member_attempt_metadata(%Project{} = project, target_user_id, reason, extra) do
    %{
      "project_id" => project.id,
      "project_name" => project.name,
      "target_user_id" => target_user_id,
      "reason_class" => failure_reason_class(reason),
      "validation_fields" => validation_fields(reason)
    }
    |> Map.merge(Keyword.get(extra, :metadata, %{}))
    |> compact_metadata()
  end

  defp failure_reason_class(%Ecto.Changeset{}), do: "validation_failed"
  defp failure_reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_class({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_class({reason, _detail}) when is_binary(reason), do: reason
  defp failure_reason_class(_reason), do: "unknown"

  defp validation_fields(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Keyword.keys()
    |> Enum.map(&Atom.to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp validation_fields(_reason), do: []

  defp compact_metadata(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> value in [nil, [], %{}] end)
    |> Map.new()
  end

  defp member_resource_label("project_member", nil), do: "Agent Swarm member write attempt"

  defp member_resource_label("project_member", user_id),
    do: "Agent Swarm member #{short_id(user_id)}"

  defp member_resource_label(_resource_type, user_id), do: "Org member #{short_id(user_id)}"

  defp audit_enabled?(opts) do
    Keyword.get(opts, :audit, false) ||
      present?(Keyword.get(opts, :actor_user_id)) ||
      present?(Keyword.get(opts, :actor_label))
  end

  defp short_id(value) when is_binary(value), do: String.slice(value, 0, 8)
  defp short_id(value), do: value

  defp default_project_min_role(:write), do: "admin"
  defp default_project_min_role(:manage), do: "admin"
  defp default_project_min_role(_), do: "user"

  defp check_org(org_id, user_id, min_role) do
    with {:ok, role} <- org_role(org_id, user_id),
         true <- @org_rank[role] >= @org_rank[min_role] do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp check_project(project_id, user_id, min_role) do
    with {:ok, role} <- project_role(project_id, user_id),
         role_rank when is_integer(role_rank) <- @project_rank[role],
         min_rank when is_integer(min_rank) <- @project_rank[min_role],
         true <- role_rank >= min_rank do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  # Org owner/admin membership on the project's org implies project admin.
  # Ordinary org membership does not grant Agent Swarm access.
  defp org_derived_project_role(project_id, user_id) do
    from(p in Project,
      join: m in OrgMembership,
      on: m.org_id == p.org_id,
      where: p.id == ^project_id and m.user_id == ^user_id,
      select: m.role
    )
    |> Repo.one()
    |> case do
      nil -> nil
      org_role when org_role in ["owner", "admin"] -> "admin"
      "member" -> nil
    end
  end

  defp max_project_role(nil, nil), do: nil
  defp max_project_role(nil, b), do: b
  defp max_project_role(a, nil), do: a

  defp max_project_role(a, b) do
    if @project_rank[a] >= @project_rank[b], do: a, else: b
  end
end
