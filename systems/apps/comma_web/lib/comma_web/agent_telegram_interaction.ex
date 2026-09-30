defmodule CommaWeb.AgentTelegramInteraction do
  @moduledoc false
  @behaviour SalixAgent.TelegramInteraction
  alias SalixIM.{GroupDirectory, TelegramInteractions}
  alias CommaWeb.TelegramBot

  @impl true
  def capabilities(ctx) do
    origin = ctx[:trusted_origin] || %{}
    destination = origin["provider_context"] || %{}

    with "router" <- ctx[:role],
         "provider_user" <- origin["source_actor_type"],
         true <-
           SalixAgent.TerminalReply.source_scope_matches_context?(ctx[:reply_source_scope], ctx),
         true <- origin["source_message_id"] == ctx[:source_message_id],
         {:ok, facts} <- GroupDirectory.scope_for_agent(ctx[:agent_id]),
         true <- facts.agent["router_session_id"] == ctx[:session_id],
         scope <-
           Map.merge(destination, %{"group_id" => facts.group_id, "agent_id" => ctx[:agent_id]}),
         {:ok, _} <- TelegramInteractions.active_connect(scope),
         {:ok, info} <- TelegramBot.get_webhook_info(),
         true <- info["url"] == TelegramBot.webhook_url(),
         true <-
           Enum.all?(["message", "callback_query"], &(&1 in (info["allowed_updates"] || []))) do
      %{"question" => true, "permission" => true, "oauth" => true}
    else
      _ -> %{}
    end
  end

  @impl true
  def request(_scope, "location", _args, _call_id),
    do: {:error, :location_request_unavailable}

  def request(scope, type, args, call_id) do
    with {:ok, facts} <- GroupDirectory.scope_for_agent(scope["agent_id"]),
         true <- facts.agent["router_session_id"] == scope["session_id"] do
      TelegramInteractions.request(
        Map.put(scope, "group_id", facts.group_id),
        type,
        args,
        call_id
      )
    else
      _ -> {:error, :unauthorized_source}
    end
  end
end
