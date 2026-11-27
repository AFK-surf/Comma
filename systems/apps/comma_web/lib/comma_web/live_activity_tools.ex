defmodule CommaWeb.LiveActivityTools do
  @moduledoc """
  Comma adapter for `SalixAgent.Tools.LiveActivity` (`live_activity.upsert`,
  `live_activity.end`, `live_activity.list`). Available to Router, Worker, and
  Background Loops within a Comma Workspace's Group.
  """

  alias Comma.{LiveStatuses, Workspaces}
  alias SalixIM.{ConversationIds, GroupDirectory}

  def upsert(args, ctx) when is_map(args) and is_map(ctx) do
    with {:ok, workspace, group_id} <- resolve_scope(ctx) do
      conversation_id = resolve_conversation_id(ctx, group_id)

      with {:ok, status} <-
             LiveStatuses.upsert(workspace["id"], group_id, args,
               conversation_id: conversation_id
             ) do
        {:ok, %{"status" => "ok", "live_activity" => status}}
      end
    end
  end

  def end_activity(args, ctx) when is_map(args) and is_map(ctx) do
    with {:ok, _workspace, group_id} <- resolve_scope(ctx),
         {:ok, status} <- LiveStatuses.end_status(group_id, args) do
      {:ok, %{"status" => "ended", "live_activity" => status}}
    end
  end

  def list(_args, ctx) when is_map(ctx) do
    with {:ok, _workspace, group_id} <- resolve_scope(ctx) do
      {:ok, %{"status" => "ok", "live_activities" => LiveStatuses.list_active(group_id)}}
    end
  end

  defp resolve_scope(ctx) do
    group_id = ctx[:group_id]
    tenant_id = ctx[:tenant_id]

    with true <- is_binary(group_id) and group_id != "",
         {:ok, workspace} <- Workspaces.get_by_group(group_id),
         true <- is_nil(tenant_id) or workspace["salix_tenant_id"] == tenant_id do
      {:ok, workspace, group_id}
    else
      _ -> {:error, :workspace_required}
    end
  end

  defp resolve_conversation_id(ctx, group_id) do
    ctx[:task_conversation_id] || ctx[:conversation_id] || home_router_conversation_id(group_id)
  end

  defp home_router_conversation_id(group_id) do
    with {:ok, record} <- GroupDirectory.get_group(group_id),
         {:ok, home} <- ConversationIds.group_router(record) do
      home
    else
      _ -> nil
    end
  end
end
