defmodule CommaWeb.Coding.SandboxAdmission do
  @moduledoc """
  Whether a Comma Workspace may start a managed sandbox (L4ES)
  (`config :salix_web, :sandbox_admission`, `SalixWeb.CodingSandboxes.authorize/5`):
  not when its owner's email is restricted (`Comma.Auth.EmailRestriction`). The Workspace's own stations, a VMM Station or a
  member's computer, are not asked about.
  """

  import Ecto.Query

  alias Comma.Data.Workspace
  alias Comma.Repo

  def admitted?(tenant_id, group_id) when is_binary(tenant_id) and is_binary(group_id) do
    owner =
      Repo.one(
        from(w in Workspace,
          where:
            w.salix_tenant_id == ^tenant_id and w.salix_group_id == ^group_id and
              w.status != "deleted",
          select: w.owner_user_id,
          limit: 1
        )
      )

    case owner && Comma.Accounts.get_user(owner) do
      {:ok, %{"email" => email}} when is_binary(email) ->
        not Comma.Auth.EmailRestriction.restricted?(email)

      _ ->
        true
    end
  end

  def admitted?(_tenant_id, _group_id), do: true
end
