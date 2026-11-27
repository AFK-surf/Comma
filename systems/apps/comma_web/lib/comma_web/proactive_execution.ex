defmodule CommaWeb.ProactiveExecution do
  @moduledoc """
  Zero-cost, read-only execution target resolver attached at proactive handoff.

  When `CommaWeb.ProactiveCheck` routes an `interrupt`, `ask`, or `signal`
  matter into Home, `resolve/5` inspects only local indexed state (zero network
  calls, zero LLM calls) to ground concrete next-step execution targets:

  - GitHub repository / pull request parsed from verified URLs in the item,
    `linked`, or `research` (`runs_on: %{"kind" => "sandbox"}, repo: ...`)
  - Matching active owner `still.fail` station chats from
    `SalixStore.StationTaskIndex` (`im_api.internal.send_message` to
    `station:<station_id>:<thread>`)
  - Currently connected `still.fail` stations from `SalixEnv.StillfailDevices`
    (`runs_on: %{"kind" => "station", "device_id" => ...}`)
  - Actionability gating (`actionable: false` for read-only FYIs/praise; `nil`
    for login/OTP verification codes) so the Home Router attaches a native
    one-tap `ConversationQuestion` card only when a real next step exists,
    while preserving the `proactive_handoff` delegation invariant (the owner's
    click supplies `source_message_id`).
  """

  alias CommaWeb.{MemberPortrait, ProactiveOwner, ProactiveResearch}
  alias SalixIM.Ports.StationHostedTasks

  @max_station_tasks 2
  @max_connected_stations 3
  @max_suggestions 3
  @station_read_limit 100
  @empty_costs MapSet.new(["", "none", "n/a", "na", "null", "nil", "无", "没有", "暂无", "-"])

  @non_repo_github_owners ~w(
    about account apps collections contact customer-stories enterprise explore
    features issues login marketplace notifications orgs pricing pulls search
    security sessions settings signup site sponsors topics trending users
  )

  @github_ident_re ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/
  @https_url_re ~r/https:\/\/[^\s<>\]\)"'）】，。；、|]+/u
  @explicit_repo_re ~r/(?:^|[^\p{L}\p{N}_\/-])([a-z0-9][a-z0-9._-]{0,99})\/([a-z0-9][a-z0-9._-]{0,99})(?:$|[^\p{L}\p{N}_\/-])/u

  @doc """
  Resolves bounded local execution targets for a routed proactive matter.
  Returns `nil` for verification codes, non-actionable FYIs, or when no
  grounded target applies.
  """
  def resolve(workspace, group_id, owner_user_id, item, evidence \\ %{})
      when is_binary(group_id) and is_binary(owner_user_id) and is_map(item) and is_map(evidence) do
    if not actionable?(item) do
      nil
    else
      portrait_repos =
        if is_map(workspace) do
          workspace
          |> MemberPortrait.statements()
          |> MemberPortrait.targets()
          |> Map.get("repos", [])
        else
          []
        end

      env = %{
        station_rows: list_station_rows(group_id),
        stations: list_stillfail_stations(group_id),
        owner_email: ProactiveOwner.owner_email(owner_user_id),
        device_owner_emails:
          ProactiveOwner.device_owner_emails(group_id, owner_user_id, workspace),
        portrait_repos: portrait_repos
      }

      build(item, evidence, env)
    end
  rescue
    _ -> nil
  end

  @doc """
  Pure execution target builder over explicit `item`, `evidence`, and `env`
  (`:station_rows`, `:stations`, `:owner_email`, `:device_owner_emails`,
  `:portrait_repos`).
  """
  def build(item, evidence \\ %{}, env \\ %{})
      when is_map(item) and is_map(evidence) and is_map(env) do
    if not actionable?(item) do
      nil
    else
      stations = List.wrap(env[:stations] || env["stations"] || [])
      station_rows = List.wrap(env[:station_rows] || env["station_rows"] || [])
      owner_email = ProactiveOwner.normalize_email(env[:owner_email] || env["owner_email"])
      device_emails = env[:device_owner_emails] || env["device_owner_emails"] || %{}
      portrait_repos = List.wrap(env[:portrait_repos] || env["portrait_repos"] || [])

      connected = connected_stations(stations)
      connected_ids = MapSet.new(connected, & &1["device_id"])
      station_names = station_name_map(stations)
      github_repo = extract_github_target(item, evidence, portrait_repos)

      matched_tasks =
        match_station_tasks(
          item,
          evidence,
          github_repo,
          station_rows,
          owner_email,
          device_emails,
          connected_ids,
          station_names
        )

      suggestions = build_suggestions(item, github_repo, matched_tasks, connected)

      if is_nil(github_repo) and matched_tasks == [] and connected == [] and suggestions == [] do
        nil
      else
        %{
          "actionable" => true,
          "github_repo" => github_repo,
          "station_tasks" => matched_tasks,
          "connected_stations" => connected,
          "suggested_actions" => Enum.take(suggestions, @max_suggestions)
        }
        |> Enum.reject(fn {k, v} -> k != "actionable" and v in [nil, []] end)
        |> Map.new()
      end
    end
  end

  @doc """
  Extracts the primary GitHub `{owner, name, pull_request?}` target only from
  canonical item URLs, structured GitHub-linked evidence, structured GitHub
  research pool items, or URLs matching portrait-watched `repo:owner/name`
  targets (never arbitrary third-party body links).
  """
  def extract_github_target(item, evidence \\ %{}, portrait_repos \\ [])
      when is_map(item) and is_map(evidence) do
    canonical_urls =
      [item["url"]]
      |> Enum.filter(&is_binary/1)
      |> Kernel.++(structured_github_urls(evidence["linked"]))
      |> Kernel.++(structured_github_urls(evidence["linked_after_screening"]))
      |> Kernel.++(research_github_urls(evidence["research"]))

    watched_set =
      portrait_repos
      |> List.wrap()
      |> Enum.filter(&is_binary/1)
      |> MapSet.new(&String.downcase/1)

    watched_urls =
      if MapSet.size(watched_set) > 0 do
        ([item["excerpt"], get_in(item, ["context", "text"])] ++
           List.wrap(evidence["linked"]))
        |> collect_urls()
        |> Enum.filter(fn url ->
          case parse_github_url(url) do
            [%{"owner" => o, "name" => n}] ->
              MapSet.member?(watched_set, String.downcase("#{o}/#{n}"))

            _ ->
              false
          end
        end)
      else
        []
      end

    parsed =
      (canonical_urls ++ watched_urls)
      |> Enum.uniq()
      |> Enum.flat_map(&parse_github_url/1)

    Enum.find(parsed, &Map.has_key?(&1, "pull_request")) || List.first(parsed)
  end

  @doc "Whether a routed proactive matter warrants a one-tap execution confirmation card."
  def actionable?(item) when is_map(item) do
    decision = item["decision"]
    role = item["role"] || get_in(item, ["assessment", "role"])
    cost = normalized_cost(get_in(item, ["assessment", "cost"]))
    relationship = item["relationship"]

    cond do
      code?(item) ->
        false

      decision in ~w(interrupt ask) ->
        true

      decision == "signal" ->
        cond do
          relationship == "upcoming_meeting_prep" -> true
          relationship == "mentions_your_work" or role == "someday" -> false
          true -> role in ~w(act calendar) or cost != ""
        end

      true ->
        false
    end
  end

  defp normalized_cost(value) do
    trimmed = value |> to_string() |> String.trim()
    if MapSet.member?(@empty_costs, String.downcase(trimmed)), do: "", else: trimmed
  end

  defp code?(item), do: get_in(item, ["assessment", "code"]) == true

  defp build_suggestions(item, github_repo, matched_tasks, connected_stations) do
    connected_matches = Enum.filter(matched_tasks, &(&1["connected"] == true))

    continue_opts =
      connected_matches
      |> Enum.take(1)
      |> Enum.map(fn task ->
        %{
          "kind" => "continue_station_task",
          "tool" => "im_api.internal.send_message",
          "conversation_id" => task["task_id"],
          "title" => task["title"],
          "station" => task["station"]
        }
      end)

    sandbox_opts =
      if is_map(github_repo) do
        kind =
          if Map.has_key?(github_repo, "pull_request"), do: "sandbox_pr", else: "sandbox_repo"

        [
          %{
            "kind" => kind,
            "tool" => "im_api.internal.task.create",
            "runs_on" => %{"kind" => "sandbox"},
            "repo" => github_repo
          }
        ]
      else
        []
      end

    coding_like? =
      is_map(github_repo) or item["toolkit"] in ~w(github linear) or
        item["app"] in ~w(GitHub Linear)

    new_station_opts =
      if connected_matches == [] and connected_stations != [] and coding_like? do
        primary = hd(connected_stations)

        [
          %{
            "kind" => "new_station_task",
            "tool" => "im_api.internal.task.create",
            "runs_on" => %{"kind" => "station", "device_id" => primary["device_id"]},
            "station" => primary["name"]
          }
        ]
      else
        []
      end

    draft_opts =
      if continue_opts == [] and sandbox_opts == [] do
        [
          %{
            "kind" => "draft_task",
            "tool" => "proactive.act",
            "action" => "draft"
          }
        ]
      else
        []
      end

    Enum.take(continue_opts ++ sandbox_opts ++ new_station_opts ++ draft_opts, @max_suggestions)
  end

  defp match_station_tasks(
         item,
         evidence,
         github_repo,
         rows,
         owner_email,
         device_emails,
         connected_ids,
         station_names
       ) do
    matter_text = matter_match_text(item, evidence)
    matter_tokens = MapSet.new(ProactiveResearch.tokens(matter_text))

    full_repo =
      if is_map(github_repo),
        do: String.downcase("#{github_repo["owner"]}/#{github_repo["name"]}"),
        else: nil

    repo_name = if is_map(github_repo), do: String.downcase(github_repo["name"]), else: nil

    pr_str =
      if is_map(github_repo) and github_repo["pull_request"],
        do: "#{github_repo["pull_request"]}",
        else: nil

    rows
    |> Enum.filter(&active_owner_row?(&1, owner_email, device_emails))
    |> Enum.flat_map(fn row ->
      station_id = field(row, :station_id, "station_id")
      thread = field(row, :thread, "thread")
      title = to_string(field(row, :title, "title") || "")
      note = to_string(field(row, :note, "note") || "")
      device_id = field(row, :device_id, "device_id")

      if is_binary(station_id) and station_id != "" and is_binary(thread) and thread != "" do
        haystack = String.downcase(title <> "\n" <> note)

        if conflicting_repo_owner?(haystack, github_repo) do
          []
        else
          row_tokens = MapSet.new(ProactiveResearch.tokens(haystack))
          overlap = MapSet.intersection(matter_tokens, row_tokens) |> MapSet.to_list()
          hits = length(overlap)

          token_score =
            Enum.reduce(overlap, 0, fn tok, acc ->
              acc + if(String.length(tok) >= 4, do: 3, else: 2)
            end)

          exact_repo_match? = is_binary(full_repo) and String.contains?(haystack, full_repo)

          bare_repo_match? =
            not exact_repo_match? and is_binary(repo_name) and String.length(repo_name) >= 5 and
              Regex.match?(
                ~r/(?:^|[^\p{L}\p{N}_\/-])#{Regex.escape(repo_name)}(?:$|[^\p{L}\p{N}_\/-])/u,
                haystack
              )

          repo_bonus =
            cond do
              exact_repo_match? -> 8
              bare_repo_match? -> 6
              true -> 0
            end

          pr_bonus =
            if repo_bonus > 0 and is_binary(pr_str) and
                 Regex.match?(~r/(?:^|[^\d])#?#{Regex.escape(pr_str)}(?:[^\d]|$)/, haystack),
               do: 8,
               else: 0

          total_score = token_score + repo_bonus + pr_bonus

          matched? =
            cond do
              is_map(github_repo) ->
                (exact_repo_match? and (pr_bonus > 0 or hits >= 1)) or
                  (bare_repo_match? and (pr_bonus > 0 or hits >= 2))

              true ->
                hits >= 2 and token_score >= 6
            end

          if matched? do
            connected? = is_binary(device_id) and MapSet.member?(connected_ids, device_id)
            activity = field(row, :last_activity_at, "last_activity_at") || 0

            [
              {
                {connected?, total_score, activity},
                %{
                  "task_id" => StationHostedTasks.ref(station_id, thread),
                  "title" => String.slice(String.trim(title), 0, 120),
                  "status" => field(row, :status, "status"),
                  "station" => Map.get(station_names, device_id) || station_id,
                  "device_id" => device_id,
                  "connected" => connected?,
                  "url" => field(row, :url, "url")
                }
                |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
                |> Map.new()
              }
            ]
          else
            []
          end
        end
      else
        []
      end
    end)
    |> Enum.sort_by(fn {{connected?, score, activity}, _map} ->
      {if(connected?, do: 0, else: 1), -score, -activity}
    end)
    |> Enum.take(@max_station_tasks)
    |> Enum.map(&elem(&1, 1))
  end

  defp active_owner_row?(row, owner_email, device_emails) do
    status = field(row, :status, "status")

    status in ~w(in_progress needs_review) and
      ProactiveOwner.station_row_owned_by?(row, owner_email, device_emails)
  end

  defp connected_stations(stations) do
    stations
    |> Enum.filter(&(field(&1, :connected, "connected") == true))
    |> Enum.flat_map(fn station ->
      device_id = field(station, :id, "id") || field(station, :device_id, "device_id")

      if is_binary(device_id) and device_id != "" do
        ws = field(station, :workspace, "workspace") || %{}

        name =
          field(station, :name, "name") || field(ws, :station, "station") || device_id

        workspace_name = field(ws, :name, "name")

        [
          %{
            "device_id" => device_id,
            "name" => String.slice(to_string(name), 0, 80),
            "workspace" =>
              if(is_binary(workspace_name) and workspace_name != "",
                do: String.slice(workspace_name, 0, 80)
              )
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()
        ]
      else
        []
      end
    end)
    |> Enum.uniq_by(& &1["device_id"])
    |> Enum.take(@max_connected_stations)
  end

  defp station_name_map(stations) do
    Enum.reduce(stations, %{}, fn station, acc ->
      device_id = field(station, :id, "id") || field(station, :device_id, "device_id")
      ws = field(station, :workspace, "workspace") || %{}
      name = field(station, :name, "name") || field(ws, :station, "station")

      if is_binary(device_id) and is_binary(name) and name != "",
        do: Map.put(acc, device_id, String.slice(name, 0, 80)),
        else: acc
    end)
  end

  defp matter_match_text(item, evidence) do
    parts = [
      item["title"],
      item["excerpt"],
      get_in(item, ["context", "text"]),
      get_in(item, ["context", "watchedTerm"]),
      item["url"],
      inspect_urls_text(evidence["linked"]),
      inspect_urls_text(evidence["research"])
    ]

    parts
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("\n")
  end

  defp inspect_urls_text(list) when is_list(list) do
    list
    |> Enum.flat_map(fn
      %{"title" => t, "url" => u} -> [t, u]
      %{"url" => u} -> [u]
      %{"matches" => matches} when is_list(matches) -> [inspect_urls_text(matches)]
      _ -> []
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp inspect_urls_text(_other), do: ""

  defp structured_github_urls(list) when is_list(list) do
    for %{"kind" => kind, "url" => url} <- list,
        kind in ~w(github_pull_request github_issue github_actions_run),
        is_binary(url),
        do: url
  end

  defp structured_github_urls(_other), do: []

  defp research_github_urls(list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"matches" => matches} when is_list(matches) ->
        for %{"app" => app, "url" => url} <- matches,
            is_binary(app) and String.downcase(app) == "github",
            is_binary(url),
            do: url

      _ ->
        []
    end)
  end

  defp research_github_urls(_other), do: []

  defp conflicting_repo_owner?(haystack, %{"owner" => owner, "name" => name})
       when is_binary(haystack) and is_binary(owner) and is_binary(name) do
    owner_down = String.downcase(owner)
    name_down = String.downcase(name)

    @explicit_repo_re
    |> Regex.scan(haystack)
    |> Enum.any?(fn
      [_, found_owner, found_name] ->
        String.downcase(found_name) == name_down and String.downcase(found_owner) != owner_down

      _ ->
        false
    end)
  end

  defp conflicting_repo_owner?(_haystack, _github_repo), do: false

  defp collect_urls(value) when is_binary(value) do
    @https_url_re
    |> Regex.scan(value)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, ".,;:!?)]}'\""))
  end

  defp collect_urls(value) when is_list(value), do: Enum.flat_map(value, &collect_urls/1)

  defp collect_urls(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&collect_urls/1)
  end

  defp collect_urls(_value), do: []

  # Strict URI-parsed canonical GitHub URL grammar: requires exact `https://github.com`
  # host with no userinfo and canonical `/owner/repo`, `/owner/repo/pull/:n`, or
  # `/owner/repo/issues/:n` path segments so non-GitHub redirect URLs or malformed
  # suffixes are never parsed as execution targets.
  defp parse_github_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    with %URI{scheme: "https", userinfo: userinfo, host: host, port: port, path: path} <-
           URI.parse(trimmed),
         true <- userinfo in [nil, ""] and port in [nil, 443] and is_binary(host),
         "github.com" <- host |> String.downcase() |> String.trim_trailing("."),
         true <- is_binary(path) and not String.contains?(path, "//"),
         segments <- String.split(path, "/", trim: true),
         {:ok, target} <- parse_github_segments(segments) do
      [target]
    else
      _ -> []
    end
  end

  defp parse_github_url(_url), do: []

  defp parse_github_segments([owner, raw_name]) do
    build_github_target(owner, raw_name, nil)
  end

  defp parse_github_segments([owner, raw_name, "pull", num]) do
    parse_github_pr(owner, raw_name, num)
  end

  defp parse_github_segments([owner, raw_name, "pull", num, sub])
       when sub in ~w(files commits checks) do
    parse_github_pr(owner, raw_name, num)
  end

  defp parse_github_segments([owner, raw_name, "issues", num]) do
    if Regex.match?(~r/^\d+$/, num) do
      build_github_target(owner, raw_name, nil)
    else
      :error
    end
  end

  defp parse_github_segments(_segments), do: :error

  defp parse_github_pr(owner, raw_name, num) do
    if Regex.match?(~r/^\d+$/, num) do
      case Integer.parse(num) do
        {pr, ""} when pr > 0 -> build_github_target(owner, raw_name, pr)
        _ -> :error
      end
    else
      :error
    end
  end

  defp build_github_target(owner, raw_name, pr) do
    name = String.trim_trailing(raw_name, ".git")

    if valid_github_ident?(owner) and valid_github_ident?(name) and
         String.downcase(owner) not in @non_repo_github_owners do
      base = %{"owner" => owner, "name" => name}
      {:ok, if(is_integer(pr), do: Map.put(base, "pull_request", pr), else: base)}
    else
      :error
    end
  end

  defp valid_github_ident?(seg) when is_binary(seg) do
    seg not in [".", ".."] and Regex.match?(@github_ident_re, seg)
  end

  defp list_station_rows(group_id) do
    SalixStore.StationTaskIndex.list_group(group_id, @station_read_limit)
  rescue
    _ -> []
  end

  defp list_stillfail_stations(group_id) do
    case SalixEnv.StillfailDevices.first_page(group_id) do
      {:ok, stations, _more?} when is_list(stations) -> stations
      _ -> []
    end
  rescue
    _ -> []
  end

  defp field(map, atom_key, string_key) when is_map(map) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end
end
