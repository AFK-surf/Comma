defmodule CommaWeb.RecommendationSlackMemberSource do
  @moduledoc false

  alias CommaWeb.{RecommendationMemberRead, SlackWebAPI}

  @own_days 30
  @own_count 100
  @target_count 20
  @per_target 5
  @targets_total 10
  @target_bytes 600
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

    with {:ok, auth} <- request.("GET", SlackWebAPI.url("auth.test"), []),
         true <- auth["ok"] == true and is_nil(auth["bot_id"]),
         user when is_binary(user) <- auth["user_id"],
         team when is_binary(team) <- auth["team_id"],
         true <- Regex.match?(~r/^[UW][A-Z0-9]+$/, user) and Regex.match?(~r/^T[A-Z0-9]+$/, team),
         :ok <- verify_subject(user, team, expected_subject),
         after_date = now |> DateTime.add(-604_800, :second) |> DateTime.to_date(),
         since = now |> DateTime.add(-86_400, :second) |> DateTime.to_date(),
         {:ok, [mentions, direct, threads], failures} <-
           slack_searches(request, [
             {"<@#{user}> after:#{after_date}", 40},
             {"to:me after:#{after_date}", 100},
             {"is:thread with:<@#{user}> after:#{after_date}", 100}
           ]),
         {:ok, in_places, place_failures} <-
           target_searches(
             request,
             for(name <- targets["channels"] || [], do: "in:##{name} after:#{since}")
           ) do
      failures = failures ++ place_failures

      mentions =
        mentions
        |> Enum.filter(&(String.contains?(&1["text"], "<@#{user}>") and &1["user"] != user))
        |> Enum.take(20)
        |> Enum.map(&Map.put(&1, "memberRelation", "mentioned_you"))

      # Newest first, so the first message per conversation or thread is its latest.
      direct =
        direct
        |> Enum.filter(&(get_in(&1, ["channel", "is_im"]) == true and &1["user"] != user))
        |> Enum.uniq_by(&get_in(&1, ["channel", "id"]))
        |> Enum.take(10)
        |> Enum.map(&Map.put(&1, "memberRelation", "direct_message_to_you"))

      threads =
        threads
        |> Enum.filter(&is_binary(slack_thread(&1)))
        |> Enum.uniq_by(&{get_in(&1, ["channel", "id"]), slack_thread(&1)})
        |> Enum.reject(&(&1["user"] == user))
        |> Enum.take(10)
        |> Enum.map(&Map.put(&1, "memberRelation", "replied_in_your_thread"))

      # The member's own threads already reach them through `threads`.
      joined = MapSet.new(threads, &{get_in(&1, ["channel", "id"]), slack_thread(&1)})

      matches =
        (mentions ++
           direct ++
           threads ++
           (in_places
            |> targeted(user, joined)
            |> Enum.take(@targets_total)))
        |> Enum.uniq_by(& &1["permalink"])

      names = mention_names(request, Enum.map(matches, & &1["text"]))

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

    with {:ok, auth} <- request.("GET", SlackWebAPI.url("auth.test"), []),
         true <- auth["ok"] == true and is_nil(auth["bot_id"]),
         user when is_binary(user) <- auth["user_id"],
         team when is_binary(team) <- auth["team_id"],
         :ok <- verify_subject(user, team, expected_subject),
         after_date = now |> DateTime.add(-@own_days * 86_400, :second) |> DateTime.to_date(),
         {:ok, matches} <-
           slack_search(request, {"from:<@#{user}> after:#{after_date}", @own_count}) do
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
          &thread_read(request, &1, replies?),
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
  def thread_news(request, threads) do
    with {:ok, %{"ok" => true, "user_id" => user}} when is_binary(user) <-
           request.("GET", SlackWebAPI.url("auth.test"), []) do
      {:ok,
       threads
       |> Enum.to_list()
       |> RecommendationMemberRead.map(&thread_since(request, &1, user), 1)
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

  defp thread_since(request, {id, {channel, thread, since}}, user) do
    case request.(
           "GET",
           SlackWebAPI.url("conversations.replies", %{
             "channel" => channel,
             "ts" => thread,
             "oldest" => since,
             "inclusive" => "false",
             "limit" => 15
           }),
           max_bytes: 200_000
         ) do
      {:ok, %{"ok" => true, "messages" => messages}} when is_list(messages) ->
        {:ok, id,
         messages
         |> Enum.filter(&(is_binary(&1["text"]) and ts_after?(&1["ts"], since)))
         |> Enum.take(@own_replies * 2)
         |> Enum.map(
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

  # The thread a message belongs to; with replies, also the one it starts.
  defp own_thread(message, false), do: slack_thread(message)
  defp own_thread(message, true), do: slack_thread(message) || message["ts"]

  # The thread's start, and with replies its first messages.
  defp thread_read(request, {channel, thread}, replies?) do
    case request.(
           "GET",
           SlackWebAPI.url("conversations.replies", %{
             "channel" => channel,
             "ts" => thread,
             "limit" => if(replies?, do: 15, else: 1)
           }),
           max_bytes: 200_000
         ) do
      {:ok, %{"ok" => true, "messages" => [%{"text" => text} | _] = messages}}
      when is_binary(text) ->
        {:ok, {channel, thread}, Enum.filter(messages, &is_binary(&1["text"]))}

      _ ->
        :error
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

  defp target_searches(_request, []), do: {:ok, [], []}

  defp target_searches(request, queries) do
    case slack_searches(request, Enum.map(queries, &{&1, @target_count})) do
      {:ok, matches, failures} -> {:ok, matches, failures}
      # The direct relationships stay readable when no target is.
      {:error, reason} -> {:ok, [], [reason]}
    end
  end

  # Per channel: the latest message of each thread, not the member's own and
  # not a thread they joined, that a bot or integration posted or that asks
  # someone for something, at most #{@per_target}, its text cut to
  # #{@target_bytes} characters.
  defp targeted(results, user, joined) do
    Enum.flat_map(results, fn matches ->
      matches
      |> Enum.reject(&(&1["user"] == user))
      |> Enum.uniq_by(&{get_in(&1, ["channel", "id"]), slack_thread(&1) || &1["ts"]})
      |> Enum.reject(&MapSet.member?(joined, {get_in(&1, ["channel", "id"]), slack_thread(&1)}))
      |> Enum.filter(&(bot?(&1) or Regex.match?(@asks, &1["text"] || "")))
      |> Enum.take(@per_target)
      |> Enum.map(fn match ->
        match
        |> Map.update("text", "", &String.slice(&1, 0, @target_bytes))
        |> Map.put("memberRelation", "posted_where_your_work_is")
      end)
    end)
  end

  # Slack writes a mention as the person's ID. The quote names them as
  # `<@U…|name>`, at most #{@named_most} people per read; a person whose name
  # cannot be read stays an ID.
  defp mention_names(request, texts) do
    texts
    |> Enum.flat_map(&Regex.scan(@mention, &1, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.take(@named_most)
    |> RecommendationMemberRead.map(&{&1, user_name(request, &1)}, 3)
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

  defp slack_search(request, {query, count}) do
    case request.(
           "GET",
           SlackWebAPI.url("search.messages", %{
             "query" => query,
             "count" => count,
             "page" => 1,
             "sort" => "timestamp",
             "sort_dir" => "desc",
             "highlight" => false
           }),
           max_bytes: 1_500_000
         ) do
      {:ok, %{"ok" => true, "messages" => %{"matches" => matches}}} when is_list(matches) ->
        {:ok,
         Enum.filter(matches, fn message ->
           is_map(message) and is_binary(message["text"]) and is_binary(message["permalink"])
         end)}

      # Slack reports method errors such as missing_scope with HTTP 200.
      {:ok, %{"ok" => false, "error" => code}} when is_binary(code) ->
        {:error, {:member_provider_error, String.slice(code, 0, 64)}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_provider_response}
    end
  end

  # Slack permalinks name the parent message of a thread reply.
  defp slack_thread(%{"permalink" => permalink}) do
    case Regex.run(~r/[?&]thread_ts=([0-9.]+)/, permalink) do
      [_, thread] -> thread
      _ -> nil
    end
  end
end
