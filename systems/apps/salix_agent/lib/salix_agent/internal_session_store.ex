defmodule SalixAgent.InternalSessionStore do
  @moduledoc """
  Session owner persistence. PostgreSQL holds birth, inputs, control and records;
  immutable archived bodies are read from the committed archive directory.
  """

  require Logger

  alias SalixAgent.{InternalSession, InternalSessionActor}
  alias SalixAgent.InternalSessionStore.PG
  alias SalixStore.{ArchiveLog, Codec, Ids, Keys, S3, SealedSegments}
  alias SalixStore.S3.Settle

  @max_commit_retries 64
  @slow_fence_ms 1_000
  @lifecycle_event_types ~w(session_created status activity_status wait_set wait_clear)

  defmodule Revision do
    @moduledoc "Owner-local working state and its exact committed SQL revision."
    @enforce_keys [:cursor, :state, :revision]
    defstruct [:cursor, :state, :revision, :pending]

    @type t :: %__MODULE__{
            cursor: tuple(),
            state: InternalSession.t(),
            revision: non_neg_integer() | nil,
            pending: tuple() | nil
          }
  end

  def read(agent_id, session_id) do
    with {:ok, version} <- read_revision(agent_id, session_id) do
      # The caller gets the state only. The revision cursor shares it and
      # would keep it resident until this process collects the cursor.
      InternalSession.release(version.cursor)
      {:ok, version.state}
    end
  end

  @doc """
  Reads the session, runs `fun` with it, and releases the state when `fun`
  returns or raises. A read keeps the whole state resident in the kernel until
  the calling process collects the handle, which a long-lived process that
  then idles may not do for hours. `fun` must return data derived from the
  session, never the handle: every call with it after the release raises
  `ArgumentError`.
  """
  @spec with_session(String.t(), String.t(), (InternalSession.t() -> result)) ::
          result | {:error, term()}
        when result: term()
  def with_session(agent_id, session_id, fun) when is_function(fun, 1) do
    case read(agent_id, session_id) do
      {:ok, session} ->
        try do
          fun.(session)
        after
          InternalSession.release(session)
        end

      {:error, _} = error ->
        error
    end
  end

  def read_revision(agent_id, session_id), do: PG.read(agent_id, session_id)

  @doc """
  The newest messages of the session's context window, newest first, without
  hydrating the window: `pick` maps a message to a list of results and the walk
  stops at `limit` results. A long window spans hundreds of archive objects, so
  the walk reads a bounded number of them; a read that fails ends it with what
  it has.
  """
  @spec recent_messages(String.t(), String.t(), pos_integer(), (map() -> list())) ::
          {:ok, list()} | {:error, term()}
  def recent_messages(agent_id, session_id, limit, pick),
    do: PG.recent_messages(agent_id, session_id, limit, pick)

  defdelegate input_committed?(agent_id, session_id, source_id), to: PG

  def read_or_new_revision(agent_id, session_id, attrs \\ %{}) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         do: read_or_new(agent_id, session_id, attrs)
  end

  defp read_or_new(agent_id, session_id, attrs) do
    case read_revision(agent_id, session_id) do
      {:error, :not_found} ->
        with true <- Ids.valid_session_id?(session_id),
             {:ok, side} when side in [:new, :internal] <- PG.birth(agent_id, session_id) do
          {:ok,
           InternalSession.new(agent_id, session_id, attrs)
           |> InternalSession.start_revision(nil)
           |> revision_from_cursor()}
        else
          false -> {:error, :invalid_session_id}
          {:ok, _reserved} -> {:error, :session_read_only}
          error -> error
        end

      result ->
        result
    end
  end

  def birth(agent_id, session_id), do: PG.birth(agent_id, session_id)

  @doc "Whether the session is hidden, read from its row without its records."
  def hidden(agent_id, session_id), do: PG.hidden(agent_id, session_id)

  def probe(agent_id, session_id) do
    case PG.birth(agent_id, session_id) do
      {:ok, :new} -> :absent
      {:ok, :internal} -> :present
      {:ok, _reserved} -> {:error, :session_read_only}
      error -> error
    end
  end

  def exists?(agent_id, session_id), do: probe(agent_id, session_id) == :present

  def create(agent_id, session_id, attrs \\ %{}, opts \\ []) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         do: prepare_create(agent_id, session_id, attrs, opts)
  end

  def prepare_create(agent_id, session_id, attrs \\ %{}, _opts \\ []) do
    with true <- Ids.valid_session_id?(session_id),
         {:ok, epoch} <- local_runtime_epoch(agent_id, session_id),
         result <- settle(PG.create(agent_id, session_id, epoch, attrs)) do
      case result do
        {:ok, version} -> {:ok, version.state}
        {:error, {:stale_revision, _}} -> {:error, :exists}
        error -> error
      end
    else
      false -> {:error, :invalid_session_id}
      error -> error
    end
  end

  def seed(agent_id, state, opts \\ []) do
    with :ok <- ensure_session_owner(agent_id, InternalSession.session_id(state)),
         do: prepare_seed(agent_id, state, opts)
  end

  def prepare_seed(agent_id, state, _opts \\ []) do
    session_id = InternalSession.session_id(state)

    with true <- Ids.valid_session_id?(session_id),
         {:ok, epoch} <- local_runtime_epoch(agent_id, session_id),
         {:ok, state} <-
           state |> InternalSession.stamp(agent_id: agent_id) |> InternalSession.prepare_write() do
      pending =
        state |> InternalSession.start_revision(nil) |> revision_from_cursor() |> PG.freeze(epoch)

      case settle(PG.execute(pending)) do
        {:ok, _} -> :ok
        {:error, {:stale_revision, _}} -> confirm_seed_identity(agent_id, state)
        error -> error
      end
    else
      false -> {:error, :invalid_session_id}
      error -> error
    end
  end

  defp confirm_seed_identity(agent_id, state) do
    with {:ok, current} <- read(agent_id, InternalSession.session_id(state)) do
      request = InternalSession.get(state, :fork_request_id)

      if is_binary(request) and request != "" and
           InternalSession.get(current, :fork_request_id) == request and
           InternalSession.get(current, :source_agent_id) ==
             InternalSession.get(state, :source_agent_id) and
           InternalSession.get(current, :source_session_id) ==
             InternalSession.get(state, :source_session_id), do: :ok, else: {:error, :exists}
    end
  end

  def ensure(agent_id, session_id, attrs) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         do: prepare_ensure(agent_id, session_id, attrs)
  end

  def prepare_ensure(agent_id, session_id, attrs) do
    case read(agent_id, session_id) do
      {:error, :not_found} ->
        case prepare_create(agent_id, session_id, attrs) do
          {:error, :exists} -> read(agent_id, session_id)
          result -> result
        end

      result ->
        result
    end
  end

  def commit(agent_id, session_id, events, opts \\ []) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         do: prepare_commit(agent_id, session_id, events, opts)
  end

  def prepare_commit(agent_id, session_id, events, opts \\ []) do
    with {:ok, version} <- read_or_new(agent_id, session_id, opts[:create_attrs] || %{}),
         {:ok, epoch} <- local_runtime_epoch(agent_id, session_id),
         {:ok, committed} <-
           PG.commit_revision(version, epoch, canonical_events(events), opts) |> settle(),
         do: {:ok, committed.state}
  end

  def commit_revision(
        agent_id,
        session_id,
        %Revision{} = version,
        events,
        opts \\ [],
        prerequisite \\ nil
      ) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         {:ok, written} <- write_revision(version, events, opts),
         do: durable_fence(agent_id, session_id, written, prerequisite)
  end

  def write_revision(%Revision{} = version, events, opts \\ []) do
    with {:ok, epoch} <-
           local_runtime_epoch(
             InternalSession.agent_id(version.state),
             InternalSession.session_id(version.state)
           ),
         do: PG.stage_revision(version, epoch, canonical_events(events), opts)
  end

  def revision_baseline(%Revision{cursor: cursor}),
    do: cursor |> InternalSession.revision_baseline() |> revision_from_cursor()

  def plan_revision(%Revision{cursor: cursor}, mode) do
    {planned, outcome, changed} = InternalSession.plan_revision(cursor, mode)
    {revision_from_cursor(planned), outcome, changed}
  end

  defp revision_from_cursor(cursor) do
    {state, revision, pending?} = InternalSession.revision_view(cursor)
    %Revision{cursor: cursor, state: state, revision: revision, pending: if(pending?, do: cursor)}
  end

  def command_revision(command),
    do: command |> InternalSession.command_revision() |> revision_from_cursor()

  def write_command(command, events) do
    version = command_revision(command)

    case local_runtime_epoch(
           InternalSession.agent_id(version.state),
           InternalSession.session_id(version.state)
         ) do
      {:ok, epoch} ->
        case PG.stage_command(command, epoch, events) do
          {:ok, step} ->
            step

          {:error, reason} ->
            InternalSession.command_step(
              command,
              :write_result,
              {:error, InternalSession.Command.external_error(reason)}
            )
        end

      {:error, reason} ->
        InternalSession.command_step(command, :write_result, {:error, reason})
    end
  end

  def input_command(agent_id, session_id, version, command, entry) do
    with {:ok, epoch} <- local_runtime_epoch(agent_id, session_id) do
      result =
        if command == :stage_conversation,
          do: PG.stage_input_revision(version, epoch, entry),
          else: PG.input_revision(version, epoch, entry)

      finish_input(result, 5)
    end
  end

  defp finish_input({:effect_required, effect}, remaining) do
    result = InternalSession.Command.execute_workspace(effect.agent_id, effect.request)
    finish_input(PG.continue_input(effect, result), remaining)
  end

  defp finish_input({:error, :commit_indeterminate, pending}, remaining) when remaining > 0,
    do: finish_input(PG.settle_input(pending), remaining - 1)

  defp finish_input({:error, :commit_indeterminate, pending}, _),
    do: {:error, {:commit_indeterminate, pending}}

  defp finish_input(result, _), do: result

  def fence_command(agent_id, session_id, command, prerequisite \\ nil) do
    timed_fence(agent_id, session_id, prerequisite, fn epoch, clock ->
      {frozen, clock} = freeze(clock, fn -> PG.freeze_command(command, epoch) end)
      {write_frozen(frozen, command, epoch), clock}
    end)
  end

  def durable_fence(agent_id, session_id, version, prerequisite \\ nil) do
    timed_fence(agent_id, session_id, prerequisite, fn epoch, clock ->
      if InternalSession.revision_pending?(version.cursor) do
        {pending, clock} = freeze(clock, fn -> PG.freeze(version, epoch) end)
        {pending |> PG.execute() |> settle(), clock}
      else
        {PG.confirm_revision(version, epoch), clock}
      end
    end)
  end

  defp timed_fence(agent_id, session_id, prerequisite, write) do
    clock = fence_clock("direct")

    case session_epoch(agent_id, session_id) do
      {:ok, epoch} ->
        clock = lap(clock, :owner_ms)

        case run_commit_prerequisite(prerequisite) do
          :ok ->
            {result, clock} = write.(epoch, lap(clock, :prerequisite_ms))
            observe_fence(agent_id, session_id, result, clock)
            result

          error ->
            observe_fence(agent_id, session_id, error, lap(clock, :prerequisite_ms))
            error
        end

      error ->
        observe_fence(agent_id, session_id, error, lap(clock, :owner_ms))
        error
    end
  end

  defp write_frozen({:ok, pending}, _command, _epoch), do: pending |> PG.execute() |> settle()
  defp write_frozen(:clean, command, epoch), do: PG.fence_command(command, epoch) |> settle()

  defp session_epoch(agent_id, session_id) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         do: local_runtime_epoch(agent_id, session_id)
  end

  defp fence_clock(kind) do
    started = SystemsClock.monotonic_time()
    %{kind: kind, started: started, lap: started, laps: %{}}
  end

  defp lap(clock, phase) do
    now = SystemsClock.monotonic_time()
    %{clock | lap: now, laps: Map.put(clock.laps, phase, now - clock.lap)}
  end

  defp freeze(clock, fun) do
    {frozen, steps} = PG.time_freeze(fun)
    {frozen, clock |> lap(:freeze_ms) |> Map.put(:freeze_steps, steps)}
  end

  # Admission, tool steps and rounds all wait here, and nothing else times the
  # phases apart. A direct fence runs its phases in the caller. A started fence
  # freezes before its prerequisite and then writes in a task, so its schedule
  # time is the wait for that task to run. The write time is everything after
  # the last lap: the transaction with its pool wait and locks, the post-commit
  # notification and the kernel's commit of the delta.
  @doc false
  def observe_fence(agent_id, session_id, result, clock) do
    finished = SystemsClock.monotonic_time()
    outcome = if match?({:ok, _}, result), do: "ok", else: "error"

    Salix.Telemetry.emit_operation(
      "salix_agent",
      "session_fence",
      SystemsObservability.Context.current_surface(),
      outcome,
      finished - clock.started
    )

    if System.convert_time_unit(finished - clock.started, :native, :millisecond) >=
         @slow_fence_ms do
      laps = Map.put(clock.laps, :write_ms, finished - clock.lap)

      fields =
        for phase <- ~w(owner_ms prerequisite_ms freeze_ms schedule_ms write_ms)a, into: %{} do
          {phase, System.convert_time_unit(Map.get(laps, phase, 0), :native, :millisecond)}
        end

      steps =
        for {step, elapsed} <- Map.get(clock, :freeze_steps, %{}), into: %{} do
          {step, System.convert_time_unit(elapsed, :native, :millisecond)}
        end

      Logger.warning("session_fence_slow",
        session_fence:
          Map.merge(fields, %{
            agent_id: agent_id,
            session_id: session_id,
            kind: clock.kind,
            outcome: outcome,
            freeze_steps: steps
          })
      )
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def start_durable_fence(agent_id, session_id, version, prerequisite \\ nil),
    do: start_frozen_fence(agent_id, session_id, version, prerequisite, nil)

  def start_command_fence(agent_id, session_id, command, prerequisite \\ nil),
    do: start_frozen_fence(agent_id, session_id, command_revision(command), prerequisite, command)

  defp start_frozen_fence(agent_id, session_id, version, prerequisite, command) do
    clock = fence_clock("started")

    case session_epoch(agent_id, session_id) do
      {:ok, epoch} ->
        clock = lap(clock, :owner_ms)

        {frozen, clock} =
          freeze(clock, fn ->
            if command,
              do: PG.freeze_command(command, epoch),
              else: {:ok, PG.freeze(version, epoch)}
          end)

        context = SystemsObservability.Context.capture()

        # Workspace I/O stays at the Session owner and outside every SQL lock.
        case run_commit_prerequisite(prerequisite) do
          :ok ->
            clock = lap(clock, :prerequisite_ms)

            task =
              SystemsRuntime.TaskSupervisor.async_nolink(SalixAgent.TaskSup, fn ->
                SystemsObservability.Context.run(context, fn ->
                  clock = lap(clock, :schedule_ms)

                  result = write_frozen(frozen, command, epoch)
                  observe_fence(agent_id, session_id, result, clock)
                  result
                end)
              end)

            {:ok, task}

          error ->
            observe_fence(agent_id, session_id, error, lap(clock, :prerequisite_ms))
            error
        end

      error ->
        observe_fence(agent_id, session_id, error, lap(clock, :owner_ms))
        error
    end
  end

  def await_durable_fence(%Task{} = task) do
    case SystemsClock.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:durable_fence_failed, reason}}
    end
  end

  def commit_revision_dynamic(agent_id, session_id, version, builder, opts \\ []) do
    with :ok <- ensure_session_owner(agent_id, session_id),
         {:ok, events, extra, meta} <- normalize_dynamic_commit(builder.(version.state)),
         options = Keyword.merge(opts, extra),
         {:ok, committed} <- commit_revision(agent_id, session_id, version, events, options),
         do: {:ok, committed, dynamic_commit_meta(meta, events, options)}
  end

  def commit_dynamic(agent_id, session_id, builder, opts \\ []) do
    with {:ok, version} <- read_or_new_revision(agent_id, session_id),
         {:ok, committed, meta} <-
           commit_revision_dynamic(agent_id, session_id, version, builder, opts),
         do: {:ok, committed.state, meta}
  end

  defp normalize_dynamic_commit({:ok, events, opts, meta}) when is_list(events) and is_list(opts),
    do: {:ok, events, opts, meta}

  defp normalize_dynamic_commit({:ok, events, opts}) when is_list(events) and is_list(opts),
    do: {:ok, events, opts, nil}

  defp normalize_dynamic_commit({:ok, events}) when is_list(events), do: {:ok, events, [], nil}
  defp normalize_dynamic_commit({:error, _} = error), do: error
  defp normalize_dynamic_commit(other), do: {:error, {:invalid_dynamic_commit, other}}

  defp dynamic_commit_meta(meta, events, opts) do
    Map.merge(if(is_map(meta), do: meta, else: %{value: meta}), %{
      event_count: length(events),
      event_types: Enum.map(events, &(&1["type"] || &1[:type])),
      hwm: opts[:hwm]
    })
  end

  defp canonical_events(events),
    do: events |> Enum.map(&SalixAgent.Utf8.scrub_term/1) |> timestamp_lifecycle_events()

  defp timestamp_lifecycle_events(events) do
    now = SystemsClock.system_time(:second)

    Enum.map(events, fn event ->
      if (event["type"] || event[:type]) in @lifecycle_event_types and
           not is_integer(event["created_at"] || event[:created_at]),
         do: Map.put(event, "created_at", now),
         else: event
    end)
  end

  defp run_commit_prerequisite(nil), do: :ok

  defp run_commit_prerequisite(fun) do
    case fun.() do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:commit_prerequisite_failed, other}}
    end
  catch
    kind, reason -> {:error, {:commit_prerequisite_failed, {kind, reason}}}
  end

  defp settle(result, remaining \\ 5)

  defp settle({:error, :commit_indeterminate, pending}, remaining) when remaining > 0,
    do: settle(PG.settle(pending), remaining - 1)

  defp settle({:error, :commit_indeterminate, pending}, _),
    do: {:error, {:commit_indeterminate, pending}}

  defp settle(result, _), do: result

  defp ensure_session_owner(agent_id, session_id) do
    systems_self = SystemsRuntime.Proc.self()

    case SystemsRuntime.Registry.lookup(
           SalixAgent.Registry,
           InternalSessionActor.key(agent_id, session_id)
         ) do
      [{pid, _}] when pid == systems_self -> :ok
      _ -> {:error, :not_session_owner}
    end
  end

  defp local_runtime_epoch(agent_id, session_id) do
    systems_self = SystemsRuntime.Proc.self()

    case SystemsRuntime.Registry.lookup(
           SalixAgent.Registry,
           InternalSessionActor.key(agent_id, session_id)
         ) do
      [{pid, %{runtime_epoch: epoch}}]
      when pid == systems_self and is_integer(epoch) ->
        actor_epoch_with_fence(agent_id, epoch)

      [{pid, _}] when pid == systems_self ->
        case SalixAgent.OwnershipCell.fetch(agent_id) do
          {:ok, epoch} ->
            SystemsRuntime.Registry.update_value(
              SalixAgent.Registry,
              InternalSessionActor.key(agent_id, session_id),
              fn _ -> %{runtime_epoch: epoch} end
            )

            actor_epoch_with_fence(agent_id, epoch)

          _ ->
            {:error, :fenced}
        end

      _ ->
        case SalixAgent.OwnershipCell.fetch(agent_id) do
          {:ok, epoch} -> {:ok, epoch}
          _ -> {:error, :fenced}
        end
    end
  end

  defp actor_epoch_with_fence(agent_id, captured) do
    case SalixAgent.OwnershipCell.entry(agent_id) do
      {:ok, epoch, :fenced} when epoch >= captured -> {:error, :fenced}
      _ -> {:ok, captured}
    end
  end

  def reduce_sessions(agent_id, acc, fun), do: reduce_all(agent_id, nil, acc, fun)

  defp reduce_all(agent_id, cursor, acc, fun) do
    with {:ok, ids} <- PG.session_ids(agent_id, cursor, 128),
         {:ok, status, acc} <- reduce_ids(agent_id, ids, acc, fun) do
      if status == :halt or length(ids) < 128,
        do: {:ok, acc},
        else: reduce_all(agent_id, List.last(ids), acc, fun)
    end
  end

  def reduce_sessions_bounded(agent_id, acc, fun, opts \\ []) do
    size = Keyword.get(opts, :page_size, 100)
    objects = Keyword.get(opts, :max_objects, 1_000)
    pages = Keyword.get(opts, :max_pages, 10)

    if size in 1..1_000 and objects > 0 and pages > 0,
      do: reduce_pages(agent_id, nil, acc, fun, size, objects, pages),
      else: {:error, :invalid_scan_budget}
  end

  defp reduce_pages(_agent, _cursor, acc, _fun, _size, objects, pages)
       when objects <= 0 or pages <= 0, do: {:ok, acc, false}

  defp reduce_pages(agent, cursor, acc, fun, size, objects, pages) do
    with {:ok, ids} <- PG.session_ids(agent, cursor, min(size, objects)),
         {:ok, status, acc} <- reduce_ids(agent, ids, acc, fun) do
      cond do
        status == :halt ->
          {:ok, acc, false}

        length(ids) < min(size, objects) ->
          {:ok, acc, true}

        true ->
          reduce_pages(agent, List.last(ids), acc, fun, size, objects - length(ids), pages - 1)
      end
    end
  end

  defp reduce_ids(agent, ids, acc, fun) do
    Enum.reduce_while(ids, {:ok, :cont, acc}, fn id, {:ok, :cont, acc} ->
      case read(agent, id) do
        {:ok, state} ->
          case fun.(state, acc) do
            {:cont, next} -> {:cont, {:ok, :cont, next}}
            {:halt, next} -> {:halt, {:ok, :halt, next}}
          end

        error ->
          {:halt, error}
      end
    end)
  end

  def list(agent_id) do
    with {:ok, reversed} <-
           reduce_sessions(agent_id, [], fn state, acc -> {:cont, [state | acc]} end),
         do: {:ok, Enum.reverse(reversed)}
  end

  @spec archive_pending(String.t(), String.t(), InternalSession.t() | nil) ::
          {:ok, :archived | :nothing_to_archive} | {:error, term()}
  def archive_pending(agent_id, session_id, session \\ nil)

  # The durable target grants this transfer. A caller's resident
  # revision is not a publication precondition, and its business view is never
  # written back by the archive worker.
  def archive_pending(agent_id, session_id, _session) do
    do_seal_pending(agent_id, session_id, @max_commit_retries, nil)
  end

  # The maintenance runner captures business identity once per finite target.
  # Ordinary worker publication does not impose this conservative comparison.
  def archive_captured(%{
        agent_id: agent,
        session_id: session,
        storage_revision: value,
        target: target
      }) do
    do_seal_pending(agent, session, @max_commit_retries, %{value: value, target: target})
  end

  defp do_seal_pending(agent_id, session_id, 0, _captured),
    do: log_archive_failure(agent_id, session_id, {:error, :stale_archive})

  defp do_seal_pending(agent_id, session_id, retries, captured) do
    with {:ok, head} <- PG.archive_head(agent_id, session_id) do
      head =
        if captured do
          head
          |> Map.put(:expected_storage_revision, %{value: captured.value})
          |> Map.put(:target, min(head.target || 0, captured.target))
        else
          head
        end

      cond do
        captured && head.storage_revision != captured.value ->
          {:error, :session_changed}

        is_nil(head.target) ->
          {:ok, :nothing_to_archive}

        head.target <= head.expected_through ->
          {:ok, :nothing_to_archive}

        is_nil(captured) and not head.ready ->
          {:ok, :nothing_to_archive}

        true ->
          seal_cut(head, retries, captured)
      end
    end
  end

  defp seal_cut(head, retries, captured) do
    agent_id = head.agent_id
    session_id = head.session_id
    first = head.expected_through + 1
    cached = archive_publication_effect({:read_segment, agent_id, session_id, first})

    with true <- match?({:ok, [_ | _]}, cached) or cached == {:error, :not_found},
         {:ok, window} <- PG.archive_window(head, cached, SealedSegments.line_bytes()) do
      case InternalSession.archive_publication(
             window.state,
             SealedSegments.line_bytes(),
             fn
               {:read_segment, ^agent_id, ^session_id, ^first} ->
                 cached

               {:create_segment, _, _, _, _} = request ->
                 case archive_publication_effect(request) do
                   {:exists, landed} = result ->
                     case List.last(landed) do
                       %{seq: last} when is_integer(last) and last > window.candidate_through ->
                         {:error, :stale_archive}

                       _ ->
                         result
                     end

                   result ->
                     result
                 end

               request ->
                 archive_publication_effect(request)
             end
           ) do
        {:ok, :nothing_to_archive} = result ->
          result

        {:advance, event} ->
          with {:ok, archive} <- PG.prepare_archive(window, event) do
            case settle_archive(PG.publish_archive(archive), 5) do
              {:ok, :archived} = result ->
                result

              {:error, :stale_archive} ->
                do_seal_pending(agent_id, session_id, retries - 1, captured)

              error ->
                error
            end
          end

        {:error, {:segment_write_failed, :stale_archive}} ->
          do_seal_pending(agent_id, session_id, retries - 1, captured)

        {:error, {:segment_divergence, first}} ->
          key = Keys.agent_internal_runtime_session_segment(agent_id, session_id, first)
          log_archive_failure(agent_id, session_id, {:error, {:segment_divergence, key}})

        {:error, _} = error ->
          log_archive_failure(agent_id, session_id, error)
      end
    else
      false ->
        reason =
          case cached do
            invalid when invalid == :invalid_segment or elem(invalid, 0) == :ok ->
              {:segment_divergence,
               Keys.agent_internal_runtime_session_segment(agent_id, session_id, first)}

            {:error, reason} ->
              {:segment_read_failed, reason}
          end

        log_archive_failure(agent_id, session_id, {:error, reason})

      {:error, :stale_archive} ->
        do_seal_pending(agent_id, session_id, retries - 1, captured)

      error ->
        error
    end
  end

  defp settle_archive({:error, :archive_indeterminate, archive}, remaining) when remaining > 0,
    do: settle_archive(PG.settle_archive(archive), remaining - 1)

  defp settle_archive(result, _remaining), do: result

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
  def window_records_shaped(session) do
    archived = InternalSession.archived_through(session) || 0

    session
    |> InternalSession.query(:archive_window_records)
    |> Enum.filter(&(&1.seq > archived))
  end

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
  The COMMITTED archived range of the session's log, in seq order, as the
  immutable archived bytes hold it.

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
  @spec archived_records(String.t(), InternalSession.t()) ::
          {:ok, [ArchiveLog.log_record()]} | {:error, term()}
  def archived_records(agent_id, session) do
    archived_through = InternalSession.archived_through(session) || 0

    if (InternalSession.storage_format(session) || 1) >= 2 and archived_through > 0 do
      with {:ok, catalog} <- committed_spans(session),
           {:ok, records} <- read_spans(agent_id, session, catalog),
           :ok <- assert_committed_coverage(records, archived_through) do
        {:ok, records}
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

  * `:window` — the live window, saying whether history was archived
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
    directly. It survives as the whole-history oracle for the archive suites and as an
    operator-only escape hatch. Never call it from a request path — pages
    take `{:tail, n}` / `{:before, seq, n}`, agent surfaces take `:window`.

  Every scope reads messages as stored; archived message maps carry
  string keys (seq restored from the record), window maps atom keys.
  """
  @spec transcript(
          String.t(),
          InternalSession.t(),
          :window | :full | {:tail, pos_integer()} | {:before, pos_integer(), pos_integer()}
        ) :: {:ok, map()} | {:error, term()}
  def transcript(_agent_id, session, :window) do
    archived_through = InternalSession.archived_through(session) || 0
    messages = InternalSession.get(session, :messages)
    released = window_floor(archived_through, messages)

    {:ok,
     %{
       messages: messages,
       archived_through: archived_through,
       truncated?: released > 0,
       has_older?: released > 0
     }}
  end

  def transcript(agent_id, session, :full) do
    archived_through = InternalSession.archived_through(session) || 0

    with {:ok, records} <- archived_records(agent_id, session) do
      {:ok,
       %{
         messages:
           archived_message_maps(records) ++
             Enum.filter(InternalSession.get(session, :messages), &(&1[:seq] > archived_through)),
         archived_through: archived_through,
         truncated?: false,
         has_older?: false
       }}
    end
  end

  def transcript(agent_id, session, {:tail, n}) when is_integer(n) and n > 0 do
    archived_through = InternalSession.archived_through(session) || 0
    window = InternalSession.get(session, :messages)
    released = window_floor(archived_through, window)
    missing = n - length(window)

    if missing <= 0 or released == 0 do
      tail = Enum.take(window, -n)

      {:ok,
       %{
         messages: tail,
         archived_through: archived_through,
         truncated?: released > 0 or length(window) > n,
         has_older?: released > 0 or length(window) > n
       }}
    else
      with {:ok, archived} <-
             archived_message_page(agent_id, session, released + 1, missing) do
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
      |> InternalSession.get(:messages)
      |> Enum.filter(&(is_integer(&1[:seq]) and &1[:seq] < before_seq))

    window_page = Enum.take(window_older, -n)
    missing = n - length(window_page)

    window_floor =
      case window_page do
        [oldest | _] -> oldest[:seq]
        [] -> min(before_seq, window_floor(session) + 1)
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

  defp window_floor(session) do
    archived = InternalSession.archived_through(session) || 0
    window_floor(archived, InternalSession.get(session, :messages))
  end

  defp window_floor(archived, messages) do
    case messages do
      [%{seq: first} | _] when is_integer(first) -> min(archived, first - 1)
      _ -> archived
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
end
