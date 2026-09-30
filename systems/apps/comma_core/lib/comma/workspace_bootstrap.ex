defmodule Comma.WorkspaceBootstrap do
  @moduledoc """
  Thin, idempotent default-Workspace command for authenticated Comma users.

  `Comma.Workspaces` and its durable external operation are the only Workspace
  state machine. This module locks the account, ensures the v1 default
  Workspace exists, and maps the internal `active` state to the public
  bootstrap contract's `ready` state.
  """

  import Ecto.Query

  alias Comma.Accounts.User
  alias Comma.Data.Workspace
  alias Comma.{Repo, Workspaces}

  @retry_after_seconds 2

  @doc false
  def retry_after_seconds, do: @retry_after_seconds

  @doc "Ensure the authenticated user has exactly one v1 default Workspace."
  def ensure_default(user_id) when is_binary(user_id) do
    Repo.transaction(fn ->
      case Repo.one(from(user in User, where: user.id == ^user_id, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback(:not_found)

        %User{status: "disabled"} ->
          Repo.rollback(:disabled)

        %User{} ->
          with {:ok, workspace} <- load_or_create_default(user_id),
               {:ok, result} <- public_result(workspace) do
            result
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  def ensure_default(_user_id), do: {:error, :not_found}

  defp load_or_create_default(user_id) do
    rows =
      Repo.all(
        from(workspace in Workspace,
          where: workspace.owner_user_id == ^user_id and workspace.status != "deleted",
          order_by: [asc: workspace.inserted_at, asc: workspace.id],
          limit: 2
        )
      )

    case rows do
      [] ->
        Workspaces.create_for_user(user_id)

      [workspace] ->
        if Workspaces.active_owner?(workspace, user_id) do
          Workspaces.get(workspace.id)
        else
          {:error, :workspace_invariant}
        end

      [_first, _second] ->
        {:error, :workspace_invariant}
    end
  end

  defp public_result(%{"status" => "active"} = workspace) do
    {:ok,
     %{
       "status" => "ready",
       "workspace" => public_workspace(workspace, "ready")
     }}
  end

  defp public_result(%{"status" => "provisioning"} = workspace) do
    {:ok,
     %{
       "retry_after_seconds" => @retry_after_seconds,
       "status" => "provisioning",
       "workspace" => public_workspace(workspace, "provisioning")
     }}
  end

  defp public_result(%{"status" => status})
       when status in ["provisioning_failed", "failed"],
       do: {:error, :workspace_provisioning_failed}

  defp public_result(_workspace), do: {:error, :workspace_unavailable}

  defp public_workspace(workspace, api_status) do
    workspace
    |> Workspaces.public()
    |> Map.put("status", api_status)
  end
end
