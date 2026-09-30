defmodule SalixAgent.AgentWorkspace do
  @moduledoc """
  Agent workspace boundary.

  The workspace owns the agent's virtual filesystem manifest. Bodies live
  immutably in canonical blob objects (`SalixStore.Blob`). Runtime code prepares
  workspace events here, commits them through an idempotent workspace operation,
  then commits its own session result separately.

  The operation ledger (`State.operations`) is a bounded idempotency and staging
  window, not history. A committed operation answers a retry of the same
  `operation_id` with its first result, and holds a mutating background tool
  result until the session commit that references it lands. Mutation-free
  internal results use the Session receipt directly. Records stay for the newest 256
  operations, 4 MB, or 24 hours, whichever limit is reached first, and a record
  younger than one hour is never evicted. Every reader needs a record for at most
  the async settlement retry budget (60 x 1 s) or the session's next activation.
  Once the session commit lands, the durable home of a background result is the
  session's `tool_result_stored` record, and of a file the manifest entry plus
  its blob. Between the workspace commit and that session commit the ledger copy
  is the only durable copy: a session that crashes in that window is re-woken by
  the eager session-work recovery lane (`process_local_background_tool_run`,
  swept on the 10 s cluster recovery tick), and its repair reads the copy back.
  The floor exists for that window. A result that has not yet been recovered into
  the session is lost once it is older than the floor and a later commit evicts it
  under any limit: the newest-256 count, the 4 MB byte budget (one large result is
  enough) or the 24-hour TTL (any later commit is enough); the call then fails as
  `runtime_restarted` and the model may re-run it. The owner accepted that loss
  (`docs/agent-runtime.md`).
  """

  alias SalixAgent.AgentActor
  alias SalixStore.{Blob, Codec, Keys, S3}
  require Logger

  defmodule State do
    @moduledoc "Durable agent workspace state."
    @type t :: %__MODULE__{agent_id: String.t() | nil, vfs: map(), operations: map()}
    defstruct agent_id: nil, vfs: %{}, operations: %{}
  end

  defmodule PreparedOperation do
    @moduledoc false

    alias SalixAgent.AgentWorkspace.State

    @enforce_keys [:agent_id, :operation_id, :result, :events, :next_state, :etag]
    defstruct [:agent_id, :operation_id, :result, :events, :next_state, :etag]

    @type t :: %__MODULE__{
            agent_id: String.t(),
            operation_id: String.t(),
            result: term(),
            events: [map()],
            next_state: State.t(),
            etag: String.t() | nil
          }
  end

  @workspace_event_types MapSet.new(["vfs_write", "vfs_delete", "vfs_copy"])
  @max_commit_retries 8

  # Ledger window. The floor keeps every record younger than an hour whatever
  # the other limits say, so a burst can grow the hot object but never evict a
  # record a settlement retry (60 x 1 s) or a restart repair could still ask
  # for. The count, byte and age limits only bound the hot object's size;
  # `SkillStore` bounds its ledger the same way.
  @operation_floor_seconds 60 * 60
  @operation_ttl_seconds 24 * 60 * 60
  @max_operations 256
  @max_operations_bytes 4 * 1024 * 1024

  @doc """
  Write `content` to `path`: store the body, return the `vfs_write` workspace
  event to commit.
  """
  @spec prepare_write(String.t(), String.t(), binary()) :: {:ok, map()} | {:error, term()}
  def prepare_write(agent_id, path, content) do
    case Blob.put(agent_id, content) do
      {:ok, ref} ->
        {:ok,
         %{
           "type" => "vfs_write",
           "path" => path,
           "ref" => stringify(ref),
           "size" => ref.size,
           "hash" => ref.hash,
           "modified_at" => System.os_time(:second)
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def prepare_managed_write(agent_id, path, content) do
    case Blob.put_prepared(agent_id, content) do
      {:ok, ref} -> managed_write_ref(path, ref)
      {:error, _} = error -> error
    end
  end

  @doc "The `vfs_delete` workspace event for `path`."
  @spec prepare_delete(String.t()) :: map()
  def prepare_delete(path), do: %{"type" => "vfs_delete", "path" => path}

  @doc "The `vfs_copy` workspace event."
  @spec prepare_copy(String.t(), String.t()) :: map()
  def prepare_copy(from, to), do: %{"type" => "vfs_copy", "from" => from, "to" => to}

  @doc "Return true when an event mutates agent workspace state."
  @spec workspace_event?(map()) :: boolean()
  def workspace_event?(event) when is_map(event) do
    type = event["type"] || event[:type]
    MapSet.member?(@workspace_event_types, type)
  end

  def workspace_event?(_event), do: false

  @doc "Read a file body from storage via the workspace manifest ref."
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, :not_found} | {:error, term()}
  def read(agent_id, path) do
    with {:ok, state} <- read_state(agent_id) do
      case Map.get(state.vfs, path) do
        nil -> {:error, :not_found}
        %{"ref" => ref} -> Blob.get(agent_id, ref)
      end
    end
  end

  @doc "Return an enumerable over a file body via the workspace manifest ref."
  @spec stream(String.t(), String.t()) ::
          {:ok, Enumerable.t(), non_neg_integer()} | {:error, :not_found} | {:error, term()}
  def stream(agent_id, path) do
    with {:ok, state} <- read_state(agent_id) do
      case Map.get(state.vfs, path) do
        nil -> {:error, :not_found}
        %{"ref" => ref} -> Blob.stream(agent_id, ref)
      end
    end
  end

  @doc "Write an enumerable body to storage and return a workspace manifest event."
  @spec prepare_write_stream(String.t(), String.t(), Enumerable.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_write_stream(agent_id, path, stream) do
    case Blob.put_stream(agent_id, stream) do
      {:ok, ref} ->
        {:ok,
         %{
           "type" => "vfs_write",
           "path" => path,
           "ref" => stringify(ref),
           "size" => ref.size,
           "hash" => ref.hash,
           "modified_at" => System.os_time(:second)
         }}

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def prepare_managed_write_stream(agent_id, path, stream) do
    case Blob.put_stream_prepared(agent_id, stream) do
      {:ok, ref} -> managed_write_ref(path, ref)
      {:error, _} = error -> error
    end
  end

  @doc "Discard the body of an uncommitted prepared write event."
  @spec discard_prepared_write(map()) :: :ok | {:error, term()}
  def discard_prepared_write(%{"type" => "vfs_write", "ref" => %{} = ref}),
    do: Blob.discard(ref)

  def discard_prepared_write(_event), do: :ok

  @doc """
  Build a `vfs_write` event for an already-stored blob `ref` (e.g. produced by a
  backpressured streaming upload via `SalixStore.Blob.put_stream_finish/1`).
  """
  @spec prepare_write_ref(String.t(), SalixStore.Blob.ref()) :: {:ok, map()}
  def prepare_write_ref(path, ref) do
    {:ok,
     %{
       "type" => "vfs_write",
       "path" => path,
       "ref" => stringify(ref),
       "size" => ref.size,
       "hash" => ref.hash,
       "modified_at" => System.os_time(:second)
     }}
  end

  @doc """
  Build a `vfs_write` event that re-points `path` at an existing manifest
  `entry`'s already-stored blob body (zero-copy cross-agent share). Reuses the
  entry's ref/size/hash verbatim with a fresh `modified_at`. The entry shape
  matches `entry/2`'s return and what `apply_workspace_event/2` stores.
  """
  @spec prepare_copy_entry(String.t(), map()) :: {:ok, map()}
  def prepare_copy_entry(path, entry) when is_map(entry) do
    {:ok,
     %{
       "type" => "vfs_write",
       "path" => path,
       "ref" => entry["ref"] || entry[:ref],
       "size" => entry["size"] || entry[:size],
       "hash" => entry["hash"] || entry[:hash],
       "modified_at" => System.os_time(:second)
     }}
  end

  @doc "List manifest paths, optionally under a prefix, sorted."
  @spec list(String.t(), String.t()) :: [String.t()]
  def list(agent_id, prefix \\ "") do
    case read_state(agent_id) do
      {:ok, state} ->
        state.vfs
        |> Map.keys()
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.sort()

      {:error, reason} ->
        raise "workspace list failed: #{inspect(reason)}"
    end
  end

  @doc "File metadata without fetching the body."
  @spec stat(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found} | {:error, term()}
  def stat(agent_id, path) do
    with {:ok, state} <- read_state(agent_id) do
      case Map.get(state.vfs, path) do
        nil -> {:error, :not_found}
        entry -> {:ok, %{size: entry["size"], hash: entry["hash"]}}
      end
    end
  end

  @doc """
  Return the raw manifest entry (including its blob `ref`) for `path`, or
  `{:error, :not_found}`. Unlike `stat/2` this exposes the ref so callers can
  share a blob body across agents without copying it.
  """
  @spec entry(String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found} | {:error, term()}
  def entry(agent_id, path) do
    with {:ok, state} <- read_state(agent_id) do
      case Map.get(state.vfs, path) do
        nil -> {:error, :not_found}
        entry -> {:ok, entry}
      end
    end
  end

  @doc """
  The audience a file carries, as encoded atoms, or `nil` when it has none
  (`docs/verification.md` §8).

  A file written while the check was on records the join of everything the
  write drew on. `nil` means the question was never asked of this file — it
  predates the check, or was written while the Group was `off` — and a read of
  it is treated as agent-private rather than as public.
  """
  @spec label(String.t(), String.t()) :: [String.t()] | nil
  def label(agent_id, path) do
    case retained(agent_id, path) do
      {:labelled, label} -> label
      _unknown_or_absent -> nil
    end
  end

  @doc """
  What a write to `path` would keep, and whether its audience is known
  (`docs/verification.md` §8).

  `label/2` answers this with two values, and a write needs three. "Nothing is
  retained" and "something is retained whose audience nobody recorded" are
  opposites for a write that keeps what it did not touch: the first is safe to
  ignore, the second is exactly the case the join exists for. Collapsing them
  into `nil` is what let a partial edit of an unlabelled file relabel the
  content it kept.

    * `{:labelled, atoms}` — the file records an audience.
    * `:unlabelled` — the file exists and does not, so what it keeps has to be
      read the way `SalixAgent.IFC.FileLabels` reads it: agent-private.
    * `:absent` — nothing is there to keep. Only a confirmed `:not_found`
      earns this; a store that cannot answer is `:unlabelled`, because a write
      that cannot see what it is overwriting must not assume it is overwriting
      nothing.
  """
  @spec retained(String.t(), String.t()) :: {:labelled, [String.t()]} | :unlabelled | :absent
  def retained(agent_id, path) do
    case entry(agent_id, path) do
      {:ok, %{"ifc_label" => label}} when is_list(label) -> {:labelled, label}
      {:ok, _entry_without_a_usable_label} -> :unlabelled
      {:error, :not_found} -> :absent
      {:error, _unreadable} -> :unlabelled
    end
  end

  @doc "Return the current workspace manifest."
  @spec manifest(String.t()) :: {:ok, map()} | {:error, term()}
  def manifest(agent_id) do
    with {:ok, state} <- read_state(agent_id), do: {:ok, state.vfs}
  end

  @doc """
  Commit workspace events behind an idempotent operation id.

  This low-level persistence entrypoint is only valid from the local AgentActor
  owner process. Callers outside that process must use
  `SalixAgent.AgentActor.commit_workspace_operation/5`, which routes to the
  owner before this function is reached.
  """
  @spec commit_operation(String.t(), String.t(), term(), [map()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def commit_operation(agent_id, operation_id, result, events, opts \\ [])

  def commit_operation(agent_id, operation_id, result, events, opts)
      when is_binary(operation_id) and operation_id != "" and is_list(events) do
    if AgentActor.local_owner_process?(agent_id) do
      do_commit_operation(agent_id, operation_id, result, events, opts, @max_commit_retries)
    else
      {:error, :not_agent_owner}
    end
  end

  def commit_operation(_agent_id, _operation_id, _result, _events, _opts),
    do: {:error, :invalid_operation_id}

  @doc false
  @spec prepare_operation(String.t(), String.t(), term(), [map()], keyword()) ::
          {:ok, {:committed, term()} | {:prepared, PreparedOperation.t()}} | {:error, term()}
  def prepare_operation(agent_id, operation_id, result, events, opts \\ [])

  def prepare_operation(agent_id, operation_id, result, events, opts)
      when is_binary(agent_id) and is_binary(operation_id) and operation_id != "" and
             is_list(events) and is_list(opts) do
    if AgentActor.local_owner_process?(agent_id) do
      with {:ok, state, etag} <- read_state_for_update(agent_id) do
        case Map.fetch(state.operations, operation_id) do
          {:ok, committed} ->
            reconcile_duplicate_writes(committed, state, events)
            {:ok, {:committed, committed["result"]}}

          :error ->
            record = %{
              "operation_id" => operation_id,
              "result" => result,
              "event_count" => length(events),
              "managed_blob_uuids" => managed_write_uuids(events),
              "committed_at" => opts[:committed_at] || System.os_time(:second)
            }

            next_state =
              events
              |> Enum.reduce(state, &apply_workspace_event/2)
              |> put_operation(operation_id, record)

            {:ok,
             {:prepared,
              %PreparedOperation{
                agent_id: agent_id,
                operation_id: operation_id,
                result: result,
                events: events,
                next_state: next_state,
                etag: etag
              }}}
        end
      end
    else
      {:error, :not_agent_owner}
    end
  end

  def prepare_operation(_agent_id, _operation_id, _result, _events, _opts),
    do: {:error, :invalid_operation_id}

  @doc false
  @spec commit_prepared_operation(PreparedOperation.t()) :: {:ok, term()} | {:error, term()}
  def commit_prepared_operation(%PreparedOperation{} = prepared) do
    if AgentActor.local_owner_process?(prepared.agent_id) do
      case write_state(prepared.agent_id, prepared.next_state, prepared.etag) do
        :ok ->
          adopt_committed_writes(prepared.events)
          {:ok, prepared.result}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_agent_owner}
    end
  end

  def commit_prepared_operation(_prepared), do: {:error, :invalid_prepared_workspace_operation}

  @doc false
  @spec seed_operation(String.t(), String.t(), term(), [map()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def seed_operation(agent_id, operation_id, result, events, opts \\ [])

  def seed_operation(agent_id, operation_id, result, events, opts)
      when is_binary(operation_id) and operation_id != "" and is_list(events) do
    do_commit_operation(agent_id, operation_id, result, events, opts, @max_commit_retries)
  end

  def seed_operation(_agent_id, _operation_id, _result, _events, _opts),
    do: {:error, :invalid_operation_id}

  @doc false
  @spec operation_result(String.t(), String.t()) ::
          {:ok, term()} | {:error, :not_found} | {:error, term()}
  def operation_result(agent_id, operation_id)
      when is_binary(operation_id) and operation_id != "" do
    with {:ok, state} <- read_state(agent_id) do
      case Map.get(state.operations, operation_id) do
        %{"result" => result} -> {:ok, result}
        _ -> {:error, :not_found}
      end
    end
  end

  def operation_result(_agent_id, _operation_id), do: {:error, :not_found}

  @doc false
  @spec latest_operation_result_by_prefix(String.t(), String.t()) ::
          {:ok, term()} | {:error, :not_found} | {:error, term()}
  def latest_operation_result_by_prefix(agent_id, prefix)
      when is_binary(prefix) and prefix != "" do
    with {:ok, state} <- read_state(agent_id) do
      state.operations
      |> Enum.filter(fn {operation_id, _record} -> String.starts_with?(operation_id, prefix) end)
      |> Enum.max_by(fn {_operation_id, record} -> record["committed_at"] || 0 end, fn -> nil end)
      |> case do
        {_operation_id, %{"result" => result}} -> {:ok, result}
        nil -> {:error, :not_found}
      end
    end
  end

  def latest_operation_result_by_prefix(_agent_id, _prefix), do: {:error, :not_found}

  @doc false
  # Migration seeding only: overwrite the workspace manifest from a legacy VFS
  # map (the `SalixAgent.Migrations.SplitRuntimeState` data migration). This is
  # not a live runtime path — runtime writes go through `commit_operation/5`.
  @spec prepare_seed(String.t(), map()) :: :ok | {:error, term()}
  def prepare_seed(agent_id, vfs) when is_binary(agent_id) and is_map(vfs) do
    state = normalize_state(agent_id, %State{agent_id: agent_id, vfs: vfs, operations: %{}})
    body = Codec.encode_snapshot(state)

    case S3.put(Keys.agent_workspace_state(agent_id), body, []) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "Read the durable workspace state, returning an empty state when absent."
  @spec read_state(String.t()) :: {:ok, State.t()} | {:error, term()}
  def read_state(agent_id) do
    case read_state_for_update(agent_id) do
      {:ok, state, _etag} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_commit_operation(_agent_id, _operation_id, _result, _events, _opts, 0),
    do: {:error, :stale_workspace}

  defp do_commit_operation(agent_id, operation_id, result, events, opts, retries) do
    with {:ok, state, etag} <- read_state_for_update(agent_id) do
      case Map.fetch(state.operations, operation_id) do
        {:ok, committed} ->
          reconcile_duplicate_writes(committed, state, events)
          {:ok, committed["result"]}

        :error ->
          record = %{
            "operation_id" => operation_id,
            "result" => result,
            "event_count" => length(events),
            "managed_blob_uuids" => managed_write_uuids(events),
            "committed_at" => opts[:committed_at] || System.os_time(:second)
          }

          next_state =
            events
            |> Enum.reduce(state, &apply_workspace_event/2)
            |> put_operation(operation_id, record)

          case write_state(agent_id, next_state, etag) do
            :ok ->
              adopt_committed_writes(events)
              {:ok, result}

            {:error, :precondition_failed} ->
              do_commit_operation(agent_id, operation_id, result, events, opts, retries - 1)

            {:error, _} = err ->
              err
          end
      end
    end
  end

  defp read_state_for_update(agent_id) do
    case S3.get(Keys.agent_workspace_state(agent_id)) do
      {:ok, %{body: body, etag: etag}} ->
        {:ok, normalize_state(agent_id, Codec.decode_snapshot(body)), etag}

      {:error, :not_found} ->
        {:ok, %State{agent_id: agent_id}, nil}

      {:error, _} = err ->
        err
    end
  end

  defp write_state(agent_id, %State{} = state, nil) do
    body = Codec.encode_snapshot(state)

    case S3.put(Keys.agent_workspace_state(agent_id), body, if_none_match: "*") do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp write_state(agent_id, %State{} = state, etag) do
    body = Codec.encode_snapshot(state)

    case S3.put(Keys.agent_workspace_state(agent_id), body, if_match: etag) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp normalize_state(agent_id, %State{} = state) do
    %State{
      state
      | agent_id: state.agent_id || agent_id,
        vfs: state.vfs || %{},
        operations: state.operations || %{}
    }
  end

  defp normalize_state(agent_id, state) when is_map(state) do
    %State{
      agent_id: Map.get(state, :agent_id) || Map.get(state, "agent_id") || agent_id,
      vfs: Map.get(state, :vfs) || Map.get(state, "vfs") || %{},
      operations: Map.get(state, :operations) || Map.get(state, "operations") || %{}
    }
  end

  defp normalize_state(agent_id, _state), do: %State{agent_id: agent_id}

  defp apply_workspace_event(%{"type" => "vfs_write", "path" => path} = ev, %State{} = state) do
    entry = %{"ref" => ev["ref"], "size" => ev["size"], "hash" => ev["hash"]}

    entry =
      case ev["modified_at"] do
        ts when is_integer(ts) -> Map.put(entry, "modified_at", ts)
        _ -> entry
      end

    # What the write drew on, so a later read of this path is no weaker than
    # reading its sources would have been
    # (docs/verification.md). A write made while the
    # check was off carries none, which reads as agent-private.
    entry =
      case ev["ifc_label"] do
        label when is_list(label) -> Map.put(entry, "ifc_label", label)
        _absent -> entry
      end

    %State{state | vfs: Map.put(state.vfs, path, entry)}
  end

  defp apply_workspace_event(%{"type" => "vfs_delete", "path" => path}, %State{} = state) do
    %State{state | vfs: Map.delete(state.vfs, path)}
  end

  defp apply_workspace_event(
         %{"type" => "vfs_copy", "from" => from, "to" => to},
         %State{} = state
       ) do
    case Map.get(state.vfs, from) do
      nil -> state
      entry -> %State{state | vfs: Map.put(state.vfs, to, entry)}
    end
  end

  defp apply_workspace_event(_event, %State{} = state), do: state

  defp put_operation(%State{} = state, operation_id, record) do
    operations =
      state.operations
      |> Map.put(operation_id, record)
      |> prune_operations(System.os_time(:second))

    %State{state | operations: operations}
  end

  @doc false
  # Keep the newest records within the count, byte and age limits. Records
  # younger than the floor are always kept and consume the budgets first, so
  # the eviction order is: floor-protected, then newest first until a limit.
  @spec prune_operations(map(), integer()) :: map()
  def prune_operations(operations, now) when is_map(operations) and is_integer(now) do
    floor_cutoff = now - @operation_floor_seconds
    ttl_cutoff = now - @operation_ttl_seconds

    {protected, candidates} =
      Enum.split_with(operations, fn {_id, record} -> committed_at(record) >= floor_cutoff end)

    protected_bytes =
      Enum.reduce(protected, 0, fn {_id, record}, acc -> acc + record_bytes(record) end)

    kept =
      candidates
      |> Enum.filter(fn {_id, record} -> committed_at(record) >= ttl_cutoff end)
      |> Enum.sort_by(fn {id, record} -> {-committed_at(record), id} end)
      |> take_within_budget(
        @max_operations - length(protected),
        @max_operations_bytes - protected_bytes
      )

    Map.new(protected ++ kept)
  end

  defp take_within_budget(entries, count_budget, byte_budget) do
    entries
    |> Enum.reduce_while({[], count_budget, byte_budget}, fn {_id, record} = entry,
                                                             {acc, count, bytes} ->
      size = record_bytes(record)

      if count >= 1 and bytes >= size do
        {:cont, {[entry | acc], count - 1, bytes - size}}
      else
        {:halt, {acc, count, bytes}}
      end
    end)
    |> elem(0)
  end

  defp committed_at(%{"committed_at" => at}) when is_integer(at), do: at
  defp committed_at(_record), do: 0

  defp record_bytes(record), do: :erlang.external_size(record)

  defp adopt_committed_writes(events) do
    Enum.each(events, fn
      %{
        "type" => "vfs_write",
        "ref" => %{} = ref,
        "prepared_blob_cleanup" => true
      } ->
        case Blob.adopt(ref) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("committed workspace blob cleanup handoff failed: #{inspect(reason)}")
        end

      _event ->
        :ok
    end)

    :ok
  end

  # A concurrent retry can prepare fresh immutable bodies before discovering
  # that the operation already committed. New operation records persist the
  # winning managed UUIDs, so replay remains safe after the path is overwritten
  # or zero-copy shared. Current VFS membership is only a compatibility fallback
  # for records written before managed UUIDs were recorded.
  defp reconcile_duplicate_writes(committed, %State{} = state, events) do
    owned_uuids =
      if Map.has_key?(committed, "managed_blob_uuids") do
        MapSet.new(committed["managed_blob_uuids"] || [])
      else
        state.vfs
        |> Map.values()
        |> Enum.map(fn entry -> get_in(entry, ["ref", "uuid"]) end)
        |> MapSet.new()
      end

    Enum.each(events, fn
      %{
        "type" => "vfs_write",
        "ref" => %{} = ref,
        "prepared_blob_cleanup" => true
      } ->
        cleanup_result =
          if MapSet.member?(owned_uuids, ref["uuid"] || ref[:uuid]) do
            Blob.adopt(ref)
          else
            Blob.discard(ref)
          end

        case cleanup_result do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("duplicate workspace blob cleanup deferred: #{inspect(reason)}")
        end

      _event ->
        :ok
    end)

    :ok
  end

  defp managed_write_uuids(events) do
    events
    |> Enum.flat_map(fn
      %{
        "type" => "vfs_write",
        "ref" => %{} = ref,
        "prepared_blob_cleanup" => true
      } ->
        case ref["uuid"] || ref[:uuid] do
          uuid when is_binary(uuid) -> [uuid]
          _ -> []
        end

      _event ->
        []
    end)
    |> Enum.uniq()
  end

  defp managed_write_ref(path, ref) do
    with {:ok, event} <- prepare_write_ref(path, ref) do
      {:ok, Map.put(event, "prepared_blob_cleanup", true)}
    end
  end

  defp stringify(ref),
    do: %{"kind" => ref.kind, "uuid" => ref.uuid, "size" => ref.size, "hash" => ref.hash}
end
