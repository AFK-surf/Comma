defmodule SalixCalendar.Server do
  @moduledoc "Public Calendar mutation boundary."

  alias SalixCalendar.{LocalStore, Placement}
  alias SalixStore.{CasRecord, Crypto, Ids, JSON, Keys}

  @id_attempts 8
  @timeout 30_000

  def create_calendar(group_id, attrs \\ %{}) when is_map(attrs),
    do: create_calendar(group_id, attrs, @id_attempts)

  def ensure_calendar(group_id, identity, attrs \\ %{}) when is_map(identity) and is_map(attrs) do
    with true <- Ids.valid_group_id?(group_id),
         true <- map_size(identity) > 0,
         {:ok, calendar_id} <- ensure_calendar_id(group_id, identity),
         {:ok, pid} <- Placement.ensure_started(group_id, calendar_id) do
      GenServer.call(pid, {:ensure_create, attrs}, @timeout)
    else
      false -> {:error, :invalid_calendar_owner_identity}
      {:error, _} = error -> error
    end
  end

  def ensure_source(group_id, calendar_id, attrs) when is_map(attrs) do
    attrs = JSON.stringify(attrs)

    with {:ok, fingerprint} <- source_fingerprint(attrs),
         {:ok, source_id} <- call(group_id, calendar_id, {:attach_source, fingerprint}),
         {:ok, pid} <- Placement.ensure_source_started(group_id, calendar_id, source_id) do
      GenServer.call(pid, {:ensure, attrs}, :infinity)
    end
  end

  def update_context(group_id, calendar_id, occurrence_ref, attrs)
      when is_map(occurrence_ref) and is_map(attrs),
      do: call(group_id, calendar_id, {:update_context, occurrence_ref, attrs})

  def get_calendar(group_id, calendar_id), do: call(group_id, calendar_id, :get_calendar)

  @doc """
  Commit one Comma-local Event from a source-bound human request.

  `owner` is the server-sealed `principal_ref`; the model never supplies it.
  `creation_request_id` is server-derived from the trusted source command, so an
  exact retry resolves the already-created item instead of duplicating it.
  """
  def create_local_item(group_id, calendar_id, proposal, owner, creation_request_id)
      when is_map(proposal) and is_map(owner) and is_binary(creation_request_id),
      do: call(group_id, calendar_id, {:create_local_item, proposal, owner, creation_request_id})

  @doc "Read one Comma-local item by id (read-only; not a source projection)."
  def get_local_item(group_id, calendar_id, item_id),
    do: LocalStore.get_local_item(group_id, calendar_id, item_id)

  @doc "List Comma-local items owned by `owner` whose start month overlaps [from_ms, to_ms]."
  def list_owner_items(group_id, calendar_id, owner, from_ms, to_ms, opts \\ [])
      when is_map(owner) and is_integer(from_ms) and is_integer(to_ms),
      do: LocalStore.list_for_owner(group_id, calendar_id, owner, from_ms, to_ms, opts)

  def get_source(group_id, calendar_id, source_id),
    do: source_call(group_id, calendar_id, source_id, :get_source)

  def refresh_source(group_id, calendar_id, source_id, query_contract)
      when is_map(query_contract),
      do: source_call(group_id, calendar_id, source_id, {:refresh, query_contract})

  def notify_source_changed(group_id, calendar_id, source_id, query_contract),
    do: source_cast(group_id, calendar_id, source_id, {:provider_dirty, query_contract})

  def revalidate_source(group_id, calendar_id, source_id, item, occurrence)
      when is_map(item) and is_map(occurrence),
      do: source_call(group_id, calendar_id, source_id, {:revalidate, item, occurrence})

  def get_item(group_id, calendar_id, item_id) do
    with {:ok, source_ids} <- source_ids(group_id, calendar_id) do
      first_source_result(group_id, calendar_id, source_ids, {:get_item, item_id})
    end
  end

  def list_items(group_id, calendar_id, opts \\ []) do
    with {:ok, source_ids} <- source_ids(group_id, calendar_id),
         {:ok, pages} <- call_sources(group_id, calendar_id, source_ids, {:list_items, opts}) do
      data = pages |> Enum.flat_map(& &1["data"]) |> Enum.sort_by(& &1["calendar_item_id"])
      {:ok, %{"data" => data, "next_cursor" => nil}}
    end
  end

  def query_items(group_id, calendar_id, range_start_ms, range_end_ms, opts \\ []) do
    with {:ok, selected} <- selected_source_ids(group_id, calendar_id, opts[:source_ids]),
         {:ok, results} <-
           call_sources(
             group_id,
             calendar_id,
             selected,
             {:query_items, range_start_ms, range_end_ms}
           ) do
      {:ok,
       results
       |> List.flatten()
       |> Enum.uniq_by(& &1["calendar_item_id"])
       |> Enum.sort_by(& &1["calendar_item_id"])}
    end
  end

  def list_link_items(group_id, calendar_id, link_id, opts \\ []) do
    with {:ok, selected} <- selected_source_ids(group_id, calendar_id, opts[:source_ids]),
         {:ok, results} <-
           call_sources(group_id, calendar_id, selected, {:list_link_items, link_id}) do
      {:ok,
       results
       |> List.flatten()
       |> Enum.uniq_by(& &1["calendar_item_id"])
       |> Enum.sort_by(& &1["calendar_item_id"])}
    end
  end

  def drain_source_retirements(group_id, calendar_id, source_id),
    do: source_call(group_id, calendar_id, source_id, :drain_retirements)

  def get_context(group_id, calendar_id, occurrence_ref),
    do: call(group_id, calendar_id, {:get_context, occurrence_ref})

  defp create_calendar(_group_id, _attrs, 0), do: {:error, :id_collision}

  defp create_calendar(group_id, attrs, attempts) do
    calendar_id = Ids.new_calendar_id()

    case call(group_id, calendar_id, {:create, attrs}) do
      {:error, :exists} -> create_calendar(group_id, attrs, attempts - 1)
      result -> result
    end
  end

  defp call(group_id, calendar_id, command) do
    with true <- Ids.valid_group_id?(group_id),
         true <- Ids.valid_calendar_id?(calendar_id),
         {:ok, pid} <- Placement.ensure_started(group_id, calendar_id) do
      GenServer.call(pid, command, @timeout)
    else
      false -> {:error, :invalid_calendar_owner_identity}
      {:error, _} = error -> error
    end
  end

  defp source_ids(group_id, calendar_id), do: call(group_id, calendar_id, :source_ids)

  defp source_call(group_id, calendar_id, source_id, command) do
    with {:ok, pid} <- Placement.ensure_source_started(group_id, calendar_id, source_id),
         do: GenServer.call(pid, command, :infinity)
  end

  defp source_cast(group_id, calendar_id, source_id, command) do
    with {:ok, pid} <- Placement.ensure_source_started(group_id, calendar_id, source_id),
         do: GenServer.cast(pid, command)
  end

  defp selected_source_ids(group_id, calendar_id, nil), do: source_ids(group_id, calendar_id)

  defp selected_source_ids(group_id, calendar_id, source_ids) when is_list(source_ids) do
    with {:ok, enrolled} <- source_ids(group_id, calendar_id),
         true <- source_ids != [] and length(source_ids) == length(Enum.uniq(source_ids)),
         true <- Enum.all?(source_ids, &(&1 in enrolled)) do
      {:ok, Enum.sort(source_ids)}
    else
      false -> {:error, :invalid_calendar_source_scope}
      {:error, _} = error -> error
    end
  end

  defp selected_source_ids(_group_id, _calendar_id, _source_ids),
    do: {:error, :invalid_calendar_source_scope}

  defp call_sources(group_id, calendar_id, source_ids, command) do
    Enum.reduce_while(source_ids, {:ok, []}, fn source_id, {:ok, results} ->
      case source_call(group_id, calendar_id, source_id, command) do
        {:ok, value} -> {:cont, {:ok, [value | results]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      error -> error
    end
  end

  defp first_source_result(_group_id, _calendar_id, [], _command), do: {:error, :not_found}

  defp first_source_result(group_id, calendar_id, [source_id | rest], command) do
    case source_call(group_id, calendar_id, source_id, command) do
      {:error, :not_found} -> first_source_result(group_id, calendar_id, rest, command)
      result -> result
    end
  end

  defp source_fingerprint(attrs) do
    with contract when is_binary(contract) and contract != "" <- attrs["adapter_contract_id"],
         locator when is_map(locator) and map_size(locator) > 0 <- attrs["source_locator"] do
      {:ok, digest({contract, locator})}
    else
      _ -> {:error, :invalid_calendar_source_identity}
    end
  end

  defp digest(value),
    do: value |> JSON.stringify() |> :erlang.term_to_binary([:deterministic]) |> Crypto.hex()

  defp ensure_calendar_id(group_id, identity) do
    identity = JSON.stringify(identity)
    key = Keys.ctl_calendar_ensure(group_id, digest(identity))

    with {:ok, binding} <-
           CasRecord.ensure(
             key,
             fn -> %{"calendar_id" => Ids.new_calendar_id(), "identity" => identity} end,
             invalid: :invalid_calendar_binding
           ),
         true <- binding["identity"] == identity,
         calendar_id when is_binary(calendar_id) <- binding["calendar_id"],
         true <- Ids.valid_calendar_id?(calendar_id) do
      {:ok, calendar_id}
    else
      false -> {:error, :calendar_identity_conflict}
      {:error, _} = error -> error
      _ -> {:error, :invalid_calendar_binding}
    end
  end
end
