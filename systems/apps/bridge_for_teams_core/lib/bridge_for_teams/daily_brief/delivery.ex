defmodule BridgeForTeams.DailyBrief.Delivery do
  @moduledoc """
  Writes and sends the daily briefs.

  A member is due once a workday in the member's time zone, after
  `deliver_at`, and once more for each admin request; a request does not move
  the next scheduled brief. Workdays are Monday to Friday, except the
  organization's days off, plus its make-up workdays (`workday?/2`). The
  first brief after days off covers them, up to 12 days back.

  Once a day the team brief is written from the shared stream (the first due
  member, or the team brief's own time, writes it). Each member's brief then
  reads the member's messages of their window (since their last brief, up to
  10 minutes ago), and the model writes it from them, the team brief, and the
  member's last brief (`Compose`); the Swarm's bot posts it, in Slack, Feishu,
  or Lark by the settings' provider (`Sources`). A brief waits as a
  `pending` run until the provider takes it, so a failed send is sent again
  without another model run. The team brief is posted to the team's channel
  (a Slack channel or a Feishu/Lark group) at its own time. Only members of
  the settings' provider are due.
  """

  import Ecto.Query

  require Logger

  alias BridgeForTeams.Repo

  alias BridgeForTeams.DailyBrief.{
    Compose,
    DirectMessages,
    Members,
    RunLease,
    Scope,
    SharedSource,
    Sources
  }

  alias BridgeForTeams.Salix.Client, as: Salix

  alias BridgeForTeams.Schema.{
    DailyBriefMember,
    DailyBriefRun,
    DailyBriefSetting,
    Organization,
    User
  }

  @shared_interval_seconds 20 * 3600
  @default_window_seconds 86_400
  # A brief after days off still reads back to the last one.
  @max_window_days 12
  # What a brief closed stays known this long, at most this many.
  @closed_days 7
  # A follow-up with no news this long leaves the list.
  @stale_days 7
  @max_closed 40
  @settle_seconds 10 * 60
  # A team brief that failed is tried again by a later brief after this long.
  @team_retry_seconds 3600

  @doc """
  Claims members whose brief time this workday has passed and who have no
  brief today, and members an admin asked a brief for.
  """
  @spec claim_due(DateTime.t(), pos_integer()) :: [{DailyBriefSetting.t(), DailyBriefMember.t()}]
  def claim_due(now, limit) do
    {:ok, claimed} =
      Repo.transaction(fn ->
        candidates =
          Repo.all(
            from(m in DailyBriefMember,
              join: s in DailyBriefSetting,
              # The Swarm that sends the member's brief; a member linked
              # before Swarms had their own settings, the organization's
              # first enabled one of the provider. One row per member.
              on:
                s.org_id == m.org_id and s.provider == m.provider and
                  ((not is_nil(m.project_id) and s.project_id == m.project_id) or
                     (is_nil(m.project_id) and
                        s.id ==
                          fragment(
                            "(SELECT x.id FROM daily_brief_settings x WHERE x.org_id = ? AND x.provider = ? AND x.enabled ORDER BY x.created_at, x.id LIMIT 1)",
                            m.org_id,
                            m.provider
                          ))),
              where:
                s.enabled and m.enabled and
                  (is_nil(m.brief_claimed_at) or not is_nil(m.brief_requested_at) or
                     m.brief_claimed_at < ^DateTime.add(now, -@shared_interval_seconds)),
              # Requests first, so members not yet due cannot hold them back.
              order_by: [
                asc_nulls_last: m.brief_requested_at,
                asc_nulls_first: m.brief_claimed_at,
                asc: m.id
              ],
              limit: ^(limit * 10),
              lock: "FOR UPDATE OF d0 SKIP LOCKED",
              select: {s, m}
            )
          )

        due =
          candidates
          |> Enum.filter(fn {settings, member} -> due?(settings, member, now) end)
          |> Enum.take(limit)

        {scheduled, requested} =
          Enum.split_with(due, fn {settings, member} -> scheduled?(settings, member, now) end)

        # Only a scheduled brief counts as today's; a request alone keeps the
        # member's time for the next one.
        Repo.update_all(from(m in DailyBriefMember, where: m.id in ^ids(scheduled)),
          set: [brief_claimed_at: now, brief_requested_at: nil]
        )

        Repo.update_all(from(m in DailyBriefMember, where: m.id in ^ids(requested)),
          set: [brief_requested_at: nil]
        )

        due
      end)

    claimed
  end

  defp ids(claimed), do: Enum.map(claimed, fn {_settings, member} -> member.id end)

  @doc "Whether an admin asked for the member's brief, or its time this workday has passed unsent."
  def due?(settings, %DailyBriefMember{brief_requested_at: %DateTime{} = at} = member, now),
    do: DateTime.compare(at, now) != :gt or scheduled?(settings, member, now)

  def due?(settings, %DailyBriefMember{} = member, now), do: scheduled?(settings, member, now)

  @doc "Whether `day` is a workday of the organization's calendar."
  @spec workday?(DailyBriefSetting.t(), Date.t()) :: boolean()
  def workday?(%DailyBriefSetting{} = settings, %Date{} = day) do
    cond do
      day in (settings.work_days || []) -> true
      day in (settings.off_days || []) -> false
      true -> Date.day_of_week(day) in 1..5
    end
  end

  defp scheduled?(settings, %DailyBriefMember{} = member, now) do
    with {:ok, local} <- DateTime.shift_zone(now, member.timezone),
         true <- workday?(settings, DateTime.to_date(local)),
         {:ok, today_at} <-
           DateTime.new(DateTime.to_date(local), member.deliver_at, member.timezone) do
      DateTime.compare(now, today_at) != :lt and
        (is_nil(member.brief_claimed_at) or
           DateTime.compare(member.brief_claimed_at, today_at) == :lt)
    else
      _day_off_or_invalid_zone -> false
    end
  end

  @doc """
  Asks for one member's brief on the delivery worker's next tick, whether or
  not today's brief went out. A brief Slack has not taken yet is sent again.
  """
  @spec request(DailyBriefMember.t(), DateTime.t()) :: {:ok, DailyBriefMember.t()}
  def request(%DailyBriefMember{} = member, now) do
    member |> Ecto.Changeset.change(brief_requested_at: now) |> Repo.update()
  end

  @doc """
  Sends one member's brief; `claimed` is the member as `claim_due/2` gave it.
  A brief written earlier that Slack has not taken yet is sent again as it
  is; otherwise the brief is written, kept as `pending`, and sent.
  """
  @spec deliver(DailyBriefSetting.t(), DailyBriefMember.t(), keyword()) ::
          {:ok, DailyBriefRun.t()} | {:error, term()}
  def deliver(%DailyBriefSetting{} = settings, %DailyBriefMember{} = claimed, opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())

    case pending_brief(claimed, now) do
      %DailyBriefRun{} = pending -> post_brief(settings, claimed, pending, now)
      nil -> write_and_send(settings, claimed, now, opts)
    end
  end

  defp write_and_send(settings, claimed, now, opts) do
    member = DailyBriefMember |> Repo.get!(claimed.id) |> Repo.preload(:aliases)
    window = member_window(member, now)
    model_opts = Keyword.take(opts, [:model, :agent_id])
    batch_members = Keyword.get(opts, :batch_members, [member])
    scope = Keyword.get_lazy(opts, :scope, fn -> Scope.personal(settings, member) end)

    team_shared =
      case ensure_team_brief(settings, now, model_opts, nil, %{
             window: window,
             members: batch_members,
             shared: opts[:shared]
           }) do
        {:ok, _run, %{} = shared} -> shared
        _other -> nil
      end

    with {:ok, shared} <-
           shared_for_member(
             scope,
             window,
             member,
             batch_members,
             opts[:shared] || team_shared
           ),
         {shared, direct} = with_direct_messages(shared, settings, member, window),
         input = %{
           settings: settings,
           member: member,
           shared: shared,
           team_brief: latest_team_brief(settings),
           previous: last_brief_text(member),
           followups: last_mine(member, now),
           closed: last_closed(member, now),
           issues: last_issues(member),
           github: last_note(member, "github"),
           station_tasks: station_tasks(scope, member, window),
           now: now
         },
         {:ok, %{text: text, usage: usage} = written} <- Compose.write(input, model_opts),
         rendered =
           Sources.sink(settings).render_personal(
             title(member.timezone, now),
             text,
             footer(settings, member)
           ),
         coverage = personal_coverage(shared.coverage, direct, member.id),
         {:ok, pending} <-
           record_pending(
             settings,
             member,
             window,
             coverage,
             text,
             rendered,
             usage,
             stamp(written[:mine], last_brief_mine(member), local_day(now, member.timezone)),
             closed(written[:mine], last_closed(member, now), now, member.timezone),
             written[:issues],
             written[:github],
             shared[:app_id]
           ) do
      post_brief(settings, claimed, pending, now)
    else
      # A brief that cannot be written is recorded and, unless the failure
      # stays, tried again in about an hour; nothing is sent.
      failed ->
        {reason, usage} = reason_and_usage(failed)
        Logger.warning("bridge_for_teams.daily_brief.write.failed reason=#{inspect(reason)}")
        record_failed(settings, member, window, reason, usage)
        if transient?(reason), do: release_claim(settings, claimed, now)
        {:error, reason}
    end
  end

  # The member's own direct messages join their relevant messages. A failed
  # read is noted in the coverage; the brief is written without them.
  defp with_direct_messages(shared, settings, member, window) do
    case DirectMessages.read(settings, member, window) do
      {:ok, %{messages: []}} when member.dm_status != "on" ->
        {shared, "off"}

      {:ok, %{messages: messages, complete?: complete?}} ->
        # The conversation the briefs are sent in holds earlier briefs and
        # the bot's other notes; read back, they would be reported again as
        # news. Only what the member writes there stays, marked as their
        # answer to the brief.
        own = brief_channel(member)

        messages =
          for m <- messages,
              own == nil or m.channel_id != own or m.actor_id == member.slack_user_id,
              do: if(m.channel_id == own, do: %{m | kind: "brief_reply"}, else: m)

        picked = for m <- messages, do: %{message: m, reasons: [:direct], tier: :p0}

        # A shared channel the bot is not in is named by the member's read.
        names =
          for %{kind: "shared", channel_name: name} = m <- messages,
              is_binary(name),
              into: %{},
              do: {m.channel_id, name}

        shared =
          %{
            shared
            | messages: shared.messages ++ messages,
              relevant: Map.update(shared.relevant, member.id, picked, &(&1 ++ picked))
          }
          |> name_channels(names)

        {shared, if(complete?, do: "read", else: "partial")}

      {:error, reason} ->
        Logger.warning(
          "bridge_for_teams.daily_brief.direct_messages.failed reason=#{inspect(reason)}"
        )

        {shared, "failed"}
    end
  end

  defp name_channels(%{channel_names: known} = shared, names) when is_map(known),
    do: %{shared | channel_names: Map.merge(names, known)}

  defp name_channels(shared, _names), do: shared

  @max_station_tasks 20
  @station_recent_ms 7 * 24 * 60 * 60 * 1_000

  # Connected still.fail workspace chats waiting on the member (`need` / `failed`)
  # or finished for them inside the brief window (`done`). Best effort: unavailable
  # RPC or unconnected stations leave the brief untouched.
  # Every Swarm the brief reads (`scope`), each task once.
  defp station_tasks(scope, member, %{after: after_at, before: before_at}) do
    salix = Salix.impl()

    with true <-
           Code.ensure_loaded?(salix) and function_exported?(salix, :daily_brief_station_tasks, 1),
         %User{email: email} when is_binary(email) and email != "" <-
           Repo.get(User, member.user_id),
         [_ | _] = rows <- scope_station_tasks(salix, scope) do
      norm = email |> String.trim() |> String.downcase()
      after_ms = DateTime.to_unix(after_at, :millisecond)
      recent_cutoff = DateTime.to_unix(before_at, :millisecond) - @station_recent_ms

      rows
      |> Enum.flat_map(&member_station_task(&1, norm, after_ms, recent_cutoff))
      |> Enum.uniq_by(&(&1["url"] || &1["title"]))
      |> Enum.sort_by(fn row ->
        rank = if row["state"] in ~w(need failed), do: 0, else: 1
        {rank, -(row["last_activity_at"] || 0)}
      end)
      |> Enum.take(@max_station_tasks)
    else
      _ -> []
    end
  end

  defp scope_station_tasks(salix, scope) do
    scope
    |> Enum.flat_map(fn settings ->
      with {:ok, %{group_id: group_id}} <- Members.source(settings),
           {:ok, rows} when is_list(rows) <- salix.daily_brief_station_tasks(group_id) do
        rows
      else
        _unavailable -> []
      end
    end)
  end

  defp member_station_task(row, email, after_ms, recent_cutoff) when is_map(row) do
    attention = row[:attention] || row["attention"]
    status = row[:status] || row["status"]
    waits_for = row[:waits_for] || row["waits_for"] || []
    created_by = row[:created_by] || row["created_by"]
    at = row[:last_activity_at] || row["last_activity_at"] || 0

    waits? =
      Enum.any?(waits_for, fn entry ->
        is_binary(entry) and String.downcase(String.trim(entry)) == email
      end)

    creator? = is_binary(created_by) and String.downcase(String.trim(created_by)) == email

    state =
      cond do
        attention in ~w(need failed) and waits? and at >= recent_cutoff ->
          attention

        attention == "done" and waits? and at >= after_ms ->
          "done"

        is_nil(attention) and status == "needs_review" and creator? and at >= recent_cutoff ->
          "need"

        true ->
          nil
      end

    if is_binary(state) do
      [
        %{
          "title" =>
            to_string(row[:title] || row["title"] || row[:thread] || row["thread"] || ""),
          "state" => state,
          "note" => row[:note] || row["note"],
          "url" => row[:url] || row["url"],
          "last_activity_at" => at
        }
        |> Map.reject(fn {_k, v} -> v in [nil, ""] end)
      ]
    else
      []
    end
  end

  defp member_station_task(_row, _email, _after_ms, _recent_cutoff), do: []

  defp personal_coverage(
         %{channels_total: total, channels_read: read} = shared_cov,
         direct,
         member_id
       ) do
    failed =
      for c <- List.wrap(shared_cov[:failed]), is_map(c), do: to_string(c[:id] || c["id"])

    truncated =
      for c <- List.wrap(shared_cov[:truncated]), is_map(c), do: to_string(c[:id] || c["id"])

    threads = get_in(shared_cov, [:threads_complete, member_id])

    %{
      "shared_complete" => SharedSource.complete?(shared_cov),
      "direct_messages" => direct,
      "channels_read" => read,
      "channels_total" => total
    }
    |> then(&if(failed != [], do: Map.put(&1, "failed_channels", failed), else: &1))
    |> then(&if(truncated != [], do: Map.put(&1, "truncated_channels", truncated), else: &1))
    |> then(&if(is_boolean(threads), do: Map.put(&1, "threads_complete", threads), else: &1))
  end

  defp personal_coverage(shared_cov, direct, _member_id) do
    %{
      "shared_complete" => SharedSource.complete?(shared_cov),
      "direct_messages" => direct
    }
  end

  # A member whose direct messages are not read is offered the switch. Only
  # Slack has one: Feishu and Lark briefs read public groups only.
  defp footer(_settings, %DailyBriefMember{dm_status: "on"}), do: nil

  defp footer(_settings, %DailyBriefMember{provider: provider})
       when provider in ["feishu", "lark"],
       do: nil

  defp footer(settings, _member) do
    with base when is_binary(base) and base != "" <-
           SystemsRuntime.get_env(:bridge_for_teams_web, :public_base_url),
         %Organization{slug: slug} when is_binary(slug) <-
           Repo.get(Organization, settings.org_id) do
      "这份简报只读了公开频道。想让它也看你的私信和群私信（只读，原文不保存）：<" <>
        String.trim_trailing(base, "/") <>
        "/orgs/#{slug}/daily-brief/direct-messages/connect|开启>"
    else
      _unavailable -> nil
    end
  end

  defp reason_and_usage({:error, reason, usage}), do: {reason, usage}
  defp reason_and_usage({:error, reason}), do: {reason, nil}

  @doc "Where a window read now may end: late mirror writes settle first."
  @spec settled(DateTime.t()) :: DateTime.t()
  def settled(now), do: DateTime.add(now, -@settle_seconds)

  @doc false
  def member_window(member, now) do
    after_at = window_start(member, now)
    %{after: after_at, before: Enum.max([settled(now), after_at], DateTime)}
  end

  # A read made for the batch or the team brief serves the member when it
  # read the same Swarms (`scope`) over the same window.
  defp shared_for_member(
         scope,
         window,
         member,
         _batch_members,
         %{window: window, relevant: relevant} = shared
       )
       when is_map_key(relevant, member.id) do
    if Map.get(shared, :scope, [hd(scope).id]) == Scope.key(scope),
      do: {:ok, shared},
      else: shared_for_member(scope, window, member, [member], nil)
  end

  defp shared_for_member(scope, window, member, batch_members, _cached) do
    members =
      if Enum.any?(batch_members, &(&1.id == member.id)),
        do: batch_members,
        else: [member | batch_members]

    with {:ok, shared} <- SharedSource.read(scope, window, members: members) do
      {:ok, Map.put(shared, :scope, Scope.key(scope))}
    end
  end

  defp title(zone, now), do: "每日简报 · " <> date_label(now, zone)

  # A pending brief from an earlier day is stale: the next brief replaces it.
  defp pending_brief(member, now) do
    cutoff = DateTime.add(now, -@shared_interval_seconds)

    case Repo.one(
           from(r in DailyBriefRun,
             where:
               r.member_id == ^member.id and r.kind == "personal_brief" and
                 r.status == "pending"
           )
         ) do
      nil ->
        nil

      %DailyBriefRun{window_before: before} = run ->
        if DateTime.compare(before, cutoff) == :lt do
          finish(run, "failed", %{error: "stale"})
          nil
        else
          run
        end
    end
  end

  defp post_brief(settings, claimed, pending, now) do
    with {:ok, content} <- pending_content(pending),
         {:ok, source} <- Members.source(settings),
         {:ok, posted} <-
           Salix.impl().daily_brief_post(
             Sources.personal_post(source, claimed, content, pending.notes["app_id"])
           ) do
      finish(pending, "completed", posted_at(source, posted))
    else
      {:error, reason} ->
        Logger.warning("bridge_for_teams.daily_brief.delivery.failed reason=#{inspect(reason)}")

        if transient?(reason),
          do: release_claim(settings, claimed, now),
          else: finish(pending, "failed", %{error: String.slice(inspect(reason), 0, 200)})

        {:error, reason}
    end
  end

  # Where the provider took the brief: Slack's columns for Slack, the
  # provider's for Feishu and Lark.
  defp posted_at(source, posted) do
    if Sources.slack?(source),
      do: %{slack_channel_id: posted[:channel_id], slack_ts: posted[:ts]},
      else: %{provider_chat_id: posted[:channel_id], provider_message_id: posted[:ts]}
  end

  # A finished brief keeps only the text the model wrote, for the next day's.
  defp finish(run, status, attrs) do
    run
    |> Ecto.Changeset.change(
      Map.merge(attrs, %{
        status: status,
        notes: Map.drop(run.notes || %{}, ["text", "blocks", "card", "app_id"])
      })
    )
    |> Repo.update()
  end

  # A Slack brief waits as text and blocks, a Feishu or Lark brief as its card.
  defp pending_content(%DailyBriefRun{notes: %{"text" => text, "blocks" => blocks}})
       when is_binary(text) and is_list(blocks),
       do: {:ok, %{text: text, blocks: blocks}}

  defp pending_content(%DailyBriefRun{notes: %{"text" => text, "card" => card}})
       when is_binary(text) and is_map(card),
       do: {:ok, %{text: text, card: card}}

  defp pending_content(_run), do: {:error, :brief_unreadable}

  defp record_pending(
         settings,
         member,
         window,
         coverage,
         written,
         rendered,
         usage,
         mine,
         closed,
         issues,
         github,
         app_id
       ) do
    notes =
      %{
        "brief" => written,
        "mine" => mine || [],
        "closed" => closed,
        "issues" => issues || %{},
        "github" => github,
        "text" => rendered.text
      }
      |> Map.merge(rendered_notes(rendered))
      |> then(&if(is_binary(app_id), do: Map.put(&1, "app_id", app_id), else: &1))

    Repo.insert(%DailyBriefRun{
      org_id: settings.org_id,
      project_id: settings.project_id,
      member_id: member.id,
      kind: "personal_brief",
      window_after: window.after,
      window_before: window.before,
      status: "pending",
      coverage: coverage,
      notes: notes,
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens
    })
  end

  defp rendered_notes(%{card: card}), do: %{"card" => card}
  defp rendered_notes(%{blocks: blocks}), do: %{"blocks" => blocks}

  defp record_failed(settings, member, window, reason, usage) do
    Repo.insert!(%DailyBriefRun{
      org_id: settings.org_id,
      project_id: settings.project_id,
      member_id: member.id,
      kind: "personal_brief",
      window_after: window.after,
      window_before: window.before,
      status: "failed",
      error: String.slice(inspect(reason), 0, 200),
      input_tokens: (usage && usage.input_tokens) || 0,
      output_tokens: (usage && usage.output_tokens) || 0
    })
  end

  # A failure that will not pass by itself (no Slack/Feishu/Lark source, no
  # model, a member or group the provider refuses, a broken credential) waits
  # for the next day's brief, so it never costs a model run every hour. Every
  # other failure (a rate limit, a 5xx, a network or RPC fault) is retried in
  # about an hour.
  @permanent_lark_codes [230_001, 230_002, 230_013, 99_991_668, 99_991_672, 99_992_361]

  @permanent_errors ~w(
    user_not_found cannot_dm_bot channel_not_found is_bot account_inactive
    invalid_auth not_authed token_revoked missing_scope not OAuth-complete
    :source_unavailable :invalid_request :model_unavailable
    channel_ineligible 230001 230002 230013 99991668 99991672 99992361
  )

  @doc false
  def transient?(reason)
      when reason in [
             :source_unavailable,
             :invalid_request,
             :model_unavailable,
             :channel_ineligible
           ],
      do: false

  def transient?({_, code, _}) when code in @permanent_lark_codes, do: false
  def transient?({_, code}) when code in @permanent_lark_codes, do: false
  def transient?(%{code: code}) when code in @permanent_lark_codes, do: false
  def transient?(%{"code" => code}) when code in @permanent_lark_codes, do: false

  def transient?(reason) when is_binary(reason),
    do: not Enum.any?(@permanent_errors, &String.contains?(reason, &1))

  def transient?(_reason), do: true

  # A brief that could not be sent is tried again in about an hour, not
  # after the next day's claim. A requested brief is asked for again in an
  # hour, so the scheduled one keeps its time. `member` is as it was claimed.
  @doc false
  def release_claim(settings, %DailyBriefMember{brief_requested_at: %DateTime{}} = member, now) do
    if scheduled?(settings, member, now),
      do: retry_scheduled(member, now),
      else:
        Repo.update_all(from(m in DailyBriefMember, where: m.id == ^member.id),
          set: [brief_requested_at: DateTime.add(now, 3600)]
        )
  end

  def release_claim(_settings, member, now), do: retry_scheduled(member, now)

  defp retry_scheduled(member, now) do
    retry_at = DateTime.add(now, -(@shared_interval_seconds - 3600))

    Repo.update_all(from(m in DailyBriefMember, where: m.id == ^member.id),
      set: [brief_claimed_at: retry_at]
    )
  end

  ## Team brief

  # One team brief per Swarm at a time: it holds a `running` row, and a
  # second Pod that finds it skips. One that failed is tried again after an
  # hour, by whichever brief comes next.
  defp ensure_team_brief(settings, now, opts, since, reuse \\ nil) do
    last = latest_team_run(settings)

    cond do
      fresh?(last, now, since) ->
        {:ok, last}

      recently_failed?(settings, now) ->
        {:error, :team_brief_failed}

      true ->
        write_team_brief(settings, last, now, opts, reuse)
    end
  end

  defp fresh?(nil, _now, _since), do: false

  defp fresh?(last, now, since),
    do:
      DateTime.diff(now, last.window_before) < @shared_interval_seconds and
        (is_nil(since) or DateTime.compare(last.created_at, since) != :lt)

  defp recently_failed?(settings, now) do
    Repo.exists?(
      from(r in DailyBriefRun,
        where:
          r.project_id == ^settings.project_id and r.kind == "team_brief" and
            r.status == "failed" and r.created_at > ^DateTime.add(now, -@team_retry_seconds)
      )
    )
  end

  defp write_team_brief(settings, last, now, opts, reuse) do
    # After a long pause the brief reads the latest days, as a member's does.
    window = %{
      after:
        Enum.max(
          [
            (last && last.window_before) || DateTime.add(now, -@default_window_seconds),
            DateTime.add(now, -@max_window_days * @default_window_seconds)
          ],
          DateTime
        ),
      before: settled(now)
    }

    with {:ok, run} <- RunLease.claim(settings, "team_brief", window, now) do
      try do
        with {:ok, shared} <- team_shared_source(settings, window, reuse),
             input = %{
               settings: settings,
               shared: shared,
               previous: last && last.notes["brief"],
               issues: last && last.notes["issues"],
               now: now
             },
             {:ok, %{text: text, posted: posted, usage: usage} = written} <-
               Compose.write_team(input, opts),
             {:ok, finished} <-
               RunLease.finish(run, "completed", %{
                 notes: %{
                   "brief" => text,
                   "brief_posted" => posted,
                   "issues" => written[:issues] || %{}
                 },
                 coverage: %{
                   "complete" => SharedSource.complete?(shared.coverage),
                   "messages" => length(shared.messages)
                 },
                 input_tokens: usage.input_tokens,
                 output_tokens: usage.output_tokens
               }) do
          {:ok, finished, shared}
        else
          failed ->
            {reason, usage} = reason_and_usage(failed)

            Logger.warning(
              "bridge_for_teams.daily_brief.team_brief.failed reason=#{inspect(reason)}"
            )

            RunLease.finish(run, "failed", %{
              error: String.slice(inspect(reason), 0, 200),
              input_tokens: (usage && usage.input_tokens) || 0,
              output_tokens: (usage && usage.output_tokens) || 0
            })

            {:error, reason}
        end
      rescue
        error ->
          RunLease.finish(run, "failed", %{error: "crashed"})
          reraise error, __STACKTRACE__
      end
    end
  end

  # The team brief reads its Swarm and the Swarms it may search. A read the
  # batch made of the same Swarms serves it.
  defp team_shared_source(settings, window, reuse) do
    scope = Scope.team(settings)
    key = Scope.key(scope)

    case reuse do
      %{window: ^window, shared: %{window: ^window} = shared} ->
        if Map.get(shared, :scope, [settings.id]) == key,
          do: {:ok, shared},
          else: read_scope(scope, window, Map.get(reuse, :members, []))

      %{window: ^window, members: [_ | _] = members} ->
        read_scope(scope, window, members)

      _none ->
        read_scope(scope, window, [])
    end
  end

  defp read_scope(scope, window, members) do
    with {:ok, shared} <- SharedSource.read(scope, window, members: members) do
      {:ok, Map.put(shared, :scope, Scope.key(scope))}
    end
  end

  @doc """
  Posts today's team brief to each organization's team channel once its
  `team_post_at` has passed, on the organization's workdays, where most
  members are. A team brief that has not been written today is written first.
  Each brief is claimed before it is posted, so two Pods post it once; a
  failed post is recorded and not retried, since the next day brings a new
  brief.
  """
  @spec post_team_briefs(DateTime.t(), keyword()) :: :ok
  def post_team_briefs(now, opts \\ []) do
    settings =
      Repo.all(from(s in DailyBriefSetting, where: s.enabled and not is_nil(s.team_channel_id)))

    for settings <- settings, {:ok, day_start, zone} <- [team_post_due(settings, now)] do
      # One organization's failure must not keep the others' briefs back.
      try do
        # The team's channel gets a brief written that day.
        _ = ensure_team_brief(settings, now, Keyword.take(opts, [:model, :agent_id]), day_start)
        post_team_brief(settings, day_start, zone, now)
      rescue
        exception ->
          Logger.error(
            "bridge_for_teams.daily_brief.team_brief.crashed #{Exception.message(exception)}"
          )
      catch
        kind, reason ->
          Logger.error(
            "bridge_for_teams.daily_brief.team_brief.exited #{kind} #{inspect(reason, limit: 5)}"
          )
      end
    end

    :ok
  end

  # The local day's start, when the brief's time today has passed in the last
  # few hours (a brief is not posted in the evening after an outage).
  @team_post_window_seconds 3 * 3600

  defp team_post_due(settings, now) do
    zone = Compose.team_zone(Members.enabled(settings))

    with {:ok, local} <- DateTime.shift_zone(now, zone),
         day = DateTime.to_date(local),
         true <- workday?(settings, day),
         {:ok, at} <- DateTime.new(day, settings.team_post_at, zone),
         seconds when seconds >= 0 and seconds < @team_post_window_seconds <-
           DateTime.diff(now, at),
         {:ok, day_start} <- DateTime.new(day, ~T[00:00:00], zone) do
      {:ok, DateTime.shift_zone!(day_start, "Etc/UTC"), zone}
    else
      _not_due -> :not_due
    end
  end

  defp post_team_brief(settings, day_start, zone, now) do
    with %DailyBriefRun{notes: %{"brief_posted" => posted}} = run
         when is_binary(posted) <- latest_team_run(settings),
         true <- DateTime.compare(run.created_at, day_start) != :lt,
         {1, _} <- claim_team_post(run, now) do
      read =
        if Sources.slack?(settings),
          do: "读了 #{run.coverage["messages"] || 0} 条公开频道消息",
          else: "读了 #{run.coverage["messages"] || 0} 条公开群消息"

      content =
        Sources.sink(settings).render_team("团队简报 · " <> date_label(now, zone), posted, read)

      result =
        with {:ok, source} <- Members.source(settings),
             {:ok, posted} <-
               Salix.impl().daily_brief_post(
                 Sources.team_post(source, settings.team_channel_id, content)
               ) do
          %{"team_brief_ts" => posted[:ts]}
        else
          {:error, reason} ->
            Logger.warning(
              "bridge_for_teams.daily_brief.team_brief.post_failed reason=#{inspect(reason)}"
            )

            %{"team_brief_post_error" => String.slice(inspect(reason), 0, 200)}
        end

      run = Repo.get!(DailyBriefRun, run.id)
      run |> Ecto.Changeset.change(coverage: Map.merge(run.coverage, result)) |> Repo.update()
    end
  end

  # Marks the brief as being posted, only if no one has.
  defp claim_team_post(run, now) do
    at = DateTime.to_iso8601(now)

    Repo.update_all(
      from(r in DailyBriefRun,
        where: r.id == ^run.id and not fragment("? \\? 'team_brief_claimed_at'", r.coverage),
        update: [
          set: [
            coverage:
              fragment(
                "? || jsonb_build_object('team_brief_claimed_at', ?::text)",
                r.coverage,
                ^at
              )
          ]
        ]
      ),
      []
    )
  end

  defp date_label(now, zone) do
    case DateTime.shift_zone(now, zone) do
      {:ok, local} -> "#{local.month}月#{local.day}日"
      _ -> "#{now.month}月#{now.day}日"
    end
  end

  defp latest_team_run(settings) do
    Repo.one(
      from(r in DailyBriefRun,
        where:
          r.project_id == ^settings.project_id and r.kind == "team_brief" and
            r.status == "completed",
        order_by: [desc: r.window_before],
        limit: 1
      )
    )
  end

  defp latest_team_brief(settings) do
    case latest_team_run(settings) do
      %DailyBriefRun{notes: %{"brief" => text}} when is_binary(text) -> text
      _none -> nil
    end
  end

  defp last_brief(member) do
    Repo.one(
      from(r in DailyBriefRun,
        where:
          r.member_id == ^member.id and r.kind == "personal_brief" and
            r.status == "completed",
        order_by: [desc: r.window_before],
        limit: 1
      )
    )
  end

  # What the recent briefs closed, kept for @closed_days so a later brief
  # does not bring it back as open from an old message.
  defp last_closed(member, now) do
    floor = now |> DateTime.add(-@closed_days * @default_window_seconds) |> DateTime.to_date()

    case last_brief(member) do
      %DailyBriefRun{notes: %{"closed" => closed}} when is_list(closed) ->
        Enum.filter(closed, &(is_map(&1) and on_or_after?(&1["on"], floor)))

      _none ->
        []
    end
  end

  defp on_or_after?(day, floor) when is_binary(day) do
    case Date.from_iso8601(day) do
      {:ok, date} -> Date.compare(date, floor) != :lt
      _invalid -> false
    end
  end

  defp on_or_after?(_day, _floor), do: false

  defp closed(mine, kept, now, zone) do
    today = local_day(now, zone)

    new =
      for %{"status" => "done" <> _ = status, "what" => what} <- mine || [],
          do: %{"what" => what, "status" => status, "on" => today}

    (new ++ kept)
    |> Enum.reduce([], fn entry, acc ->
      if Enum.any?(acc, &Compose.same_thing?(entry, &1)), do: acc, else: [entry | acc]
    end)
    |> Enum.reverse()
    |> Enum.take(@max_closed)
  end

  defp last_note(member, key) do
    case last_brief(member) do
      %DailyBriefRun{notes: %{^key => value}} -> value
      _none -> nil
    end
  end

  defp last_issues(member) do
    case last_brief(member) do
      %DailyBriefRun{notes: %{"issues" => issues}} when is_map(issues) -> issues
      _none -> %{}
    end
  end

  defp brief_channel(member) do
    case last_brief(member) do
      %DailyBriefRun{slack_channel_id: channel} when is_binary(channel) -> channel
      _none -> nil
    end
  end

  # The member's things the last brief listed, carried to the next one; a
  # thing with no news for @stale_days drops out (a reply brings it back).
  defp last_mine(member, now) do
    floor = now |> DateTime.add(-@stale_days * @default_window_seconds) |> DateTime.to_date()

    Enum.filter(last_brief_mine(member), fn
      %{"news_on" => day} when is_binary(day) -> on_or_after?(day, floor)
      _unstamped -> true
    end)
  end

  defp last_brief_mine(member) do
    case last_brief(member) do
      %DailyBriefRun{notes: %{"mine" => mine}} when is_list(mine) -> mine
      _none -> []
    end
  end

  # Each listed thing keeps the day it last had news: today when the model
  # cited a message for it, else the day the last brief kept for it.
  defp stamp(mine, previous, today) do
    earlier = Map.new(for %{"what" => what} = e <- previous, is_map(e), do: {what, e["news_on"]})

    for entry <- mine || [] do
      news_on =
        if entry["evidence"] not in [nil, ""],
          do: today,
          else: earlier[entry["what"]] || reworded(entry, previous) || today

      Map.put(entry, "news_on", news_on)
    end
  end

  # A thing given again under other words keeps the day it last had news.
  defp reworded(entry, previous) do
    Enum.find_value(previous, fn e ->
      is_map(e) and Compose.same_thing?(entry, e) and e["news_on"]
    end)
  end

  defp local_day(now, zone) do
    case DateTime.shift_zone(now, zone || "Etc/UTC") do
      {:ok, local} -> local
      _unknown -> now
    end
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp last_brief_text(member) do
    case last_brief(member) do
      %DailyBriefRun{notes: %{"brief" => text}} when is_binary(text) -> text
      _none -> nil
    end
  end

  # The window starts where the member's last sent brief ended, so a failed
  # day is read again by the next brief instead of being skipped. With none
  # yet, it starts at the first attempt, at most 12 days back.
  defp window_start(member, now) do
    floor = DateTime.add(now, -@max_window_days * @default_window_seconds)

    at =
      case last_brief(member) do
        %DailyBriefRun{window_before: before} -> before
        nil -> first_attempt_at(member)
      end

    case at do
      nil -> DateTime.add(now, -@default_window_seconds)
      at -> Enum.max([at, floor], DateTime)
    end
  end

  defp first_attempt_at(member) do
    Repo.one(
      from(r in DailyBriefRun,
        where: r.member_id == ^member.id and r.kind == "personal_brief",
        select: min(r.window_after)
      )
    )
  end
end
