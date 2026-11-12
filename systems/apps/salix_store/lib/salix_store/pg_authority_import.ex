defmodule SalixStore.PGAuthorityImport do
  @moduledoc """
  Bounded source reads and release progress for the offline S and C imports.

  The release runner stops the old writers. Source reads finish before a short
  transaction writes facts and their cursor. This module does not start an
  application, discover writers, or admit online requests.

  `wire_bytes` counts GET body bytes. It excludes LIST responses and protocol
  headers. `inflated_bytes` counts the decoded source buffers.
  """

  alias SalixStore.{Codec, Repo, S3}

  @markers %{s: "salix_pg_authority_s_v1", c: "salix_pg_authority_c_v1"}

  defmodule Pending do
    @moduledoc "A frozen import page whose commit result is not yet known."
    @derive {Inspect, only: [:unit]}
    defstruct [:unit, :expected, :next, :apply, :stats]
  end

  defmodule SourceBudget do
    @moduledoc false
    use SystemsRuntime.Server

    def init(limits), do: {:ok, %{limits: limits, active: %{}, waiting: :queue.new()}}

    def handle_call({:acquire, kind}, from, state) do
      {:noreply, drain(%{state | waiting: :queue.in({kind, from}, state.waiting)})}
    end

    def handle_call({:release, ref}, _from, state) do
      SystemsRuntime.Proc.demonitor(ref, [:flush])
      {:reply, :ok, drain(%{state | active: Map.delete(state.active, ref)})}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
      do: {:noreply, drain(%{state | active: Map.delete(state.active, ref)})}

    defp drain(state) do
      {waiting, active} =
        Enum.reduce(:queue.to_list(state.waiting), {:queue.new(), state.active}, fn
          {kind, {pid, _} = from} = entry, {waiting, active} ->
            used = Enum.count(active, fn {_, held} -> held == kind end)

            if used < Map.fetch!(state.limits, kind) do
              ref = SystemsRuntime.Proc.monitor(pid)
              SystemsRuntime.Server.reply(from, ref)
              {waiting, Map.put(active, ref, kind)}
            else
              {:queue.in(entry, waiting), active}
            end
        end)

      %{state | waiting: waiting, active: active}
    end
  end

  @doc "Share transport and decode concurrency between the two offline units."
  def with_source_budget(fun, opts \\ []) do
    {:ok, pid} =
      SystemsRuntime.Server.start_link(SourceBudget, %{
        io: Keyword.get(opts, :io_concurrency, 64),
        decode: Keyword.get(opts, :decode_concurrency, 2),
        page: 2
      })

    try do
      fun.(source_budget: pid)
    after
      SystemsRuntime.Server.stop(pid)
    end
  end

  @doc false
  def with_decode(budget, fun), do: with_permit(budget, :decode, fun)

  @doc false
  def with_io(budget, fun), do: with_permit(budget, :io, fun)

  @doc false
  def with_page(budget, fun), do: with_permit(budget, :page, fun)

  defp with_permit(%{source_budget: pid}, kind, fun) when is_pid(pid) do
    ref = SystemsRuntime.Server.call(pid, {:acquire, kind}, :infinity)

    try do
      fun.()
    after
      SystemsRuntime.Server.call(pid, {:release, ref}, :infinity)
    end
  end

  defp with_permit(_, _, fun), do: fun.()

  @doc "Prefetch bounded wire buffers; decode them later in source order."
  def prefetch(keys, budget) do
    sources =
      keys
      |> Enum.uniq()
      |> SystemsClock.async_stream(
        fn key ->
          {key,
           with_permit(budget, :io, fn ->
             S3.get(key, range: {0, min(budget.max_object_bytes, budget.remaining_bytes) + 1})
           end)}
        end,
        max_concurrency: 24,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, entry} -> entry end)
      |> Map.new()

    Enum.reduce(sources, %{budget | prefetched: sources}, fn
      {_, {:ok, %{body: body}}}, acc ->
        %{acc | objects: acc.objects + 1, wire_bytes: acc.wire_bytes + byte_size(body)}

      _, acc ->
        acc
    end)
  end

  @doc "Build per-request limits. These limits do not cap the dataset."
  def limits(opts \\ []) do
    budget = %{
      page_size: Keyword.get(opts, :page_size, 1000),
      source_budget: Keyword.get(opts, :source_budget),
      max_page_inflated_bytes: Keyword.get(opts, :max_page_inflated_bytes, 64 * 1_048_576),
      prefetched: %{},
      max_object_bytes: Keyword.get(opts, :max_object_bytes, 4 * 1_048_576),
      max_inflated_bytes: Keyword.get(opts, :max_inflated_bytes, 64 * 1_048_576),
      remaining_bytes: Keyword.get(opts, :max_page_bytes, 16 * 1_048_576),
      objects: 0,
      wire_bytes: 0,
      inflated_bytes: 0
    }

    if budget.page_size in 1..1000 and
         Enum.all?(
           [:max_object_bytes, :max_inflated_bytes, :max_page_inflated_bytes, :remaining_bytes],
           fn key ->
             is_integer(budget[key]) and budget[key] > 0
           end
         ) do
      {:ok, budget}
    else
      {:error, :invalid_import_limits}
    end
  end

  @doc "List one source page without reading object bodies."
  def list_page(prefix, cursor, budget, opts \\ []) do
    with_permit(budget, :io, fn ->
      S3.list(prefix, Keyword.merge(opts, max_keys: budget.page_size, continuation_token: cursor))
    end)
  end

  @doc "Read at most the remaining byte budget plus one overflow byte."
  def read_binary(key, budget) do
    limit = min(budget.max_object_bytes, budget.remaining_bytes)

    if limit > 0 do
      result =
        case Map.fetch(budget.prefetched, key) do
          {:ok, result} -> result
          :error -> with_permit(budget, :io, fn -> S3.get(key, range: {0, limit + 1}) end)
        end

      cached? = Map.has_key?(budget.prefetched, key)

      case result do
        {:ok, %{body: body, etag: etag}} when byte_size(body) <= limit ->
          {:ok, %{key: key, etag: etag, bytes: byte_size(body), value: body},
           %{
             budget
             | remaining_bytes: budget.remaining_bytes - byte_size(body),
               objects: budget.objects + if(cached?, do: 0, else: 1),
               wire_bytes: budget.wire_bytes + if(cached?, do: 0, else: byte_size(body))
           }}

        {:ok, _} ->
          {:error, {:source_byte_limit, key}}

        {:error, _} = error ->
          error
      end
    else
      {:error, {:source_byte_limit, key}}
    end
  end

  def read_json(key, budget) do
    with {:ok, source, budget} <- read_binary(key, budget),
         {:ok, value} <- with_decode(budget, fn -> Jason.decode(source.value) end) do
      {:ok, %{source | value: value},
       %{budget | inflated_bytes: budget.inflated_bytes + source.bytes}}
    else
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_source_json, key}}
      error -> error
    end
  end

  @doc "Start only the database and object transport dependencies for a release command."
  def with_dependencies(fun) when is_function(fun, 0) do
    Enum.each([:ecto_sql, :postgrex, :finch], fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)

    Application.load(:salix_store)
    Application.load(:salix_verified_kernel)

    repo = start_dependency(Repo, &Repo.start_link/0)
    finch = start_dependency(SalixStore.Finch, fn -> Finch.start_link(name: SalixStore.Finch) end)

    try do
      fun.()
    after
      Enum.each([finch, repo], fn
        nil -> :ok
        pid -> GenServer.stop(pid)
      end)
    end
  end

  defp start_dependency(name, start) do
    if SystemsRuntime.Proc.whereis(name) do
      nil
    else
      {:ok, pid} = start.()
      SystemsRuntime.Proc.unlink(pid)
      pid
    end
  end

  def read_snapshot(key, budget) do
    with {:ok, source, budget} <- read_etf(key, budget),
         {:ok, value} <-
           with_decode(budget, fn ->
             Codec.decode_snapshot_bounded(source.value, budget.max_inflated_bytes)
           end) do
      {:ok, %{source | value: value}, budget}
    else
      {:error, {:snapshot_too_large, _}} ->
        {:error, {:snapshot_too_large, key}}

      {:error, reason} when reason in [:invalid_snapshot, :snapshot_too_large] ->
        {:error, {reason, key}}

      error ->
        error
    end
  end

  @doc "Read bounded decompressed ETF bytes for the native Session codec."
  def read_etf(key, budget) do
    with {:ok, source, budget} <- read_binary(key, budget),
         {:ok, etf} <-
           with_decode(budget, fn ->
             Codec.snapshot_etf_bounded(source.value, budget.max_inflated_bytes)
           end) do
      {:ok, %{source | value: etf},
       %{budget | inflated_bytes: budget.inflated_bytes + byte_size(etf)}}
    else
      {:error, {:snapshot_too_large, _}} -> {:error, {:snapshot_too_large, key}}
      {:error, :invalid_snapshot} -> {:error, {:invalid_snapshot, key}}
      error -> error
    end
  end

  @doc "Read progress without interpreting a changed cursor as proof of a commit."
  def state(unit) when is_map_key(@markers, unit) do
    case Repo.query("SELECT evidence FROM salix_cutover_markers WHERE name=$1", [@markers[unit]]) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [[evidence]]}} -> decode_position(evidence)
      _ -> {:error, :import_state_unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :import_state_unavailable}
  catch
    :exit, _ -> {:error, :import_state_unavailable}
  end

  @doc "Commit one frozen page and its progress on the same Repo connection."
  def commit_page(unit, expected, next_cursor, apply, stats \\ %{})
      when is_map_key(@markers, unit) and is_function(apply, 0) do
    pending = %Pending{
      unit: unit,
      expected: expected,
      next: next_cursor,
      apply: apply,
      stats: stats
    }

    execute(pending, 2)
  end

  @doc "Retry the original frozen page after an unknown result."
  def settle_page(%Pending{} = pending), do: settle_unknown(pending, 2)

  defp execute(pending, attempts) do
    case transaction(pending) do
      {:ok, position} -> {:ok, position}
      {:error, :commit_indeterminate} -> settle_unknown(pending, attempts)
      error -> error
    end
  end

  defp settle_unknown(pending, attempts) do
    case state(pending.unit) do
      {:ok, position} ->
        cond do
          landed?(position, pending) ->
            {:ok, position}

          original?(position, pending) and attempts > 0 ->
            case execute(pending, attempts - 1) do
              {:error, :stale_import_progress} -> {:error, :import_outcome_unknown, pending}
              result -> result
            end

          true ->
            {:error, :import_outcome_unknown, pending}
        end

      _ ->
        {:error, :import_outcome_unknown, pending}
    end
  end

  defp transaction(pending) do
    Repo.transaction(fn ->
      marker = @markers[pending.unit]
      initial = evidence(pending.expected, nil, %{})

      if pending.expected.step == 0 do
        Repo.query!(
          "INSERT INTO salix_cutover_markers(name,completed_at,evidence) " <>
            "VALUES($1,statement_timestamp(),$2) ON CONFLICT(name) DO NOTHING",
          [marker, initial]
        )
      end

      current =
        case Repo.query!("SELECT evidence FROM salix_cutover_markers WHERE name=$1 FOR UPDATE", [
               marker
             ]) do
          %{rows: [[current]]} -> current
          _ -> Repo.rollback(:stale_import_progress)
        end

      position =
        case decode_position(current) do
          {:ok, position} -> position
          _ -> Repo.rollback(:invalid_import_progress)
        end

      cond do
        landed?(position, pending) ->
          position

        original?(position, pending) ->
          case pending.apply.() do
            {:error, reason} -> Repo.rollback(reason)
            _ -> :ok
          end

          next = %{cursor: pending.next, step: pending.expected.step + 1}
          stats = merge_stats(position.stats, pending.stats)
          updated = evidence(next, pending.expected.cursor, stats)

          Repo.query!(
            "UPDATE salix_cutover_markers SET evidence=$2,completed_at=statement_timestamp() WHERE name=$1",
            [marker, updated]
          )

          {:ok, result} = decode_position(updated)
          result

        true ->
          Repo.rollback(:stale_import_progress)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if error.postgres &&
           error.postgres[:code] not in [:admin_shutdown, :crash_shutdown, :cannot_connect_now] do
        {:error, {:import_database_error, error.postgres[:code]}}
      else
        {:error, :commit_indeterminate}
      end

    _ in DBConnection.ConnectionError ->
      {:error, :commit_indeterminate}
  catch
    :exit, _ -> {:error, :commit_indeterminate}
  end

  defp original?(nil, %{expected: %{step: 0}}), do: true
  defp original?(nil, _), do: false

  defp original?(position, pending),
    do: position.step == pending.expected.step and position.cursor == pending.expected.cursor

  defp landed?(nil, _), do: false

  defp landed?(position, pending),
    do:
      position.step == pending.expected.step + 1 and
        position.previous_cursor == pending.expected.cursor and position.cursor == pending.next

  defp evidence(position, previous, stats) do
    %{
      "phase" => if(position.cursor["phase"] == "complete", do: "complete", else: "importing"),
      "step" => position.step,
      "cursor" => position.cursor,
      "previous_cursor" => previous,
      "stats" => stats
    }
  end

  defp decode_position(%{"phase" => phase, "cursor" => cursor, "step" => step} = evidence)
       when phase in ["importing", "complete"] and is_map(cursor) and is_integer(step) and
              step >= 0 do
    {:ok,
     %{
       phase: phase,
       cursor: cursor,
       step: step,
       previous_cursor: evidence["previous_cursor"],
       stats: evidence["stats"] || %{}
     }}
  end

  defp decode_position(_), do: {:error, :invalid_import_progress}

  defp merge_stats(previous, delta) do
    Enum.reduce(delta, previous, fn {key, value}, acc ->
      key = to_string(key)
      Map.update(acc, key, value, &(&1 + value))
    end)
  end

  @doc false
  def with_import_batch!(apply, diagnose, source_errors \\ [ArgumentError]) do
    Repo.query!("SAVEPOINT authority_import_batch")

    try do
      apply.()
    rescue
      error ->
        unless import_data_error?(error, source_errors), do: reraise(error, __STACKTRACE__)
        Repo.query!("ROLLBACK TO SAVEPOINT authority_import_batch")
        diagnose.(error)
        reraise(error, __STACKTRACE__)
    end

    Repo.query!("RELEASE SAVEPOINT authority_import_batch")
  end

  defp import_data_error?(%Postgrex.Error{postgres: %{code: code}}, _source_errors),
    do:
      code in [
        :unique_violation,
        :foreign_key_violation,
        :not_null_violation,
        :check_violation,
        :invalid_text_representation,
        :numeric_value_out_of_range,
        :datetime_field_overflow,
        :string_data_right_truncation
      ]

  defp import_data_error?(error, source_errors),
    do: Enum.any?(source_errors, &is_struct(error, &1))

  @doc "Insert frozen facts; an existing different fact rolls back the page."
  def insert_exact!(table, key_columns, values),
    do: insert_exact_many!(table, key_columns, [values])

  def insert_exact_many!(table, key_columns, rows, opts \\ []) do
    rows
    |> Enum.chunk_by(fn row -> row |> Map.keys() |> Enum.sort() end)
    |> Enum.each(&insert_exact_rows!(table, key_columns, &1, opts))

    :ok
  end

  defp insert_exact_rows!(table, key_columns, rows, opts) do
    case rows do
      [] ->
        :ok

      [first | _] ->
        columns = first |> Map.keys() |> Enum.sort()
        table_sql = identifier(table)
        first_key = key_columns |> hd() |> identifier()
        keys_sql = Enum.map_join(key_columns, ",", &identifier/1)

        equal_sql =
          Enum.map_join(columns, " AND ", fn column ->
            name = identifier(column)
            "#{table_sql}.#{name} IS NOT DISTINCT FROM EXCLUDED.#{name}"
          end)

        suffix =
          " ON CONFLICT(#{keys_sql}) DO UPDATE SET #{first_key}=EXCLUDED.#{first_key} " <>
            "WHERE #{equal_sql} RETURNING #{keys_sql}"

        batch_rows(rows, opts)
        |> Enum.flat_map(
          &split_repeated_keys(&1, fn row ->
            Enum.map(key_columns, fn key -> Map.fetch!(row, key) end)
          end)
        )
        |> Enum.each(fn batch ->
          values = Enum.map(batch, fn row -> Enum.map(columns, &Map.fetch!(row, &1)) end)
          result = query_insert!(table, columns, values, suffix)
          returned = MapSet.new(result.rows)

          case Enum.find(batch, fn row ->
                 not MapSet.member?(returned, Enum.map(key_columns, &Map.fetch!(row, &1)))
               end) do
            nil -> :ok
            row -> Repo.rollback({:import_conflict, table, Map.take(row, key_columns)})
          end
        end)
    end

    :ok
  end

  @doc false
  def insert_many!(table, columns, rows, opts \\ []) do
    conflict = Keyword.get(opts, :conflict)

    suffix =
      case conflict do
        nil ->
          ""

        {:nothing, keys} ->
          " ON CONFLICT(" <> Enum.map_join(keys, ",", &identifier/1) <> ") DO NOTHING"

        {:update, keys, updated} ->
          " ON CONFLICT(" <>
            Enum.map_join(keys, ",", &identifier/1) <>
            ") DO UPDATE SET " <>
            Enum.map_join(updated, ",", fn column ->
              name = identifier(column)
              "#{name}=EXCLUDED.#{name}"
            end)
      end

    # A repeated UPDATE key must remain in a later statement: PostgreSQL cannot
    # update the same target twice within one INSERT. Preserve the source order.
    keys =
      case conflict do
        {:update, keys, _} -> Enum.map(keys, fn key -> Enum.find_index(columns, &(&1 == key)) end)
        _ -> []
      end

    rows
    |> batch_rows(opts)
    |> Enum.each(fn batch ->
      batch
      |> split_repeated_keys(fn row -> Enum.map(keys, &Enum.at(row, &1)) end)
      |> Enum.each(&query_insert!(table, columns, &1, suffix))
    end)

    :ok
  end

  defp split_repeated_keys(rows, key_for) do
    Enum.chunk_while(
      rows,
      {[], MapSet.new()},
      fn row, {acc, seen} ->
        key = key_for.(row)

        if key != [] and MapSet.member?(seen, key),
          do: {:cont, Enum.reverse(acc), {[row], MapSet.new([key])}},
          else: {:cont, {[row | acc], MapSet.put(seen, key)}}
      end,
      fn
        {[], _} -> {:cont, []}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], MapSet.new()}}
      end
    )
  end

  defp batch_rows(rows, opts) do
    max_rows = Keyword.get(opts, :max_rows, 128)
    max_bytes = Keyword.get(opts, :max_bytes, 1_048_576)

    Enum.chunk_while(
      rows,
      {[], 0, 0},
      fn row, {acc, count, bytes} ->
        size = :erlang.external_size(row)

        if count > 0 and (count == max_rows or bytes + size > max_bytes),
          do: {:cont, Enum.reverse(acc), {[row], 1, size}},
          else: {:cont, {[row | acc], count + 1, bytes + size}}
      end,
      fn
        {[], _, _} -> {:cont, []}
        {acc, _, _} -> {:cont, Enum.reverse(acc), {[], 0, 0}}
      end
    )
  end

  defp query_insert!(table, columns, rows, suffix) do
    columns_sql = Enum.map_join(columns, ",", &identifier/1)
    count = length(columns)

    placeholders =
      rows
      |> Enum.with_index()
      |> Enum.map_join(",", fn {_, offset} ->
        "(" <> Enum.map_join(1..count, ",", &"$#{offset * count + &1}") <> ")"
      end)

    Repo.query!(
      "INSERT INTO #{identifier(table)}(#{columns_sql}) VALUES #{placeholders}#{suffix}",
      Enum.flat_map(rows, & &1)
    )
  end

  defp identifier(name) do
    name = to_string(name)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name),
      do: ~s("#{name}"),
      else: raise(ArgumentError, "invalid SQL identifier")
  end
end
