defmodule SalixIM.ConversationInput do
  @moduledoc """
  Generic runtime input adapter for conversation and agent participant facts.

  Product and transport callers use this adapter when agent context must be
  resolved. `ConversationServer` receives only prepared canonical facts and
  remains responsible for generic validation, routing, and owner placement.

  The bounded Router Participant reconciliation protocol is modeled in
  `tla/salix/CommaAssistantRouterReassignment.tla`.
  """

  alias SalixIM.{AgentDeliveryPayload, ConversationServer, Conversations, GroupDirectory}

  @router_reconciliation_attempts 3

  def create_group_conversation(group_id, attrs) when is_map(attrs) do
    with {:ok, prepared} <- prepare_conversation_create(group_id, attrs) do
      ConversationServer.create_group_conversation(group_id, prepared)
    end
  end

  def create_group_conversation_with_id(group_id, conversation_id, attrs)
      when is_map(attrs) do
    with {:ok, prepared} <- prepare_conversation_create(group_id, attrs) do
      ConversationServer.create_group_conversation_with_id(
        group_id,
        conversation_id,
        prepared
      )
    end
  end

  def ensure_group_conversation_agent_participant(group_id, conversation_id, attrs)
      when is_map(attrs) do
    with {:ok, prepared} <- prepare_agent(group_id, conversation_id, attrs) do
      ConversationServer.ensure_group_conversation_agent_participant(
        group_id,
        conversation_id,
        prepared
      )
    end
  end

  @doc """
  Reconciles one conversation's Router Participant to the current Group Router.

  The Group control plane remains authoritative. A control-plane change observed
  around the owner-serialized participant mutation causes a bounded retry; an
  invalid, missing, or unstable Router fails closed.
  """
  def reconcile_group_conversation_router_participant(group_id, conversation_id) do
    reconcile_group_conversation_router_participant(
      group_id,
      conversation_id,
      @router_reconciliation_attempts
    )
  end

  defp reconcile_group_conversation_router_participant(
         _group_id,
         _conversation_id,
         0
       ),
       do: {:error, :group_router_changed_during_reconciliation}

  defp reconcile_group_conversation_router_participant(
         group_id,
         conversation_id,
         attempts_left
       ) do
    with {:ok, router_agent_id, desired} <- prepare_current_router(group_id, conversation_id),
         {:ok, participant} <-
           ConversationServer.reconcile_group_conversation_agent_participants(
             group_id,
             conversation_id,
             %{
               "desired" => desired,
               "selector" => %{
                 "actor_type" => "agent",
                 "role_label" => ["agent", "router"]
               },
               "authority_guard" => %{
                 "type" => "group_router",
                 "router_agent_id" => router_agent_id
               }
             }
           ),
         {:ok, ^router_agent_id} <- current_group_router_agent_id(group_id) do
      {:ok, participant}
    else
      {:ok, _changed_router_agent_id} ->
        reconcile_group_conversation_router_participant(
          group_id,
          conversation_id,
          attempts_left - 1
        )

      {:error, :not_group_router_agent} ->
        reconcile_group_conversation_router_participant(
          group_id,
          conversation_id,
          attempts_left - 1
        )

      {:error, :stale_group_router_authority} ->
        reconcile_group_conversation_router_participant(
          group_id,
          conversation_id,
          attempts_left - 1
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_current_router(group_id, conversation_id) do
    SalixStore.ReadScope.run(fn ->
      with {:ok, router_agent_id} <- current_group_router_agent_id(group_id),
           {:ok, desired} <-
             prepare_agent(group_id, conversation_id, %{
               "actor_type" => "agent",
               "agent_id" => router_agent_id,
               "role_label" => "agent",
               "state" => "active",
               "notification_filter" => %{"messages" => "all", "statuses" => "none"}
             }) do
        {:ok, router_agent_id, desired}
      end
    end)
  end

  def prepare_agent(group_id, conversation_id, attrs, opts \\ [])
      when is_map(attrs) and is_list(opts) do
    with {:ok, conversation} <-
           Conversations.get_group_conversation(group_id, conversation_id) do
      prepare_agent_for_create(group_id, conversation, attrs, opts)
    end
  end

  def prepare_agent_for_create(group_id, conversation, attrs, opts \\ [])
      when is_map(conversation) and is_map(attrs) and is_list(opts),
      do: prepare_agent_facts(group_id, conversation, attrs, opts)

  defp prepare_conversation_create(group_id, attrs) do
    conversation =
      attrs
      |> Map.put("agent_group_id", group_id)
      |> Map.put_new("title", attrs["name"] || "Untitled")

    case Map.get(attrs, "participants", []) do
      participants when is_list(participants) ->
        participants
        |> Enum.reduce_while({:ok, []}, fn
          %{"actor_type" => "agent"} = participant, {:ok, acc} ->
            case prepare_agent_facts(group_id, conversation, participant, []) do
              {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
              {:error, _reason} = error -> {:halt, error}
            end

          participant, {:ok, acc} ->
            {:cont, {:ok, [participant | acc]}}
        end)
        |> case do
          {:ok, prepared} -> {:ok, Map.put(attrs, "participants", Enum.reverse(prepared))}
          {:error, _reason} = error -> error
        end

      _participants ->
        {:error, {:bad_request, "participants must be a list"}}
    end
  end

  defp prepare_agent_facts(group_id, conversation, attrs, opts) do
    agent_id = trim(attrs["agent_id"] || attrs[:agent_id])

    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, agent} <- GroupDirectory.get_agent(agent_id),
         true <- agent["group_id"] == group_id,
         {:ok, payload} <-
           AgentDeliveryPayload.materialize_participant_payload(
             group,
             agent,
             conversation,
             attrs,
             opts
           ) do
      {:ok,
       attrs
       |> Map.put("agent_id", agent_id)
       |> Map.put_new("agent_name", agent["name"])
       |> Map.put("payload", payload)
       |> Map.merge(
         AgentDeliveryPayload.participant_delivery_defaults(group, agent, conversation)
       )}
    else
      false ->
        {:error,
         {:bad_request, "conversation participant agent #{agent_id} is not in group #{group_id}"}}

      {:error, _reason} = error ->
        error
    end
  end

  defp current_group_router_agent_id(group_id) do
    SalixStore.ReadScope.invalidate({:record, SalixStore.Keys.ctl_group(group_id)})

    with {:ok, group} <- GroupDirectory.get_group(group_id),
         router_agent_id when is_binary(router_agent_id) <- group["router_agent_id"],
         router_agent_id when router_agent_id != "" <- String.trim(router_agent_id),
         :ok <-
           SalixStore.ReadScope.invalidate({:record, SalixStore.Keys.ctl_agent(router_agent_id)}),
         {:ok, router_agent} <- GroupDirectory.get_agent(router_agent_id),
         true <- router_agent["group_id"] == group_id and router_agent["role"] == "router" do
      {:ok, router_agent_id}
    else
      nil -> {:error, :router_not_configured}
      "" -> {:error, :router_not_configured}
      false -> {:error, :not_group_router_agent}
      {:error, _reason} = error -> error
      _invalid -> {:error, :not_group_router_agent}
    end
  end

  defp trim(nil), do: ""
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value |> to_string() |> String.trim()
end
