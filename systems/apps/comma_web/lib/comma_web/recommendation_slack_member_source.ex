defmodule CommaWeb.RecommendationSlackMemberSource do
  @moduledoc false

  alias CommaWeb.RecommendationMemberRead

  @slack "https://slack.com/api"

  # Three direct relationships from the last seven days: messages that mention
  # the member, one-to-one direct messages to the member, and threads the
  # member joined whose latest message is from someone else.
  def read(request, now, expected_subject \\ nil) do
    with {:ok, auth} <- request.("GET", @slack <> "/auth.test", []),
         true <- auth["ok"] == true and is_nil(auth["bot_id"]),
         user when is_binary(user) <- auth["user_id"],
         team when is_binary(team) <- auth["team_id"],
         true <- Regex.match?(~r/^[UW][A-Z0-9]+$/, user) and Regex.match?(~r/^T[A-Z0-9]+$/, team),
         :ok <- verify_subject(user, team, expected_subject),
         after_date = now |> DateTime.add(-604_800, :second) |> DateTime.to_date(),
         {:ok, [mentions, direct, threads], failures} <-
           slack_searches(request, [
             {"<@#{user}> after:#{after_date}", 40},
             {"to:me after:#{after_date}", 100},
             {"is:thread with:<@#{user}> after:#{after_date}", 100}
           ]) do
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

      selected =
        (mentions ++ direct ++ threads)
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

          item |> Map.take(~w(text ts permalink memberRelation)) |> Map.put("context", context)
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
           @slack <>
             "/search.messages?" <>
             URI.encode_query(%{
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
