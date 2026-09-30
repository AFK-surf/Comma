defmodule SalixStore.CasDirectory do
  @moduledoc """
  A bounded id → record map stored as ONE S3 object, mutated by CAS.

  Single-object CAS is the only transaction S3 offers. For a **bounded,
  small** collection (hundreds to a couple thousand entries), holding the
  whole collection in one object makes every multi-entry invariant — unique
  keys, membership, atomic move between states — a plain conditional PUT: no
  per-key index to keep in lockstep with a canonical prefix, no backfill, no
  reconcile worker, no tombstone protocol, and reads are one GET instead of
  LIST + N GETs.

  This module deliberately refuses to become a database:

    * **Bounds are enforced, not advisory.** A write that would push the
      directory past `max_entries` or `max_bytes` fails with
      `{:error, {:directory_limit, ...}}`. Unbounded growth belongs in
      segmented per-key layouts (see `docs/storage-search.md`), never in one object. Limits stop GROWTH only:
      a write that leaves an already-over-limit directory no worse (e.g. a
      delete, or a bulk fold reducing itself) is always admitted — rejecting
      shrinkage would permanently lock an over-limit directory against its
      own reduction.
    * **Ambiguous CAS outcomes are settled by operation identity**, exactly
      like the storage kernel's root-object protocol (`SalixStore.Agent`'s
      `commit_uuid`): every write stamps a fresh op token into the object,
      and a 412/ambiguous PUT is success only when read-back finds our token
      in the object's recent-op ring. Byte comparison is NOT identity — two
      writers applying the same transform in the same millisecond produce
      identical bodies, and adopting the other writer's byte-twin would
      silently drop one update.
    * **Contention is expected to be low.** Every mutation rewrites the
      object, so this fits admin-frequency collections (connects, pins,
      schedules, small working sets), not per-message or per-commit state.

  ## Layout

      {"format": 1, "entries": {"<id>": {...}}, "updated_at": <ms>,
       "op": "<this write's token>", "ops": ["<newest>", ...]}

  `ops` is a bounded ring of the most recent write tokens (newest first,
  `op` included). It exists solely so a writer whose conditional PUT landed
  but whose reply was lost — and whose committed version may ALREADY have
  been superseded by a faster competing writer — can still recognize its own
  landed write on read-back instead of re-running a non-idempotent reducer
  over its own result.

  ## Adopting an existing per-key prefix

  `ensure_bootstrapped/3` migrates a legacy `prefix/{id}.json` collection
  into a directory lazily and race-safely: the first caller LISTs the old
  prefix (fail-closed — a partial scan never seeds a partial directory),
  transforms each record, and create-onces the directory; concurrent
  bootstrappers collapse on the create-once. Old keys are left in place for
  a separate cleanup pass — the directory is authoritative from the moment
  it exists.
  """

  alias SalixStore.S3

  @default_max_entries 2_000
  @default_max_bytes 512 * 1024
  @cas_attempts 8
  @cas_backoff_ms 2
  @cas_backoff_max_ms 25

  # Recent-op ring depth. The ring is a POSITIVE-ONLY fast path: finding our
  # token proves our write landed; not finding it proves nothing (the token
  # may simply have been evicted by later writes), and an ambiguous outcome
  # whose token is absent stays ambiguous. Depth therefore tunes how often
  # the fast path hits — it is not a correctness parameter.
  @op_ring 16

  @type dir_key :: String.t()
  @type id :: String.t()
  @type entry :: map()
  @type entries :: %{optional(id()) => entry()}
  @type opt :: {:max_entries, pos_integer()} | {:max_bytes, pos_integer()}

  @doc "All entries as a map. `{:error, :not_found}` when the directory does not exist."
  @spec entries(dir_key()) :: {:ok, entries()} | {:error, term()}
  def entries(dir_key) do
    case read(dir_key) do
      {:ok, entries, _etag, _ops} -> {:ok, entries}
      {:error, _} = error -> error
    end
  end

  @doc "Like `entries/1`, but an absent directory reads as empty."
  @spec entries_or_empty(dir_key()) :: {:ok, entries()} | {:error, term()}
  def entries_or_empty(dir_key) do
    case entries(dir_key) do
      {:ok, entries} -> {:ok, entries}
      {:error, :not_found} -> {:ok, %{}}
      {:error, _} = error -> error
    end
  end

  @doc "All entries as an id-sorted list, `[]` when the directory does not exist."
  @spec list(dir_key()) :: {:ok, [{id(), entry()}]} | {:error, term()}
  def list(dir_key) do
    case read(dir_key) do
      {:ok, entries, _etag, _ops} -> {:ok, Enum.sort_by(entries, &elem(&1, 0))}
      {:error, :not_found} -> {:ok, []}
      {:error, _} = error -> error
    end
  end

  @doc "One entry. `{:error, :not_found}` covers both a missing directory and a missing id."
  @spec get(dir_key(), id()) :: {:ok, entry()} | {:error, term()}
  def get(dir_key, id) do
    case read(dir_key) do
      {:ok, entries, _etag, _ops} ->
        case Map.fetch(entries, id) do
          {:ok, record} -> {:ok, record}
          :error -> {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Upsert one entry by CAS. `value` is the record map, or a
  `(record | nil -> record)` function of the current entry. Creates the
  directory (create-once) when absent.
  """
  @spec put(dir_key(), id(), entry() | (entry() | nil -> entry()), [opt()]) ::
          {:ok, entry()} | {:error, term()}
  def put(dir_key, id, value, opts \\ []) do
    result =
      update(
        dir_key,
        fn entries ->
          record = resolve_value(value, Map.get(entries, id))
          Map.put(entries, id, record)
        end,
        opts
      )

    case result do
      {:ok, entries} -> {:ok, Map.fetch!(entries, id)}
      {:error, _} = error -> error
    end
  end

  @doc "Remove one entry by CAS. Removing a missing id (or from a missing directory) is `:ok`."
  @spec delete(dir_key(), id(), [opt()]) :: :ok | {:error, term()}
  def delete(dir_key, id, opts \\ []) do
    case update(dir_key, &Map.delete(&1, id), opts) do
      {:ok, _entries} -> :ok
      # No directory yet — nothing to delete from.
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Atomically transform the whole entry map (the convergence hook). `fun`
  receives the current entries (`%{}` only when `create: true` and the
  directory is absent) and returns the next entries. No-op transforms skip
  the write.
  """
  @spec update(dir_key(), (entries() -> entries()), [opt() | {:create, boolean()}]) ::
          {:ok, entries()} | {:error, term()}
  def update(dir_key, fun, opts \\ []), do: do_update(dir_key, fun, opts, @cas_attempts)

  @doc """
  The single-object transaction: evaluate `fun` against the current entries
  and either commit a new entry map or abort — decision and write are one
  CAS, so every invariant `fun` checks (uniqueness, ownership, fencing
  tokens) holds at the moment the write lands, with no cross-object window.

  `fun` returns `{:commit, next_entries, result}` or `{:abort, result}`;
  both yield `{:ok, result}` (an abort is a decided outcome, not an error).
  A CAS conflict re-reads and re-evaluates `fun` on the fresh entries,
  bounded. A committed write that equals the current entries skips the PUT.
  The directory is created create-once when absent (`fun` sees `%{}`).

  `materialize: true` additionally creates the directory even when the
  committed entries are empty (`%{} -> %{}` on an absent directory writes
  an explicit empty object instead of skipping). Use it when the caller's
  contract makes directory EXISTENCE itself meaningful — e.g. a cache whose
  absence reads as "never reconciled" and forces expensive rebuild work.
  Do NOT use it on directories adopted via `ensure_bootstrapped/4`: an
  empty materialized object would win the create-once and orphan the
  legacy source it was supposed to fold in.
  """
  @spec transact(dir_key(), (entries() -> {:commit, entries(), term()} | {:abort, term()}), [
          opt() | {:materialize, boolean()}
        ]) :: {:ok, term()} | {:error, term()}
  def transact(dir_key, fun, opts \\ []), do: do_transact(dir_key, fun, opts, @cas_attempts)

  defp do_transact(_dir_key, _fun, _opts, 0), do: {:error, :cas_exhausted}

  defp do_transact(dir_key, fun, opts, attempts) do
    {entries, etag_or_create, prev_ops} =
      case read(dir_key) do
        {:ok, entries, etag, ops} -> {entries, etag, ops}
        {:error, :not_found} -> {%{}, :create, []}
        {:error, _} = error -> throw({:transact_read, error})
      end

    case fun.(entries) do
      {:abort, result} ->
        {:ok, result}

      {:commit, next, result} when is_map(next) ->
        materialize_absent? = etag_or_create == :create and Keyword.get(opts, :materialize, false)

        if next == entries and not materialize_absent? do
          {:ok, result}
        else
          limit_base = if etag_or_create == :create, do: :absent, else: entries

          with :ok <- check_limits(next, limit_base, opts) do
            case write(dir_key, next, etag_or_create, prev_ops) do
              :ok ->
                {:ok, result}

              {:error, :precondition_failed} ->
                attempt = max(@cas_attempts - attempts + 1, 1)
                Process.sleep(min(attempt * @cas_backoff_ms, @cas_backoff_max_ms))
                do_transact(dir_key, fun, opts, attempts - 1)

              {:error, _} = error ->
                error
            end
          end
        end
    end
  catch
    {:transact_read, error} -> error
  end

  defp do_update(_dir_key, _fun, _opts, 0), do: {:error, :cas_exhausted}

  defp do_update(dir_key, fun, opts, attempts) do
    case read(dir_key) do
      {:ok, entries, etag, prev_ops} ->
        next = fun.(entries)

        if next == entries do
          {:ok, entries}
        else
          with :ok <- check_limits(next, entries, opts) do
            case write(dir_key, next, etag, prev_ops) do
              :ok -> {:ok, next}
              {:error, :precondition_failed} -> retry_update(dir_key, fun, opts, attempts)
              {:error, _} = error -> error
            end
          end
        end

      {:error, :not_found} ->
        next = fun.(%{})

        cond do
          next == %{} and not Keyword.get(opts, :create, false) ->
            {:error, :not_found}

          true ->
            with :ok <- check_limits(next, :absent, opts) do
              case write(dir_key, next, :create, []) do
                :ok -> {:ok, next}
                {:error, :precondition_failed} -> retry_update(dir_key, fun, opts, attempts)
                {:error, _} = error -> error
              end
            end
        end

      {:error, _} = error ->
        error
    end
  end

  defp retry_update(dir_key, fun, opts, attempts) do
    attempt = max(@cas_attempts - attempts + 1, 1)
    Process.sleep(min(attempt * @cas_backoff_ms, @cas_backoff_max_ms))
    do_update(dir_key, fun, opts, attempts - 1)
  end

  @default_max_source_objects 2_000

  @doc """
  Create the directory from a legacy per-key `source_prefix` if it does not
  exist yet. `transform` maps each `{key, decoded_record}` to `{id, record}`
  or `:skip`. Fail-closed: any LIST or record-GET fault aborts (a partial
  scan must never seed a partial directory), and a source larger than
  `:max_source_objects` (default #{@default_max_source_objects}) aborts
  BEFORE hydrating — the scan is bounded, never a repeated unbounded
  request-path fan-out. Concurrent bootstrappers collapse on the
  create-once; old keys are left for a separate cleanup.

  This is an EXCLUSIVE-cutover primitive: after the directory exists the
  legacy prefix is never read again, so it only suits collections with a
  single writer generation (deploy-stopped, or data older than any running
  writer). For rolling deploys where old code keeps writing the legacy
  layout, use a dual-read protocol plus an idempotent migration instead.
  """
  @spec ensure_bootstrapped(
          dir_key(),
          String.t(),
          ({String.t(), map()} -> {id(), entry()} | :skip),
          [opt() | {:max_source_objects, pos_integer()}]
        ) :: :ok | {:error, term()}
  def ensure_bootstrapped(dir_key, source_prefix, transform, opts \\ []) do
    case S3.head(dir_key) do
      {:ok, _} ->
        :ok

      {:error, :not_found} ->
        with {:ok, entries} <- collect_source(source_prefix, transform, opts),
             :ok <- check_limits(entries, :absent, opts) do
          case write(dir_key, entries, :create, []) do
            :ok -> :ok
            # Another bootstrapper won the create-once — theirs is authoritative.
            {:error, :precondition_failed} -> :ok
            {:error, _} = error -> error
          end
        end

      {:error, _} = error ->
        error
    end
  end

  defp collect_source(source_prefix, transform, opts) do
    budget = Keyword.get(opts, :max_source_objects, @default_max_source_objects)

    with {:ok, objects} <- list_source_bounded(source_prefix, budget) do
      Enum.reduce_while(objects, {:ok, %{}}, fn %{key: key}, {:ok, acc} ->
        case S3.get(key) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, record} when is_map(record) ->
                case transform.({key, record}) do
                  {id, transformed} -> {:cont, {:ok, Map.put(acc, id, transformed)}}
                  :skip -> {:cont, {:ok, acc}}
                end

              _ ->
                {:halt, {:error, {:bootstrap_source_invalid, key}}}
            end

          # Deleted between LIST and GET — not part of the collection.
          {:error, :not_found} ->
            {:cont, {:ok, acc}}

          {:error, reason} ->
            {:halt, {:error, {:bootstrap_source_read_failed, key, reason}}}
        end
      end)
    end
  end

  # One LIST page sized to the budget: a continuation past it means the
  # source exceeds what this directory may hold — abort before any GETs.
  # Real S3 caps a ListObjectsV2 page at 1,000 keys regardless of max_keys,
  # so the budget is enforced by paginating METADATA (never hydrating) until
  # either the prefix is exhausted or the budget is exceeded — a
  # 1,001–2,000-object source under a 2,000 budget is valid in production,
  # not a false over-budget.
  @list_page_cap 1_000

  defp list_source_bounded(source_prefix, budget) do
    collect_source_pages(source_prefix, budget, nil, [])
  end

  defp collect_source_pages(source_prefix, budget, token, acc) do
    page_size = min(budget + 1 - length(acc), @list_page_cap)
    opts = [max_keys: page_size] ++ if token, do: [continuation_token: token], else: []

    case S3.list(source_prefix, opts) do
      {:ok, %{objects: objects, next: next}} ->
        acc = acc ++ objects

        cond do
          length(acc) > budget ->
            {:error, {:bootstrap_source_over_budget, source_prefix, budget}}

          is_nil(next) or objects == [] ->
            {:ok, acc}

          true ->
            collect_source_pages(source_prefix, budget, next, acc)
        end

      {:error, reason} ->
        {:error, {:bootstrap_source_list_failed, reason}}
    end
  end

  # ---- object encoding / IO ----

  defp read(dir_key) do
    case S3.get(dir_key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, %{"format" => 1, "entries" => entries} = decoded} when is_map(entries) ->
            {:ok, entries, etag, decoded_ops(decoded)}

          _ ->
            {:error, {:invalid_directory, dir_key}}
        end

      {:error, :not_found} = error ->
        error

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Settlement is by OPERATION IDENTITY, not byte comparison: our fresh op
  # token in the live object's recent-op ring proves our write landed, even
  # when a faster competing writer has already committed on top of it.
  #
  # The soundness split with the adapter (salix_store/s3/aws.ex):
  #
  #   * a CLEAN `:precondition_failed` is guaranteed by the adapter to be a
  #     real competing-writer conflict — a conditional write whose FIRST
  #     attempt answered 412 cannot have landed, and a 412 after a transport
  #     retry is never reported as 412 (it arrives as
  #     `{:ambiguous, :conditional_retry_412}` instead, because only the
  #     adapter knows the retry happened). Re-running the reducer on a clean
  #     412 is therefore always safe; the ring check on that path is a fast
  #     path, not a correctness requirement — no finite ring depth is.
  #   * an AMBIGUOUS outcome settles by ring only in the positive direction:
  #     token present -> our write landed -> :ok. Token absent proves
  #     NOTHING (it may simply have been evicted by later commits) — the
  #     outcome stays ambiguous and is returned to the caller, never
  #     collapsed into "conflict, re-run".
  defp write(dir_key, entries, etag_or_create, prev_ops) do
    op = op_token()
    body = encode(entries, [op | prev_ops] |> Enum.take(@op_ring))

    put_opts =
      case etag_or_create do
        :create -> [if_none_match: "*"]
        etag -> [if_match: etag]
      end

    case S3.put(dir_key, body, put_opts) do
      {:ok, _} -> :ok
      {:error, :precondition_failed} = error -> settle_by_op(dir_key, op, error)
      {:error, {:ambiguous, _}} = error -> settle_by_op(dir_key, op, error)
      {:error, _} = error -> error
    end
  end

  defp settle_by_op(dir_key, op, original_error) do
    case S3.get(dir_key) do
      {:ok, %{body: live}} ->
        case Jason.decode(live) do
          {:ok, decoded} when is_map(decoded) ->
            cond do
              op in decoded_ops(decoded) ->
                :ok

              # Clean 412: adapter-guaranteed competing writer (see write/4)
              # — safe for the caller to re-read and re-run.
              original_error == {:error, :precondition_failed} ->
                original_error

              # Ambiguous with the token absent: eviction is indistinguishable
              # from never-landed — stay ambiguous, never become a re-run.
              true ->
                original_error
            end

          # An undecodable live object proves nothing about our write.
          _ ->
            {:error, {:ambiguous, {:readback_undecodable, dir_key}}}
        end

      # :not_found can follow a landed create-once whose object was since
      # deleted, or a never-landed write — undecidable either way.
      {:error, reason} ->
        {:error, {:ambiguous, {:readback_failed, dir_key, reason}}}
    end
  end

  defp decoded_ops(%{"op" => op, "ops" => ops}) when is_list(ops),
    do: Enum.uniq([op | Enum.filter(ops, &is_binary/1)])

  defp decoded_ops(%{"op" => op}) when is_binary(op), do: [op]
  defp decoded_ops(_decoded), do: []

  defp op_token, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)

  defp encode(entries, ops) do
    Jason.encode!(%{
      "format" => 1,
      "entries" => entries,
      "updated_at" => System.system_time(:millisecond),
      "op" => List.first(ops),
      "ops" => ops
    })
  end

  # Limits stop growth, not repair: a next state over a limit is rejected
  # ONLY when it is also worse than the current state on that dimension.
  # An over-limit directory (e.g. bulk-seeded by a migration under wider
  # limits) therefore stays reducible — every delete is admitted — instead
  # of being permanently locked against its own reduction.
  #
  # Byte sizes are measured with a worst-case full op ring so admission
  # cannot depend on how many ops happen to be in the live ring.
  # Creating the object (`current == :absent`): there is no pre-existing
  # size to grandfather, so the full bounds apply — including the encoded
  # empty-map envelope itself. The growth-only exemption below exists so an
  # already-over-limit directory stays REDUCIBLE; a not-yet-existing one has
  # nothing to reduce.
  defp check_limits(next, :absent, opts) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    next_bytes = byte_size(encode(next, empty_ring()))

    cond do
      map_size(next) > max_entries ->
        {:error, {:directory_limit, :max_entries, map_size(next), max_entries}}

      next_bytes > max_bytes ->
        {:error, {:directory_limit, :max_bytes, next_bytes, max_bytes}}

      true ->
        :ok
    end
  end

  defp check_limits(next, current, opts) when is_map(current) do
    max_entries = Keyword.get(opts, :max_entries, @default_max_entries)
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)
    next_bytes = byte_size(encode(next, empty_ring()))

    cond do
      map_size(next) > max_entries and map_size(next) > map_size(current) ->
        {:error, {:directory_limit, :max_entries, map_size(next), max_entries}}

      next_bytes > max_bytes and next_bytes > byte_size(encode(current, empty_ring())) ->
        {:error, {:directory_limit, :max_bytes, next_bytes, max_bytes}}

      true ->
        :ok
    end
  end

  defp empty_ring, do: List.duplicate(String.duplicate("0", 24), @op_ring)

  defp resolve_value(fun, current) when is_function(fun, 1), do: fun.(current)
  defp resolve_value(record, _current) when is_map(record), do: record
end
