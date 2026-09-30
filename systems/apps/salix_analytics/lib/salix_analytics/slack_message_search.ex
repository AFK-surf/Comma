defmodule SalixAnalytics.SlackMessageSearch do
  @moduledoc """
  Bounded index query adapter for the group-owned message search facade.
  Keyword matching is an explicit literal substring strategy; hybrid combines
  two finite rankings with RRF, without silently substituting one for another.
  """
  alias SalixAnalytics.{SlackMessageSearchIndex, SlackSemanticIndex}

  def active?, do: SlackSemanticIndex.active?()

  def candidates(scope, connects, request) do
    started = System.monotonic_time()
    result = do_candidates(scope, connects, request)

    outcome =
      case result do
        {:ok, _} -> "ok"
        {:error, :read_over_budget} -> "over_budget"
        _ -> "error"
      end

    SlackSemanticIndex.observe("slack_message_search", started, outcome)
    result
  end

  defp do_candidates(_scope, [], _request), do: {:ok, []}

  defp do_candidates(scope, connects, request) do
    filters = %{
      mode: mode(request["mode"]),
      oldest: request["oldest"],
      latest: request["latest"],
      workspace: request["workspace"],
      sender: request["sender"] || "",
      channel: request["channel"],
      kind: request["kind"]
    }

    if filters.mode == :keyword do
      SlackMessageSearchIndex.candidates(scope, connects, request["query"], nil, filters, 200)
    else
      with {:ok, vector} <- SlackSemanticIndex.embed(request["query"]) do
        if filters.mode == :semantic do
          SlackMessageSearchIndex.candidates(
            scope,
            connects,
            request["query"],
            vector,
            filters,
            200
          )
        else
          with {:ok, semantic} <-
                 SlackMessageSearchIndex.candidates(
                   scope,
                   connects,
                   request["query"],
                   vector,
                   %{filters | mode: :semantic},
                   100
                 ),
               {:ok, keyword} <-
                 SlackMessageSearchIndex.candidates(
                   scope,
                   connects,
                   request["query"],
                   nil,
                   %{filters | mode: :keyword},
                   100
                 ) do
            {:ok, fuse(semantic, keyword)}
          end
        end
      end
    end
  end

  defdelegate current_sources(tenant, candidates), to: SlackMessageSearchIndex
  defdelegate excerpts(scope, candidates), to: SlackMessageSearchIndex

  defp fuse(semantic, keyword) do
    [semantic, keyword]
    |> Enum.reduce(%{}, fn ranking, acc ->
      ranking
      |> Enum.with_index(1)
      |> Enum.reduce(acc, fn {row, rank}, found ->
        key = SlackMessageSearchIndex.source_key(row)

        Map.update(found, key, {row, 1.0 / (60 + rank)}, fn {_first, score} ->
          {row, score + 1.0 / (60 + rank)}
        end)
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {row, score} ->
      {-score, -row["message_ts_us"], row["workspace_id"], row["channel_id"]}
    end)
    |> Enum.map(fn {row, score} -> Map.put(row, "rrf_score", score) end)
  end

  defp mode("semantic"), do: :semantic
  defp mode("keyword"), do: :keyword
  defp mode("hybrid"), do: :hybrid
end
