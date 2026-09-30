defmodule SalixCluster.ConversationPlacement do
  @moduledoc """
  Cluster-aware placement for group-level and conversation-local owner actors.

  Conversation-local placement uses `{group_id, conversation_id}` and group
  collection placement uses `{group_id}`. The owner node starts the matching
  local actor; non-owner nodes route through `:erpc`.
  """

  @behaviour SalixIM.ConversationPlacement

  @impl true
  def ensure_started(group_id, conversation_id, opts) do
    owner = SalixCluster.Ring.owner(owner_key(group_id, conversation_id))

    if owner == Node.self() do
      SalixIM.ConversationFleet.ensure_started(group_id, conversation_id, opts)
    else
      case :erpc.call(
             owner,
             SalixIM.ConversationFleet,
             :ensure_started,
             [group_id, conversation_id, opts],
             5_000
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} = err -> err
      end
    end
  rescue
    e ->
      {:error, {:owner_unreachable, owner_key(group_id, conversation_id), e}}
  catch
    :exit, reason ->
      {:error, {:owner_unreachable, owner_key(group_id, conversation_id), reason}}
  end

  @impl true
  def ensure_group_started(group_id, opts) do
    owner = SalixCluster.Ring.owner(group_owner_key(group_id))

    if owner == Node.self() do
      SalixIM.ConversationFleet.ensure_group_started(group_id, opts)
    else
      case :erpc.call(
             owner,
             SalixIM.ConversationFleet,
             :ensure_group_started,
             [group_id, opts],
             5_000
           ) do
        {:ok, pid} -> {:ok, pid}
        {:error, _} = err -> err
      end
    end
  rescue
    e ->
      {:error, {:owner_unreachable, group_owner_key(group_id), e}}
  catch
    :exit, reason ->
      {:error, {:owner_unreachable, group_owner_key(group_id), reason}}
  end

  @impl true
  def notify_group_conversation_mutation_if_running(group_id, mutation) do
    owner = SalixCluster.Ring.owner(group_owner_key(group_id))

    if owner == Node.self() do
      SalixIM.ConversationGroupActor.notify_conversation_mutation_if_running(
        group_id,
        mutation
      )
    else
      :erpc.cast(
        owner,
        SalixIM.ConversationGroupActor,
        :notify_conversation_mutation_if_running,
        [group_id, mutation]
      )
    end

    :ok
  rescue
    _exception -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp owner_key(group_id, conversation_id), do: group_id <> ":" <> conversation_id
  defp group_owner_key(group_id), do: "conversation-group:" <> group_id
end
