defmodule BridgeForTeams.StationMembers do
  @moduledoc """
  `SalixStore.StationMembers` for BridgeForTeams: a Project is a Salix Group
  in its Organization's tenant. An Organization owner or admin has that role
  in every active Project of the Organization; anyone else has their explicit
  Project role (`admin` or `user`), and an Organization member without one
  has none (`BridgeForTeams.Memberships`). Owners and admins, of the
  Organization or the Project, manage the Group's stations; a Project `user`
  is a member. The stations of a Project that is archived or not active, or
  whose Organization is not active, are refused as removed ones are
  (`workspace_active?/2`).

  A member removed from a Project or from the Organization loses the member
  credentials issued until then (`revoke_removed/2`): the stations of those
  Groups check credentials offline, so Salix keeps a revocation per Group
  (`SalixStore.Stations.Revocations`).
  """

  @behaviour SalixStore.StationMembers

  import Ecto.Query

  alias BridgeForTeams.Repo
  alias BridgeForTeams.Schema.{Organization, OrgMembership, Project, ProjectMembership}

  @org_managers ~w(owner admin)
  @managers ~w(owner admin)

  @impl true
  def requester(tenant, group, %{"provider" => provider, "app_id" => app}, subject)
      when provider in ~w(feishu lark) and is_binary(app) and app != "" do
    case Repo.all(
           from(p in Project,
             join: o in Organization,
             on: o.id == p.org_id,
             join: s in BridgeForTeams.Schema.OrgSsoConnection,
             on: s.org_id == o.id,
             join: i in BridgeForTeams.Schema.OrgSsoIdentity,
             on: i.org_id == o.id and i.provider == s.provider,
             where:
               p.salix_group_id == ^group and o.salix_tenant_id == ^tenant and
                 s.provider == ^provider and s.client_id == ^app and
                 i.provider_subject == ^subject,
             distinct: i.user_id,
             select: i.user_id,
             limit: 2
           )
         ) do
      [user] -> {:ok, user}
      _ -> :none
    end
  end

  def requester(_, _, _, _), do: :none

  @impl true
  def role(tenant_id, group_id, user_id) do
    with {:ok, user_id} <- Ecto.UUID.cast(user_id),
         %Project{} = project <- project(tenant_id, group_id) do
      case org_role(project.org_id, user_id) do
        role when role in @org_managers -> {:ok, role}
        _ -> project_role(project.id, user_id)
      end
    else
      _ -> :none
    end
  end

  @impl true
  def manager_role?(role), do: role in @managers

  # A Project has no read-only role.
  @impl true
  def read_only_role?(_role), do: false

  @impl true
  def workspace_name(tenant_id, group_id) do
    case project(tenant_id, group_id) do
      %Project{name: name} when is_binary(name) -> {:ok, name}
      _ -> :none
    end
  end

  @impl true
  def workspace_active?(tenant_id, group_id) do
    Repo.all(
      from(p in Project,
        join: o in Organization,
        on: o.id == p.org_id,
        where: p.salix_group_id == ^group_id and o.salix_tenant_id == ^tenant_id,
        select: p.status == "active" and is_nil(p.archived_at) and o.status == "active"
      )
    )
    |> case do
      [] -> :none
      answers -> Enum.any?(answers)
    end
  end

  @doc "The Group of a Project, as `[{tenant_id, group_id}]`; empty when it has none."
  def project_groups(project_id) do
    Repo.all(from([p, o] in groups(), where: p.id == ^project_id))
  end

  @doc "The Groups of an Organization's Projects, as `[{tenant_id, group_id}]`."
  def org_groups(org_id) do
    Repo.all(from([p, o] in groups(), where: p.org_id == ^org_id))
  end

  defp groups do
    from(p in Project,
      join: o in Organization,
      on: o.id == p.org_id,
      where: not is_nil(p.salix_group_id) and not is_nil(o.salix_tenant_id),
      select: {o.salix_tenant_id, p.salix_group_id}
    )
  end

  @doc """
  Takes back the member credentials a removed member holds for `groups`.
  Answers the revocations, for `SalixStore.Stations.Events.publish/1` once
  the removal has committed.
  """
  def revoke_removed(groups, user_id),
    do: SalixStore.Stations.Revocations.revoke(groups, "sub", to_string(user_id))

  defp project(tenant_id, group_id) do
    Repo.one(
      from(p in Project,
        join: o in Organization,
        on: o.id == p.org_id,
        where:
          p.salix_group_id == ^group_id and o.salix_tenant_id == ^tenant_id and
            p.status == "active" and is_nil(p.archived_at) and o.status == "active"
      )
    )
  end

  defp org_role(org_id, user_id) do
    Repo.one(
      from(m in OrgMembership,
        where: m.org_id == ^org_id and m.user_id == ^user_id,
        select: m.role
      )
    )
  end

  defp project_role(project_id, user_id) do
    Repo.one(
      from(m in ProjectMembership,
        where: m.project_id == ^project_id and m.user_id == ^user_id,
        select: m.role
      )
    )
    |> case do
      role when is_binary(role) -> {:ok, role}
      nil -> :none
    end
  end
end
