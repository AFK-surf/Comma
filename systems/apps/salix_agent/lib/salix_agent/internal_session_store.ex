defmodule SalixAgent.InternalSessionStore do
  @moduledoc """
  Durable store for Salix-managed internal runtime sessions.

  A session is addressed by `{agent_id, session_id}` and stored as one CAS
  object. The key uses a hash of the session id for S3 safety, so list loads the
  session state and reads `state.session_id` from the body. The abstract
  mark-before-CAS activation and stable-first cleanup cell is modeled in
  `tla/salix/SessionActivation.tla`; the concrete local-marker → Postgres →
  Session CAS admission and revision retirement are modeled in
  `tla/salix/SessionWorkProjection.tla`. Activity-revision rotation, no-op
  stability, and the rolling old-writer storage-revision fallback are modeled
  in `tla/salix/SessionActivityVersion.tla`.
  """

  require Logger

  alias SalixAgent.{
    InternalSession,
    InternalSessionActor,
    SessionStorageRevision,
    SessionWorkIndex,
    Waits
  }

  alias SalixStore.{ArchiveLog, Codec, Ids, Keys, S3, SealedSegments}
  alias SalixStore.S3.Settle

  @max_commit_retries 64
  @commit_retry_backoff_ms 2
  @commit_retry_backoff_max_ms 20
  @lifecycle_event_types ~w(session_created status activity_status wait_set wait_clear)
  @tool_result_record_fields ~w(
    result_ref
    tool_call_id
    tool_name
    result_json
    result_sha256
    result_bytes
    result_chars
    status
    is_error
    ifc
    stored_at_ms
  )

  @type read_result :: {:ok, InternalSession.t()} | {:error, :not_found} | {:error, term()}

  defmodule Revision do
    @moduledoc """
    An owner-local Session snapshot paired with the exact object generation
    that produced it.

    Revisions are not durable values. The owner can delegate a frozen revision
    to its fenced persistence task. A failed conditional write rejects the
    working candidate and retains the baseline.
    The kernel cursor owns fresh, committed, and pending revisions.
    The other fields are read-only projections of that cursor.
    """

    alias SalixAgent.InternalSession

    @enforce_keys [:cursor, :state, :etag]
    defstruct [:cursor, :state, :etag, :pending]

    @type t :: %__MODULE__{
            cursor: tuple(),
            state: InternalSession.t(),
            etag: String.t() | nil,
            pending: tuple() | nil
          }
  end

  @spec read(String.t(), String.t()) :: read_result()
  def read(agent_id, session_id) when is_binary(agent_id) and is_binary(session_id) do
    case read_for_update(agent_id, session_id) do
      {:ok, state, _etag} -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  @doc false
  @spec read_with_etag(String.t(), String.t()) ::
          {:ok, InternalSession.t(), String.t()} | {:error, :not_found} | {:error, term()}
  def read_with_etag(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id),
      do: read_for_update(agent_id, session_id)

  @doc false
  @spec read_revision(String.t(), String.t()) ::
          {:ok, Revision.t()} | {:error, :not_found} | {:error, term()}
  def read_revision(agent_id, session_id)
      when is_binary(agent_id) and is_binary(session_id) do
    SystemsObservability.Trace.with_span(
      :salix_session_read,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn ->
        with {:ok, cursor} <-
               InternalSession.read_revision(agent_id, session_id, &read_revision_object/2) do
          {:ok, revision_from_cursor(cursor)}
        end
      end
    )
  end

  @doc false
  def read_or_new_revision(agent_id, session_id, attrs \\ %{}) do
    with :ok <- ensure_session_owner(agent_id, session_id) do
      case read_revision(agent_id, session_id) do
        {:error, :not_found} ->
          with :ok <- claim_internal_birth(agent_id, session_id) do
            state = InternalSession.new(agent_id, session_id, attrs)
            {:ok, revision_from_cursor(InternalSession.start_revision(state, nil))}
          end

        other ->
          other
      end
    end
  end

  @doc """
  Tri-state existence probe: `:present`, `:absent` (CONFIRMED not-found), or
  the probe's own error. Session-birth routing must never read a transient
  HEAD failure as absence (#873 round 7: one 503 on the old side after a
  runtime flip re-birthed a pre-marker session in the other store), so the
  error is surfaced for the caller to fail closed on.
  """
  @spec probe(String.t(), String.t()) :: :present | :absent | {:error, term()}
  def probe(agent_id, session_id) do
    if Ids.valid_session_id?(session_id) do
      # Inside a delivery's read scope the facade may have started this
      # probe early; that one observation, a transient error included,
      # answers the whole delivery (#873 round 7: an error is not absence).
      key = Keys.agent_internal_runtime_session(agent_id, session_id)
      {:ok, observation} = SalixStore.ReadScope.fetch({:probe, key}, fn -> probe_key(key) end)
      observation
    else
      :absent
    end
  end

  @doc false
  def probe_key(key) do
    case S3.head(key) do
      {:ok, _} -> {:ok, :present}
      {:error, :not_found} -> {:ok, :absent}
      {:error, reason} -> {:ok, {:error, reason}}
    end
  end

  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(agent_id, session_id), do: probe(agent_id, session_id) == :present

  @spec create(String.t(), String.t(), map(), keyword()) ::
          {:ok, InternalSession.t()} | {:error, term()}
  def create(agent_id, session_id, attrs \\ %{}, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with :ok <- ensure_session_owner(agent_id, session_id) do
      do_create(agent_id, session_id, attrs, opts)
    end
  end

  @doc """
  Create an internal session record before the session is live.

  Runtime code must use `create/4` from the owning `InternalSessionActor`.
  This preparation entrypoint is for agent creation/clone/session-rotation
  setup and tests that need durable fixture state without starting an otherwise
  idle session actor.
  """
  @spec prepare_create(String.t(), String.t(), map(), keyword()) ::
          {:ok, InternalSession.t()} | {:error, term()}
  def prepare_create(agent_id, session_id, attrs \\ %{}, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    do_create(agent_id, session_id, attrs, opts)
  end

  # STORE-LAYER birth authority (#873 round 8): every internal-session
  # CREATION — whichever public function or ingress reached it — claims the
  # per-session birth marker inside the store, immediately before the
  # create-once write. Routing's earlier claim (SessionDelivery) is a
  # same-side re-claim here and answers :ok; a creator racing a lost birth
  # (the marker records :external) is refused with zero session writes —
  # no caller can fabricate an internal session for an externally-born id.
  # The three creating branches below (do_create, do_seed's absent branch,
  # write_state with no base etag) are the ONLY code paths that produce a
  # first PUT of the internal session object; see the creation-point audit
  # in docs/salix/conversation-owner-actor.md clause 2b.
  # Marker ABSENCE is not birth authority for the markerless legacy
  # population (#873 round 9): before claiming, an unmarked id must
  # reconcile the OPPOSITE store with the same tri-state/fail-closed
  # semantics routing uses — a legacy external session found there refuses
  # the internal create (and backfills its truthful marker); a probe error
  # refuses fail-closed. Creation-only cost, never per-delivery.
  defp claim_internal_birth(agent_id, session_id) do
    case SalixAgent.SessionBirth.side(agent_id, session_id) do
      {:ok, :internal} ->
        :ok

      {:ok, :external} ->
        {:error, :session_born_external}

      {:error, :not_found} ->
        case SalixAgent.ExternalSessionStore.probe(agent_id, session_id) do
          :present ->
            _ = SalixAgent.SessionBirth.claim(agent_id, session_id, :external)
            {:error, :session_born_external}

          :absent ->
            case SalixAgent.SessionBirth.claim(agent_id, session_id, :internal) do
              {:ok, :internal} -> :ok
              {:ok, :external} -> {:error, :session_born_external}
              {:error, _} = err -> err
            end

          {:error, reason} ->
            {:error, {:unavailable, {:session_probe, reason}}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp seed_birth_claim(agent_id, session_id, "absent"),
    do: claim_internal_birth(agent_id, session_id)

  defp seed_birth_claim(_agent_id, _session_id, _existing_etag), do: :ok

  defp do_create(agent_id, session_id, attrs, opts) do
    with true <- Ids.valid_session_id?(session_id),
         :ok <- claim_internal_birth(agent_id, session_id),
         {:ok, local_epoch} <- local_runtime_epoch(agent_id, session_id) do
      state =
        agent_id
        |> InternalSession.new(session_id, attrs)
        |> InternalSession.stamp(
          activity_revision: SessionStorageRevision.new(),
          storage_revision: SessionStorageRevision.new()
        )
        |> stamp_runtime_epoch(local_epoch)

      body = encode_state(state)
      key = Keys.agent_internal_runtime_session(agent_id, session_id)

      if opts[:force] do
        force_create_overwrite(agent_id, key, state, local_epoch)
      else
        # Through the shared settlement primitive: an ambiguous-but-landed
        # create is recognized by byte equality (the body is fixed within
        # this invocation) instead of surfacing an error for a session that
        # now durably exists.
        case Settle.create_once(key, body, Settle.byte_settle(body)) do
          :created -> {:ok, state}
          :landed -> {:ok, state}
          {:exists, _} -> {:error, :exists}
          {:error, _} = err -> err
        end
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = err -> err
    end
  end

  # A force-create used to be the one unconditional PUT in this store; an
  # unconditional write can clobber a higher-epoch owner's object, so it is
  # now a read-CAS overwrite that goes through the same runtime-epoch fence
  # as every other write — and, like seeds, an unstamped (absent-cell)
  # overwrite carries the existing object's stamp forward instead of
  # resetting it. No production caller uses force; the option is a
  # test/tooling seam.
  defp force_create_overwrite(agent_id, key, state, local_epoch) do
    session_id = InternalSession.session_id(state)

    case read_with_etag(agent_id, session_id) do
      {:ok, existing, etag} ->
        with {:ok, _local_epoch} <- verify_runtime_epoch(agent_id, session_id, existing) do
          state = preserve_or_stamp_runtime_epoch(state, local_epoch, existing)
          body = encode_state(state)

          case Settle.cas_put(key, body, etag) do
            :ok -> {:ok, state}
            {:error, _} = err -> err
          end
        end

      {:error, :not_found} ->
        body = encode_state(state)

        case Settle.create_once(key, body, Settle.byte_settle(body)) do
          :created -> {:ok, state}
          :landed -> {:ok, state}
          {:exists, _} -> {:error, :stale_internal_session}
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @spec seed(String.t(), InternalSession.t(), keyword()) :: :ok | {:error, term()}
  def seed(agent_id, state, opts \\ []) when is_binary(agent_id) do
    with :ok <- ensure_session_owner(agent_id, InternalSession.session_id(state)) do
      do_seed(agent_id, state, opts)
    end
  end

  @doc """
  Seed an internal session record before the session is live.

  Runtime code must use `seed/3` from the owning `InternalSessionActor`.
  """
  @spec prepare_seed(String.t(), InternalSession.t(), keyword()) :: :ok | {:error, term()}
  def prepare_seed(agent_id, state, opts \\ []) when is_binary(agent_id) do
    do_seed(agent_id, state, opts)
  end

  defp do_seed(agent_id, state, opts) do
    session_id = InternalSession.session_id(state)

    with true <- is_binary(session_id) and Ids.valid_session_id?(session_id),
         {:ok, state} <-
           state |> InternalSession.stamp(agent_id: agent_id) |> InternalSession.prepare_write(),
         :ok <- validate_state_wait(state),
         {:ok, current, put_opts, cas_base} <-
           seed_current_state(agent_id, session_id, opts),
         {:ok, local_epoch} <- verify_runtime_epoch(agent_id, session_id, current),
         # A seed onto an ABSENT session is a creation (fork targets land
         # here) and claims the birth marker like every other creator;
         # overwriting an existing session is not a birth.
         :ok <- seed_birth_claim(agent_id, session_id, cas_base),
         {:ok, state, cleanup} <-
           sync_work_index(agent_id, session_id, current, state,
             cas_base: cas_base,
             base_revision: InternalSession.storage_revision(current)
           ) do
      state =
        current
        |> put_activity_revision(state)
        |> InternalSession.stamp(storage_revision: SessionStorageRevision.new())
        |> preserve_or_stamp_runtime_epoch(local_epoch, current)

      body = encode_state(state)
      key = Keys.agent_internal_runtime_session(agent_id, session_id)

      case seed_write(key, body, put_opts, state) do
        :ok ->
          _ = cleanup_work_index(cleanup)
          :ok

        {:error, :exists} ->
          cleanup_uncommitted_work_index(agent_id, session_id, state)
          reconcile_rejected_seed_local_index(agent_id, session_id, state)
          {:error, :exists}

        {:error, _} = err ->
          err
      end
    else
      false -> {:error, :invalid_session_id}
      {:error, _} = error -> error
    end
  end

  defp validate_state_wait(state) do
    case InternalSession.wait(state) do
      nil -> :ok
      wait -> Waits.validate(wait)
    end
  end

  @spec ensure(String.t(), String.t(), map()) :: {:ok, InternalSession.t()} | {:error, term()}
  def ensure(agent_id, session_id, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    with :ok <- ensure_session_owner(agent_id, session_id) do
      do_ensure(agent_id, session_id, attrs, &create/4)
    end
  end

  @doc """
  Ensure an internal session record before the session is live.

  Runtime code must use `ensure/3` from the owning `InternalSessionActor`.
  """
  @spec prepare_ensure(String.t(), String.t(), map()) ::
          {:ok, InternalSession.t()} | {:error, term()}
  def prepare_ensure(agent_id, session_id, attrs)
      when is_binary(agent_id) and is_binary(session_id) and is_map(attrs) do
    do_ensure(agent_id, session_id, attrs, &prepare_create/4)
  end

  defp do_ensure(agent_id, session_id, attrs, create_fun) do
    case read(agent_id, session_id) do
      {:ok, state} ->
        {:ok, state}

      {:error, :not_found} ->
        case create_fun.(agent_id, session_id, attrs, []) do
          {:ok, state} -> {:ok, state}
          {:error, :exists} -> read(agent_id, session_id)
          {:error, _} = err -> err
        end

      {:error, _} = err ->
        err
    end
  end

  @spec commit(String.t(), String.t(), [map()], keyword()) ::
          {:ok, InternalSession.t()} | {:error, term()}
  def commit(agent_id, session_id, events, opts \\ [])

  def commit(agent_id, session_id, events, opts)
      when is_binary(agent_id) and is_binary(session_id) and is_list(events) do
    with :ok <- ensure_session_owner(agent_id, session_id) do
      do_commit_with_log(agent_id, session_id, events, opts)
    end
  end

  @doc false
  @spec commit_revision(
          String.t(),
          String.t(),
          Revision.t(),
          [map()],
          keyword(),
          (-> :ok | {:error, term()}) | nil
        ) :: {:ok, Revision.t()} | {:error, term()}
  def commit_revision(
        agent_id,
        session_id,
        %Revision{} = revision,
        events,
        opts \\ [],
        prerequisite \\ nil
      )
      when is_binary(agent_id) and is_binary(session_id) and is_list(events) and
             (is_nil(prerequisite) or is_function(prerequisite, 0)) do
    with :ok <- ensure_session_owner(agent_id, session_id) do
      if InternalSession.revision_pending?(revision.cursor) do
        with {:ok, written} <- write_revision(revision, events, opts) do
          durable_fence(agent_id, session_id, written, prerequisite)
        end
      else
        do_commit_revision_with_log(
          agent_id,
          session_id,
          revision,
          events,
          opts,
          prerequisite
        )
      end
    end
  end

  @doc """
  Apply events to the owner's working revision without storage I/O.

  Success is not a durable acknowledgement. The owner must carry this revision
  to `durable_fence/4` before releasing an accepted input or a unique result.
  The durable baseline remains separate from the working state.
  """
  def write_revision(%Revision{} = revision, events, opts \\ []) when is_list(events) do
    SystemsObservability.Trace.with_span(
      :salix_session_apply,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> do_write_revision(revision, events, opts) end
    )
  end

  defp do_write_revision(%Revision{} = revision, events, opts) when is_list(events) do
    events = events |> Enum.map(&SalixAgent.Utf8.scrub_term/1) |> timestamp_lifecycle_events()

    with :ok <- SalixAgent.InternalSession.State.validate_events(events) do
      cursor = InternalSession.write_revision(revision.cursor, events, opts[:hwm])
      {:ok, revision_from_cursor(cursor)}
    end
  end

  @doc false
  def revision_baseline(%Revision{cursor: cursor}) do
    cursor |> InternalSession.revision_baseline() |> revision_from_cursor()
  end

  @doc false
  def plan_revision(%Revision{cursor: cursor}, mode) do
    {planned, outcome, changed} = InternalSession.plan_revision(cursor, mode)
    {revision_from_cursor(planned), outcome, changed}
  end

  defp revision_from_cursor(cursor) do
    {state, etag, pending?} = InternalSession.revision_view(cursor)
    %Revision{cursor: cursor, state: state, etag: etag, pending: if(pending?, do: cursor)}
  end

  @doc false
  def command_revision(input),
    do: input |> InternalSession.command_revision() |> revision_from_cursor()

  @doc false
  def write_command(input, events) do
    SystemsObservability.Trace.with_span(
      :salix_session_apply,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn ->
        result = SalixAgent.InternalSession.State.validate_events(events)
        InternalSession.command_step(input, :write_result, result)
      end
    )
  end

  @doc false
  def fence_command(agent_id, session_id, input, prerequisite \\ nil) do
    revision = command_revision(input)

    with :ok <- ensure_session_owner(agent_id, session_id) do
      if InternalSession.revision_pending?(revision.cursor) or not is_nil(prerequisite) do
        {baseline, events, hwm, _pending} = pending_fence(revision)

        do_commit_revision_with_log(
          agent_id,
          session_id,
          baseline,
          events,
          [hwm: hwm, on_conflict: :error],
          prerequisite,
          input
        )
      else
        with :ok <-
               validate_revision_identity(agent_id, session_id, revision.state, revision.etag),
             {:ok, _epoch} <- verify_runtime_epoch(agent_id, session_id, revision.state) do
          {confirmed, {:committed}} = InternalSession.command_step(input, :fence_clean, nil)
          {:ok, confirmed}
        end
      end
    end
  end

  defp committed_cursor({:verified_kernel, 1, :session_revision, _} = cursor),
    do: revision_from_cursor(cursor)

  defp committed_cursor({:verified_kernel, 1, :command_driver, _} = cursor), do: cursor

  defp pending_fence(%Revision{cursor: cursor} = revision) do
    if InternalSession.revision_pending?(cursor) do
      {events, hwm} = InternalSession.revision_metadata(cursor)
      {revision_baseline(revision), events, hwm, cursor}
    else
      {revision_from_cursor(cursor), [], nil, nil}
    end
  end

  @doc """
  Persist all pending writes through the existing fenced snapshot CAS.

  No recovery record is acknowledged before its data is durable. A conflict
  fails closed: pending events were planned against the saved baseline and
  must not be silently re-planned against another owner's state.
  """
  def durable_fence(agent_id, session_id, revision, prerequisite \\ nil)

  def durable_fence(agent_id, session_id, %Revision{} = revision, prerequisite) do
    revision = revision_from_cursor(revision.cursor)

    if not InternalSession.revision_pending?(revision.cursor) and is_nil(prerequisite) do
      with :ok <- ensure_session_owner(agent_id, session_id),
           :ok <- validate_revision_identity(agent_id, session_id, revision.state, revision.etag),
           {:ok, _epoch} <- verify_runtime_epoch(agent_id, session_id, revision.state),
           do: {:ok, revision}
    else
      {baseline, events, hwm, pending} = pending_fence(revision)

      with :ok <- ensure_session_owner(agent_id, session_id) do
        do_commit_revision_with_log(
          agent_id,
          session_id,
          baseline,
          events,
          [hwm: hwm, on_conflict: :error],
          prerequisite,
          pending
        )
      end
    end
  end

  @doc """
  Start persistence of a fixed working revision in a task.

  The optional prerequisite runs in the owner before this function returns.

  The owner can compute from `revision.state` while this task runs. It must join
  the task before another storage write or an effect that requires this state.
  The task retains the complete snapshot input, not only a durability marker.
  """
  def start_durable_fence(agent_id, session_id, %Revision{} = revision, prerequisite \\ nil) do
    start_frozen_fence(agent_id, session_id, revision, prerequisite, nil)
  end

  @doc false
  def start_command_fence(agent_id, session_id, command, prerequisite \\ nil) do
    start_frozen_fence(agent_id, session_id, command_revision(command), prerequisite, command)
  end

  defp start_frozen_fence(agent_id, session_id, revision, prerequisite, command) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         {:ok, epoch} <- local_runtime_epoch(agent_id, session_id) do
      {baseline, events, hwm, pending} = pending_fence(revision)
      observability_context = SystemsObservability.Context.capture()
      prerequisite_ref = make_ref()
      owner = self()

      delegated_prerequisite =
        if prerequisite do
          fn ->
            receive do
              {:fence_prerequisite, ^prerequisite_ref, result} -> result
            end
          end
        end

      task =
        Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
          # Delegate the owner's frozen epoch, never the worker's ambient cell.
          Process.put({__MODULE__, :fence_epoch}, {agent_id, session_id, epoch, owner})

          SystemsObservability.Context.run(observability_context, fn ->
            do_commit_revision_with_log(
              agent_id,
              session_id,
              baseline,
              events,
              [hwm: hwm, on_conflict: :error],
              delegated_prerequisite,
              command || pending
            )
          end)
        end)

      # Workspace prerequisites still execute at their Session-owner seam.
      # Their I/O overlaps the marker task. Provider preparation follows them.
      # Mutation-free Session results have no workspace prerequisite.
      if prerequisite do
        result = run_commit_prerequisite(prerequisite)
        send(task.pid, {:fence_prerequisite, prerequisite_ref, result})
      end

      {:ok, task}
    end
  end

  @doc """
  Join a persistence task. A failure does not authorize discarding its input.
  """
  def await_durable_fence(%Task{} = task) do
    SystemsObservability.Trace.with_span(
      :salix_session_fence_wait,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> do_await_durable_fence(task) end
    )
  end

  defp do_await_durable_fence(%Task{} = task) do
    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:durable_fence_failed, reason}}
    end
  end

  @doc """
  `commit_dynamic/4` against a resident revision: the builder plans its events
  from the revision's state instead of a fresh read. A CAS conflict re-reads
  once and re-runs the builder on the newer state, exactly as `commit_dynamic`
  would have observed it.
  """
  @spec commit_revision_dynamic(
          String.t(),
          String.t(),
          Revision.t(),
          (InternalSession.t() -> term()),
          keyword()
        ) :: {:ok, Revision.t(), term()} | {:error, term()}
  def commit_revision_dynamic(agent_id, session_id, %Revision{} = revision, builder, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and is_function(builder, 1) do
    revision = revision_from_cursor(revision.cursor)

    with :ok <- ensure_session_owner(agent_id, session_id) do
      started = System.monotonic_time(:millisecond)

      result =
        if InternalSession.revision_pending?(revision.cursor) do
          with {:ok, events, commit_opts, meta} <-
                 normalize_dynamic_commit(builder.(revision.state)),
               commit_opts = Keyword.merge(opts, commit_opts),
               {:ok, committed} <-
                 commit_revision(agent_id, session_id, revision, events, commit_opts) do
            {:ok, committed, dynamic_commit_meta(meta, events, commit_opts)}
          end
        else
          do_commit_revision_dynamic(
            agent_id,
            session_id,
            revision,
            builder,
            opts,
            @max_commit_retries
          )
        end

      CommaLog.log("store_commit", %{
        agent_id: agent_id,
        session_id: session_id,
        event_count: dynamic_result_event_count(result),
        event_types: dynamic_result_event_types(result),
        hwm: dynamic_result_hwm(result),
        duration_ms: System.monotonic_time(:millisecond) - started,
        result: result_label(result)
      })

      result
    end
  end

  @spec commit_dynamic(String.t(), String.t(), (InternalSession.t() -> term()), keyword()) ::
          {:ok, InternalSession.t(), term()} | {:error, term()}
  def commit_dynamic(agent_id, session_id, builder, opts \\ [])

  def commit_dynamic(agent_id, session_id, builder, opts)
      when is_binary(agent_id) and is_binary(session_id) and is_function(builder, 1) do
    with :ok <- ensure_session_owner(agent_id, session_id) do
      do_commit_dynamic_with_log(agent_id, session_id, builder, opts)
    end
  end

  @doc """
  Commit fixture or create-time preparation events without a live session actor.

  Runtime mutation must use `commit/4` from the owning `InternalSessionActor`.
  """
  @spec prepare_commit(String.t(), String.t(), [map()], keyword()) ::
          {:ok, InternalSession.t()} | {:error, term()}
  def prepare_commit(agent_id, session_id, events, opts \\ [])

  def prepare_commit(agent_id, session_id, events, opts)
      when is_binary(agent_id) and is_binary(session_id) and is_list(events) do
    do_commit_with_log(agent_id, session_id, events, opts)
  end

  # Both commit paths scrub event text before applying: session state persists
  # as an ETF snapshot, which round-trips invalid UTF-8 that Jason later
  # rejects — an unscrubbed byte here surfaces only when the next LLM request
  # fails to encode, and by then it is durable and wedges the session.
  defp do_commit_with_log(agent_id, session_id, events, opts) do
    started = System.monotonic_time(:millisecond)
    events = events |> Enum.map(&SalixAgent.Utf8.scrub_term/1) |> timestamp_lifecycle_events()
    result = do_commit(agent_id, session_id, events, opts, @max_commit_retries)

    CommaLog.log("store_commit", %{
      agent_id: agent_id,
      session_id: session_id,
      event_count: length(events),
      event_types: Enum.map(events, &(&1["type"] || &1[:type])),
      hwm: opts[:hwm],
      duration_ms: System.monotonic_time(:millisecond) - started,
      result: result_label(result)
    })

    result
  end

  defp do_commit_dynamic_with_log(agent_id, session_id, builder, opts) do
    started = System.monotonic_time(:millisecond)
    result = do_commit_dynamic(agent_id, session_id, builder, opts, @max_commit_retries)

    CommaLog.log("store_commit", %{
      agent_id: agent_id,
      session_id: session_id,
      event_count: dynamic_result_event_count(result),
      event_types: dynamic_result_event_types(result),
      hwm: dynamic_result_hwm(result),
      duration_ms: System.monotonic_time(:millisecond) - started,
      result: result_label(result)
    })

    result
  end

  defp do_commit_revision_with_log(
         agent_id,
         session_id,
         revision,
         events,
         opts,
         prerequisite,
         prepared_pending \\ nil
       ) do
    started = System.monotonic_time(:millisecond)
    events = events |> Enum.map(&SalixAgent.Utf8.scrub_term/1) |> timestamp_lifecycle_events()

    result =
      do_commit_revision(
        agent_id,
        session_id,
        revision,
        events,
        opts,
        prerequisite,
        @max_commit_retries,
        prepared_pending
      )

    CommaLog.log("store_commit", %{
      agent_id: agent_id,
      session_id: session_id,
      event_count: length(events),
      event_types: Enum.map(events, &(&1["type"] || &1[:type])),
      hwm: opts[:hwm],
      duration_ms: System.monotonic_time(:millisecond) - started,
      result: result_label(result)
    })

    result
  end

  defp ensure_session_owner(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
      [{pid, _}] when pid == self() -> :ok
      _ -> {:error, :not_session_owner}
    end
  end

  # ---- runtime ownership fence ----
  #
  # Modeled in tla/salix/SessionEpochFence.tla; changes here must move the spec.
  # The session object carries the agent-root epoch of its last committing
  # owner. Every write path checks the freshly read state against the
  # node-local ownership cell (zero I/O) and stamps the local epoch into the
  # same CAS it already performs — check and stamp travel in one conditional
  # PUT, so a superseded writer can never land after the new owner's first
  # write, and it receives a terminal :fenced instead of rebasing.
  #
  # Compatibility escapes, both deliberate:
  #   * An absent cell (agent never claimed on this node: tests, migrations,
  #     prepare_* seams) stays unfenced and PRESERVES the durable stamp
  #     rather than resetting it.
  #   * A :fenced cell only refuses while this node still has live runtime
  #     for the agent; once the abort has drained it, prepare_*-style
  #     entrypoints on this node degrade to legacy (absent) behavior instead
  #     of failing forever for an agent that simply lives elsewhere now.
  #   * `:session_fence_enforce` (default true) is an operational
  #     kill-switch: off, an epoch regression logs `session_fence_would_fence`
  #     and proceeds legacy-style (preserving the durable stamp). Note the
  #     regression check itself cannot false-positive — only a genuinely
  #     newer root claim ever stamps a higher epoch — but during a
  #     mixed-version deploy an OLD node's read-modify-write strips the field
  #     entirely (its State struct drops unknown keys), so the fence is only
  #     fully effective once the fleet is uniformly on this code. See the
  #     design doc's deployment section.

  defp fence_enforced?,
    do: Application.get_env(:salix_agent, :session_fence_enforce, true)

  # Which epoch does this writer run under? Resolution order:
  #
  #   1. The registered session actor's own FROZEN epoch (its Registry
  #      value, set at actor start). Immutable per actor, so a later
  #      re-claim on the same node can never launder a stale in-flight
  #      actor's write as the new epoch's: the old actor keeps admitting
  #      and stamping at the epoch its work started under, and the durable
  #      comparison fences it the moment a newer owner has stamped.
  #   2. An actor not yet frozen (its start raced the root Server's claim)
  #      freezes the cell's current claim at this first commit — immutable
  #      from here on.
  #   3. Non-actor seams (prepare_*/seed/tooling) fall back to the
  #      node-wide cell, as before.
  defp local_runtime_epoch(agent_id, session_id) do
    case Process.get({__MODULE__, :fence_epoch}) do
      {^agent_id, ^session_id, epoch, _owner} -> actor_epoch_with_fence(agent_id, epoch)
      _ -> resolve_local_runtime_epoch(agent_id, session_id)
    end
  end

  defp resolve_local_runtime_epoch(agent_id, session_id) do
    key = InternalSessionActor.key(agent_id, session_id)

    case Registry.lookup(SalixAgent.Registry, key) do
      [{pid, %{runtime_epoch: captured}}] when pid == self() and is_integer(captured) ->
        actor_epoch_with_fence(agent_id, captured)

      [{pid, _}] when pid == self() ->
        # First ownership resolution for this actor: bind its immutable
        # generation NOW, before its first durable write, to whatever is
        # visible — including "nothing". An absent cell pins the actor as
        # LEGACY (epoch 0) permanently: its work started outside any claim,
        # so it must never later adopt a newer claim's epoch and launder a
        # stale result past the fence. Any stamped durable object (> 0)
        # then fences it.
        frozen =
          case SalixAgent.OwnershipCell.fetch(agent_id) do
            {:ok, epoch} ->
              epoch

            :fenced ->
              if fence_enforced?(), do: :fenced, else: 0

            :absent ->
              0
          end

        case frozen do
          :fenced ->
            {:error, :fenced}

          frozen when is_integer(frozen) ->
            _ =
              Registry.update_value(SalixAgent.Registry, key, fn _ ->
                %{runtime_epoch: frozen}
              end)

            actor_epoch_with_fence(agent_id, frozen)
        end

      _ ->
        cell_runtime_epoch(agent_id)
    end
  end

  # A fence recorded at or above the actor's own epoch supersedes it; a
  # fence BELOW it is stale evidence about an earlier claim and is ignored.
  defp actor_epoch_with_fence(agent_id, captured) do
    case SalixAgent.OwnershipCell.entry(agent_id) do
      {:ok, fenced_epoch, :fenced} when fenced_epoch >= captured ->
        if fence_enforced?(), do: {:error, :fenced}, else: {:ok, captured}

      _ ->
        {:ok, captured}
    end
  end

  defp cell_runtime_epoch(agent_id) do
    case SalixAgent.OwnershipCell.fetch(agent_id) do
      {:ok, epoch} ->
        {:ok, epoch}

      :fenced ->
        cond do
          not SalixAgent.Fleet.running?(agent_id) -> {:ok, nil}
          fence_enforced?() -> {:error, :fenced}
          true -> {:ok, nil}
        end

      :absent ->
        {:ok, nil}
    end
  end

  defp verify_runtime_epoch(agent_id, session_id, state) do
    with {:ok, local_epoch} <- local_runtime_epoch(agent_id, session_id) do
      durable_epoch = InternalSession.get(state, :runtime_epoch) || 0

      cond do
        not (is_integer(local_epoch) and durable_epoch > local_epoch) ->
          {:ok, local_epoch}

        fence_enforced?() ->
          fence_local_runtime(agent_id, durable_epoch)
          {:error, :fenced}

        true ->
          CommaLog.log("session_fence_would_fence", %{
            agent_id: agent_id,
            session_id: InternalSession.session_id(state),
            durable_epoch: durable_epoch,
            local_epoch: local_epoch
          })

          # Legacy-style proceed; a nil epoch stamps nothing, so the newer
          # durable stamp is preserved rather than regressed.
          {:ok, nil}
      end
    end
  end

  defp stamp_runtime_epoch(state, nil), do: state

  defp stamp_runtime_epoch(state, epoch) when is_integer(epoch),
    do: InternalSession.stamp(state, runtime_epoch: epoch, runtime_node: to_string(node()))

  # Seed/create bodies are built fresh, so an unstamped (absent-cell) writer
  # must carry the overwritten object's stamp forward instead of resetting a
  # higher-epoch owner's fence to 0 (migration imports run exactly this way).
  defp preserve_or_stamp_runtime_epoch(state, nil, current) do
    InternalSession.stamp(state,
      runtime_epoch:
        max(
          InternalSession.get(state, :runtime_epoch) || 0,
          InternalSession.get(current, :runtime_epoch) || 0
        ),
      runtime_node: InternalSession.get(current, :runtime_node)
    )
  end

  defp preserve_or_stamp_runtime_epoch(state, epoch, _current),
    do: stamp_runtime_epoch(state, epoch)

  # A higher epoch in the durable session object is proof of takeover: fence
  # the local cell synchronously (new LLM/tool dispatches refuse at once) and
  # abort the rest of this agent's local runtime asynchronously — the caller
  # is one of the session actors the abort stops. The abort is spawned once
  # per discovery (a cell already fenced means one is in flight or done) and
  # under the core task supervisor, never as a bare unsupervised process.
  defp fence_local_runtime(agent_id, observed_epoch) do
    already_fenced = SalixAgent.OwnershipCell.fetch(agent_id) == :fenced
    _ = SalixAgent.OwnershipCell.fence(agent_id, observed_epoch)

    unless already_fenced do
      _ =
        Task.Supervisor.start_child(SalixAgent.TaskSup, fn ->
          SalixAgent.Fleet.abort_agent_runtime(agent_id, observed_epoch, :session_epoch_fenced)
        end)
    end

    :ok
  end

  @spec list(String.t()) :: {:ok, [InternalSession.t()]} | {:error, term()}
  @doc """
  Early-stoppable fold over the agent's sessions: one LIST, then one state
  GET per session UNTIL the reducer halts — the bounded alternative to
  `list/1` for consumers (message search) whose `limit` must bound S3 work.
  Backup objects are excluded.
  """
  @spec reduce_sessions(String.t(), acc, (InternalSession.t(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce_sessions(agent_id, acc, fun) when is_binary(agent_id) and is_function(fun, 2) do
    prefix = Keys.agent_internal_runtime_sessions_prefix(agent_id)

    with {:ok, objects} <- S3.list_all(prefix) do
      objects
      |> Enum.filter(
        &(String.ends_with?(&1.key, "/state.etf.zst") and
            not String.contains?(&1.key, "/backup/"))
      )
      |> Enum.reduce_while({:ok, acc}, fn object, {:ok, acc} ->
        case load_key(agent_id, object.key) do
          {:ok, state} ->
            case fun.(state, acc) do
              {:cont, acc} -> {:cont, {:ok, acc}}
              {:halt, acc} -> {:halt, {:ok, acc}}
            end

          {:error, reason} ->
            {:halt, {:error, {:session_load_failed, object.key, reason}}}
        end
      end)
    end
  end

  @doc """
  Page-bounded, early-stoppable fold over internal sessions.

  The boolean result is true only when the object prefix was exhausted. A
  reducer halt or a page/object budget returns false so callers can report an
  honest lower bound without first materializing the full prefix.
  """
  @spec reduce_sessions_bounded(
          String.t(),
          acc,
          (InternalSession.t(), acc -> {:cont, acc} | {:halt, acc}),
          keyword()
        ) :: {:ok, acc, boolean()} | {:error, term()}
        when acc: term()
  def reduce_sessions_bounded(agent_id, acc, fun, opts \\ [])
      when is_binary(agent_id) and is_function(fun, 2) do
    page_size = Keyword.get(opts, :page_size, 100)
    max_objects = Keyword.get(opts, :max_objects, 1_000)
    max_pages = Keyword.get(opts, :max_pages, 10)

    if page_size in 1..1_000 and max_objects > 0 and max_pages > 0 do
      prefix = Keys.agent_internal_runtime_sessions_prefix(agent_id)

      reduce_session_pages(
        agent_id,
        prefix,
        nil,
        acc,
        fun,
        page_size,
        max_objects,
        max_pages,
        0,
        0
      )
    else
      {:error, :invalid_scan_budget}
    end
  end

  defp reduce_session_pages(
         _agent_id,
         _prefix,
         _token,
         acc,
         _fun,
         _page_size,
         max_objects,
         max_pages,
         objects_seen,
         pages_seen
       )
       when objects_seen >= max_objects or pages_seen >= max_pages,
       do: {:ok, acc, false}

  defp reduce_session_pages(
         agent_id,
         prefix,
         token,
         acc,
         fun,
         page_size,
         max_objects,
         max_pages,
         objects_seen,
         pages_seen
       ) do
    remaining = max_objects - objects_seen
    list_opts = [max_keys: min(page_size, remaining)]
    list_opts = if token, do: Keyword.put(list_opts, :continuation_token, token), else: list_opts

    case S3.list(prefix, list_opts) do
      {:ok, %{objects: objects, next: next}} ->
        case reduce_session_objects(agent_id, objects, acc, fun) do
          {:halt, acc} ->
            {:ok, acc, false}

          {:cont, acc} ->
            objects_seen = objects_seen + length(objects)
            pages_seen = pages_seen + 1

            cond do
              is_nil(next) ->
                {:ok, acc, true}

              objects_seen >= max_objects or pages_seen >= max_pages ->
                {:ok, acc, false}

              true ->
                reduce_session_pages(
                  agent_id,
                  prefix,
                  next,
                  acc,
                  fun,
                  page_size,
                  max_objects,
                  max_pages,
                  objects_seen,
                  pages_seen
                )
            end

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp reduce_session_objects(agent_id, objects, acc, fun) do
    objects
    |> Enum.filter(
      &(String.ends_with?(&1.key, "/state.etf.zst") and
          not String.contains?(&1.key, "/backup/"))
    )
    |> Enum.reduce_while({:cont, acc}, fn object, {:cont, acc} ->
      case load_key(agent_id, object.key) do
        {:ok, state} ->
          case fun.(state, acc) do
            {:cont, acc} -> {:cont, {:cont, acc}}
            {:halt, acc} -> {:halt, {:halt, acc}}
          end

        {:error, reason} ->
          {:halt, {:error, {:session_load_failed, object.key, reason}}}
      end
    end)
  end

  def list(agent_id) when is_binary(agent_id) do
    prefix = Keys.agent_internal_runtime_sessions_prefix(agent_id)

    with {:ok, objects} <- S3.list_all(prefix) do
      objects
      |> Enum.filter(&String.ends_with?(&1.key, "/state.etf.zst"))
      |> Enum.reduce_while({:ok, []}, fn object, {:ok, acc} ->
        case load_key(agent_id, object.key) do
          {:ok, state} -> {:cont, {:ok, [state | acc]}}
          {:error, reason} -> {:halt, {:error, {:session_load_failed, object.key, reason}}}
        end
      end)
      |> case do
        {:ok, sessions} -> {:ok, Enum.reverse(sessions)}
        {:error, _} = err -> err
      end
    end
  end

  defp do_commit_revision(
         agent_id,
         session_id,
         revision,
         events,
         opts,
         prerequisite,
         retries,
         prepared_pending \\ nil
       )

  defp do_commit_revision(
         _agent_id,
         _session_id,
         _revision,
         _events,
         _opts,
         _prerequisite,
         0,
         _prepared_pending
       ),
       do: {:error, :stale_internal_session}

  defp do_commit_revision(
         agent_id,
         session_id,
         %Revision{cursor: cursor},
         events,
         opts,
         prerequisite,
         retries,
         prepared_pending
       ) do
    {state, etag, _pending?} = InternalSession.revision_view(cursor)

    with :ok <- validate_revision_base(agent_id, session_id, cursor),
         :ok <- SalixAgent.InternalSession.State.validate_events(events),
         :ok <- validate_tool_result_event_sessions(events, session_id),
         {:ok, local_epoch} <- verify_runtime_epoch(agent_id, session_id, state),
         :ok <- validate_tool_result_ref_idempotency(agent_id, session_id, state, events),
         {:ok, fence, next_state} <-
           prepare_fenced_write(agent_id, session_id, cursor, events, opts, prepared_pending) do
      case join_revision_prerequisites(
             agent_id,
             session_id,
             state,
             next_state,
             etag,
             prerequisite
           ) do
        {:ok, work_index, cleanup} ->
          metadata =
            {work_index.work_index_token, work_index.work_index_reasons,
             activity_revision_value(state, next_state), SessionStorageRevision.new(),
             SessionStorageRevision.new(), local_epoch, to_string(node())}

          fence = InternalSession.stamp_revision_fence(fence, metadata)

          case write_fenced_state(agent_id, session_id, fence) do
            {:ok, committed_cursor} ->
              _ = cleanup_work_index(cleanup)
              {:ok, committed_cursor(committed_cursor)}

            {:error, uncommitted, :precondition_failed} ->
              cleanup_uncommitted_work_index(agent_id, session_id, uncommitted)

              if Keyword.get(opts, :on_conflict, :retry) == :error do
                {:error, :precondition_failed}
              else
                sleep_commit_retry(retries)

                with {:ok, fresh} <- read_revision(agent_id, session_id),
                     :ok <- revision_coordinates_unchanged(state, fresh.state) do
                  do_commit_revision(
                    agent_id,
                    session_id,
                    fresh,
                    events,
                    opts,
                    nil,
                    retries - 1
                  )
                end
              end

            {:error, _uncommitted, reason} ->
              {:error, reason}
          end

        {:error, work_index, reason} when is_map(work_index) ->
          uncommitted = InternalSession.stamp(next_state, work_index)
          cleanup_uncommitted_work_index(agent_id, session_id, uncommitted)
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_commit_revision_dynamic(_agent_id, _session_id, _revision, _builder, _opts, 0),
    do: {:error, :stale_internal_session}

  defp do_commit_revision_dynamic(
         agent_id,
         session_id,
         %Revision{state: state} = revision,
         builder,
         opts,
         retries
       ) do
    with {:ok, events, commit_opts, meta} <- normalize_dynamic_commit(builder.(state)) do
      commit_opts = Keyword.merge(opts, commit_opts)
      meta = dynamic_commit_meta(meta, events, commit_opts)
      events = events |> Enum.map(&SalixAgent.Utf8.scrub_term/1) |> timestamp_lifecycle_events()

      result =
        with {:ok, written} <- write_revision(revision, events, commit_opts) do
          durable_fence(agent_id, session_id, written)
        end

      case result do
        {:ok, committed} ->
          {:ok, committed, meta}

        {:error, :precondition_failed} ->
          sleep_commit_retry(retries)

          with {:ok, fresh} <- read_revision(agent_id, session_id),
               :ok <- revision_coordinates_unchanged(state, fresh.state) do
            do_commit_revision_dynamic(agent_id, session_id, fresh, builder, opts, retries - 1)
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp do_commit(_agent_id, _session_id, _events, _opts, 0),
    do: {:error, :stale_internal_session}

  defp do_commit(agent_id, session_id, events, opts, retries) do
    with :ok <- SalixAgent.InternalSession.State.validate_events(events),
         :ok <- validate_tool_result_event_sessions(events, session_id),
         {:ok, state, etag} <- read_or_new_for_update(agent_id, session_id, opts),
         {:ok, local_epoch} <- verify_runtime_epoch(agent_id, session_id, state),
         :ok <- validate_tool_result_ref_idempotency(agent_id, session_id, state, events),
         {:ok, next_state} <- prepare_write(state, events, opts) do
      with {:ok, next_state, cleanup} <-
             sync_work_index(agent_id, session_id, state, next_state,
               cas_base: etag || "absent",
               base_revision: InternalSession.storage_revision(state)
             ) do
        next_state =
          state
          |> put_activity_revision(next_state)
          |> InternalSession.stamp(
            storage_revision: SessionStorageRevision.new(),
            flush_id: SessionStorageRevision.new()
          )
          |> stamp_runtime_epoch(local_epoch)

        case write_state(agent_id, session_id, next_state, etag) do
          :ok ->
            _ = cleanup_work_index(cleanup)
            {:ok, next_state}

          {:error, :precondition_failed} ->
            cleanup_uncommitted_work_index(agent_id, session_id, next_state)
            sleep_commit_retry(retries)
            do_commit(agent_id, session_id, events, opts, retries - 1)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp validate_revision_identity(agent_id, session_id, state, etag)
       when is_binary(etag) and etag != "" do
    if InternalSession.agent_id(state) == agent_id and
         InternalSession.session_id(state) == session_id,
       do: :ok,
       else: {:error, :revision_identity_mismatch}
  end

  defp validate_revision_identity(_agent_id, _session_id, _state, _etag),
    do: {:error, :invalid_session_revision}

  defp validate_revision_base(agent_id, session_id, cursor) do
    {state, etag, pending?} = InternalSession.revision_view(cursor)

    if is_nil(etag) and pending? do
      if InternalSession.agent_id(state) == agent_id and
           InternalSession.session_id(state) == session_id,
         do: claim_internal_birth(agent_id, session_id),
         else: {:error, :revision_identity_mismatch}
    else
      validate_revision_identity(agent_id, session_id, state, etag)
    end
  end

  defp join_revision_prerequisites(agent_id, session_id, current, next_state, etag, prerequisite) do
    SystemsObservability.Trace.with_span(
      :salix_session_prerequisites,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn ->
        do_join_revision_prerequisites(
          agent_id,
          session_id,
          current,
          next_state,
          etag,
          prerequisite
        )
      end
    )
  end

  defp do_join_revision_prerequisites(
         agent_id,
         session_id,
         current,
         next_state,
         etag,
         prerequisite
       ) do
    marker = fn ->
      sync_work_index_fields(agent_id, session_id, current, next_state,
        cas_base: etag || "absent",
        base_revision: InternalSession.storage_revision(current)
      )
    end

    case prerequisite do
      nil ->
        case marker.() do
          {:ok, marked, cleanup} -> {:ok, marked, cleanup}
          {:error, reason} -> {:error, reason}
        end

      fun when is_function(fun, 0) ->
        observability_context = SystemsObservability.Context.capture()

        task =
          Task.Supervisor.async_nolink(SalixAgent.TaskSup, fn ->
            SystemsObservability.Context.run(observability_context, marker)
          end)

        prerequisite_result = run_commit_prerequisite(fun)
        marker_result = await_commit_prerequisite(task)

        case {prerequisite_result, marker_result} do
          {:ok, {:ok, marked, cleanup}} ->
            {:ok, marked, cleanup}

          {{:error, reason}, {:ok, marked, _cleanup}} ->
            {:error, marked, reason}

          {:ok, {:error, reason}} ->
            {:error, reason}

          {{:error, reason}, {:error, _marker_reason}} ->
            {:error, reason}
        end
    end
  end

  defp run_commit_prerequisite(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _value} -> :ok
      {:error, _} = error -> error
      other -> {:error, {:invalid_commit_prerequisite_result, other}}
    end
  catch
    kind, reason -> {:error, {:commit_prerequisite_failed, kind, reason}}
  end

  defp await_commit_prerequisite(task) do
    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:work_index_task_failed, reason}}
      nil -> {:error, :work_index_task_timeout}
    end
  end

  defp do_commit_dynamic(_agent_id, _session_id, _builder, _opts, 0),
    do: {:error, :stale_internal_session}

  defp do_commit_dynamic(agent_id, session_id, builder, opts, retries) do
    with {:ok, state, etag} <- read_or_new_for_update(agent_id, session_id, opts),
         {:ok, local_epoch} <- verify_runtime_epoch(agent_id, session_id, state),
         {:ok, events, commit_opts, meta} <- normalize_dynamic_commit(builder.(state)),
         events <- Enum.map(events, &SalixAgent.Utf8.scrub_term/1),
         events <- timestamp_lifecycle_events(events),
         :ok <- SalixAgent.InternalSession.State.validate_events(events),
         :ok <- validate_tool_result_event_sessions(events, session_id),
         :ok <- validate_tool_result_ref_idempotency(agent_id, session_id, state, events) do
      commit_opts = Keyword.merge(opts, commit_opts)
      meta = dynamic_commit_meta(meta, events, commit_opts)

      with {:ok, next_state} <- prepare_write(state, events, commit_opts),
           {:ok, next_state, cleanup} <-
             sync_work_index(agent_id, session_id, state, next_state,
               cas_base: etag || "absent",
               base_revision: InternalSession.storage_revision(state)
             ) do
        next_state =
          state
          |> put_activity_revision(next_state)
          |> InternalSession.stamp(
            storage_revision: SessionStorageRevision.new(),
            flush_id: SessionStorageRevision.new()
          )
          |> stamp_runtime_epoch(local_epoch)

        case write_state(agent_id, session_id, next_state, etag) do
          :ok ->
            _ = cleanup_work_index(cleanup)
            {:ok, next_state, meta}

          {:error, :precondition_failed} ->
            cleanup_uncommitted_work_index(agent_id, session_id, next_state)
            sleep_commit_retry(retries)
            do_commit_dynamic(agent_id, session_id, builder, opts, retries - 1)

          {:error, _} = err ->
            err
        end
      end
    end
  end

  # Legacy session events keep their historical mismatch/no-op behavior. The
  # stored-result protocol is new and always session-bound, so fail its commit
  # before applying or writing a snapshot when the envelope names another
  # session.
  defp validate_tool_result_event_sessions(events, session_id) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      type = event["type"] || event[:type]

      if type in ["tool_result_stored", :tool_result_stored] and
           (event["session_id"] || event[:session_id]) != session_id do
        {:halt, {:error, :session_id_mismatch}}
      else
        {:cont, :ok}
      end
    end)
  end

  # A result_ref identifies one canonical result inside the bounded live-ref
  # window, not a last-write-wins key. Exact producer retries are absorbing;
  # conflicting reuse fails before the reducer or snapshot write. While a live
  # pointer addresses an archived record, compare through the archive catalog.
  # Once every projection retires, the pointer is intentionally gone; globally
  # unique opaque refs provide collision avoidance beyond that window.
  defp validate_tool_result_ref_idempotency(agent_id, session_id, state, events) do
    events
    |> Enum.reduce_while({:ok, %{}}, fn raw_event, {:ok, seen} ->
      event = normalize_event_keys(raw_event)

      if event["type"] == "tool_result_stored" do
        ref = event["result_ref"]

        case Map.fetch(seen, ref) do
          {:ok, record} ->
            compare_tool_result_record(record, event, seen)

          :error ->
            case existing_tool_result_record(agent_id, session_id, state, ref) do
              {:ok, record} -> compare_tool_result_record(record, event, seen)
              :not_found -> {:cont, {:ok, Map.put(seen, ref, event)}}
              {:error, _reason} = error -> {:halt, error}
            end
        end
      else
        {:cont, {:ok, seen}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp existing_tool_result_record(agent_id, session_id, state, ref) do
    case InternalSession.lookup_async_call(state, ref) do
      {:ok, %{"kind" => "tool_result"} = record} ->
        {:ok, record}

      {:ok, _other_record} ->
        {:error, :tool_result_ref_conflict}

      {:archived, seq} ->
        case fetch_archived_record(agent_id, session_id, state, seq) do
          {:ok, %{"kind" => "tool_result"} = record} -> {:ok, record}
          {:ok, _other_record} -> {:error, :tool_result_ref_conflict}
          {:error, _reason} = error -> error
        end

      :not_found ->
        :not_found
    end
  end

  defp compare_tool_result_record(record, event, seen) do
    if canonical_tool_result_record(record) == canonical_tool_result_record(event) do
      {:cont, {:ok, Map.put(seen, event["result_ref"], record)}}
    else
      {:halt, {:error, :tool_result_ref_conflict}}
    end
  end

  defp canonical_tool_result_record(record) do
    record
    |> normalize_event_keys()
    |> Map.take(@tool_result_record_fields)
  end

  defp normalize_event_keys(event),
    do: Map.new(event, fn {key, value} -> {to_string(key), value} end)

  defp normalize_dynamic_commit({:ok, events, commit_opts, meta})
       when is_list(events) and is_list(commit_opts),
       do: {:ok, events, commit_opts, meta}

  defp normalize_dynamic_commit({:ok, events, commit_opts})
       when is_list(events) and is_list(commit_opts),
       do: {:ok, events, commit_opts, %{}}

  defp normalize_dynamic_commit({:ok, events}) when is_list(events),
    do: {:ok, events, [], %{}}

  defp normalize_dynamic_commit({:error, _} = err), do: err

  defp normalize_dynamic_commit(other),
    do: {:error, {:invalid_dynamic_commit_result, other}}

  defp put_activity_revision(current, next) do
    InternalSession.stamp(next, activity_revision: activity_revision_value(current, next))
  end

  # The kernel keeps the current activity revision while the monitored
  # activity signature is unchanged.
  defp activity_revision_value(current, next) do
    InternalSession.query(
      current,
      :activity_revision,
      {InternalSession.monitored_activity_signature(next), SessionStorageRevision.new()}
    )
  end

  defp sleep_commit_retry(retries_left) do
    attempt = max(@max_commit_retries - retries_left + 1, 1)
    delay_ms = min(attempt * @commit_retry_backoff_ms, @commit_retry_backoff_max_ms)
    Process.sleep(delay_ms)
  end

  defp dynamic_commit_meta(meta, events, commit_opts) when is_map(meta) do
    meta
    |> Map.put_new(:event_count, length(events))
    |> Map.put_new(:event_types, Enum.map(events, &(&1["type"] || &1[:type])))
    |> Map.put_new(:hwm, commit_opts[:hwm])
  end

  defp dynamic_commit_meta(_meta, events, commit_opts),
    do: dynamic_commit_meta(%{}, events, commit_opts)

  defp timestamp_lifecycle_events(events) do
    timestamp = System.system_time(:second)

    Enum.map(events, fn event ->
      type = event["type"] || event[:type]
      created_at = event["created_at"] || event[:created_at]

      if type in @lifecycle_event_types and not is_integer(created_at),
        do: Map.put(event, "created_at", timestamp),
        else: event
    end)
  end

  defp sync_work_index(agent_id, session_id, current, next_state, opts) do
    with {:ok, fields, cleanup} <-
           sync_work_index_fields(agent_id, session_id, current, next_state, opts) do
      {:ok, InternalSession.stamp(next_state, fields), cleanup}
    end
  end

  defp sync_work_index_fields(agent_id, session_id, current, next_state, opts) do
    current_token = InternalSession.work_index_token(current)

    current_discovery =
      SessionWorkIndex.discovery_ref(
        agent_id,
        :internal,
        session_id,
        current_token,
        InternalSession.work_reasons(current),
        InternalSession.recovery_wait(current)
      )

    case InternalSession.work_reasons(next_state) do
      [] ->
        {:ok, %{work_index_token: nil, work_index_reasons: []},
         {:delete, agent_id, session_id, current_token, current_discovery}}

      reasons ->
        with {:ok, %{"token" => token}} <-
               SessionWorkIndex.mark(agent_id, :internal, session_id, reasons,
                 cas_base: opts[:cas_base],
                 base_revision: opts[:base_revision],
                 recover_after_ms:
                   SessionWorkIndex.recover_after_ms(
                     reasons,
                     InternalSession.recovery_wait(next_state)
                   )
               ) do
          {:ok, %{work_index_token: token, work_index_reasons: reasons},
           {:delete_discovery, current_discovery}}
        end
    end
  end

  defp cleanup_work_index(cleanup) do
    SystemsObservability.Trace.with_span(
      :salix_session_cleanup,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> do_cleanup_work_index(cleanup) end
    )
  end

  defp do_cleanup_work_index({:delete, agent_id, session_id, token, discovery}) do
    case SessionWorkIndex.delete_if_token(agent_id, :internal, session_id, token) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "internal session #{agent_id}/#{session_id} work index cleanup failed: #{inspect(reason)}"
        )

        :ok
    end

    cleanup_discovery(discovery, "internal session #{agent_id}/#{session_id}")
  end

  defp do_cleanup_work_index({:delete_discovery, discovery}) do
    cleanup_discovery(discovery, "internal session")
  end

  defp do_cleanup_work_index(:none), do: :ok

  defp cleanup_uncommitted_work_index(agent_id, session_id, state) do
    case SessionWorkIndex.discard_uncommitted(
           agent_id,
           :internal,
           session_id,
           InternalSession.work_index_token(state),
           InternalSession.work_reasons(state),
           InternalSession.recovery_wait(state)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "internal session #{agent_id}/#{session_id} uncommitted work index cleanup failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp reconcile_rejected_seed_local_index(agent_id, session_id, rejected) do
    with {:ok, authoritative} <- read(agent_id, session_id),
         :ok <-
           SessionWorkIndex.reconcile_local_after_rejection(
             agent_id,
             :internal,
             session_id,
             InternalSession.work_index_token(rejected),
             InternalSession.work_index_token(authoritative),
             InternalSession.work_reasons(authoritative),
             InternalSession.recovery_wait(authoritative)
           ) do
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "internal session #{agent_id}/#{session_id} rejected seed local index reconciliation failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp cleanup_discovery(discovery, label) do
    case SessionWorkIndex.delete_discovery(discovery) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("#{label} work discovery cleanup failed: #{inspect(reason)}")
        :ok
    end
  end

  # Seed writes settle through the shared primitive. Create-once (the fork
  # and plain-create path) recognizes its own landed write by the PERSISTED
  # identity — (source_session_id, fork_request_id) — never by byte
  # comparison: created_at, the storage revision, and the source snapshot
  # all drift between attempts, so recomputed bytes would misjudge our own
  # success (#756). A target without a fork_request_id is unsettleable and
  # any existing object stays a genuine :exists.
  defp seed_write(key, body, [if_match: etag], _state) do
    case Settle.cas_put(key, body, etag) do
      :ok -> :ok
      {:error, :precondition_failed} -> {:error, :exists}
      {:error, _} = err -> err
    end
  end

  defp seed_write(key, body, _if_none_match, state) do
    settle_fn =
      fork_identity_settle(
        InternalSession.get(state, :source_agent_id),
        InternalSession.get(state, :source_session_id),
        InternalSession.get(state, :fork_request_id)
      )

    case Settle.create_once(key, body, settle_fn) do
      :created -> :ok
      :landed -> :ok
      {:exists, _foreign} -> {:error, :exists}
      {:error, _} = err -> err
    end
  end

  defp fork_identity_settle(source_agent_id, source_session_id, fork_request_id)
       when is_binary(fork_request_id) and fork_request_id != "" do
    # The FULL persisted identity tuple: a clone/fork from source agent A
    # must never be adopted by a retry naming the same session id under
    # source agent B — that would expose A's transcript.
    fn %{body: got} ->
      case landed_session(got) do
        {:ok, landed} ->
          if InternalSession.get(landed, :fork_request_id) == fork_request_id and
               InternalSession.get(landed, :source_session_id) == source_session_id and
               InternalSession.get(landed, :source_agent_id) == source_agent_id,
             do: :own,
             else: :foreign

        :error ->
          :foreign
      end
    end
  end

  defp fork_identity_settle(_agent, _source, _absent_request_id),
    do: fn _read_back -> :foreign end

  defp landed_session(body) do
    case InternalSession.load(Codec.snapshot_etf(body)) do
      {:ok, landed} -> {:ok, landed}
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp seed_current_state(agent_id, session_id, opts) do
    if opts[:force] do
      case read_with_etag(agent_id, session_id) do
        {:ok, state, etag} ->
          {:ok, state, [if_match: etag], etag}

        {:error, :not_found} ->
          {:ok, InternalSession.new(agent_id, session_id, %{}), [if_none_match: "*"], "absent"}

        {:error, _} = err ->
          err
      end
    else
      {:ok, InternalSession.new(agent_id, session_id, %{}), [if_none_match: "*"], "absent"}
    end
  end

  defp read_or_new_for_update(agent_id, session_id, opts) do
    case read_for_update(agent_id, session_id) do
      {:ok, _state, _etag} = ok ->
        ok

      {:error, :not_found} ->
        # The commit path's CREATION decision point: the birth claim runs
        # HERE, before sync_work_index touches Postgres, so a refused birth
        # leaves zero rows behind (#873 round 10: the claim inside
        # write_state/4 ran AFTER the work-index insert and leaked
        # permanent recovery candidates the sweep kept retaining).
        with :ok <- claim_internal_birth(agent_id, session_id) do
          attrs = Keyword.get(opts, :create_attrs, %{})
          {:ok, InternalSession.new(agent_id, session_id, attrs), nil}
        end

      {:error, _} = err ->
        err
    end
  end

  defp read_for_update(agent_id, session_id) do
    case read_revision(agent_id, session_id) do
      {:ok, revision} -> {:ok, revision.state, revision.etag}
      {:error, _} = error -> error
    end
  end

  defp read_revision_object(key, accept) do
    case SystemsObservability.Trace.with_span(
           :salix_session_get,
           %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
           fn -> S3.get(key) end
         ) do
      {:ok, %{body: body, etag: etag}} ->
        SystemsObservability.Trace.with_span(
          :salix_session_decode,
          %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
          fn ->
            case snapshot_etf(body) do
              {:ok, bytes} -> accept.({:ok, bytes, etag})
              {:error, {:snapshot_too_large, _stats}} -> accept.(recover_snapshot(key))
              _ -> accept.({:error, :invalid_session_snapshot})
            end
          end
        )

      {:error, _} = error ->
        accept.(error)
    end
  end

  defp load_key(agent_id, key) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        decode_loaded(agent_id, nil, key, body, etag)

      {:error, _} = err ->
        err
    end
  end

  @doc """
  The only archive writer: compaction seals immutable format-3 segments.
  Legacy snapshots use the same current hot writer before sealing. It seals
  first-seq-named segments, including the partial compacted tail, and advances
  only after archive publication and the hot-object CAS succeed. See
  docs/storage-search.md and tla/salix/README.md. Archived generic tool results retain their
  small source-session pointer in the hot state.

  Landed archive records are adopted after a lost hot-object CAS, without
  requiring the resumed writer to reproduce identical encoded bytes.
  Archival runs after compaction commits. Errors are returned and logged.
  A later compaction can retry, but there is no independent retry worker.
  """
  @spec archive_compacted(String.t(), String.t(), InternalSession.t() | nil) ::
          {:ok, :archived | :nothing_to_archive} | {:error, term()}
  def archive_compacted(agent_id, session_id, session \\ nil)

  # A caller's Session view has no CAS revision and can be stale. Read one
  # baseline for both publication and removal. Landed objects retain their cuts.
  def archive_compacted(agent_id, session_id, _session) do
    with {:ok, revision} <- read_revision(agent_id, session_id) do
      if InternalSession.storage_format(revision.state) == 3 do
        do_seal_compacted(agent_id, session_id, revision, @max_commit_retries)
      else
        with {:ok, current} <- commit_revision(agent_id, session_id, revision, []),
             do: do_seal_compacted(agent_id, session_id, current, @max_commit_retries)
      end
    end
  end

  defp do_seal_compacted(agent_id, session_id, _revision, 0),
    do: log_archive_failure(agent_id, session_id, {:error, :stale_internal_session})

  # Each attempt publishes from the exact revision that its CAS replaces.
  # A conflict repeats publication from the new baseline, not the old event.
  defp do_seal_compacted(agent_id, session_id, %Revision{} = revision, retries) do
    case InternalSession.archive_publication(
           revision.state,
           SealedSegments.line_bytes(),
           &archive_publication_effect/1
         ) do
      {:ok, :nothing_to_archive} = result ->
        result

      {:advance, event} ->
        case commit_revision(agent_id, session_id, revision, [event], on_conflict: :error) do
          {:ok, _session} ->
            {:ok, :archived}

          {:error, :precondition_failed} ->
            sleep_commit_retry(retries)

            with {:ok, fresh} <- read_revision(agent_id, session_id),
                 :ok <- revision_coordinates_unchanged(revision.state, fresh.state) do
              do_seal_compacted(agent_id, session_id, fresh, retries - 1)
            else
              {:error, _} = error -> log_archive_failure(agent_id, session_id, error)
            end

          {:error, _} = error ->
            log_archive_failure(agent_id, session_id, error)
        end

      {:error, {:segment_divergence, first}} ->
        key = Keys.agent_internal_runtime_session_segment(agent_id, session_id, first)
        log_archive_failure(agent_id, session_id, {:error, {:segment_divergence, key}})

      {:error, _} = error ->
        log_archive_failure(agent_id, session_id, error)
    end
  end

  defp archive_publication_effect({:read_segment, agent_id, session_id, first}) do
    key = Keys.agent_internal_runtime_session_segment(agent_id, session_id, first)

    case S3.get(key) do
      {:ok, %{body: body}} -> decode_archive_result(body, :ok)
      {:error, reason} -> {:error, InternalSession.Command.external_error(reason)}
    end
  end

  defp archive_publication_effect({:create_segment, agent_id, session_id, first, etf}) do
    key = Keys.agent_internal_runtime_session_segment(agent_id, session_id, first)
    body = Codec.compress_snapshot_etf(etf)

    case Settle.create_once(key, body, Settle.byte_settle(body)) do
      {:exists, %{body: landed}} -> decode_archive_result(landed, :exists)
      {:error, reason} -> {:error, InternalSession.Command.external_error(reason)}
      result -> result
    end
  end

  defp archive_publication_effect({:deterministic_etf, value}),
    do: :erlang.term_to_binary(value, [:deterministic, {:minor_version, 1}])

  defp decode_archive_result(body, tag) do
    {tag, SealedSegments.decode(body)}
  rescue
    _ -> :invalid_segment
  end

  defp log_archive_failure(agent_id, session_id, {:error, reason} = err) do
    CommaLog.log("session_archive_failed", %{
      agent_id: agent_id,
      session_id: session_id,
      reason: inspect(reason)
    })

    err
  end

  @doc false
  def window_records_shaped(session), do: InternalSession.query(session, :archive_window_records)

  @doc """
  Fetch one archived result record by seq: one catalog-addressed GET
  (a format-2 archive range or a format-3 segment), never a history scan. This is the pointer tier of the result lookup ladder for legacy async
  results or generic tool results archived while still live-referenced;
  unprotected bare-id lookups never reach it (owner 2026-08-06).

  The archive wire form stores `seq` outside `data`. Restore it on the returned
  record so exact result pointers remain authoritative after archival, and
  reject any other record kind even if a stale/corrupt pointer names its seq.
  """
  @spec fetch_archived_record(String.t(), String.t(), InternalSession.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def fetch_archived_record(agent_id, _session_id, session, seq)
      when is_integer(seq) and seq > 0 do
    if seq > (InternalSession.archived_through(session) || 0) do
      {:error, :not_found}
    else
      with {:ok, catalog} <- committed_spans(session),
           %{} = span <- Enum.find(catalog, &(&1.first <= seq and seq <= &1.last)) || :not_found,
           {:ok, records} <- read_spans(agent_id, session, [span]) do
        records
        |> Enum.find(&(&1.seq == seq))
        |> case do
          nil ->
            {:error, :not_found}

          %{kind: kind, seq: ^seq, data: data}
          when kind in ["async_result", "tool_result"] ->
            {:ok, data |> Map.put("kind", kind) |> Map.put("seq", seq)}

          %{} ->
            {:error, :not_found}
        end
      else
        :not_found -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Resolve a session-owned result through the hot lookup ladder and, when its
  live pointer names archived history, one catalog-addressed ranged read.

  `lookup_ref` may be a legacy async tool_call_id or an opaque result_ref.
  """
  @spec fetch_result(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_result(agent_id, session_id, lookup_ref)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(lookup_ref) do
    with {:ok, session} <- read(agent_id, session_id) do
      case InternalSession.lookup_async_call(session, lookup_ref) do
        {:ok, record} -> {:ok, record}
        {:archived, seq} -> fetch_archived_record(agent_id, session_id, session, seq)
        :not_found -> {:error, :not_found}
      end
    end
  end

  @doc "Resolve one generic stored tool result by its opaque session-owned ref."
  @spec fetch_tool_result(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def fetch_tool_result(agent_id, session_id, result_ref)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(result_ref) do
    case fetch_result(agent_id, session_id, result_ref) do
      {:ok, %{"kind" => "tool_result"} = record} -> {:ok, record}
      {:ok, _other_kind} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The COMMITTED archived range of the session's log, in seq order, redaction
  overlays applied to message records read-side — archived bytes carry the
  original content and are never rewritten.

  This explicit full-history reader transfers the committed archive. Paged
  transcript and exact-result reads select only their required catalog spans.
  Objects or bytes from landed-but-uncommitted archival stay outside the read
  range and cannot be double-counted against the live window.

  Both formats require the catalog to tile `1..archived_through` in seq space.
  Format 2 also tiles its single object's bytes from zero; format 3 names one
  immutable object per span. A broken tiling returns
  `{:error, {:archive_incomplete, ...}}` — a hard failure, never a silently
  shortened history.
  """
  @spec archived_records(String.t(), InternalSession.t(), keyword()) ::
          {:ok, [ArchiveLog.log_record()]} | {:error, term()}
  def archived_records(agent_id, session, opts \\ []) do
    archived_through = InternalSession.archived_through(session) || 0

    if (InternalSession.storage_format(session) || 1) >= 2 and archived_through > 0 do
      with {:ok, catalog} <- committed_spans(session),
           {:ok, records} <- read_spans(agent_id, session, catalog),
           :ok <- assert_committed_coverage(records, archived_through) do
        # `mask: false` answers the raw immutable history for verification;
        # every runtime reader keeps the redaction overlay.
        if Keyword.get(opts, :mask, true),
          do:
            {:ok,
             mask_archived_message_records(records, InternalSession.get(session, :redactions))},
          else: {:ok, records}
      end
    else
      {:ok, []}
    end
  end

  @doc false
  def normalized_catalog(session), do: SalixAgent.InternalSessionArchiveReader.catalog(session)

  defp committed_spans(session),
    do: SalixAgent.InternalSessionArchiveReader.committed_spans(session)

  defp read_spans(agent_id, session, spans),
    do: SalixAgent.InternalSessionArchiveReader.read(agent_id, session, spans)

  @doc """
  The bounded logical transcript — the ONE message view every reader uses.

  * `:window` — the masked live window, saying whether history was archived
    out of it (`truncated?`); agent-facing surfaces serve this scope and
    state the truncation instead of silently shortening.
  * `{:tail, n}` — the newest `n` messages: the window completed backwards
    from the committed archive, reading only the catalog spans that hold
    them (zero LIST, one ranged GET per contiguous run — never the whole
    archive). `has_older?` and `oldest_seq` are the pagination cursor.
  * `{:before, seq, n}` — up to `n` archived messages older than `seq`
    (the "load older" page), same bounded span access.
  * `:full` — the entire committed archive ahead of the window. UNBOUNDED
    (every span, whole history in memory) and therefore
    has NO runtime callers: recovery files read `archived_records/2`
    directly and the microcompact selector uses the persisted id HWM. It
    survives as the whole-history oracle for the archive suites and as an
    operator-only escape hatch. Never call it from a request path — pages
    take `{:tail, n}` / `{:before, seq, n}`, agent surfaces take `:window`.

  Every scope applies the redaction overlay; archived message maps carry
  string keys (seq restored from the record), window maps atom keys.
  """
  @spec transcript(
          String.t(),
          InternalSession.t(),
          :window | :full | {:tail, pos_integer()} | {:before, pos_integer(), pos_integer()}
        ) :: {:ok, map()} | {:error, term()}
  def transcript(_agent_id, session, :window) do
    archived_through = InternalSession.archived_through(session) || 0

    {:ok,
     %{
       messages: InternalSession.masked_messages(session),
       archived_through: archived_through,
       truncated?: archived_through > 0,
       has_older?: archived_through > 0
     }}
  end

  def transcript(agent_id, session, :full) do
    archived_through = InternalSession.archived_through(session) || 0

    with {:ok, records} <- archived_records(agent_id, session) do
      {:ok,
       %{
         messages: archived_message_maps(records) ++ InternalSession.masked_messages(session),
         archived_through: archived_through,
         truncated?: false,
         has_older?: false
       }}
    end
  end

  def transcript(agent_id, session, {:tail, n}) when is_integer(n) and n > 0 do
    archived_through = InternalSession.archived_through(session) || 0
    window = InternalSession.masked_messages(session)
    missing = n - length(window)

    if missing <= 0 or archived_through == 0 do
      tail = Enum.take(window, -n)

      {:ok,
       %{
         messages: tail,
         archived_through: archived_through,
         truncated?: archived_through > 0 or length(window) > n,
         has_older?: archived_through > 0 or length(window) > n
       }}
    else
      with {:ok, archived} <-
             archived_message_page(agent_id, session, archived_through + 1, missing) do
        messages = archived ++ window
        oldest = List.first(archived)

        {:ok,
         %{
           messages: messages,
           archived_through: archived_through,
           truncated?: oldest != nil and (oldest["seq"] || 0) > 1,
           has_older?: oldest != nil and (oldest["seq"] || 0) > 1
         }}
      end
    end
  end

  def transcript(agent_id, session, {:before, before_seq, n})
      when is_integer(before_seq) and is_integer(n) and n > 0 do
    archived_through = InternalSession.archived_through(session) || 0

    # The hot window can itself be deeper than one page: serve the older
    # window slice first, and only descend into the archive for whatever
    # the window cannot cover — never skip the hot range.
    window_older =
      session
      |> InternalSession.masked_messages()
      |> Enum.filter(&(is_integer(&1[:seq]) and &1[:seq] < before_seq))

    window_page = Enum.take(window_older, -n)
    missing = n - length(window_page)

    window_floor =
      case window_page do
        [oldest | _] -> oldest[:seq]
        [] -> min(before_seq, archived_through + 1)
      end

    with {:ok, archived} <-
           (if missing > 0 do
              archived_message_page(agent_id, session, window_floor, missing)
            else
              {:ok, []}
            end) do
      messages = archived ++ window_page
      oldest = List.first(messages)
      oldest_seq = oldest && (oldest["seq"] || oldest[:seq])

      {:ok,
       %{
         messages: messages,
         archived_through: archived_through,
         truncated?: oldest_seq != nil and oldest_seq > 1,
         has_older?: oldest_seq != nil and oldest_seq > 1
       }}
    end
  end

  defp archived_message_maps(records) do
    # The wire form keeps seq at the record's top level only; readers get it
    # back on the message map as their log coordinate.
    for %{kind: "message", seq: seq, data: data} <- records,
        do: Map.put(data, "seq", seq)
  end

  # Up to `count` archived MESSAGE maps with seq < before_seq, reading only
  # the catalog spans that can hold them. Selection completes BEFORE any
  # read, so a sparse archive cannot turn a one-message page into a scan,
  # and the selected spans collapse into a single ranged GET.
  defp archived_message_page(agent_id, session, before_seq, count) do
    archived_through = InternalSession.archived_through(session) || 0

    if (InternalSession.storage_format(session) || 1) >= 2 and archived_through > 0 and
         before_seq > 1 do
      with {:ok, catalog} <- committed_spans(session),
           spans =
             catalog
             |> Enum.filter(&(&1.first < before_seq))
             |> Enum.sort_by(& &1.first, :desc)
             |> select_page_spans(before_seq, count, []),
           {:ok, records} <- read_spans(agent_id, session, spans) do
        {:ok,
         records
         |> mask_archived_message_records(InternalSession.get(session, :redactions))
         |> archived_message_maps()
         |> Enum.filter(&(&1["seq"] < before_seq))
         |> Enum.take(-count)}
      end
    else
      {:ok, []}
    end
  end

  # The catalog's per-span message count decides what a page needs without
  # transferring a byte: spans holding no messages are never read, and a
  # span straddling the cursor is read but credited nothing — at worst the
  # page over-reads by that one span, never by the archive.
  defp select_page_spans([], _before_seq, _needed, acc), do: acc

  defp select_page_spans(_spans, _before_seq, needed, acc) when needed <= 0, do: acc

  defp select_page_spans([span | rest], before_seq, needed, acc) do
    cond do
      span.messages == 0 ->
        select_page_spans(rest, before_seq, needed, acc)

      span.last >= before_seq ->
        select_page_spans(rest, before_seq, needed, [span | acc])

      true ->
        select_page_spans(rest, before_seq, needed - span.messages, [span | acc])
    end
  end

  defp assert_committed_coverage(records, archived_through) do
    seqs = Enum.map(records, & &1.seq)

    if seqs == Enum.to_list(1..archived_through//1) do
      :ok
    else
      {:error,
       {:archive_incomplete,
        %{
          expected_through: archived_through,
          found: length(seqs),
          first_mismatch: first_coverage_mismatch(seqs, archived_through)
        }}}
    end
  end

  defp first_coverage_mismatch(seqs, archived_through) do
    seqs
    |> Enum.zip(1..archived_through//1)
    |> Enum.find(fn {got, expected} -> got != expected end)
    |> case do
      {got, expected} -> %{expected: expected, got: got}
      nil -> %{expected: min(length(seqs) + 1, archived_through), got: :absent}
    end
  end

  defp mask_archived_message_records(records, redactions) when redactions in [nil, []],
    do: records

  defp mask_archived_message_records(records, redactions) do
    by_seq =
      Map.new(
        for entry <- redactions,
            is_integer(entry["seq"]),
            do: {entry["seq"], entry["replacement"]}
      )

    by_id =
      Map.new(
        for entry <- redactions,
            not is_nil(entry["message_id"]),
            do: {entry["message_id"], entry["replacement"]}
      )

    predicates =
      Enum.filter(
        redactions,
        &(&1["kind"] in ["tool_messages_through", "non_model_messages_over_bytes_through"])
      )

    Enum.map(records, fn
      %{kind: "message", seq: seq, data: data} = record ->
        replacement =
          Map.get(by_seq, seq) || Map.get(by_id, data["id"]) ||
            predicate_replacement(predicates, data["role"], data["id"], data["content"])

        case replacement do
          nil -> record
          replacement -> %{record | data: Map.put(data, "content", replacement)}
        end

      record ->
        record
    end)
  end

  # Redaction predicates over archived message records. The same rule masks
  # the live window inside the kernel (`masked_messages`); archived bytes
  # live outside it, so the predicate is applied here read-side.
  defp predicate_replacement(predicates, role, id, content) when is_integer(id) do
    Enum.find_value(predicates, fn
      %{"kind" => "tool_messages_through"} = entry when role == "tool" ->
        if id <= (entry["through_id"] || 0), do: entry["replacement"]

      %{"kind" => "non_model_messages_over_bytes_through"} = entry
      when role != "assistant" ->
        max_bytes = entry["max_bytes"]

        if is_integer(max_bytes) and max_bytes > 0 and is_binary(content) and
             id <= (entry["through_id"] || 0) and byte_size(content) > max_bytes,
           do: entry["replacement"]

      _entry ->
        nil
    end)
  end

  defp predicate_replacement(_predicates, _role, _id, _content), do: nil

  # Settlement retains the original uploaded bytes through its final read-only
  # budget. A matching marker alone cannot identify the committed candidate.
  # Exhaustion returns :commit_indeterminate; the caller must reload, not replay.
  # No base etag = the commit path is CREATING the session. Its birth claim
  # already ran at the creation decision point (read_or_new_for_update),
  # before any work-index write — do not re-claim here, past the PG insert.
  # Every new hot write uses the current envelope in pinned-minor zstd ETF.
  # Legacy decoding remains a read-only compatibility boundary.
  # A Revision carries caller-owned coordinates. Generic event replay cannot
  # translate those across first-write legacy normalization.
  defp revision_coordinates_unchanged(state, fresh) do
    if InternalSession.storage_format(state) == 1 and
         (InternalSession.storage_format(fresh) || 1) >= 2,
       do: {:error, :stale_internal_session},
       else: :ok
  end

  # A pending revision already contains these exact events and HWM. Its CAS
  # base is frozen and conflicts fail closed, so replaying them is redundant.
  # The native fence retains normalization and format validation. An ordinary
  # retry starts from its fresh baseline, not an older pending continuation.
  defp prepare_fenced_write(agent_id, session_id, cursor, events, opts, prepared) do
    SystemsObservability.Trace.with_span(
      :salix_session_prepare_write,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn ->
        pending =
          case prepared do
            nil ->
              InternalSession.write_revision(cursor, events, opts[:hwm])

            pending ->
              pending
          end

        key = Keys.agent_internal_runtime_session(agent_id, session_id)

        with {:ok, fence} <- InternalSession.start_revision_fence(pending, key) do
          {:ok, fence, InternalSession.fence_prepared_state(fence)}
        end
      end
    )
  end

  defp prepare_write(state, events, opts) do
    state
    |> InternalSession.apply_events(events)
    |> InternalSession.bump_hwm(opts[:hwm])
    |> InternalSession.prepare_write()
  end

  # The kernel produces the persistable snapshot ETF; only compression and
  # the CAS stay on the host.
  defp encode_state(state),
    do:
      SystemsObservability.Trace.with_span(
        :salix_session_encode,
        %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
        fn -> state |> InternalSession.persist() |> Codec.compress_snapshot_etf() end
      )

  defp write_state(agent_id, session_id, state, etag) do
    case write_state_with_etag(agent_id, session_id, state, etag) do
      {:ok, _committed_etag} -> :ok
      {:error, _} = error -> error
    end
  end

  defp write_state_with_etag(agent_id, session_id, state, etag) do
    key = Keys.agent_internal_runtime_session(agent_id, session_id)

    result =
      execute_snapshot_cas(
        fn -> InternalSession.start_storage_commit(state, key, etag) end,
        &InternalSession.resume_storage_commit/2
      )

    case result do
      {:ok, committed_etag} ->
        SalixAgent.SessionHistory.Worker.hint(agent_id, session_id)
        notify_owner_of_foreign_write(agent_id, session_id)
        {:ok, committed_etag}

      {:error, _} = error ->
        error
    end
  end

  defp write_fenced_state(agent_id, session_id, fence) do
    result =
      execute_snapshot_cas(
        fn -> InternalSession.encode_revision_fence(fence) end,
        &InternalSession.resume_revision_fence_cursor/2
      )

    case result do
      {:ok, _cursor} = committed ->
        SalixAgent.SessionHistory.Worker.hint(agent_id, session_id)
        notify_owner_of_foreign_write(agent_id, session_id)
        committed

      {:error, _state, _reason} = error ->
        error
    end
  end

  defp execute_snapshot_cas(prepare, resume) do
    {cursor, cas_key, body, base} =
      SystemsObservability.Trace.with_span(
        :salix_session_encode,
        %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
        fn ->
          {cursor, {:cas, cas_key, bytes, base}} = prepare.()

          {cursor, cas_key, Codec.compress_snapshot_etf(bytes), base}
        end
      )

    result =
      SystemsObservability.Trace.with_span(
        :salix_session_cas,
        %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
        fn -> Settle.cas_put_with_etag(cas_key, body, base, final_readback_attempts: 4) end
      )

    result = InternalSession.Command.external_error(result)

    resume.(cursor, result)
  end

  # The owning actor holds its session revision resident. A write from any
  # other local process (fixtures, operator repair, migrations) tells the
  # owner so its next processing entry reads; the owner's own writes are
  # what its revision already is.
  defp notify_owner_of_foreign_write(agent_id, session_id) do
    case Registry.lookup(SalixAgent.Registry, InternalSessionActor.key(agent_id, session_id)) do
      [{pid, _}] when pid != self() ->
        case Process.get({__MODULE__, :fence_epoch}) do
          # The initiating owner joins this writer and retains its committed revision.
          {^agent_id, ^session_id, _epoch, ^pid} -> :ok
          _ -> send(pid, {:session_written_elsewhere, session_id})
        end

      _ ->
        :ok
    end

    :ok
  end

  defp decode_loaded(agent_id, expected_session_id, key, body, etag) do
    SystemsObservability.Trace.with_span(
      :salix_session_decode,
      %{component: "salix_agent", surface: SystemsObservability.Context.current_surface()},
      fn -> traced_decode_loaded(agent_id, expected_session_id, key, body, etag) end
    )
  end

  defp traced_decode_loaded(agent_id, expected_session_id, key, body, _etag) do
    etf = snapshot_etf(body)

    # The kernel decodes and normalizes the snapshot; the host checks only
    # that the object belongs where it was found.
    with {:ok, bytes} <- etf,
         {:ok, state} <- InternalSession.load(bytes) do
      session_id = InternalSession.session_id(state)

      cond do
        InternalSession.agent_id(state) != agent_id ->
          {:error, :session_agent_id_mismatch}

        not (is_binary(session_id) and Ids.valid_session_id?(session_id)) ->
          {:error, :invalid_session_id}

        is_binary(expected_session_id) and session_id != expected_session_id ->
          {:error, :session_id_mismatch}

        key != Keys.agent_internal_runtime_session(agent_id, session_id) ->
          {:error, :session_key_mismatch}

        true ->
          {:ok, state}
      end
    else
      {:error, {:snapshot_too_large, _stats}} ->
        recover_snapshot(key)

      _other ->
        {:error, :invalid_session_snapshot}
    end
  end

  defp snapshot_etf(body) do
    if Application.get_env(:salix_agent, :snapshot_recovery_enabled, false),
      do: Codec.snapshot_etf_bounded(body, SalixAgent.LegacyGuardSnapshotRepair.read_limit()),
      else: {:ok, Codec.snapshot_etf(body)}
  end

  defp recover_snapshot(key) do
    case SalixAgent.LegacyGuardSnapshotRepair.recover(key) do
      {:ok, _} -> {:error, :snapshot_repaired_retry}
      {:error, _} = error -> error
    end
  end

  defp dynamic_result_event_count({:ok, _state, %{event_count: count}}), do: count
  defp dynamic_result_event_count(_result), do: nil

  defp dynamic_result_event_types({:ok, _state, %{event_types: types}}) when is_list(types),
    do: types

  defp dynamic_result_event_types(_result), do: []

  defp dynamic_result_hwm({:ok, _state, %{hwm: hwm}}), do: hwm
  defp dynamic_result_hwm(_result), do: nil

  defp result_label({:ok, _}), do: "ok"
  defp result_label({:ok, _, _}), do: "ok"
  defp result_label({:error, reason}), do: inspect(reason)
  defp result_label(other), do: inspect(other)
end
