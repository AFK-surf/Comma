defmodule Comma.WorkspaceTestSupport do
  @moduledoc false

  import ExUnit.Assertions

  alias Comma.Data.{ExternalOperation, Workspace}
  alias Comma.{Repo, WorkspaceBootstrap}

  def create_ready_workspace!(user_or_id, attrs \\ %{}) do
    user_id = user_id(user_or_id)
    attrs = if is_binary(attrs), do: %{"name" => attrs}, else: stringify(attrs)

    attrs = Map.put_new(attrs, "vm", %{"enabled" => false})

    assert is_binary(user_id)
    assert {:ok, pending} = WorkspaceBootstrap.ensure_default(user_id)
    workspace_id = pending["workspace"]["id"]

    unless attrs == %{} do
      workspace = Repo.get!(Workspace, workspace_id)
      changes = Map.take(attrs, ["name", "vm"])
      assert {:ok, _workspace} = Repo.update(Workspace.changeset(workspace, changes))
    end

    operation =
      Repo.get_by!(ExternalOperation,
        operation_type: "workspace_convergence",
        owner_id: workspace_id,
        generation: 1
      )

    assert {:ok, %{status: "succeeded"}} =
             Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

    assert {:ok, %{"status" => "ready", "workspace" => %{"id" => ^workspace_id}}} =
             WorkspaceBootstrap.ensure_default(user_id)

    assert {:ok, workspace} = Comma.Workspaces.get(workspace_id)
    workspace
  end

  @doc """
  Create one more ready Workspace for an account that already owns the default.

  `create_ready_workspace!/2` goes through `WorkspaceBootstrap.ensure_default/1`,
  which owns exactly one default Workspace per account. Use this helper to reach
  the multi-Workspace states that only the Workspaces command supports.
  """
  def create_additional_ready_workspace!(user_or_id, attrs \\ %{}) do
    user_id = user_id(user_or_id)
    attrs = if is_binary(attrs), do: %{"name" => attrs}, else: stringify(attrs)
    attrs = Map.put_new(attrs, "vm", %{"enabled" => false})

    assert is_binary(user_id)
    assert {:ok, created} = Comma.Workspaces.create_for_user(user_id, attrs)
    workspace_id = created["id"]

    operation =
      Repo.get_by!(ExternalOperation,
        operation_type: "workspace_convergence",
        owner_id: workspace_id,
        generation: 1
      )

    assert {:ok, %{status: "succeeded"}} =
             Comma.Workers.WorkspaceConvergence.run(operation.operation_id)

    assert {:ok, %{"status" => "active"} = workspace} = Comma.Workspaces.get(workspace_id)
    workspace
  end

  def cleanup_committed_user!(repo, user_id) when is_pid(repo) and is_binary(user_id) do
    Ecto.Adapters.SQL.query!(
      repo,
      """
      DELETE FROM oban_jobs
      WHERE args->>'operation_id' IN (
        SELECT operation_id
        FROM comma_external_operations
        WHERE owner_id IN (
          SELECT id FROM comma_workspaces WHERE owner_user_id = $1
        )
      )
      """,
      [user_id]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      """
      DELETE FROM comma_external_operations
      WHERE owner_id IN (
        SELECT id FROM comma_workspaces WHERE owner_user_id = $1
      )
      """,
      [user_id]
    )

    Ecto.Adapters.SQL.query!(
      repo,
      "DELETE FROM comma_workspaces WHERE owner_user_id = $1",
      [user_id]
    )

    Ecto.Adapters.SQL.query!(repo, "DELETE FROM comma_users WHERE id = $1", [user_id])
    :ok
  end

  defp user_id(%{"id" => id}), do: id
  defp user_id(%{id: id}), do: id
  defp user_id(id), do: id

  defp stringify(attrs),
    do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
