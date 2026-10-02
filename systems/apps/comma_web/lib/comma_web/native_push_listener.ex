defmodule CommaWeb.NativePushListener do
  @moduledoc """
  Shares one Conversation Group owner subscription per Group with APNs targets.
  Recovery pages the address index at 100 rows/step and only rereads exact followed
  Tasks. Notifications are best effort; APNs acceptance does not prove delivery.
  """
  use GenServer
  alias Comma.{Notifications, Workspaces}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def child_specs do
    if Application.get_env(:comma_core, :start_repo, false) and
         Comma.Notifications.APNs.configured?(), do: [__MODULE__], else: []
  end

  @impl true
  def init(_) do
    send(self(), {:recover, nil})
    {:ok, %{groups: %{}, cycle: MapSet.new()}}
  end

  @impl true
  def handle_info({:native_push_group, group}, state) do
    state = ensure_group(state, group)
    {:noreply, %{state | cycle: MapSet.put(state.cycle, group)}}
  end

  def handle_info(
        {:group_conversation_list_invalidated, group, "agent_task", task, _version},
        state
      ) do
    _ = Notifications.enqueue_task(group, task)
    {:noreply, state}
  end

  def handle_info({:recover, cursor}, state) do
    page = Notifications.recovery_page(cursor)

    state =
      Enum.reduce(page, state, fn target, state ->
        state = ensure_group(state, target.group_id)
        if target.kind == "live_activity", do: Notifications.enqueue(target.id)
        %{state | cycle: MapSet.put(state.cycle, target.group_id)}
      end)

    if length(page) == 100 do
      Process.send_after(self(), {:recover, List.last(page).id}, 100)
      {:noreply, state}
    else
      # Exiting a subscriber process removes its owner registrations. Keep one
      # relay per Group so expired/logged-out sessions do not retain subscriptions.
      {kept, retired} =
        Enum.split_with(state.groups, fn {group, _} -> MapSet.member?(state.cycle, group) end)

      Enum.each(retired, fn {_group, {pid, _ref}} -> Process.exit(pid, :shutdown) end)
      Process.send_after(self(), {:recover, nil}, 60_000)
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
      parent = self()
      {pid, ref} = spawn_monitor(fn -> relay(parent, group) end)
      put_in(state.groups[group], {pid, ref})
    end
  end

  defp relay(parent, group) do
    parent_ref = Process.monitor(parent)

    with {:ok, workspace} <- Workspaces.get_by_group(group),
         {:ok, %{"owner_pid" => owner}} <-
           Comma.Salix.Client.impl().subscribe_group_conversation_list(
             workspace,
             "agent_task",
             self()
           ) do
      receive_loop(parent, parent_ref, Process.monitor(owner))
    end
  end

  defp receive_loop(parent, parent_ref, owner_ref) do
    receive do
      {:group_conversation_list_invalidated, _, "agent_task", _, _} = event ->
        send(parent, event)
        receive_loop(parent, parent_ref, owner_ref)

      {:DOWN, ref, :process, _, _} when ref in [parent_ref, owner_ref] ->
        :ok

      _ ->
        receive_loop(parent, parent_ref, owner_ref)
    end
  end
end
