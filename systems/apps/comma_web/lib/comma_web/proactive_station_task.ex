defmodule CommaWeb.ProactiveStationTask do
  @moduledoc """
  Station-hosted Tasks that concern their workspace owner, as proactive
  matters: a still.fail chat that waits for the owner, finished with a result
  the owner has not read, or failed, as its station's Task index
  (`SalixStore.StationTaskIndex`) says.

  The owner's collection chain (`CommaWeb.MemberSourceIngest`, every 15
  minutes) and debounced station index updates call `reconcile/3`. It reads
  the Group's index (its 500 most recently active rows), applies the owner's
  deterministic notification policy (`stillfail_notification_level`, 2-minute
  presence deferral while active in still.fail, 6-hour recency window, and
  Lean-verified `SalixStore.ProactiveKernel` transitions), and projects each
  admitted actionable decision card (`need` with a non-system card or legacy
  pre-attention stop) **deterministically into Comma Home** as a non-waking
  message (with an independent clickable question card for CAS-capable
  stations) plus a compact 1-line `no_wake` context note for the Router.
  Link-only system cards (`login`, `secret`, `vault`, `signin`, `device`,
  `adb`, `rig`), `failed` stops, `done` receipts, and cardless prose stay in
  Routine and the Monoid Tasks rail instead of interrupting Home chat.

  Only `options` and `text` stops call `StationHostedTasks.read/4` (inside the
  Oban worker, before entering `ConversationActor`). Transient read failures
  schedule bounded backoff retries instead of writing cardless placeholders;
  if retries exhaust, the stop stays open in Routine and reconciles again when
  the station reconnects or pushes a new index update.

  The matter key is `["station_task", task_ref]`. Its observation is the kind
  and the row's last activity when it was seen (`needs_review:<at>` for a
  `need`, `done:<at>`, `failed:<at>`). Each committed Home notification stores
  `home_message_id` on the matter so reverse-folding and new-question
  replacement locate the open card directly in O(1).
  """
  use Oban.Worker, queue: :comma_external, max_attempts: 3

  require Logger
  alias CommaWeb.{HomeMail, Proactive}
  alias SalixIM.{ConversationServer, Conversations, MailInteraction, StationTaskQuestionSync}
  alias SalixIM.Ports.StationHostedTasks
  alias SalixStore.ProactiveKernel

  @account "station_task"
  # The status a station from before says a chat waits for a person with.
  @legacy_status "needs_review"
  @attentions ~w(need done failed)
  # The index rows one check reads (the most recently active first).
  @read_limit 500
  # A chat of a station from before that has waited longer is no news, and a
  # need or a failure older than this is no longer urgent.
  @recent_ms 7 * 24 * 60 * 60 * 1000
  # Unseen stops older than this belong in Routine, not as real-time Home
  # notifications.
  @handoff_max_age_ms 6 * 60 * 60 * 1000
  # Unread `done` stops wait this long before notifying Home so owners who are
  # already reading still.fail incur zero redundant notifications.
  @done_grace_ms 3 * 60 * 1000
  # When a connected still.fail station reports owner activity within this
  # window, ordinary `need`/`failed` stops defer for `@presence_defer_ms`
  # anchored to `last_activity_at` so active in-app handling stays quiet.
  @presence_active_window_ms 2 * 60 * 1000
  @presence_defer_ms 2 * 60 * 1000
  # Uniform short debounce for index-driven wakeups (no LLM batching needed).
  @debounce_s 2
  # Max forward station clock skew tolerated when computing grace or presence
  # windows so a wildly skewed timestamp cannot stall delivery indefinitely.
  @max_clock_skew_ms 60 * 1000
  # Maximum ordinary stops delivered per reconcile pass; any overflow queues
  # an immediate continuation pass.
  @max_ordinary_per_reconcile 3
  @read_tail 12
  # Bounded retry backoff (seconds) when `task.read` fails transiently for an
  # `options` or `text` stop.
  @read_retry_delays_s [10, 20, 30]
  @max_card_images 4
  @max_card_image_bytes 10_000_000
  @max_image_chunks 64
  @image_extensions ~w(.png .jpg .jpeg .webp .gif)

  @doc """
  The `SalixWeb.StationTaskIndex` observer. Queues one short debounced check
  for the workspace owner when automatic messages and still.fail notifications
  are enabled.
  """
  def station_tasks_changed(group_id) when is_binary(group_id) do
    with {:ok, %{"status" => "active", "owner_user_id" => owner}} when is_binary(owner) <-
           Comma.Workspaces.get_by_group(group_id),
         {:ok, true} <- Proactive.automatic?(group_id, owner),
         true <- Proactive.stillfail_notification_level(group_id, owner) != "off",
         {:ok, _job} <- enqueue_change_check(group_id, owner) do
      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  def station_tasks_changed(_group_id), do: :ok

  defp enqueue_change_check(group_id, owner) do
    %{"group_id" => group_id, "user_id" => owner}
    |> new(
      schedule_in: @debounce_s,
      unique: [
        period: 15,
        fields: [:worker, :args],
        states: [:available, :scheduled]
      ]
    )
    |> then(&Oban.insert(Comma.Oban, &1))
  end

  @doc """
  The `SalixIM` station-task reply observer. Closes an open `station_task`
  matter as soon as the owner's reply reaches the station chat (either via a
  Home question card click or a Router `send_message`), keeping its observation
  so the same stop is not re-notified before the station sends its next index
  page.
  """
  def router_replied(group_id, conversation_id, _seq)
      when is_binary(group_id) and is_binary(conversation_id) do
    with {:ok, %{"status" => "active", "owner_user_id" => owner}} when is_binary(owner) <-
           Comma.Workspaces.get_by_group(group_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(owner),
         {:ok, workspace, ctx, home} <- HomeMail.context(user, %{}, group_id),
         true <- workspace["owner_user_id"] == owner,
         {:ok, conversation} <- Conversations.get_group_conversation_record(group_id, home),
         key = MailInteraction.key(@account, conversation_id),
         %{} = value <- MailInteraction.entries(conversation)[key],
         true <- value["owner_id"] == owner,
         {{:handled, tag, at}, true} <- ProactiveKernel.station_router_replied(track_of(value)) do
      observation = format_observation({tag, at})

      case ConversationServer.mail_interaction(group_id, home, owner, ctx.agent_id, %{
             "action" => "handled",
             "key" => key,
             "generation" => value["generation"],
             "request_id" => request_id("station-task-answered", key, observation),
             "message_id" => observation
           }) do
        {:ok, _} ->
          CommaWeb.ProactiveNotebook.enqueue(group_id, owner)
          :ok

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  def router_replied(_group_id, _conversation_id, _seq), do: :ok

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"group_id" => group, "user_id" => owner} = args}) do
    with {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(owner),
         {:ok, workspace, ctx, home} <- HomeMail.context(user, %{}, group),
         true <- workspace["owner_user_id"] == owner,
         {:ok, true} <- Proactive.automatic?(group, owner) do
      reconcile(ctx, home, owner, retry_attempt: args["read_retry_attempt"] || 0)
    else
      _ -> :ok
    end
  end

  @doc """
  Deterministically delivers admitted station Tasks directly into Comma Home
  (one Home message per stop, zero Router LLM calls) and closes matters whose
  Task moved on.
  """
  def reconcile(ctx, home, owner, opts \\ []) do
    retry_attempt = Keyword.get(opts, :retry_attempt, 0)

    with {:ok, %{"status" => "active", "email" => email}} when is_binary(email) <-
           Comma.Accounts.get_user(owner),
         {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      now = SystemsClock.system_time(:millisecond)
      since = now - @recent_ms
      handoff_since = now - @handoff_max_age_ms
      matters = matters(conversation, owner)
      level = MailInteraction.stillfail_notification_level(conversation, owner)
      device_emails = SalixEnv.StillfailDevices.owner_emails_by_device(ctx.group_id)
      cas_by_device = SalixEnv.StillfailDevices.task_say_cas_by_device(ctx.group_id)
      read_file_by_device = SalixEnv.StillfailDevices.task_read_file_by_device(ctx.group_id)
      owner_active? = owner_active_in_stillfail?(ctx.group_id, now)
      locale = Comma.Accounts.locale(owner)

      concerning =
        concerning(
          ctx.group_id,
          String.downcase(String.trim(email)),
          device_emails,
          since,
          handoff_since,
          now,
          owner_active?,
          level,
          matters
        )

      closes =
        for {ref, value} <- matters,
            not Map.has_key?(concerning, ref),
            {_next_track, {:close, _obs}} <- [
              ProactiveKernel.step_station_stop(track_of(value), :working, 0, since)
            ],
            do: close(ctx, home, owner, ref, value, locale)

      for {ref, value} <- matters,
          %{pending: false, observation: obs, kind: item_kind} <- [Map.get(concerning, ref)],
          is_binary(value["message_id"]) and value["message_id"] != obs do
        fold_prior_card_if_open(ctx, home, owner, ref, value,
          reason: if(item_kind == "need", do: :superseded, else: :closed),
          locale: locale
        )
      end

      {admitted_code, admitted_ordinary, more_ordinary?} =
        presents(conversation, owner, concerning, now)

      deliver_opts = [
        cas_by_device: cas_by_device,
        read_file_by_device: read_file_by_device,
        locale: locale
      ]

      code_results =
        Enum.map(admitted_code, fn {ref, item} ->
          deliver_stop(ctx, home, owner, ref, item, matters[ref], deliver_opts)
        end)

      ordinary_results =
        Enum.map(admitted_ordinary, fn {ref, item} ->
          deliver_stop(ctx, home, owner, ref, item, matters[ref], deliver_opts)
        end)

      results = code_results ++ ordinary_results ++ closes

      schedule_deferred_rechecks(ctx.group_id, owner, concerning)

      if Enum.any?(results, &match?({:retry_read, _}, &1)) do
        schedule_read_retry(ctx.group_id, owner, retry_attempt)
      end

      if more_ordinary? do
        _ = enqueue_change_check(ctx.group_id, owner)
      end

      # Routine's notebook lists the owner's matters, these among them.
      if Enum.any?(results, &match?({:ok, _}, &1)),
        do: CommaWeb.ProactiveNotebook.enqueue(ctx.group_id, owner)

      for {:error, reason} <- results,
          do: Logger.info("proactive_station_task skipped reason=#{inspect(reason)}")
    end

    :ok
  end

  @doc """
  The normalized emails that identify the Comma workspace owner on `row`'s
  still.fail station: the owner's Comma login email, plus any still.fail owner
  email bound to `row.device_id`.
  """
  def matching_emails(row, owner_email, device_emails)
      when is_binary(owner_email) and is_map(device_emails) do
    case Map.get(device_emails, row.device_id) do
      bound when is_binary(bound) and bound != "" and bound != owner_email ->
        [owner_email, bound]

      _ ->
        [owner_email]
    end
  end

  defp owner_active_in_stillfail?(group_id, now) do
    group_id
    |> SalixEnv.StillfailDevices.owner_active_at_by_device()
    |> Map.values()
    |> Enum.any?(fn ts ->
      is_integer(ts) and now - ts < @presence_active_window_ms and ts <= now + @max_clock_skew_ms
    end)
  end

  # The rows that concern the owner and are admitted by the owner's still.fail
  # notification level, by their Task ref, evaluated through the verified stop
  # state machine.
  defp concerning(
         group,
         email,
         device_emails,
         since,
         handoff_since,
         now,
         owner_active?,
         level,
         matters
       ) do
    group
    |> SalixStore.StationTaskIndex.list_group(@read_limit)
    |> Enum.flat_map(fn row ->
      emails = matching_emails(row, email, device_emails)

      case kind(row, emails, since) do
        nil ->
          []

        kind ->
          card_kind = card_kind(row)

          if home_notification_admitted?(level, kind, card_kind, row) do
            ref = StationHostedTasks.ref(row.station_id, row.thread)
            at = row.last_activity_at || 0
            phase = phase_of(kind, card_kind)
            track = track_of(matters[ref])

            case ProactiveKernel.step_station_stop(track, phase, at, since) do
              {_next, {:present, obs_tuple, pool, urgency}} when at >= handoff_since ->
                {defer_reason, defer_until} = deferral(pool, kind, at, now, owner_active?)

                [
                  {ref,
                   %{
                     row: row,
                     kind: kind,
                     card_kind: card_kind,
                     pool: pool,
                     observation: format_observation(obs_tuple),
                     urgency: Atom.to_string(urgency),
                     pending: is_nil(defer_until),
                     defer_reason: defer_reason,
                     defer_until: defer_until
                   }}
                ]

              {_next, _transition} ->
                [
                  {ref,
                   %{
                     row: row,
                     kind: kind,
                     card_kind: card_kind,
                     pool: :ordinary,
                     observation: observation_prefix(kind) <> ":" <> Integer.to_string(at),
                     urgency: "normal",
                     pending: false,
                     defer_reason: nil,
                     defer_until: nil
                   }}
                ]
            end
          else
            []
          end
      end
    end)
    |> Map.new()
  end

  # Urgent interactive system cards never wait for grace or presence deferral.
  defp deferral(:code, _kind, _at, _now, _owner_active?), do: {nil, nil}

  defp deferral(_pool, "done", at, now, _owner_active?)
       when is_integer(at) and at > now - @done_grace_ms and at <= now + @max_clock_skew_ms do
    {"done_grace", at + @done_grace_ms}
  end

  defp deferral(_pool, kind, at, now, true)
       when kind in ~w(need failed) and is_integer(at) and at > now - @presence_defer_ms and
              at <= now + @max_clock_skew_ms do
    {"presence_defer", at + @presence_defer_ms}
  end

  defp deferral(_pool, _kind, _at, _now, _owner_active?), do: {nil, nil}

  defp schedule_deferred_rechecks(group_id, owner, concerning) do
    for reason <- ~w(done_grace presence_defer) do
      earliest =
        concerning
        |> Map.values()
        |> Enum.filter(&(&1.defer_reason == reason and is_integer(&1.defer_until)))
        |> Enum.map(& &1.defer_until)
        |> Enum.min(fn -> nil end)

      if is_integer(earliest) do
        at = DateTime.from_unix!(earliest, :millisecond)

        %{"group_id" => group_id, "user_id" => owner, "reason" => reason}
        |> new(
          scheduled_at: at,
          unique: [
            period: :infinity,
            fields: [:worker, :args],
            states: [:available, :scheduled]
          ],
          replace: [scheduled: [:scheduled_at]]
        )
        |> then(&Oban.insert(Comma.Oban, &1))
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  defp schedule_read_retry(group_id, owner, attempt)
       when is_integer(attempt) and attempt >= 0 do
    case Enum.at(@read_retry_delays_s, attempt) do
      delay_s when is_integer(delay_s) ->
        %{
          "group_id" => group_id,
          "user_id" => owner,
          "reason" => "read_retry",
          "read_retry_attempt" => attempt + 1
        }
        |> new(
          schedule_in: delay_s,
          unique: [
            period: delay_s + 15,
            fields: [:worker, :args],
            states: [:available, :scheduled]
          ]
        )
        |> then(&Oban.insert(Comma.Oban, &1))

        :ok

      nil ->
        # Retries exhausted while station stays offline: leave stop open in
        # Routine without writing a dead cardless placeholder; reconnect or
        # the next index update will reconcile automatically.
        :ok
    end
  rescue
    _ -> :ok
  end

  defp kind(%{attention: "need", waits_for: people}, emails, _since)
       when is_list(people) and people != [] do
    if emails_intersect?(people, emails), do: "need"
  end

  defp kind(%{attention: attention} = row, emails, _since) when attention in @attentions do
    if owner_involved?(row, emails), do: attention
  end

  # A station from before says neither what a chat asks nor of whom.
  defp kind(%{attention: nil, waits_for: people} = row, emails, since) when people in [nil, []] do
    if row.status == @legacy_status and (row.last_activity_at || 0) >= since and
         owner_involved?(row, emails),
       do: "need"
  end

  defp kind(_row, _emails, _since), do: nil

  defp owner_involved?(row, emails) do
    row.router == true or
      emails_intersect?(row.waits_for, emails) or
      email_in?(row.created_by, emails) or
      emails_intersect?(Map.get(row, :participants), emails)
  end

  defp emails_intersect?(list, emails) when is_list(list) do
    Enum.any?(list, &email_in?(&1, emails))
  end

  defp emails_intersect?(_list, _emails), do: false

  defp email_in?(value, emails) when is_binary(value) do
    String.downcase(String.trim(value)) in emails
  end

  defp email_in?(_value, _emails), do: false

  @home_blocked_system_cards ~w(login secret vault signin device adb rig)

  # Home chat only receives actionable decision cards (`need` with an
  # interactive card like `options`, `text`, or `approval`, or legacy
  # pre-attention stations). Link-only system cards (`login`, `secret`, `vault`,
  # `signin`, `device`, `adb`, `rig`), `failed` runtime stops, completed
  # (`done`) summaries, and cardless prose notices stay in the Routine /
  # Monoid Tasks rail rather than interrupting the Home conversation stream.
  defp home_notification_admitted?(level, kind, card_kind, row) do
    if MailInteraction.stillfail_notification_allows?(level, kind) do
      case kind do
        "need" ->
          (is_binary(card_kind) and card_kind != "" and
             card_kind not in @home_blocked_system_cards) or
            is_nil(row.attention)

        _ ->
          false
      end
    else
      false
    end
  end

  defp card_kind(row) do
    Enum.find_value(row.labels || [], fn
      "card:" <> kind when kind != "" -> kind
      _ -> nil
    end)
  end

  defp phase_of("need", card) when is_binary(card), do: {:need, card}
  defp phase_of("need", _card), do: :need
  defp phase_of("done", _card), do: :done
  defp phase_of("failed", _card), do: :failed

  # A need keeps the observation of a station from before, so a stop already
  # handed over is not handed over again when its station starts saying more.
  defp observation_prefix("need"), do: @legacy_status
  defp observation_prefix(kind), do: kind

  defp format_observation({1, at}), do: @legacy_status <> ":" <> Integer.to_string(at)
  defp format_observation({2, at}), do: "done:" <> Integer.to_string(at)
  defp format_observation({3, at}), do: "failed:" <> Integer.to_string(at)

  defp parse_observation(@legacy_status <> ":" <> digits), do: parse_obs_digits(1, digits)
  defp parse_observation("done:" <> digits), do: parse_obs_digits(2, digits)
  defp parse_observation("failed:" <> digits), do: parse_obs_digits(3, digits)
  defp parse_observation(_other), do: :error

  defp parse_obs_digits(tag, digits) do
    case Integer.parse(digits) do
      {at, ""} -> {:ok, {tag, at}}
      _ -> :error
    end
  end

  defp track_of(nil), do: :unseen

  defp track_of(%{"message_id" => "left:" <> rest}) do
    case parse_observation(rest) do
      {:ok, {tag, at}} -> {:left, tag, at}
      :error -> {:left, 0, 0}
    end
  end

  defp track_of(%{"state" => state, "message_id" => message_id}) when is_binary(message_id) do
    case parse_observation(message_id) do
      {:ok, {tag, at}} ->
        if state in ~w(handled quiet),
          do: {:handled, tag, at},
          else: {:open, tag, at}

      :error ->
        :unseen
    end
  end

  defp track_of(_other), do: :unseen

  # Admits urgent interactive system cards individually against the dedicated
  # `agent_code` pool (40/day), and ordinary stops individually against the
  # `agent` safety circuit-breaker (`agent_sent_at`, 120/day), capped per pass
  # with continuation when more remain.
  defp presents(conversation, owner, concerning, now) do
    pending =
      concerning
      |> Enum.filter(fn {_ref, item} -> item.pending end)
      |> Enum.sort_by(fn {ref, item} ->
        {item.urgency != "high", -(item.row.last_activity_at || 0), ref}
      end)

    {code_items, ordinary_items} =
      Enum.split_with(pending, fn {_ref, item} -> item.pool == :code end)

    admitted_code =
      case MailInteraction.agent_code_budget(conversation, owner, :handoff, now) do
        {:open, remaining} -> Enum.take(code_items, remaining)
        {:closed, _next_at} -> []
      end

    {admitted_ordinary, more_ordinary?} =
      case MailInteraction.agent_budget(conversation, owner, :handoff, now) do
        {:open, remaining} when remaining > 0 ->
          take_n = min(remaining, @max_ordinary_per_reconcile)
          admitted = Enum.take(ordinary_items, take_n)
          more? = length(ordinary_items) > take_n and remaining > take_n
          {admitted, more?}

        _ ->
          {[], false}
      end

    {admitted_code, admitted_ordinary, more_ordinary?}
  end

  defp deliver_stop(ctx, home, owner, ref, item, current, opts) do
    cas_by_device = Keyword.get(opts, :cas_by_device, %{})
    read_file_by_device = Keyword.get(opts, :read_file_by_device, %{})
    locale = Keyword.get(opts, :locale)
    %{row: row} = item

    stop_spec = %{
      ref: ref,
      kind: item.kind,
      card_kind: item.card_kind,
      title: row.title || "",
      url: row.url || "",
      note: row.note,
      observation: item.observation,
      cas_supported?: Map.get(cas_by_device, row.device_id, false),
      locale: locale
    }

    if needs_station_read?(item) do
      case fetch_station_messages(ctx, ref) do
        {:ok, messages} ->
          attachments =
            if Map.get(read_file_by_device, row.device_id, false) do
              case StationTaskQuestionSync.pending_card_message(messages, item.card_kind) do
                {:pending, card_msg, _card} -> stage_card_images(ctx, ref, card_msg)
                _ -> []
              end
            else
              []
            end

          case StationTaskQuestionSync.build_home_notification(stop_spec,
                 messages: messages,
                 attachments: attachments
               ) do
            :already_resolved ->
              if is_map(current) do
                sync_closed_home_question_card(ctx, home, owner, ref, current,
                  messages: messages,
                  reason: :closed,
                  locale: locale
                )

                mark_handled(ctx, home, owner, ref, current, item.observation)
              else
                {:ok, :already_resolved}
              end

            {:ok, built} ->
              fold_prior_card_if_open(ctx, home, owner, ref, current,
                messages: messages,
                reason: if(item.kind == "need", do: :superseded, else: :closed),
                locale: locale
              )

              commit_direct_home(ctx, home, owner, ref, item, current, built)
          end

        {:error, _reason} ->
          {:retry_read, ref}
      end
    else
      {:ok, built} = StationTaskQuestionSync.build_home_notification(stop_spec)

      fold_prior_card_if_open(ctx, home, owner, ref, current,
        reason: if(item.kind == "need", do: :superseded, else: :closed),
        locale: locale
      )

      commit_direct_home(ctx, home, owner, ref, item, current, built)
    end
  end

  defp needs_station_read?(%{kind: "need", card_kind: card_kind})
       when card_kind in ~w(options text),
       do: true

  defp needs_station_read?(_item), do: false

  defp commit_direct_home(ctx, home, owner, ref, item, current, built) do
    %{row: row, observation: observation} = item
    key = MailInteraction.key(@account, ref)

    base = %{
      "action" => "present",
      "automatic" => true,
      "urgency" => item.urgency,
      "key" => key,
      "request_id" => request_id("station-task", key, observation),
      "generation" => if(is_map(current), do: current["generation"]),
      "account_id" => @account,
      "thread_id" => ref,
      "message_id" => observation,
      "subject" => row.title || "",
      "source_url" => row.url || "",
      "read" => read_recipe(ref),
      "direct_home" => %{
        "content" => built.content,
        "metadata" => built.metadata,
        "kind" => built.kind,
        "router_context" => Map.get(built, :router_context, %{}),
        "advise_router" => Map.get(built, :advise_router, false)
      }
    }

    payload =
      if item.pool == :code do
        Map.merge(base, %{
          "pool" => "agent_code",
          "assessment" => %{
            "role" => "act",
            "code" => true,
            "cost" => "approval_or_login_expires",
            "reversible" => true
          }
        })
      else
        Map.put(base, "pool", "agent")
      end

    ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, payload)
  end

  defp mark_handled(ctx, home, owner, ref, current, observation) do
    key = MailInteraction.key(@account, ref)

    ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, %{
      "action" => "handled",
      "key" => key,
      "generation" => current["generation"],
      "request_id" => request_id("station-task-resolved", key, observation),
      "message_id" => observation
    })
  end

  # The owner's station Task matters, by their Task ref.
  defp matters(conversation, owner) do
    conversation
    |> MailInteraction.entries()
    |> Enum.filter(fn {_key, value} ->
      value["owner_id"] == owner and value["account_id"] == @account
    end)
    |> Map.new(fn {_key, value} -> {value["thread_id"], value} end)
  end

  defp read_recipe(ref) do
    %{
      "tool" => "im_api.internal.read_conversation",
      "arguments" => %{
        "connect_id" => "internal",
        "conversation_id" => ref,
        "tail" => @read_tail
      }
    }
  end

  # Leaving is recorded even when the matter was already handled, so the next
  # stop of the same chat starts new attention. If an open Home question card
  # was bound to this still.fail chat, mirror the user's still.fail choice into
  # Home so the card folds cleanly without waking the Router.
  defp close(ctx, home, owner, ref, value, locale) do
    fold_prior_card_if_open(ctx, home, owner, ref, value, reason: :closed, locale: locale)
    key = MailInteraction.key(@account, ref)
    observation = "left:" <> (value["message_id"] || "")

    ConversationServer.mail_interaction(ctx.group_id, home, owner, ctx.agent_id, %{
      "action" => "handled",
      "key" => key,
      "generation" => value["generation"],
      "request_id" => request_id("station-task-closed", key, observation),
      "message_id" => observation
    })
  end

  defp fold_prior_card_if_open(ctx, home, owner, ref, current, opts) do
    if is_map(current) do
      sync_closed_home_question_card(ctx, home, owner, ref, current, opts)
    else
      :ok
    end
  end

  @home_card_sync_window 30
  @station_sync_read_limit 50

  defp sync_closed_home_question_card(ctx, home, owner, ref, current, opts) do
    with {:ok, %{"message_id" => question_id, "content" => content} = question_msg} <-
           locate_open_question_message(ctx.group_id, home, ref, current),
         %{} = question_block <- SalixIM.ConversationQuestion.question_block(content) do
      card_seq = get_in(question_msg, ["metadata", "station_task_question", "card_seq"])

      stillfail_messages =
        case Keyword.get(opts, :messages) do
          list when is_list(list) ->
            list

          _ ->
            case fetch_station_messages(ctx, ref) do
              {:ok, list} -> list
              _ -> []
            end
        end

      {display_text, answer_block} =
        StationTaskQuestionSync.resolve_stillfail_answer(
          question_block,
          stillfail_messages,
          card_seq: card_seq,
          reason: Keyword.get(opts, :reason, :closed),
          locale: Keyword.get(opts, :locale)
        )

      _ =
        SalixIM.RouterConversationInput.append_resolved_question_answer(
          ctx.group_id,
          owner,
          question_id,
          display_text,
          answer_block,
          ref
        )

      :ok
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # O(1) lookup via the `home_message_id` pointer persisted on `MailInteraction`,
  # with bounded fallback only for legacy matters predating the pointer.
  defp locate_open_question_message(group_id, home, ref, %{"home_message_id" => msg_id})
       when is_binary(msg_id) and msg_id != "" do
    case Conversations.get_group_conversation_message(group_id, home, msg_id) do
      {:ok, %{"actor_type" => "agent"} = msg} ->
        if get_in(msg, ["metadata", "station_task_question", "conversation_id"]) == ref and
             not is_nil(SalixIM.ConversationQuestion.question_block(msg["content"])),
           do: {:ok, msg},
           else: :none

      _ ->
        :none
    end
  end

  defp locate_open_question_message(group_id, home, ref, _current) do
    with {:ok, %{"messages" => messages}} <-
           Conversations.list_group_conversation_message_page(group_id, home,
             limit: @home_card_sync_window
           ) do
      StationTaskQuestionSync.find_open_question_message(messages, ref)
    else
      _ -> :none
    end
  end

  defp fetch_station_messages(ctx, ref) do
    with {station_id, thread} <- StationHostedTasks.parse(ref),
         scope when is_map(scope) <- station_read_scope(ctx),
         {:ok, %{"messages" => list} = page} when is_list(list) <-
           StationHostedTasks.read(scope, station_id, thread, %{
             "after" => 0,
             "limit" => @station_sync_read_limit
           }) do
      through = page["through"]
      last_seq = list |> Enum.map(&(&1["seq"] || 0)) |> Enum.max(fn -> 0 end)

      if is_integer(through) and through > last_seq do
        tail_after = max(through - @station_sync_read_limit, 0)

        case StationHostedTasks.read(scope, station_id, thread, %{
               "after" => tail_after,
               "limit" => @station_sync_read_limit
             }) do
          {:ok, %{"messages" => tail}} when is_list(tail) -> {:ok, tail}
          _ -> {:ok, list}
        end
      else
        {:ok, list}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :station_read_unavailable}
    end
  end

  defp station_read_scope(ctx) do
    tenant_id =
      Map.get(ctx, :tenant_id) ||
        case SalixIM.GroupDirectory.get_group(ctx.group_id) do
          {:ok, %{"tenant_id" => tid}} -> tid
          _ -> nil
        end

    if is_binary(tenant_id),
      do: %{tenant_id: tenant_id, group_id: ctx.group_id},
      else: nil
  end

  defp request_id(prefix, key, observation) do
    prefix <> ":" <> Base.encode16(:crypto.hash(:sha256, key <> observation), case: :lower)
  end

  defp stage_card_images(ctx, ref, %{"seq" => seq, "files" => files})
       when is_integer(seq) and seq > 0 and is_list(files) do
    agent_id = Map.get(ctx, :agent_id)

    with true <- is_binary(agent_id) and agent_id != "",
         {station_id, thread} <- StationHostedTasks.parse(ref),
         scope when is_map(scope) <- station_read_scope(ctx) do
      files
      |> Enum.filter(&eligible_card_image?/1)
      |> Enum.uniq_by(& &1["name"])
      |> Enum.take(@max_card_images)
      |> Enum.flat_map(fn file ->
        case stage_card_image(agent_id, scope, station_id, thread, ref, seq, file) do
          {:ok, block} -> [block]
          :error -> []
        end
      end)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp stage_card_images(_ctx, _ref, _card_msg), do: []

  defp eligible_card_image?(%{"name" => name, "size" => size})
       when is_binary(name) and is_integer(size) and size > 0 and size <= @max_card_image_bytes do
    trimmed = String.trim(name)
    trimmed != "" and String.downcase(Path.extname(trimmed)) in @image_extensions
  end

  defp eligible_card_image?(_), do: false

  defp stage_card_image(agent_id, scope, station_id, thread, ref, seq, %{
         "name" => name,
         "size" => size
       }) do
    digest =
      :crypto.hash(:sha256, "#{ref}:#{seq}:#{name}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    path = "/uploads/stillfail/#{digest}/#{safe_upload_name(name)}"
    state = SalixStore.Blob.put_stream_init(agent_id)

    with {:ok, state} <-
           pull_station_file(scope, station_id, thread, seq, name, size, 0, 0, state),
         {:ok, blob_ref} <- SalixStore.Blob.put_stream_finish(state),
         {:ok, _entry} <- SalixIM.Ports.AgentWorkspace.put_ref(agent_id, path, blob_ref) do
      wire_ref = Map.new(blob_ref, fn {k, v} -> {to_string(k), v} end)
      {:ok, %{"type" => "file", "path" => path, "file_name" => name, "blob_ref" => wire_ref}}
    else
      {:error, _reason, state} ->
        SalixStore.Blob.put_stream_abort(state)
        :error

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp pull_station_file(_scope, _station_id, _thread, _seq, _name, size, offset, _chunks, state)
       when offset >= size,
       do: {:ok, state}

  defp pull_station_file(
         _scope,
         _station_id,
         _thread,
         _seq,
         _name,
         _size,
         _offset,
         chunks,
         state
       )
       when chunks >= @max_image_chunks,
       do: {:error, :too_many_chunks, state}

  defp pull_station_file(scope, station_id, thread, seq, name, size, offset, chunks, state) do
    with {:ok, %{"data" => data} = resp} when is_binary(data) <-
           StationHostedTasks.read_file(scope, station_id, thread, seq, name, offset),
         expected_size =
           if(
             is_integer(resp["size"]) and resp["size"] > 0 and
               resp["size"] <= @max_card_image_bytes,
             do: resp["size"],
             else: size
           ),
         {:ok, part} when byte_size(part) > 0 and offset + byte_size(part) <= expected_size <-
           Base.decode64(data),
         {:ok, state} <- SalixStore.Blob.put_stream_step(state, part) do
      pull_station_file(
        scope,
        station_id,
        thread,
        seq,
        name,
        expected_size,
        offset + byte_size(part),
        chunks + 1,
        state
      )
    else
      {:error, reason, state} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
      _ -> {:error, :invalid_file_chunk, state}
    end
  end

  defp safe_upload_name(name) do
    base = Path.basename(name)
    cleaned = Regex.replace(~r/[^A-Za-z0-9._-]/, base, "_") |> String.trim_leading(".")
    if cleaned == "", do: "image.png", else: String.slice(cleaned, 0, 120)
  end
end
