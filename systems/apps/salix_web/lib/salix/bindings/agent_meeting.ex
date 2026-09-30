defmodule Salix.Bindings.AgentMeeting do
  @moduledoc "Trusted-source coordinator for Router-owned manual meeting tools."

  @behaviour SalixAgent.Meetings

  alias SalixIM.{Conversations, ProviderConnects}
  alias SalixMeet.ProviderDispatcher

  @impl true
  def join(group_id, params, tool_context) do
    with :ok <- require_router(group_id, tool_context),
         {:ok, source} <- current_human_source(group_id, tool_context),
         {:ok, connect} <-
           ProviderConnects.get_active_connect_by_id(
             group_id,
             source["connect_id"],
             source["provider"]
           ) do
      ProviderDispatcher.join_from_router(connect, source, params)
    end
  end

  @impl true
  def get(group_id, params) do
    SalixMeet.get_group_meeting_bounded(group_id, params["meeting_id"],
      deadline_ms: 1_000,
      with_ifc: true
    )
  end

  @impl true
  def summary_materials(group_id, params, ctx) do
    with :ok <- require_router(group_id, ctx),
         :ok <- Salix.Bindings.RouterMeetingSummary.authorize(group_id, params, ctx),
         {:ok, result, state} <- SalixMeet.RouterSummary.read(group_id, params) do
      {:ok, result, SalixMeet.IFC.ReadLabels.for_summary_materials(state)}
    end
  end

  @impl true
  def submit_summary(group_id, params, ctx) do
    with :ok <- require_router(group_id, ctx),
         :ok <- Salix.Bindings.RouterMeetingSummary.authorize(group_id, params, ctx) do
      SalixMeet.RouterSummary.submit(group_id, params)
    end
  end

  defp require_router(group_id, tool_context) do
    if tool_context["role"] == "router" and tool_context["group_id"] == group_id,
      do: :ok,
      else: {:error, :router_current_human_request_required}
  end

  defp current_human_source(group_id, %{"trusted_origin" => %{} = origin} = tool_context) do
    case origin["provider"] do
      provider when provider in ["slack", "feishu"] ->
        direct_provider_source(group_id, tool_context, origin, provider)

      "internal" ->
        conversation_source(group_id, origin)

      _ ->
        {:error, :router_current_human_request_required}
    end
  end

  defp current_human_source(_group_id, _tool_context),
    do: {:error, :router_current_human_request_required}

  defp direct_provider_source(group_id, tool_context, origin, provider) do
    context = stringify(origin["provider_context"] || %{})

    with true <- origin["agent_group_id"] == group_id,
         true <- origin["source_actor_type"] == "provider_user",
         source_message_id when is_binary(source_message_id) and source_message_id != "" <-
           origin["source_message_id"],
         true <- source_message_id == tool_context["source_message_id"],
         connect_id when is_binary(connect_id) and connect_id != "" <- context["connect_id"],
         true <- human_provider_source?(provider, context),
         :ok <- validate_direct_provider_target(provider, context) do
      {:ok,
       %{
         "provider" => provider,
         "connect_id" => connect_id,
         "source_message_id" => source_message_id,
         "text" => to_string(origin["source_text"] || ""),
         "metadata" => context
       }}
    else
      _ -> {:error, :router_current_human_request_required}
    end
  end

  defp validate_direct_provider_target("slack", context) do
    if nonblank?(context["channel_id"]) and nonblank?(context["user_id"]),
      do: :ok,
      else: {:error, :invalid_slack_source}
  end

  defp validate_direct_provider_target("feishu", context) do
    if nonblank?(context["chat_id"]) and nonblank?(context["message_id"]),
      do: :ok,
      else: {:error, :invalid_feishu_source}
  end

  defp conversation_source(group_id, origin) do
    with true <- origin["agent_group_id"] == group_id,
         true <- origin["conversation_kind"] == "user_chat",
         true <- origin["source_actor_type"] == "provider_user",
         conversation_id when is_binary(conversation_id) and conversation_id != "" <-
           origin["conversation_id"],
         message_id when is_binary(message_id) and message_id != "" <- origin["message_id"],
         {:ok, message} <-
           Conversations.get_group_conversation_message(group_id, conversation_id, message_id),
         true <- message["actor_type"] == "provider_user",
         metadata = stringify(message["metadata"] || %{}),
         provider when provider in ["slack", "feishu"] <- metadata["provider"],
         true <- human_provider_source?(provider, metadata),
         connect_id when is_binary(connect_id) and connect_id != "" <- metadata["connect_id"] do
      {:ok,
       %{
         "provider" => provider,
         "connect_id" => connect_id,
         "source_message_id" => message["source_message_id"],
         "message_id" => message_id,
         "text" => content_text(message["content"]),
         "metadata" => metadata
       }}
    else
      _ -> {:error, :router_current_human_request_required}
    end
  end

  defp content_text(content) when is_binary(content), do: content
  defp content_text(%{"text" => text}) when is_binary(text), do: text

  defp content_text(content) when is_list(content),
    do: content |> Enum.map(&content_text/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

  defp content_text(_content), do: ""

  # The general Conversation projection calls provider-originated app messages
  # `provider_user` too. Re-prove the provider's own human-sender fields at the
  # final write-authority gate instead of treating that projection as authority.
  defp human_provider_source?("feishu", metadata),
    do: metadata["sender_type"] == "user" and nonblank?(metadata["sender_open_id"])

  defp human_provider_source?("slack", metadata) do
    nonblank?(metadata["user_id"]) and not nonblank?(metadata["bot_id"]) and
      not nonblank?(metadata["app_id"]) and metadata["subtype"] != "bot_message"
  end

  defp human_provider_source?(_provider, _metadata), do: false

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
