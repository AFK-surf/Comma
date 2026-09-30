defmodule SalixIM.Triage.InvestigationAuthority do
  @moduledoc """
  Organization authority for the assigned Worker in one accepted Triage Task.

  `VerifiedKernel.IFC.System.Gates.commandScope` represents this host obligation.
  Runtime tests cover current scope and recovery. Lean does not prove this adapter.
  """

  alias SalixIM.{ConversationSourceIdentity, Conversations, GroupDirectory, ProviderConnects}
  alias SalixIM.Triage.Investigation

  def seal_conversation(record) do
    scope = %{
      "conversation_id" => record["conversation_id"],
      "message_id" => record["message_id"],
      "participant_id" => record["participant_id"],
      "agent_id" => record["participant_agent_id"],
      "session_id" => get_in(record, ["participant_payload", "session_id"])
    }

    with true <- is_map(get_in(record, ["conversation_source_refs", Investigation.grant_key()])),
         {:ok, _, _} <- validate(record["agent_group_id"], scope),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:agent, scope["agent_id"]}) do
      {:ok, scope, principal}
    else
      _ -> :none
    end
  end

  def validate(group_id, scope) when is_map(scope) do
    with {:ok, conversation, original} <-
           Investigation.authorize(group_id, scope["agent_id"], scope["conversation_id"]),
         {:ok, %{"participants" => participants} = page} <-
           Conversations.list_group_conversation_participants(group_id, scope["conversation_id"]),
         true <- page["has_more"] != true,
         participant when is_map(participant) <-
           Enum.find(participants, &(&1["participant_id"] == scope["participant_id"])),
         true <- participant["actor_type"] == "agent" and participant["state"] == "active",
         true <- participant["agent_id"] == scope["agent_id"],
         session_id when is_binary(session_id) and session_id != "" <- scope["session_id"],
         true <- get_in(participant, ["payload", "session_id"]) == session_id,
         {:ok, command} <-
           Conversations.get_group_conversation_message(
             group_id,
             scope["conversation_id"],
             scope["message_id"]
           ),
         true <- product_command?(command, scope, original),
         :ok <- source_authority(group_id, original) do
      {:ok, conversation, original}
    else
      _ -> {:error, :triage_investigation_scope_denied}
    end
  end

  def validate(_, _), do: {:error, :triage_investigation_scope_denied}

  defp product_command?(command, scope, original) do
    initial =
      command["actor_type"] == "agent" and
        command["agent_id"] == get_in(original.payload, ["product_identity", "salix_agent_id"]) and
        command["client_request_id"] == "delegate-task-" <> scope["conversation_id"]

    retry = get_in(command, ["metadata", Investigation.retry_key()])

    initial or
      (command["actor_type"] == "system" and is_map(retry) and
         retry["worker_agent_id"] == scope["agent_id"])
  end

  defp source_authority(group_id, original) do
    target = original.payload["target"]

    with {:ok, group} <- GroupDirectory.get_group(group_id),
         {:ok, authority} <-
           ProviderConnects.get_slack_triage_authority(
             group["tenant_id"],
             group_id,
             target["connect_id"],
             target["channel_id"]
           ),
         true <- authority["triage_enabled"] == true,
         true <- authority["connect_id"] == target["connect_id"],
         true <- authority["connect_generation"] == target["connect_generation"],
         true <- authority["workspace_id"] == target["workspace_id"],
         true <- authority["approved_channel_id"] == target["channel_id"] do
      :ok
    else
      _ -> {:error, :triage_investigation_scope_denied}
    end
  end

  def authorize_call(call, ctx) do
    name = call[:name] || call["name"]

    scopes =
      [get_in(ctx, [:trusted_origin, "triage_investigation"]) | List.wrap(ctx[:triage_scopes])]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if name == "end_turn" do
      :ok
    else
      Enum.reduce_while(scopes, :ok, fn scope, _ ->
        with true <-
               scope["agent_id"] == ctx[:agent_id] and scope["session_id"] == ctx[:session_id],
             true <- consumed?(scope, ctx),
             {:ok, _, _} <- validate(ctx[:group_id], scope),
             true <- allowed?(call, scope, ctx) do
          {:cont, :ok}
        else
          _ -> {:halt, {:error, :triage_investigation_scope_denied}}
        end
      end)
    end
  end

  defp consumed?(scope, ctx) do
    Enum.any?(List.wrap(ctx[:source_message_ids]), fn id ->
      case ConversationSourceIdentity.decode(id, scope["conversation_id"]) do
        {:ok, identity} ->
          identity.message_id == scope["message_id"] and
            identity.participant_id == scope["participant_id"]

        _ ->
          false
      end
    end)
  end

  defp allowed?(call, scope, ctx) do
    name = call[:name] || call["name"]
    args = call[:args] || call["args"] || %{}

    cond do
      name in ~w(im_api.internal.triage.read_source im_api.internal.triage.complete) ->
        true

      name == "im_api.internal.send_message" ->
        args["conversation_id"] == scope["conversation_id"]

      # These research calls still pass through IFC as public egress. This Task
      # grant must not reject them before IFC evaluates their selected sources.
      name in ~w(web.search web.read_pages) ->
        true

      name in ~w(help tool_call.get_status tool_call.get_result wait_for) ->
        true

      true ->
        # Existing Worker policy still decides which research tools are available.
        # This grant permits reads and private working files, never arbitrary egress.
        case SalixAgent.IFC.Destination.describe(name, args, ctx) do
          {kind, _} when kind in [:read, :none] -> name != "js.run"
          {_, %{"kind" => "agent_private"}} -> true
          _ -> false
        end
    end
  end

  def destination(request) do
    scope = get_in(request, ["destination", "scope"])

    with true <- is_map(scope),
         true <-
           request["agent_id"] == scope["agent_id"] and
             request["session_id"] == scope["session_id"],
         {:ok, _, original} <- validate(request["group_id"], scope),
         {:ok, principal} <- SalixIFC.Codec.encode_principal({:agent, scope["agent_id"]}),
         true <- request["requester"] == principal do
      target = original.payload["target"]

      {:ok, %{"connect_id" => target["connect_id"], "scope_id" => target["channel_id"]},
       principal}
    else
      _ -> {:error, :triage_investigation_scope_denied}
    end
  end
end
