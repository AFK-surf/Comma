defmodule CommaWeb.RecommendationSlackMemberSource do
  @moduledoc false

  alias CommaWeb.{RecommendationMemberRead, SlackWebAPI}

  @own_days 30
  @own_count 100
  @target_count 20
  @per_target 5
  @targets_total 10
  @target_bytes 600
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

      selected =
        (mentions ++
           direct ++
           threads ++
           (in_places
            |> targeted(user, joined)
            |> Enum.take(@targets_total)))
        |> Enum.uniq_by(& &1["permalink"])
        |> Enum.map(fn item ->
          neighbors =
            Map.new(~w(previous_2 previous next next_2), fn key ->
              message = item[key]
              {key, if(is_map(message), do: Map.take(message, ~w(text ts user)), else: nil)}
            end)

          context =
            CommaWeb.RecommendationSourceContext.attach(
              neighbors,
              Map.keys(neighbors),
              "search_neighbors"
            )["context"]

          item
          |> Map.take(~w(text ts permalink memberRelation))
          |> Map.put("context", context)
          |> CommaWeb.RecommendationSourceQuote.put(
            author: item["username"],
            body: {:slack, item["text"]}
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

  @doc """
  The member's own messages from the last #{@own_days} days, newest first, each
  with the text of the thread it answered: what the member said and did, the
  evidence of their portrait (`CommaWeb.MemberPortrait`). At most
  #{@own_threads} threads are read.
  """
  def own_messages(request, now, expected_subject \\ nil) do
    with {:ok, auth} <- request.("GET", SlackWebAPI.url("auth.test"), []),
         true <- auth["ok"] == true and is_nil(auth["bot_id"]),
         user when is_binary(user) <- auth["user_id"],
         team when is_binary(team) <- auth["team_id"],
         :ok <- verify_subject(user, team, expected_subject),
         after_date = now |> DateTime.add(-@own_days * 86_400, :second) |> DateTime.to_date(),
         {:ok, matches} <-
           slack_search(request, {"from:<@#{user}> after:#{after_date}", @own_count}) do
      own = Enum.filter(matches, &(&1["user"] == user))

      parents =
        own
        |> Enum.flat_map(fn message ->
          case {get_in(message, ["channel", "id"]), slack_thread(message)} do
            {channel, thread} when is_binary(channel) and is_binary(thread) -> [{channel, thread}]
            _ -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.take(@own_threads)
        |> RecommendationMemberRead.map(&thread_parent(request, &1), 3)
        |> Enum.flat_map(fn
          {:ok, key, text} -> [{key, text}]
          _ -> []
        end)
        |> Map.new()

      {:ok,
       Enum.map(own, fn message ->
         key = {get_in(message, ["channel", "id"]), slack_thread(message)}

         %{
           "text" => message["text"],
           "ts" => message["ts"],
           "permalink" => message["permalink"],
           "channel" => get_in(message, ["channel", "name"]),
           "direct" =>
             get_in(message, ["channel", "is_im"]) == true or
               get_in(message, ["channel", "is_mpim"]) == true,
           "thread" => parents[key]
         }
         |> Map.reject(fn {_key, value} -> is_nil(value) end)
       end),
       %{"provider_user_id" => user, "provider_workspace_id" => team, "handle" => auth["user"]}}
    else
      {:error, _} = error -> error
      _ -> {:error, :member_identity_or_source_unavailable}
    end
  end

  defp thread_parent(request, {channel, thread}) do
    case request.(
           "GET",
           SlackWebAPI.url("conversations.replies", %{
             "channel" => channel,
             "ts" => thread,
             "limit" => 1
           }),
           max_bytes: 200_000
         ) do
      {:ok, %{"ok" => true, "messages" => [%{"text" => text} | _]}} when is_binary(text) ->
        {:ok, {channel, thread}, String.slice(text, 0, 1_200)}

      _ ->
        :error
    end
  end

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
