defmodule Comma.WeChatLinks do
  @moduledoc "Workspace references to Salix-owned WeChat connections and pending QR login."
  import Ecto.Query
  alias Comma.{Repo, Workspaces}
  alias Comma.Data.Workspace

  # The ingress has checked the provider peer. This exact indexed Group lookup
  # also requires the current product binding and active owner before UI reads.
  def resolve_sender(%{"managed_by" => "comma_product"} = connect) do
    with {:ok, user} <- Comma.Accounts.get_user(connect["owner_user_id"]),
         {:ok, workspace} <- Workspaces.authorize_group(user, %{}, connect["group_id"]),
         {:ok, refs} <- references(workspace["id"]),
         true <-
           refs.current == connect["connect_id"] and
             workspace["salix_tenant_id"] == connect["tenant_id"] do
      {:ok, %{user: user, workspace: workspace}}
    else
      _ -> {:error, :wechat_not_linked}
    end
  end

  def resolve_sender(_), do: {:error, :wechat_not_linked}

  def references(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = workspace ->
        {:ok,
         %{current: workspace.wechat_connect_id, pending: workspace.wechat_pending_connect_id}}

      nil ->
        {:error, :not_found}
    end
  end

  def with_lock(user, session, workspace_id, fun) do
    Repo.checkout(
      fn ->
        key = "comma.wechat:" <> workspace_id

        case Repo.query!("SELECT pg_try_advisory_lock(hashtextextended($1, 0))", [key]).rows do
          [[true]] ->
            try do
              with {:ok, workspace} <- Workspaces.authorize(user, session, workspace_id),
                   {:ok, refs} <- references(workspace_id),
                   do: fun.(workspace, refs)
            after
              Repo.query!("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [key])
            end

          [[false]] ->
            {:error, :wechat_link_busy}
        end
      end,
      timeout: 120_000
    )
  end

  # Only called under with_lock, after current Workspace authorization.
  def put(workspace, current, pending) do
    query =
      from(w in Workspace,
        where:
          w.id == ^workspace["id"] and w.owner_user_id == ^workspace["owner_user_id"] and
            w.salix_group_id == ^workspace["default_group_id"] and w.status == "active"
      )

    case Repo.update_all(query,
           set: [wechat_connect_id: current, wechat_pending_connect_id: pending]
         ) do
      {1, _} -> :ok
      _ -> {:error, :forbidden}
    end
  end
end
