defmodule SalixCalendar.Occurrences do
  @moduledoc "Bounded internal OccurrenceView queries over one Comma Calendar."

  alias SalixCalendar.{Recurrence, SchedulingLink, Server}
  alias SalixStore.Ids

  @max_occurrences 200

  def list(group_id, calendar_id, range_start_ms, range_end_ms, opts \\ [])

  def list(group_id, calendar_id, range_start_ms, range_end_ms, opts)
      when is_integer(range_start_ms) and is_integer(range_end_ms) do
    limit = Keyword.get(opts, :limit, 50)
    object_type = Keyword.get(opts, :object_type)
    source_ids = Keyword.get(opts, :source_ids)

    with true <- range_start_ms < range_end_ms,
         true <- is_integer(limit) and limit > 0 and limit <= @max_occurrences,
         true <- object_type in [nil, "Event", "Task"],
         true <- valid_source_ids?(source_ids),
         {:ok, items} <-
           Server.query_items(group_id, calendar_id, range_start_ms, range_end_ms,
             source_ids: source_ids
           ),
         {:ok, items} <- select_link_items(group_id, calendar_id, items, source_ids),
         {:ok, occurrences} <-
           expand(items, range_start_ms, range_end_ms, object_type, limit) do
      {:ok, Enum.sort_by(occurrences, &{get_in(&1, ["occurrence", "start_ms"]), item_id(&1)})}
    else
      false ->
        {:error, :invalid_occurrence_query}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_occurrence_query}
    end
  end

  def list(_group_id, _calendar_id, _range_start_ms, _range_end_ms, _opts),
    do: {:error, :invalid_occurrence_query}

  def get(group_id, calendar_id, calendar_item_id, occurrence_ref, opts \\ []) do
    source_ids = Keyword.get(opts, :source_ids)

    with true <- valid_source_ids?(source_ids),
         {:ok, item} <- Server.get_item(group_id, calendar_id, calendar_item_id),
         :ok <- require_live_item(item),
         true <- source_selected?(item, source_ids),
         link_id when is_binary(link_id) <- item["scheduling_link_id"],
         {:ok, selected} when is_map(selected) <-
           selected_link(group_id, calendar_id, link_id, source_ids),
         :ok <- require_selected_item(selected, calendar_item_id),
         {:ok, occurrence} <- Recurrence.resolve(item, occurrence_ref) do
      {:ok, %{"item" => item, "occurrence" => occurrence}}
    else
      nil ->
        {:error, :occurrence_not_found}

      {:ok, nil} ->
        {:error, :occurrence_not_found}

      {:error, :ambiguous} ->
        {:error, {:ambiguous_scheduling_link, occurrence_ref["scheduling_link_id"]}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :occurrence_not_found}
    end
  end

  defp require_live_item(%{
         "tombstoned_at" => nil,
         "normalization_state" => state
       })
       when state != "unsupported_timing",
       do: :ok

  defp require_live_item(_item), do: {:error, :occurrence_not_found}

  defp require_selected_item(%{"calendar_item_id" => calendar_item_id}, calendar_item_id),
    do: :ok

  defp require_selected_item(_selected, _calendar_item_id),
    do: {:error, :occurrence_copy_changed}

  defp expand(items, range_start_ms, range_end_ms, object_type, limit) do
    items
    |> Enum.reject(
      &(not is_nil(&1["tombstoned_at"]) or
          &1["normalization_state"] == "unsupported_timing")
    )
    |> Enum.filter(fn item ->
      is_nil(object_type) or get_in(item, ["object", "@type"]) == object_type
    end)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      remaining = limit + 1 - length(acc)

      case Recurrence.expand(item, range_start_ms, range_end_ms, limit: remaining) do
        {:ok, views} ->
          entries = Enum.map(views, &%{"item" => item, "occurrence" => &1})
          expanded = acc ++ entries

          if length(expanded) <= limit,
            do: {:cont, {:ok, expanded}},
            else: {:halt, {:error, :occurrence_limit_exceeded}}

        {:error, :occurrence_limit_exceeded} ->
          {:halt, {:error, :occurrence_limit_exceeded}}

        {:error, reason} ->
          {:halt, {:error, {item["calendar_item_id"], reason}}}
      end
    end)
  end

  defp select_link_items(group_id, calendar_id, items, source_ids) do
    items = Enum.filter(items, &source_selected?(&1, source_ids))

    items
    |> Enum.map(& &1["scheduling_link_id"])
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn link_id, {:ok, selected} ->
      case selected_link(group_id, calendar_id, link_id, source_ids) do
        {:ok, nil} -> {:cont, {:ok, selected}}
        {:ok, item} -> {:cont, {:ok, [item | selected]}}
        {:error, :ambiguous} -> {:halt, {:error, {:ambiguous_scheduling_link, link_id}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp selected_link(group_id, calendar_id, link_id, source_ids) do
    with {:ok, copies} <-
           Server.list_link_items(group_id, calendar_id, link_id, source_ids: source_ids),
         do: SchedulingLink.select_item(Enum.filter(copies, &source_selected?(&1, source_ids)))
  end

  defp item_id(%{"item" => item}), do: item["calendar_item_id"] || ""

  defp valid_source_ids?(nil), do: true

  defp valid_source_ids?(source_ids) when is_list(source_ids) do
    source_ids != [] and length(source_ids) <= 50 and
      length(source_ids) == length(Enum.uniq(source_ids)) and
      Enum.all?(source_ids, &Ids.valid_calendar_source_id?/1)
  end

  defp valid_source_ids?(_source_ids), do: false

  defp source_selected?(_item, nil), do: true

  defp source_selected?(item, source_ids),
    do: get_in(item, ["origin", "source_id"]) in source_ids
end
