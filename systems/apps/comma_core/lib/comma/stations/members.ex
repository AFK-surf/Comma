defmodule Comma.Stations.Members do
  @moduledoc """
  `SalixStore.StationMembers` for Comma: a Comma Workspace is a Salix Group,
  and the user's role in it is their active Membership role in the active
  Workspace. Owners and admins manage the Group's stations, as in
  `Comma.Stations`; a viewer is read-only. Only an active Workspace has stations: those of a
  suspended or deleted one are refused as removed ones are.
  """

  @behaviour SalixStore.StationMembers

  import Ecto.Query

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Repo

  @managers ~w(owner admin)
  @read_only ~w(viewer)

  @impl true
  def requester(
        _tenant,
        group,
        %{"provider" => "telegram", "managed_by" => "comma_product", "connect_id" => connect},
        subject
      ) do
    case Comma.TelegramLinks.resolve_sender(subject) do
      {:ok,
       %{link: %{connect_id: ^connect}, user: user, workspace: %{"default_group_id" => ^group}}} ->
        {:ok, user["id"]}

      _ ->
        :none
    end
  end

  def requester(
        _tenant,
        group,
        %{
          "provider" => "wechat",
          "managed_by" => "comma_product",
          "connect_id" => connect,
          "wechat_id" => subject,
          "owner_user_id" => owner
        },
        subject
      ) do
    with {:ok, workspace} <- Comma.Workspaces.authorize_group(%{"id" => owner}, %{}, group),
         {:ok, %{current: ^connect}} <- Comma.WeChatLinks.references(workspace["id"]) do
      {:ok, owner}
    else
      _ -> :none
    end
  end

  def requester(_, _, _, _), do: :none

  @impl true
  def role(tenant_id, group_id, user_id) do
    Repo.one(
      from(w in Workspace,
        join: m in WorkspaceMembership,
        on: m.workspace_id == w.id,
        where:
          w.salix_tenant_id == ^tenant_id and w.salix_group_id == ^group_id and
            w.status == "active" and m.user_id == ^user_id and m.status == "active",
        select: m.role
      )
    )
    |> case do
      role when is_binary(role) -> {:ok, role}
      nil -> :none
    end
  end

  @impl true
  def manager_role?(role), do: role in @managers

  @impl true
  def read_only_role?(role), do: role in @read_only

  @impl true
  def workspace_active?(tenant_id, group_id) do
    Repo.one(
      from(w in Workspace,
        where: w.salix_tenant_id == ^tenant_id and w.salix_group_id == ^group_id,
        select: w.status
      )
    )
    |> case do
      nil -> :none
      status -> status == "active"
    end
  end

  @impl true
  def workspace_name(tenant_id, group_id) do
    Repo.one(
      from(w in Workspace,
        where: w.salix_tenant_id == ^tenant_id and w.salix_group_id == ^group_id,
        select: w.name
      )
    )
    |> case do
      name when is_binary(name) -> {:ok, name}
      nil -> :none
    end
  end
end
