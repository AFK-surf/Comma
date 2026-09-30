defmodule SalixCalendar.Actor do
  @moduledoc """
  Owns Calendar metadata, bounded source membership and editable context.

  It never reads or writes source records, items, indexes, synchronization or
  retirement. Those belong to each `SalixCalendar.SourceActor`.
  """

  use GenServer

  alias SalixCalendar.{LocalItems, Placement, Recurrence, SchedulingLink}
  alias SalixStore.{CasRecord, Crypto, Ids, JSON, Keys}

  @max_sources 50

  def child_spec(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    calendar_id = Keyword.fetch!(opts, :calendar_id)

    %{
      id: key(group_id, calendar_id),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    group_id = Keyword.fetch!(opts, :group_id)
    calendar_id = Keyword.fetch!(opts, :calendar_id)
    GenServer.start_link(__MODULE__, opts, name: via(group_id, calendar_id))
  end

  def key(group_id, calendar_id), do: {:calendar, group_id, calendar_id}

  defp via(group_id, calendar_id),
    do: {:via, Registry, {SalixCalendar.Registry, key(group_id, calendar_id)}}

  @impl true
  def init(opts) do
    {:ok,
     %{
       group_id: Keyword.fetch!(opts, :group_id),
       calendar_id: Keyword.fetch!(opts, :calendar_id)
     }}
  end

  @impl true
  def handle_call({:create, attrs}, _from, state), do: reply(create(state, attrs), state)
  def handle_call({:ensure_create, attrs}, _from, state), do: reply(ensure(state, attrs), state)

  def handle_call({:attach_source, fingerprint}, _from, state),
    do: reply(attach_source(state, fingerprint), state)

  def handle_call(:source_ids, _from, state), do: reply(source_ids(state), state)
  def handle_call(:get_calendar, _from, state), do: reply(get_calendar(state), state)

  def handle_call({:get_context, occurrence_ref}, _from, state),
    do: reply(get_context(state, occurrence_ref), state)

  def handle_call({:update_context, occurrence_ref, attrs}, _from, state),
    do: reply(update_context(state, occurrence_ref, attrs), state)

  def handle_call({:create_local_item, proposal, owner, creation_request_id}, _from, state),
    do: reply(create_local_item(state, proposal, owner, creation_request_id), state)

  defp create(state, attrs) do
    attrs = JSON.stringify(attrs)

    with true <- Ids.valid_group_id?(state.group_id) and Ids.valid_calendar_id?(state.calendar_id),
         {:ok, %{"group_id" => group_id}} when group_id == state.group_id <-
           record(Keys.ctl_group(state.group_id)),
         {:ok, name} <- text(attrs["name"] || "Calendar"),
         {:ok, time_zone} <- text(attrs["default_time_zone"] || "UTC"),
         :ok <- valid_time_zone(time_zone) do
      now = now_ms()

      create_once(calendar_key(state), %{
        "calendar_id" => state.calendar_id,
        "tenant_id" => Ids.tenant_id_from_group!(state.group_id),
        "group_id" => state.group_id,
        "name" => name,
        "default_time_zone" => time_zone,
        "source_memberships" => %{},
        "status" => "active",
        "revision" => 1,
        "created_at" => now,
        "updated_at" => now
      })
    else
      false -> {:error, :invalid_calendar_identity}
      {:error, _} = error -> error
    end
  end

  defp ensure(state, attrs) do
    attrs = JSON.stringify(attrs)

    case get_calendar(state) do
      {:ok, calendar} ->
        if calendar["name"] == (attrs["name"] || "Calendar") and
             calendar["default_time_zone"] == (attrs["default_time_zone"] || "UTC"),
           do: {:ok, calendar},
           else: {:error, :calendar_identity_conflict}

      {:error, :not_found} ->
        create(state, attrs)

      {:error, _} = error ->
        error
    end
  end

  defp get_calendar(state), do: record(calendar_key(state))

  defp attach_source(state, fingerprint) when is_binary(fingerprint) do
    update(calendar_key(state), fn calendar ->
      memberships = calendar["source_memberships"] || %{}

      cond do
        is_binary(memberships[fingerprint]) ->
          {:unchanged, calendar}

        map_size(memberships) >= @max_sources ->
          {:error, :calendar_source_limit_exceeded}

        true ->
          source_id = Ids.new_calendar_source_id()
          now = now_ms()

          calendar
          |> put_in(["source_memberships", fingerprint], source_id)
          |> Map.put("updated_at", now)
          |> Map.update("revision", 1, &(&1 + 1))
      end
    end)
    |> case do
      {:ok, calendar} -> {:ok, get_in(calendar, ["source_memberships", fingerprint])}
      {:error, _} = error -> error
    end
  end

  defp source_ids(state) do
    with {:ok, calendar} <- get_calendar(state),
         memberships when is_map(memberships) <- calendar["source_memberships"] do
      {:ok, memberships |> Map.values() |> Enum.uniq() |> Enum.sort()}
    else
      nil -> {:ok, []}
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_source_memberships}
    end
  end

  defp get_context(state, occurrence_ref) do
    occurrence_ref = JSON.stringify(occurrence_ref)

    with {:ok, link_id, recurrence_digest} <- context_identity(state, occurrence_ref),
         {:ok, context} <-
           record(context_key(state, link_id, recurrence_digest)),
         true <- context["occurrence_ref"] == occurrence_ref do
      {:ok, context}
    else
      false -> {:error, :calendar_context_hash_conflict}
      {:error, _} = error -> error
    end
  end

  defp update_context(state, occurrence_ref, attrs) do
    occurrence_ref = JSON.stringify(occurrence_ref)
    attrs = JSON.stringify(attrs)

    with {:ok, link_id, recurrence_digest} <- context_identity(state, occurrence_ref),
         {:ok, item} <- current_occurrence(state, occurrence_ref),
         true <- item["scheduling_link_id"] == link_id,
         expected when is_integer(expected) and expected >= 0 <- attrs["expected_revision"],
         {:ok, patch} <- context_patch(attrs) do
      update(context_key(state, link_id, recurrence_digest), fn
        nil when expected == 0 ->
          now = now_ms()

          patch
          |> Map.merge(%{
            "occurrence_ref" => occurrence_ref,
            "revision" => 1,
            "created_at" => now,
            "updated_at" => now
          })

        nil ->
          {:error, :conflict}

        %{"occurrence_ref" => ^occurrence_ref, "revision" => ^expected} = current ->
          current
          |> Map.merge(patch)
          |> Map.put("revision", expected + 1)
          |> Map.put("updated_at", now_ms())

        %{"occurrence_ref" => ^occurrence_ref} ->
          {:error, :conflict}

        _ ->
          {:error, :calendar_context_hash_conflict}
      end)
    else
      nil -> {:error, :expected_revision_required}
      false -> {:error, :occurrence_not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_expected_revision}
    end
  end

  defp current_occurrence(state, occurrence_ref) do
    with {:ok, source_ids} <- source_ids(state),
         {:ok, items} <- source_items(state, source_ids, occurrence_ref["scheduling_link_id"]),
         {:ok, selected} when is_map(selected) <- SchedulingLink.select_item(items),
         {:ok, _occurrence} <- Recurrence.resolve(selected, occurrence_ref) do
      {:ok, selected}
    else
      {:ok, nil} -> {:error, :occurrence_not_found}
      {:error, :ambiguous} -> {:error, :occurrence_not_found}
      {:error, :undated_item} -> {:error, :occurrence_not_found}
      {:error, :occurrence_not_found} -> {:error, :occurrence_not_found}
      {:error, _} = error -> error
    end
  end

  defp source_items(state, source_ids, link_id) do
    Enum.reduce_while(source_ids, {:ok, []}, fn source_id, {:ok, items} ->
      with {:ok, pid} <-
             Placement.ensure_source_started(state.group_id, state.calendar_id, source_id),
           {:ok, source_items} <-
             GenServer.call(pid, {:list_link_items, link_id}, :infinity) do
        {:cont, {:ok, source_items ++ items}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp context_identity(
         %{calendar_id: calendar_id},
         %{
           "calendar_id" => calendar_id,
           "scheduling_link_id" => link_id,
           "recurrence_key" => recurrence_key
         } = occurrence_ref
       ) do
    if map_size(occurrence_ref) == 3 and Ids.valid_scheduling_link_id?(link_id) and
         Recurrence.valid_key?(recurrence_key),
       do: {:ok, link_id, digest(recurrence_key)},
       else: {:error, :invalid_occurrence_ref}
  end

  defp context_identity(_state, _occurrence_ref), do: {:error, :invalid_occurrence_ref}

  defp context_patch(attrs) do
    patch = Map.take(attrs, ~w(objective background agenda questions resource_refs updated_by))

    case Jason.encode(patch) do
      {:ok, encoded} when byte_size(encoded) <= 64_000 -> {:ok, patch}
      {:ok, _} -> {:error, :calendar_context_too_large}
      {:error, _} -> {:error, :invalid_calendar_context}
    end
  end

  # A source-bound human request commits one Comma-local Event. The actor validates
  # the calendar exists (it owns the calendar record) and delegates the item and
  # index persistence to `LocalItems`, the sole owner of local-item storage keys.
  defp create_local_item(state, proposal, owner, creation_request_id)
       when is_map(proposal) and is_binary(creation_request_id) do
    with true <- Ids.valid_group_id?(state.group_id) and Ids.valid_calendar_id?(state.calendar_id),
         {:ok, _calendar} <- get_calendar(state) do
      LocalItems.create(state.group_id, state.calendar_id, proposal, owner, creation_request_id)
    else
      false -> {:error, :invalid_calendar_identity}
      {:error, :not_found} -> {:error, :calendar_not_found}
      {:error, _} = error -> error
    end
  end

  defp create_local_item(_state, _proposal, _owner, _creation_request_id),
    do: {:error, :invalid_local_item_request}

  defp calendar_key(state), do: Keys.ctl_calendar(state.group_id, state.calendar_id)

  defp context_key(state, link_id, recurrence_digest),
    do:
      Keys.ctl_calendar_context(
        state.group_id,
        state.calendar_id,
        link_id,
        recurrence_digest
      )

  defp update(key, fun), do: CasRecord.update(key, fun, invalid: :invalid_calendar_record)

  defp create_once(key, value),
    do:
      update(key, fn
        nil -> value
        _current -> {:error, :exists}
      end)

  defp record(key), do: CasRecord.get(key, :invalid_calendar_record)

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_calendar_field}
      text -> {:ok, text}
    end
  end

  defp text(_), do: {:error, :invalid_calendar_field}

  defp valid_time_zone(zone) do
    case DateTime.shift_zone(DateTime.utc_now(), zone) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:invalid_field, "default_time_zone"}}
    end
  end

  defp digest(value),
    do: value |> JSON.stringify() |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()

  defp now_ms, do: System.system_time(:millisecond)
  defp reply(result, state), do: {:reply, result, state}
end
