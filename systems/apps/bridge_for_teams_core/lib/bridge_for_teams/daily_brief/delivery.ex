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
  member's last brief (`Compose`); the Swarm's bot posts it. A brief waits as
  a `pending` run until Slack takes it, so a failed send is sent again without
  another model run. The team brief is posted to the team's channel at its
  own time.
  """

  import Ecto.Query

  require Logger

  alias BridgeForTeams.Repo
  alias BridgeForTeams.DailyBrief.{Compose, Members, RunLease, SharedSource, Sinks}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefRun, DailyBriefSetting}

  @shared_interval_seconds 20 * 3600
  @default_window_seconds 86_400
  # A brief after days off still reads back to the last one.
  @max_window_days 12
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
              on: s.org_id == m.org_id,
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
    after_at = window_start(member, now)
    window = %{after: after_at, before: Enum.max([settled(now), after_at], DateTime)}
    model_opts = Keyword.take(opts, [:model, :agent_id])

    _ = ensure_team_brief(settings, now, model_opts)

    with {:ok, shared} <- SharedSource.read(settings, window, members: [member]),
         input = %{
           settings: settings,
           member: member,
           shared: shared,
           team_brief: latest_team_brief(settings),
           previous: last_brief_text(member),
           now: now
         },
         {:ok, %{text: text, usage: usage}} <- Compose.write(input, model_opts),
         rendered = Sinks.Slack.render_personal(title(member.timezone, now), text),
         coverage = %{"shared_complete" => SharedSource.complete?(shared.coverage)},
         {:ok, pending} <-
           record_pending(settings, member, window, coverage, text, rendered, usage) do
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

  defp reason_and_usage({:error, reason, usage}), do: {reason, usage}
  defp reason_and_usage({:error, reason}), do: {reason, nil}

  @doc "Where a window read now may end: late mirror writes settle first."
  @spec settled(DateTime.t()) :: DateTime.t()
  def settled(now), do: DateTime.add(now, -@settle_seconds)

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
    with {:ok, %{text: text, blocks: blocks}} <- pending_content(pending),
         {:ok, source} <- Members.source(settings),
         {:ok, posted} <-
           Salix.impl().daily_brief_post(
             Map.merge(source, %{slack_user_id: claimed.slack_user_id, text: text, blocks: blocks})
           ) do
      finish(pending, "completed", %{
        slack_channel_id: posted[:channel_id],
        slack_ts: posted[:ts]
      })
    else
      {:error, reason} ->
        Logger.warning("bridge_for_teams.daily_brief.delivery.failed reason=#{inspect(reason)}")

        if transient?(reason),
          do: release_claim(settings, claimed, now),
          else: finish(pending, "failed", %{error: String.slice(inspect(reason), 0, 200)})

        {:error, reason}
    end
  end

  # A finished brief keeps only the text the model wrote, for the next day's.
  defp finish(run, status, attrs) do
    run
    |> Ecto.Changeset.change(
      Map.merge(attrs, %{status: status, notes: Map.drop(run.notes || %{}, ["text", "blocks"])})
    )
    |> Repo.update()
  end

  defp pending_content(%DailyBriefRun{notes: %{"text" => text, "blocks" => blocks}})
       when is_binary(text) and is_list(blocks),
       do: {:ok, %{text: text, blocks: blocks}}

  defp pending_content(_run), do: {:error, :brief_unreadable}

  defp record_pending(settings, member, window, coverage, written, rendered, usage) do
    Repo.insert(%DailyBriefRun{
      org_id: settings.org_id,
      project_id: settings.project_id,
      member_id: member.id,
      kind: "personal_brief",
      window_after: window.after,
      window_before: window.before,
      status: "pending",
      coverage: coverage,
      notes: %{"brief" => written, "text" => rendered.text, "blocks" => rendered.blocks},
      input_tokens: usage.input_tokens,
      output_tokens: usage.output_tokens
    })
  end

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

  # A failure that will not pass by itself (no Slack source, no model, a
  # member Slack refuses, a broken credential) waits for the next day's brief,
  # so it never costs a model run every hour. Every other failure (a rate
  # limit, a Slack 5xx, a network or RPC fault) is retried in about an hour.
  @permanent_slack_errors ~w(
    user_not_found cannot_dm_bot channel_not_found is_bot account_inactive
    invalid_auth not_authed token_revoked missing_scope not OAuth-complete
    :source_unavailable :invalid_request :model_unavailable
  )

  @doc false
  def transient?(reason)
      when reason in [:source_unavailable, :invalid_request, :model_unavailable],
      do: false

  def transient?(reason) when is_binary(reason),
    do: not Enum.any?(@permanent_slack_errors, &String.contains?(reason, &1))

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
  defp ensure_team_brief(settings, now, opts, since \\ nil) do
    last = latest_team_run(settings)

    cond do
      fresh?(last, now, since) ->
        {:ok, last}

      recently_failed?(settings, now) ->
        {:error, :team_brief_failed}

      true ->
        write_team_brief(settings, last, now, opts)
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

  defp write_team_brief(settings, last, now, opts) do
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
        with {:ok, shared} <- SharedSource.read(settings, window, members: []),
             input = %{
               settings: settings,
               shared: shared,
               previous: last && last.notes["brief"],
               now: now
             },
             {:ok, %{text: text, posted: posted, usage: usage}} <-
               Compose.write_team(input, opts) do
          RunLease.finish(run, "completed", %{
            notes: %{"brief" => text, "brief_posted" => posted},
            coverage: %{
              "complete" => SharedSource.complete?(shared.coverage),
              "messages" => length(shared.messages)
            },
            input_tokens: usage.input_tokens,
            output_tokens: usage.output_tokens
          })
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
    zone = Compose.team_zone(Members.enabled(settings.org_id))

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
      read = "读了 #{run.coverage["messages"] || 0} 条公开频道消息"

      %{text: text, blocks: blocks} =
        Sinks.Slack.render_team("团队简报 · " <> date_label(now, zone), posted, read)

      result =
        with {:ok, source} <- Members.source(settings),
             {:ok, posted} <-
               Salix.impl().daily_brief_post(
                 Map.merge(source, %{
                   channel_id: settings.team_channel_id,
                   text: text,
                   blocks: blocks
                 })
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
