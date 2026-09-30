defmodule SalixStore.TriageRecords do
  @moduledoc """
  Conditional-record compatibility facade over native Triage's typed tables.

  Logical keys remain stable for the existing domain modules, but each key
  shape resolves to one protocol-owned PostgreSQL table with explicit identity
  columns and table-level schema constraints. Evidence tables accept only
  create-once writes; mutable coordination tables expose revision-fenced CAS.
  There is deliberately no catch-all key/value table.
  """

  alias SalixStore.Repo

  @default_page_size 1_000
  @max_page_size 2_000
  @body_size_metadata_tables ~w(triage_buckets triage_run_fences triage_runs triage_replays)
  @root ~r/\Atriage\/engine-v2\/([0-9a-f]{64})\/(.+)\z/

  @type spec :: %{
          table: String.t(),
          namespace_key: String.t(),
          identity: [{String.t(), String.t() | integer()}],
          mutable?: boolean(),
          deletable?: boolean(),
          timestamp: String.t()
        }

  @spec put(String.t(), iodata(), keyword()) ::
          {:ok, %{etag: String.t()}} | {:error, :precondition_failed | :invalid | :unavailable}
  def put(key, body, opts \\ [])

  def put(key, body, opts) when is_binary(key) and is_list(opts) do
    with {:ok, spec} <- resolve_key(key),
         {:ok, decoded} <- decode_body(body) do
      case condition(opts) do
        :create -> insert_once(key, spec, decoded)
        {:match, revision} -> update_exact(key, spec, decoded, revision)
        :invalid -> {:error, :invalid}
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def put(_key, _body, _opts), do: {:error, :invalid}

  @spec get(String.t(), keyword()) ::
          {:ok, %{body: binary(), etag: String.t(), meta: map()}}
          | {:error, :not_found | :not_modified | :unavailable}
  def get(key, opts \\ [])

  def get(key, opts) when is_binary(key) and is_list(opts) do
    with {:ok, spec} <- resolve_key(key) do
      case Repo.query(
             "SELECT body::text, revision FROM #{spec.table} WHERE record_key = $1",
             [key]
           ) do
        {:ok, %{rows: [[body, revision]]}} ->
          etag = etag(revision)

          if opts[:if_none_match] == etag,
            do: {:error, :not_modified},
            else: {:ok, %{body: body, etag: etag, meta: %{}}}

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid} -> {:error, :not_found}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def get(_key, _opts), do: {:error, :not_found}

  @doc "Reads one typed record only when its encoded JSON body fits the caller's byte limit."
  @spec get_bounded(String.t(), pos_integer()) ::
          {:ok, %{body: binary(), etag: String.t(), meta: map(), size: non_neg_integer()}}
          | {:error, :not_found | :too_large | :unavailable | :invalid}
  def get_bounded(key, max_bytes)
      when is_binary(key) and is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, spec} <- resolve_key(key) do
      case Repo.query(
             "SELECT CASE WHEN sizes.body_bytes <= $2 THEN records.body::text ELSE NULL END, records.revision, sizes.body_bytes FROM #{spec.table} AS records LEFT JOIN triage_record_body_sizes AS sizes ON sizes.source_table = $3 AND sizes.record_key = records.record_key AND sizes.revision = records.revision WHERE records.record_key = $1",
             [key, max_bytes, spec.table]
           ) do
        {:ok, %{rows: [[nil, _revision, nil]]}} ->
          {:error, :unavailable}

        {:ok, %{rows: [[nil, _revision, _size]]}} ->
          {:error, :too_large}

        {:ok, %{rows: [[body, revision, size]]}} ->
          {:ok, %{body: body, etag: etag(revision), meta: %{}, size: size}}

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid} -> {:error, :not_found}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def get_bounded(_key, _max_bytes), do: {:error, :invalid}

  @doc """
  Reads several typed records of one table in one query, in the caller's
  order, while their cumulative encoded size fits `max_total_bytes`.

  Each found key maps to the `get_bounded/2` result it would get with
  `max_total_bytes`. A missing key maps to `{:error, :not_found}`. A key whose
  body fits alone but not within the running total is left out, and the
  caller reads it on its own. The total therefore bounds the bytes this call
  transfers, as the one-record limit bounds `get_bounded/2`.
  """
  @spec get_bounded_many([String.t()], pos_integer()) ::
          {:ok, %{String.t() => term()}} | {:error, :invalid | :unavailable}
  def get_bounded_many(keys, max_total_bytes)
      when is_list(keys) and length(keys) in 1..100 and is_integer(max_total_bytes) and
             max_total_bytes > 0 do
    keys = Enum.uniq(keys)

    with {:ok, table} <- single_table(keys) do
      case Repo.query(
             """
             SELECT selected.record_key,
                    CASE WHEN sizes.body_bytes IS NOT NULL
                          AND sum(sizes.body_bytes) OVER (ORDER BY selected.ordinal) <= $2
                         THEN records.body::text END,
                    records.revision,
                    sizes.body_bytes
             FROM unnest($1::text[]) WITH ORDINALITY AS selected(record_key, ordinal)
             JOIN #{table} AS records ON records.record_key = selected.record_key
             LEFT JOIN triage_record_body_sizes AS sizes
               ON sizes.source_table = $3
               AND sizes.record_key = records.record_key
               AND sizes.revision = records.revision
             ORDER BY selected.ordinal
             """,
             [keys, max_total_bytes, table]
           ) do
        {:ok, %{rows: rows}} ->
          found =
            Enum.flat_map(rows, fn
              [key, nil, _revision, nil] ->
                [{key, {:error, :unavailable}}]

              [key, nil, _revision, size] when size > max_total_bytes ->
                [{key, {:error, :too_large}}]

              [_key, nil, _revision, _size] ->
                []

              [key, body, revision, size] ->
                [{key, {:ok, %{body: body, etag: etag(revision), meta: %{}, size: size}}}]
            end)
            |> Map.new()

          returned = MapSet.new(rows, &hd/1)

          {:ok,
           Enum.reduce(keys, found, fn key, acc ->
             if MapSet.member?(returned, key),
               do: acc,
               else: Map.put(acc, key, {:error, :not_found})
           end)}

        {:error, _reason} ->
          {:error, :unavailable}
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def get_bounded_many(_keys, _max_total_bytes), do: {:error, :invalid}

  defp single_table(keys) do
    tables =
      Enum.map(keys, fn key ->
        case resolve_key(key) do
          {:ok, %{table: table}} -> table
          _ -> nil
        end
      end)

    case Enum.uniq(tables) do
      [table] when is_binary(table) -> {:ok, table}
      _ -> {:error, :invalid}
    end
  end

  @doc """
  Reads the recorded execution state of one exact fence without transferring
  model input, output or proof bodies. This is a status projection, not a
  verified public review. The detail reader still owns evidence validation.
  At most 20 selected receipt references can check archived membership.
  """
  def processing_fence(key, receipt_refs)
      when is_binary(key) and is_list(receipt_refs) and length(receipt_refs) in 1..20 do
    case processing_fences([{key, receipt_refs}]) do
      {:ok, %{^key => result}} -> result
      {:error, :invalid} -> {:error, :invalid}
      _ -> {:error, :unavailable}
    end
  end

  def processing_fence(_key, _receipt_refs), do: {:error, :invalid}

  @doc """
  `processing_fence/2` for up to 20 fences in one query. Each request is
  `{fence_key, receipt_refs}`; the result maps each fence key to what
  `processing_fence/2` returns for it. Keys must be unique.
  """
  @spec processing_fences([{String.t(), [String.t()]}]) ::
          {:ok, %{String.t() => {:ok, map()} | {:error, atom()}}}
          | {:error, :invalid | :unavailable}
  def processing_fences(requests) when is_list(requests) and length(requests) in 1..20 do
    keys = Enum.map(requests, &elem(&1, 0))

    valid? =
      Enum.uniq(keys) == keys and
        Enum.all?(requests, fn {key, refs} ->
          is_list(refs) and length(refs) in 1..20 and Enum.all?(refs, &is_binary/1) and
            match?({:ok, %{table: "triage_run_fences"}}, resolve_key(key))
        end)

    if valid? do
      refs =
        Enum.map(requests, fn {_key, refs} ->
          Jason.encode!(Enum.map(refs, &%{"receipt_ref" => &1}))
        end)

      # Extract the fields together so PostgreSQL does not decompress the large
      # evidence body once per field. Materialize the summary to encode it once
      # for both the byte-limit check and the returned value.
      case Repo.query(
             """
             WITH selected AS (
               SELECT * FROM unnest($1::text[], $2::text[]) WITH ORDINALITY
                 AS selected(record_key, receipt_refs, ordinal)
             ), fields AS MATERIALIZED (
               SELECT selected.record_key, selected.receipt_refs::jsonb AS receipt_refs, fields.*
               FROM selected
               JOIN triage_run_fences AS fences ON fences.record_key = selected.record_key
               CROSS JOIN LATERAL jsonb_to_record(fences.body) AS fields(
                 schema jsonb, bucket_scope jsonb, generation jsonb, run_id jsonb,
                 created_at jsonb, deadline_at jsonb, terminal jsonb, sealed_generation jsonb
               )
             ), summaries AS MATERIALIZED (
               SELECT record_key, jsonb_build_object(
                 'schema', schema,
                 'bucket_scope', bucket_scope,
                 'generation', generation,
                 'run_id', run_id,
                 'created_at', created_at,
                 'deadline_at', deadline_at,
                 'terminal', CASE WHEN terminal IS NULL THEN 'null'::jsonb
                   ELSE jsonb_build_object(
                     'status', terminal -> 'status',
                     'settled_at', terminal -> 'settled_at') END,
                 'archived_membership', sealed_generation -> 'receipts' @> receipt_refs,
                 'sealed_at', sealed_generation -> 'sealed_at',
                 'receipt_count', CASE
                   WHEN jsonb_typeof(sealed_generation -> 'receipts') = 'array'
                   THEN jsonb_array_length(sealed_generation -> 'receipts') END
               )::text AS summary
               FROM fields
             )
             SELECT record_key, CASE WHEN octet_length(summary) <= 16384 THEN summary END
             FROM summaries
             """,
             [keys, refs],
             timeout: 250 + 25 * length(requests)
           ) do
        {:ok, %{rows: rows}} ->
          found =
            Map.new(rows, fn
              [key, summary] when is_binary(summary) ->
                case Jason.decode(summary) do
                  {:ok, decoded} -> {key, {:ok, decoded}}
                  _ -> {key, {:error, :unavailable}}
                end

              [key, nil] ->
                {key, {:error, :too_large}}
            end)

          {:ok, Map.new(keys, &{&1, Map.get(found, &1, {:error, :not_found})})}

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def processing_fences(_requests), do: {:error, :invalid}

  @spec head(String.t()) ::
          {:ok, %{etag: String.t(), meta: map()}} | {:error, :not_found | :unavailable}
  def head(key) when is_binary(key) do
    with {:ok, spec} <- resolve_key(key) do
      case Repo.query("SELECT revision FROM #{spec.table} WHERE record_key = $1", [key]) do
        {:ok, %{rows: [[revision]]}} -> {:ok, %{etag: etag(revision), meta: %{}}}
        {:ok, %{rows: []}} -> {:error, :not_found}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :invalid} -> {:error, :not_found}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def head(_key), do: {:error, :not_found}

  @spec delete(String.t(), keyword()) ::
          :ok | {:error, :not_found | :precondition_failed | :invalid | :unavailable}
  def delete(key, opts \\ [])

  def delete(key, opts) when is_binary(key) and is_list(opts) do
    with {:ok, %{deletable?: true} = spec} <- resolve_key(key) do
      conditional? = Keyword.has_key?(opts, :if_match)

      result =
        case Keyword.fetch(opts, :if_match) do
          :error ->
            Repo.query("DELETE FROM #{spec.table} WHERE record_key = $1 RETURNING 1", [key])

          {:ok, token} ->
            delete_exact(key, spec, token)
        end

      case {result, conditional?} do
        {{:ok, %{rows: [[1]]}}, _conditional?} -> :ok
        {{:ok, %{rows: []}}, true} -> conditional_delete_miss(key, spec)
        {{:ok, %{rows: []}}, false} -> {:error, :not_found}
        {{:error, :invalid}, _conditional?} -> {:error, :invalid}
        {{:error, _reason}, _conditional?} -> {:error, :unavailable}
      end
    else
      _not_deletable -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def delete(_key, _opts), do: {:error, :invalid}

  @spec list(String.t(), keyword()) ::
          {:ok, %{objects: [map()], next: String.t() | nil}} | {:error, :invalid | :unavailable}
  def list(prefix, opts \\ [])

  def list(prefix, opts) when is_binary(prefix) and is_list(opts) do
    with {:ok, table, timestamp} <- resolve_prefix(prefix),
         {:ok, limit} <- page_size(opts[:max_keys]),
         {:ok, after_key} <- after_key(opts),
         {:ok, %{rows: rows}} <- list_rows(table, timestamp, prefix, after_key, limit + 1),
         :ok <- validate_list_sizes(rows) do
      {page, overflow} = Enum.split(rows, limit)

      objects =
        Enum.map(page, fn [key, revision, size, updated_at] ->
          %{
            key: key,
            etag: etag(revision),
            size: size,
            last_modified: DateTime.to_iso8601(updated_at)
          }
        end)

      next =
        if overflow == [],
          do: nil,
          else: page |> List.last() |> hd() |> encode_continuation()

      {:ok, %{objects: objects, next: next}}
    else
      {:error, :invalid} -> {:error, :invalid}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def list(_prefix, _opts), do: {:error, :invalid}

  @doc "Returns bounded recovery work without loading completed fence snapshots."
  def recovery_page(prefix, opts) when is_binary(prefix) and is_list(opts) do
    with [_, namespace_key, lane] when lane in ["buckets/", "seals/"] <- Regex.run(@root, prefix),
         {:ok, limit} <- page_size(opts[:max_keys]) do
      case lane do
        "buckets/" -> recovery_bucket_page(namespace_key, opts, limit)
        "seals/" -> recovery_fence_page(namespace_key, opts, limit)
      end
    else
      _invalid -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def recovery_page(_prefix, _opts), do: {:error, :invalid}

  defp recovery_fence_page(namespace_key, opts, limit) do
    with {:ok, after_key} <- after_key(opts),
         {:ok, %{rows: rows}} <- recovery_rows("seals/", namespace_key, after_key, limit + 1) do
      {page, overflow} = Enum.split(rows, limit)

      next =
        if overflow == [], do: nil, else: page |> List.last() |> hd() |> encode_continuation()

      {:ok, %{records: Enum.map(page, fn [key, record] -> {key, record} end), next: next}}
    else
      {:error, :invalid} -> {:error, :invalid}
      _unavailable -> {:error, :unavailable}
    end
  end

  defp recovery_bucket_page(namespace_key, opts, limit) do
    with {:ok, after_key, offset} <- bucket_recovery_cursor(opts),
         {:ok, %{rows: rows}} <- recovery_bucket_rows(namespace_key, after_key, offset, limit) do
      case rows do
        [] ->
          {:ok, %{records: [], next: nil}}

        [[key, record, total, start_offset, has_next_bucket, invalid_history]] ->
          next_offset = start_offset + limit

          next =
            cond do
              next_offset < total -> encode_bucket_recovery_cursor(key, next_offset)
              has_next_bucket -> encode_bucket_recovery_cursor(key, 0)
              true -> nil
            end

          if invalid_history,
            do: {:ok, %{records: [], next: next, record_errors: 1}},
            else: {:ok, %{records: [{key, record}], next: next}}
      end
    else
      {:error, :invalid} -> {:error, :invalid}
      _unavailable -> {:error, :unavailable}
    end
  end

  defp bucket_recovery_cursor(opts) do
    case {opts[:start_after], opts[:continuation_token]} do
      {nil, "pgb:" <> encoded} ->
        with {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
             {:ok, [key, offset]} when is_binary(key) and is_integer(offset) and offset >= 0 <-
               Jason.decode(bytes) do
          {:ok, key, offset}
        else
          _invalid -> {:error, :invalid}
        end

      _other ->
        with {:ok, key} <- after_key(opts), do: {:ok, key, 0}
    end
  end

  defp encode_bucket_recovery_cursor(key, offset),
    do: "pgb:" <> Base.url_encode64(Jason.encode!([key, offset]), padding: false)

  defp recovery_rows("seals/", namespace_key, after_key, limit) do
    Repo.query(
      """
      SELECT record_key, body
      FROM triage_run_fences
      WHERE namespace_key = $1 AND body -> 'terminal' = 'null'::jsonb
        AND record_key > COALESCE($2::text, '')
      ORDER BY record_key
      LIMIT $3
      """,
      [namespace_key, after_key, limit]
    )
  end

  defp recovery_bucket_rows(namespace_key, after_key, offset, limit) do
    # The cursor includes a generation offset: even one long-lived bucket can
    # inspect at most `limit` generations per turn. Indexed JSON array access
    # avoids expanding the complete history before filtering fence membership.
    Repo.query(
      """
      WITH keys AS MATERIALIZED (
        SELECT record_key
        FROM triage_buckets
        WHERE namespace_key = $1 AND record_key >= COALESCE($2::text, '')
          AND (record_key <> COALESCE($2::text, '') OR $3::int > 0)
        ORDER BY record_key
        LIMIT 2
      ), bucket AS MATERIALIZED (
        SELECT b.namespace_key, b.bucket_key, b.record_key,
          b.body -> 'bucket_scope' AS scope,
          CASE WHEN jsonb_typeof(b.body -> 'sealed_generations') = 'array'
            THEN b.body -> 'sealed_generations' ELSE '[]'::jsonb END AS history,
          COALESCE(jsonb_typeof(b.body -> 'sealed_generations') NOT IN ('array', 'null'), false)
            AS invalid_history,
          CASE WHEN b.record_key = $2 THEN $3::int ELSE 0 END AS start_offset
        FROM triage_buckets AS b
        WHERE b.record_key = (SELECT record_key FROM keys ORDER BY record_key LIMIT 1)
      )
      SELECT bucket.record_key,
        jsonb_build_object(
          'bucket_scope', bucket.scope,
          'sealed_generations', COALESCE((
            SELECT jsonb_agg(bucket.history -> ordinal ORDER BY ordinal)
            FROM generate_series(bucket.start_offset,
              LEAST(COALESCE(jsonb_array_length(bucket.history), 0) - 1,
                bucket.start_offset + $4::int - 1))
              AS ordinal
            WHERE NOT EXISTS (
              SELECT 1 FROM triage_run_fences AS fence
              WHERE fence.namespace_key = bucket.namespace_key
                AND fence.bucket_key = bucket.bucket_key
                AND fence.generation_key =
                  encode(sha256(convert_to(bucket.history -> ordinal ->> 'generation', 'UTF8')), 'hex')
            )
          ), '[]'::jsonb)
        ), COALESCE(jsonb_array_length(bucket.history), 0), bucket.start_offset,
        (SELECT count(*) > 1 FROM keys), bucket.invalid_history
      FROM bucket
      """,
      [namespace_key, after_key, offset, limit]
    )
  end

  @spec list_all(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_all(prefix, opts \\ []), do: do_list_all(prefix, opts, [])

  def commit_authoritative(commit),
    do: SalixStore.TriageTransactions.commit_authoritative(commit)

  def admit_receipt(admission),
    do: SalixStore.TriageTransactions.admit_receipt(admission)

  # One indexed membership lookup per selected receipt, at most 20, without
  # scanning a channel's completed batches or loading their archived payloads.
  def receipt_memberships(namespace, identities)
      when is_binary(namespace) and is_list(identities) and length(identities) in 1..20 do
    {sources, recipients} = Enum.unzip(identities)

    case Repo.query(
           """
           SELECT m.canonical_receipt_ref, m.bucket_key, m.generation
           FROM unnest($2::text[], $3::text[]) AS selected(source_key, recipient_key)
           JOIN triage_bucket_memberships m
             ON m.namespace_key = $1
             AND m.physical_source_key = selected.source_key
             AND m.recipient_key = selected.recipient_key
           """,
           [SalixStore.TriageKeys.namespace_key(namespace), sources, recipients],
           timeout: 250
         ) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  def receipt_memberships(_namespace, _identities), do: {:error, :invalid}

  def record_intent_settlement(settlement),
    do: SalixStore.TriageTransactions.record_intent_settlement(settlement)

  defp do_list_all(prefix, opts, acc) do
    case list(prefix, opts) do
      {:ok, %{objects: objects, next: nil}} ->
        {:ok, acc ++ objects}

      {:ok, %{objects: objects, next: token}} ->
        do_list_all(prefix, Keyword.put(opts, :continuation_token, token), acc ++ objects)

      {:error, _reason} = error ->
        error
    end
  end

  defp insert_once(key, spec, body) do
    identity_columns = Enum.map(spec.identity, &elem(&1, 0))
    columns = ["record_key", "namespace_key" | identity_columns] ++ ["body"]
    values = [key, spec.namespace_key | Enum.map(spec.identity, &elem(&1, 1))] ++ [body]
    placeholders = Enum.map_join(1..length(values), ", ", &"$#{&1}")

    case Repo.query(
           "INSERT INTO #{spec.table} (#{Enum.join(columns, ", ")}) VALUES (#{placeholders}) ON CONFLICT DO NOTHING RETURNING revision",
           values
         ) do
      {:ok, %{rows: [[revision]]}} -> {:ok, %{etag: etag(revision)}}
      {:ok, %{rows: []}} -> {:error, :precondition_failed}
      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} -> {:error, :invalid}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp update_exact(_key, %{mutable?: false}, _body, _revision),
    do: {:error, :precondition_failed}

  defp update_exact(key, spec, body, revision) do
    case Repo.query(
           "UPDATE #{spec.table} SET body = $2, revision = revision + 1, updated_at = now() WHERE record_key = $1 AND revision = $3 RETURNING revision",
           [key, body, revision]
         ) do
      {:ok, %{rows: [[next_revision]]}} -> {:ok, %{etag: etag(next_revision)}}
      {:ok, %{rows: []}} -> {:error, :precondition_failed}
      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} -> {:error, :invalid}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp delete_exact(key, spec, token) do
    case revision(token) do
      {:ok, revision} ->
        Repo.query(
          "DELETE FROM #{spec.table} WHERE record_key = $1 AND revision = $2 RETURNING 1",
          [key, revision]
        )

      :error ->
        {:error, :invalid}
    end
  end

  defp conditional_delete_miss(key, spec) do
    case Repo.query("SELECT 1 FROM #{spec.table} WHERE record_key = $1", [key]) do
      {:ok, %{rows: [[1]]}} -> {:error, :precondition_failed}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp list_rows(table, timestamp, prefix, after_key, limit) do
    pattern = escape_like(prefix) <> "%"

    if table in @body_size_metadata_tables do
      Repo.query(
        "SELECT records.record_key, records.revision, sizes.body_bytes, records.#{timestamp} FROM #{table} AS records LEFT JOIN triage_record_body_sizes AS sizes ON sizes.source_table = $4 AND sizes.record_key = records.record_key AND sizes.revision = records.revision WHERE records.record_key LIKE $1 ESCAPE '\\' AND ($2::text IS NULL OR records.record_key > $2) ORDER BY records.record_key LIMIT $3",
        [pattern, after_key, limit, table]
      )
    else
      Repo.query(
        "SELECT record_key, revision, octet_length(body::text), #{timestamp} FROM #{table} WHERE record_key LIKE $1 ESCAPE '\\' AND ($2::text IS NULL OR record_key > $2) ORDER BY record_key LIMIT $3",
        [pattern, after_key, limit]
      )
    end
  end

  defp validate_list_sizes(rows) do
    if Enum.all?(rows, fn
         [_key, _revision, size, _updated_at] when is_integer(size) and size > 0 -> true
         _row -> false
       end),
       do: :ok,
       else: {:error, :unavailable}
  end

  defp resolve_key(key) do
    with [_, namespace_key, path] <- Regex.run(@root, key),
         {:ok, table, identity, mutable?, deletable?, timestamp} <- resolve_path(path) do
      {:ok,
       %{
         table: table,
         namespace_key: namespace_key,
         identity: identity,
         mutable?: mutable?,
         deletable?: deletable?,
         timestamp: timestamp
       }}
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp resolve_path("receipt_recovery_lease.json"),
    do: {:ok, "triage_recovery_leases", [], true, true, "updated_at"}

  defp resolve_path(path) do
    case String.split(path, "/") do
      ["projections", receipt] ->
        immutable("triage_receipt_projections", receipt_key: leaf!(receipt))

      ["source_aliases", source] ->
        immutable("triage_ambient_aliases", physical_source_key: leaf!(source))

      ["buckets", bucket] ->
        mutable("triage_buckets", bucket_key: leaf!(bucket))

      ["seals", bucket, generation] ->
        mutable("triage_run_fences", bucket_key: bucket, generation_key: leaf!(generation))

      ["ledger", "runs", run_id] ->
        immutable("triage_runs", run_id: leaf!(run_id))

      ["ledger", "correlations", selector_kind, selector_key, run_id] ->
        immutable("triage_correlation_entries",
          selector_kind: selector_kind,
          selector_key: selector_key,
          run_id: leaf!(run_id)
        )

      ["ledger", "by_time", created_at, run_id] ->
        with {created_at_ms, ""} <- Integer.parse(created_at) do
          immutable("triage_time_index_entries",
            created_at_ms: created_at_ms,
            run_id: leaf!(run_id)
          )
        else
          _invalid -> {:error, :invalid}
        end

      ["ledger", "activity", identity_scope_key, reverse_created_at, run_id] ->
        with {reverse_created_at_ms, ""} <- Integer.parse(reverse_created_at) do
          immutable("triage_activity_index_entries",
            identity_scope_key: identity_scope_key,
            reverse_created_at_ms: reverse_created_at_ms,
            run_id: leaf!(run_id)
          )
        else
          _invalid -> {:error, :invalid}
        end

      ["replay", run_id] ->
        immutable("triage_replays", run_id: leaf!(run_id))

      ["lifecycle", run_id, event_id] ->
        immutable("triage_lifecycle_events", run_id: run_id, event_id: leaf!(event_id))

      ["ledger", "late", run_id, observation_id] ->
        immutable("triage_late_results",
          run_id: run_id,
          observation_id: leaf!(observation_id)
        )

      _unknown ->
        {:error, :invalid}
    end
  rescue
    ArgumentError -> {:error, :invalid}
  end

  defp resolve_prefix(prefix) do
    with [_, _namespace_key, path] <- Regex.run(@root, prefix) do
      cond do
        String.starts_with?(path, "projections/") ->
          {:ok, "triage_receipt_projections", "inserted_at"}

        String.starts_with?(path, "source_aliases/") ->
          {:ok, "triage_ambient_aliases", "inserted_at"}

        String.starts_with?(path, "buckets/") ->
          {:ok, "triage_buckets", "updated_at"}

        String.starts_with?(path, "seals/") ->
          {:ok, "triage_run_fences", "updated_at"}

        String.starts_with?(path, "ledger/runs/") ->
          {:ok, "triage_runs", "inserted_at"}

        String.starts_with?(path, "ledger/correlations/") ->
          {:ok, "triage_correlation_entries", "inserted_at"}

        String.starts_with?(path, "ledger/by_time/") ->
          {:ok, "triage_time_index_entries", "inserted_at"}

        String.starts_with?(path, "ledger/activity/") ->
          {:ok, "triage_activity_index_entries", "inserted_at"}

        String.starts_with?(path, "replay/") ->
          {:ok, "triage_replays", "inserted_at"}

        String.starts_with?(path, "lifecycle/") ->
          {:ok, "triage_lifecycle_events", "inserted_at"}

        String.starts_with?(path, "ledger/late/") ->
          {:ok, "triage_late_results", "inserted_at"}

        true ->
          {:error, :invalid}
      end
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp immutable(table, identity),
    do: {:ok, table, normalize_identity(identity), false, false, "inserted_at"}

  defp mutable(table, identity),
    do: {:ok, table, normalize_identity(identity), true, false, "updated_at"}

  defp normalize_identity(identity),
    do: Enum.map(identity, fn {key, value} -> {Atom.to_string(key), value} end)

  defp leaf!(value) do
    case String.split(value, ".json", parts: 2) do
      [leaf, ""] when leaf != "" -> leaf
      _invalid -> raise ArgumentError
    end
  end

  defp decode_body(body) do
    with binary when is_binary(binary) <- IO.iodata_to_binary(body),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(binary) do
      {:ok, decoded}
    else
      _invalid -> {:error, :invalid}
    end
  rescue
    _exception -> {:error, :invalid}
  end

  defp condition(opts) do
    case {Keyword.fetch(opts, :if_none_match), Keyword.fetch(opts, :if_match)} do
      {{:ok, "*"}, :error} ->
        :create

      {:error, {:ok, token}} ->
        case revision(token) do
          {:ok, value} -> {:match, value}
          :error -> :invalid
        end

      _other ->
        :invalid
    end
  end

  defp page_size(nil), do: {:ok, @default_page_size}
  defp page_size(value) when is_integer(value) and value in 1..@max_page_size, do: {:ok, value}
  defp page_size(_value), do: {:error, :invalid}

  defp after_key(opts) do
    case {Keyword.get(opts, :start_after), Keyword.get(opts, :continuation_token)} do
      {nil, nil} -> {:ok, nil}
      {value, nil} when is_binary(value) -> {:ok, value}
      {nil, value} when is_binary(value) -> decode_continuation(value)
      _other -> {:error, :invalid}
    end
  end

  defp encode_continuation(key), do: "pg:" <> Base.url_encode64(key, padding: false)

  defp decode_continuation("pg:" <> encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :invalid}
    end
  end

  defp decode_continuation(_token), do: {:error, :invalid}

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp etag(revision), do: "pg:#{revision}"

  defp revision("pg:" <> encoded) do
    case Integer.parse(encoded) do
      {value, ""} when value > 0 -> {:ok, value}
      _invalid -> :error
    end
  end

  defp revision(_token), do: :error
end
