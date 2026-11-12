defmodule SalixAgent.IFC.ChannelOnboarding do
  @moduledoc """
  A product-owned, source-local welcome attempt. The joined event remains data;
  only its exact channel send receives command authority, never declassification.
  TerminalReply binds the standalone attempt to the current activation and
  settles it on either success or refusal so optional onboarding cannot starve
  later human requests.
  """

  # The event of each provider that says its bot joined a place, and the
  # context key that names the place.
  @joins %{
    "slack" => {"member_joined_channel", "channel_id"},
    "feishu" => {"im.chat.member.bot.added_v1", "chat_id"},
    "lark" => {"im.chat.member.bot.added_v1", "chat_id"}
  }

  # Slack's channel post, and the chat send of Feishu and Lark.
  @chat_sends ["im_api.feishu.send_message", "im_api.lark.send_message"]
  @sends ["im_api.slack.post_message", "im_api.slack.post_channel_message" | @chat_sends]

  def origin?(%{"provider" => provider, "provider_context" => context} = origin)
      when is_map_key(@joins, provider) and is_map(context) do
    {event_type, place} = @joins[provider]

    with ^event_type <- context["event_type"],
         connect when is_binary(connect) and connect != "" <- context["connect_id"],
         channel when is_binary(channel) and channel != "" <- context[place],
         event when is_binary(event) and event != "" <- context["event_id"] do
      origin["source_message_id"] ==
        "im_provider:#{provider}:#{connect}:channel_joined:#{channel}:#{event}"
    else
      _ -> false
    end
  end

  def origin?(_), do: false

  def prepare(call, {wire, declaration}, ctx) do
    binding = call[:terminal_reply] || %{}
    origin = ctx[:trusted_origin] || %{}

    with name when name in @sends <- call[:name],
         "router" <- ctx[:role],
         true <- ctx[:llm_tool_envelope] == true,
         "channel_onboarding" <- binding["kind"],
         true <- binding["tool_call_id"] == call[:id],
         true <- binding["source_message_id"] == ctx[:source_message_id],
         true <- binding["context_source_message_ids"] == ctx[:source_message_ids],
         %{} = args <- call[:args],
         true <- args["connect_id"] == binding["connect_id"],
         true <- welcome_target?(name, args, binding["chat_id"]),
         true <- origin?(origin),
         group when is_binary(group) and group != "" <- ctx[:group_id],
         ^group <- origin["agent_group_id"],
         source_id = binding["source_message_id"],
         true <- source_id == origin["source_message_id"],
         %{"items" => items} <- wire,
         [source] <- Enum.filter(items, &(&1["source_message_id"] == source_id)),
         true <- declaration.request in [nil, source["ref"]],
         ref = "ifc:channel-onboarding:" <> source_id,
         false <- Enum.any?(items, &(&1["ref"] == ref)) do
      command = %{
        "ref" => ref,
        "label" => source["label"],
        "integrity" => "command",
        "principal" => "system"
      }

      wire =
        Map.merge(wire, %{
          "items" => items ++ [command],
          "request" => ref,
          "requester" => "system",
          "source_scope" => source["label"],
          "consumed_refs" => [ref]
        })

      {wire, %{declaration | request: ref}}
    else
      _ -> {wire, declaration}
    end
  end

  # A welcome is a new message to the joined place itself: no thread, reply
  # or person.
  defp welcome_target?(name, args, chat) when name in @chat_sends,
    do: args["chat_id"] == chat and args["user_id"] in [nil, ""] and args["reply_to"] in [nil, ""]

  defp welcome_target?(_name, args, chat),
    do: args["channel"] == chat and args["thread_ts"] in [nil, ""]
end
