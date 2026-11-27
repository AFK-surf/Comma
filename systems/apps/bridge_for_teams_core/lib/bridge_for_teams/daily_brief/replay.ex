defmodule BridgeForTeams.DailyBrief.Replay do
  @moduledoc """
  Replays recorded personal daily brief cases through the production
  `Classifier`, `Compose` and `SalixStore.ProactiveKernel` pipeline without
  PostgreSQL, Slack or Salix RPC.

  A case map (or JSON file) supplies the member's Slack identity, aliases and
  focus channels, the window's channel and direct/shared messages, earlier
  follow-ups, closed tombstones, known issue URLs and states, and optional
  declarative `expect` checks.
  """

  alias BridgeForTeams.DailyBrief.{Classifier, Compose, Focus}
  alias BridgeForTeams.Schema.{DailyBriefAlias, DailyBriefMember, DailyBriefSetting}

  @doc "Loads a JSON case file from `path`."
  def load!(path) do
    path |> File.read!() |> Jason.decode!() |> Map.put("path", path)
  end

  @doc """
  Runs every scenario of `kase` with `judge`, a function `fn %{view: view, input: input} -> {:ok, text} | {:error, reason} end`.
  Returns one report map per scenario.
  """
  def run(kase, judge) when is_map(kase) and is_function(judge, 1) do
    scenarios = kase["scenarios"] || [%{"name" => "as_is"}]
    Enum.map(scenarios, &run_scenario(kase, &1, judge))
  end

  defp run_scenario(kase, scenario, judge) do
    merged = Map.merge(kase, Map.drop(scenario, ["name", "expect"]))
    {:ok, now, _} = DateTime.from_iso8601(merged["now"])
    {:ok, window_after, _} = DateTime.from_iso8601(merged["window_after"])
    window = %{after: window_after, before: now}

    member = build_member(merged["member"] || %{})
    settings = build_settings(merged["settings"] || %{})
    shared = build_shared(merged, member, window)

    salix_state = %{
      issue_states: merged["issue_states"] || %{},
      user_names: merged["user_names"] || %{},
      thread_roots: merged["thread_roots"] || %{}
    }

    previous_salix = SystemsRuntime.get_env(:bridge_for_teams_core, :salix_client)
    Process.put(:daily_brief_replay_judge, judge)
    Process.put(:daily_brief_replay_salix, salix_state)
    Process.put(:daily_brief_replay_inputs, %{})

    result =
      try do
        SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, __MODULE__.SalixStub)

        Compose.write(
          %{
            settings: settings,
            member: member,
            shared: shared,
            team_brief: merged["team_brief"],
            previous: merged["previous_brief"],
            followups: merged["followups"] || [],
            closed: merged["closed"] || [],
            issues: merged["issues"] || %{},
            github: get_in(merged, ["member", "github"]),
            now: now
          },
          model: __MODULE__.ModelStub,
          agent_id: "replay-agent",
          members: [member]
        )
      after
        if is_nil(previous_salix),
          do: SystemsRuntime.delete_env(:bridge_for_teams_core, :salix_client),
          else: SystemsRuntime.put_env(:bridge_for_teams_core, :salix_client, previous_salix)

        Process.delete(:daily_brief_replay_judge)
        Process.delete(:daily_brief_replay_salix)
      end

    captured = Process.delete(:daily_brief_replay_inputs) || %{}
    expect = Map.merge(kase["expect"] || %{}, scenario["expect"] || %{})

    case result do
      {:ok, written} ->
        report = %{
          "scenario" => scenario["name"] || "as_is",
          "text" => written.text,
          "mine" => written.mine,
          "issues" => written.issues,
          "item_count" =>
            length(
              get_in(captured, [:mine, "items"]) || get_in(captured, [:brief, "items"]) || []
            )
        }

        Map.put(report, "checks", evaluate_checks(expect, report))

      {:error, reason, _usage} ->
        report = %{"scenario" => scenario["name"] || "as_is", "error" => inspect(reason)}
        Map.put(report, "checks", evaluate_checks(expect, report))
    end
  end

  defp build_settings(raw) do
    %DailyBriefSetting{
      id: "00000000-0000-0000-0000-000000000001",
      org_id: nil,
      project_id: nil,
      slack_connect_id: raw["slack_connect_id"] || "imc_replay",
      enabled: true,
      team_names: raw["team_names"] || "shown"
    }
  end

  defp build_member(raw) do
    aliases =
      for entry <- raw["aliases"] || [] do
        %DailyBriefAlias{kind: entry["kind"] || "name", term: entry["term"] || ""}
      end

    focus_aliases =
      for ch <- raw["focus_channels"] || [] do
        %DailyBriefAlias{kind: "channel", term: ch}
      end

    bot_aliases =
      for ch <- raw["bot_channels"] || [] do
        %DailyBriefAlias{kind: "channel_bots", term: ch}
      end

    %DailyBriefMember{
      id: raw["id"] || "00000000-0000-0000-0000-000000000010",
      org_id: "00000000-0000-0000-0000-000000000002",
      user_id: "00000000-0000-0000-0000-000000000011",
      slack_workspace_id: raw["slack_workspace_id"] || "T_REPLAY",
      slack_user_id: raw["slack_user_id"] || "U_OWNER",
      timezone: raw["timezone"] || "Asia/Shanghai",
      dm_status: if((raw["direct_messages"] || "on") == "on", do: "on", else: "off"),
      aliases: aliases ++ focus_aliases ++ bot_aliases
    }
  end

  defp build_shared(merged, member, window) do
    channel_names = merged["channels"] || %{}
    readable = Map.keys(channel_names)

    public_messages = Enum.map(merged["messages"] || [], &normalize_message/1)
    dm_messages = Enum.map(merged["direct_messages"] || [], &normalize_direct_message/1)

    window_counts =
      public_messages
      |> Enum.filter(&(&1.actor_kind == "user" and &1.actor_id == member.slack_user_id))
      |> Enum.frequencies_by(& &1.channel_id)

    focus = Focus.of(member, [], MapSet.new(readable), window_counts)

    wrote_threads =
      for m <- public_messages,
          m.actor_id == member.slack_user_id,
          do: %{channel_id: m.channel_id, thread_ts: m.thread_ts || m.ts}

    extra_threads =
      for entry <- merged["member_threads"] || [] do
        %{channel_id: entry["channel_id"], thread_ts: entry["thread_ts"]}
      end

    aliases = Enum.map(member.aliases, &%{term: &1.term, kind: &1.kind})

    matcher =
      Classifier.member(
        member.slack_user_id,
        aliases,
        Enum.uniq(wrote_threads ++ extra_threads),
        focus
      )

    relevant_public =
      for message <- public_messages,
          reasons = Classifier.reasons(message, matcher),
          tier = Classifier.tier(reasons),
          not is_nil(tier),
          do: %{message: message, reasons: reasons, tier: tier}

    relevant_dm =
      for message <- dm_messages,
          do: %{message: message, reasons: [:direct], tier: :p0}

    dm_channel_names =
      for %{kind: "shared", channel_name: name, channel_id: id} <- dm_messages,
          is_binary(name),
          into: %{},
          do: {id, name}

    %{
      window: window,
      messages: public_messages ++ dm_messages,
      relevant: %{member.id => relevant_public ++ relevant_dm},
      channel_names: Map.merge(dm_channel_names, channel_names),
      coverage: %{
        channels_read: map_size(channel_names),
        channels_total: map_size(channel_names),
        channel_list_complete?: true,
        failed: [],
        truncated: [],
        threads_complete: %{member.id => true}
      }
    }
  end

  defp normalize_message(raw) do
    %{
      channel_id: raw["channel_id"],
      ts: raw["ts"],
      thread_ts: raw["thread_ts"],
      actor_kind: raw["actor_kind"] || if(raw["bot"], do: "bot", else: "user"),
      actor_id: raw["actor_id"] || raw["user"],
      subtype: raw["subtype"],
      text: raw["text"] || "",
      permalink: raw["permalink"],
      reactions: normalize_reactions(raw["reactions"])
    }
  end

  defp normalize_direct_message(raw) do
    raw
    |> normalize_message()
    |> Map.put(:kind, raw["kind"] || "im")
    |> Map.put(:channel_name, raw["channel_name"])
  end

  defp normalize_reactions(list) when is_list(list) do
    Enum.map(list, fn r ->
      %{name: r["name"] || r[:name], users: List.wrap(r["users"] || r[:users])}
    end)
  end

  defp normalize_reactions(_other), do: []

  defp evaluate_checks(expect, report) do
    mine = report["mine"] || []
    open_whats = for e <- mine, not String.starts_with?(e["status"] || "", "done"), do: e["what"]
    all_whats = Enum.map(mine, & &1["what"])

    must_open =
      for term <- expect["mine_open_contains"] || [] do
        %{
          "check" => "mine_open_contains:#{term}",
          "pass" => Enum.any?(open_whats, &String.contains?(&1 || "", term))
        }
      end

    forbid_open =
      for term <- expect["mine_open_excludes"] || [] do
        %{
          "check" => "mine_open_excludes:#{term}",
          "pass" => not Enum.any?(open_whats, &String.contains?(&1 || "", term))
        }
      end

    must_present =
      for term <- expect["mine_contains"] || [] do
        %{
          "check" => "mine_contains:#{term}",
          "pass" => Enum.any?(all_whats, &String.contains?(&1 || "", term))
        }
      end

    text_checks =
      for term <- expect["text_contains"] || [] do
        %{
          "check" => "text_contains:#{term}",
          "pass" => String.contains?(report["text"] || "", term)
        }
      end

    must_open ++ forbid_open ++ must_present ++ text_checks
  end

  defmodule ModelStub do
    @moduledoc false

    def compose(request) do
      view = Map.get(request, :view, :brief)
      inputs = Process.get(:daily_brief_replay_inputs) || %{}
      Process.put(:daily_brief_replay_inputs, Map.put(inputs, view, request.input))
      judge = Process.get(:daily_brief_replay_judge)

      case judge.(%{view: view, input: request.input}) do
        {:ok, text} when is_binary(text) ->
          {:ok, %{text: text, usage: %{input_tokens: 1, output_tokens: 1}}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defmodule SalixStub do
    @moduledoc false

    def daily_brief_messages(%{channel_id: channel, ts: ts_list}) do
      state = Process.get(:daily_brief_replay_salix) || %{}
      roots = state.thread_roots || %{}

      messages =
        for ts <- ts_list,
            raw = get_in(roots, [channel, ts]),
            is_map(raw) do
          %{
            channel_id: channel,
            ts: ts,
            thread_ts: ts,
            actor_kind: raw["actor_kind"] || "user",
            actor_id: raw["actor_id"] || "U_OTHER",
            subtype: nil,
            text: raw["text"] || ""
          }
        end

      {:ok, %{messages: messages}}
    end

    def daily_brief_user_names(_request) do
      state = Process.get(:daily_brief_replay_salix) || %{}
      {:ok, state.user_names || %{}}
    end

    def daily_brief_issue_states(%{issues: issues}) do
      state = Process.get(:daily_brief_replay_salix) || %{}
      known = state.issue_states || %{}

      found =
        for %{repo: repo, number: number} <- issues,
            status = known["#{repo}##{number}"] || known["##{number}"] || known[number],
            is_binary(status),
            into: %{},
            do: {"#{repo}##{number}", status}

      {:ok, found}
    end

    def daily_brief_member_pulls(_request), do: {:ok, []}
    def daily_brief_member_login(_request), do: {:ok, nil}
    def daily_brief_message_links(_request), do: {:ok, %{}}
  end
end
