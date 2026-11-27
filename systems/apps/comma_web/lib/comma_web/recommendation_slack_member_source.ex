defmodule CommaWeb.RecommendationSlackMemberSource do
  @moduledoc false

  alias CommaWeb.{RecommendationMemberRead, SlackLocalMirror, SlackWebAPI}

  @own_days 30
  @own_count 100
  @max_own_pages 3
  @mentions_limit 30
  @direct_limit 30
  @threads_limit 30
  @max_search_pages 3
  @channel_after_window 3_600
  @target_count 20
  @per_target 5
  @targets_total 10
  @target_bytes 600
  @message_chars 1_200
  @message_preamble_chars 360
  @mention ~r/<@([UW][A-Z0-9]+)>/
  @named_most 20
  # A channel message that asks someone for something.
  @asks ~r/[?？]|请|谁|帮忙|please|can you|could you|<!here|<!channel|<@/iu

  # Three direct relationships from the last seven days: messages that mention
  # the member, one-to-one direct messages to the member, and threads the
  # member joined whose latest message is from someone else. Option `targets`
  # (`CommaWeb.MemberPortrait.targets/1`) adds the last day of the channels
  # where the member's work is reported; `targeted/3` keeps bot posts and
  # requests, at most #{@targets_total}.
  def read(request, now, expected_subject \\ nil, opts \\ []) do
    targets = opts[:targets] || %{}
    tenant_id = opts[:tenant_id]
    token_fingerprint = opts[:token_fingerprint]

    with {:ok, auth} <-
           SlackLocalMirror.auth_test(tenant_id, expected_subject, token_fingerprint, fn ->
             request.("GET", SlackWebAPI.url("auth.test"), [])
           end),
         true <- auth["ok"] == true and is_nil(auth["bot_id"]),
         user when is_binary(user) <- auth["user_id"],
         team when is_binary(team) <- auth["team_id"],
         true <- Regex.match?(~r/^[UW][A-Z0-9]+$/, user) and Regex.match?(~r/^T[A-Z0-9]+$/, team),
         :ok <- verify_subject(user, team, expected_subject),
         after_date = now |> DateTime.add(-604_800, :second) |> DateTime.to_date(),
         since = now |> DateTime.add(-86_400, :second) |> DateTime.to_date(),
         {:ok, [mentions, direct, threads], failures} <-
           slack_searches(request, [
             {"<@#{user}> after:#{after_date}", 40, @max_search_pages,
              &(length(mention_candidates(&1, user)) >= @mentions_limit)},
             {"to:me after:#{after_date}", 100, @max_search_pages,
              &(length(direct_candidates(&1, user)) >= @direct_limit)},
             {"is:thread with:<@#{user}> after:#{after_date}", 100, @max_search_pages,
              &(length(thread_candidates(&1, user)) >= @threads_limit)}
           ]),
         _ = SlackLocalMirror.register_channels(team, user, mentions ++ direct ++ threads),
         {:ok, in_places, place_failures} <-
           target_searches(
             request,
             targets["channels"] || [],
             since,
             tenant_id,
             team,
             user
           ) do
      failures = failures ++ place_failures

      mentions =
        mentions
        |> mention_candidates(user)
        |> Enum.take(@mentions_limit)
        |> Enum.map(&Map.put(&1, "memberRelation", "mentioned_you"))

      # Newest first, so the first message per conversation or thread is its latest.
      direct =
        direct
        |> direct_candidates(user)
        |> Enum.take(@direct_limit)
        |> Enum.map(&Map.put(&1, "memberRelation", "direct_message_to_you"))

      threads =
        threads
        |> thread_candidates(user)
        |> Enum.take(@threads_limit)
        |> Enum.map(&Map.put(&1, "memberRelation", "replied_in_your_thread"))

      # The member's own threads already reach them through `threads`.
      joined = MapSet.new(threads, &{get_in(&1, ["channel", "id"]), slack_thread(&1)})

      targeted_items =
        in_places
        |> targeted(user, joined, targets["terms"] || [])
        |> Enum.take(@targets_total)

      # A message in two lists keeps its stronger relation and its full text:
      # `targeted/3` shortens its own copies.
      {lists, _seen} =
        [mentions, direct, threads, targeted_items]
        |> Enum.map_reduce(MapSet.new(), fn list, seen ->
          kept = Enum.reject(list, &MapSet.member?(seen, &1["permalink"]))
          {kept, Enum.reduce(kept, seen, &MapSet.put(&2, &1["permalink"]))}
        end)

      matches =
        interleave(lists)
        |> Enum.uniq_by(& &1["permalink"])
        |> Enum.map(&Map.update(&1, "text", "", fn text -> bounded_message_text(text, user) end))

      names = mention_names(request, team, Enum.map(matches, & &1["text"]))

      selected =
        Enum.map(matches, fn item ->
          neighbors =
            Map.new(~w(previous_2 previous next next_2), fn key ->
              message = item[key]
              {key, if(is_map(message), do: Map.take(message, ~w(text ts user)), else: nil)}
            end)

          # The sender is the handle the search returns, not a looked-up name:
          # a failed lookup would change the item's context and judge it again.
          context =
            neighbors
            |> Map.put("sender", item["username"])
            |> CommaWeb.RecommendationSourceContext.attach(
              ["sender" | Map.keys(neighbors)],
              "search_neighbors"
            )
            |> Map.fetch!("context")

          item
          |> Map.take(~w(text ts permalink memberRelation))
          |> Map.put("context", context)
          |> CommaWeb.RecommendationSourceQuote.put(
            author: item["username"],
            body: {:slack, named(item["text"], names)}
          )
        end)

      {:ok,
       RecommendationMemberRead.warn(
         %{"messages" => %{"matches" => selected}, "memberRelation" => "involves_you"},
         failures
       ), %{"provider_user_id" => user, "provider_workspace_id" => team}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  @own_threads 15
  @own_replies 6
  @reply_chars 400

  @doc """
  The member's own messages from the last #{@own_days} days, newest first, each
  with the text of the thread it answered: what the member said and did, the
  evidence of their portrait (`CommaWeb.MemberPortrait`). At most
  #{@own_threads} threads are read.

  Option `replies: true` also reads the threads the member started and gives
  each message the thread's later messages (`"replies"`, at most
  #{@own_replies}, each `"from"` `you` or `other`), so a reader can tell
  whether someone answered (`CommaWeb.OpenThreads`).
  """
  def own_messages(request, now, expected_subject \\ nil, opts \\ []) do
    replies? = Keyword.get(opts, :replies, false)
    since_ts = Keyword.get(opts, :since_ts)
    max_pages = if is_binary(since_ts), do: @max_own_pages, else: 1

    done? =
      if is_binary(since_ts),
        do: fn matches ->
          matches != [] and not ts_after?(List.last(matches)["ts"], since_ts)
        end,
        else: fn _matches -> true end

    tenant_id = Keyword.get(opts, :tenant_id)
    token_fingerprint = Keyword.get(opts, :token_fingerprint)

    with {:ok, auth} <-
           SlackLocalMirror.auth_test(tenant_id, expected_subject, token_fingerprint, fn ->
             request.("GET", SlackWebAPI.url("auth.test"), [])
           end),
         true <- auth["ok"] == true and is_nil(auth["bot_id"]),
         user when is_binary(user) <- auth["user_id"],
         team when is_binary(team) <- auth["team_id"],
         :ok <- verify_subject(user, team, expected_subject),
         after_date = now |> DateTime.add(-@own_days * 86_400, :second) |> DateTime.to_date(),
         {:ok, matches} <-
           slack_search(
             request,
             {"from:<@#{user}> after:#{after_date}", @own_count, max_pages, done?}
           ) do
      _ = SlackLocalMirror.register_channels(team, user, matches)
      own = Enum.filter(matches, &(&1["user"] == user))

      read =
        own
        |> Enum.flat_map(fn message ->
          case {get_in(message, ["channel", "id"]), own_thread(message, replies?)} do
            {channel, thread} when is_binary(channel) and is_binary(thread) -> [{channel, thread}]
            _ -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.take(@own_threads)
        # Thread reads with replies go one at a time and take a smaller page,
        # to lower the load on the shared conversations.replies allowance.
        |> RecommendationMemberRead.map(
          &thread_read(request, &1, replies?, Keyword.get(opts, :tenant_id), team),
          if(replies?, do: 1, else: 3)
        )
        |> Enum.flat_map(fn
          {:ok, key, messages} -> [{key, messages}]
          _ -> []
        end)
        |> Map.new()

      parents =
        Map.new(read, fn {key, [first | _]} -> {key, String.slice(first["text"], 0, 1_200)} end)

      {:ok,
       Enum.map(own, fn message ->
         key = {get_in(message, ["channel", "id"]), slack_thread(message)}
         thread = {get_in(message, ["channel", "id"]), own_thread(message, replies?)}

         %{
           "text" => message["text"],
           "ts" => message["ts"],
           "permalink" => message["permalink"],
           "channel" => get_in(message, ["channel", "name"]),
           "direct" =>
             get_in(message, ["channel", "is_im"]) == true or
               get_in(message, ["channel", "is_mpim"]) == true,
           "thread" => parents[key],
           "replies" => if(replies?, do: later(read[thread], message["ts"], user))
         }
         |> Map.reject(fn {_key, value} -> value in [nil, []] end)
       end),
       %{"provider_user_id" => user, "provider_workspace_id" => team, "handle" => auth["user"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  @doc """
  The messages of each tracked thread after its checked ts, read one thread
  at a time: `threads` maps an ID to `{channel, thread_ts, since}`. Returns
  the ID to its new messages (`"ts"`, `"from"` `you` or `other`, `"text"`),
  at most #{@own_replies * 2} each; a thread that cannot be read is left out
  (`CommaWeb.OpenThreads`).
  """
  def thread_news(request, threads, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id)
    workspace_id = Keyword.get(opts, :workspace_id)
    user_id = Keyword.get(opts, :user_id)
    token_fingerprint = Keyword.get(opts, :token_fingerprint)

    expected_subject =
      if is_binary(user_id) and is_binary(workspace_id),
        do: %{"provider_user_id" => user_id, "provider_workspace_id" => workspace_id},
        else: nil

    with {:ok, %{"ok" => true, "user_id" => user} = auth} when is_binary(user) <-
           SlackLocalMirror.auth_test(tenant_id, expected_subject, token_fingerprint, fn ->
             request.("GET", SlackWebAPI.url("auth.test"), [])
           end) do
      team = workspace_id || auth["team_id"]

      {:ok,
       threads
       |> Enum.to_list()
       |> RecommendationMemberRead.map(&thread_since(request, &1, user, tenant_id, team), 1)
       |> Enum.flat_map(fn
         {:ok, id, messages} -> [{id, messages}]
         _ -> []
       end)
       |> Map.new()}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  defp thread_since(request, {id, {channel, thread, since}}, user, tenant_id, team) do
    url =
      SlackWebAPI.url("conversations.replies", %{
        "channel" => channel,
        "ts" => thread,
        "oldest" => since,
        "inclusive" => "false",
        "limit" => 15
      })

    case local_or_slack_get(request, tenant_id, team, url, max_bytes: 200_000) do
      {:ok, %{"ok" => true, "messages" => messages}} when is_list(messages) ->
        replies =
          messages
          |> Enum.filter(&(is_binary(&1["text"]) and ts_after?(&1["ts"], since)))
          |> Enum.take(@own_replies * 2)

        found =
          if replies == [] and since == thread and String.starts_with?(channel, "C"),
            do: channel_after_since(request, channel, since, tenant_id, team),
            else: replies

        {:ok, id,
         Enum.map(
           found,
           &%{
             "ts" => &1["ts"],
             "from" => if(&1["user"] == user and is_nil(&1["bot_id"]), do: "you", else: "other"),
             "text" => String.slice(&1["text"], 0, @reply_chars)
           }
         )}

      _ ->
        :error
    end
  end

  # A top-level channel message may be answered straight in the channel rather
  # than in a Slack thread; read the hour after it when no thread reply exists.
  defp channel_after_since(request, channel, since, tenant_id, team) do
    with {seconds, _} <- Integer.parse(since),
         url =
           SlackWebAPI.url("conversations.history", %{
             "channel" => channel,
             "oldest" => since,
             "latest" => Integer.to_string(seconds + @channel_after_window),
             "limit" => 15
           }),
         {:ok, %{"ok" => true, "messages" => messages}} when is_list(messages) <-
           local_or_slack_get(request, tenant_id, team, url, max_bytes: 200_000) do
      messages
      |> Enum.reverse()
      |> Enum.filter(fn message ->
        is_binary(message["text"]) and ts_after?(message["ts"], since) and
          (is_nil(message["thread_ts"]) or message["thread_ts"] == message["ts"])
      end)
      |> Enum.take(@own_replies * 2)
    else
      _ -> []
    end
  end

  defp mention_candidates(matches, user) do
    Enum.filter(matches, &(String.contains?(&1["text"], "<@#{user}>") and &1["user"] != user))
  end

  defp direct_candidates(matches, user) do
    matches
    |> Enum.filter(&(get_in(&1, ["channel", "is_im"]) == true and &1["user"] != user))
    |> Enum.uniq_by(&get_in(&1, ["channel", "id"]))
  end

  defp thread_candidates(matches, user) do
    matches
    |> Enum.filter(&is_binary(slack_thread(&1)))
    |> Enum.uniq_by(&{get_in(&1, ["channel", "id"]), slack_thread(&1)})
    |> Enum.reject(&(&1["user"] == user))
  end

  # The thread a message belongs to; with replies, also the one it starts.
  defp own_thread(message, false), do: slack_thread(message)
  defp own_thread(message, true), do: slack_thread(message) || message["ts"]

  # The thread's start, and with replies its first messages.
  defp thread_read(request, {channel, thread}, replies?, tenant_id, team) do
    url =
      SlackWebAPI.url("conversations.replies", %{
        "channel" => channel,
        "ts" => thread,
        "limit" => if(replies?, do: 15, else: 1)
      })

    case local_or_slack_get(request, tenant_id, team, url, max_bytes: 200_000) do
      {:ok, %{"ok" => true, "messages" => [%{"text" => text} | _] = messages}}
      when is_binary(text) ->
        {:ok, {channel, thread}, Enum.filter(messages, &is_binary(&1["text"]))}

      _ ->
        :error
    end
  end

  defp local_or_slack_get(request, tenant_id, team, url, opts) do
    case SlackLocalMirror.fetch_url(tenant_id, team, url) do
      {:ok, body} -> {:ok, body}
      :miss -> request.("GET", url, opts)
    end
  end

  # The thread's messages after `ts`, from the member (`you`) or anyone else.
  defp later(nil, _ts, _user), do: nil

  defp later(messages, ts, user) do
    messages
    |> Enum.filter(&ts_after?(&1["ts"], ts))
    |> Enum.take(@own_replies)
    |> Enum.map(
      &%{
        "from" => if(&1["user"] == user and is_nil(&1["bot_id"]), do: "you", else: "other"),
        "text" => String.slice(&1["text"], 0, @reply_chars)
      }
    )
  end

  defp ts_after?(a, b) when is_binary(a) and is_binary(b) do
    case {Float.parse(a), Float.parse(b)} do
      {{x, _}, {y, _}} -> x > y
      _ -> false
    end
  end

  defp ts_after?(_a, _b), do: false

  defp target_searches(_request, [], _since, _tenant_id, _team, _user), do: {:ok, [], []}

  defp target_searches(request, channels, since, tenant_id, team, user) do
    {local_hits, fallback_queries} =
      Enum.reduce(channels, {[], []}, fn name, {hits, queries} ->
        case SlackLocalMirror.fetch_target_search(
               tenant_id,
               team,
               user,
               name,
               since,
               limit: @target_count
             ) do
          {:ok, matches} ->
            {[matches | hits], queries}

          :miss ->
            {hits, ["in:##{name} after:#{since}" | queries]}
        end
      end)

    local_results = Enum.reverse(local_hits)

    case Enum.reverse(fallback_queries) do
      [] ->
        {:ok, local_results, []}

      queries ->
        case slack_searches(request, Enum.map(queries, &{&1, @target_count})) do
          {:ok, remote_matches, failures} ->
            Enum.each(remote_matches, &SlackLocalMirror.register_channels(team, user, &1))
            {:ok, local_results ++ remote_matches, failures}

          # The direct relationships stay readable when no target is.
          {:error, reason} ->
            {:ok, local_results, [reason]}
        end
    end
  end

  @per_target_links 2

  # Per channel: the latest message of each thread, not the member's own and
  # not a thread they joined, that a bot or integration posted, asks someone
  # for something, names a watched portrait term, or shares a public content
  # link for downstream unfurling, at most #{@per_target}, its text cut to
  # #{@target_bytes} characters. Priority items (bots, asks, watched terms)
  # always rank ahead of link-only posts, which are capped at #{@per_target_links}
  # per channel so casual link shares cannot crowd out real alerts.
  defp targeted(results, user, joined, terms) do
    Enum.flat_map(results, fn matches ->
      candidates =
        matches
        |> Enum.reject(&(&1["user"] == user))
        |> Enum.uniq_by(&{get_in(&1, ["channel", "id"]), slack_thread(&1) || &1["ts"]})
        |> Enum.reject(&MapSet.member?(joined, {get_in(&1, ["channel", "id"]), slack_thread(&1)}))

      priority =
        Enum.filter(candidates, fn match ->
          text = match["text"] || ""
          bot?(match) or Regex.match?(@asks, text) or mentions_term?(text, terms)
        end)

      priority_keys = MapSet.new(priority, &{get_in(&1, ["channel", "id"]), &1["ts"]})

      link_only =
        candidates
        |> Enum.reject(&MapSet.member?(priority_keys, {get_in(&1, ["channel", "id"]), &1["ts"]}))
        |> Enum.filter(&has_external_url?(&1["text"] || ""))
        |> Enum.take(@per_target_links)

      (priority ++ link_only)
      |> Enum.take(@per_target)
      |> Enum.map(fn match ->
        match
        |> Map.update("text", "", &String.slice(&1, 0, @target_bytes))
        |> Map.put("memberRelation", "posted_where_your_work_is")
      end)
    end)
  end

  defp mentions_term?(_text, []), do: false

  defp mentions_term?(text, terms) when is_binary(text) and is_list(terms) do
    down = String.downcase(text)

    Enum.any?(terms, fn
      term when is_binary(term) ->
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
            String.contains?(down, String.downcase(trimmed))
        end

      _ ->
        false
    end)
  end

  defp mentions_term?(_text, _terms), do: false

  defp has_external_url?(text) when is_binary(text) do
    CommaWeb.ProactiveEvidence.external_urls(text) != []
  end

  # Slack writes a mention as the person's ID. The quote names them as
  # `<@U…|name>`, at most #{@named_most} people per read; a person whose name
  # cannot be read stays an ID.
  defp mention_names(request, team, texts) do
    texts
    |> Enum.flat_map(&Regex.scan(@mention, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.take(@named_most)
    |> RecommendationMemberRead.map(
      &{&1, SlackLocalMirror.user_name(team, &1, fn -> user_name(request, &1) end)},
      3
    )
    |> Map.new()
  end

  defp user_name(request, user) do
    case request.("GET", SlackWebAPI.url("users.info", %{"user" => user}), max_bytes: 200_000) do
      {:ok, %{"ok" => true, "user" => %{} = person}} ->
        profile = if is_map(person["profile"]), do: person["profile"], else: %{}

        [profile["display_name"], profile["real_name"], person["real_name"], person["name"]]
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&(&1 |> String.replace(~r/[<>|\s]+/u, " ") |> String.trim()))
        |> Enum.find(&(&1 != ""))

      _ ->
        nil
    end
  end

  defp named(text, names) do
    Regex.replace(@mention, text, fn mention, user ->
      case names[user] do
        name when is_binary(name) -> "<@#{user}|#{name}>"
        _ -> mention
      end
    end)
  end

  defp bot?(match),
    do: is_nil(match["user"]) or is_binary(match["bot_id"]) or match["subtype"] == "bot_message"

  defp verify_subject(_user, _team, nil), do: :ok

  defp verify_subject(user, team, expected) do
    if expected == %{"provider_user_id" => user, "provider_workspace_id" => team},
      do: :ok,
      else: {:error, :member_source_identity_mismatch}
  end

  # The three relationships are independent searches. One that fails leaves
  # the others readable; the source fails only when none can be read.
  defp slack_searches(request, queries) do
    results = RecommendationMemberRead.map(queries, &slack_search(request, &1), 3)

    case for {:error, reason} <- results, do: reason do
      failures when length(failures) == length(results) ->
        {:error, hd(failures)}

      failures ->
        matches =
          Enum.map(results, fn
            {:ok, matches} -> matches
            {:error, _} -> []
          end)

        {:ok, matches, failures}
    end
  end

  defp slack_search(request, {query, count}),
    do: slack_search_pages(request, query, count, 1, 1, fn _ -> true end, [])

  defp slack_search(request, {query, count, max_pages, done?}),
    do: slack_search_pages(request, query, count, 1, max_pages, done?, [])

  defp slack_search_pages(request, query, count, page, max_pages, done?, acc) do
    case request.(
           "GET",
           SlackWebAPI.url("search.messages", %{
             "query" => query,
             "count" => count,
             "page" => page,
             "sort" => "timestamp",
             "sort_dir" => "desc",
             "highlight" => false
           }),
           max_bytes: 1_500_000
         ) do
      {:ok, %{"ok" => true, "messages" => %{"matches" => matches} = body}}
      when is_list(matches) ->
        valid =
          Enum.filter(matches, fn message ->
            is_map(message) and is_binary(message["text"]) and is_binary(message["permalink"])
          end)

        merged = Enum.uniq_by(acc ++ valid, & &1["permalink"])
        pages = get_in(body, ["paging", "pages"])

        if page < max_pages and is_integer(pages) and pages > page and valid != [] and
             not done?.(merged) do
          slack_search_pages(request, query, count, page + 1, max_pages, done?, merged)
        else
          {:ok, merged}
        end

      # Slack reports method errors such as missing_scope with HTTP 200.
      {:ok, %{"ok" => false, "error" => code}} when is_binary(code) ->
        if page == 1,
          do: {:error, {:member_provider_error, String.slice(code, 0, 64)}},
          else: {:ok, acc}

      {:error, _} = error ->
        if page == 1, do: error, else: {:ok, acc}

      _ ->
        if page == 1, do: {:error, :invalid_provider_response}, else: {:ok, acc}
    end
  end

  # Slack permalinks name the parent message of a thread reply.
  defp slack_thread(%{"permalink" => permalink}) do
    case Regex.run(~r/[?&]thread_ts=([0-9.]+)/, permalink) do
      [_, thread] -> thread
      _ -> nil
    end
  end

  defp interleave(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] ->
        []

      non_empty ->
        Enum.map(non_empty, &hd/1) ++ interleave(Enum.map(non_empty, &tl/1))
    end
  end

  defp bounded_message_text(text, user) when is_binary(text) do
    if String.length(text) <= @message_chars do
      text
    else
      mention = "<@#{user}>"

      case :binary.match(text, mention) do
        {byte_idx, _len} ->
          prefix_before = binary_part(text, 0, byte_idx)
          char_idx = String.length(prefix_before)

          if char_idx < @message_chars - 200 do
            String.slice(text, 0, @message_chars)
          else
            line_start =
              case String.split(prefix_before, "\n") do
                parts when length(parts) > 1 ->
                  char_idx - String.length(List.last(parts))

                _ ->
                  max(char_idx - 80, 0)
              end

            head = String.slice(text, 0, @message_preamble_chars)
            tail_budget = @message_chars - String.length(head) - 3
            # The tail keeps the whole mention and does not repeat the head.
            mention_reserve = max(200, String.length(mention))
            max_before_mention = max(tail_budget - mention_reserve, 0)

            tail_start =
              if line_start < @message_preamble_chars or
                   char_idx - line_start > max_before_mention,
                 do: max(@message_preamble_chars, char_idx - min(80, max_before_mention)),
                 else: line_start

            head <> "\n…\n" <> String.slice(text, tail_start, tail_budget)
          end

        :nomatch ->
          String.slice(text, 0, @message_chars)
      end
    end
  end

  defp bounded_message_text(_text, _user), do: ""
end
