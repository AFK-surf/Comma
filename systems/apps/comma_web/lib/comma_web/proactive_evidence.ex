defmodule CommaWeb.ProactiveEvidence do
  @moduledoc """
  The current state of a matter's links, read once before the matter reaches
  the Router: whether a GitHub Actions run is still failing, whether a pull
  request or issue is still open, who spoke last in the Slack thread, and,
  for a message posted straight in a channel, what the channel said in the
  hour after it. The Router decides with it, for example to stay quiet about
  a failure that a rerun already fixed or a mention the owner already
  answered in the channel.

  Only matters that the proactive check hands to the Router are read, at most
  three links each, with the owner's own managed GitHub or Slack grant. A link
  that cannot be read is left out.
  """

  alias CommaWeb.{ProactiveMatters, RecommendationOAuthSource}
  alias SalixAgent.Tools.Web

  @limit 3
  @web_limit 2
  @thread_tail 3
  @text_bytes 200
  @web_title_chars 160
  @web_text_chars 1_200
  # People answer a channel message in the channel as often as in its thread;
  # the hour after it holds the answer.
  @channel_window 3600
  @channel_limit 100

  @excluded_web_hosts ~w(
    slack.com github.com api.github.com raw.githubusercontent.com
    mail.google.com outlook.office.com outlook.live.com
    calendar.google.com drive.google.com docs.google.com
    linear.app notion.so www.notion.so feishu.cn larksuite.com
  )
  @tracking_host_prefixes ~w(track. click. links. pixel. email. cdn. static. assets. images. img. auth. login. sso. billing. pay. checkout.)
  @sensitive_path_re ~r/(?:^|[\/._-])(unsubscribe|opt[-_]?out|manage[-_]?preferences|email[-_]?preferences|tracking|pixel|beacon|open\.php|click\.php|auth|oauth\d*|login|sign[-_]?in|sso|verify|confirm|activate|reset|password|magic|token|invite|invitation|billing|invoice|receipt|checkout|payment|redirect|redir|goto)(?:$|[\/._-])/i
  @token_segment_re ~r/\/(?:[a-f0-9]{24,}|(?=[A-Za-z0-9_-]*[A-Z])(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{24,})(?:\/|$)/
  @asset_ext_re ~r/\.(png|jpe?g|gif|webp|svg|ico|css|js|woff2?|ttf|eot|pdf|zip|tar|gz|mp4|mov|mp3|wav)$/i
  @https_url_re ~r/https:\/\/[^\s<>\]\)"'）】，。；、|]+/u

  @doc "Public HTTPS content URLs found in `text`, normalized and filtered by `sanitize_public_fetch_url/1`."
  def external_urls(text) when is_binary(text) do
    @https_url_re
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.flat_map(fn raw ->
      case sanitize_public_fetch_url(clean_url(raw)) do
        {:ok, clean} -> [clean]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  def external_urls(_text), do: []

  defp clean_url(url) do
    String.trim_trailing(url, ".,;:!?)]}'\"")
  end

  @doc """
  Shared policy boundary for every automatic third-party Exa URL fetch
  (both link unfurling and `ProactiveResearch` `web_read`).

  Normalizes trailing-dot hostnames, strips `#fragment`s, rejects userinfo,
  query strings, malformed or double percent-encoding, provider/tracking hosts,
  static assets, high-entropy token path segments, and sensitive auth/billing/
  capability paths (on both raw and percent-decoded paths), then verifies
  `SalixAgent.Tools.Web.public_url?/1` on the exact URL sent to Exa.
  """
  def sanitize_public_fetch_url(url) when is_binary(url) do
    url = String.trim(url)

    with true <- byte_size(url) in 1..512,
         %URI{
           scheme: "https",
           userinfo: userinfo,
           host: host,
           port: port,
           path: path,
           query: query
         } =
           uri <- URI.parse(url),
         true <-
           userinfo in [nil, ""] and port in [nil, 443] and query in [nil, ""] and
             is_binary(host) and is_binary(path) and path not in ["", "/"],
         host_down = host |> String.downcase() |> String.trim_trailing("."),
         true <- host_down != "",
         false <- excluded_host?(host_down),
         false <- Enum.any?(@tracking_host_prefixes, &String.starts_with?(host_down, &1)),
         {:ok, decoded_path} <- decode_safe_path(path),
         false <- Regex.match?(@asset_ext_re, path) or Regex.match?(@asset_ext_re, decoded_path),
         false <-
           Regex.match?(@sensitive_path_re, path) or
             Regex.match?(@sensitive_path_re, decoded_path),
         false <-
           Regex.match?(@token_segment_re, path) or Regex.match?(@token_segment_re, decoded_path),
         clean = URI.to_string(%URI{uri | host: host_down, fragment: nil}),
         true <- byte_size(clean) <= 512 and Web.public_url?(clean) do
      {:ok, clean}
    else
      _ -> :error
    end
  end

  def sanitize_public_fetch_url(_url), do: :error

  defp decode_safe_path(path) when is_binary(path) do
    cond do
      # Fail closed on malformed percent-escapes or double-encoded sequences (`%25`).
      Regex.match?(~r/%(?![0-9a-fA-F]{2})/, path) ->
        :error

      Regex.match?(~r/%25/i, path) ->
        :error

      true ->
        decoded = URI.decode(path)

        if String.valid?(decoded) and not Regex.match?(~r/[\x00-\x1F\x7F\\]/, decoded) and
             not Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."])) do
          {:ok, decoded}
        else
          :error
        end
    end
  end

  defp excluded_host?(host) do
    Enum.any?(@excluded_web_hosts, fn blocked ->
      host == blocked or String.ends_with?(host, "." <> blocked)
    end)
  end

  @doc "The links of a matter to read, newest item first, at most #{@limit}."
  def targets(matter) do
    [matter]
    |> ProactiveMatters.items()
    |> Enum.sort_by(&(get_in(&1, ["facts", "ts"]) || ""), :desc)
    |> Enum.flat_map(&targets_of/1)
    |> Enum.uniq()
    |> Enum.take(@limit)
  end

  defp targets_of(item) do
    text = Enum.map_join([item["url"], item["excerpt"]], "\n", &(&1 || ""))

    runs =
      for [_, repo, id] <- Regex.scan(~r<github\.com/([\w.-]+/[\w.-]+)/actions/runs/(\d+)>, text),
          do: {:github, "https://api.github.com/repos/#{repo}/actions/runs/#{id}", :run}

    pulls =
      for [_, repo, kind, number] <-
            Regex.scan(~r<github\.com/([\w.-]+/[\w.-]+)/(pull|issues)/(\d+)>, text),
          do:
            {:github, "https://api.github.com/repos/#{repo}/#{endpoint(kind)}/#{number}", :issue}

    owner = item["recipient"]

    threads =
      case Regex.run(~r<archives/(C[A-Z0-9]+)/p(\d+)(\?thread_ts=([\d.]+))?>, item["url"] || "") do
        [_, channel, digits, _query, thread] ->
          url =
            CommaWeb.SlackWebAPI.url("conversations.replies", %{
              "channel" => channel,
              "ts" => thread,
              "limit" => 50
            })

          since = with {ts, _seconds} <- permalink_ts(digits), do: ts
          [{:slack, url, {:thread, owner, since}}]

        [_, channel, digits] ->
          case permalink_ts(digits) do
            {ts, seconds} ->
              url =
                CommaWeb.SlackWebAPI.url("conversations.history", %{
                  "channel" => channel,
                  "oldest" => ts,
                  "latest" => Integer.to_string(seconds + @channel_window),
                  "limit" => @channel_limit
                })

              [{:slack, url, {:channel_after, owner}}]

            nil ->
              []
          end

        _ ->
          []
      end

    web =
      if unfurl_allowed_item?(item) do
        body =
          Enum.map_join([item["excerpt"], get_in(item, ["context", "text"])], "\n", &(&1 || ""))

        body
        |> external_urls()
        |> Enum.reject(&(&1 == item["url"]))
        |> Enum.take(@web_limit)
        |> Enum.map(&{:web, &1, :web_page})
      else
        []
      end

    threads ++ runs ++ pulls ++ web
  end

  @doc """
  Whether `item` may trigger automatic third-party Exa URL fetching (link
  unfurling or `ProactiveResearch` `web_read`). Private Gmail/Outlook mail and
  junk mail are never permitted; only Slack messages, Web Radar hits, and
  watched-term `mentions_your_work` items qualify.
  """
  def unfurl_allowed_item?(item) when is_map(item) do
    rel = item["relationship"]
    toolkit = item["toolkit"]
    url = item["url"] || ""

    cond do
      rel == "in_your_junk_folder" -> false
      rel == "mentions_your_work" -> true
      toolkit in ~w(slack web_radar) -> true
      toolkit in ~w(gmail outlook) -> false
      rel in ~w(posted_where_your_work_is web_radar_hit) -> true
      String.contains?(url, ".slack.com/archives/") -> true
      true -> false
    end
  end

  def unfurl_allowed_item?(_item), do: false

  # A permalink's `p` digits are the message ts without its dot.
  defp permalink_ts(digits) when byte_size(digits) > 6 do
    {seconds, micros} = String.split_at(digits, -6)
    {seconds <> "." <> micros, String.to_integer(seconds)}
  end

  defp permalink_ts(_digits), do: nil

  defp endpoint("pull"), do: "pulls"
  defp endpoint("issues"), do: "issues"

  @doc """
  Reads `targets` with `get`, a function from provider and URL to
  `{:ok, body}`. Returns one summary per link that could be read.
  """
  def read(targets, get) do
    for {provider, url, kind} <- targets,
        {:ok, body} <- [get.(provider, url)],
        summary = summarize(kind, body),
        summary != nil,
        do: summary
  end

  @doc "Reads the matter's links with the owner's managed grants and bounded Exa web contents."
  def linked(workspace, owner, sources, matter) do
    grants =
      for %{"enabled" => true, "kind" => "managed_oauth", "appId" => app} = source <-
            sources || [],
          app in ~w(github slack),
          into: %{},
          do: {app, source}

    get = fn
      :web, url ->
        case Web.contents([url], max_characters: @web_text_chars, receive_timeout: 8_000) do
          {:ok, [page | _]} -> {:ok, page}
          {:ok, []} -> {:error, :empty}
          {:error, reason} -> {:error, reason}
        end

      provider, url ->
        case grants[Atom.to_string(provider)] do
          nil -> {:error, :no_grant}
          source -> RecommendationOAuthSource.member_get(workspace, owner, source, url)
        end
    end

    read(targets(matter), get)
  end

  defp summarize(:run, %{"html_url" => url} = run),
    do: %{
      "url" => url,
      "kind" => "github_actions_run",
      "name" => run["name"],
      "status" => run["status"],
      "conclusion" => run["conclusion"],
      "attempt" => run["run_attempt"],
      "updated_at" => run["updated_at"]
    }

  defp summarize(:issue, %{"html_url" => url} = issue) do
    summary = %{
      "url" => url,
      "kind" =>
        if(Map.has_key?(issue, "merged"), do: "github_pull_request", else: "github_issue"),
      "title" => issue["title"],
      "state" => issue["state"],
      "merged" => issue["merged"]
    }

    if Map.has_key?(issue, "draft"),
      do: Map.put(summary, "draft", issue["draft"] == true),
      else: summary
  end

  defp summarize({:thread, owner, since}, %{"ok" => true, "messages" => [_ | _] = messages}),
    do: %{
      "kind" => "slack_thread",
      "replies" => length(messages) - 1,
      "owner_replied" => owner_spoke?(Enum.filter(tl(messages), &later?(&1["ts"], since)), owner),
      "latest" => messages |> Enum.take(-@thread_tail) |> Enum.map(&brief/1)
    }

  # The channel's messages after a message posted straight in it, newest
  # first as Slack returns them. Its thread replies stay in the thread.
  defp summarize({:channel_after, owner}, %{"ok" => true, "messages" => messages})
       when is_list(messages) do
    after_it = Enum.reverse(messages)

    %{
      "kind" => "slack_channel_after",
      "window_seconds" => @channel_window,
      "messages" => length(after_it),
      "owner_replied" => owner_spoke?(after_it, owner),
      "first" => after_it |> Enum.take(@thread_tail) |> Enum.map(&brief/1)
    }
  end

  defp summarize(:web_page, %{"url" => url} = page) when is_binary(url) do
    title = (page["title"] || "") |> String.trim() |> String.slice(0, @web_title_chars)
    text = (page["text"] || "") |> String.trim() |> String.slice(0, @web_text_chars)

    if title == "" and text == "" do
      nil
    else
      %{
        "kind" => "web_page",
        "url" => url,
        "title" => title,
        "text" => text
      }
      |> Map.reject(fn {_k, v} -> v == "" end)
    end
  end

  defp summarize(_kind, _body), do: nil

  # After the item's message; without its ts, any reply counts.
  defp later?(_ts, nil), do: true
  defp later?(ts, since) when is_binary(ts), do: ts_value(ts) > ts_value(since)
  defp later?(_ts, _since), do: false

  defp ts_value(ts) do
    case Float.parse(ts) do
      {value, _} -> value
      :error -> 0.0
    end
  end

  defp owner_spoke?(_messages, nil), do: nil
  defp owner_spoke?(messages, owner), do: Enum.any?(messages, &(&1["user"] == owner))

  defp brief(message),
    do: %{
      "from" => message["user"] || message["username"] || message["bot_id"],
      "ts" => message["ts"],
      "text" => String.slice(message["text"] || "", 0, @text_bytes)
    }
end
