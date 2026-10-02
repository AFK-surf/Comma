defmodule CommaWeb.ProactiveBriefing do
  @moduledoc """
  Hands a newly published scheduled Routine briefing to the owner's Router.

  The briefing is a Home matter with the fixed key `["routine", "briefing"]`,
  observed at its generation, so each scheduled briefing hands over once and
  Home keeps one value for it. The Router decides whether the owner hears
  about it, in Home and in their bound personal chats; the server sends
  nothing. Automatic messages off, a closed handoff budget or a briefing for a
  member other than the Workspace owner hand over nothing. A failed handoff
  never fails the briefing.
  """
  require Logger
  alias CommaWeb.{HomeMail, ProactiveRoutine}
  alias SalixIM.{ConversationServer, Conversations, MailInteraction}

  @account "routine"
  @thread "briefing"
  @evidence_items 3

  def key, do: MailInteraction.key(@account, @thread)

  @doc "Hands one published briefing over. Always returns `:ok`."
  def handoff(workspace, profile, run, snapshot) do
    with true <- run.trigger == "schedule",
         true <- workspace["owner_user_id"] == profile.user_id,
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, _, ctx, home} <- HomeMail.context(user, %{}, workspace["default_group_id"]),
         {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home),
         items = ProactiveRoutine.items(snapshot),
         true <- items != [],
         # When the daily notification cap is reached, the Router could not
         # notify about it today; the next briefing replaces it.
         {:open, _} <-
           MailInteraction.notification_budget(
             conversation,
             profile.user_id,
             System.system_time(:millisecond),
             "critical"
           ) do
      current = MailInteraction.entries(conversation)[key()]
      observation = "generation:" <> Integer.to_string(run.generation)

      command = %{
        "action" => "present",
        "automatic" => true,
        "urgency" => "normal",
        "key" => key(),
        "request_id" =>
          "routine:" <>
            Base.encode16(:crypto.hash(:sha256, profile.id <> ":" <> observation), case: :lower),
        "generation" => if(is_map(current), do: current["generation"]),
        "account_id" => @account,
        "thread_id" => @thread,
        "message_id" => observation,
        "subject" => "Routine briefing",
        "source_url" => "",
        "read" => %{"tool" => "recommendation.read", "arguments" => %{}},
        "text" => text(items)
      }

      case ConversationServer.mail_interaction(
             ctx.group_id,
             home,
             profile.user_id,
             ctx.agent_id,
             command
           ) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.info("proactive_briefing handoff skipped reason=#{inspect(reason)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.warning("proactive_briefing handoff failed #{Exception.message(error)}")
      :ok
  end

  # Evidence for the Router, never sent as is: the most urgent items first.
  defp text(items) do
    lines =
      items
      |> Enum.take(@evidence_items)
      |> Enum.map_join("\n", fn item ->
        "- " <> String.slice(item["title"] || "", 0, 300) <> link(item["url"])
      end)

    "The owner's scheduled Routine briefing was published. Its first items:\n" <> lines
  end

  defp link(url) when is_binary(url) and url != "",
    do: " (" <> String.slice(url, 0, 1_000) <> ")"

  defp link(_url), do: ""
end
