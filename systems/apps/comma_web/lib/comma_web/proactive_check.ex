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
  alias CommaWeb.{HomeMail, ProactiveMatters, ProactiveNotebook, ProactiveRoutine}
  alias CommaWeb.RecommendationRenderer
  alias CommaWeb.RecommendationRuntime
  alias SalixIM.{ConversationServer, Conversations, MailInteraction}

  # One judgment reads at most this many pending items; later items wait for
  # the next run.
  @judged_limit 24
  @judge_timeout_ms 45_000
  @history_bytes 2_400
  # An unclear answer judges the rest again in the same check, at most this
  # many times, so one unclear item does not hold back the others.
  @unclear_rejudgments 2
  # The judgment sees the owner's latest Home matters, so a later notice about
  # the same matter is judged with what happened to the earlier one.
  @matters_limit 20
  @matters_days 60

  # The model ranks urgency; the Router alone decides whether to interrupt the
  # owner. Items the owner personally must act on reach the Router as evidence,
  # and so do items that may be theirs (`ask`), for the Router to ask about.
  # Lower levels stay in the daily briefing.
  @routed_urgencies ~w(critical high ask)

  def enqueue(profile_id),
    do: %{"profile_id" => profile_id} |> new() |> then(&Oban.insert(Comma.Oban, &1))

  @impl Oban.Worker
  def timeout(_job), do: 90_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    Logger.metadata(profile_id: profile_id)

    with %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         {:ok, workspace, ctx, home} <-
           HomeMail.context(user, %{}, workspace["default_group_id"]) do
      # Every line of this job names whose check it is.
      Logger.metadata(
        user_id: profile.user_id,
        workspace_id: profile.workspace_id,
        group_id: ctx.group_id
      )

      case consume(workspace, ctx, home, profile) do
        {:ok, outcome} ->
          Logger.info(
            "proactive_check outcome=#{outcome} locale=#{Comma.Accounts.locale(profile.user_id)}"
          )

          if outcome != :idle, do: ProactiveNotebook.enqueue(ctx.group_id, profile.user_id)
          :ok

        {:error, reason} = error ->
          Logger.warning("proactive_check failed reason=#{inspect(reason, limit: 3)}")

          case reason do
            :insufficient_credits ->
              {:cancel, reason}

            {:billing_unavailable, code} ->
              if SalixAgent.BillingAvailability.denied?({:billing_unavailable, %{reason: code}}),
                do: {:cancel, reason},
                else: error

            _ ->
              error
          end
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

      watched = watched_keys(ctx, owner)

      {earlier, fresh} =
        profile.id
        |> MemberSourceItems.pending(@judged_limit)
        |> Enum.map(&view/1)
        |> Enum.split_with(&already_routed?(routed, watched, &1))

      settle(earlier, "routed_earlier")
      # The Home Conversation records each spend on this clock.
      now = SystemsClock.system_time(:millisecond)

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

        match?(
          {:closed, _},
          MailInteraction.notification_budget(conversation, owner, now, "critical")
        ) ->
          # Not even a critical matter could notify today: judging would only
          # spend a model call. Items wait for the daily cap to reopen.
          {:ok, :deferred}

        true ->
          judge_and_route(
            workspace,
            ctx,
            home,
            profile,
            conversation,
            CommaWeb.ProactiveMatters.group(fresh),
            now,
            @unclear_rejudgments
          )
      end
    end
  end

  defp judge_and_route(workspace, ctx, home, profile, conversation, items, now, rejudgments) do
    judged = judge(workspace, profile, ctx, home, conversation, items)

    # The Router could not notify about a non-critical item now. The items
    # stay pending and are judged again once the notification spacing passed.
    judged =
      with {:ok, {_item, urgency, _message}} when urgency != "critical" <- judged,
           {:closed, _} <- MailInteraction.notification_budget(conversation, profile.user_id, now) do
        Logger.info("proactive_check deferred urgency=#{urgency} notification_budget=closed")
        :deferred
      else
        _ -> judged
      end

    case judged do
      :deferred ->
        {:ok, :deferred}

      # Like a Loop's defer: the evidence could not tell, so nothing settles.
      # The items are judged again, a bounded number of times.
      # A mail whose pooled excerpt was cut off is read in full once, and the
      # same items are judged again with its text.
      {:ok, {:unclear, item}} when rejudgments > 0 ->
        case full_mail(ctx, item) do
          {:ok, read} ->
            items = Enum.map(items, &if(&1 == item, do: read, else: &1))

            judge_and_route(
              workspace,
              ctx,
              home,
              profile,
              conversation,
              items,
              now,
              rejudgments - 1
            )

          :error ->
            unclear(workspace, ctx, home, profile, conversation, items, item, now, rejudgments)
        end

      {:ok, {:unclear, item}} ->
        unclear(workspace, ctx, home, profile, conversation, items, item, now, rejudgments)

      {:ok, nil} ->
        settle(items, "quiet")
        {:ok, :quiet}

      {:ok, {:below, urgency, assessment}} ->
        # The most urgent item needs no action from the owner, so no other
        # judged item does. They stay in the daily briefing.
        settle(items, "quiet", urgency, assessment)
        {:ok, :quiet}

      {:ok, {item, urgency, message}} ->
        # The judgment read the item before a model call. It is routed only if it
        # still waits unchanged: revocation, a source turned off or a newer
        # collection may have withdrawn it meanwhile.
        # Provider reads happen before the item rows are locked.
        linked =
          CommaWeb.ProactiveEvidence.linked(workspace, profile.user_id, profile.sources, item)

        routed =
          MemberSourceItems.while_pending(item["record"], fn ->
            route(ctx, home, profile.user_id, conversation, item, message, linked)
          end)

        case routed do
          {:ok, _} ->
            # The other items stay pending and are judged again when the
            # budget allows another handoff.
            settle([item], "routed", urgency, item["assessment"])
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
        # An unusable answer decides nothing: the items keep waiting and are
        # judged again, a bounded number of times, instead of being dropped.
        retry(items)
        {:ok, :deferred}

      {:error, _} = error ->
        error
    end
  end

  # Only the unclear item spends a retry. The others are judged again
  # without it, so a request the owner must act on is not held back.
  defp unclear(workspace, ctx, home, profile, conversation, items, item, now, rejudgments) do
    retry([item])

    case List.delete(items, item) do
      rest when rest != [] and rejudgments > 0 ->
        judge_and_route(workspace, ctx, home, profile, conversation, rest, now, rejudgments - 1)

      _ ->
        {:ok, :deferred}
    end
  end

  # The full text of a mail item whose pooled excerpt was cut off, read once
  # through the owner's consented mail account. Other items, a complete
  # excerpt or a failed read leave the item as it is.
  defp full_mail(
         ctx,
         %{"toolkit" => toolkit, "messageId" => id, "context" => %{"truncated" => true}} = item
       )
       when toolkit in ~w(gmail outlook) and is_binary(id) do
    with {:ok, mail} <-
           CommaWeb.ProactiveMail.read(
             %{"message_id" => id, "connection_id" => item["sourceId"]},
             ctx
           ),
         %{"body" => body} when is_binary(body) and body != "" <-
           Enum.find(mail["messages"] || [], &(&1["message_id"] == id)) do
      {:ok,
       Map.put(item, "context", %{
         "scope" => "full_message",
         "text" => String.replace(body, ~r/\s+/u, " "),
         "truncated" => false
       })}
    else
      _ -> :error
    end
  end

  defp full_mail(_ctx, _item), do: :error

  # The assessment belongs to the judged matter only; the other items settle
  # with the level it set.
  defp settle(items, outcome, urgency \\ nil, assessment \\ nil) do
    attention =
      %{"outcome" => outcome, "at" => SystemsClock.system_time(:millisecond)}
      |> then(&if(urgency, do: Map.put(&1, "urgency", urgency), else: &1))

    {judged, others} =
      case assessment do
        %{"id" => id} -> Enum.split_with(items, &(&1["id"] == id))
        %{} -> {items, []}
        nil -> {[], items}
      end

    for {matters, attention} <- [
          {judged, Map.put(attention, "assessment", Map.delete(assessment || %{}, "id"))},
          {others, attention}
        ],
        do:
          MemberSourceItems.settle(
            Enum.map(ProactiveMatters.items(matters), & &1["record"]),
            attention
          )

    :ok
  end

  defp retry(items) do
    now = SystemsClock.system_time(:millisecond)

    Enum.each(ProactiveMatters.items(items), fn item ->
      attempts = ((item["record"].attention || %{})["attempts"] || 0) + 1

      attention =
        if attempts >= MemberSourceItems.judge_attempts(),
          do: %{"outcome" => "invalid", "at" => now},
          else: %{"outcome" => "retry", "attempts" => attempts, "at" => now}

      MemberSourceItems.settle([item["record"]], attention)
    end)
  end

  @doc "The consumer's view of one pooled item, with a candidate ID for the model."
  def view(%MemberSourceItem{} = record) do
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
      "toolkit" => record.toolkit,
      "threadId" => record.provider_ids["threadId"],
      "messageId" => record.provider_ids["messageId"],
      "arrivedAt" => record.first_seen_at
    }
  end

  defp already_routed?(routed, watched, item) do
    ref = reference(item)
    key = MailInteraction.key(item["sourceId"], ref["source_ref"])

    # The owner's active watch follows this matter and wakes the Router itself.
    observation = ref["observation_id"]

    MapSet.member?(watched, key) or
      match?(%{"message_id" => ^observation}, routed[key])
  end

  # Matter keys of the owner's active watches (at most 17 rows per agent).
  defp watched_keys(ctx, owner) do
    case SalixStore.Loops.proactive_monitors(ctx.agent_id) do
      {:ok, rows} ->
        for %{
              "status" => "active",
              "config" => %{"comma_proactive" => %{"user_id" => ^owner}} = config
            } <-
              rows,
            is_binary(config["source_ref"]),
            into: MapSet.new(),
            do:
              MailInteraction.key(
                CommaWeb.Proactive.source_account(config["source"] || %{}),
                config["source_ref"]
              )

      _ ->
        MapSet.new()
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
        item["sourceVersion"],
        item["toolkit"]
      )

  defp judge(workspace, profile, ctx, home, conversation, items) do
    now = SystemsClock.utc_now()
    matters = matters(conversation, profile.user_id, now)

    with {:ok, model} <- RecommendationRuntime.model(workspace["router_agent_id"]),
         {:ok, history} <-
           Conversations.list_group_conversation_messages(ctx.group_id, home,
             tail: 12,
             limit: 12
           ),
         input =
           attention_input(
             items,
             history,
             CommaWeb.MemberPortrait.statements(workspace),
             now,
             matters
           ),
         {:ok, decision} <-
           RecommendationRenderer.attention(
             workspace,
             model,
             profile,
             input,
             @judge_timeout_ms
           ) do
      choice(decision, items, now, matters)
    end
  end

  @doc """
  The owner's latest Home matters, as the notebook shows them: at most
  #{@matters_limit} changed within #{@matters_days} days, newest first, each
  with a run-local ID for the judgment's `continues` answer.
  """
  def matters(conversation, owner, now \\ SystemsClock.utc_now()) do
    since = DateTime.to_unix(now, :millisecond) - @matters_days * 86_400_000

    conversation
    |> MailInteraction.entries()
    |> Enum.filter(fn {_key, value} ->
      value["owner_id"] == owner and is_integer(value["changed_at"]) and
        value["changed_at"] >= since and
        not (value["account_id"] == "routine" and value["thread_id"] == "briefing")
    end)
    |> Enum.sort_by(fn {_key, value} -> -value["changed_at"] end)
    |> Enum.take(@matters_limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {{key, value}, index} ->
      %{
        "id" => "m#{index}",
        "key" => key,
        "subject" => value["subject"],
        "state" => value["state"],
        "urgency" => value["urgency"],
        "decision" => get_in(value, ["decision", "decision"]),
        "reason" => get_in(value, ["decision", "reason"]),
        "changedAt" =>
          value["changed_at"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
        "cost" => get_in(value, ["assessment", "cost"]),
        "due" => get_in(value, ["assessment", "due"]),
        "continues" => get_in(value, ["continues", "subject"])
      }
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)
    end)
  end

  @doc """
  The judgment input: the items as the model sees them, the latest Home
  messages and the Condensed Workspace, portrait first. The proactive replay judges the same
  input.
  """
  def attention_input(
        items,
        home_messages,
        statements \\ [],
        now \\ SystemsClock.utc_now(),
        matters \\ []
      ),
      do:
        %{
          "candidates" => Enum.map(items, &model_view(&1, now)),
          "conversation" => history(home_messages),
          "member" => CommaWeb.MemberPortrait.view(statements),
          "matters" => Enum.map(matters, &Map.delete(&1, "key"))
        }
        |> Map.reject(fn {key, value} -> key in ~w(member matters) and value == [] end)

  @doc """
  The checked judgment: `nil`, `{:unclear, item}`, `{:below, urgency, assessment}` or
  `{item, urgency, message}`; an answer outside the offered items or levels is
  `{:error, :invalid_attention_decision}`.

  The answer's cost, due time and reversibility set a floor under the level:
  a cost that lands within two days, or a cost that cannot be undone and lands
  within a week, is critical; any other cost is at least high. Ask and
  unclear answers keep their level. A routed item carries the assessment.
  """
  def choice(decision, items, now \\ SystemsClock.utc_now(), matters \\ [])

  def choice(%{"most_urgent" => nil}, _items, _now, _matters), do: {:ok, nil}

  def choice(
        %{"most_urgent" => %{"id" => id, "urgency" => urgency, "message" => message} = answer},
        items,
        now,
        matters
      )
      when is_binary(id) and is_binary(message) do
    message = String.trim(message)
    item = Enum.find(items, &(&1["id"] == id))
    assessment = assessment(answer, matters)
    urgency = with_floor(urgency, assessment, now)

    cond do
      is_map(item) and urgency == "unclear" ->
        Logger.info("proactive_attention urgency=unclear routed=false")
        {:ok, {:unclear, item}}

      not is_map(item) or urgency not in RecommendationRenderer.attention_urgencies() or
        message == "" or byte_size(message) > 2_400 ->
        {:error, :invalid_attention_decision}

      urgency in @routed_urgencies ->
        Logger.info("proactive_attention urgency=#{urgency} routed=true")

        {:ok,
         {item |> Map.put("urgency", urgency) |> Map.put("assessment", assessment), urgency,
          message}}

      true ->
        Logger.info("proactive_attention urgency=#{urgency} routed=false")
        {:ok, {:below, urgency, Map.put(assessment, "id", id)}}
    end
  end

  def choice(_decision, _items, _now, _matters), do: {:error, :invalid_attention_decision}

  @levels ~w(low normal high critical)

  # What the answer says happens if the owner does nothing, kept with the
  # item's attention so a quiet judgment can be explained.
  defp assessment(answer, matters) do
    # The earlier Home matter this item continues, as the owner saw it.
    continues =
      case Enum.find(matters, &(&1["id"] == answer["continues"])) do
        %{} = matter ->
          Map.take(matter, ~w(key subject urgency decision reason changedAt))

        nil ->
          nil
      end

    due =
      with due when is_binary(due) <- answer["due"],
           {:ok, at, _offset} <- DateTime.from_iso8601(due),
           do: DateTime.to_iso8601(at),
           else: (_ -> nil)

    %{
      "cost" => if(is_binary(answer["cost"]), do: String.trim(answer["cost"]), else: ""),
      "due" => due,
      "reversible" => answer["reversible"] != false
    }
    |> then(&if(continues, do: Map.put(&1, "continues", continues), else: &1))
  end

  defp with_floor(urgency, %{"cost" => cost} = assessment, now)
       when urgency in @levels and cost != "" do
    hours =
      with due when is_binary(due) <- assessment["due"],
           {:ok, at, _offset} <- DateTime.from_iso8601(due),
           do: DateTime.diff(at, now, :hour),
           else: (_ -> nil)

    least =
      cond do
        is_integer(hours) and hours <= 48 -> "critical"
        is_integer(hours) and hours <= 7 * 24 and not assessment["reversible"] -> "critical"
        true -> "high"
      end

    Enum.max_by([urgency, least], &Enum.find_index(@levels, fn level -> level == &1 end))
  end

  defp with_floor(urgency, _assessment, _now), do: urgency

  # `minutesAgo` says how long ago Comma first saw the item, so a judgment can
  # tell a fresh login code from an old one.
  defp model_view(item, now) do
    %{
      "minutesAgo" =>
        if(match?(%DateTime{}, item["arrivedAt"]),
          do: max(DateTime.diff(now, item["arrivedAt"], :minute), 0)
        ),
      "id" => item["id"],
      "app" => item["app"],
      "title" => item["title"],
      "excerpt" => item["excerpt"],
      "relationship" => item["relationship"],
      "recipient" => item["recipient"],
      "context" => item["context"],
      "facts" => item["facts"],
      "related" => item["related"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
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

  defp route(ctx, home, owner, conversation, item, message, linked) do
    ref = reference(item)
    key = MailInteraction.key(item["sourceId"], ref["source_ref"])
    current = MailInteraction.entries(conversation)[key]

    command = %{
      "action" => "present",
      "automatic" => true,
      "urgency" => item["urgency"],
      # What happens if the owner does nothing: cost, due time, reversibility.
      "assessment" => Map.delete(item["assessment"] || %{}, "continues"),
      # The earlier matter this one continues: the Router sees its decision,
      # and the notebook shows them together.
      "continues" => continues(item, key),
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
      "text" => CommaWeb.Proactive.message(message, item["title"], item["url"]),
      # What the matter's links say now, read only for a handoff.
      "linked" => linked
    }

    with {:ok, command} <- HomeMail.retire_completed_task(command, ctx, home) do
      ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, command)
    end
  end

  # The earlier matter the judgment linked, unless it is this matter itself.
  defp continues(item, key) do
    case get_in(item, ["assessment", "continues"]) do
      %{"key" => earlier} = matter when earlier != key -> matter
      _ -> nil
    end
  end
end
