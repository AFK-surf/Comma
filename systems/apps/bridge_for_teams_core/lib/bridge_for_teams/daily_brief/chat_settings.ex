defmodule BridgeForTeams.DailyBrief.ChatSettings do
  @moduledoc """
  Changes to the daily brief that a member asks the Swarm's bot for in Slack,
  Feishu, or Lark. Salix's Router tools `daily_brief.set_time`,
  `daily_brief.set_channel`, `daily_brief.set_project`, and
  `daily_brief.set_github` call this with the signed origin of the current
  message, so the requester is the provider user who wrote it (a Slack user
  id, or a Feishu or Lark open id), never a name in its text. Only a bot
  of a Swarm with daily brief settings takes the change. Channels and projects change only
  the requester's own brief.

    * `"mine"` sets the requester's own brief time; any enabled brief member
      may. Today's brief, if sent, is not sent again.
    * `"team"` sets the team brief's time of the Swarm whose bot took the
      message; only an organization owner or admin may.

  A member is one per provider, whichever Swarm's bot they write to: their
  time, channels, projects, and GitHub login are of their one brief.
  """

  import Ecto.Query

  alias BridgeForTeams.{DailyBrief, Memberships, Repo}
  alias BridgeForTeams.DailyBrief.{Compose, Focus, Members, Scope, Sources}
  alias BridgeForTeams.Salix.Client, as: Salix
  alias BridgeForTeams.Schema.{DailyBriefAlias, DailyBriefMember, DailyBriefSetting, Project}

  @channel_modes ~w(follow follow_with_bots ignore default)
  @project_modes ~w(add remove)

  @spec set_time(String.t(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def set_time(group_id, origin, brief, time) when brief in ["mine", "team"] do
    with {:ok, requester} <- requester(group_id, origin),
         {:ok, at} <- parse(time),
         {:ok, settings} <- settings(group_id, requester),
         {:ok, member} <- member(settings, requester) do
      apply_time(brief, settings, member, at)
    end
  end

  def set_time(_group_id, _origin, _brief, _time), do: {:error, :invalid_request}

  @doc """
  Changes one of the requester's main channels: `follow` reads all of its
  human messages, `follow_with_bots` its bot messages too, `ignore` drops it
  from the defaults, `default` forgets the choice. `channel` is a channel id,
  a Slack channel link, a Feishu or Lark group id or link, or a name.
  Answers the requester's main channels now.
  """
  @spec set_channel(String.t(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def set_channel(group_id, origin, channel, mode)
      when is_binary(channel) and mode in @channel_modes do
    with {:ok, requester} <- requester(group_id, origin),
         {:ok, settings} <- settings(group_id, requester),
         {:ok, member} <- member(settings, requester),
         {entries, names} = scope_channels(Scope.personal(settings, member)),
         {:ok, channel_id} <- channel_id(channel, names),
         :ok <- put_choice(member, channel_id, Focus.kinds(), channel_kind(mode)) do
      focus(entries, settings, member, names)
    end
  end

  def set_channel(_group_id, _origin, _channel, _mode), do: {:error, :invalid_request}

  @doc "Adds or removes one of the requester's project terms."
  @spec set_project(String.t(), map(), String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def set_project(group_id, origin, term, mode) when is_binary(term) and mode in @project_modes do
    term = String.trim(term)

    with true <- (term != "" and String.length(term) <= 128) || {:error, :invalid_project},
         {:ok, requester} <- requester(group_id, origin),
         {:ok, settings} <- settings(group_id, requester),
         {:ok, member} <- member(settings, requester),
         :ok <-
           put_choice(member, term, ["project"], if(mode == "add", do: "project", else: nil)) do
      projects =
        Repo.all(
          from(a in DailyBriefAlias,
            where: a.member_id == ^member.id and a.kind == "project",
            order_by: a.term,
            select: a.term
          )
        )

      {:ok, %{"projects" => projects}}
    end
  end

  def set_project(_group_id, _origin, _term, _mode), do: {:error, :invalid_request}

  @doc """
  Sets or clears the requester's GitHub login: their brief then looks up the
  pull requests that login merged or closed. One login per member.
  """
  @spec set_github(String.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def set_github(group_id, origin, login) when is_binary(login) or is_nil(login) do
    login = login && login |> String.trim() |> String.trim_leading("@")

    with true <- valid_login?(login) || {:error, :invalid_github_login},
         {:ok, requester} <- requester(group_id, origin),
         {:ok, settings} <- settings(group_id, requester),
         {:ok, member} <- member(settings, requester) do
      Repo.transaction(fn ->
        Repo.delete_all(
          from(a in DailyBriefAlias, where: a.member_id == ^member.id and a.kind == "github")
        )

        if login not in [nil, ""],
          do:
            Repo.insert!(
              DailyBriefAlias.changeset(%DailyBriefAlias{}, %{
                member_id: member.id,
                term: login,
                kind: "github"
              })
            )
      end)

      {:ok, %{"github" => if(login in [nil, ""], do: nil, else: login)}}
    end
  end

  def set_github(_group_id, _origin, _login), do: {:error, :invalid_request}

  defp valid_login?(login) when login in [nil, ""], do: true
  defp valid_login?(login), do: login =~ ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/

  defp channel_kind("follow"), do: "channel"
  defp channel_kind("follow_with_bots"), do: "channel_bots"
  defp channel_kind("ignore"), do: "channel_off"
  defp channel_kind("default"), do: nil

  # One choice per term: the old one of these kinds goes, the new one (if
  # any) is written.
  defp put_choice(member, term, kinds, kind) do
    Repo.transaction(fn ->
      Repo.delete_all(
        from(a in DailyBriefAlias,
          where:
            a.member_id == ^member.id and a.kind in ^kinds and
              fragment("lower(?)", a.term) == ^String.downcase(term)
        )
      )

      with kind when is_binary(kind) <- kind,
           {:error, _changeset} <-
             %DailyBriefAlias{}
             |> DailyBriefAlias.changeset(%{member_id: member.id, term: term, kind: kind})
             |> Repo.insert() do
        Repo.rollback(:term_taken)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp channel_id(channel, names) do
    wanted = channel |> String.trim() |> String.trim_leading("#")

    id =
      case Regex.run(
             ~r/^<#([CG][A-Z0-9_]+)(?:\|[^>]*)?>$|(?:openChatId=|^)(oc_[A-Za-z0-9_]+)/,
             String.trim(channel)
           ) do
        [_, id] when id != "" -> id
        [_, _slack, id] -> id
        nil -> if Map.has_key?(names, wanted), do: wanted, else: by_name(names, wanted)
      end

    if is_binary(id) and Map.has_key?(names, id),
      do: {:ok, id},
      else: {:error, :channel_not_readable_by_the_bot}
  end

  defp by_name(names, name) do
    Enum.find_value(names, fn {id, n} ->
      if String.downcase(n) == String.downcase(name), do: id
    end)
  end

  defp scope_channels(scope) do
    {entries, names, _seen} =
      Enum.reduce(scope, {[], %{}, MapSet.new()}, fn s, {entries, names, seen} ->
        with {:ok, source} <- Members.source(s),
             {:ok, %{channels: channels} = resp} <-
               Salix.impl().daily_brief_channels(Sources.channels_request(source)) do
          fresh = Enum.reject(channels, &MapSet.member?(seen, &1.id))
          seen = Enum.reduce(fresh, seen, &MapSet.put(&2, &1.id))
          names = Enum.reduce(fresh, names, &Map.put(&2, &1.id, &1.name))
          app_id = if is_binary(resp[:app_id]), do: resp[:app_id]
          entry = %{source: source, app_id: app_id, channel_ids: Enum.map(fresh, & &1.id)}
          {entries ++ [entry], names, seen}
        else
          _unavailable -> {entries, names, seen}
        end
      end)

    {entries, names}
  end

  defp focus(entries, settings, member, names) do
    member = Repo.preload(member, :aliases, force: true)
    now = SystemsClock.utc_now()

    with {:ok, _head_source} <- Members.source(settings) do
      merged =
        Enum.reduce(entries, Focus.none(), fn %{
                                                source: source,
                                                app_id: app_id,
                                                channel_ids: ids
                                              },
                                              acc ->
          part =
            source
            |> Focus.for_members([member], ids, now, [], app_id)
            |> Map.get(member.id, Focus.none())

          %{
            humans: MapSet.union(acc.humans, part.humans),
            bots: MapSet.union(acc.bots, part.bots)
          }
        end)

      mark = if Sources.slack?(settings), do: "#", else: ""
      label = fn ids -> ids |> Enum.map(&(mark <> Map.get(names, &1, &1))) |> Enum.sort() end

      {:ok,
       %{
         "main_channels" => label.(merged.humans),
         "with_bot_messages" => label.(merged.bots)
       }}
    end
  end

  # Today's brief, if it went out, is not sent again at the new time: its
  # claim moves to today's new time, so the next one is tomorrow's.
  defp apply_time("mine", _settings, member, at) do
    now = SystemsClock.utc_now()

    claimed =
      with true <- sent_today?(member, now),
           {:ok, local} <- DateTime.shift_zone(now, member.timezone),
           {:ok, today_at} <- DateTime.new(DateTime.to_date(local), at, member.timezone) do
        [
          brief_claimed_at:
            Enum.max(
              [
                member.brief_claimed_at,
                today_at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.add(0, :microsecond)
              ],
              DateTime
            )
        ]
      else
        _not_sent -> []
      end

    with {:ok, member} <-
           member |> Ecto.Changeset.change([deliver_at: at] ++ claimed) |> Repo.update() do
      {:ok, %{"brief" => "mine", "time" => label(at), "timezone" => member.timezone}}
    end
  end

  defp apply_time("team", settings, member, at) do
    with {:ok, role} when role in ["owner", "admin"] <-
           Memberships.org_role(settings.org_id, member.user_id),
         {:ok, settings} <-
           DailyBrief.put_settings(settings.org_id, %{
             project_id: settings.project_id,
             team_post_at: at
           }) do
      zone = Compose.team_zone(Members.enabled(settings))
      {:ok, %{"brief" => "team", "time" => label(settings.team_post_at), "timezone" => zone}}
    else
      {:ok, _role} -> {:error, :owner_or_admin_required}
      {:error, %Ecto.Changeset{}} -> {:error, :daily_brief_settings_invalid}
      _other -> {:error, :owner_or_admin_required}
    end
  end

  # The same signed-origin checks as meeting preparation's personal reminders.
  defp requester(group_id, %{} = origin) do
    context = origin["provider_context"] || %{}

    with true <- origin["source_actor_type"] == "provider_user",
         true <- origin["agent_group_id"] == group_id,
         true <- is_binary(context["connect_id"]),
         {:ok, provider, user_id} <- requester_id(origin["provider"], context) do
      {:ok,
       %{
         provider: provider,
         user_id: user_id,
         connect_id: context["connect_id"],
         workspace_id: context["workspace_id"]
       }}
    else
      _other -> {:error, :daily_brief_requires_provider_request}
    end
  end

  defp requester(_group_id, _origin), do: {:error, :daily_brief_requires_provider_request}

  defp requester_id("slack", %{"user_id" => user_id}) when is_binary(user_id) do
    if Regex.match?(~r/^[UW][A-Z0-9]+$/, user_id), do: {:ok, "slack", user_id}, else: :error
  end

  # A Feishu or Lark message names its sender by the app's open id.
  defp requester_id(provider, context) when provider in ["feishu", "lark"] do
    user_id = context["sender_open_id"] || context["from_user_id"] || context["user_id"]

    if is_binary(user_id) and Regex.match?(~r/^ou_[A-Za-z0-9_-]{2,64}$/, user_id),
      do: {:ok, provider, user_id},
      else: :error
  end

  defp requester_id(_provider, _context), do: :error

  defp parse(time) when is_binary(time) do
    case Regex.run(~r/^([01]\d|2[0-3]):([0-5]\d)$/, String.trim(time), capture: :all_but_first) do
      [h, m] -> Time.new(String.to_integer(h), String.to_integer(m), 0)
      nil -> {:error, :invalid_time}
    end
  end

  defp parse(_time), do: {:error, :invalid_time}

  # Only through a bot of a Swarm with daily brief settings.
  defp settings(group_id, %{provider: "slack", connect_id: connect_id}) do
    one_setting(
      from(s in DailyBriefSetting,
        join: p in Project,
        on: p.id == s.project_id and p.org_id == s.org_id,
        where:
          p.salix_group_id == ^group_id and s.provider == "slack" and
            s.slack_connect_id == ^connect_id,
        select: s
      )
    )
  end

  defp settings(group_id, %{provider: provider, connect_id: connect_id}) do
    one_setting(
      from(s in DailyBriefSetting,
        join: p in Project,
        on: p.id == s.project_id and p.org_id == s.org_id,
        where:
          p.salix_group_id == ^group_id and s.provider == ^provider and
            s.connect_id == ^connect_id,
        select: s
      )
    )
  end

  defp one_setting(query) do
    case Repo.one(query) do
      %DailyBriefSetting{} = settings -> {:ok, settings}
      nil -> {:error, :daily_brief_not_set_up}
    end
  end

  # The Slack workspace owns the user id: both must match an enabled member.
  # A Feishu or Lark open id is the app's whose bot took the message: the
  # member's own, or one of their open ids in the other Swarms' apps, so a
  # member changes their one brief through any Swarm's bot.
  defp member(settings, %{provider: "slack"} = requester) do
    one_member(
      from(m in DailyBriefMember,
        where:
          m.org_id == ^settings.org_id and m.provider == "slack" and m.enabled and
            m.slack_user_id == ^requester.user_id and
            m.slack_workspace_id == ^requester.workspace_id
      )
    )
  end

  defp member(settings, %{provider: provider} = requester) do
    one_member(
      from(m in DailyBriefMember,
        where:
          m.org_id == ^settings.org_id and m.provider == ^provider and m.enabled and
            (m.open_id == ^requester.user_id or
               fragment(
                 "EXISTS (SELECT 1 FROM jsonb_each_text(?) e WHERE e.value = ?)",
                 m.app_open_ids,
                 ^requester.user_id
               ))
      )
    )
  end

  defp one_member(query) do
    case Repo.one(query) do
      %DailyBriefMember{} = member -> {:ok, member}
      nil -> {:error, :not_a_brief_member}
    end
  end

  defp label(%Time{} = at), do: Calendar.strftime(at, "%H:%M")

  defp sent_today?(%DailyBriefMember{brief_claimed_at: %DateTime{} = claimed} = member, now) do
    with {:ok, local} <- DateTime.shift_zone(now, member.timezone),
         {:ok, claimed_local} <- DateTime.shift_zone(claimed, member.timezone) do
      DateTime.to_date(local) == DateTime.to_date(claimed_local)
    else
      _invalid_zone -> false
    end
  end

  defp sent_today?(_member, _now), do: false
end
