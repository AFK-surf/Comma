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

  @limit 3
  @thread_tail 3
  @text_bytes 200
  # People answer a channel message in the channel as often as in its thread;
  # the hour after it holds the answer.
  @channel_window 3600
  @channel_limit 100

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

    threads ++ runs ++ pulls
  end

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

  @doc "Reads the matter's links with the owner's managed grants."
  def linked(workspace, owner, sources, matter) do
    grants =
      for %{"enabled" => true, "kind" => "managed_oauth", "appId" => app} = source <-
            sources || [],
          app in ~w(github slack),
          into: %{},
          do: {app, source}

    get = fn provider, url ->
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

  defp summarize(:issue, %{"html_url" => url} = issue),
    do: %{
      "url" => url,
      "kind" =>
        if(Map.has_key?(issue, "merged"), do: "github_pull_request", else: "github_issue"),
      "title" => issue["title"],
      "state" => issue["state"],
      "merged" => issue["merged"]
    }

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
