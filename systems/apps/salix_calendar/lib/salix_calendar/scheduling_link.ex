defmodule SalixCalendar.SchedulingLink do
  @moduledoc "Scheduling-role resolution for the currently visible copies of one link."

  def select_item(items) when is_list(items) do
    live = Enum.reject(items, & &1["tombstoned_at"])
    organizers = Enum.filter(live, &(&1["copy_role"] == "organizer"))

    case organizers do
      [] -> select_observation(live)
      copies -> select_ranked(copies)
    end
  end

  defp select_observation([]), do: {:ok, nil}
  defp select_observation(copies), do: select_ranked(copies)

  defp select_ranked([copy]), do: {:ok, copy}

  defp select_ranked(copies) do
    with {:ok, ranked} <- comparable_revisions(copies),
         highest <- ranked |> Enum.map(&elem(&1, 1)) |> Enum.max(),
         leaders <- Enum.filter(ranked, &(elem(&1, 1) == highest)),
         true <- compatible_leaders?(leaders) do
      selected =
        leaders
        |> Enum.map(&elem(&1, 0))
        |> Enum.max_by(&(&1["calendar_item_id"] || ""))

      {:ok, selected}
    else
      _ -> {:error, :ambiguous}
    end
  end

  defp comparable_revisions(copies) do
    ranked = Enum.map(copies, &{&1, revision_rank(&1)})

    with true <- Enum.all?(ranked, &match?({_copy, {:ok, _rank}}, &1)),
         [_family] <-
           ranked
           |> Enum.map(fn {_copy, {:ok, {family, _value}}} -> family end)
           |> Enum.uniq() do
      {:ok, Enum.map(ranked, fn {copy, {:ok, rank}} -> {copy, rank} end)}
    else
      _ -> {:error, :incomparable}
    end
  end

  defp revision_rank(item) do
    revision = item["scheduling_revision"] || %{}
    sequence = revision["sequence"]
    timestamp = revision["updated"] || revision["timestamp"]
    timestamp_rank = timestamp_rank(timestamp)

    cond do
      is_integer(sequence) -> {:ok, {:sequence, {sequence, timestamp_rank}}}
      timestamp_rank >= 0 -> {:ok, {:timestamp, timestamp_rank}}
      true -> {:error, :incomparable}
    end
  end

  defp timestamp_rank(value) when is_integer(value), do: value

  defp timestamp_rank(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      _ -> -1
    end
  end

  defp timestamp_rank(_value), do: -1

  defp compatible_leaders?([_single]), do: true

  defp compatible_leaders?(leaders) do
    hashes =
      Enum.map(leaders, fn {copy, _rank} ->
        get_in(copy, ["scheduling_revision", "shared_fact_hash"])
      end)

    Enum.all?(hashes, &(is_binary(&1) and &1 != "")) and length(Enum.uniq(hashes)) == 1
  end
end
