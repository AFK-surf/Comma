defmodule CommaWeb.ProactiveWebRadar do
  @moduledoc """
  Low-frequency public web entity mention radar.

  Runs at most once every 6 hours per personal Workspace when automatic messages
  are enabled, Exa search is configured, and the owner's portrait declares
  distinctive product/project watch terms (`term:<name>`).

  Searches up to 3 watched terms over the last 48 hours of published web pages,
  keeps only public HTTPS results that literally mention the watched term and
  have not already been handed over, and routes surviving candidates through
  `CommaWeb.ProactiveCheck.screen_external/6` under the strict `signal` cap
  (at most 2 notifications per 24 hours).
  """
  use Oban.Worker,
    queue: :comma_external,
    max_attempts: 2,
    unique: [
      period: 21_600,
      fields: [:worker, :args],
      states: [
        :available,
        :scheduled,
        :executing,
        :retryable,
        :suspended,
        :completed,
        :cancelled,
        :discarded
      ]
    ]

  require Logger
  alias Comma.Data.RecommendationProfile
  alias Comma.Repo
  alias CommaWeb.{HomeMail, MemberPortrait, Proactive, ProactiveCheck, ProactiveEvidence}
  alias SalixAgent.BillingAvailability
  alias SalixAgent.Tools.Web
  alias SalixIM.{Conversations, MailInteraction}

  @max_terms 3
  @max_candidates 3
  @published_window_s 48 * 3_600
  @seen_ttl_s 72 * 3_600
  @seen_redis Comma.MiniApps.RateLimit.Redis

  @doc "Queues a 6-hourly public web mention sweep for `profile` when enabled."
  def enqueue(%RecommendationProfile{} = profile) do
    if enabled?() do
      %{"profile_id" => profile.id} |> new() |> then(&Oban.insert(Comma.Oban, &1))
    else
      {:ok, :skipped}
    end
  end

  @impl Oban.Worker
  def timeout(_job), do: 180_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"profile_id" => profile_id}}) do
    Logger.metadata(profile_id: profile_id)

    with true <- enabled?(),
         %RecommendationProfile{} = profile <- Repo.get(RecommendationProfile, profile_id),
         {:ok, %{"status" => "active"} = user} <- Comma.Accounts.get_user(profile.user_id),
         {:ok, workspace} <- Comma.Workspaces.authorize(user, %{}, profile.workspace_id),
         true <- workspace["owner_user_id"] == profile.user_id,
         true <- personal?(workspace, profile.user_id),
         {:ok, true} <- Proactive.automatic?(workspace["default_group_id"], profile.user_id),
         {:ok, workspace, ctx, home} <-
           HomeMail.context(user, %{}, workspace["default_group_id"]),
         {:ok, conversation} <- Conversations.get_group_conversation_record(ctx.group_id, home) do
      now = SystemsClock.utc_now()
      now_ms = DateTime.to_unix(now, :millisecond)
      statements = MemberPortrait.statements(workspace)

      terms =
        statements |> MemberPortrait.web_radar_terms() |> Enum.take(@max_terms)

      if terms == [] do
        :ok
      else
        since_iso = now |> DateTime.add(-@published_window_s, :second) |> DateTime.to_iso8601()
        routed = MailInteraction.entries(conversation)
        term_contexts = MemberPortrait.term_contexts(statements)

        search_fun = fn term ->
          query = search_query(term, Map.get(term_contexts, String.downcase(term), []))

          Web.search(query,
            start_published_date: since_iso,
            receive_timeout: 8_000,
            retry: false
          )
        end

        seen_pred = fn url -> already_seen?(routed, url) or seen?(profile.id, url) end

        case collect_candidates(terms, search_fun, now, seen_pred) do
          {:ok, []} ->
            :ok

          {:ok, raw_hits} ->
            hits = Enum.map(raw_hits, &Map.put(&1, "profile_id", profile.id))

            case ProactiveCheck.screen_external(workspace, ctx, home, profile, hits, now_ms) do
              {:ok, outcome} ->
                Logger.info("proactive_web_radar outcome=#{outcome} hits=#{length(hits)}")
                :ok

              {:error, reason} ->
                Logger.warning("proactive_web_radar failed reason=#{inspect(reason, limit: 3)}")
                if billing_denied?(reason), do: {:cancel, reason}, else: {:error, reason}
            end

          {:error, reason} ->
            Logger.warning(
              "proactive_web_radar search failed reason=#{inspect(reason, limit: 3)}"
            )

            {:error, reason}
        end
      end
    else
      _ -> :ok
    end
  end

  @doc """
  Collects up to #{@max_candidates} unseen verified public web mention
  candidates from `terms` using `search_fun`, filtering already-seen URLs BEFORE
  applying the candidate cap so previously seen results cannot starve fresh hits.
  Propagates `{:error, reason}` when search fails and yields no fresh candidates
  so Oban retries instead of locking out for the 6-hour unique window.
  """
  def collect_candidates(terms, search_fun, now, seen_pred \\ fn _url -> false end)
      when is_list(terms) and is_function(search_fun, 1) and is_function(seen_pred, 1) do
    {hits_rev, errors_rev} =
      terms
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(@max_terms)
      |> Enum.reduce({[], []}, fn term, {hits_acc, err_acc} ->
        case search_fun.(term) do
          {:ok, results} when is_list(results) ->
            valid =
              results
              |> Enum.filter(&valid_hit?(&1, term))
              |> Enum.map(&to_candidate(term, &1, now))

            {Enum.reverse(valid, hits_acc), err_acc}

          {:error, reason} ->
            {hits_acc, [reason | err_acc]}

          other ->
            {hits_acc, [{:unexpected_search_result, other} | err_acc]}
        end
      end)

    candidates =
      hits_rev
      |> Enum.reverse()
      |> Enum.uniq_by(& &1["url"])
      |> Enum.reject(&seen_pred.(&1["url"]))
      |> Enum.take(@max_candidates)

    errors = Enum.reverse(errors_rev)

    if candidates == [] and errors != [] do
      {:error, hd(errors)}
    else
      {:ok, candidates}
    end
  end

  @doc "Builds verified public web mention candidates from `terms` using `search_fun`."
  def candidates(terms, search_fun, now) when is_list(terms) and is_function(search_fun, 1) do
    case collect_candidates(terms, search_fun, now) do
      {:ok, list} -> list
      {:error, _reason} -> []
    end
  end

  # Fixed allowlist of generic public product/software categories used solely to
  # disambiguate short single-word watched terms (such as "Comma" or "Cue") in
  # Exa queries. Raw portrait text, customer names, and handles never leave the
  # system because only these static vocabulary tokens can be appended.
  @category_hints [
    {~r/\b(?:ai|llm|gpt)\b|人工智能/iu, "AI"},
    {~r/\b(?:agents?|agentic)\b|智能体/iu, "agent"},
    {~r/\b(?:assistants?)\b|助手|助理/iu, "assistant"},
    {~r/\b(?:ios|iphone|ipad|testflight)\b/iu, "iOS"},
    {~r/\b(?:macos|mac)\b/iu, "macOS"},
    {~r/\b(?:android|apk)\b/iu, "Android"},
    {~r/\b(?:browser|webview|electron)\b|浏览器/iu, "browser"},
    {~r/\b(?:screenshots?|snipping)\b|截图/iu, "screenshot"},
    {~r/\b(?:screen\s*record\w*|recorder)\b|录屏/iu, "screen recorder"},
    {~r/\b(?:3d|svg|shader|medal)\b|奖章/iu, "3D"},
    {~r/\b(?:hardware|esp32|firmware)\b|硬件/iu, "hardware"},
    {~r/\b(?:plugins?|extensions?|mcp)\b|插件/iu, "plugin"},
    {~r/\b(?:cli|sdk|ide|compiler)\b/iu, "developer tool"},
    {~r/\b(?:app|apps|client|clients|desktop|mobile)\b|客户端|应用/iu, "app"},
    {~r/\b(?:workspace|proactive|router|chat|messaging)\b|聊天|工作区/iu, "software"}
  ]

  @doc """
  Builds the Exa search query for `term`. Already-distinctive terms (multi-word,
  dotted/hyphenated, camelCase, CJK, or long words) are queried verbatim as
  `"term"`. Short single-word ASCII product names (such as `"Comma"` or `"Cue"`)
  append up to two allowlisted generic product-category hints derived from their
  portrait entry lines so common English words do not crowd out product hits.
  """
  def search_query(term, context_lines \\ []) when is_binary(term) do
    trimmed = String.trim(term)

    hints =
      if ambiguous_single_word?(trimmed) and is_list(context_lines) and context_lines != [] do
        joined = context_lines |> Enum.filter(&is_binary/1) |> Enum.join("\n")

        @category_hints
        |> Enum.filter(fn {pattern, _label} -> Regex.match?(pattern, joined) end)
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.take(2)
      else
        []
      end

    case hints do
      [] -> ~s("#{trimmed}")
      list -> ~s("#{trimmed}") <> " " <> Enum.join(list, " ")
    end
  end

  defp ambiguous_single_word?(term), do: Regex.match?(~r/^[A-Za-z][a-z]{1,8}$/, term)

  @doc "Builds replay candidates from recorded `web_radar` entries."
  def from_replay(entries, now) when is_list(entries) do
    entries
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn entry ->
      term = entry["term"] || ""
      term == "" or valid_hit?(entry, term)
    end)
    |> Enum.map(fn entry -> to_candidate(entry["term"] || "watch", entry, now) end)
    |> Enum.uniq_by(& &1["url"])
    |> Enum.take(@max_candidates)
  end

  @doc "Stable matter key for one web radar URL."
  def matter_key(url) when is_binary(url) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    MailInteraction.key("web_radar", hash)
  end

  @doc "Records a settled radar URL in Redis (72h TTL) so rejected hits are not re-screened across sweeps."
  def mark_seen(profile_id, url) when is_binary(profile_id) and is_binary(url) do
    case seen_redis() do
      nil ->
        :ok

      conn ->
        _ =
          Redix.command(
            conn,
            ["SET", seen_key(profile_id, url), "1", "EX", Integer.to_string(@seen_ttl_s)],
            timeout: 1_500
          )

        :ok
    end
  rescue
    _ -> :ok
  end

  def mark_seen(_profile_id, _url), do: :ok

  @doc "Whether `url` was already settled for `profile_id` within the 72h radar dedup window."
  def seen?(profile_id, url) when is_binary(profile_id) and is_binary(url) do
    case seen_redis() do
      nil ->
        false

      conn ->
        match?(
          {:ok, 1},
          Redix.command(conn, ["EXISTS", seen_key(profile_id, url)], timeout: 1_500)
        )
    end
  rescue
    _ -> false
  end

  def seen?(_profile_id, _url), do: false

  defp seen_redis do
    case SystemsRuntime.get_env(:comma_web, :web_radar_seen_redis, @seen_redis) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid, else: nil
      name when is_atom(name) -> if Process.whereis(name), do: name, else: nil
      _ -> nil
    end
  end

  defp seen_key(profile_id, url) do
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    "comma:web_radar:seen:#{profile_id}:#{hash}"
  end

  defp already_seen?(routed, url) when is_map(routed) and is_binary(url) do
    Map.has_key?(routed, matter_key(url))
  end

  defp valid_hit?(%{"url" => url} = result, term) when is_binary(url) and is_binary(term) do
    text = (result["title"] || "") <> "\n" <> (result["text"] || "")
    ProactiveEvidence.external_urls(url) != [] and term_matches?(text, term)
  end

  defp valid_hit?(_result, _term), do: false

  defp term_matches?(text, term) when is_binary(text) and is_binary(term) do
    trimmed = String.trim(term)

    cond do
      trimmed == "" ->
        false

      Regex.match?(~r/^[A-Za-z0-9._-]+$/, trimmed) ->
        Regex.match?(
          ~r/(?:^|[^\p{L}\p{N}_])#{Regex.escape(trimmed)}(?:$|[^\p{L}\p{N}_])/iu,
          text
        )

      true ->
        String.contains?(String.downcase(text), String.downcase(trimmed))
    end
  end

  defp to_candidate(term, result, now) do
    url = String.trim(result["url"])
    title = (result["title"] || url) |> String.trim() |> String.slice(0, 200)
    text = (result["text"] || "") |> String.trim() |> String.slice(0, 1_200)
    hash = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower) |> String.slice(0, 16)

    item = %{
      "id" => "wr:" <> hash,
      "sourceId" => "web_radar",
      "sourceVersion" => hash,
      "toolkit" => "web_radar",
      "app" => "Web Radar",
      "title" => title,
      "url" => url,
      "excerpt" => if(text == "", do: title, else: text),
      "context" => %{"text" => text, "watchedTerm" => term},
      "relationship" => "web_mention_of_your_work",
      "facts" => %{"watchedTerm" => term},
      "arrivedAt" => now,
      "web_radar" => true
    }

    Map.put(item, "members", [item])
  end

  defp personal?(workspace, owner),
    do: Enum.map(workspace["members"] || [], & &1["user_id"]) in [[], [owner]]

  defp billing_denied?(:insufficient_credits), do: true

  defp billing_denied?({:billing_unavailable, decision}) when is_map(decision),
    do: BillingAvailability.denied?({:billing_unavailable, decision})

  defp billing_denied?({:billing_unavailable, code}) when is_binary(code),
    do: BillingAvailability.denied?({:billing_unavailable, %{reason: code}})

  defp billing_denied?(_reason), do: false

  @doc "Whether automatic Web Radar sweeps are enabled and Exa search is configured."
  def enabled? do
    SystemsRuntime.get_env(:comma_web, :proactive_web_radar_enabled, false) == true and
      exa_configured?()
  end

  defp exa_configured? do
    key = SystemsRuntime.get_env(:salix_agent, :exa_api_key)
    is_binary(key) and String.trim(key) != ""
  end
end
