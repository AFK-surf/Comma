defmodule SalixCalendar.Query do
  @moduledoc "Read-only projection used exclusively by `SalixCalendar.SourceActor`."

  alias SalixStore.{CasRecord, Ids, Keys, S3}

  @max_page_size 200
  @max_source_members 10_000
  @max_query_candidates 1_000
  @max_query_months 120
  @max_link_members 200

  def get_item(source, item_id) do
    with true <- Ids.valid_calendar_item_id?(item_id),
         {:ok, _member} <-
           record(
             Keys.ctl_calendar_source_member(
               source["group_id"],
               source["calendar_id"],
               source["source_id"],
               item_id
             )
           ),
         {:ok, envelope} <-
           record(Keys.ctl_calendar_item(source["group_id"], source["calendar_id"], item_id)),
         item when is_map(item) <- materialize(envelope, source["active_generation"] || 0) do
      {:ok, item}
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_calendar_item_id}
      {:error, _} = error -> error
    end
  end

  def list_items(source, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    cursor = Keyword.get(opts, :cursor)

    if is_integer(limit) and limit in 1..@max_page_size and (is_nil(cursor) or is_binary(cursor)) do
      with {:ok, item_ids, next} <- source_member_page(source, cursor, limit),
           {:ok, items} <- hydrate_items(source, item_ids) do
        {:ok, %{"data" => items, "next_cursor" => next}}
      end
    else
      {:error, :invalid_page}
    end
  end

  def query_items(source, range_start_ms, range_end_ms) do
    group_id = source["group_id"]
    calendar_id = source["calendar_id"]

    with {:ok, months} <- interval_months(range_start_ms, range_end_ms, @max_query_months),
         prefixes <-
           [
             Keys.ctl_calendar_query_recurring_prefix(group_id, calendar_id),
             Keys.ctl_calendar_query_spanning_prefix(group_id, calendar_id)
           ] ++ Enum.map(months, &Keys.ctl_calendar_query_month_prefix(group_id, calendar_id, &1)),
         {:ok, item_ids} <- indexed_item_ids(prefixes),
         {:ok, items} <- hydrate_items(source, item_ids) do
      {:ok, items}
    end
  end

  def list_link_items(source, link_id) do
    with true <- Ids.valid_scheduling_link_id?(link_id),
         {:ok, item_ids} <- link_item_ids(source["group_id"], source["calendar_id"], link_id),
         {:ok, items} <- hydrate_items(source, item_ids) do
      {:ok, Enum.filter(items, &(&1["scheduling_link_id"] == link_id))}
    else
      false -> {:error, :invalid_scheduling_link_id}
      {:error, _} = error -> error
    end
  end

  def scheduling_link_live?(group_id, calendar_id, link_id) do
    with {:ok, item_ids} <- link_item_ids(group_id, calendar_id, link_id) do
      Enum.reduce_while(item_ids, {:ok, false}, fn item_id, {:ok, false} ->
        case live_member?(group_id, calendar_id, link_id, item_id) do
          {:ok, true} -> {:halt, {:ok, true}}
          {:ok, false} -> {:cont, {:ok, false}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  def source_member_page(source, cursor, limit \\ @max_page_size) do
    with {:ok, %{objects: objects, next: next}} <-
           S3.list(
             Keys.ctl_calendar_source_members_prefix(
               source["group_id"],
               source["calendar_id"],
               source["source_id"]
             ),
             page_opts(min(limit, @max_source_members), cursor)
           ),
         {:ok, item_ids} <- object_item_ids(objects) do
      {:ok, item_ids, next}
    end
  end

  def interval_months(start_ms, end_ms, limit)
      when is_integer(start_ms) and is_integer(end_ms) and start_ms < end_ms do
    with {:ok, first} <- DateTime.from_unix(start_ms, :millisecond),
         {:ok, last} <- DateTime.from_unix(end_ms - 1, :millisecond) do
      first_month = first.year * 12 + first.month - 1
      last_month = last.year * 12 + last.month - 1

      if last_month - first_month < limit,
        do: {:ok, Enum.map(first_month..last_month, &month_key/1)},
        else: {:error, :calendar_query_range_too_large}
    end
  end

  def interval_months(_start_ms, _end_ms, _limit), do: {:error, :invalid_occurrence_query}

  def envelope(group_id, calendar_id, item_id),
    do: record(Keys.ctl_calendar_item(group_id, calendar_id, item_id))

  def materialize(%{"versions" => versions} = envelope, generation) when is_map(versions) do
    case versions[Integer.to_string(generation)] do
      %{"base" => base} = version when is_map(base) ->
        overrides = version["overrides"] || %{}

        base
        |> apply_overrides(overrides)
        |> Map.merge(Map.take(envelope, ~w(calendar_item_id calendar_id origin)))

      _ ->
        nil
    end
  end

  def materialize(_envelope, _generation), do: nil

  defp apply_overrides(base, overrides) do
    recurrence_overrides =
      Map.new(overrides, fn {key, entry} -> {key, entry["override"]} end)

    recurrence_instances =
      Map.new(overrides, fn {key, entry} -> {key, entry["instance_id"]} end)

    base
    |> update_in(["object"], &merge_field(&1, "recurrenceOverrides", recurrence_overrides))
    |> update_in(
      ["source_version"],
      &merge_field(&1, "recurrence_instances", recurrence_instances)
    )
  end

  defp merge_field(map, key, additions) when is_map(map),
    do: Map.update(map, key, additions, &Map.merge(&1, additions))

  defp merge_field(value, _key, _additions), do: value

  defp indexed_item_ids(prefixes) do
    Enum.reduce_while(prefixes, {:ok, MapSet.new()}, fn prefix, {:ok, ids} ->
      case S3.list(prefix, max_keys: @max_query_candidates + 1) do
        {:ok, %{objects: objects, next: next}}
        when length(objects) <= @max_query_candidates and is_nil(next) ->
          with {:ok, item_ids} <- object_item_ids(objects) do
            merged = Enum.reduce(item_ids, ids, &MapSet.put(&2, &1))

            if MapSet.size(merged) <= @max_query_candidates,
              do: {:cont, {:ok, merged}},
              else: {:halt, {:error, :calendar_query_index_budget_exceeded}}
          else
            {:error, _} = error -> {:halt, error}
          end

        {:ok, _too_many} ->
          {:halt, {:error, :calendar_query_index_budget_exceeded}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  defp hydrate_items(source, item_ids),
    do: parallel(item_ids, &get_item(source, &1))

  defp live_member?(group_id, calendar_id, link_id, item_id) do
    with true <- Ids.valid_calendar_item_id?(item_id),
         {:ok, %{"origin" => %{"source_id" => source_id}} = envelope} <-
           record(Keys.ctl_calendar_item(group_id, calendar_id, item_id)),
         {:ok, source} <- record(Keys.ctl_calendar_source(group_id, calendar_id, source_id)) do
      case materialize(envelope, source["active_generation"] || 0) do
        %{"scheduling_link_id" => ^link_id} = item ->
          {:ok,
           is_nil(item["tombstoned_at"]) and
             item["normalization_state"] != "unsupported_timing"}

        _ ->
          {:ok, false}
      end
    else
      false -> {:error, :invalid_scheduling_link_member}
      {:error, _} = error -> error
    end
  end

  defp parallel(values, fun) do
    values
    |> Task.async_stream(fun,
      ordered: true,
      max_concurrency: 8,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, value}}, {:ok, values} ->
        {:cont, {:ok, [value | values]}}

      {:ok, {:error, :not_found}}, {:ok, values} ->
        {:cont, {:ok, values}}

      {:ok, {:error, reason}}, _ ->
        {:halt, {:error, reason}}

      {:exit, reason}, _ ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp record(key), do: CasRecord.get(key, :invalid_calendar_source_projection)

  defp link_item_ids(group_id, calendar_id, link_id) do
    case S3.list(Keys.ctl_calendar_link_members_prefix(group_id, calendar_id, link_id),
           max_keys: @max_link_members
         ) do
      {:ok, %{objects: objects, next: nil}} -> object_item_ids(objects)
      {:ok, _} -> {:error, :scheduling_link_member_budget_exceeded}
      {:error, _} = error -> error
    end
  end

  defp object_item_ids(objects) do
    ids = Enum.map(objects, &(&1.key |> Path.basename() |> Path.rootname(".json")))

    if Enum.all?(ids, &Ids.valid_calendar_item_id?/1),
      do: {:ok, ids},
      else: {:error, :invalid_calendar_query_index}
  end

  defp page_opts(limit, nil), do: [max_keys: limit]
  defp page_opts(limit, cursor), do: [max_keys: limit, continuation_token: cursor]

  defp month_key(index),
    do: "#{div(index, 12)}-" <> String.pad_leading(Integer.to_string(rem(index, 12) + 1), 2, "0")
end
