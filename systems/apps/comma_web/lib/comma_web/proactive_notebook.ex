defmodule CommaWeb.ProactiveNotebook do
  @moduledoc """
  The owner's proactive notebook: one Markdown file in the Router's VFS,
  `/Comma/Notebook.md`, that shows what Comma follows for them, what it
  decided and why, and what it watches. The owner reads it in Drive's System
  Files (`Comma.SystemFiles`), read-only; it needs no device. It is a
  projection. The Home Conversation's matters, the member source pool and the
  owner's watch Loops stay the only state; a lost or edited file is replaced
  by the next render.

  The server renders the file from those facts. No model writes it, so it
  cannot invent or drop a matter.

  Every member's Router turn can read the Router's VFS. The notebook holds the
  owner's private source titles, so it is written only while the owner is the
  Workspace's only member. Otherwise the render deletes it.

  Matter changes, source collections and proactive checks queue one render.
  Renders for an owner are at most one per minute, and a render that produces
  the stored content writes nothing.
  """
  use Oban.Worker, queue: :comma_external, max_attempts: 3

  require Logger
  alias CommaWeb.{HomeMail, Proactive, ProactiveWatch}
  alias SalixAgent.AgentWorkspace
  alias SalixIM.{Conversations, MailInteraction}

  @path "/Comma/Notebook.md"
  @delay_s 30

  # Bounds of each section; the notebook is a summary, not an archive.
  @section_limit 12
  @judged_limit 24
  @recent_ms 7 * 24 * 60 * 60 * 1000
  @needs_you_ms 3 * 24 * 60 * 60 * 1000
  @threads_shown 5
  @context_bytes 10_000

  @doc "Queues one render for the owner. Renders queued within a minute merge."
  def enqueue(group, owner) when is_binary(group) and is_binary(owner) do
    case %{"group_id" => group, "owner_id" => owner}
         # A waiting render absorbs later changes; a running one renders what
         # it read, so a change made meanwhile queues the next render.
         |> new(
           schedule_in: @delay_s,
           unique: [period: 60, fields: [:worker, :args], states: [:available, :scheduled]]
         )
         |> then(&Oban.insert(Comma.Oban, &1)) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("proactive_notebook enqueue failed reason=#{inspect(reason, limit: 3)}")
        :ok
    end
  end

  def enqueue(_group, _owner), do: :ok

  @doc "The notebook path when the Router's VFS holds it, for `proactive.state`."
  def locate(ctx) do
    case AgentWorkspace.entry(ctx.agent_id, @path) do
      {:ok, _entry} -> @path
      _ -> nil
    end
  end

  @doc """
  The notebook as the proactive screening reads it: the stored file without
  what Comma did not interrupt the owner about and what is done, cut at a line
  end within #{@context_bytes} bytes. `nil` when there is no notebook, and
  while the owner is not the Workspace's only member, even before the next
  render deletes the file.
  """
  def context(workspace, owner, agent_id) do
    case private?(workspace, owner) && AgentWorkspace.read(agent_id, @path) do
      {:ok, body} when body != "" ->
        skipped =
          for locale <- ["zh-CN", "en"], t = text(locale), h <- [t.quiet, t.done], do: "## " <> h

        body
        |> String.split(~r/\n(?=## )/)
        |> Enum.reject(&(hd(String.split(&1, "\n", parts: 2)) in skipped))
        |> Enum.join("\n")
        |> cut(@context_bytes)

      _ ->
        nil
    end
  end

  defp cut(text, limit) when byte_size(text) <= limit, do: text

  defp cut(text, limit) do
    head = binary_part(text, 0, limit)

    case :binary.matches(head, "\n") do
      [] -> ""
      ends -> binary_part(head, 0, elem(List.last(ends), 0))
    end
  end

  @doc """
  The judged pool items that are the owner's next actions (`next_actions`)
  and that wait on someone else (`waiting`), as the notebook lists them, for
  `proactive.state`, while the owner is the Workspace's only member. Each
  names its title, link, level, outcome and, while deferred, the reason and
  the time it is judged again. `open_threads` lists what the owner left open
  in their own messages, every open one, with the ID `proactive.thread`
  takes (`open_thread_rows/1`).
  """
  def pool_lists(workspace, owner) do
    # Like the notebook, private source titles only while the owner is the
    # Workspace's only member.
    {judged, threads} =
      case private?(workspace, owner) && profile(workspace, owner) do
        %{id: id} ->
          {Comma.MemberSourceItems.judged(id, @judged_limit), Comma.OpenThreads.list(id)}

        _ ->
          {[], []}
      end

    row = fn item ->
      Map.merge(
        %{"title" => item.title, "url" => item.url},
        Map.take(item.attention, ~w(urgency outcome reason next_at role))
      )
    end

    %{
      "next_actions" =>
        judged |> Enum.filter(&next_action?/1) |> Enum.take(@section_limit) |> Enum.map(row),
      "waiting" =>
        judged
        |> Enum.filter(&(&1.attention["outcome"] == "waiting"))
        |> Enum.take(@section_limit)
        |> Enum.map(row),
      "open_threads" => open_thread_rows(threads)
    }
  end

  @doc """
  The owner's threads as `proactive.state` lists them: every open one, which
  the notebook promises Comma can show (`Comma.OpenThreads` keeps at most 40),
  then the latest resolved ones.
  """
  def open_thread_rows(threads) do
    {open, rest} = Enum.split_with(threads, &(&1.status == "open"))
    resolved = rest |> Enum.filter(&(&1.status == "resolved")) |> Enum.take(@section_limit)

    Enum.map(
      open ++ resolved,
      &%{
        "id" => &1.id,
        "kind" => &1.kind,
        "status" => &1.status,
        "summary" => &1.summary,
        "url" => &1.url,
        "due_on" => &1.due_on && Date.to_iso8601(&1.due_on)
      }
    )
  end

  @impl Oban.Worker
  def timeout(_job), do: 60_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"group_id" => group, "owner_id" => owner}}) do
    # Every line of this job names whose notebook it is.
    Logger.metadata(user_id: owner, group_id: group)

    with {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(owner),
         {:ok, workspace, ctx, home} <- HomeMail.context(user, %{}, group),
         true <- workspace["owner_user_id"] == owner do
      Logger.metadata(workspace_id: workspace["id"])

      result =
        if private?(workspace, owner),
          do: publish(workspace, ctx, home, owner),
          else: withdraw(ctx)

      case result do
        {:ok, outcome} ->
          Logger.info("proactive_notebook outcome=#{outcome}")
          :ok

        # A transport failure retries; the next change renders again anyway.
        {:error, {:retryable, _}} = error ->
          Logger.warning("proactive_notebook failed reason=retryable")
          error

        # A refused write (credits, a gone Router) waits for the next render.
        {:error, reason} ->
          Logger.info("proactive_notebook skipped reason=#{inspect(reason, limit: 3)}")
          :ok
      end
    else
      # The owner left or the workspace is gone: nothing to render.
      _ -> :ok
    end
  end

  defp private?(workspace, owner),
    do: Enum.map(workspace["members"] || [], & &1["user_id"]) == [owner]

  defp withdraw(ctx) do
    case AgentWorkspace.entry(ctx.agent_id, @path) do
      {:ok, _entry} ->
        with {:ok, _} <- SalixAgent.Workspace.delete(ctx.agent_id, @path, storage(ctx)),
             do: {:ok, :withdrawn}

      {:error, :not_found} ->
        {:ok, :absent}

      error ->
        error
    end
  end

  defp publish(workspace, ctx, home, owner) do
    with {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home),
         {:ok, monitors} <- ProactiveWatch.status(ctx) do
      # The Home Conversation records spends and changes on this clock.
      now = SystemsClock.system_time(:millisecond)
      profile = profile(workspace, owner)

      facts = %{
        now: now,
        locale: Comma.Accounts.locale(owner),
        timezone: (profile && profile.timezone) || "Etc/UTC",
        automatic: MailInteraction.enabled?(conversation, owner),
        notifications: MailInteraction.notification_budget(conversation, owner, now),
        urgent: MailInteraction.notification_budget(conversation, owner, now, true),
        matters:
          MailInteraction.entries(conversation)
          |> Map.values()
          |> Enum.filter(&(&1["owner_id"] == owner)),
        monitors: monitors,
        sources: if(profile, do: Comma.MemberSourceItems.states(profile.id), else: []),
        judged:
          if(profile, do: Comma.MemberSourceItems.judged(profile.id, @judged_limit), else: []),
        briefing: briefing(workspace, owner, conversation),
        portrait: CommaWeb.MemberPortrait.statements(workspace),
        open_threads: if(profile, do: Comma.OpenThreads.list(profile.id), else: [])
      }

      body = render(facts)
      store(ctx, body)
    end
  end

  # The items of the owner's latest published Routine briefing, each with the
  # Home matter that follows it, if any. Routine and proactive attention share
  # these matter keys (`CommaWeb.ProactiveRoutine.reference/6`).
  defp briefing(workspace, owner, conversation) do
    # The published snapshot stays the briefing while a run refreshes or after
    # a failed run.
    with {:ok, %{"snapshot" => snapshot}} when is_map(snapshot) <-
           Comma.Recommendations.read_existing(%{"id" => owner}, %{}, workspace["id"]) do
      entries = MailInteraction.entries(conversation)

      %{
        generated_at: snapshot["generatedAt"],
        items:
          snapshot
          |> CommaWeb.ProactiveRoutine.items()
          |> Enum.map(fn item ->
            matter = entries[MailInteraction.key(item["source_id"], item["source_ref"])]

            %{
              "title" => item["title"],
              "url" => item["url"],
              "matter" => if(is_map(matter) and matter["owner_id"] == owner, do: matter)
            }
          end)
      }
    else
      _ -> nil
    end
  end

  defp profile(workspace, owner) do
    case Comma.Recommendations.get_runtime_profile(workspace["id"], owner) do
      {:ok, profile} -> profile
      _ -> nil
    end
  end

  # A render equal to the stored file writes nothing, so collections that
  # change nothing leave no new version. The manifest names a blob by the
  # SHA-256 of its bytes (`SalixStore.Blob`).
  defp store(ctx, body) do
    hash = SalixStore.Crypto.hex(body)

    case AgentWorkspace.entry(ctx.agent_id, @path) do
      {:ok, %{"hash" => ^hash}} ->
        {:ok, :unchanged}

      {:ok, _other} ->
        write(ctx, body)

      {:error, :not_found} ->
        write(ctx, body)

      error ->
        error
    end
  end

  defp write(ctx, body) do
    with {:ok, _} <- SalixAgent.Workspace.write(ctx.agent_id, @path, body, storage(ctx)),
         do: {:ok, :written}
  end

  # Billed to the Home Conversation's account, as Comma's own write.
  defp storage(ctx),
    do: [billing_context: ctx.billing_context, entrypoint: "comma_notebook", actor_type: "system"]

  @doc """
  Renders the notebook. `facts` holds `:now`, `:locale`, `:timezone`,
  `:automatic`, `:notifications` and `:urgent` (notification budget tuples
  for ordinary and critical matters), the owner's `:matters`,
  watch `:monitors`, pool source `:sources`, `:judged` pool items and the
  latest Routine `:briefing` (`nil`, or its `:generated_at` and `:items`),
  the Condensed Workspace statements (`:portrait`), of which it lists the
  portrait (`CommaWeb.MemberPortrait`), and the owner's `:open_threads`
  (`Comma.OpenThreads`), of which it lists the open ones.
  """
  def render(facts) do
    t = text(facts.locale)
    # The briefing handoff has its own section, built from Routine.
    matters =
      facts.matters
      |> Enum.reject(&(&1["account_id"] == "routine" and &1["thread_id"] == "briefing"))
      |> Enum.map(&Map.put(&1, "section", place(&1, facts.now)))

    [
      "# " <> t.title,
      "",
      "> " <> t.intro,
      "",
      status_line(facts, t),
      section(t.today, rows(matters, "today", facts, t), t.empty_today),
      section(briefing_heading(facts, t), briefing_rows(facts, t), nil),
      section(t.later, rows(matters, "later", facts, t) ++ next_actions(facts, t), nil),
      section(t.waiting, rows(matters, "waiting", facts, t) ++ others_move(facts, t), nil),
      section(t.open_threads, open_threads(facts, t), nil),
      section(t.watching, watching(facts, t), t.empty_watching),
      section(t.portrait, portrait(facts), nil),
      section(t.quiet, rows(matters, "quiet", facts, t) ++ judged(facts, t), nil),
      section(t.done, rows(matters, "done", facts, t), nil)
    ]
    |> List.flatten()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # What Comma knows about the owner: the portrait statements of the
  # Condensed Workspace, where the owner edits them.
  defp portrait(facts) do
    for %{"text" => text} <- Map.get(facts, :portrait) || [],
        String.starts_with?(text, ["About you · ", "关于你 · "]),
        do: "- " <> text
  end

  # What the owner left open in their own messages, at most five by
  # priority: a due date first (soonest first), then what the owner promised
  # someone, then the newest. The rest are counted.
  defp open_threads(facts, t) do
    {shown, rest} =
      (Map.get(facts, :open_threads) || [])
      |> Enum.filter(&(&1.status == "open"))
      |> Enum.sort_by(
        &{is_nil(&1.due_on), &1.due_on && Date.to_iso8601(&1.due_on), &1.kind != "promised",
         -DateTime.to_unix(&1.evidence_at)}
      )
      |> Enum.split(@threads_shown)

    rows =
      Enum.map(shown, fn thread ->
        parts =
          [
            t.thread_kind.(thread.kind),
            clean(thread.counterpart) && t.thread_counterpart.(clean(thread.counterpart)),
            thread.due_on && t.thread_due.(Calendar.strftime(thread.due_on, "%m-%d"))
          ]
          |> Enum.filter(&is_binary/1)

        "- " <> link(thread.summary, thread.url) <> " — " <> Enum.join(parts, t.separator)
      end)

    case length(rest) do
      0 -> rows
      more -> rows ++ ["- " <> t.thread_more.(more)]
    end
  end

  defp section(_heading, [], nil), do: []
  defp section(heading, [], empty), do: ["", "## " <> heading, "", "_" <> empty <> "_"]
  defp section(heading, rows, _empty), do: ["", "## " <> heading, "" | rows]

  defp status_line(facts, t) do
    budget =
      case {facts.notifications, facts.urgent} do
        {{:open, remaining}, _} -> t.budget_open.(remaining)
        {{:closed, at}, {:open, _}} -> t.budget_urgent.(time(at, facts))
        {{:closed, _}, {:closed, at}} -> t.budget_closed.(time(at, facts))
      end

    if facts.automatic, do: t.automatic_on <> " " <> budget, else: t.automatic_off
  end

  # Where one matter belongs. A matter the Router told the owner about, or a
  # reminder the owner asked for that came due, needs them until it is handled.
  defp place(%{"state" => "handled"} = matter, now),
    do: if(recent?(matter, now), do: "done")

  defp place(%{"state" => "quiet"} = matter, now),
    do: if(recent?(matter, now), do: "quiet")

  defp place(%{"state" => "snoozed"}, _now), do: "later"
  defp place(%{"state" => "failed"}, _now), do: "waiting"
  defp place(%{"task_id" => task}, _now) when is_binary(task), do: "waiting"

  # A matter stays in "needs you" for a few days, then waits with the rest.
  defp place(matter, now) do
    fresh = is_integer(matter["changed_at"]) and now - matter["changed_at"] < @needs_you_ms

    cond do
      fresh and get_in(matter, ["decision", "decision"]) == "notify" ->
        "today"

      fresh and get_in(matter, ["last_command", "action"]) == "present" and
          matter["automatic"] != true ->
        "today"

      true ->
        "waiting"
    end
  end

  defp recent?(matter, now),
    do: is_integer(matter["changed_at"]) and now - matter["changed_at"] < @recent_ms

  defp rows(matters, name, facts, t) do
    matters
    |> Enum.filter(&(&1["section"] == name))
    |> Enum.sort_by(&{-(&1["changed_at"] || 0), &1["subject"] || ""})
    |> Enum.take(@section_limit)
    |> Enum.map(&("- " <> link(&1["subject"], &1["source_url"]) <> detail(&1, name, facts, t)))
  end

  defp detail(matter, name, facts, t) do
    parts =
      [
        matter["urgency"] in ~w(critical high ask) && t.urgency.(matter["urgency"]),
        name == "later" && is_integer(matter["run_at"]) &&
          t.recheck.(time(matter["run_at"], facts)),
        name == "later" && clean(matter["followup_reason"]),
        name == "waiting" && is_binary(matter["task_id"]) && t.in_task,
        name == "waiting" && matter["state"] == "failed" && t.failed,
        is_binary(get_in(matter, ["continues", "subject"])) &&
          t.continues.(clean(matter["continues"]["subject"])),
        decision(matter, facts, t)
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    if parts == [], do: "", else: " — " <> Enum.join(parts, t.separator)
  end

  defp decision(%{"decision" => %{"decision" => choice} = decision}, facts, t) do
    reason = clean(decision["reason"])
    at = if is_integer(decision["decided_at"]), do: time(decision["decided_at"], facts)
    label = if choice == "notify", do: t.notified.(at), else: t.stayed_quiet.(at)
    if reason in [nil, ""], do: label, else: label <> t.colon <> reason
  end

  defp decision(_matter, _facts, _t), do: nil

  defp watching(facts, t) do
    watches =
      Enum.map(facts.monitors, fn row ->
        state =
          case row["status"] do
            "active" -> t.watch_active
            "paused" -> t.watch_paused
            _ -> t.watch_stopped
          end

        "- " <> t.watch <> t.colon <> (clean(row["name"]) || t.untitled) <> " — " <> state
      end)

    sources =
      Enum.map(facts.sources, fn state ->
        name = if state.app in [nil, ""], do: state.toolkit, else: state.app

        status =
          cond do
            failed_latest?(state) -> t.source_failed
            is_nil(state.collected_at) -> t.source_waiting
            true -> t.source_read.(hour(state.collected_at, facts))
          end

        "- " <> t.source <> t.colon <> (clean(name) || t.untitled) <> " — " <> status
      end)

    watches ++ sources
  end

  # A partial read keeps its warning with a successful collection time. Only
  # an attempt newer than the last success failed as a whole.
  defp failed_latest?(%{failure: nil}), do: false

  defp failed_latest?(state),
    do:
      is_nil(state.collected_at) or
        DateTime.compare(state.attempted_at, state.collected_at) == :gt

  defp briefing_heading(%{briefing: %{generated_at: at}} = facts, t) when is_integer(at),
    do: t.briefing <> " (" <> time(at, facts) <> ")"

  defp briefing_heading(_facts, t), do: t.briefing

  # Today's Routine items, with what happened to each since.
  defp briefing_rows(%{briefing: %{items: items}} = facts, t) do
    items
    |> Enum.take(@section_limit)
    |> Enum.map(fn item ->
      status =
        case item["matter"] do
          %{"state" => "handled"} ->
            t.briefing_handled

          %{"state" => "snoozed", "run_at" => at} when is_integer(at) ->
            t.recheck.(time(at, facts))

          %{"decision" => %{"decision" => "notify"}} ->
            t.briefing_notified

          _ ->
            nil
        end

      "- " <> link(item["title"], item["url"]) <> if(status, do: " — " <> status, else: "")
    end)
  end

  defp briefing_rows(_facts, _t), do: []

  defp briefing_urls(%{briefing: %{items: items}}),
    do: items |> Enum.map(& &1["url"]) |> Enum.filter(&is_binary/1) |> MapSet.new()

  defp briefing_urls(_facts), do: MapSet.new()

  # Pool items that are the owner's move but did not interrupt them: what
  # comes up next, and why a deferred one waits and until when.
  defp next_actions(facts, t) do
    facts.judged
    |> Enum.filter(&next_action?/1)
    |> Enum.take(@section_limit)
    |> Enum.map(fn item ->
      attention = item.attention

      parts =
        [
          attention["urgency"] in ~w(critical high) && t.urgency.(attention["urgency"]),
          attention["outcome"] == "deferred" && is_integer(attention["next_at"]) &&
            t.deferred.(
              t.deferred_reason.(attention["reason"]),
              time(attention["next_at"], facts)
            )
        ]
        |> Enum.filter(&is_binary/1)

      "- " <>
        link(item.title, item.url) <>
        if(parts == [], do: "", else: " — " <> Enum.join(parts, t.separator))
    end)
  end

  defp next_action?(%{attention: %{"role" => "act", "outcome" => outcome} = attention}),
    do:
      outcome in ~w(quiet deferred) and
        get_in(attention, ["assessment", "link"]) not in ~w(subscribed none)

  defp next_action?(_item), do: false

  # Pool items whose next move belongs to someone else.
  defp others_move(facts, t) do
    for %{attention: %{"outcome" => "waiting"}} = item <- facts.judged do
      "- " <> link(item.title, item.url) <> " — " <> t.others_move
    end
    |> Enum.take(@section_limit)
  end

  # Pool items the check judged but did not hand over: why they stayed quiet.
  defp judged(facts, t) do
    in_briefing = briefing_urls(facts)

    facts.judged
    |> Enum.reject(&next_action?/1)
    |> Enum.filter(
      &(&1.attention["outcome"] in ~w(quiet resolved off invalid duplicate) or
          &1.attention["isolated"] == true)
    )
    |> Enum.map(fn item ->
      # The briefing is where quiet items go; say whether this one is there.
      reason =
        if MapSet.member?(in_briefing, item.url),
          do: t.judged_in_briefing,
          else: judged_reason(item, t)

      at = if is_integer(item.attention["at"]), do: time(item.attention["at"], facts)

      "- " <>
        link(item.title, item.url) <> " — " <> reason <> if(at, do: " (" <> at <> ")", else: "")
    end)
  end

  defp judged_reason(item, t) do
    case item.attention do
      %{"outcome" => "off"} -> t.judged_off
      %{"outcome" => "invalid"} -> t.judged_invalid
      %{"outcome" => "duplicate"} -> t.judged_duplicate
      %{"isolated" => true} -> t.judged_isolated
      %{"outcome" => "resolved"} -> t.judged_resolved
      %{"role" => "reference"} -> t.judged_reference
      %{"urgency" => urgency} when is_binary(urgency) -> t.judged_below.(urgency)
      _ -> t.judged_quiet
    end
  end

  defp link(title, url), do: Proactive.link(title, url)

  defp clean(text) when is_binary(text) do
    text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 200)
  end

  defp clean(_), do: nil

  defp time(ms, facts) do
    ms |> DateTime.from_unix!(:millisecond) |> local(facts) |> Calendar.strftime("%m-%d %H:%M")
  end

  # Source reads show the hour only, so each collection does not rewrite the file.
  defp hour(%DateTime{} = at, facts),
    do: at |> local(facts) |> Calendar.strftime("%m-%d %H:00")

  defp local(at, facts) do
    case DateTime.shift_zone(at, facts.timezone) do
      {:ok, shifted} -> shifted
      _ -> at
    end
  end

  defp text("zh-CN") do
    %{
      title: "Comma 记事本",
      intro: "Comma 会自动更新这页：它在跟进什么、做了什么决定、为什么没打扰你。这里的修改会被覆盖；想调整请直接在聊天里告诉 Comma。",
      automatic_on: "自动提醒已开启。",
      automatic_off: "自动提醒已关闭。Comma 不会检查新到的消息，你让它盯着的事情照常跟进。",
      budget_open: &"今天还能主动提醒你 #{&1} 次。",
      budget_urgent: &"#{&1} 之前只会为紧急的事提醒你。",
      budget_closed: &"今天的主动提醒额度已用完，#{&1} 恢复。",
      today: "今天先确认",
      empty_today: "现在没有需要你处理的事。",
      later: "接下来",
      waiting: "等待与跟进中",
      watching: "我在盯着",
      portrait: "我对你的了解（存在精简工作区里，说错了请告诉我）",
      open_threads: "你可能还没结的事（从你在 Slack 的发言里找的；已经结了或不归你，告诉我一声）",
      thread_kind: &%{"promised" => "你答应的", "asked" => "你问了还没人回", "blocked" => "你提过的问题"}[&1],
      thread_counterpart: &"对方：#{&1}",
      thread_due: &"#{&1} 前",
      thread_more: &"还有 #{&1} 件没列出，问 Comma 可以看全部",
      empty_watching: "还没有连接的来源或盯着的事项。",
      quiet: "没打扰你的",
      done: "最近完成",
      urgency: &%{"critical" => "紧急", "high" => "重要", "ask" => "问你是否归你"}[&1],
      recheck: &"#{&1} 再看",
      in_task: "已在 Task 中处理",
      failed: "上次处理失败",
      notified: &if(&1, do: "#{&1} 已提醒你", else: "已提醒你"),
      continues: &"接续：#{&1}",
      stayed_quiet: &if(&1, do: "#{&1} 决定不打扰", else: "决定不打扰"),
      watch: "盯着",
      watch_active: "进行中",
      watch_paused: "已暂停",
      watch_stopped: "已停止",
      untitled: "未命名",
      source: "来源",
      source_read: &"上次读取约 #{&1}",
      source_failed: "上次读取失败",
      source_waiting: "等待第一次读取",
      judged_off: "当时自动提醒已关闭",
      judged_below:
        &"判断为#{%{"critical" => "紧急", "high" => "重要", "normal" => "一般", "low" => "低"}[&1] || &1}，留给每日简报",
      judged_quiet: "不需要你处理，留给每日简报",
      judged_resolved: "来源显示已经解决或你已回复",
      judged_in_briefing: "在最新简报里",
      briefing: "最新简报",
      briefing_handled: "已处理",
      briefing_notified: "已提醒你",
      judged_invalid: "这次没能判断，留给每日简报",
      judged_duplicate: "和已跟进的事项相同，没有新进展",
      judged_isolated: "模型暂时判断不了这一条，稍后会再试",
      judged_reference: "只是信息或别人的事，不需要你处理",
      others_move: "等对方处理，阻塞到你时再找你",
      deferred: &"#{&1}，#{&2} 再看",
      deferred_reason:
        &(%{
            "notification_budget" => "今天的提醒额度暂满",
            "handoff_budget" => "今天的自动检查额度暂满",
            "budgets" => "今天的提醒额度暂满"
          }[&1] || "暂缓"),
      separator: "；",
      colon: "："
    }
  end

  defp text(_locale) do
    %{
      title: "Comma notebook",
      intro:
        "Comma keeps this page up to date: what it follows for you, what it decided, and why it did not interrupt you. Edits here are replaced; tell Comma in chat instead.",
      automatic_on: "Automatic messages are on.",
      automatic_off:
        "Automatic messages are off. Comma does not check new arrivals; matters you asked it to follow continue.",
      budget_open: &"#{&1} more automatic messages today.",
      budget_urgent: &"Until #{&1}, only urgent matters can interrupt you.",
      budget_closed: &"No automatic messages until #{&1}.",
      today: "Needs you",
      empty_today: "Nothing needs you right now.",
      later: "Coming up",
      waiting: "Waiting and in progress",
      watching: "Watching",
      portrait:
        "What I know about you (kept in the Condensed Workspace; tell me if something is wrong)",
      open_threads:
        "What you may have left open (from your own Slack messages; tell me when one is done or not yours)",
      thread_kind:
        &%{
          "promised" => "you promised",
          "asked" => "you asked, no answer yet",
          "blocked" => "a problem you raised"
        }[&1],
      thread_counterpart: &"with #{&1}",
      thread_due: &"by #{&1}",
      thread_more: &"#{&1} more not listed; ask Comma to see them all",
      empty_watching: "No connected sources or watches yet.",
      quiet: "Did not interrupt you",
      done: "Recently done",
      urgency:
        &%{"critical" => "urgent", "high" => "important", "ask" => "asked if it is yours"}[&1],
      recheck: &"checking again #{&1}",
      in_task: "in a Task",
      failed: "the last action failed",
      notified: &if(&1, do: "told you at #{&1}", else: "told you"),
      continues: &"continues: #{&1}",
      stayed_quiet: &if(&1, do: "stayed quiet at #{&1}", else: "stayed quiet"),
      watch: "Watch",
      watch_active: "active",
      watch_paused: "paused",
      watch_stopped: "stopped",
      untitled: "untitled",
      source: "Source",
      source_read: &"last read around #{&1}",
      source_failed: "the last read failed",
      source_waiting: "waiting for its first read",
      judged_off: "automatic messages were off",
      judged_below: &"rated #{&1}, left for the daily briefing",
      judged_quiet: "nothing for you to do, left for the daily briefing",
      judged_resolved: "the source shows it resolved or answered",
      judged_in_briefing: "in the latest briefing",
      briefing: "Latest briefing",
      briefing_handled: "handled",
      briefing_notified: "told you",
      judged_invalid: "could not be judged this time, left for the daily briefing",
      judged_duplicate: "same as a matter Comma already follows, nothing new",
      judged_isolated: "the model could not judge this one yet; Comma tries again later",
      judged_reference: "information or someone else's work, nothing for you to do",
      others_move: "waiting on someone else; Comma tells you when it blocks on you",
      deferred: &"#{&1}, checking again #{&2}",
      deferred_reason:
        &(%{
            "notification_budget" => "no automatic messages left for now",
            "handoff_budget" => "no automatic checks left for now",
            "budgets" => "no automatic messages left for now"
          }[&1] || "waiting"),
      separator: "; ",
      colon: ": "
    }
  end
end
