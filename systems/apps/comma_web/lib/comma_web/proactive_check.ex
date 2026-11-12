defmodule CommaWeb.ProactiveCheck do
  @moduledoc """
  The proactive consumer of the member source item pool. It reads items that
  arrived or changed, groups them into matters, reads each matter's current
  state, and screens each matter once: the screening is the only place that
  decides whether a matter interrupts the owner. A matter it decides to
  interrupt goes to the Router in the Home conversation, which writes and
  sends the reminder.

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

  # One check reads at most this many pending items; later items wait for
  # the next run.
  @judged_limit 24
  # Each matter is screened in its own model call, a few at once: one call
  # that reasons over a whole batch outlasts the timeout.
  @screen_concurrency 8
  @judge_timeout_ms 45_000
  # Link and full-mail reads before the screening, for the newest matters.
  @evidence_limit 8
  # One check hands over at most this many matters, earliest due first.
  @handoffs_per_check 3
  @history_bytes 2_400
  # Items a failed judgment returned wait at most this long behind new
  # arrivals once their backoff passed.
  @retry_after_ms 60 * 60 * 1000
  @failure_backoff_ms 15 * 60 * 1000
  @failure_backoff_max_ms 6 * 60 * 60 * 1000
  # The judgment sees the owner's latest Home matters, so a later notice about
  # the same matter is judged with what happened to the earlier one.
  @matters_limit 20
  @matters_days 60

  # The level the Home value and the notebook keep for each decision.
  @urgency %{"interrupt" => "high", "ask" => "ask", "briefing" => "normal", "resolved" => "low"}

  # A matter handed over recently is not handed over again for the same
  # evidence: a later copy needs a higher level, a nearer due time or newly
  # reserve-eligible cost. A handled matter stays handled for longer.
  @repeat_ms 24 * 60 * 60 * 1000
  @handled_repeat_ms 7 * 24 * 60 * 60 * 1000
  @levels_by_rank ~w(low normal ask high critical)

  def enqueue(profile_id),
    do: %{"profile_id" => profile_id} |> new() |> then(&Oban.insert(Comma.Oban, &1))

  @impl Oban.Worker
  def timeout(_job), do: 180_000

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

      # The owner dismissed these from Routine and does not want to hear about them.
      {dismissed, fresh} =
        Enum.split_with(
          fresh,
          &Comma.Recommendations.dismissed?(profile, &1["sourceId"], &1["url"])
        )

      settle(earlier, "routed_earlier")
      settle(dismissed, "dismissed")
      # The Home Conversation records each spend on this clock.
      now = SystemsClock.system_time(:millisecond)
      fresh = batch(fresh, now)

      cond do
        fresh == [] ->
          {:ok, :idle}

        not MailInteraction.enabled?(conversation, owner) ->
          # The owner turned automatic messages off. Nothing is judged or sent.
          settle(fresh, "off")
          {:ok, :off}

        # The budgets limit handoffs and notifications, not organization: every
        # check judges what arrived, so a matter that must reach the reserve is
        # found while the ordinary pools are closed, and the rest is settled
        # with whose move it is instead of waiting unjudged.
        true ->
          # A mail's attachments are read before its first judgment: the text
          # often only points to them ("details in the attached file").
          fresh = Enum.map(fresh, &with_attachments(ctx, &1))

          screen_and_route(
            workspace,
            ctx,
            home,
            profile,
            conversation,
            CommaWeb.ProactiveMatters.group(fresh),
            now
          )
      end
    end
  end

  defp screen_and_route(workspace, ctx, home, profile, conversation, matters, now) do
    at = DateTime.from_unix!(now, :millisecond)

    with {:ok, model} <- RecommendationRuntime.model(workspace["router_agent_id"]),
         {:ok, history} <-
           Conversations.list_group_conversation_messages(ctx.group_id, home,
             tail: 12,
             limit: 12
           ) do
      known = matters(conversation, profile.user_id, at)
      statements = CommaWeb.MemberPortrait.statements(workspace)
      notebook = CommaWeb.ProactiveNotebook.context(workspace, profile.user_id, ctx.agent_id)

      read =
        matters
        |> Enum.sort_by(&arrived/1, :desc)
        |> Enum.take(@evidence_limit)
        |> MapSet.new(& &1["id"])

      screened =
        matters
        |> SystemsClock.async_stream(
          fn matter ->
            matter =
              if MapSet.member?(read, matter["id"]),
                do: with_evidence(workspace, ctx, profile, matter),
                else: matter

            input = attention_input([matter], history, statements, at, known, notebook)
            {matter, screen(workspace, model, profile, input, matter, at, known)}
          end,
          max_concurrency: @screen_concurrency,
          timeout: @judge_timeout_ms + 5_000,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Enum.zip(matters)
        |> Enum.map(fn
          {{:ok, result}, _matter} -> result
          {{:exit, _reason}, matter} -> {matter, {:error, :model_timed_out}}
        end)

      route_screened(workspace, ctx, home, profile, conversation, screened, now)
    end
  end

  # When the matter's newest item arrived, for the evidence reads.
  defp arrived(%{"arrivedAt" => %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)
  defp arrived(_matter), do: 0

  # The matter's current state before the screening: the full text of a mail
  # whose excerpt was cut off, and its links (`linked`).
  defp with_evidence(workspace, ctx, profile, matter) do
    matter =
      case full_mail(ctx, matter) do
        {:ok, read} -> read
        :error -> matter
      end

    # An empty read is kept: the screening saw that no link said anything.
    Map.put(
      matter,
      "linked",
      CommaWeb.ProactiveEvidence.linked(workspace, profile.user_id, profile.sources, matter)
    )
  end

  defp screen(workspace, model, profile, input, matter, now, known) do
    with {:ok, answer} <-
           RecommendationRenderer.attention(workspace, model, profile, input, @judge_timeout_ms),
         do: decide(answer, matter, now, known)
  end

  # Settles each screened matter by its decision and hands over at most
  # #{@handoffs_per_check} `interrupt` or `ask` matters, earliest due first.
  # The others the screening would hand over stay pending for the next check.
  # A failure the model could not finish counts on its matter alone; any
  # other error (billing) leaves every item pending.
  defp route_screened(workspace, ctx, home, profile, conversation, screened, now) do
    fatal =
      Enum.find_value(screened, fn
        {_matter, {:error, reason} = error} ->
          if not failed_judgment?(reason) and reason != :invalid_attention_decision, do: error

        _ ->
          nil
      end)

    if fatal do
      fatal
    else
      handoffs =
        Enum.flat_map(screened, fn {matter, result} ->
          settle_screened(matter, result, now)
        end)

      {now_batch, _later} =
        handoffs
        |> Enum.sort_by(fn {item, _message} -> {due_ms(item) || :infinity, arrived(item)} end)
        |> Enum.split(@handoffs_per_check)

      outcomes =
        Enum.map(now_batch, fn {item, message} ->
          result = dispose(workspace, ctx, home, profile, conversation, item, message, now)

          Logger.info(
            "proactive_check disposed decision=#{item["decision"]} role=#{item["role"]} " <>
              "outcome=#{inspect(elem(result, 1))}"
          )

          result
        end)

      case Enum.find(outcomes, &(elem(&1, 0) != :ok)) do
        nil -> {:ok, summary(outcomes, screened)}
        error -> error
      end
    end
  end

  # One screened matter: settled now, or a handoff to dispose.
  defp settle_screened(matter, result, now) do
    case result do
      {:ok, {:handoff, item, message}} ->
        Logger.info("proactive_attention decision=#{item["decision"]} routed=true")
        [{item, message}]

      {:ok, {:settle, decision, assessment}} ->
        Logger.info("proactive_attention decision=#{decision} routed=false")

        outcome =
          if decision == "resolved", do: "resolved", else: outcome(assessment["role"])

        settle([matter], outcome, @urgency[decision], Map.delete(assessment, "reason"),
          decision: decision,
          reason: assessment["reason"],
          due_at: due_wake(assessment, now)
        )

        []

      {:ok, :unclear} ->
        # The evidence could not tell, so nothing settles. The matter is
        # screened again, a bounded number of times.
        retry([matter])
        []

      {:error, :invalid_attention_decision} ->
        # An unusable answer decides nothing: the items keep waiting and are
        # screened again, a bounded number of times, instead of being dropped.
        retry([matter])
        []

      {:error, reason} ->
        # The model could not finish (a timeout or a permanent provider
        # error). The items stay pending with the failure counted and are
        # screened again after a backoff (`batch/2`).
        Logger.warning(
          "proactive_check judgment_failed reason=#{inspect(reason, limit: 3)} " <>
            "items=#{length(ProactiveMatters.items([matter]))}"
        )

        failed([matter])
        []
    end
  end

  defp summary(outcomes, screened) do
    results = Enum.map(outcomes, &elem(&1, 1))

    cond do
      :routed in results -> :routed
      :off in results -> :off
      :deferred in results -> :deferred
      Enum.any?(screened, &match?({_, {:error, _}}, &1)) -> :deferred
      :withdrawn in results -> :withdrawn
      true -> :quiet
    end
  end

  defp due_ms(item) do
    with due when is_binary(due) <- get_in(item, ["assessment", "due"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(due),
         do: DateTime.to_unix(at, :millisecond),
         else: (_ -> nil)
  end

  defp failed_judgment?(:model_timed_out), do: true
  defp failed_judgment?({:model_error, "permanent_provider_error"}), do: true
  defp failed_judgment?(_reason), do: false

  # A failed screening of these items. An item that failed alone is marked
  # `isolated`: the model cannot answer it, and it keeps being retried at the
  # longest backoff, visible in the owner's notebook.
  defp failed(items) do
    now = SystemsClock.system_time(:millisecond)
    records = ProactiveMatters.items(items)

    Enum.each(records, fn item ->
      attention = item["record"].attention || %{}

      MemberSourceItems.settle([item["record"]], %{
        "outcome" => "retry",
        "attempts" => attention["attempts"] || 0,
        "failures" => (attention["failures"] || 0) + 1,
        "isolated" => length(records) == 1,
        "at" => now
      })
    end)
  end

  defp failures(view), do: get_in(view, ["record", Access.key(:attention), "failures"]) || 0

  # How long items wait after their latest failed judgment: 15 minutes,
  # doubling with each failure, at most 6 hours.
  defp failure_backoff(failures),
    do: min(@failure_backoff_ms * Integer.pow(2, max(failures - 1, 0)), @failure_backoff_max_ms)

  # The items one check judges. Items a failed judgment returned are judged
  # apart from new arrivals, so an item the model cannot answer does not hold
  # back the rest: new arrivals and woken items every time; the returned
  # items once their backoff passed and nothing new waits, or they waited an
  # hour longer, fewest failures first, in a batch that halves with each
  # failure, so an item that keeps failing ends up judged alone.
  defp batch(views, now) do
    at = &(get_in(&1, ["record", Access.key(:attention), "at"]) || 0)

    {new, retried} = Enum.split_with(views, &(failures(&1) == 0))
    ready = Enum.filter(retried, &(at.(&1) + failure_backoff(failures(&1)) <= now))

    overdue =
      Enum.any?(ready, &(at.(&1) + failure_backoff(failures(&1)) + @retry_after_ms <= now))

    if ready != [] and (new == [] or overdue) do
      ready = Enum.sort_by(ready, &failures/1)
      least = failures(hd(ready))
      Enum.take(ready, max(div(length(ready), Integer.pow(2, least)), 1))
    else
      new
    end
  end

  # What happens to a matter the screening decided to hand over: a handoff
  # only when it is routable, not a copy of one handed over, and both its
  # handoff and its notification could be spent now. Otherwise it settles
  # with why and when it can be judged again.
  defp dispose(workspace, ctx, home, profile, conversation, item, message, now_ms) do
    owner = profile.user_id
    now = DateTime.from_unix!(now_ms, :millisecond)
    key = item_key(item)
    pool = if reserve_eligible?(item, now), do: "reserve", else: "ordinary"
    reserve = pool == "reserve"
    item = Map.put(item, "pool", pool)

    cond do
      not routable?(item) ->
        # Someone else has the next move, or it only informs the owner. A
        # matter with a due time is looked at again as it comes near.
        settle([item], outcome(item["role"]), item["urgency"], item["assessment"],
          due_at: due_wake(item["assessment"], now_ms)
        )

        {:ok, :quiet}

      repeat = repeated(conversation, owner, key, item, now_ms) ->
        settle([item], "duplicate", item["urgency"], item["assessment"], of: repeat)
        {:ok, :quiet}

      true ->
        handoff = MailInteraction.automatic_budget(conversation, owner, now_ms, reserve)
        notify = MailInteraction.notification_budget(conversation, owner, now_ms, reserve)

        case {handoff, notify} do
          {{:open, _}, {:open, _}} ->
            route_judged(workspace, ctx, home, profile, conversation, item, message)

          _ ->
            # The Router could not notify about it now, so a handoff would only
            # spend its cost. The matter waits with the reason and the time the
            # closed pool opens, or sooner when its due time comes into the
            # action window.
            {reason, opens} =
              case {handoff, notify} do
                {{:closed, at}, {:closed, other}} -> {"budgets", max(at, other)}
                {{:closed, at}, _} -> {"handoff_budget", at}
                {_, {:closed, at}} -> {"notification_budget", at}
              end

            # The pool that closed opens later than now.
            next_at = max(opens, now_ms + 1)

            Logger.info(
              "proactive_check deferred urgency=#{item["urgency"]} pool=#{pool} " <>
                "reason=#{reason} next_at=#{next_at}"
            )

            settle([item], "deferred", item["urgency"], item["assessment"],
              reason: reason,
              next_at: next_at,
              # The matter's own time is a separate wake, kept also after the
              # budget rechecks run out.
              due_at: due_wake(item["assessment"], now_ms),
              rechecks: rechecks(item),
              pool: pool
            )

            {:ok, :deferred}
        end
    end
  end

  defp route_judged(workspace, ctx, home, profile, conversation, item, message) do
    # The judgment read the item before a model call. It is routed only if it
    # still waits unchanged: revocation, a source turned off or a newer
    # collection may have withdrawn it meanwhile.
    # Provider reads happen before the item rows are locked.
    # The links the screening read travel as `linked`. A matter whose links
    # were not read before the screening is read now; that read is evidence
    # the screening did not have (`linked_after_screening`), and the Router
    # may withhold the matter for it.
    evidence =
      if Map.has_key?(item, "linked"),
        do: %{"linked" => item["linked"]},
        else: %{
          "linked_after_screening" =>
            CommaWeb.ProactiveEvidence.linked(workspace, profile.user_id, profile.sources, item)
        }

    routed =
      MemberSourceItems.while_pending(item["record"], fn ->
        route(ctx, home, profile.user_id, conversation, item, message, evidence)
      end)

    case routed do
      {:ok, _} ->
        settle([item], "routed", item["urgency"], item["assessment"],
          pool: item["pool"],
          decision: item["decision"],
          reason: item["reason"]
        )

        {:ok, :routed}

      {:error, :withdrawn} ->
        # Nothing is sent. The other judged items wait for the next check.
        {:ok, :withdrawn}

      {:error, :proactive_budget_exhausted} ->
        # Another check spent the last handoff meanwhile.
        {:ok, :deferred}

      {:error, :proactive_disabled} ->
        settle([item], "off")
        {:ok, :off}

      {:error, reason} when reason in [:mail_source_handled, :mail_source_changed] ->
        settle([item], "quiet")
        {:ok, :quiet}

      {:error, _} = error ->
        error
    end
  end

  # How often the item has waited for its `next_at` already, this time included.
  defp rechecks(item) do
    case item["record"].attention do
      %{"outcome" => outcome} = attention when outcome in ~w(deferred waiting) ->
        (attention["rechecks"] || 0) + 1

      _ ->
        1
    end
  end

  @doc "Whether a judged item may reach the Router: the owner must act, or may be the person someone waits on (`ask`)."
  def routable?(item) do
    # What ties the item to the owner: watching or being copied is not
    # responsibility. An answer without a link keeps the earlier behavior.
    linked = get_in(item, ["assessment", "link"]) not in ~w(subscribed none)

    linked and
      (item["role"] == "act" or
         (item["urgency"] == "ask" and item["role"] not in ~w(waiting reference)))
  end

  defp outcome("waiting"), do: "waiting"
  defp outcome(_role), do: "quiet"

  @doc """
  Whether a judged matter may spend the reserve pools
  (`SalixIM.MailInteraction.reserve_eligible?/2`): the owner must act and a
  cost lands inside the action window, or cannot be undone and names no time.
  The Home Conversation checks it again when it spends.
  """
  def reserve_eligible?(item, now \\ SystemsClock.utc_now()) do
    MailInteraction.reserve_eligible?(
      Map.put(item["assessment"] || %{}, "role", item["role"]),
      DateTime.to_unix(now, :millisecond)
    )
  end

  # When a matter with a due time is judged again: as it enters the reserve
  # window, then at the due time itself, whichever is still ahead. Each
  # judgment sets the next one, so a due time wakes a matter at most twice.
  # Any role: a meeting next week or a review someone else is doing may need
  # the owner as it comes near.
  defp due_wake(assessment, now_ms) do
    with nil <- MailInteraction.reserve_window_at(assessment, now_ms),
         {:ok, due, _offset} <- DateTime.from_iso8601((assessment || %{})["due"] || ""),
         at when at > now_ms <- DateTime.to_unix(due, :millisecond) do
      at
    else
      at when is_integer(at) -> at
      _ -> nil
    end
  end

  # The Home matter this one only repeats. The judgment must say so
  # (`repeats`: a copy, a resend, another alert of the same failure, with no
  # new cost, deadline, person waiting or change of state); the server can
  # tell a copy from a new event in the same thread or chain only through
  # that answer. Then a matter of the same key that changed within a day (a
  # week once handled), or the earlier matter it continues in another thread
  # once the Router stayed quiet about it or it was handled, absorbs it,
  # unless the new judgment rates it higher, gives an earlier due time or
  # makes it reserve-eligible. A later step that is not a copy reaches the
  # Router with the earlier matter, its decision and reason (`continues`),
  # and the Router weighs what the owner already said.
  defp repeated(conversation, owner, key, item, now) do
    entries = MailInteraction.entries(conversation)
    earlier = get_in(item, ["assessment", "continues", "key"])

    [{key, :same}, {earlier, :continues}]
    |> Enum.filter(fn {matter_key, _} -> is_binary(matter_key) end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.find_value(fn {matter_key, relation} ->
      value = entries[matter_key]

      with true <- get_in(item, ["assessment", "repeats"]) == true,
           %{"owner_id" => ^owner, "urgency" => urgency} when is_binary(urgency) <- value,
           changed when is_integer(changed) <- value["changed_at"],
           true <-
             now - changed <
               if(value["state"] == "handled", do: @handled_repeat_ms, else: @repeat_ms),
           true <- relation == :same or value["state"] in ~w(handled quiet),
           false <- escalates?(item, value) do
        matter_key
      else
        _ -> nil
      end
    end)
  end

  defp escalates?(item, value) do
    rank(item["urgency"]) > rank(value["urgency"]) or
      (item["pool"] == "reserve" and value["pool"] != "reserve") or
      earlier?(get_in(item, ["assessment", "due"]), get_in(value, ["assessment", "due"]))
  end

  defp rank(level), do: Enum.find_index(@levels_by_rank, &(&1 == level)) || -1

  defp earlier?(due, previous) do
    with {:ok, due, _} <- DateTime.from_iso8601(due || ""),
         previous <- DateTime.from_iso8601(previous || "") do
      case previous do
        {:ok, previous, _} -> DateTime.compare(due, previous) == :lt
        _ -> true
      end
    else
      _ -> false
    end
  end

  defp with_attachments(ctx, %{"context" => %{"attachments" => "unread"}} = item) do
    case full_mail(ctx, item) do
      {:ok, read} -> read
      :error -> item
    end
  end

  defp with_attachments(_ctx, item), do: item

  # The full text of a mail item whose pooled excerpt was cut off or whose
  # attachments were not read, read once through the owner's consented mail
  # account, with the text of its small text attachments. Other items or a
  # failed read leave the item as it is.
  defp full_mail(ctx, %{"toolkit" => toolkit, "messageId" => id, "context" => context} = item)
       when toolkit in ~w(gmail outlook) and is_binary(id) and is_map(context) do
    with true <- context["truncated"] == true or context["attachments"] == "unread",
         {:ok, mail} <-
           CommaWeb.ProactiveMail.read(
             %{"message_id" => id, "connection_id" => item["sourceId"]},
             ctx
           ),
         %{"body" => body} when is_binary(body) and body != "" <-
           Enum.find(mail["messages"] || [], &(&1["message_id"] == id)) do
      text =
        [body | attachment_texts(mail["attachments"])]
        |> Enum.join("\n")
        |> String.replace(~r/\s+/u, " ")

      read = %{"scope" => "full_message", "text" => text, "truncated" => false}

      # An attachment list that could not be read stays unread for the judgment.
      read =
        if context["attachments"],
          do:
            Map.put(read, "attachments", if(mail["attachments_read"], do: "read", else: "unread")),
          else: read

      {:ok, Map.put(item, "context", read)}
    else
      _ -> :error
    end
  end

  defp full_mail(_ctx, _item), do: :error

  # Each attachment by name; a file that was not read says so.
  defp attachment_texts(attachments) do
    for %{"name" => name} = file <- List.wrap(attachments) do
      case file["text"] do
        text when is_binary(text) ->
          "attachment #{name}" <>
            if(file["truncated"], do: " (cut off)", else: "") <> ":\n" <> text

        _ ->
          "attachment #{name} (#{file["content_type"]}, #{file["size"]} bytes): not read"
      end
    end
  end

  # The assessment belongs to the judged matter only; the other items settle
  # with the level it set. `opts` adds when the item is judged again
  # (`next_at` for a budget, `due_at` for its due time), why it waits
  # (`reason`), the pool it may spend (`pool`) and
  # the matter it repeats (`of`).
  defp settle(items, outcome, urgency \\ nil, assessment \\ nil, opts \\ []) do
    attention =
      %{"outcome" => outcome, "at" => SystemsClock.system_time(:millisecond)}
      |> then(&if(urgency, do: Map.put(&1, "urgency", urgency), else: &1))
      |> then(&if(role = (assessment || %{})["role"], do: Map.put(&1, "role", role), else: &1))
      |> Map.merge(
        opts
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      )

    {judged, others} =
      case assessment do
        %{"id" => id} -> Enum.split_with(items, &(&1["id"] == id))
        %{"cost" => _} -> {items, []}
        _ -> {[], items}
      end

    for {matters, attention} <- [
          {judged, Map.put(attention, "assessment", Map.drop(assessment || %{}, ~w(id role)))},
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

  defp item_key(item) do
    ref = reference(item)
    MailInteraction.key(item["sourceId"], ref["source_ref"])
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
  messages, the Condensed Workspace, portrait first, and the owner's notebook
  (`CommaWeb.ProactiveNotebook.context/3`). The proactive replay judges the
  same input.
  """
  def attention_input(
        items,
        home_messages,
        statements \\ [],
        now \\ SystemsClock.utc_now(),
        matters \\ [],
        notebook \\ nil
      ),
      do:
        %{
          "candidates" => Enum.map(items, &model_view(&1, now)),
          "conversation" => history(home_messages),
          "member" => CommaWeb.MemberPortrait.view(statements),
          "matters" => Enum.map(matters, &Map.delete(&1, "key")),
          "notebook" => notebook
        }
        |> Map.reject(fn {key, value} ->
          key in ~w(member matters notebook) and value in [[], nil, ""]
        end)

  @doc """
  The checked screening of one matter: `{:ok, :unclear}`,
  `{:ok, {:settle, decision, assessment}}` for `briefing` and `resolved`, or
  `{:ok, {:handoff, item, message}}` for an `interrupt` or `ask` matter the
  Router may receive. An answer about another candidate, with an unknown
  decision, or a handoff without a usable message is
  `{:error, :invalid_attention_decision}`. The server does not change a
  decision. An `interrupt` or `ask` matter that is not routable (another
  person's move, or only watched) settles as `briefing`.
  """
  def decide(answer, matter, now \\ SystemsClock.utc_now(), matters \\ [])

  def decide(
        %{"id" => id, "decision" => decision} = answer,
        %{"id" => id} = matter,
        _now,
        matters
      )
      when is_binary(decision) do
    # An answer without a role keeps the earlier behavior: the owner must act.
    role =
      if answer["role"] in RecommendationRenderer.attention_roles(),
        do: answer["role"],
        else: "act"

    reason =
      if is_binary(answer["reason"]), do: String.slice(String.trim(answer["reason"]), 0, 400)

    assessment =
      answer
      |> assessment(matters)
      |> Map.put("role", role)
      |> then(
        &if(answer["link"] in RecommendationRenderer.attention_links(),
          do: Map.put(&1, "link", answer["link"]),
          else: &1
        )
      )
      |> then(&if(reason, do: Map.put(&1, "reason", reason), else: &1))

    message = String.trim(if is_binary(answer["message"]), do: answer["message"], else: "")

    item =
      matter
      |> Map.put("urgency", @urgency[decision])
      |> Map.put("role", role)
      |> Map.put("decision", decision)
      |> Map.put("reason", reason)
      |> Map.put("assessment", Map.delete(assessment, "reason"))

    cond do
      decision == "unclear" ->
        {:ok, :unclear}

      decision not in RecommendationRenderer.attention_decisions() ->
        {:error, :invalid_attention_decision}

      decision in ~w(interrupt ask) and routable?(item) ->
        if message == "" or byte_size(message) > 2_400,
          do: {:error, :invalid_attention_decision},
          else: {:ok, {:handoff, item, message}}

      decision in ~w(interrupt ask) ->
        {:ok, {:settle, "briefing", assessment}}

      true ->
        {:ok, {:settle, decision, assessment}}
    end
  end

  def decide(_answer, _matter, _now, _matters), do: {:error, :invalid_attention_decision}

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
      "reversible" => answer["reversible"] != false,
      "repeats" => answer["repeats"] == true
    }
    |> then(&if(continues, do: Map.put(&1, "continues", continues), else: &1))
  end

  # Mail age starts at provider receipt. Collection can find an expired code
  # for the first time. An unknown receipt time does not make the mail fresh.
  defp model_view(item, now) do
    at = age_from(item)

    %{
      "minutesAgo" =>
        if(match?(%DateTime{}, at),
          do: max(DateTime.diff(now, at, :minute), 0)
        ),
      "id" => item["id"],
      "app" => item["app"],
      "title" => item["title"],
      "excerpt" => item["excerpt"],
      "relationship" => item["relationship"],
      "recipient" => item["recipient"],
      "context" => item["context"],
      "facts" => item["facts"],
      "related" => item["related"],
      "linked" => item["linked"]
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", %{}, []] end)
    |> Map.new()
  end

  defp age_from(%{"toolkit" => toolkit} = item) when toolkit in ~w(gmail outlook) do
    with timestamp when is_binary(timestamp) <- get_in(item, ["facts", "messageTimestamp"]),
         {:ok, at, _offset} <- DateTime.from_iso8601(timestamp) do
      at
    else
      _ -> nil
    end
  end

  defp age_from(item), do: item["arrivedAt"]

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

  defp route(ctx, home, owner, conversation, item, message, evidence) do
    ref = reference(item)
    key = MailInteraction.key(item["sourceId"], ref["source_ref"])
    current = MailInteraction.entries(conversation)[key]

    command = %{
      "action" => "present",
      "automatic" => true,
      "urgency" => item["urgency"],
      # The screening's decision: the Router delivers it, and withholds it
      # only for evidence the screening did not have.
      "decision" => item["decision"],
      "reason" => item["reason"],
      # The pool the handoff and the Router's notification may spend: the
      # reserve only for a reserve-eligible matter.
      "pool" => item["pool"],
      # What happens if the owner does nothing: cost, due time, reversibility.
      "assessment" => Map.delete(item["assessment"] || %{}, "continues"),
      # The earlier matter this one continues: the Router sees its decision,
      # and the notebook shows them together.
      "continues" => continues(item, key),
      # How the item reached the owner, such as through the junk folder.
      "relationship" => item["relationship"],
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
      # What the matter's links said when it was screened, or, for a matter
      # whose links the screening did not read, when it was handed over.
      "linked" => evidence["linked"],
      "linked_after_screening" => evidence["linked_after_screening"]
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
