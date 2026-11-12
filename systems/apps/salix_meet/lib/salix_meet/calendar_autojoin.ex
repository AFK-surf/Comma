defmodule SalixMeet.CalendarAutojoin do
  @moduledoc """
  Bounded, lease-guarded calendar discovery and meeting dispatch.

  Each configured group owns one CAS-fenced `CalendarProjection` containing
  independent fresh and recovery queues plus their shared fairness cursor.
  Production passes resolve enrollment into pure cache intents, verify the global
  lease, apply those intents in a bounded task wave, and verify again before any
  group work. Each proof uses HEAD while enough phase budget remains, otherwise
  a conditional renewal. Projection checkpoints retain the same proof ordering.

  Runtime joins are claimed through the meeting's durable join-dispatch outbox.
  The external driver runs in the bounded caller task, never in the independent
  `SalixMeet.Meeting` process.
  """

  use SystemsRuntime.Server
  require Logger

  alias SalixMeet.{
    CalendarChanges,
    CalendarEnrollmentCache,
    CalendarEnrollmentGroups,
    CalendarProjection,
    LarkBot,
    MeetingState,
    Ports,
    Runtime,
    SlackThreadIndex,
    Store
  }

  alias SalixStore.{Keys, Lease, S3}

  @scan_interval_ms 120_000
  @join_interval_ms 60_000
  @lease_key "ctl/meet/calendar_autojoin/lease.json"
  @lease_ttl_ms 300_000
  # ConfigJson caps a work wave below 180 seconds, leaving this request margin.
  @lease_request_margin_ms 120_000
  @lead_ms 120_000
  @grace_ms 300_000
  @recovery_ms 15 * 60 * 1_000
  @horizon_ms 24 * 60 * 60 * 1_000
  @min_horizon_ms 30 * 60 * 1_000
  @near_horizon_ms 3 * 60 * 60 * 1_000
  @default_bot_name "Cirno"
  @default_caption_language "Chinese, Mandarin (Simplified)"
  @max_groups_per_pass 25
  @max_events_per_group 50
  @max_concurrency 5
  @task_timeout_ms 30_000
  @max_dispatches_per_unit 25
  @max_dispatch_concurrency 25
  @enrollment_ttl_ms 60 * 60 * 1_000
  @enrollment_retry_backoff_ms 60_000
  # Members connect accounts at any time; each resolution lists a bounded
  # number of new accounts, so it may run on every pass.
  @member_enrollment_ttl_ms 60_000
  # A Feishu/Lark calendar sends no change notice: its enrollment is resolved
  # on every pass, and the resolution reads each calendar again when its
  # last read is old enough (`Salix.Bindings.LarkCalendarEnrollment`).
  @polled_enrollment_ttl_ms 60_000

  def start_link(opts \\ []) do
    SystemsRuntime.Server.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    # Trap exits so a supervisor shutdown (deploy, pod eviction) reaches terminate/2 and the global lease is
    # released instead of left to expire: without this the successor node cannot acquire the lease for up to
    # @lease_ttl_ms, which is long enough to swallow a meeting's whole T-2 join window.
    #
    # Trapping also turns every linked process exit into a mailbox message. The S3 client runs each request
    # in a `Task.async` whose normal completion is delivered here as `{:EXIT, task, :normal}` after
    # `Task.await` returns, so handle_info/2 must accept those (see the EXIT clauses below) or the first
    # store call after boot crashes the worker.
    SystemsRuntime.Proc.trap_exit(true)

    state = %{
      lease: nil,
      node: opts[:node] || to_string(node()),
      channels: opts[:channels] || configured_channels(),
      managed_channels: not Keyword.has_key?(opts, :channels),
      groups_override: opts[:groups],
      groups: opts[:groups] || [],
      resolved: %{},
      # Meeting windows each unit's projection last showed, so the join pass
      # visits units with a meeting about to start before its rotation.
      windows: %{},
      enrollment: nil,
      enrollment_ttl_ms: opts[:enrollment_ttl_ms] || @enrollment_ttl_ms,
      enrollment_retry_backoff_ms:
        opts[:enrollment_retry_backoff_ms] || @enrollment_retry_backoff_ms,
      scan_ms: opts[:scan_interval_ms] || @scan_interval_ms,
      join_ms: opts[:join_interval_ms] || @join_interval_ms,
      max_groups: opts[:max_groups_per_pass] || @max_groups_per_pass,
      max_events: opts[:max_events_per_group] || @max_events_per_group,
      max_concurrency: opts[:max_concurrency] || @max_concurrency,
      task_timeout: opts[:task_timeout_ms] || @task_timeout_ms
    }

    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :scan_tick)
    SystemsRuntime.Proc.send(SystemsRuntime.Proc.self(), :join_tick)
    {:ok, state}
  end

  # A scan tick resolves enrollments in a task of its own and scans when they
  # arrive, so the worker keeps taking join ticks while members are enrolled.
  # With fixed groups (tests, operators) it scans at once.
  @impl true
  def handle_info(:scan_tick, %{groups_override: override} = state) when is_list(override) do
    state = with_lease(state, &run_scan_pass/2)
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :scan_tick, state.scan_ms)
    {:noreply, state}
  end

  # Enrollment writes calendars and watches, so it starts only while this
  # worker holds the lease; a tick without the lease takes it first.
  def handle_info(:scan_tick, state) do
    state = state |> take_lease() |> start_enrollment()
    SystemsClock.send_after(SystemsRuntime.Proc.self(), :scan_tick, state.scan_ms)
    {:noreply, state}
  end

  def handle_info({ref, prepared}, %{enrollment: %{ref: ref}} = state) do
    SystemsRuntime.Proc.demonitor(ref, [:flush])

    state =
      %{state | enrollment: nil}
      |> Map.put(:prepared_enrollment, prepared)
      |> with_lease(&run_scan_pass/2)
      |> Map.delete(:prepared_enrollment)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{enrollment: %{ref: ref}} = state) do
    Logger.warning("calendar_autojoin enrollment task exited: #{inspect(reason)}")
    {:noreply, %{state | enrollment: nil}}
  end

  def handle_info(:join_tick, state) do
    # The join pass works from the enrollments the last scan pass resolved, so
    # enrolling members never delays a meeting's dispatch.
    state =
      state
      |> Map.put(:reuse_enrollment, true)
      |> with_lease(&run_join_pass/2)
      |> Map.put(:reuse_enrollment, false)

    SystemsClock.send_after(SystemsRuntime.Proc.self(), :join_tick, state.join_ms)
    {:noreply, state}
  end

  # Linked helper processes (the S3 client's per-request `Task.async`, `Task.async_stream` workers) report
  # their exit here because init/1 traps exits. A normal exit is the task having finished after its result
  # was already consumed; nothing to do. An abnormal exit is logged and does not take the worker down: the
  # call that owned that task has already returned or raised on its own, and crashing here would exhaust
  # the supervisor's restart budget and stop the whole meeting ingress tree. The parent supervisor's EXIT
  # never reaches this clause; gen_server handles it before dispatching to handle_info/2.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, state) do
    Logger.warning("calendar autojoin linked process exited",
      pid: inspect(pid),
      reason: inspect(reason)
    )

    {:noreply, state}
  end

  # Release is ETag-fenced (delete if_match), so a lease this process no longer owns is left untouched.
  # Best-effort by contract: on a graceful shutdown whose release succeeds the successor acquires on its
  # next tick; if the release fails, the shutdown is killed before terminate/2 runs, or the node dies hard,
  # the lease ages out under @lease_ttl_ms exactly as before. The documented deploy bound is scoped to the
  # graceful case.
  @impl true
  def terminate(_reason, %{lease: %Lease{} = lease}), do: Lease.release(lease)
  def terminate(_reason, _state), do: :ok

  # Operator/test inspection is intentionally read-only. Production workers use
  # refresh_groups_with_lease/2 so no durable cache mutation can happen without
  # a post-resolution remote ownership proof.
  defp refresh_groups(state) do
    started_at = SystemsClock.monotonic_time()
    {state, actions, outcome} = prepare_enrollment(state)
    emit_enrollment_telemetry(started_at, outcome)

    case actions do
      :preserve ->
        state

      actions ->
        optimistic_results = Enum.map(actions, fn _action -> {:ok, :ok} end)
        finalize_enrollment_actions(state, actions, optimistic_results)
    end
  end

  defp refresh_groups_with_lease(%{groups_override: override} = state, lease)
       when is_list(override),
       do: {:ok, %{state | groups: override}, lease}

  defp refresh_groups_with_lease(state, lease) do
    started_at = SystemsClock.monotonic_time()

    {prepared_state, actions, outcome} =
      case Map.get(state, :prepared_enrollment) do
        {prepared, actions, outcome} -> {merge_prepared(state, prepared), actions, outcome}
        nil -> prepare_enrollment(state)
      end

    case renew_lease(lease, state) do
      {:ok, cache_lease} ->
        refreshed_state = apply_enrollment_actions(prepared_state, actions)

        case renew_lease(cache_lease, state) do
          {:ok, work_lease} ->
            emit_enrollment_telemetry(started_at, outcome)
            {:ok, refreshed_state, work_lease}

          {:error, reason} ->
            emit_enrollment_telemetry(started_at, enrollment_lease_outcome(reason))
            {:error, {:calendar_enrollment_post_write_lease, reason}, state}
        end

      {:error, reason} ->
        emit_enrollment_telemetry(started_at, enrollment_lease_outcome(reason))
        {:error, {:calendar_enrollment_pre_write_lease, reason}, state}
    end
  end

  # The enrollment task reads a snapshot of the worker's state; only what it
  # resolved is taken back.
  defp merge_prepared(state, prepared),
    do: Map.merge(state, Map.take(prepared, [:groups, :channels, :resolved]))

  defp take_lease(%{lease: nil} = state) do
    case Lease.acquire(@lease_key, state.node, ttl_ms: @lease_ttl_ms) do
      {:ok, lease} ->
        %{state | lease: lease}

      {:error, {:held_by, _, _}} ->
        state

      {:error, reason} ->
        Logger.warning("calendar_autojoin lease acquire failed: #{inspect(reason)}")
        state
    end
  end

  defp take_lease(state), do: state

  defp start_enrollment(%{lease: nil} = state), do: state
  defp start_enrollment(%{enrollment: %{}} = state), do: state

  defp start_enrollment(state) do
    snapshot = Map.drop(state, [:lease])
    task = Task.async(fn -> prepare_enrollment(snapshot) end)
    %{state | enrollment: %{ref: task.ref}}
  end

  defp enrollment_lease_outcome(:lost), do: "conflict"
  defp enrollment_lease_outcome(reason) when reason in [:timeout, :unavailable], do: "unavailable"
  defp enrollment_lease_outcome({:http, status}) when status >= 500, do: "unavailable"
  defp enrollment_lease_outcome({:http, status, _body}) when status >= 500, do: "unavailable"
  defp enrollment_lease_outcome(_reason), do: "error"

  defp emit_enrollment_telemetry(started_at, outcome) do
    SystemsRuntime.Telemetry.execute(
      [:salix, :operation, :stop],
      %{duration: SystemsClock.monotonic_time() - started_at},
      %{
        component: "salix_meet",
        operation: "calendar_enrollment",
        surface: "system",
        outcome: outcome
      }
    )
  end

  defp prepare_enrollment(state) do
    case current_channels(state) do
      {:ok, channels} -> prepare_current_enrollment(%{state | channels: channels})
      {:error, _reason} -> {%{state | groups: [], channels: []}, :preserve, "unavailable"}
    end
  end

  defp current_channels(%{managed_channels: true}), do: SalixMeet.CalendarConfiguration.entries()
  defp current_channels(state), do: {:ok, state.channels}

  defp prepare_current_enrollment(state) do
    now = now_ms()

    case Ports.CalendarEnrollment.resolve_identities(state.channels) do
      {:ok, identities} when is_map(identities) ->
        candidates = enrollment_candidates(state.channels, identities, state.resolved)
        duplicate_groups = duplicate_enrollment_groups(candidates)

        Enum.each(duplicate_groups, fn group_id ->
          Logger.warning(
            "calendar_autojoin group #{group_id} has multiple configured targets; skipping all before target resolution (fail-closed)"
          )
        end)

        # Each enrollment resolves in its own task with the pass's task
        # timeout: a slow account (listing calendars, setting up watches, a
        # first sync) keeps what its enrollment had and is retried on a later
        # pass, and cannot hold up the other enrollments or the meetings.
        actions =
          candidates
          |> bounded_map(
            Map.get(state, :max_concurrency, @max_concurrency),
            Map.get(state, :task_timeout, @task_timeout_ms),
            fn candidate ->
              prepare_enrollment_candidate(
                candidate,
                duplicate_groups,
                now,
                state.enrollment_ttl_ms,
                state.enrollment_retry_backoff_ms
              )
            end
          )
          |> Enum.zip(candidates)
          |> Enum.map(fn
            {{:ok, action}, _candidate} ->
              action

            {{:exit, reason}, candidate} ->
              Logger.warning(
                "calendar_autojoin enrollment #{inspect(candidate.connect_id)}: #{inspect({:task_exit, reason})}"
              )

              if is_map(candidate.cached),
                do:
                  {:activate, candidate,
                   defer_enrollment_retry(
                     candidate.cached,
                     now,
                     state.enrollment_ttl_ms,
                     state.enrollment_retry_backoff_ms
                   )},
                else: :drop
          end)

        {state, actions, "ok"}

      {:error, reason} ->
        Logger.warning("calendar_autojoin identity refresh failed: #{inspect(reason)}")

        if transient_identity_refresh_error?(reason) do
          {retain_in_memory_groups(state), :preserve, "unavailable"}
        else
          {%{state | groups: []}, :preserve, "rejected"}
        end

      other ->
        Logger.warning("calendar_autojoin identity refresh invalid: #{inspect(other)}")
        {%{state | groups: []}, :preserve, "error"}
    end
  end

  defp enrollment_candidates(entries, identities, memory) do
    Enum.map(entries, fn entry ->
      connect_id = trim(entry["connect_id"])
      cached = read_enrollment_cache(entry, memory, nil)

      case identities[connect_id] do
        {:ok, identity} when is_map(identity) ->
          %{
            entry: entry,
            connect_id: connect_id,
            identity: identity,
            cached:
              if(
                is_map(cached) and
                  CalendarEnrollmentCache.identity_matches?(cached, identity),
                do: cached,
                else: nil
              ),
            error: nil
          }

        {:error, reason} ->
          %{
            entry: entry,
            connect_id: connect_id,
            identity: nil,
            cached: cached,
            error: reason
          }

        other ->
          %{
            entry: entry,
            connect_id: connect_id,
            identity: nil,
            cached: cached,
            error: {:invalid_connect_identity, other}
          }
      end
    end)
  end

  defp duplicate_enrollment_groups(candidates) do
    candidates
    |> Enum.map(&candidate_identity/1)
    |> CalendarEnrollmentGroups.duplicate_group_ids()
  end

  defp candidate_identity(%{identity: identity}) when is_map(identity), do: identity
  defp candidate_identity(%{cached: %{identity: identity}}) when is_map(identity), do: identity
  defp candidate_identity(_candidate), do: %{}

  defp candidate_group_id(candidate),
    do: candidate |> candidate_identity() |> CalendarEnrollmentGroups.group_id()

  defp prepare_enrollment_candidate(
         %{identity: nil} = candidate,
         _duplicates,
         _now,
         _ttl,
         _retry_backoff
       ) do
    Logger.warning(
      "calendar_autojoin enrollment #{inspect(candidate.connect_id)}: #{inspect(candidate.error)}"
    )

    emit_meet_operation("calendar_enrollment_group", "dropped")
    {:delete, candidate}
  end

  defp prepare_enrollment_candidate(
         candidate,
         duplicates,
         now,
         ttl,
         retry_backoff
       ) do
    if MapSet.member?(duplicates, candidate_group_id(candidate)) do
      :drop
    else
      prepare_enrollment_resolution(candidate, now, ttl, retry_backoff)
    end
  end

  defp prepare_enrollment_resolution(candidate, now, ttl, retry_backoff) do
    ttl =
      cond do
        members?(candidate.entry) -> min(ttl, @member_enrollment_ttl_ms)
        polled?(candidate) -> min(ttl, @polled_enrollment_ttl_ms)
        true -> ttl
      end

    if enrollment_cache_deferred?(candidate.cached, now, ttl) do
      {:activate, candidate, candidate.cached}
    else
      prepare_enrollment_target(candidate, now, ttl, retry_backoff)
    end
  end

  defp prepare_enrollment_target(candidate, now, ttl, retry_backoff) do
    case Ports.CalendarEnrollment.resolve(resolution_entry(candidate), candidate.identity) do
      {:ok, group} ->
        group = CalendarEnrollmentCache.sanitize_group(group)
        next = %{group: group, identity: candidate.identity, at: now}
        {:put, candidate, next, now, ttl, retry_backoff}

      {:error, reason} ->
        Logger.warning(
          "calendar_autojoin enrollment #{inspect(candidate.connect_id)}: #{inspect(reason)}"
        )

        backoff = if source_maintenance?(reason), do: ttl, else: retry_backoff

        if is_map(candidate.cached) and retain_enrollment_cache?(reason) do
          {:activate, candidate, defer_enrollment_retry(candidate.cached, now, ttl, backoff)}
        else
          emit_meet_operation("calendar_enrollment_group", "dropped")
          {:delete, candidate}
        end

      other ->
        Logger.warning(
          "calendar_autojoin enrollment #{inspect(candidate.connect_id)}: #{inspect(other)}"
        )

        emit_meet_operation("calendar_enrollment_group", "dropped")
        {:delete, candidate}
    end
  end

  # A members' resolution starts from the units it already has, so a pass
  # lists only new or long-unlisted accounts.
  defp resolution_entry(%{entry: entry, cached: %{group: group}}) when is_map(group) do
    if members?(entry), do: Map.put(entry, "enrolled", group), else: entry
  end

  defp resolution_entry(%{entry: entry}), do: entry

  defp members?(entry), do: is_map(entry) and entry["calendar_scope"] == "members"

  # A Feishu/Lark connect reading its own calendars (not Google's).
  defp polled?(%{entry: entry, identity: identity}),
    do:
      is_map(entry) and entry["mode"] in ["prepare", "join"] and
        entry["calendar_source"] != "google" and is_map(identity) and
        identity["provider"] in ["feishu", "lark"]

  defp polled?(_candidate), do: false

  defp apply_enrollment_actions(state, :preserve), do: state

  defp apply_enrollment_actions(state, actions) do
    results =
      bounded_map(actions, state.max_concurrency, state.task_timeout, &apply_enrollment_action/1)

    finalize_enrollment_actions(state, actions, results)
  end

  defp apply_enrollment_action({:put, candidate, next, now, _ttl, _retry_backoff}) do
    with :ok <- CalendarEnrollmentCache.put(candidate.entry, candidate.identity, next.group, now) do
      delete_removed_member_projections(candidate.cached, next.group)
    end
  end

  defp apply_enrollment_action({:delete, candidate}),
    do: CalendarEnrollmentCache.delete(candidate.entry)

  defp apply_enrollment_action(_action), do: :ok

  # A disconnected member's projection would still name meetings that another
  # member's calendar should now own (see claim_member_scope/5).
  defp delete_removed_member_projections(%{group: previous}, next) do
    kept = MapSet.new(member_units(next), &unit_key/1)

    previous
    |> member_units()
    |> Enum.reject(&MapSet.member?(kept, unit_key(&1)))
    |> Enum.each(fn unit ->
      with {:ok, key} <- CalendarProjection.projection_key(unit), do: S3.delete(key)
    end)

    :ok
  end

  defp delete_removed_member_projections(_cached, _next), do: :ok

  defp finalize_enrollment_actions(state, actions, results) do
    {resolved, groups} =
      actions
      |> Enum.zip(results)
      |> Enum.reduce({%{}, []}, fn
        {{:activate, candidate, cached}, _result}, acc ->
          activate_enrollment(candidate.entry, cached, acc)

        {{:put, candidate, next, now, ttl, retry_backoff}, result}, acc ->
          case enrollment_cache_result(result) do
            :ok ->
              activate_enrollment(candidate.entry, next, acc)

            {:error, reason} ->
              Logger.warning(
                "calendar_autojoin enrollment cache #{inspect(candidate.connect_id)}: #{inspect(reason)}"
              )

              if is_map(candidate.cached) do
                candidate.cached
                |> defer_enrollment_retry(now, ttl, retry_backoff)
                |> then(&activate_enrollment(candidate.entry, &1, acc))
              else
                acc
              end
          end

        {{:delete, _candidate}, result}, acc ->
          case enrollment_cache_result(result) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("calendar_autojoin cache delete failed: #{inspect(reason)}")
          end

          acc

        {_drop, _result}, acc ->
          acc
      end)

    %{state | resolved: resolved, groups: groups |> Enum.reverse() |> dedup_groups()}
  end

  defp activate_enrollment(entry, cached, {resolved, groups}) do
    key = CalendarEnrollmentCache.fingerprint(entry)
    {Map.put(resolved, key, cached), Enum.reverse(scan_units(cached.group)) ++ groups}
  end

  # A Group that enrolls its members' own calendars is scanned and joined per
  # member calendar. Each unit carries the Group's settings.
  defp scan_units(%{"calendar_scope" => "members"} = group) do
    group
    |> member_units()
    |> Enum.filter(&(List.wrap(&1["calendars"]) != []))
  end

  defp scan_units(group), do: [group]

  defp member_units(%{"calendar_scope" => "members", "units" => units} = group)
       when is_list(units) do
    base =
      group
      |> Map.drop(["units", "calendars", "calendar_id"])
      |> Map.put(
        "member_emails",
        units |> Enum.map(& &1["account_email"]) |> Enum.filter(&is_binary/1)
      )

    Enum.map(units, fn unit ->
      Map.merge(base, %{
        "calendar_id" => unit["calendar_id"],
        "calendars" => List.wrap(unit["calendars"]),
        "member_account_id" => unit["account_id"],
        "account_email" => unit["account_email"]
      })
    end)
  end

  defp member_units(_group), do: []

  defp enrollment_cache_result({:ok, :ok}), do: :ok
  defp enrollment_cache_result({:ok, {:error, reason}}), do: {:error, reason}
  defp enrollment_cache_result({:exit, reason}), do: {:error, {:task_exit, reason}}
  defp enrollment_cache_result(other), do: {:error, {:invalid_result, other}}

  defp enrollment_cache_deferred?(cached, now, ttl) when is_map(cached) do
    resolved_at = cached[:at]
    retry_at = cached[:retry_at]

    fresh? =
      is_integer(resolved_at) and now - resolved_at >= 0 and now - resolved_at < ttl

    retry_deferred? =
      ttl > 0 and is_integer(retry_at) and retry_at > now

    fresh? or retry_deferred?
  end

  defp enrollment_cache_deferred?(_cached, _now, _ttl), do: false

  defp defer_enrollment_retry(cached, _now, 0, _retry_backoff),
    do: Map.delete(cached, :retry_at)

  defp defer_enrollment_retry(cached, now, _ttl, retry_backoff)
       when is_integer(retry_backoff) and retry_backoff > 0,
       do: Map.put(cached, :retry_at, now + retry_backoff)

  defp defer_enrollment_retry(cached, _now, _ttl, _retry_backoff),
    do: Map.delete(cached, :retry_at)

  defp retain_enrollment_cache?(:transient), do: true
  defp retain_enrollment_cache?({:calendar_not_found, _name}), do: true
  defp retain_enrollment_cache?({:channel_not_found, _name}), do: true
  defp retain_enrollment_cache?({:calendar_enrollment_account, _reason}), do: true
  defp retain_enrollment_cache?({:calendar_enrollment_list, _reason}), do: true
  defp retain_enrollment_cache?({:channel_resolve, _reason}), do: true
  defp retain_enrollment_cache?(reason), do: source_maintenance?(reason)

  defp source_maintenance?(:source_operation_timeout), do: true
  defp source_maintenance?({:calendar_source_maintenance, _}), do: true
  defp source_maintenance?(_reason), do: false

  defp transient_identity_refresh_error?(:transient), do: true

  defp transient_identity_refresh_error?(
         {:calendar_enrollment_connect_lookup, {:ambiguous, _reason}}
       ),
       do: true

  defp transient_identity_refresh_error?({:calendar_enrollment_connect_lookup, reason})
       when reason in [:timeout, :unavailable],
       do: true

  defp transient_identity_refresh_error?({:calendar_enrollment_connect_lookup, {:http, status}})
       when status in [408, 425, 429] or status >= 500,
       do: true

  defp transient_identity_refresh_error?(
         {:calendar_enrollment_connect_lookup, {:http, status, _body}}
       )
       when status in [408, 425, 429] or status >= 500,
       do: true

  defp transient_identity_refresh_error?(_reason), do: false

  defp read_enrollment_cache(entry, memory, expected_identity) do
    key = CalendarEnrollmentCache.fingerprint(entry)

    case memory[key] do
      cached when is_map(cached) ->
        if is_nil(expected_identity) or
             CalendarEnrollmentCache.identity_matches?(cached, expected_identity),
           do: cached,
           else: load_enrollment_cache(entry, expected_identity)

      _ ->
        load_enrollment_cache(entry, expected_identity)
    end
  end

  defp load_enrollment_cache(entry, expected_identity) do
    case CalendarEnrollmentCache.load(entry, expected_identity) do
      {:ok, cached} -> cached
      _ -> nil
    end
  end

  defp retain_in_memory_groups(state) do
    {resolved, groups} =
      Enum.reduce(state.channels, {%{}, []}, fn entry, {cache, groups} ->
        key = CalendarEnrollmentCache.fingerprint(entry)

        case state.resolved[key] do
          nil ->
            {cache, groups}

          cached when is_map(cached) ->
            {Map.put(cache, key, cached), Enum.reverse(scan_units(cached.group)) ++ groups}

          _other ->
            {cache, groups}
        end
      end)

    %{state | resolved: resolved, groups: groups |> Enum.reverse() |> dedup_groups()}
  end

  defp with_lease(%{lease: nil} = state, work) do
    case Lease.acquire(@lease_key, state.node, ttl_ms: @lease_ttl_ms) do
      {:ok, lease} ->
        finish_leased_work(state, lease, work)

      {:error, {:held_by, _, _}} ->
        state

      {:error, reason} ->
        Logger.warning("calendar_autojoin lease acquire failed: #{inspect(reason)}")
        state
    end
  end

  defp with_lease(%{lease: lease} = state, work) do
    case renew_lease(lease, state) do
      {:ok, renewed} ->
        finish_leased_work(state, renewed, work)

      {:error, reason} ->
        Logger.warning("calendar_autojoin lease renew failed: #{inspect(reason)}")
        %{state | lease: nil}
    end
  end

  defp renew_lease(lease, state) do
    groups = min(max(length(state.groups), length(state.channels)), state.max_groups)
    waves = div(groups + state.max_concurrency - 1, state.max_concurrency)
    min_remaining = waves * state.task_timeout + @lease_request_margin_ms

    Lease.renew_if_due(lease,
      ttl_ms: @lease_ttl_ms,
      min_remaining_ms: min_remaining
    )
  end

  defp finish_leased_work(%{reuse_enrollment: true} = state, lease, work),
    do: finish_group_work(state, lease, work)

  defp finish_leased_work(state, lease, work) do
    case refresh_groups_with_lease(state, lease) do
      {:ok, refreshed_state, work_lease} ->
        finish_group_work(refreshed_state, work_lease, work)

      {:error, reason, refreshed_state} ->
        Logger.warning("calendar_autojoin enrollment checkpoint failed: #{inspect(reason)}")
        %{refreshed_state | lease: nil}
    end
  end

  defp finish_group_work(state, lease, work) do
    case work.(state, lease) do
      {:ok, work_lease, work_result} ->
        with {:ok, checkpoint_lease} <- renew_lease(work_lease, state),
             :ok <- checkpoint_projection_intents(work_result.items, state),
             {:ok, cursor_lease} <- renew_lease(checkpoint_lease, state),
             :ok <- checkpoint_pass_cursor(work_result.pass_cursor, state),
             :ok <- clear_scanned_changes(work_result),
             {:ok, final_lease} <- renew_lease(cursor_lease, state) do
          %{state | lease: final_lease, windows: next_windows(state, work_result)}
        else
          {:error, reason} ->
            Logger.warning("calendar_autojoin checkpoint failed: #{inspect(reason)}")
            %{state | lease: nil}
        end

      {:error, reason} ->
        Logger.warning("calendar_autojoin pass preparation failed: #{inspect(reason)}")
        %{state | lease: nil}
    end
  end

  # A pass scans the calendars whose sources reported changes first, then
  # continues the rotation, so a meeting added shortly before it starts is
  # indexed on the next pass however many calendars the deployment scans.
  defp run_scan_pass(state, lease) do
    changes = CalendarChanges.read(state.max_groups)
    {changed, rest} = Enum.split_with(state.groups, &Map.has_key?(changes, change_key(&1)))
    # A quarter of the pass stays with the rotation, so frequent changes in
    # some calendars cannot keep the others from being scanned.
    changed =
      changed
      |> Enum.sort_by(&group_key/1)
      |> Enum.take(max(state.max_groups - div(state.max_groups, 4), 1))
      |> Enum.map(&Map.put(&1, "near_first", true))

    with {:ok, rotated, pass_cursor} <-
           cursor_batch(
             rest,
             Keys.ctl_meet_calendar_scan_cursor(),
             state.max_groups - length(changed)
           ),
         {:ok, work_lease} <- renew_lease(lease, state) do
      groups = changed ++ rotated

      items =
        prepare_scan_groups(groups,
          now: now_ms(),
          max_events_per_group: state.max_events,
          max_concurrency: state.max_concurrency,
          task_timeout_ms: state.task_timeout,
          lease_epoch: work_lease.epoch
        )

      {:ok, work_lease,
       %{
         pass_cursor: pass_cursor,
         items: items,
         groups: groups,
         changes: scanned_changes(changes, state.groups, groups, items)
       }}
    end
  end

  # Units with a meeting inside its join window come first, one unit for each
  # such meeting before the other units that show it; the rotation fills the
  # rest of the pass. Meetings that start together are dispatched together.
  defp run_join_pass(state, lease) do
    now = now_ms()
    {due, rest} = Enum.split_with(state.groups, &unit_due?(state.windows, &1, now))

    due =
      due
      |> Enum.sort_by(&{next_window_start(state.windows, &1, now), group_key(&1)})
      |> one_unit_per_meeting(state.windows, now)
      |> Enum.take(state.max_groups)

    with {:ok, rotated, pass_cursor} <-
           cursor_batch(
             rest,
             Keys.ctl_meet_calendar_join_cursor(),
             state.max_groups - length(due)
           ),
         {:ok, work_lease} <- renew_lease(lease, state) do
      groups = due ++ rotated

      items =
        prepare_join_groups(groups,
          now: now,
          max_events_per_group: state.max_events,
          max_concurrency: state.max_concurrency,
          task_timeout_ms: state.task_timeout,
          lease_epoch: work_lease.epoch
        )

      {:ok, work_lease, %{pass_cursor: pass_cursor, items: items, groups: groups}}
    end
  end

  defp change_key(group), do: {group_id(group), trim(group["calendar_id"])}

  # A mark is cleared when its calendar was scanned, or when no enrolled unit
  # has that calendar any more.
  defp scanned_changes(changes, enrolled, groups, items) do
    scanned =
      groups
      |> Enum.zip(items)
      |> Enum.filter(fn {_group, item} -> not is_nil(item.intent) end)
      |> MapSet.new(fn {group, _item} -> change_key(group) end)

    known = MapSet.new(enrolled, &change_key/1)

    Map.filter(changes, fn {key, _etag} ->
      MapSet.member?(scanned, key) or not MapSet.member?(known, key)
    end)
  end

  defp clear_scanned_changes(%{changes: changes}) do
    Enum.each(changes, fn {key, etag} -> CalendarChanges.clear(key, etag) end)
    :ok
  end

  defp clear_scanned_changes(_work_result), do: :ok

  defp next_windows(state, %{groups: groups, items: items}) do
    current = MapSet.new(state.groups, &unit_key/1)

    groups
    |> Enum.zip(items)
    |> Enum.reduce(Map.take(state.windows, MapSet.to_list(current)), fn {group, item}, acc ->
      case item_windows(item) do
        nil -> acc
        windows -> Map.put(acc, unit_key(group), windows)
      end
    end)
  end

  defp next_windows(state, _work_result), do: state.windows

  defp item_windows(%{windows: windows}) when is_list(windows), do: windows

  defp item_windows(%{intent: %CalendarProjection{} = projection}),
    do: projection_windows(projection)

  defp item_windows(_item), do: nil

  defp projection_windows(%CalendarProjection{fresh: fresh, recovery: recovery}) do
    for %{"meeting_id" => mid, "event" => %{"start_ms" => start_ms} = event} <- fresh ++ recovery,
        is_integer(start_ms) and is_binary(event["meet_url"]) do
      end_ms = if is_integer(event["end_ms"]), do: event["end_ms"], else: start_ms + 3_600_000
      {start_ms, max(end_ms, start_ms + @grace_ms), mid}
    end
  end

  defp due_windows(windows, group, now),
    do:
      windows
      |> Map.get(unit_key(group), [])
      |> Enum.filter(fn {start_ms, end_ms, _mid} ->
        now >= start_ms - @lead_ms and now <= end_ms
      end)

  defp unit_due?(windows, group, now), do: due_windows(windows, group, now) != []

  defp next_window_start(windows, group, now) do
    windows
    |> due_windows(group, now)
    |> Enum.map(&elem(&1, 0))
    |> Enum.min(fn -> now end)
  end

  defp one_unit_per_meeting(units, windows, now) do
    {first, others, _seen} =
      Enum.reduce(units, {[], [], MapSet.new()}, fn unit, {first, others, seen} ->
        mids = windows |> due_windows(unit, now) |> MapSet.new(&elem(&1, 2))

        if MapSet.subset?(mids, seen),
          do: {first, [unit | others], seen},
          else: {[unit | first], others, MapSet.union(seen, mids)}
      end)

    Enum.reverse(first) ++ Enum.reverse(others)
  end

  @doc "Scan a bounded set of groups and checkpoint one projection per group."
  @spec scan_once([map()], keyword()) :: [{String.t(), non_neg_integer() | tuple()}]
  def scan_once(groups, opts \\ []) do
    items = prepare_scan_groups(groups, opts)
    checkpoint_public_items(items, opts)
  end

  defp prepare_scan_groups(groups, opts) do
    now = opts[:now] || now_ms()
    max_groups = positive(opts[:max_groups_per_pass], length(groups))
    max_events = positive(opts[:max_events_per_group], @max_events_per_group)
    concurrency = positive(opts[:max_concurrency], 1)
    timeout = positive(opts[:task_timeout_ms], @task_timeout_ms)
    lease_epoch = non_negative(opts[:lease_epoch], 0)
    groups = groups |> List.wrap() |> Enum.take(max_groups)

    groups
    |> bounded_map(concurrency, timeout, fn group ->
      prepare_scan_group(group, now, max_events, lease_epoch)
    end)
    |> Enum.zip(groups)
    |> Enum.map(fn
      {{:ok, item}, _group} ->
        item

      {{:exit, reason}, group} ->
        Logger.warning("calendar_autojoin scan task exit #{group_id(group)}: #{inspect(reason)}")
        emit_meet_operation("calendar_scan_group", task_exit_outcome(reason))
        error_item(group, {:task_exit, reason})
    end)
  end

  # A member's calendar is read one page of calendar items per pass,
  # continuing after the stored item on the next pass and starting over after
  # the last page, so each pass's work is bounded however many meetings the
  # calendar holds. The projection keeps the meetings outside the page it read
  # and leaves out the ones already dispatched; only a meeting missing from
  # its own page counts as gone. Other calendars are read whole, as before.
  defp scan_request(%{"calendar_scope" => "members"} = group, projection, max_events),
    do:
      Map.merge(group, %{
        "max_events" => max_events,
        "paged" => true,
        "page_after" => projection.page_after
      })

  defp scan_request(group, _projection, max_events), do: Map.put(group, "max_events", max_events)

  # A member calendar that just changed also reads the next few hours whole,
  # so a meeting created to start now joins without waiting for its page.
  defp near_events(
         %{"calendar_scope" => "members", "near_first" => true} = group,
         max_events,
         now
       ) do
    case list_occurrences(Map.put(group, "max_events", max_events), now, @near_horizon_ms) do
      {:ok, events} when is_list(events) -> {:ok, events}
      _ -> {:ok, []}
    end
  end

  defp near_events(_group, _max_events, _now), do: {:ok, []}

  defp read_page({:ok, events}, group, _projection, max_events, _now, _near)
       when is_list(events),
       do: {:ok, keep_events(group, events, max_events), MapSet.new(), nil}

  defp read_page({:ok, events, next}, group, projection, max_events, now, near)
       when is_list(events) do
    after_item = projection.page_after

    outside =
      for %{"event" => event} <- projection.fresh,
          item = event["calendar_item_id"] || "",
          not ((is_nil(after_item) or item > after_item) and (is_nil(next) or item <= next)),
          do: event

    seen = Enum.uniq_by(near ++ events ++ outside, &meeting_id(group, &1))
    present = MapSet.new(seen, &meeting_id(group, &1))

    kept =
      seen
      |> Enum.reject(&dispatched?(group, &1, now))
      |> then(&keep_events(group, &1, max_events))

    {:ok, kept, present, next}
  end

  defp read_page(other, _group, _projection, _max_events, _now, _near), do: other

  # The projection holds at most max_events meetings, nearest first. A meeting
  # that is only prepared (a link that is not joined) takes a place only when
  # no joinable one needs it, so prepare-only meetings can never push a
  # joinable meeting out of joining. A placeholder keeps its place too: it
  # stands for a meeting whose preparation failed and must not look gone.
  defp keep_events(group, events, max_events) do
    {first, rest} =
      events
      |> Enum.sort_by(&{&1["start_ms"], &1["event_id"]})
      |> Enum.split_with(
        &(joinable_url?(group, &1["meet_url"]) or is_binary(&1["prepare_error"]))
      )

    (first ++ rest)
    |> Enum.take(max_events)
    |> Enum.sort_by(&{&1["start_ms"], &1["event_id"]})
  end

  defp dispatched?(group, event, now) do
    case resolve_dispatch_identity([meeting_id(group, event)]) do
      {:ok, mid, _doc} -> not dispatch_needed?(mid, now)
      _ -> false
    end
  end

  # A calendar with more events in the horizon than one query returns is read
  # over a shorter horizon instead of failing: the nearest meetings are the
  # ones to join, and later ones come into range on later passes.
  defp list_occurrences(request, now, horizon_ms) do
    case Ports.CalendarOccurrences.list(request, now, now + horizon_ms) do
      {:error, :occurrence_limit_exceeded} when horizon_ms > @min_horizon_ms ->
        list_occurrences(request, now, max(div(horizon_ms, 2), @min_horizon_ms))

      result ->
        result
    end
  end

  defp prepare_scan_group(group, now, max_events, lease_epoch) do
    started_at = SystemsClock.monotonic_time()

    with {:ok, projection} <-
           CalendarProjection.load(group,
             lease_epoch: lease_epoch,
             now: now,
             max_events: max_events
           ),
         request = scan_request(group, projection, max_events),
         {:ok, near} <- near_events(group, max_events, now),
         {:ok, fresh_events, present_ids, page_after} <-
           read_page(
             list_occurrences(request, now, @horizon_ms),
             group,
             projection,
             max_events,
             now,
             near
           ) do
      fresh_ids = MapSet.union(MapSet.new(fresh_events, &meeting_id(group, &1)), present_ids)
      recovery_results = recovery_results(projection, group, fresh_ids, now)

      {:ok, updated, %{partial_errors: partial_errors}} =
        CalendarProjection.reconcile(projection, fresh_events, recovery_results,
          max_events: max_events,
          now: now,
          present_ids: present_ids
        )

      updated = %{updated | page_after: page_after}

      count = length(updated.fresh) + length(updated.recovery)

      # Placeholder entries are isolated single-event preparation failures:
      # present in the fresh set (so reconciliation cannot misread the event
      # as gone) but never joinable. Surface them exactly like recovery
      # partial errors.
      placeholder_errors =
        for event <- fresh_events, is_binary(event["prepare_error"]) do
          %{
            meeting_id: meeting_id(group, event),
            reason: {:prepare_error, event["prepare_error"]}
          }
        end

      public =
        case partial_errors ++ placeholder_errors do
          [] ->
            emit_meet_operation("calendar_scan_group", "ok", started_at)
            {group_id(group), count}

          errors ->
            Logger.warning(
              "calendar_autojoin scan partial #{group_id(group)}: #{length(errors)} candidate error(s)"
            )

            emit_meet_operation("calendar_scan_group", "partial", started_at)
            {group_id(group), {:partial, count, errors}}
        end

      %{group_id: group_id(group), public: public, intent: updated}
    else
      {:ok, other} ->
        Logger.warning(
          "calendar_autojoin scan #{group_id(group)}: #{inspect({:invalid_calendar_result, other})}"
        )

        emit_meet_operation("calendar_scan_group", "error", started_at)
        error_item(group, {:invalid_calendar_result, other})

      {:error, reason} ->
        Logger.warning("calendar_autojoin scan #{group_id(group)}: #{inspect(reason)}")
        emit_meet_operation("calendar_scan_group", "error", started_at)
        error_item(group, reason)

      other ->
        Logger.warning("calendar_autojoin scan #{group_id(group)}: #{inspect(other)}")
        emit_meet_operation("calendar_scan_group", "error", started_at)
        error_item(group, {:invalid_calendar_result, other})
    end
  end

  defp recovery_results(projection, group, fresh_ids, now) do
    (projection.fresh ++ projection.recovery)
    |> Enum.reject(&MapSet.member?(fresh_ids, meeting_id(group, &1["event"])))
    |> Enum.reduce(%{}, fn entry, results ->
      event = entry["event"]

      Map.put(
        results,
        entry["meeting_id"],
        recovery_event_decision(
          group,
          event,
          CalendarProjection.dispatch_meeting_ids(projection, entry),
          now
        )
      )
    end)
  end

  defp recovery_event_decision(group, event, dispatch_mids, now) do
    case resolve_dispatch_identity(dispatch_mids) do
      {:ok, _mid, %{"join_requested_at" => requested_at}} when is_integer(requested_at) ->
        {:drop, :join_already_claimed}

      {:ok, mid, doc} when is_map(doc) ->
        cond do
          recovery_open?(doc, now) -> revalidate_recovery(group, event, mid, now)
          recovery_abandoned?(doc) -> {:drop, :already_abandoned}
          true -> abandon_recovery_decision(group, mid, event, now, :recovery_deadline_exceeded)
        end

      {:ok, _mid, nil} ->
        {:drop, :meeting_not_found}

      {:error, reason} ->
        {:retain, event, {:meeting_state, dispatch_mids, reason}}
    end
  end

  defp revalidate_recovery(group, event, mid, now) do
    case Ports.CalendarOccurrences.revalidate(group, event) do
      :ok ->
        {:retain, event, nil}

      {:error, reason} ->
        if terminal_recovery_revocation?(reason) do
          abandon_recovery_decision(group, mid, event, now, reason)
        else
          {:retain, event, {:calendar_revalidation, mid, reason}}
        end

      other ->
        {:retain, event, {:calendar_revalidation, mid, {:invalid_result, other}}}
    end
  end

  # One member's copy leaving (a decline, a removed invitee) says nothing about
  # the other members' copies of the same meeting: drop it from this calendar
  # only and leave the shared meeting to them.
  defp abandon_recovery_decision(%{"calendar_scope" => "members"}, _mid, _event, _now, reason),
    do: {:drop, reason}

  defp abandon_recovery_decision(_group, mid, event, now, reason) do
    case abandon_recovery(mid, now, "calendar event revalidation failed: #{inspect(reason)}") do
      :ok -> {:drop, reason}
      {:error, :join_already_claimed} -> {:drop, :join_already_claimed}
      {:error, error} -> {:retain, event, {:abandon, mid, error}}
    end
  end

  defp terminal_recovery_revocation?(:calendar_event_cancelled), do: true
  defp terminal_recovery_revocation?(_reason), do: false

  defp deferred_join_revalidation?(reason),
    do:
      reason in [
        :not_found,
        :calendar_connected_account_not_found,
        :calendar_event_cancelled,
        :calendar_event_changed,
        :calendar_event_not_found,
        :calendar_event_source_mismatch,
        :meeting_calendar_not_configured
      ]

  @doc "Dispatch indexed meetings inside the join window and checkpoint projection cursors."
  @spec join_sweep([map()], keyword()) :: [map()]
  def join_sweep(groups, opts \\ []) do
    if opts[:group_bounded] do
      opts
      |> then(&prepare_join_groups(groups, &1))
      |> checkpoint_public_items(opts)
      |> Enum.flat_map(&join_public_results/1)
    else
      join_candidates_globally(groups, opts)
    end
  end

  defp prepare_join_groups(groups, opts) do
    now = opts[:now] || now_ms()
    dry_run = opts[:dry_run] || false
    max_groups = positive(opts[:max_groups_per_pass], length(groups))
    max_events = positive(opts[:max_events_per_group], @max_events_per_group)
    max_joins = positive(opts[:max_joins_per_pass], max_groups)
    concurrency = positive(opts[:max_concurrency], 1)
    timeout = positive(opts[:task_timeout_ms], @task_timeout_ms)
    lease_epoch = non_negative(opts[:lease_epoch], 0)
    groups = groups |> List.wrap() |> Enum.take(max_groups) |> Enum.take(max_joins)

    groups
    |> bounded_map(concurrency, timeout, fn group ->
      prepare_join_group(group, now, dry_run, max_events, lease_epoch)
    end)
    |> Enum.zip(groups)
    |> Enum.map(fn
      {{:ok, item}, _group} ->
        item

      {{:exit, reason}, group} ->
        emit_meet_operation("calendar_join_group", task_exit_outcome(reason))
        join_error_item(group, {:task_exit, reason})
    end)
    |> dispatch_pending(now, timeout)
  end

  # Every meeting the units' walks collected is dispatched as its own task with
  # its own timeout, all in this pass: a slow dispatch delays only its own
  # meeting. A dispatch that times out is not advanced past, so the next pass
  # reads its meeting record again (a finished dispatch is then a no-op).
  defp dispatch_pending(items, now, timeout) do
    jobs =
      for {item, index} <- Enum.with_index(items),
          {candidate, mid} <- Enum.reverse(Map.get(item, :pending, [])),
          do: {index, candidate, mid}

    # The Group's meeting agent is started once before its meetings are
    # dispatched in parallel, so they do not race to create it.
    jobs
    |> Enum.map(fn {index, _candidate, _mid} -> Enum.at(items, index).group end)
    |> Enum.uniq_by(&group_id/1)
    |> Enum.each(&Runtime.start_for_group(&1["tenant_id"], group_id(&1)))

    outcomes =
      jobs
      |> bounded_map(min(max(length(jobs), 1), @max_dispatch_concurrency), timeout, fn {index,
                                                                                        candidate,
                                                                                        mid} ->
        handle(Enum.at(items, index).group, candidate.event, mid, now, false)
      end)
      |> Enum.zip(jobs)
      |> Enum.group_by(fn {_outcome, {index, _c, _m}} -> index end)

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, index} ->
      item
      |> fold_dispatches(Map.get(outcomes, index, []))
      |> Map.drop([
        :pending,
        :group,
        :order,
        :walk_results,
        :walk_projection,
        :base_projection,
        :done
      ])
    end)
  end

  defp fold_dispatches(%{pending: _} = item, outcomes) do
    acc =
      Enum.reduce(outcomes, %{results: item.walk_results, projection: item.walk_projection}, fn
        {{:ok, result}, {_index, candidate, _mid}}, acc ->
          emit_meet_operation("calendar_join_dispatch", dispatch_outcome(result))

          if result.action == :already do
            acc
          else
            log_join_result(result)

            %{
              acc
              | results: [result | acc.results],
                projection:
                  advance_in_order(
                    acc.projection || item.base_projection,
                    candidate,
                    item.order,
                    item.base_projection.cursor
                  )
            }
          end

        {{:exit, reason}, {_index, _candidate, mid}}, acc ->
          emit_meet_operation("calendar_join_dispatch", task_exit_outcome(reason))
          result = index_error(item.group, {:dispatch_task_exit, mid, reason})
          %{acc | results: [result | acc.results]}
      end)

    # A unit's windows leave out its meetings that are dispatched, so the next
    # join pass goes to the units whose due meetings are still waiting. A
    # deferred join still waits.
    dispatched =
      MapSet.new(
        item.done ++
          for(
            {{:ok, %{action: action} = result}, {_index, _candidate, mid}} <- outcomes,
            action != :error and not match?(%{reason: {:join_deferred, _}}, result),
            do: mid
          )
      )

    windows =
      (acc.projection || item.base_projection)
      |> projection_windows()
      |> Enum.reject(fn {_start, _end, mid} -> MapSet.member?(dispatched, mid) end)

    item.group
    |> join_item(Enum.reverse(acc.results), acc.projection)
    |> Map.put(:windows, windows)
  end

  defp fold_dispatches(item, _outcomes), do: item

  defp prepare_join_group(group, now, dry_run, max_events, lease_epoch) do
    case CalendarProjection.load(group,
           lease_epoch: lease_epoch,
           now: now,
           max_events: max_events
         ) do
      {:ok, projection} ->
        candidates =
          projection
          |> CalendarProjection.candidates(max_events)
          |> Enum.filter(&joinable?(group, &1, now))

        cond do
          dry_run ->
            results =
              candidates
              |> Enum.take(1)
              |> Enum.map(&handle_candidate(group, &1, now, true))

            join_item(group, results, nil)

          true ->
            item = attempt_group_candidate(group, projection, candidates, now)
            emit_meet_operation("calendar_join_group", "ok")
            item
        end

      {:error, reason} ->
        emit_meet_operation("calendar_join_group", "error")
        join_error_item(group, reason)
    end
  end

  # A unit's walk collects every due meeting that still needs a dispatch (at
  # most @max_dispatches_per_unit); the pass then dispatches each of them as
  # its own task (dispatch_pending/3). Cheap store-read skips continue within
  # the walk; a deferred (or unreadable) candidate is recorded and rotated
  # past, and what was collected before it is still dispatched.
  defp attempt_group_candidate(group, projection, candidates, now) do
    initial = %{results: [], projection: nil, dispatches: [], done: []}

    walked =
      Enum.reduce_while(candidates, initial, fn candidate, acc ->
        step_group_candidate(group, projection, candidate, now, acc)
      end)

    %{
      group: group,
      pending: walked.dispatches,
      order: candidates |> Enum.with_index() |> Map.new(fn {c, i} -> {c.key, i} end),
      walk_results: walked.results,
      walk_projection: walked.projection,
      done: walked.done,
      base_projection: projection
    }
  end

  # The walk may already have rotated past a later candidate; the cursor
  # never moves back. Candidates are in rotated order, which starts right after
  # the stored cursor, so the stored cursor counts as the start of that order.
  defp advance_in_order(projection, candidate, order, base_cursor) do
    current =
      if projection.cursor == base_cursor, do: -1, else: Map.get(order, projection.cursor, -1)

    if current < order[candidate.key],
      do: CalendarProjection.advance(projection, candidate),
      else: projection
  end

  defp step_group_candidate(group, projection, candidate, now, acc) do
    current_projection = acc.projection || projection

    case resolve_dispatch_identity(candidate.dispatch_meeting_ids) do
      {:ok, mid, doc} ->
        if dispatch_needed?(mid, now) do
          acc = %{acc | dispatches: [{candidate, mid} | acc.dispatches]}

          if length(acc.dispatches) >= @max_dispatches_per_unit,
            do: {:halt, acc},
            else: {:cont, acc}
        else
          note_skipped_dispatch(group, mid, doc)
          acc = %{acc | done: [mid | acc.done]}

          case ensure_existing_thread_owner(group, candidate.event, mid, doc) do
            :ok ->
              {:cont, acc}

            {:error, {:thread_owned, _existing_id}} ->
              # A pre-fence deployment could create a calendar meeting after a
              # manual meeting had already claimed this thread. The immutable
              # existing owner is already the safety boundary, so the legacy
              # conflict must not wedge later candidates in this group.
              {:cont,
               %{acc | projection: drop_projection_candidate(current_projection, candidate)}}

            {:error, reason} ->
              result = index_error(group, {:slack_thread_owner, mid, reason})

              {:halt, %{acc | results: [result | acc.results]}}
          end
        end

      {:error, reason} ->
        result = index_error(group, {:dispatch_identity, reason})

        # One unreadable meeting document no longer wedges the group forever:
        # record it, rotate past it, and end the pass — the next pass starts
        # beyond it.
        {:halt,
         %{
           acc
           | results: [result | acc.results],
             projection: CalendarProjection.advance(current_projection, candidate)
         }}
    end
  end

  defp drop_projection_candidate(projection, candidate) do
    meeting_id = candidate.meeting_id

    projection
    |> Map.update!(:fresh, &Enum.reject(&1, fn entry -> entry["meeting_id"] == meeting_id end))
    |> Map.update!(:recovery, &Enum.reject(&1, fn entry -> entry["meeting_id"] == meeting_id end))
    |> CalendarProjection.advance(candidate)
  end

  # The operator/test path keeps the historical global cap while still using
  # one snapshot and one CAS checkpoint per affected group. It is deliberately
  # sequential; the production worker always uses the bounded group path.
  defp join_candidates_globally(groups, opts) do
    now = opts[:now] || now_ms()
    dry_run = opts[:dry_run] || false
    max_groups = positive(opts[:max_groups_per_pass], length(groups))
    max_events = positive(opts[:max_events_per_group], @max_events_per_group)
    max_joins = positive(opts[:max_joins_per_pass], max_groups)
    lease_epoch = non_negative(opts[:lease_epoch], 0)
    groups = groups |> List.wrap() |> Enum.take(max_groups)

    {loaded, load_errors} =
      Enum.reduce(groups, {[], []}, fn group, {loaded, errors} ->
        case CalendarProjection.load(group,
               lease_epoch: lease_epoch,
               now: now,
               max_events: max_events
             ) do
          {:ok, projection} -> {[{group, projection} | loaded], errors}
          {:error, reason} -> {loaded, [index_error(group, reason) | errors]}
        end
      end)

    candidates =
      loaded
      |> Enum.flat_map(fn {group, projection} ->
        projection
        |> CalendarProjection.candidates(max_events)
        |> Enum.filter(&joinable?(group, &1, now))
        |> Enum.map(&{group, projection, &1})
      end)
      |> Enum.sort_by(fn {group, _projection, candidate} ->
        {candidate.key, group_key(group)}
      end)
      |> then(fn values -> if dry_run, do: values, else: Enum.take(values, max_joins) end)

    if dry_run do
      Enum.reverse(load_errors) ++
        Enum.map(candidates, fn {group, _projection, candidate} ->
          handle_candidate(group, candidate, now, true)
        end)
    else
      {results, advanced} =
        Enum.reduce(candidates, {[], %{}}, fn {group, projection, candidate},
                                              {results, advanced} ->
          current = Map.get(advanced, group_id(group), projection)

          result = handle_candidate(group, candidate, now, false)

          log_join_result(result)

          advanced =
            if result.action == :already or deferred_projection_candidate?(result),
              do: advanced,
              else:
                Map.put(advanced, group_id(group), CalendarProjection.advance(current, candidate))

          {[result | results], advanced}
        end)

      checkpoint_items =
        Enum.map(advanced, fn {group_id, projection} ->
          %{group_id: group_id, public: {group_id, []}, intent: projection}
        end)

      checkpoint_errors =
        checkpoint_public_items(checkpoint_items, opts)
        |> Enum.flat_map(fn
          {_group_id, []} ->
            []

          {_group_id, {:error, reason}} ->
            [%{group: nil, mid: nil, action: :error, reason: reason}]
        end)

      Enum.reverse(load_errors) ++ Enum.reverse(results) ++ checkpoint_errors
    end
  end

  defp join_public_results({_group_id, results}) when is_list(results), do: results

  defp join_public_results({group_id, {:error, reason}}) do
    [%{group: group_id, mid: nil, action: :error, reason: reason}]
  end

  defp join_public_results({_group_id, _other}), do: []

  defp checkpoint_public_items(items, opts) do
    concurrency = positive(opts[:max_concurrency], 1)
    timeout = positive(opts[:task_timeout_ms], @task_timeout_ms)

    checkpoint_results =
      bounded_map(items, concurrency, timeout, fn
        %{intent: nil} -> :noop
        %{intent: intent} -> CalendarProjection.checkpoint(intent)
      end)

    Enum.zip(items, checkpoint_results)
    |> Enum.map(fn
      {%{public: public}, {:ok, :noop}} ->
        public

      {%{public: public}, {:ok, {:ok, _projection}}} ->
        public

      {item, {:ok, {:error, reason}}} ->
        checkpoint_failure_public(item, {:calendar_projection_checkpoint, reason})

      {item, {:exit, reason}} ->
        checkpoint_failure_public(item, {:calendar_projection_checkpoint_task_exit, reason})
    end)
  end

  defp checkpoint_failure_public(
         %{group_id: group_id, public: {group_id, [event_result | _]}},
         reason
       ) do
    {group_id,
     [
       %{
         group: event_result.group,
         mid: event_result.mid,
         action: :error,
         reason: reason,
         event_result: event_result
       }
     ]}
  end

  defp checkpoint_failure_public(%{group_id: group_id}, reason),
    do: {group_id, {:error, reason}}

  defp checkpoint_projection_intents(items, state) do
    intents = for %{intent: intent} when not is_nil(intent) <- items, do: intent

    intents
    |> bounded_map(state.max_concurrency, state.task_timeout, &CalendarProjection.checkpoint/1)
    |> Enum.reduce_while(:ok, fn
      {:ok, {:ok, _projection}}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, {:calendar_projection, reason}}}
      {:exit, reason}, :ok -> {:halt, {:error, {:calendar_projection_task_exit, reason}}}
    end)
  end

  # Finite outcome vocabulary for the per-candidate join step (PR1 telemetry
  # contract): a pass that ran and found nothing to do is now distinguishable
  # from a pass that never ran.
  defp dispatch_outcome(%{action: action}) when action in [:joined, :notified], do: "dispatched"

  defp dispatch_outcome(%{action: action}) when action in [:already, :already_notified],
    do: "already"

  defp dispatch_outcome(%{action: :skipped}), do: "skipped"
  defp dispatch_outcome(%{action: :error}), do: "error"

  defp join_item(group, results, intent),
    do: %{group_id: group_id(group), public: {group_id(group), results}, intent: intent}

  defp error_item(group, reason),
    do: %{group_id: group_id(group), public: {group_id(group), {:error, reason}}, intent: nil}

  defp join_error_item(group, reason) do
    join_item(group, [index_error(group, reason)], nil)
  end

  # A Google Meet is joined, and a Feishu/Lark meeting when the Group has a
  # bot of its platform (`lark_join/2`). A meeting that qualified by another
  # recognized link (Zoom, Teams; `OccurrenceQualification`) is listed and
  # prepared, and never reaches dispatch.
  defp joinable?(group, candidate, now) do
    event = candidate.event

    valid_event =
      present?(event["event_id"]) and is_integer(event["start_ms"]) and
        joinable_url?(group, event["meet_url"]) and is_map(event["occurrence_ref"])

    valid_event and
      (within_dispatch_window?(group, event, now) or
         (dispatch_mode(group) == "join" and candidate.kind == :recovery and
            recoverable_meeting?(candidate.dispatch_meeting_ids, now))) and
      meeting_id(group, event) == candidate.meeting_id
  end

  # Join mode: a meeting is joinable from T-@lead_ms until it ends. The old upper bound (start + @grace_ms,
  # five minutes) turned any dispatcher outage that overlapped those seven minutes — a rolling deploy, a
  # lease hand-off, a runtime crash on first attempt — into a meeting that was never joined at all, while
  # a late join is still a recorded meeting. The scan already keeps in-progress events fresh (occurrence
  # queries are overlap-based), so this predicate is the only gate to widen. `end_ms` must be present for
  # the widened bound; an event without it keeps the conservative window.
  defp within_join_window?(event, now) do
    start_ms = event["start_ms"]

    upper =
      case event["end_ms"] do
        end_ms when is_integer(end_ms) and end_ms > start_ms -> end_ms
        _ -> start_ms + @grace_ms
      end

    now >= start_ms - @lead_ms and now <= upper
  end

  defp within_dispatch_window?(%{"mode" => "prepare"}, _event, _now), do: false

  defp within_dispatch_window?(%{"mode" => "notify"}, event, now) do
    now >= event["start_ms"] and now <= event["start_ms"] + @grace_ms
  end

  defp within_dispatch_window?(_group, event, now), do: within_join_window?(event, now)

  defp dispatch_mode(%{"mode" => "prepare"}), do: "prepare"
  defp dispatch_mode(%{"mode" => "notify"}), do: "notify"
  defp dispatch_mode(_group), do: "join"

  defp recoverable_meeting?(dispatch_mids, now) do
    case resolve_dispatch_identity(dispatch_mids) do
      {:ok, _mid, %{"join_requested_at" => requested_at}} when is_integer(requested_at) ->
        false

      {:ok, _mid, doc} when is_map(doc) ->
        recovery_open?(doc, now) and not recovery_abandoned?(doc)

      _ ->
        false
    end
  end

  defp recovery_open?(doc, now) do
    created_at = doc["created_at"]
    is_integer(created_at) and now <= created_at + @recovery_ms
  end

  defp recovery_abandoned?(doc) do
    state = map_or_empty(doc["state"])
    dispatch = map_or_empty(state["join_dispatch"])

    is_integer(state["calendar_autojoin_abandoned_at"]) or
      get_in(state, ["calendar_root", "status"]) == "abandoned" or
      dispatch["status"] == "abandoned"
  end

  defp abandon_recovery(mid, now, reason) do
    case Store.abandon_join_dispatch(mid, reason, now: now) do
      {:ok, _doc, _etag} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_needed?(mid, now) do
    case Store.get(mid) do
      {:ok, doc, _etag} ->
        dispatch_needed_doc?(doc, now)

      {:error, :not_found} ->
        true

      {:error, _reason} ->
        true
    end
  end

  defp dispatch_needed_doc?(doc, now \\ now_ms()) do
    state = map_or_empty(doc["state"])
    dispatch = map_or_empty(state["join_dispatch"])

    fresh =
      not recovery_abandoned?(doc) and is_nil(doc["join_requested_at"]) and
        dispatch["status"] in [nil, "", "pending"]

    fresh or Store.join_retry_candidate?(doc, now)
  end

  defp resolve_dispatch_identity(dispatch_mids) do
    dispatch_mids = dispatch_mids |> List.wrap() |> Enum.filter(&present?/1) |> Enum.uniq()

    with true <- dispatch_mids != [] do
      dispatch_mids
      |> Enum.reduce_while({:ok, []}, fn mid, {:ok, existing} ->
        case Store.get(mid) do
          {:ok, doc, _etag} -> {:cont, {:ok, [{mid, doc} | existing]}}
          {:error, :not_found} -> {:cont, {:ok, existing}}
          {:error, reason} -> {:halt, {:error, {mid, reason}}}
        end
      end)
      |> case do
        {:ok, []} ->
          {:ok, List.last(dispatch_mids), nil}

        {:ok, existing} ->
          {mid, doc} =
            existing
            |> Enum.reverse()
            |> Enum.min_by(fn {_mid, doc} -> if dispatch_needed_doc?(doc), do: 1, else: 0 end)

          {:ok, mid, doc}

        {:error, _reason} = error ->
          error
      end
    else
      false -> {:error, :invalid_dispatch_identity}
    end
  end

  defp index_error(group, reason) do
    Logger.warning("calendar_autojoin join projection #{group_id(group)}: #{inspect(reason)}")
    %{group: group_id(group), mid: nil, action: :error, reason: reason}
  end

  # A candidate inside its join window that no longer "needs dispatch" is
  # normally already dispatched, explicitly abandoned, or freshly in flight.
  # With the retry path in place, a `failed` record reaching here means the
  # attempt budget is exhausted — a permanent, surfaced loss. A `dispatching`
  # record is only surfaced once it is old enough to be reclaimable (a fresh
  # in-flight claim under the reclaim window is normal operation).
  defp note_skipped_dispatch(group, mid, doc) when is_map(doc) do
    state = map_or_empty(doc["state"])
    dispatch = map_or_empty(state["join_dispatch"])

    case dispatch["status"] do
      "failed" ->
        Logger.warning(
          "calendar_autojoin skip #{group_id(group)} #{mid}: join budget exhausted: " <>
            inspect(dispatch["last_error"])
        )

        emit_meet_operation("calendar_join_dispatch_skip", "failed")

      "dispatching" ->
        claimed_at = dispatch["claimed_at"]

        if is_integer(claimed_at) and
             claimed_at <= now_ms() - Store.join_reclaim_after_ms() do
          Logger.warning(
            "calendar_autojoin skip #{group_id(group)} #{mid}: join_dispatch in doubt since " <>
              inspect(claimed_at)
          )

          emit_meet_operation("calendar_join_dispatch_skip", "in_doubt")
        else
          :ok
        end

      _ ->
        :ok
    end
  end

  defp note_skipped_dispatch(_group, _mid, _doc), do: :ok

  defp task_exit_outcome(:timeout), do: "timeout"
  defp task_exit_outcome(_reason), do: "error"

  defp emit_meet_operation(operation, outcome, started_at \\ nil) do
    duration =
      if is_integer(started_at), do: SystemsClock.monotonic_time() - started_at, else: 0

    Salix.Telemetry.emit_operation("salix_meet", operation, "system", outcome, duration)
  end

  defp handle_candidate(group, candidate, now, dry_run) do
    case resolve_dispatch_identity(candidate.dispatch_meeting_ids) do
      {:ok, mid, _doc} -> handle(group, candidate.event, mid, now, dry_run)
      {:error, reason} -> index_error(group, {:dispatch_identity, reason})
    end
  end

  defp handle(group, event, mid, _now, true) do
    %{
      group: group_id(group),
      mid: mid,
      title: event["title"],
      meet_url: event["meet_url"],
      start_ms: event["start_ms"],
      action: if(dispatch_mode(group) == "notify", do: :would_notify, else: :would_join)
    }
  end

  defp handle(group, event, mid, now, false) do
    case Ports.CalendarOccurrences.revalidate(group, event) do
      :ok ->
        dispatch_revalidated(group, event, mid, now)

      {:error, reason} ->
        if deferred_join_revalidation?(reason) do
          # A join-time read cannot tell a stable-identity source/duration move
          # from a terminal revocation. Leave the durable meeting pending so the
          # next authoritative scan can replace or abandon its projection.
          %{group: group_id(group), mid: mid, action: :skipped, reason: reason}
        else
          %{
            group: group_id(group),
            mid: mid,
            action: :error,
            reason: {:calendar_revalidation, reason}
          }
        end

      other ->
        %{
          group: group_id(group),
          mid: mid,
          action: :error,
          reason: {:calendar_revalidation, {:invalid_result, other}}
        }
    end
  end

  defp dispatch_revalidated(%{"mode" => "notify"} = group, event, mid, _now) do
    case Ports.CalendarNotifier.notify(group, event, mid) do
      {:ok, :queued} ->
        %{group: group_id(group), mid: mid, action: :notified}

      {:ok, :exists} ->
        %{group: group_id(group), mid: mid, action: :already_notified}

      {:error, reason} ->
        %{group: group_id(group), mid: mid, action: :error, reason: reason, retry: true}
    end
  end

  defp dispatch_revalidated(group, event, mid, now) do
    with {:ok, doc, target} <- load_or_create(group, event, mid, now),
         :ok <- ensure_not_abandoned(doc),
         {:ok, doc} <- claim_member_scope(doc, group, event, mid, now),
         :ok <- validate_scope(doc, group, event, mid),
         {:ok, refreshed} <- refresh_mutable_calendar_state(mid, doc, group, event, now),
         :ok <- ensure_not_abandoned(refreshed),
         :ok <- validate_scope(refreshed, group, event, mid) do
      dispatch_or_resume(group, event, mid, refreshed, target, now)
    else
      {:skip, reason} ->
        %{group: group_id(group), mid: mid, action: :skipped, reason: reason}

      {:already, _reason} ->
        %{group: group_id(group), mid: mid, action: :already}

      {:error, reason} ->
        %{group: group_id(group), mid: mid, action: :error, reason: reason}
    end
  end

  # Several members' calendars name the same meeting. The first one to
  # dispatch owns it; another member's calendar takes over only a meeting that
  # was not dispatched (or awaits a retry) and that the owner's calendar no
  # longer holds, so a member's decline cannot leave the meeting unjoined.
  defp claim_member_scope(
         %{"state" => state} = doc,
         %{"calendar_scope" => "members"} = group,
         event,
         mid,
         now
       )
       when is_map(state) do
    owner = get_in(state, ["source", "calendar_id"])

    cond do
      calendar_scope_matches?(state, group, event) ->
        {:ok, doc}

      member_scope_open?(state, now) and member_owner_released?(group, owner, mid) ->
        case Store.update_state_retrying(mid, fn current ->
               if get_in(current, ["source", "calendar_id"]) == owner and
                    member_scope_open?(current, now),
                  do: put_mutable_calendar_state(current, group, event),
                  else: current
             end) do
          {:ok, refreshed, _etag} -> {:ok, refreshed}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:already, :meeting_owned_by_member_calendar}
    end
  end

  defp claim_member_scope(doc, _group, _event, _mid, _now), do: {:ok, doc}

  defp member_scope_open?(state, now),
    do:
      never_dispatched?(state, map_or_empty(state["join_dispatch"])) or
        Store.join_retry_candidate?(%{"state" => state}, now)

  defp member_owner_released?(group, owner_calendar_id, mid) do
    owner = Map.put(group, "calendar_id", owner_calendar_id)

    with {:ok, key} <- CalendarProjection.projection_key(owner) do
      case S3.get(key) do
        {:error, :not_found} ->
          true

        {:ok, %{body: body}} ->
          case Jason.decode(body) do
            {:ok, %{"fresh" => fresh, "recovery" => recovery}}
            when is_list(fresh) and is_list(recovery) ->
              not Enum.any?(fresh ++ recovery, &(is_map(&1) and &1["meeting_id"] == mid))

            _ ->
              false
          end

        {:error, _reason} ->
          false
      end
    else
      {:error, _reason} -> false
    end
  end

  defp deferred_projection_candidate?(%{action: :skipped, reason: reason}),
    do: deferred_join_revalidation?(reason)

  defp deferred_projection_candidate?(%{reason: {:calendar_revalidation, _reason}}), do: true

  defp deferred_projection_candidate?(%{retry: true}), do: true

  defp deferred_projection_candidate?(_result), do: false

  defp ensure_not_abandoned(%{"state" => state}) when is_map(state) do
    root = map_or_empty(state["calendar_root"])
    dispatch = map_or_empty(state["join_dispatch"])

    if is_integer(state["calendar_autojoin_abandoned_at"]) or root["status"] == "abandoned" or
         dispatch["status"] == "abandoned",
       do: {:skip, :calendar_autojoin_abandoned},
       else: :ok
  end

  defp ensure_not_abandoned(_doc), do: {:error, :invalid_meeting_document}

  # A join that waits for its meeting is asked again every pass: no log.
  defp log_join_result(%{reason: {:join_deferred, _reason}}), do: :ok

  defp log_join_result(%{action: action, group: group, mid: mid, reason: reason})
       when action in [:error, :skipped] do
    Logger.warning(
      "calendar_autojoin #{action} group=#{group} meeting=#{mid || "none"}: #{inspect(reason)}"
    )
  end

  defp log_join_result(_result), do: :ok

  defp load_or_create(group, event, mid, now) do
    case Store.get(mid) do
      {:ok, doc, _etag} ->
        {:ok, doc, target_from_state(doc["state"] || %{})}

      {:error, :not_found} ->
        with {:ok, state, target} <- build_state(group, event, mid),
             result <- Store.create_once(mid, state: state, now: now) do
          case result do
            {:ok, doc, _etag} -> {:ok, doc, target}
            {:error, :exists} -> load_existing(mid)
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, reason} -> {:skip, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_existing(mid) do
    case Store.get(mid) do
      {:ok, doc, _etag} -> {:ok, doc, target_from_state(doc["state"] || %{})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_mutable_calendar_state(mid, %{"state" => state} = doc, group, event, now)
       when is_map(state) do
    if mutable_calendar_state_current?(state, group, event) do
      {:ok, doc}
    else
      case Store.update_state_retrying(mid, fn current ->
             if refreshable_calendar_state?(current, group, event, now),
               do: put_mutable_calendar_state(current, group, event),
               else: current
           end) do
        {:ok, refreshed, _etag} -> {:ok, refreshed}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp refresh_mutable_calendar_state(_mid, _doc, _group, _event, _now),
    do: {:error, :invalid_meeting_document}

  defp refreshable_calendar_state?(state, group, event, now) do
    dispatch = map_or_empty(state["join_dispatch"])
    root = map_or_empty(state["calendar_root"])

    calendar_scope_matches?(state, group, event) and
      not is_integer(state["calendar_autojoin_abandoned_at"]) and
      root["status"] != "abandoned" and
      (never_dispatched?(state, dispatch) or
         Store.join_retry_candidate?(%{"state" => state}, now))
  end

  # A retry re-dispatch refreshes the mutable calendar facts too: without
  # this, a retried join would use the meet_url/time captured by the failed
  # first attempt.
  defp never_dispatched?(state, dispatch) do
    dispatch["status"] not in ["abandoned", "dispatching", "dispatched", "failed"] and
      not is_integer(state["join_requested_at"])
  end

  defp mutable_calendar_state_current?(state, group, event) do
    source = map_or_empty(state["source"])
    desired_source = event_source(group, event)

    state["start_at"] == div(event["start_ms"], 1_000) and
      state["end_at"] == event_end_s(event) and state["meet_url"] == event["meet_url"] and
      state["title"] == event_title(event) and
      Enum.all?(desired_source, fn {key, value} -> source[key] == value end)
  end

  defp put_mutable_calendar_state(state, group, event) do
    source = state["source"] |> map_or_empty() |> Map.merge(event_source(group, event))

    state
    |> Map.put("start_at", div(event["start_ms"], 1_000))
    |> Map.put("end_at", event_end_s(event))
    |> Map.put("meet_url", event["meet_url"])
    |> Map.put("title", event_title(event))
    |> Map.put("source", source)
    |> put_meeting_number(event["meet_url"])
  end

  # A Feishu/Lark meeting moved to a new link is joined by its new number.
  defp put_meeting_number(%{"runtime_source" => "lark_bot", "lark_bot" => bot} = state, url)
       when is_map(bot) do
    case LarkBot.meeting_link(url) do
      {:ok, _platform, meeting_no} ->
        Map.put(state, "lark_bot", Map.put(bot, "meeting_no", meeting_no))

      :error ->
        state
    end
  end

  defp put_meeting_number(state, _url), do: state

  defp dispatch_or_resume(group, event, mid, doc, target, now) do
    if dispatch_needed_doc?(doc, now) do
      case ensure_thread_owner(group, event, mid, doc, target) do
        {:ok, thread_ts, refreshed} ->
          dispatch_owned_meeting(group, mid, refreshed, thread_ts, now)

        {:error, reason} ->
          %{group: group_id(group), mid: mid, action: :error, reason: reason}
      end
    else
      case ensure_existing_thread_owner(group, event, mid, doc) do
        :ok ->
          dispatch_owned_meeting(group, mid, doc, "", now)

        {:error, {:thread_owned, existing_id}} ->
          %{
            group: group_id(group),
            mid: mid,
            action: :skipped,
            reason: {:thread_owned, existing_id}
          }

        {:error, reason} ->
          %{group: group_id(group), mid: mid, action: :error, reason: reason}
      end
    end
  end

  defp dispatch_owned_meeting(group, mid, doc, thread_ts, now) do
    state = map_or_empty(doc["state"])
    dispatch = map_or_empty(state["join_dispatch"])
    retryable = Store.join_retry_candidate?(doc, now)

    cond do
      dispatch["status"] == "dispatching" and not retryable ->
        %{group: group_id(group), mid: mid, action: :error, reason: :join_in_progress}

      dispatch["status"] == "failed" and not retryable ->
        %{
          group: group_id(group),
          mid: mid,
          action: :error,
          reason: {:join_failed, dispatch["last_error"] || "unknown runtime failure"}
        }

      (dispatch["status"] == "dispatched" and not retryable) or
          (is_integer(doc["join_requested_at"]) and dispatch == %{}) ->
        %{group: group_id(group), mid: mid, action: :already}

      true ->
        case default_join(mid) do
          :ok ->
            %{group: group_id(group), mid: mid, action: :joined, thread_ts: thread_ts}

          {:error, :join_liveness_unavailable} ->
            # Fail-closed round (RFC contract one): the live-session answer is
            # unavailable, so a retry re-dispatch is refused without consuming
            # budget. The next pass asks again.
            emit_meet_operation("calendar_join_dispatch_skip", "unavailable")

            %{
              group: group_id(group),
              mid: mid,
              action: :skipped,
              reason: :join_liveness_unavailable
            }

          # A Feishu/Lark meeting that cannot take the bot yet (not started,
          # or refused for now by its settings) is normal operation: its join
          # is pending again with no attempt spent, and every pass until the
          # meeting ends offers it again. One that will never take the bot is
          # abandoned. Neither is an error of the pass.
          {:error, {kind, _reason} = reason} when kind in [:join_deferred, :join_abandoned] ->
            %{group: group_id(group), mid: mid, action: :skipped, reason: reason}

          {:error, reason} ->
            %{group: group_id(group), mid: mid, action: :error, reason: reason}
        end
    end
  end

  defp ensure_existing_thread_owner(_group, _event, mid, doc) do
    state = map_or_empty(doc["state"])
    channel = trim(get_in(state, ["slack_ref", "channel_id"]))
    thread_ts = trim(get_in(state, ["slack_ref", "thread_ts"]))

    if channel == "" or thread_ts == "" do
      :ok
    else
      with {:ok, %{"meeting_id" => ^mid}} <-
             SlackThreadIndex.claim(state, channel, thread_ts, mid) do
        :ok
      end
    end
  end

  # A Feishu/Lark Meeting has no thread to own: its first message in the
  # destination chat (`Ports.MeetingChannel.ensure_root/4`) names the chat.
  defp ensure_thread_owner(
         group,
         event,
         mid,
         %{"state" => %{"provider" => provider}} = doc,
         target
       )
       when provider in ["feishu", "lark"] do
    with {:ok, _chat_id} <- ensure_root(group, event, mid, doc, target),
         {:ok, refreshed, _etag} <- Store.get(mid) do
      {:ok, "", refreshed}
    end
  end

  defp ensure_thread_owner(group, event, mid, doc, target) do
    state = map_or_empty(doc["state"])
    existing_thread_ts = get_in(state, ["slack_ref", "thread_ts"]) |> trim()

    with {:ok, thread_ts} <-
           if(existing_thread_ts == "",
             do: ensure_root(group, event, mid, doc, target),
             else: {:ok, existing_thread_ts}
           ),
         {:ok, refreshed, _etag} <- Store.get(mid),
         refreshed_state = map_or_empty(refreshed["state"]),
         true <-
           trim(get_in(refreshed_state, ["slack_ref", "thread_ts"])) == thread_ts ||
             {:error, :meeting_thread_missing},
         channel when channel != "" <-
           trim(get_in(refreshed_state, ["slack_ref", "channel_id"])),
         {:ok, %{"meeting_id" => ^mid}} <-
           SlackThreadIndex.claim(refreshed_state, channel, thread_ts, mid) do
      {:ok, thread_ts, refreshed}
    else
      "" -> {:error, :meeting_channel_missing}
      false -> {:error, :meeting_thread_missing}
      {:error, _} = error -> error
    end
  end

  defp ensure_root(group, event, mid, _doc, target),
    do: Ports.MeetingChannel.ensure_root(group, mid, event, target)

  @doc false
  def default_join(meeting_id), do: request_join(meeting_id, 20)

  defp request_join(_meeting_id, 0), do: {:error, :not_leader}

  defp request_join(meeting_id, retries) do
    with {:ok, _pid} <- ensure_meeting_process(meeting_id) do
      case SalixMeet.Meeting.join(meeting_id) do
        {:ok, _joined_at} ->
          :ok

        {:error, reason} when reason in [:not_leader, :not_running] ->
          SystemsClock.sleep(25)
          request_join(meeting_id, retries - 1)

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_meeting_process(meeting_id) do
    case SalixMeet.Application.start_meeting(meeting_id) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:already_present, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc false
  @spec meeting_id(map(), map()) :: String.t()
  def meeting_id(group, event), do: CalendarProjection.meeting_id(group, event)

  # The Meeting is of the destination's platform (`Ports.MeetingChannel`):
  # a Slack thread, or a Feishu/Lark chat. A Feishu/Lark meeting link is
  # joined by that platform's bot (`SalixMeet.LarkBot`), whatever the
  # destination; any other link by a dispatched runtime.
  defp build_state(group, event, mid) do
    with {:ok, target} <- Ports.MeetingChannel.resolve(group, event),
         {:ok, meeting_agent} <- Runtime.start_for_group(group["tenant_id"], group_id(group)) do
      start_s = div(event["start_ms"], 1_000)
      source = Map.put(event_source(group, event), "workspace_id", target["workspace_id"])
      bot = lark_join(group, event["meet_url"])

      attrs = %{
        "tenant_id" => group["tenant_id"],
        "group_id" => group_id(group),
        "connect_id" => target["connect_id"],
        "meet_url" => event["meet_url"],
        "title" => event_title(event),
        "bot_name" => default_bot_name(),
        "caption_language" => default_caption_language(),
        "start_at" => start_s,
        "end_at" => event_end_s(event),
        "runtime_source" =>
          if(match?({:ok, _}, bot),
            do: LarkBot.source(),
            else: SalixMeet.MeetingRuntimePolicy.default_source()
          ),
        "source" => source
      }

      case new_meeting_state(target, mid, meeting_agent, attrs) do
        {:ok, state} -> {:ok, put_lark_bot(state, bot), target}
        {:error, _} = error -> error
      end
    end
  end

  defp new_meeting_state(%{"provider" => provider} = target, mid, meeting_agent, attrs)
       when provider in ["feishu", "lark"] do
    # Without a chat the first message goes to `open_id` and names the
    # private chat (`Ports.MeetingChannel.ensure_root/4`).
    ref = %{
      "chat_id" => trim(target["chat_id"]),
      "open_id" => trim(target["open_id"]),
      "chat_type" => "group",
      "thread_id" => "",
      "root_message_id" => "",
      "trigger_message_id" => ""
    }

    if provider == "feishu",
      do: MeetingState.new_feishu(mid, meeting_agent, Map.put(attrs, "feishu_ref", ref)),
      else: MeetingState.new_lark(mid, meeting_agent, Map.put(attrs, "lark_ref", ref))
  end

  defp new_meeting_state(target, mid, meeting_agent, attrs) do
    MeetingState.new_slack(
      mid,
      meeting_agent,
      Map.put(attrs, "slack_ref", %{
        "channel_id" => target["channel_id"],
        "thread_ts" => trim(target["thread_ts"])
      })
    )
  end

  defp put_lark_bot(state, {:ok, bot}), do: Map.put(state, "lark_bot", bot)
  defp put_lark_bot(state, :error), do: state

  defp validate_scope(%{"id" => mid, "state" => state}, group, event, mid)
       when is_map(state) do
    if calendar_scope_matches?(state, group, event),
      do: :ok,
      else: {:error, :meeting_event_scope_mismatch}
  end

  defp validate_scope(_doc, _group, _event, _mid), do: {:error, :invalid_meeting_document}

  defp calendar_scope_matches?(state, group, event) do
    source = map_or_empty(state["source"])

    state["tenant_id"] == group["tenant_id"] and state["group_id"] == group_id(group) and
      source["kind"] == "calendar" and source["calendar_id"] == event["calendar_id"] and
      source["calendar_item_id"] == event["calendar_item_id"] and
      source["occurrence_ref"] == event["occurrence_ref"]
  end

  defp event_source(group, event) do
    %{
      "kind" => "calendar",
      "event_id" => event["event_id"],
      "calendar_id" => event["calendar_id"] || group["calendar_id"],
      "calendar_item_id" => event["calendar_item_id"],
      "occurrence_ref" => event["occurrence_ref"],
      "meeting_plan_id" => event["meeting_plan_id"]
    }
  end

  defp event_title(event), do: event["title"] || "Calendar meeting"

  defp event_end_s(event) do
    if is_integer(event["end_ms"]),
      do: div(event["end_ms"], 1_000),
      else: div(event["start_ms"], 1_000) + 3_600
  end

  defp target_from_state(state) do
    %{
      "connect_id" => state["connect_id"],
      "workspace_id" => get_in(state, ["source", "workspace_id"]),
      "channel_id" => get_in(state, ["slack_ref", "channel_id"]),
      "thread_ts" => get_in(state, ["slack_ref", "thread_ts"])
    }
  end

  @spec enabled_groups() :: [map()]
  def enabled_groups, do: enabled_groups(configured_channels())

  @spec enabled_groups([map()]) :: [map()]
  def enabled_groups(entries) do
    refresh_groups(%{
      groups_override: nil,
      channels: entries,
      managed_channels: false,
      resolved: %{},
      groups: [],
      enrollment_ttl_ms: @enrollment_ttl_ms,
      enrollment_retry_backoff_ms: @enrollment_retry_backoff_ms
    }).groups
  end

  defp configured_channels do
    SalixMeet.CalendarConfiguration.authorized_entries()
  end

  defp dedup_groups(groups) do
    groups
    |> Enum.group_by(&unit_key/1)
    |> Enum.flat_map(fn
      {_group_id, [single]} ->
        [single]

      {group_id, conflicting} ->
        Logger.warning(
          "calendar_autojoin group #{group_id} resolved to #{length(conflicting)} conflicting targets; skipping (fail-closed)"
        )

        []
    end)
  end

  defp cursor_batch(groups, key, limit) do
    sorted = Enum.sort_by(List.wrap(groups), &group_key/1)

    case sorted do
      [] ->
        {:ok, [], nil}

      _ ->
        with {:ok, cursor, etag, new?} <- read_cursor(key) do
          {after_cursor, before_or_at} = Enum.split_with(sorted, &(group_key(&1) > cursor))
          batch = (after_cursor ++ before_or_at) |> Enum.take(limit)

          pass_cursor = %{
            key: key,
            cursor: batch |> List.last() |> then(&(&1 && group_key(&1))),
            etag: etag,
            new?: new?
          }

          {:ok, batch, pass_cursor}
        end
    end
  end

  defp read_cursor(key) do
    case S3.get(key) do
      {:ok, %{body: body, etag: etag}} ->
        case Jason.decode(body) do
          {:ok, %{"cursor" => cursor}} when is_binary(cursor) ->
            {:ok, cursor, etag, false}

          _ ->
            {:error, {:invalid_calendar_pass_cursor, key}}
        end

      {:error, :not_found} ->
        {:ok, "", nil, true}

      {:error, reason} ->
        {:error, {:calendar_pass_cursor_read, key, reason}}
    end
  end

  defp checkpoint_pass_cursor(nil, _state), do: :ok
  defp checkpoint_pass_cursor(%{cursor: nil}, _state), do: :ok

  defp checkpoint_pass_cursor(pass_cursor, state) do
    case bounded_map([pass_cursor], 1, state.task_timeout, &checkpoint_cursor/1) do
      [{:ok, :ok}] -> :ok
      [{:ok, {:error, reason}}] -> {:error, reason}
      [{:exit, reason}] -> {:error, {:calendar_pass_cursor_task_exit, reason}}
    end
  end

  defp checkpoint_cursor(%{key: key, cursor: cursor, etag: etag, new?: new?}) do
    body = Jason.encode!(%{"cursor" => cursor, "updated_at" => now_ms()})
    opts = if new?, do: [if_none_match: "*"], else: [if_match: etag]

    case S3.put(key, body, opts) do
      {:ok, _} ->
        :ok

      {:error, :precondition_failed} ->
        {:error, {:calendar_pass_cursor_write, key, :stale}}

      {:error, {:ambiguous, _reason}} ->
        verify_cursor_checkpoint(key, cursor)

      {:error, reason} ->
        {:error, {:calendar_pass_cursor_write, key, reason}}
    end
  end

  defp verify_cursor_checkpoint(key, cursor) do
    case S3.get(key) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"cursor" => ^cursor}} -> :ok
          _ -> {:error, {:calendar_pass_cursor_write, key, :stale}}
        end

      _ ->
        {:error, {:calendar_pass_cursor_write, key, :stale}}
    end
  end

  # The task budget runs on SystemsClock, as every other deadline here does.
  defp bounded_map(values, concurrency, timeout, fun) do
    SystemsClock.async_stream(values, fun,
      ordered: true,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.to_list()
  end

  defp group_key(group), do: trim(group["tenant_id"]) <> <<0>> <> unit_key(group)

  # A member calendar is its own scan unit inside its Group.
  defp unit_key(%{"calendar_scope" => "members"} = group),
    do: group_id(group) <> "/" <> trim(group["calendar_id"])

  defp unit_key(group), do: group_id(group)
  defp group_id(group), do: trim(group["group_id"])

  defp positive(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive(_value, fallback), do: max(fallback, 1)
  defp non_negative(value, _fallback) when is_integer(value) and value >= 0, do: value
  defp non_negative(_value, fallback), do: fallback

  defp google_meet_url?(url) do
    case URI.parse(trim(url)) do
      %URI{scheme: scheme, host: host, userinfo: nil, port: port, path: path, fragment: nil}
      when port in [nil, 443] and is_binary(path) ->
        String.downcase(to_string(scheme || "")) == "https" and
          String.downcase(to_string(host || "")) == "meet.google.com" and
          Regex.match?(~r|^/[a-z]{3}-[a-z]{4}-[a-z]{3}/?$|, path)

      _ ->
        false
    end
  end

  defp joinable_url?(group, url),
    do: google_meet_url?(url) or match?({:ok, _bot}, lark_join(group, url))

  # The bot that joins a Feishu/Lark meeting link: the Group's bot of the
  # link's platform, as the enrollment names it (`lark_join`). Without one
  # the meeting is only prepared.
  defp lark_join(group, url) do
    with {:ok, platform, meeting_no} <- LarkBot.meeting_link(url),
         connect_id when is_binary(connect_id) and connect_id != "" <-
           get_in(map_or_empty(group["lark_join"]), [platform]) do
      {:ok, %{"connect_id" => connect_id, "provider" => platform, "meeting_no" => meeting_no}}
    else
      _ -> :error
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}
  defp default_bot_name, do: configured_default(:default_bot_name, @default_bot_name)

  defp default_caption_language,
    do: configured_default(:default_caption_language, @default_caption_language)

  defp configured_default(key, fallback) do
    case SystemsRuntime.get_env(:salix_meet, key) do
      value when is_binary(value) -> blank_default(String.trim(value), fallback)
      _ -> fallback
    end
  end

  defp blank_default("", fallback), do: fallback
  defp blank_default(value, _fallback), do: value
  defp trim(value), do: String.trim(to_string(value || ""))
  defp now_ms, do: SystemsClock.system_time(:millisecond)
end
