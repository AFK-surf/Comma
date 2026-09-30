defmodule Comma.TaskLabels do
  @moduledoc """
  Product API for the Group's Task label catalog.

  Comma authorizes the caller against the Group and then reads or writes the
  catalog through `Comma.Salix.Client`; Salix owns the record and the agent
  proposal lifecycle (`SalixIM.TaskLabels`). Every write here is a *human*
  decision. `resolve_proposal/5` approves or rejects one change;
  `update_policy/4` grants or revokes automatic approval of future proposals.
  """

  alias Comma.Workspaces

  @spec list(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def list(user, session, group_id) do
    with {:ok, workspace} <- authorize(user, session, group_id) do
      Comma.Salix.Client.list_group_task_labels(workspace)
    end
  end

  @spec create(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create(user, session, group_id, attrs) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, attrs} <- label_attrs(attrs) do
      Comma.Salix.Client.create_group_task_label(workspace, attrs)
    end
  end

  @spec update(map(), map(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update(user, session, group_id, label_id, attrs) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, attrs} <- label_attrs(attrs) do
      Comma.Salix.Client.update_group_task_label(workspace, label_id, attrs)
    end
  end

  @spec delete(map(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def delete(user, session, group_id, label_id) do
    with {:ok, workspace} <- authorize(user, session, group_id) do
      Comma.Salix.Client.delete_group_task_label(workspace, label_id)
    end
  end

  @spec update_policy(map(), map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_policy(user, session, group_id, attrs) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, policy} <- policy(attrs) do
      Comma.Salix.Client.update_group_task_label_policy(workspace, policy)
    end
  end

  @spec resolve_proposal(map(), map(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def resolve_proposal(user, session, group_id, proposal_id, attrs) do
    with {:ok, workspace} <- authorize(user, session, group_id),
         {:ok, resolution} <- decision(attrs) do
      Comma.Salix.Client.resolve_group_task_label_proposal(workspace, proposal_id, resolution)
    end
  end

  defp authorize(user, session, group_id) do
    with {:ok, workspace} <- Workspaces.authorize_group(user, session, group_id),
         :ok <- Workspaces.group_session_scope(session, group_id, nil) do
      Comma.Salix.Client.impl().resolve_workspace_scope(workspace)
    end
  end

  # Only the three human-editable fields cross the boundary; Salix validates
  # their values so the product and the Router share one rule set.
  defp label_attrs(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.take(["name", "color", "description"])

    if Enum.all?(attrs, fn {_key, value} -> is_binary(value) end),
      do: {:ok, attrs},
      else: {:error, {:bad_request, "name, color and description must be strings"}}
  end

  defp label_attrs(_attrs), do: {:error, {:bad_request, "expected a JSON object"}}

  defp policy(%{"approval_policy" => policy}) when policy in ["ask", "auto"], do: {:ok, policy}
  defp policy(_attrs), do: {:error, {:bad_request, "approval_policy must be ask or auto"}}

  defp decision(%{"decision" => decision} = attrs) when decision in ["approve", "reject"] do
    auto_approve = Map.get(attrs, "auto_approve", false)

    if is_boolean(auto_approve) and (not auto_approve or decision == "approve"),
      do: {:ok, %{"decision" => decision, "auto_approve" => auto_approve}},
      else:
        {:error, {:bad_request, "auto_approve must be a boolean and is only valid with approve"}}
  end

  defp decision(_attrs), do: {:error, {:bad_request, "decision must be approve or reject"}}
end
