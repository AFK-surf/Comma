defmodule Comma.CondensedWorkspace do
  @moduledoc """
  Comma access to a Group's Condensed Workspace
  (docs/agent-runtime.md#condensed-workspace).

  The Workspace owner turns the feature on or off and edits the statements.
  Comma Group access has no other role today, so the owner is also the only
  editor. Salix owns the statements and the flag.
  """

  alias Comma.Workspaces

  @spec get(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(user, session, group_id) do
    with {:ok, workspace} <- authorize(user, session, group_id) do
      Comma.Salix.Client.get_group_condensed_workspace(workspace)
    end
  end

  @spec update_settings(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_settings(user, session, group_id, attrs) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, enabled} <- enabled(attrs) do
      Comma.Salix.Client.set_group_condensed_workspace_enabled(workspace, enabled)
    end
  end

  @spec update(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(user, session, group_id, attrs) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, operations} <- operations(attrs) do
      Comma.Salix.Client.update_group_condensed_workspace(workspace, operations, user["id"])
    end
  end

  defp authorize(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, nil) do
      {:ok, workspace}
    end
  end

  defp enabled(%{"enabled" => enabled}) when is_boolean(enabled), do: {:ok, enabled}
  defp enabled(_attrs), do: {:error, {:bad_request, "enabled must be a boolean"}}

  defp operations(%{"operations" => operations}) when is_list(operations), do: {:ok, operations}
  defp operations(_attrs), do: {:error, {:bad_request, "operations must be a list"}}
end
