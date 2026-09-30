defmodule SalixCalendar.LocalStore do
  @moduledoc """
  Read-only projection of Comma-local items for owner-scoped Feed reads.

  Reads are bounded by owner/month markers and never scan the whole group
  Calendar. Markers are not authorization authority: every result revalidates the
  hydrated item's current `owner_principal_ref` and local origin, so a stale
  marker can cost bounded work but can never disclose another principal's Event.
  """

  alias SalixCalendar.LocalItem
  alias SalixStore.{CasRecord, Keys, S3}

  @max_candidates 2000
  @subject_keys ~w(namespace tenant_id subject_id)

  @spec get_local_item(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_local_item(group_id, calendar_id, item_id) do
    if valid_scope?(group_id, calendar_id) and valid_item?(item_id) do
      case CasRecord.get(item_key(group_id, calendar_id, item_id), :invalid_calendar_record) do
        {:ok, %{"origin" => %{"kind" => "local"}} = item} -> {:ok, item}
        {:ok, _non_local} -> {:error, :not_found}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_local_item}
    end
  end

  @doc """
  Owner-scoped local items whose start month overlaps the fixed Feed horizon.

  Fails explicitly when the candidate set exceeds the item budget rather than
  silently omitting authorized items.
  """
  @spec list_for_owner(String.t(), String.t(), map(), integer(), integer(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_for_owner(group_id, calendar_id, owner, from_ms, to_ms, opts \\ [])
      when is_integer(from_ms) and is_integer(to_ms) and from_ms <= to_ms do
    limit = opts |> Keyword.get(:limit, @max_candidates) |> min(@max_candidates)

    with true <- valid_scope?(group_id, calendar_id) or {:error, :invalid_local_item},
         {:ok, owner} <- LocalItem.owner(owner),
         digest <- LocalItem.owner_digest(owner),
         {:ok, item_ids} <- candidate_ids(group_id, calendar_id, digest, from_ms, to_ms, limit) do
      hydrate(group_id, calendar_id, owner, item_ids)
    else
      {:error, _} = error -> error
    end
  end

  defp candidate_ids(group_id, calendar_id, digest, from_ms, to_ms, limit) do
    from_ms
    |> horizon_months(to_ms)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn month, {:ok, ids} ->
      prefix = Keys.ctl_calendar_query_owner_month_prefix(group_id, calendar_id, digest, month)

      case S3.list(prefix, max_keys: limit + 1) do
        {:ok, %{objects: objects, next: nil}} ->
          case object_item_ids(objects) do
            {:ok, month_ids} ->
              merged = Enum.reduce(month_ids, ids, &MapSet.put(&2, &1))

              if MapSet.size(merged) <= limit,
                do: {:cont, {:ok, merged}},
                else: {:halt, {:error, :calendar_feed_too_large}}

            {:error, _} = error ->
              {:halt, error}
          end

        {:ok, _paged} ->
          {:halt, {:error, :calendar_feed_too_large}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  # A GET that proves the marker stale (`:not_found`) or points at a non-local /
  # non-owned item is safely skipped. A backend or invalid-record failure is NOT
  # proof of absence, so it fails the whole feed rather than silently omitting an
  # authorized Event (which a calendar client would read as a deletion).
  defp hydrate(group_id, calendar_id, owner, item_ids) do
    item_ids
    |> Enum.reduce_while({:ok, []}, fn item_id, {:ok, acc} ->
      case CasRecord.get(item_key(group_id, calendar_id, item_id), :invalid_calendar_record) do
        {:ok, %{"origin" => %{"kind" => "local"}, "owner_principal_ref" => item_owner} = item} ->
          if canonical(item_owner) == owner,
            do: {:cont, {:ok, [item | acc]}},
            else: {:cont, {:ok, acc}}

        {:ok, _non_local} ->
          {:cont, {:ok, acc}}

        {:error, :not_found} ->
          {:cont, {:ok, acc}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _} = error -> error
    end
  end

  defp horizon_months(from_ms, to_ms) do
    start = month_index(from_ms)
    stop = month_index(to_ms)

    for index <- start..stop do
      {year, month0} = {div(index, 12), rem(index, 12)}
      "#{year}-#{pad2(month0 + 1)}"
    end
  end

  defp month_index(ms) do
    dt = DateTime.from_unix!(ms, :millisecond)
    dt.year * 12 + (dt.month - 1)
  end

  defp object_item_ids(objects) do
    ids = Enum.map(objects, &(&1.key |> Path.basename() |> Path.rootname(".json")))

    if Enum.all?(ids, &valid_item?/1),
      do: {:ok, ids},
      else: {:error, :invalid_calendar_query_index}
  end

  defp canonical(%{} = owner), do: Map.take(owner, @subject_keys)
  defp canonical(_owner), do: %{}

  defp valid_scope?(group_id, calendar_id),
    do: SalixStore.Ids.valid_group_id?(group_id) and SalixStore.Ids.valid_calendar_id?(calendar_id)

  defp valid_item?(item_id), do: SalixStore.Ids.valid_calendar_item_id?(item_id)

  defp item_key(group_id, calendar_id, item_id),
    do: Keys.ctl_calendar_item(group_id, calendar_id, item_id)

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
