defmodule SalixAgent.Tools.DailyBrief do
  @moduledoc """
  The Router's tools for changing the Swarm's daily brief on a Slack
  requester's explicit request: when it is sent, and which channels and
  projects the requester's own brief follows. The requester comes from the signed
  current input, never from a name in text; the product decides what that
  person may change. A turn that several people wrote in changes nothing.
  """

  alias SalixAgent.GroupRuntime

  @auto_wait_seconds SalixAgent.Tools.AsyncPolicy.normal_tool_auto_wait_seconds()

  def defs do
    [
      {"daily_brief.set_time",
       "Change when the daily brief is sent, for the current Slack requester's explicit request. brief \"mine\" sets the requester's own brief time; brief \"team\" sets the team brief's time and needs the requester to be an organization owner or admin. time is HH:MM in 24-hour form, in the requester's (mine) or the team's (team) time zone. Briefs are sent on workdays only. Report the result in plain words.",
       &__MODULE__.set_time/2, @auto_wait_seconds, [roles: ["router"]]},
      {"daily_brief.set_channel",
       "Change which channels the current Slack requester's own daily brief follows, for their explicit request. By default a brief follows the public channels its reader wrote most in lately; in a followed channel every human message reaches the brief. mode \"follow\" adds the channel, \"follow_with_bots\" adds it with its bot messages too (for an alerts channel), \"ignore\" stops following it, \"default\" forgets the choice. channel is the channel as the requester wrote it (a channel link, #name, or name). The answer lists the channels the brief follows now; report them in plain words.",
       &__MODULE__.set_channel/2, @auto_wait_seconds, [roles: ["router"]]},
      {"daily_brief.set_project",
       "Add or remove a project term of the current Slack requester's own daily brief, for their explicit request: a message that names one reaches the brief even when the requester was not in it. mode is \"add\" or \"remove\". The answer lists the requester's project terms now; report them in plain words.",
       &__MODULE__.set_project/2, @auto_wait_seconds, [roles: ["router"]]}
    ]
  end

  def set_channel(args, ctx),
    do:
      change(ctx, "daily_brief.set_channel", :set_channel, [
        value(args, "channel"),
        value(args, "mode")
      ])

  def set_project(args, ctx),
    do:
      change(ctx, "daily_brief.set_project", :set_project, [
        value(args, "term"),
        value(args, "mode")
      ])

  defp change(ctx, name, function, args) do
    with {:ok, origin} <- requester_origin(ctx),
         {:ok, result} <-
           GroupRuntime.call(
             ctx.agent_id,
             :daily_brief_mod,
             :daily_brief_not_configured,
             function,
             [origin | args]
           ) do
      Jason.encode!(result)
    else
      {:error, reason} -> raise "#{name} failed: #{inspect(reason)}"
    end
  end

  def set_time(args, ctx) do
    with {:ok, origin} <- requester_origin(ctx),
         {:ok, result} <-
           GroupRuntime.call(
             ctx.agent_id,
             :daily_brief_mod,
             :daily_brief_not_configured,
             :set_time,
             [origin, value(args, "brief"), value(args, "time")]
           ) do
      Jason.encode!(result)
    else
      {:error, reason} -> raise "daily_brief.set_time failed: #{inspect(reason)}"
    end
  end

  # The signed origin proves who woke this turn. When people other than one
  # Slack user wrote in it, nobody can tell whose request this is, so the
  # change is refused rather than made with the wrong person's rights.
  defp requester_origin(ctx) do
    origins = List.wrap(ctx[:trusted_origins] || ctx[:trusted_origin])

    users =
      origins
      |> Enum.map(&get_in(&1, ["provider_context", "user_id"]))
      # A Worker's or the system's input in the same turn is no requester.
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case {ctx[:trusted_origin], users} do
      {%{} = origin, [_one]} -> {:ok, origin}
      {_origin, [_ | _]} -> {:error, :requester_ambiguous_ask_them_to_repeat_alone}
      _none -> {:error, :daily_brief_requires_slack_request}
    end
  end

  defp value(args, key), do: Map.get(args, key, Map.get(args, String.to_atom(key)))
end
