defmodule CommaWeb.ProactiveCheck do
  @moduledoc """
  The proactive consumer of the member source item pool. It reads items that
  arrived or changed, ranks the most urgent one, and hands it to the Router
  in the Home conversation when the owner personally must act on it. The
  Router session alone decides whether to notify the owner.

  The pool owns what arrived. The Home Conversation owns reminder state and
  the automatic message budget. This consumer records its outcome on each
  item it judged.
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args], states: :incomplete]

  require Logger
  alias Comma.{MemberSourceItems, Repo}
  alias Comma.Data.{MemberSourceItem, RecommendationProfile}
  alias CommaWeb.{HomeMail, ProactiveRoutine, RecommendationRenderer}
  alias CommaWeb.RecommendationRuntime
  alias SalixIM.{ConversationServer, Conversations, MailInteraction}

  # One judgment reads at most this many pending items; later items wait for
  # the next run.
  @judged_limit 24
  @judge_timeout_ms 45_000
  @history_bytes 2_400

  # The model ranks urgency; the Router alone decides whether to interrupt the
  # owner. Items the owner personally must act on reach the Router as evidence.
  # Lower levels stay in the daily briefing.
  @routed_urgencies ~w(critical high)

  def enqueue(profile_id),
    do: %{"profile_id" => profile_id} |> new() |> then(&Oban.insert(Comma.Oban, &1))

  @impl Oban.Worker
  def timeout(_job), do: 90_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         {:ok, workspace, ctx, home} <-
           HomeMail.context(user, %{}, workspace["default_group_id"]) do
      case consume(workspace, ctx, home, profile) do
        {:ok, outcome} ->
          Logger.info("proactive_check outcome=#{outcome}")
          :ok

        {:error, reason} = error ->
          Logger.warning("proactive_check failed reason=#{inspect(reason, limit: 3)}")
          error
      end
    else
      # A removed profile or an owner who left the workspace has nothing to tell.
      _ -> :ok
    end
  end

  @doc """
  Judges the profile's pending items once. Returns `{:ok, outcome}` with
  outcome `:idle`, `:quiet`, `:deferred`, `:routed`, `:withdrawn` or `:off`, or
  an error that leaves the items pending for the next run.
  """
  def consume(workspace, ctx, home, profile) do
    owner = profile.user_id

    with {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      routed = MailInteraction.entries(conversation)

      {earlier, fresh} =
        profile.id
        |> MemberSourceItems.pending(@judged_limit)
        |> Enum.map(&item/1)
        |> Enum.split_with(&already_routed?(routed, &1))

      settle(earlier, "routed_earlier")
      now = System.system_time(:millisecond)

      cond do
        fresh == [] ->
          {:ok, :idle}

        not MailInteraction.enabled?(conversation, owner) ->
          # The owner turned automatic messages off. Nothing is judged or sent.
          settle(fresh, "off")
          {:ok, :off}

        match?({:closed, _}, MailInteraction.automatic_budget(conversation, owner, now)) ->
          # Pending items wait for the budget instead of being dropped.
          {:ok, :deferred}

        true ->
          judge_and_route(workspace, ctx, home, profile, conversation, fresh)
      end
    end
  end

  defp judge_and_route(workspace, ctx, home, profile, conversation, items) do
    case judge(workspace, profile, ctx, home, items) do
      {:ok, nil} ->
        settle(items, "quiet")
        {:ok, :quiet}

      {:ok, {:below, urgency}} ->
        # The most urgent item needs no action from the owner, so no other
        # judged item does. They stay in the daily briefing.
        settle(items, "quiet", urgency)
        {:ok, :quiet}

      {:ok, {item, urgency, message}} ->
        # The judgment read the item before a model call. It is routed only if it
        # still waits unchanged: revocation, a source turned off or a newer
        # collection may have withdrawn it meanwhile.
        routed =
          MemberSourceItems.while_pending(item["record"], fn ->
            route(workspace, ctx, home, profile.user_id, conversation, item, message)
          end)

        case routed do
          {:ok, _} ->
            # The other items stay pending and are judged again when the
            # budget allows another handoff.
            settle([item], "routed", urgency)
            {:ok, :routed}

          {:error, :withdrawn} ->
            # Nothing is sent. The other judged items wait for the next check.
            {:ok, :withdrawn}

          {:error, :proactive_budget_exhausted} ->
            {:ok, :deferred}

          {:error, :proactive_disabled} ->
            settle(items, "off")
            {:ok, :off}

          {:error, reason} when reason in [:mail_source_handled, :mail_source_changed] ->
            settle(items, "quiet")
            {:ok, :quiet}

          {:error, _} = error ->
            error
        end

      {:error, :invalid_attention_decision} ->
        # An unusable answer is not a reason to wake the Router. Stay quiet.
        settle(items, "invalid")
        {:ok, :quiet}

      {:error, _} = error ->
        error
    end
  end

  defp settle(items, outcome, urgency \\ nil) do
    attention =
      %{"outcome" => outcome, "at" => System.system_time(:millisecond)}
      |> then(&if(urgency, do: Map.put(&1, "urgency", urgency), else: &1))

    MemberSourceItems.settle(Enum.map(items, & &1["record"]), attention)
  end

  # The consumer's view of one pooled item, with a candidate ID for the model.
  defp item(%MemberSourceItem{} = record) do
    %{
      "record" => record,
      "sourceVersion" => record.fingerprint,
      "id" => "i#{record.id}",
      "sourceId" => record.source_id,
      "app" => record.app,
      "title" => record.title,
      "url" => record.url,
      "excerpt" => record.excerpt,
      "context" => record.context,
      "promptContext" => record.prompt_context,
      "relationship" => record.relationship,
      "recipient" => record.recipient,
      "facts" => record.facts,
      "threadId" => record.provider_ids["threadId"],
      "messageId" => record.provider_ids["messageId"]
    }
  end

  defp already_routed?(routed, item) do
    ref = reference(item)

    case routed[MailInteraction.key(item["sourceId"], ref["source_ref"])] do
      %{"message_id" => message} -> message == ref["observation_id"]
      _ -> false
    end
  end

  defp reference(item),
    do:
      ProactiveRoutine.reference(
        item["sourceId"],
        item["url"],
        item["promptContext"],
        item["threadId"],
        item["messageId"],
        item["sourceVersion"]
      )

  defp judge(workspace, profile, ctx, home, items) do
    with {:ok, template} <- RecommendationRuntime.template_id(workspace["router_agent_id"]),
         {:ok, history} <-
           Conversations.list_group_conversation_messages(ctx.group_id, home,
             tail: 12,
             limit: 12
           ),
         input = %{
           "candidates" => Enum.map(items, &model_view/1),
           "conversation" => history(history)
         },
         {:ok, decision} <-
           RecommendationRenderer.attention(
             workspace,
             template,
             profile,
             input,
             @judge_timeout_ms
           ) do
      choice(decision, items)
    end
  end

  defp choice(%{"most_urgent" => nil}, _items), do: {:ok, nil}

  defp choice(
         %{"most_urgent" => %{"id" => id, "urgency" => urgency, "message" => message}},
         items
       )
       when is_binary(id) and is_binary(message) do
    message = String.trim(message)
    item = Enum.find(items, &(&1["id"] == id))

    cond do
      not is_map(item) or urgency not in RecommendationRenderer.attention_urgencies() or
        message == "" or byte_size(message) > 2_400 ->
        {:error, :invalid_attention_decision}

      urgency in @routed_urgencies ->
        Logger.info("proactive_attention urgency=#{urgency} routed=true")
        {:ok, {Map.put(item, "urgency", urgency), urgency, message}}

      true ->
        Logger.info("proactive_attention urgency=#{urgency} routed=false")
        {:ok, {:below, urgency}}
    end
  end

  defp choice(_decision, _items), do: {:error, :invalid_attention_decision}

  defp model_view(item) do
    %{
      "id" => item["id"],
      "app" => item["app"],
      "title" => item["title"],
      "excerpt" => item["excerpt"],
      "relationship" => item["relationship"],
      "recipient" => item["recipient"],
      "context" => item["context"],
      "facts" => item["facts"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}] end)
    |> Map.new()
  end

  # The latest visible messages, newest kept first when the budget runs out.
  defp history(messages) do
    messages
    |> Enum.filter(&(&1["kind"] == "message" and &1["actor_type"] in ~w(user agent)))
    |> Enum.reverse()
    |> Enum.reduce({[], @history_bytes}, fn message, {rows, budget} ->
      text =
        message["content"]
        |> List.wrap()
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join("\n", & &1["text"])
        |> String.slice(0, 400)

      if byte_size(text) > budget or text == "",
        do: {rows, budget},
        else:
          {[
             %{
               "from" => if(message["actor_type"] == "user", do: "member", else: "comma"),
               "text" => text
             }
             | rows
           ], budget - byte_size(text)}
    end)
    |> elem(0)
  end

  defp route(_workspace, ctx, home, owner, conversation, item, message) do
    ref = reference(item)
    key = MailInteraction.key(item["sourceId"], ref["source_ref"])
    current = MailInteraction.entries(conversation)[key]

    command = %{
      "action" => "present",
      "automatic" => true,
      "urgency" => item["urgency"],
      "key" => key,
      "request_id" =>
        "check:" <>
          Base.encode16(:crypto.hash(:sha256, key <> ref["observation_id"]), case: :lower),
      "generation" => if(is_map(current), do: current["generation"]),
      "account_id" => item["sourceId"],
      "thread_id" => ref["source_ref"],
      "message_id" => ref["observation_id"],
      "subject" => item["title"],
      "source_url" => item["url"],
      "read" => ref["live_read"] || ref["read"],
      "text" => CommaWeb.Proactive.message(message, item["title"], item["url"])
    }

    with {:ok, command} <- HomeMail.retire_completed_task(command, ctx, home) do
      ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, command)
    end
  end
end
