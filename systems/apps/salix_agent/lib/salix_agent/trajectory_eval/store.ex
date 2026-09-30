defmodule SalixAgent.TrajectoryEval.Store do
  @moduledoc """
  Session-adjacent persistence for trajectory eval results.

  One JSON object per `{agent_id, session_id}` holding the most recent eval
  entries (newest first). This is the dashboard's read path; the analytics
  ClickHouse rows emitted by the recorder are the aggregation path. Writes are
  last-writer-wins: evals for one session are serialized behind its round
  lifecycle, so concurrent writers are not expected.

  Consecutive entries with the same signature (outcome + metric set) are
  merged instead of appended: the newest entry is replaced with the fresh one
  carrying `"repeats"` and `"first_evaluated_at"`. A self-waking session that
  settles the same way every round (the runaway-polling case) therefore holds
  one entry per *state*, not one per settle.
  """

  alias SalixStore.{Ids, Keys, S3}

  @max_entries 50

  @spec read(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read(agent_id, session_id) do
    if Ids.valid_session_id?(session_id) do
      case S3.get(Keys.agent_session_trajectory_eval(agent_id, session_id)) do
        {:ok, %{body: body}} -> decode(body)
        {:error, _} = err -> err
      end
    else
      {:error, :invalid_session_id}
    end
  end

  @doc """
  Append an eval entry, merging into the newest entry when the signature is
  unchanged. Returns the stored entry; `"repeats" > 1` means it was merged.
  """
  @spec append(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def append(agent_id, session_id, entry) when is_map(entry) do
    with true <- Ids.valid_session_id?(session_id) do
      existing =
        case read(agent_id, session_id) do
          {:ok, doc} -> doc["evals"] || []
          _ -> []
        end

      {evals, stored} = merge(existing, entry)

      doc = %{
        "session_id" => session_id,
        "agent_id" => agent_id,
        "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "evals" => Enum.take(evals, @max_entries)
      }

      case S3.put(Keys.agent_session_trajectory_eval(agent_id, session_id), Jason.encode!(doc)) do
        {:ok, _} -> {:ok, stored}
        {:error, _} = err -> err
      end
    else
      false -> {:error, :invalid_session_id}
    end
  end

  @doc """
  Attach an LLM-judge result to the stored entry matching `stored_entry`'s
  signature (newest first). The judge runs after `append/3` returns, so under
  debounce the target entry may already carry bumped `repeats` — matching by
  signature instead of timestamp tolerates that.
  """
  @spec attach_judge(String.t(), String.t(), map(), map()) :: :ok | {:error, term()}
  def attach_judge(agent_id, session_id, stored_entry, judge) when is_map(judge) do
    with {:ok, doc} <- read(agent_id, session_id) do
      evals = doc["evals"] || []

      case Enum.find_index(evals, &(signature(&1) == signature(stored_entry))) do
        nil ->
          {:error, :entry_not_found}

        index ->
          doc = %{
            doc
            | "evals" => List.update_at(evals, index, &Map.put(&1, "judge", judge)),
              "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

          case S3.put(
                 Keys.agent_session_trajectory_eval(agent_id, session_id),
                 Jason.encode!(doc)
               ) do
            {:ok, _} -> :ok
            {:error, _} = err -> err
          end
      end
    end
  end

  # Same signature as the newest entry → replace it in place, keeping the
  # latest window/findings values but accumulating the repeat count and the
  # first-seen timestamp. Different signature → plain prepend.
  defp merge([head | rest] = existing, entry) do
    if signature(head) == signature(entry) do
      merged =
        entry
        |> Map.put("repeats", (head["repeats"] || 1) + 1)
        |> Map.put("first_evaluated_at", head["first_evaluated_at"] || head["evaluated_at"])
        |> keep_judge(head)

      {[merged | rest], merged}
    else
      {[entry | existing], entry}
    end
  end

  defp merge([], entry), do: {[entry], entry}

  # The judge runs once per signature change, so a debounced repeat must not
  # drop the verdicts already attached to the entry it merges into.
  defp keep_judge(entry, %{"judge" => %{} = judge}), do: Map.put_new(entry, "judge", judge)
  defp keep_judge(entry, _head), do: entry

  defp signature(entry) do
    metrics =
      entry["findings"]
      |> List.wrap()
      |> Enum.map(& &1["metric"])
      |> Enum.sort()

    {entry["outcome"], metrics}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = doc} -> {:ok, doc}
      {:ok, _} -> {:error, :invalid_document}
      {:error, _} = err -> err
    end
  end
end
