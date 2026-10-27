defmodule CommaWeb.Coding.Members do
  @moduledoc """
  Who the members of a Comma Workspace's L4ES workspace are
  (`config :salix_web, :coding_members`, `SalixWeb.CodingSandboxes`): the
  Workspace's active members who may open a coding sandbox's terminal, as
  Comma's terminal link allows (`CommaWeb.Coding.Endpoints.terminal/3`), so
  no viewer, by Comma user id (the subject of their Comma sign-in) and email.
  A suspended or deleted Workspace has none.
  """

  import Ecto.Query

  alias Comma.Data.{Workspace, WorkspaceMembership}
  alias Comma.Repo

  def members(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    user_ids =
      Repo.all(
        from(w in Workspace,
          join: m in WorkspaceMembership,
          on: m.workspace_id == w.id,
          where:
            w.salix_tenant_id == ^tenant_id and w.salix_group_id == ^group_id and
              w.status == "active" and m.status == "active" and m.role != "viewer",
          order_by: m.inserted_at,
          select: m.user_id
        )
      )

    {:ok,
     for id <- user_ids do
       case Comma.Accounts.get_user(id) do
         {:ok, %{"email" => email}} when is_binary(email) -> %{subject: id, email: email}
         _ -> %{subject: id}
       end
     end}
  end
end
