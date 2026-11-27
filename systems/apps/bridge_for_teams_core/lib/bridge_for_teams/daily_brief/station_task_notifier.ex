defmodule BridgeForTeams.DailyBrief.StationTaskNotifier do
  @moduledoc """
  Sends immediate personal DMs (Slack, Feishu, or Lark) to linked `DailyBriefMember`s
  when a connected `still.fail` chat transitions to `need`, `failed`, or `done`
  for them within the recent live window, deduplicated per `(member, task_key, stop)`
  in `daily_brief_members.station_task_notified`.
  """
  use SystemsRuntime.Server

  import Ecto.Query
  require Logger

  alias BridgeForTeams.DailyBrief.{Members, Sources}
  alias BridgeForTeams.Repo
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefMember, DailyBriefSetting, Project, User}

  @default_interval_ms 30_000
  @default_debounce_ms 1_000
  @live_window_ms 30 * 60 * 1_000
  @done_grace_ms 3 * 60 * 1_000
  @presence_active_window_ms 2 * 60 * 1_000
  @presence_defer_ms 2 * 60 * 1_000
  @max_clock_skew_ms 60_000
  @max_tracked_keys 100
  @max_per_member_per_tick 5
  @system_card_kinds ~w(login secret vault signin device adb rig)
  @baseline_key "__baseline__"

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec run_once(keyword()) :: {:ok, non_neg_integer()}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, SystemsClock.utc_now())
    group_ids = Keyword.get(opts, :group_ids)

    cutoff_ms =
      DateTime.to_unix(now, :millisecond) - Keyword.get(opts, :window_ms, @live_window_ms)

    salix = Salix.impl()

    sent =
      if Code.ensure_loaded?(salix) and function_exported?(salix, :daily_brief_station_tasks, 1) do
        enabled_settings(group_ids)
        |> Enum.reduce(0, fn settings, acc ->
          acc + notify_org(settings, salix, cutoff_ms, now)
        end)
      else
        0
      end

    {:ok, sent}
  end

  @impl true
  def init(opts) do
    cfg = SystemsRuntime.get_env(:bridge_for_teams_core, __MODULE__, [])

    interval =
      Keyword.get(opts, :interval_ms, Keyword.get(cfg, :interval_ms, @default_interval_ms))

    debounce =
      Keyword.get(opts, :debounce_ms, Keyword.get(cfg, :debounce_ms, @default_debounce_ms))

    schedule(interval)

    state =
      maybe_subscribe(%{
        interval_ms: interval,
        debounce_ms: debounce,
        run_opts: Keyword.get(opts, :run_opts, []),
        subscribed?: false,
        pending_groups: MapSet.new()
      })

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    state = maybe_subscribe(state)
    safe_run_once(state.run_opts)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:station_tasks_invalidated, group_id}, state) when is_binary(group_id) do
    if MapSet.size(state.pending_groups) == 0 do
      SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll_invalidated, state.debounce_ms)
    end

    {:noreply, %{state | pending_groups: MapSet.put(state.pending_groups, group_id)}}
  end

  def handle_info(:poll_invalidated, state) do
    groups = MapSet.to_list(state.pending_groups)

    if groups != [] do
      safe_run_once(Keyword.put(state.run_opts, :group_ids, groups))
    end

    {:noreply, %{state | pending_groups: MapSet.new()}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp safe_run_once(run_opts) do
    try do
      run_once(run_opts)
    rescue
      exception ->
        Logger.error(
          "bridge_for_teams.daily_brief.station_task_notifier.failed #{Exception.message(exception)}"
        )
    end
  end

  defp maybe_subscribe(%{subscribed?: true} = state), do: state

  defp maybe_subscribe(state) do
    mod = SalixWeb.StationTaskIndex

    try do
      if Code.ensure_loaded?(mod) and function_exported?(mod, :subscribe_all, 1) do
        :ok = apply(mod, :subscribe_all, [SystemsRuntime.Proc.self()])
        %{state | subscribed?: true}
      else
        state
      end
    rescue
      _ -> state
    catch
      :exit, _ -> state
    end
  end

  defp schedule(interval_ms),
    do: SystemsClock.send_after(SystemsRuntime.Proc.self(), :poll, interval_ms)

  defp enabled_settings([_ | _] = group_ids) do
    Repo.all(
      from(s in DailyBriefSetting,
        join: p in Project,
        on: p.id == s.project_id,
        where: s.enabled == true and p.salix_group_id in ^group_ids,
        order_by: [asc: s.created_at, asc: s.id]
      )
    )
  end

  defp enabled_settings(_all) do
    Repo.all(
      from(s in DailyBriefSetting,
        where: s.enabled == true,
        order_by: [asc: s.created_at, asc: s.id]
      )
    )
  end

  defp notify_org(settings, salix, cutoff_ms, now) do
    with {:ok, source} <- Members.source(settings),
         members when members != [] <- Members.enabled(settings),
         {:ok, rows} when is_list(rows) <- salix.daily_brief_station_tasks(source.group_id) do
      now_ms = DateTime.to_unix(now, :millisecond)
      emails = member_emails(members)
      active_owners = active_owner_emails(salix, source.group_id, now_ms)

      Enum.reduce(members, 0, fn member, count ->
        case Map.get(emails, member.user_id) do
          email when is_binary(email) and email != "" ->
            member_active? = MapSet.member?(active_owners, email)

            count +
              notify_member(
                settings,
                source,
                member,
                email,
                rows,
                salix,
                cutoff_ms,
                now,
                now_ms,
                member_active?
              )

          _ ->
            count
        end
      end)
    else
      _ -> 0
    end
  end

  defp active_owner_emails(salix, group_id, now_ms) do
    stations =
      if Code.ensure_loaded?(salix) and function_exported?(salix, :stillfail_stations, 1) do
        try do
          case salix.stillfail_stations(group_id) do
            {:ok, list} when is_list(list) -> list
            _ -> []
          end
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      else
        []
      end

    Enum.reduce(stations, MapSet.new(), fn station, acc ->
      if is_map(station) and (station["connected"] == true or station[:connected] == true) do
        owner_email = station["owner_email"] || station[:owner_email]
        owner_active_at = station["owner_active_at"] || station[:owner_active_at]

        if is_binary(owner_email) and is_integer(owner_active_at) and
             now_ms - owner_active_at < @presence_active_window_ms and
             owner_active_at <= now_ms + @max_clock_skew_ms do
          normalized = normalize_email(owner_email)
          if normalized != "", do: MapSet.put(acc, normalized), else: acc
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp member_emails(members) do
    user_ids = members |> Enum.map(& &1.user_id) |> Enum.uniq()

    from(u in User,
      where: u.id in ^user_ids and u.status == "active" and not is_nil(u.email),
      select: {u.id, u.email}
    )
    |> Repo.all()
    |> Map.new(fn {id, email} -> {id, normalize_email(email)} end)
  end

  defp notify_member(
         settings,
         source,
         member,
         email,
         rows,
         salix,
         cutoff_ms,
         now,
         now_ms,
         member_active?
       ) do
    all_candidates =
      rows
      |> Enum.flat_map(&match_row(&1, email, cutoff_ms))
      |> Enum.sort_by(fn c -> {priority_rank(c), -c.at, c.task_key} end)

    case ensure_member_baseline(settings.org_id, member.id, all_candidates, now) do
      :locked_out ->
        0

      baseline_state ->
        to_deliver =
          case baseline_state do
            :seeded_done -> Enum.reject(all_candidates, &(&1.state == "done"))
            _ -> all_candidates
          end
          |> Enum.reject(&deferred?(&1, now_ms, member_active?))
          |> Enum.take(@max_per_member_per_tick)

        Enum.reduce(to_deliver, 0, fn candidate, sent ->
          case deliver_candidate(settings, source, member.id, candidate, salix, now) do
            :sent -> sent + 1
            :skip -> sent
          end
        end)
    end
  end

  # Urgent interactive system cards never wait for grace or presence deferral.
  defp deferred?(%{state: "need", card_kind: kind}, _now_ms, _member_active?)
       when kind in @system_card_kinds,
       do: false

  # Unread `done` stops wait `@done_grace_ms` before sending a DM.
  defp deferred?(%{state: "done", at: at}, now_ms, _member_active?)
       when is_integer(at) and at > now_ms - @done_grace_ms and
              at <= now_ms + @max_clock_skew_ms,
       do: true

  # When the member is active in Monoid, ordinary `need`/`failed` defer for `@presence_defer_ms`.
  defp deferred?(%{state: state, at: at}, now_ms, true)
       when state in ~w(need failed) and is_integer(at) and
              at > now_ms - @presence_defer_ms and at <= now_ms + @max_clock_skew_ms,
       do: true

  defp deferred?(_candidate, _now_ms, _member_active?), do: false

  defp ensure_member_baseline(org_id, member_id, all_candidates, now) do
    Repo.transaction(fn ->
      locked =
        Repo.one(
          from(m in DailyBriefMember,
            where: m.id == ^member_id and m.enabled == true,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      case locked do
        nil ->
          :locked_out

        %DailyBriefMember{} = current ->
          current_map =
            if is_map(current.station_task_notified), do: current.station_task_notified, else: %{}

          if map_size(current_map) > 0 do
            :already_seeded
          else
            sibling_notified =
              from(m in DailyBriefMember,
                where:
                  m.org_id == ^org_id and m.user_id == ^current.user_id and m.id != ^current.id,
                select: m.station_task_notified
              )
              |> Repo.all()
              |> Enum.filter(&(is_map(&1) and map_size(&1) > 0))
              |> Enum.reduce(%{}, &Map.merge(&2, &1))

            if map_size(sibling_notified) > 0 do
              current
              |> Ecto.Changeset.change(station_task_notified: sibling_notified, updated_at: now)
              |> Repo.update!()

              :inherited
            else
              now_ms = DateTime.to_unix(now, :millisecond)

              seed =
                all_candidates
                |> Enum.filter(&(&1.state == "done"))
                |> Enum.reduce(%{@baseline_key => "seeded:#{now_ms}"}, fn candidate, acc ->
                  put_bounded(acc, candidate.task_key, candidate.obs)
                end)

              current
              |> Ecto.Changeset.change(station_task_notified: seed, updated_at: now)
              |> Repo.update!()

              :seeded_done
            end
          end
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _reason} -> :locked_out
    end
  end

  defp deliver_candidate(settings, source, member_id, candidate, salix, now) do
    Repo.transaction(fn ->
      locked =
        Repo.one(
          from(m in DailyBriefMember,
            where: m.id == ^member_id and m.enabled == true,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )

      case locked do
        %DailyBriefMember{} = current ->
          notified =
            if is_map(current.station_task_notified), do: current.station_task_notified, else: %{}

          if Map.get(notified, candidate.task_key) == candidate.obs do
            :skip
          else
            rendered = render_dm(settings, candidate)
            request = Sources.personal_post(source, current, rendered)

            case salix.daily_brief_post(request) do
              {:ok, _receipt} ->
                updated = put_bounded(notified, candidate.task_key, candidate.obs)

                current
                |> Ecto.Changeset.change(station_task_notified: updated, updated_at: now)
                |> Repo.update!()

                :sent

              {:error, reason} ->
                Logger.warning(
                  "bridge_for_teams.daily_brief.station_task_notifier.post_failed member=#{member_id} reason=#{inspect(reason, limit: 5)}"
                )

                :skip
            end
          end

        nil ->
          :skip
      end
    end)
    |> case do
      {:ok, outcome} -> outcome
      {:error, _reason} -> :skip
    end
  end

  defp put_bounded(map, key, obs) when is_map(map) do
    next = Map.put(map, key, obs)

    if map_size(next) <= @max_tracked_keys do
      next
    else
      next
      |> Enum.sort_by(fn {_k, v} -> obs_timestamp(v) end, :desc)
      |> Enum.take(@max_tracked_keys)
      |> Map.new()
    end
  end

  defp obs_timestamp(obs) when is_binary(obs) do
    case String.split(obs, ":") do
      [_kind, ts] ->
        case Integer.parse(ts) do
          {n, ""} -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp obs_timestamp(_), do: 0

  defp match_row(row, email, cutoff_ms) when is_map(row) do
    station_id = to_string(row[:station_id] || row["station_id"] || "")
    thread = to_string(row[:thread] || row["thread"] || "")
    url = to_string(row[:url] || row["url"] || "")
    at = row[:last_activity_at] || row["last_activity_at"] || 0
    attention = row[:attention] || row["attention"]
    status = row[:status] || row["status"]
    waits_for = row[:waits_for] || row["waits_for"] || []
    created_by = row[:created_by] || row["created_by"]
    participants = row[:participants] || row["participants"] || []

    waits_list =
      waits_for
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_email/1)
      |> Enum.reject(&(&1 == ""))

    waits? = email in waits_list
    creator? = is_binary(created_by) and normalize_email(created_by) == email

    participant? =
      Enum.any?(List.wrap(participants), fn entry ->
        is_binary(entry) and normalize_email(entry) == email
      end)

    state =
      cond do
        station_id == "" or thread == "" or not String.starts_with?(url, "https://") ->
          nil

        not is_integer(at) or at < cutoff_ms ->
          nil

        attention == "need" and waits_list != [] ->
          if waits?, do: "need", else: nil

        attention == "need" ->
          if creator? or participant?, do: "need", else: nil

        attention in ~w(failed done) ->
          if waits? or creator? or participant?, do: attention, else: nil

        is_nil(attention) and status == "needs_review" and (creator? or participant?) ->
          "need"

        true ->
          nil
      end

    if is_binary(state) do
      obs_kind = if state == "need", do: "needs_review", else: state
      card_kind = extract_card_kind(row[:labels] || row["labels"])
      title = sanitize_inline(row[:title] || row["title"] || thread)
      note = sanitize_inline(row[:note] || row["note"])

      [
        %{
          task_key: "#{station_id}:#{thread}",
          obs: "#{obs_kind}:#{at}",
          state: state,
          card_kind: card_kind,
          title: if(title == "", do: thread, else: title),
          note: note,
          url: url,
          at: at
        }
      ]
    else
      []
    end
  end

  defp match_row(_row, _email, _cutoff_ms), do: []

  defp priority_rank(%{state: "need", card_kind: kind}) when kind in @system_card_kinds, do: 0
  defp priority_rank(%{state: state}) when state in ~w(need failed), do: 1
  defp priority_rank(_done), do: 2

  defp render_dm(settings, candidate) do
    title = dm_title(candidate)
    body = dm_body(settings, candidate)
    Sources.sink(settings).render_personal(title, body, nil)
  end

  defp dm_title(%{state: "need", card_kind: kind}) when kind in @system_card_kinds,
    do: "Monoid 需要确认授权"

  defp dm_title(%{state: "need"}), do: "Monoid 等待你的回复"
  defp dm_title(%{state: "failed"}), do: "Monoid 任务执行出错"
  defp dm_title(%{state: "done"}), do: "Monoid 任务已完成"

  defp dm_body(settings, %{title: title, note: note, url: url, state: state} = candidate) do
    hint = card_hint(state, candidate[:card_kind])
    detail = [note, hint] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" — ")

    if Sources.slack?(settings) do
      link = "<#{url}|打开对话>"

      if detail == "" do
        "*#{escape_mrkdwn(title)}* · #{link}"
      else
        "*#{escape_mrkdwn(title)}*：#{escape_mrkdwn(detail)} · #{link}"
      end
    else
      link = "[打开对话](#{url})"

      if detail == "" do
        "**#{escape_md(title)}** · #{link}"
      else
        "**#{escape_md(title)}**：#{escape_md(detail)} · #{link}"
      end
    end
  end

  defp card_hint("need", kind) when kind in ~w(login signin), do: "请在页面卡片中完成登录授权"
  defp card_hint("need", kind) when kind in ~w(secret vault), do: "请在页面卡片中审批凭证使用"
  defp card_hint("need", kind) when kind in ~w(device adb rig), do: "请在页面卡片中确认设备授权"
  defp card_hint("need", "options"), do: "包含选项卡片，可直接点选"
  defp card_hint(_state, _kind), do: nil

  defp extract_card_kind(labels) when is_list(labels) do
    Enum.find_value(labels, fn
      "card:" <> kind when kind != "" -> kind
      _ -> nil
    end)
  end

  defp extract_card_kind(_), do: nil

  defp sanitize_inline(nil), do: ""

  defp sanitize_inline(value) do
    value
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 240)
  end

  defp escape_mrkdwn(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("*", "∗")
  end

  defp escape_md(text) do
    text
    |> String.replace("[", "\\[")
    |> String.replace("]", "\\]")
    |> String.replace("*", "\\*")
  end

  defp normalize_email(email), do: email |> String.trim() |> String.downcase()
end
