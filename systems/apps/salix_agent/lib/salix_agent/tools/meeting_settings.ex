defmodule SalixAgent.Tools.MeetingSettings do
  @moduledoc """
  The Router's tools for where the Group's meeting reminders, join notices and
  minutes go when it has both a Slack bot and a Feishu/Lark bot. The requester
  comes from the signed current input, never from a name in text; the product
  decides who may change it (an organization owner or admin). A turn that
  several people wrote in changes nothing.
  """

  alias SalixAgent.GroupRuntime

  @auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"meeting.settings.get_destination",
       "Read where this Group's meeting reminders, join notices and minutes go: the platform (Slack, Feishu or Lark), its bot and chat. status \"choice_needed\" means the Group has both Slack and Feishu/Lark connected and nobody chose yet: ask the person which platform they want, then call meeting.settings.set_destination. options lists the bots that can take it.",
       &__MODULE__.get_destination/2, @auto_wait_seconds, [roles: ["router"]]},
      {"meeting.settings.set_destination",
       "Change where this Group's meeting reminders, join notices and minutes go, for the current requester's explicit request. platform is slack, feishu or lark; connect_id picks one bot when that platform has several (from get_destination options); chat_or_channel_id optionally names the team chat or channel for the notices. Only an organization owner or admin may change it: on admin_required, tell the person to ask an admin or use the Meetings page of the dashboard. Meetings read from Feishu/Lark calendars cannot notify in Slack. Report the result in plain words.",
       &__MODULE__.set_destination/2, @auto_wait_seconds, [roles: ["router"]]}
    ]
  end

  def get_destination(_args, ctx),
    do: change(ctx, "meeting.settings.get_destination", :get_destination, [])

  def set_destination(args, ctx),
    do:
      change(ctx, "meeting.settings.set_destination", :set_destination, [
        value(args, "platform"),
        value(args, "connect_id"),
        value(args, "chat_or_channel_id")
      ])

  defp change(ctx, name, function, args) do
    with {:ok, origin} <- requester_origin(ctx),
         {:ok, result} <-
           GroupRuntime.call(
             ctx.agent_id,
             :meeting_settings_mod,
             :meeting_settings_not_configured,
             function,
             [origin | args]
           ) do
      Jason.encode!(result)
    else
      {:error, :admin_required} ->
        raise "#{name} failed: admin_required. Only an organization owner or admin may change this; tell the person to ask one, or to use the Meetings page of the dashboard."

      {:error, reason} ->
        raise "#{name} failed: #{inspect(reason)}"
    end
  end

  # The signed origin proves who woke this turn. When several people wrote in
  # it, nobody can tell whose request this is, so nothing is read or changed
  # with the wrong person's rights.
  defp requester_origin(ctx) do
    origins = List.wrap(ctx[:trusted_origins] || ctx[:trusted_origin])

    people =
      origins
      |> Enum.map(&person/1)
      # A Worker's or the system's input in the same turn is no requester.
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case {ctx[:trusted_origin], people} do
      {%{} = origin, [_one]} -> {:ok, origin}
      {_origin, [_ | _]} -> {:error, :requester_ambiguous_ask_them_to_repeat_alone}
      _none -> {:error, :meeting_settings_requires_provider_request}
    end
  end

  defp person(%{"provider_context" => context}) when is_map(context),
    do: context["user_id"] || context["sender_open_id"]

  defp person(_origin), do: nil

  defp value(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))
end
