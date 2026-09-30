defmodule SalixCalendar.AgentAPI do
  @moduledoc "Bounded, read-only Calendar facts plus CalendarContext mutation for agent tools."

  alias SalixCalendar.{Occurrences, Recurrence, Server}
  alias SalixStore.{Ids, JSON}

  @owner_subject_keys ~w(namespace tenant_id subject_id)

  @max_occurrences 200
  @public_item_fields ~w(calendar_item_id calendar_id scheduling_link_id copy_role object participant_set_state attachment_set_state normalization_state present_fields source_fresh_at tombstoned_at revision meeting_qualification)
  @public_local_item_fields ~w(calendar_item_id calendar_id object revision created_at updated_at)
  @local_calendar_identity %{"kind" => "comma_local_default"}
  @default_duration "PT30M"

  def list_items(group_id, params, principal_ref \\ nil) when is_map(params) do
    params = JSON.stringify(params)
    calendar_id = params["calendar_id"]
    range_start = params["range_start_ms"]
    range_end = params["range_end_ms"]
    limit = params["limit"] || 50
    object_type = normalize_type(params["object_type"])

    with true <- is_integer(range_start) and is_integer(range_end) and range_start < range_end,
         true <- is_integer(limit) and limit > 0 and limit <= @max_occurrences,
         true <- object_type != :invalid,
         true <- is_nil(params["cursor"]),
         {:ok, occurrences} <-
           Occurrences.list(group_id, calendar_id, range_start, range_end,
             object_type: object_type,
             limit: limit
           ),
         {:ok, source_data} <- map_occurrences(group_id, occurrences),
         {:ok, local_data} <-
           local_occurrences(
             group_id,
             calendar_id,
             principal_ref,
             range_start,
             range_end,
             object_type,
             limit
           ) do
      data =
        (source_data ++ local_data)
        |> Enum.sort_by(&get_in(&1, ["occurrence", "start_ms"]))
        |> Enum.take(limit)

      {:ok,
       %{
         "data" => data,
         "range_start_ms" => range_start,
         "range_end_ms" => range_end
       }}
    else
      false -> {:error, :invalid_calendar_query}
      {:error, _} = error -> error
    end
  end

  def get_item(group_id, params, principal_ref \\ nil) when is_map(params) do
    params = JSON.stringify(params)
    calendar_id = params["calendar_id"]

    case params["occurrence_ref"] do
      occurrence_ref when is_map(occurrence_ref) ->
        with {:ok, %{"item" => item, "occurrence" => occurrence}} <-
               Occurrences.get(
                 group_id,
                 calendar_id,
                 params["calendar_item_id"],
                 occurrence_ref
               ),
             {:ok, context} <- context(group_id, occurrence_ref),
             do:
               {:ok,
                %{
                  "item" => public_item(item),
                  "occurrence" => occurrence,
                  "calendar_context" => context
                }}

      nil ->
        case Server.get_item(group_id, calendar_id, params["calendar_item_id"]) do
          {:ok, item} ->
            {:ok, %{"item" => public_item(item)}}

          {:error, :not_found} ->
            local_item(group_id, calendar_id, params["calendar_item_id"], principal_ref)

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, :invalid_occurrence_ref}
    end
  end

  def update_context(group_id, params) when is_map(params) do
    params = JSON.stringify(params)
    occurrence_ref = params["occurrence_ref"]

    attrs =
      params
      |> Map.take(~w(expected_revision objective background agenda questions resource_refs))
      |> Map.put("updated_by", params["actor"])

    Server.update_context(group_id, params["calendar_id"], occurrence_ref, attrs)
  end

  @doc """
  Create one Comma-local Event from a human-authored request.

  `principal_ref` and `creation_request_id` are server-owned: the model supplies
  only the Event proposal. The calendar is the group's canonical local calendar,
  resolved server-side (never a model-supplied `calendar_id`). Fails closed when
  no trusted human principal is available.
  """
  def create_event(group_id, params, principal_ref, creation_request_id) when is_map(params) do
    params = JSON.stringify(params)

    with {:ok, owner} <- validate_principal(group_id, principal_ref),
         true <- is_binary(creation_request_id) and creation_request_id != "",
         {:ok, calendar} <- ensure_local_calendar(group_id),
         {:ok, item} <-
           Server.create_local_item(
             group_id,
             calendar["calendar_id"],
             proposal(params),
             owner,
             creation_request_id
           ) do
      {:ok, Map.take(item, @public_local_item_fields)}
    else
      false -> {:error, :invalid_creation_request}
      {:error, _} = error -> error
    end
  end

  @doc """
  Validate the requesting principal and resolve the private-feed subscription
  scope for the group's canonical local calendar.

  Returns only the scope; subscription issuance and delivery are the caller's
  concern, so the secret is never minted here.
  """
  def feed_scope(group_id, principal_ref) do
    with {:ok, owner} <- validate_principal(group_id, principal_ref),
         {:ok, calendar} <- ensure_local_calendar(group_id) do
      {:ok,
       %{
         "tenant_id" => owner["tenant_id"],
         "group_id" => group_id,
         "calendar_id" => calendar["calendar_id"],
         "subject_namespace" => owner["namespace"],
         "subject_id" => owner["subject_id"]
       }}
    end
  end

  defp ensure_local_calendar(group_id),
    do:
      Server.ensure_calendar(group_id, @local_calendar_identity, %{
        name: "Comma",
        default_time_zone: "UTC"
      })

  defp validate_principal(
         group_id,
         %{"namespace" => ns, "tenant_id" => tid, "subject_id" => sid} = ref
       )
       when is_binary(ns) and ns != "" and is_binary(tid) and is_binary(sid) and sid != "" do
    cond do
      not Ids.valid_group_id?(group_id) -> {:error, :invalid_calendar_owner_identity}
      tid != Ids.tenant_id_from_group!(group_id) -> {:error, :principal_tenant_mismatch}
      true -> {:ok, Map.take(ref, ~w(namespace tenant_id subject_id))}
    end
  end

  defp validate_principal(_group_id, _ref), do: {:error, :missing_principal}

  defp proposal(params) do
    duration =
      case params["duration"] do
        value when is_binary(value) and value != "" -> value
        _ -> @default_duration
      end

    params
    |> Map.take(~w(title start time_zone attendees))
    |> Map.put("duration", duration)
  end

  defp normalize_type(nil), do: nil
  defp normalize_type(type) when type in ~w(event Event), do: "Event"
  defp normalize_type(type) when type in ~w(task Task), do: "Task"
  defp normalize_type(_), do: :invalid

  defp map_occurrences(group_id, occurrences) do
    Enum.reduce_while(occurrences, {:ok, []}, fn entry, {:ok, entries} ->
      case context(group_id, get_in(entry, ["occurrence", "occurrence_ref"])) do
        {:ok, context} ->
          public =
            entry
            |> update_in(["item"], &public_item/1)
            |> Map.put("calendar_context", context)

          {:cont, {:ok, [public | entries]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp context(group_id, %{"calendar_id" => calendar_id} = occurrence_ref) do
    case Server.get_context(group_id, calendar_id, occurrence_ref) do
      {:ok, context} -> {:ok, context}
      {:error, :not_found} -> {:ok, %{"revision" => 0}}
      {:error, _} = error -> error
    end
  end

  defp context(_group_id, _occurrence_ref), do: {:error, :invalid_occurrence_ref}

  defp public_item(item), do: Map.take(item, @public_item_fields)

  defp local_occurrences(_group_id, _calendar_id, _principal_ref, _from, _to, "Task", _limit),
    do: {:ok, []}

  defp local_occurrences(_group_id, _calendar_id, nil, _from, _to, _object_type, _limit),
    do: {:ok, []}

  defp local_occurrences(
         group_id,
         calendar_id,
         principal_ref,
         range_start,
         range_end,
         _type,
         limit
       ) do
    with {:ok, owner} <- validate_principal(group_id, principal_ref),
         {:ok, items} <-
           Server.list_owner_items(group_id, calendar_id, owner, range_start, range_end,
             limit: limit
           ) do
      entries =
        Enum.flat_map(items, fn item ->
          case Recurrence.expand(item, range_start, range_end, limit: limit) do
            {:ok, views} ->
              Enum.map(views, fn view ->
                %{
                  "item" => Map.take(item, @public_local_item_fields),
                  "occurrence" => view,
                  "calendar_context" => %{"revision" => 0}
                }
              end)

            _ ->
              []
          end
        end)

      {:ok, entries}
    else
      {:error, reason} when reason in [:missing_principal, :principal_tenant_mismatch] ->
        {:ok, []}

      {:error, _} = error ->
        error
    end
  end

  defp local_item(_group_id, _calendar_id, _item_id, nil), do: {:error, :not_found}

  defp local_item(group_id, calendar_id, item_id, principal_ref) do
    with {:ok, owner} <- validate_principal(group_id, principal_ref),
         {:ok, %{"owner_principal_ref" => item_owner} = item} <-
           Server.get_local_item(group_id, calendar_id, item_id),
         true <- Map.take(item_owner, @owner_subject_keys) == owner do
      {:ok, %{"item" => Map.take(item, @public_local_item_fields)}}
    else
      _ -> {:error, :not_found}
    end
  end
end
