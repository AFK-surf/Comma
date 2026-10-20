defmodule CommaWeb.NativePushListener do
  require SystemsRuntime.Proc

  @moduledoc """
  Shares one Conversation Group owner subscription per Group with APNs targets.
  Recovery pages the address index at 100 rows/step and reconciles bounded Group
  task and Router projections. APNs acceptance does not prove delivery.
  """
  use SystemsRuntime.Server
  alias Comma.{Notifications, RouterNotifications, Workspaces}

  def start_link(_opts), do: SystemsRuntime.Server.start_link(__MODULE__, nil, name: __MODULE__)

  def child_specs do
    if SystemsRuntime.get_env(:comma_core, :start_repo, false) and
         Comma.Notifications.APNs.configured?(), do: [__MODULE__], else: []
  end

  @impl true
  def init(_) do
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), {:recover, nil})
    {:ok, %{groups: %{}, cycle: MapSet.new()}}
  end

  @impl true
  def handle_info({:native_push_group, group}, state) do
    state = ensure_group(state, group)
    _ = Notifications.enqueue_activity(group)
    _ = Notifications.enqueue_router(group)
    {:noreply, %{state | cycle: MapSet.put(state.cycle, group)}}
  end

  def handle_info(
        {:group_conversation_list_invalidated, group, "agent_task", task, _version},
        state
      ) do
    if is_binary(task), do: Notifications.enqueue_task(group, task)
    _ = Notifications.enqueue_activity(group)
    {:noreply, state}
  end

  def handle_info(
        {:group_conversation_list_invalidated, group, "user_chat", conversation, _},
        state
      ) do
    # Only the Workspace's canonical Router conversation owns phone unread.
    # The relay handles reconciliation outside this subscription process.
    case state.groups[group] do
      {pid, _} -> SystemsRuntime.Proc.send(pid, {:reconcile_router, conversation})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:native_push_group_resynced, group}, state) do
    _ = Notifications.enqueue_activity(group)
    _ = Notifications.enqueue_router(group)
    {:noreply, state}
  end

  def handle_info({:recover, cursor}, state) do
    page = Notifications.recovery_page(cursor)

    state =
      Enum.reduce(page, state, fn target, state ->
        state = ensure_group(state, target.group_id)

        if not MapSet.member?(state.cycle, target.group_id) do
          _ = Notifications.enqueue_activity(target.group_id)
          _ = Notifications.enqueue_router(target.group_id)

          case state.groups[target.group_id] do
            {pid, _} -> SystemsRuntime.Proc.send(pid, {:reconcile_router, nil})
            _ -> :ok
          end
        end

        %{state | cycle: MapSet.put(state.cycle, target.group_id)}
      end)

    if length(page) == 100 do
      SystemsClock.send_after(SystemsRuntime.Proc.self(), {:recover, List.last(page).id}, 100)
      {:noreply, state}
    else
      # Exiting a subscriber process removes its owner registrations. Keep one
      # relay per Group so expired/logged-out sessions do not retain subscriptions.
      {kept, retired} =
        Enum.split_with(state.groups, fn {group, _} -> MapSet.member?(state.cycle, group) end)

      Enum.each(retired, fn {_group, {pid, _ref}} -> SystemsRuntime.Proc.exit(pid, :shutdown) end)
      SystemsClock.send_after(SystemsRuntime.Proc.self(), {:recover, nil}, 60_000)
      {:noreply, %{state | groups: Map.new(kept), cycle: MapSet.new()}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    groups = Map.reject(state.groups, fn {_group, {_pid, monitor}} -> monitor == ref end)
    {:noreply, %{state | groups: groups}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp ensure_group(state, group) do
    if Map.has_key?(state.groups, group) do
      state
    else
      parent = SystemsRuntime.Proc.self()
      {pid, ref} = spawn_monitor(fn -> relay(parent, group) end)
      put_in(state.groups[group], {pid, ref})
    end
  end

  defp relay(parent, group) do
    parent_ref = SystemsRuntime.Proc.monitor(parent)

    with {:ok, workspace} <- Workspaces.get_by_group(group),
         {:ok, workspace} <- Comma.Salix.Client.impl().resolve_workspace_scope(workspace),
         {:ok, %{"owner_pid" => owner}} <-
           Comma.Salix.Client.impl().subscribe_group_conversation_list(
             workspace,
             "agent_task",
             SystemsRuntime.Proc.self()
           ),
         {:ok, _} <-
           Comma.Salix.Client.impl().subscribe_group_conversation_list(
             workspace,
             "user_chat",
             SystemsRuntime.Proc.self()
           ) do
      _ = RouterNotifications.reconcile(workspace)
      SystemsRuntime.Proc.send(parent, {:native_push_group_resynced, group})
      receive_loop(parent, parent_ref, SystemsRuntime.Proc.monitor(owner), workspace)
    end
  end

  defp receive_loop(parent, parent_ref, owner_ref, workspace) do
    SystemsRuntime.Proc.receive do
      {:group_conversation_list_invalidated, _, kind, _, _} = event
      when kind in ["agent_task", "user_chat"] ->
        SystemsRuntime.Proc.send(parent, event)
        receive_loop(parent, parent_ref, owner_ref, workspace)

      {:reconcile_router, conversation} ->
        if conversation == nil or conversation == workspace["router_conversation_id"] do
          case RouterNotifications.reconcile(workspace) do
            {:ok, _} -> Notifications.enqueue_router(workspace["default_group_id"])
            _ -> :ok
          end
        end

        receive_loop(parent, parent_ref, owner_ref, workspace)

      {:DOWN, ref, :process, _, _} when ref in [parent_ref, owner_ref] ->
        :ok

      _ ->
        receive_loop(parent, parent_ref, owner_ref, workspace)
    end
  end
end
