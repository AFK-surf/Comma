defmodule SalixStore.StationTaskSessions do
  @moduledoc """
  The Sessions of other stations taking part in a Task Salix keeps, the
  Message seq through which each was given the Task (`sent`), what each was
  invited with (`start`; nil for those invited before it was kept, until
  `SalixWeb.Migrations.StationTaskStarts` keeps it), and
  through which Message the station's Sessions answered the Task already
  (`answered`: what `sent` was when one of them last ended a turn; nil for
  those from before it was kept, until the Task is read for it), as a station
  keeps its `task_sessions` (`systems/station/docs/tasks.md`).
  `SalixWeb.StationTasks` gives each the Messages after `sent`.

  A station expected in a Task (`expect/1`) has a row with no Session yet
  (`session` is `awaited/0`): the Task was made while the station, the Group's
  Cloud VM, was not connected, and it is invited with `start` when it
  connects, its Session then taking the row's place (`rejoin/4`).
  """

  @awaited ""

  alias SalixStore.Repo

  @columns "tenant_id, group_id, conversation_id, device_id, session, agent_id, sent, start, answered"

  @doc "The `session` of a station expected in a Task, not invited yet (`expect/1`)."
  def awaited, do: @awaited

  @doc "Whether the row is a station's expected in the Task, with no Session of it yet."
  def awaited?(%{session: session}), do: session == @awaited

  @doc """
  Records that `session` of `device_id` takes part in the Task; kept as it was
  when it did already. A row of the station expected in the Task, with no
  Session yet, gives way to it.
  """
  def join(row) when is_map(row) do
    case join_with_token(row) do
      {:ok, _token} -> :ok
      error -> error
    end
  end

  @doc """
  Same as `join/1`, returning `{:ok, committed_binding_token}` from the DB row
  (`RETURNING start->>'binding_token'`). On conflict, preserves any existing non-empty
  `binding_token` (or fills it from `EXCLUDED.start->'binding_token'` when absent) so
  concurrent registrations converge on one DB-authoritative binding token.
  """
  def join_with_token(
        %{
          tenant_id: tenant,
          group_id: group,
          conversation_id: conversation,
          device_id: device,
          session: session,
          agent_id: agent
        } = row
      )
      when is_binary(session) and session != @awaited do
    req_answered =
      case row[:answered] do
        n when is_integer(n) and n >= 0 -> n
        _ -> 0
      end

    slot = slot_of(row[:start]) || "lead"
    incoming_seq = if is_map(row[:start]), do: row[:start]["start_seq"], else: nil
    tx_guard = row[:tx_guard]
    expected_pending_invite_id = row[:expected_pending_invite_id]

    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device),
                {:ok, %{rows: locked_rows}} <-
                  query(
                    """
                    SELECT session, answered, start
                    FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
             if is_binary(expected_pending_invite_id) and expected_pending_invite_id != "" do
               already_committed_same_invite? =
                 Enum.any?(locked_rows, fn [s, _a, st] ->
                   s != @awaited and s == session and (slot_of(st) || "lead") == slot and
                     is_map(st) and
                     (st["invite_id"] == expected_pending_invite_id or
                        expected_pending_invite_id in List.wrap(st["committed_invite_ids"]))
                 end)

               unless already_committed_same_invite? do
                 primary_start =
                   locked_rows
                   |> Enum.sort_by(fn [s, _a, st] ->
                     is_prim =
                       case is_map(st) && st["is_primary"] do
                         v when is_boolean(v) -> v
                         _ -> (slot_of(st) || "lead") == "lead"
                       end

                     {if(is_prim, do: 0, else: 1), s}
                   end)
                   |> List.first()
                   |> case do
                     [_, _, st] when is_map(st) -> st
                     _ -> %{}
                   end

                 cur_pending =
                   primary_start
                   |> Map.get("pending_multi_starts", [])
                   |> List.wrap()
                   |> Enum.find(&(&1["slot"] == slot))

                 unless is_map(cur_pending) and
                          cur_pending["invite_id"] == expected_pending_invite_id and
                          cur_pending["pending_deactivation"] != true do
                   Repo.rollback({:stale_slot_binding, :invite_superseded})
                 end
               end
             end

             device_hwm =
               locked_rows
               |> Enum.map(fn [_, _, st] ->
                 if is_map(st), do: get_in(st, ["slot_seq_hwm", slot]) || 0, else: 0
               end)
               |> Enum.max(fn -> 0 end)

             if device_hwm > 0 and (not is_integer(incoming_seq) or incoming_seq < device_hwm) do
               Repo.rollback({:stale_slot_binding, :superseded})
             end

             if is_function(tx_guard, 0) do
               case tx_guard.() do
                 :ok -> :ok
                 {:error, guard_err} -> Repo.rollback(guard_err)
               end
             end

             other_same_slot =
               Enum.filter(locked_rows, fn [s, _ans, st] ->
                 s != @awaited and s != session and (slot_of(st) || "lead") == slot
               end)

             answered =
               case other_same_slot do
                 [] ->
                   req_answered

                 others ->
                   max_existing_seq =
                     others
                     |> Enum.map(fn [_, _, st] -> (is_map(st) && st["start_seq"]) || 0 end)
                     |> Enum.max()

                   if is_integer(incoming_seq) and incoming_seq > max_existing_seq do
                     other_sessions = Enum.map(others, &hd/1)

                     case query(
                            """
                            DELETE FROM station_task_sessions
                            WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                              AND session = ANY($4::text[])
                            """,
                            [group, conversation, device, other_sessions]
                          ) do
                       {:ok, _} ->
                         max_other_ans =
                           others
                           |> Enum.map(fn [_, a, _] -> if is_integer(a), do: a, else: 0 end)
                           |> Enum.max(fn -> 0 end)

                         max(req_answered, max_other_ans)

                       {:error, del_err} ->
                         Repo.rollback(del_err)
                     end
                   else
                     [first_existing | _] = Enum.map(others, &hd/1)
                     Repo.rollback({:stale_slot_binding, first_existing})
                   end
               end

             with {:ok, %{rows: [[committed_token]]}} <-
                    query(
                      """
                      INSERT INTO station_task_sessions (#{@columns}, joined_at)
                      VALUES ($1, $2, $3, $4, $5, $6, 0, $7, $8, $9)
                      ON CONFLICT (group_id, conversation_id, device_id, session)
                      DO UPDATE SET
                        answered = GREATEST(COALESCE(station_task_sessions.answered, 0), EXCLUDED.answered),
                        start = CASE
                          WHEN EXCLUDED.start IS NOT NULL THEN
                            (COALESCE(EXCLUDED.start, '{}'::jsonb) - 'connector_run_id' - 'pending_multi_starts' - 'pending_orphan_leaves' - 'binding_token' - 'invite_id' - 'committed_invite_ids' - 'claim_token' - 'claim_confirmed' - 'start_seq' - 'slot_seq_hwm')
                            || COALESCE(station_task_sessions.start, '{}'::jsonb)
                            || CASE
                                 WHEN COALESCE(station_task_sessions.start->>'connector_run_id', '') = ''
                                      AND EXCLUDED.start ? 'connector_run_id'
                                   THEN jsonb_build_object('connector_run_id', EXCLUDED.start->'connector_run_id')
                                 ELSE '{}'::jsonb
                               END
                            || CASE
                                 WHEN COALESCE(station_task_sessions.start->>'binding_token', '') = ''
                                      AND EXCLUDED.start ? 'binding_token'
                                   THEN jsonb_build_object('binding_token', EXCLUDED.start->'binding_token')
                                 ELSE '{}'::jsonb
                               END
                            || CASE
                                 WHEN COALESCE(station_task_sessions.start->>'invite_id', '') = ''
                                      AND EXCLUDED.start ? 'invite_id'
                                   THEN jsonb_build_object('invite_id', EXCLUDED.start->'invite_id')
                                 ELSE '{}'::jsonb
                               END
                            || CASE
                                 WHEN COALESCE(station_task_sessions.start->>'claim_token', '') = ''
                                      AND COALESCE(EXCLUDED.start->>'claim_token', '') <> ''
                                   THEN jsonb_build_object('claim_token', EXCLUDED.start->'claim_token')
                                 ELSE '{}'::jsonb
                               END
                            || CASE
                                 WHEN COALESCE((station_task_sessions.start->>'claim_confirmed')::boolean, false) = true
                                   THEN jsonb_build_object('claim_confirmed', true)
                                 WHEN EXCLUDED.start ? 'claim_confirmed'
                                   THEN jsonb_build_object('claim_confirmed', EXCLUDED.start->'claim_confirmed')
                                 ELSE '{}'::jsonb
                               END
                            || CASE
                                 WHEN COALESCE(station_task_sessions.start->>'invite_id', '') <> ''
                                      OR COALESCE(EXCLUDED.start->>'invite_id', '') <> ''
                                      OR station_task_sessions.start ? 'committed_invite_ids'
                                   THEN jsonb_build_object(
                                     'committed_invite_ids',
                                     (
                                       SELECT COALESCE(jsonb_agg(DISTINCT val), '[]'::jsonb)
                                       FROM (
                                         SELECT jsonb_array_elements_text(COALESCE(station_task_sessions.start->'committed_invite_ids', '[]'::jsonb)) AS val
                                         UNION
                                         SELECT station_task_sessions.start->>'invite_id' AS val
                                         UNION
                                         SELECT EXCLUDED.start->>'invite_id' AS val
                                       ) s
                                       WHERE val IS NOT NULL AND val <> ''
                                     )
                                   )
                                 ELSE '{}'::jsonb
                               END
                            || CASE
                                 WHEN station_task_sessions.start ? 'start_seq'
                                      OR EXCLUDED.start ? 'start_seq'
                                   THEN jsonb_build_object(
                                     'start_seq',
                                     GREATEST(
                                       COALESCE((station_task_sessions.start->>'start_seq')::bigint, 0),
                                       COALESCE((EXCLUDED.start->>'start_seq')::bigint, 0)
                                     )
                                   )
                                 ELSE '{}'::jsonb
                               END
                          ELSE station_task_sessions.start
                        END
                      RETURNING start->>'binding_token'
                      """,
                      [
                        tenant,
                        group,
                        conversation,
                        device,
                        session,
                        agent,
                        row[:start],
                        answered,
                        SystemsClock.system_time(:millisecond)
                      ]
                    ),
                  :ok <-
                    query(
                      """
                      DELETE FROM station_task_sessions
                      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                      """,
                      [group, conversation, device, @awaited]
                    )
                    |> ok() do
               committed_token
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, committed_token} -> {:ok, committed_token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records that the station `device_id` is expected in the Task: not connected
  when the Task was made, it is invited with `start` when it connects. Nothing
  is recorded for a station that has a row of the Task already, expected or
  with a Session.
  """
  def expect(
        %{
          tenant_id: tenant,
          group_id: group,
          conversation_id: conversation,
          device_id: device,
          agent_id: agent
        } = row
      ) do
    query(
      """
      INSERT INTO station_task_sessions (#{@columns}, joined_at)
      SELECT $1, $2, $3, $4, $5, $6, 0, $7, 0, $8
      WHERE NOT EXISTS (
        SELECT 1 FROM station_task_sessions
        WHERE group_id = $2 AND conversation_id = $3 AND device_id = $4
      )
      """,
      [
        tenant,
        group,
        conversation,
        device,
        @awaited,
        agent,
        row[:start],
        SystemsClock.system_time(:millisecond)
      ]
    )
    |> ok()
  end

  @doc """
  The station lost the Task and was invited again, or was expected in it and
  is now invited: `session` takes the place of `device`'s rows of it, given
  nothing yet, invited with `start`. What its Sessions answered already
  (`answered`) stays.
  """
  def rejoin(
        %{tenant_id: tenant, group_id: group, conversation_id: conversation, device_id: device} =
          row,
        session,
        start,
        answered
      ) do
    with {:ok, _} <-
           query(
             """
             INSERT INTO station_task_sessions (#{@columns}, joined_at)
             VALUES ($1, $2, $3, $4, $5, $6, 0, $7, $9, $8)
             ON CONFLICT (group_id, conversation_id, device_id, session)
             DO UPDATE SET sent = 0, start = EXCLUDED.start,
               answered = GREATEST(COALESCE(station_task_sessions.answered, 0), EXCLUDED.answered)
             """,
             [
               tenant,
               group,
               conversation,
               device,
               session,
               row.agent_id,
               start,
               SystemsClock.system_time(:millisecond),
               answered
             ]
           ) do
      query(
        """
        DELETE FROM station_task_sessions
        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session <> $4
        """,
        [group, conversation, device, session]
      )
      |> ok()
    end
  end

  @doc """
  Slot-keyed transactional rejoin with connection-generation fencing:
  in a single DB transaction, conditionally deletes the exact old binding
  `(group_id, conversation_id, device_id, old_row.session) RETURNING 1`.
    * If 1 row is deleted: inserts the new binding `(new_session, expected_run_id)`.
    * If 0 rows are deleted (NEVER writes!): performs a read-only check on the
      current row for `(group_id, conversation_id, device_id, slot)`: returns
      `{:ok, :already_current}` if it already matches `(new_session, expected_run_id)`,
      otherwise `{:error, :stale}` (so a stale `A -> A` retry arriving after `A -> B`
      can never resurrect retired `A`).
  """
  def rejoin_slot(old_row, new_session, expected_run_id, start, answered) do
    case replace_awaited(old_row, new_session, expected_run_id, start, answered) do
      {:ok, status, _pending} -> {:ok, status}
      other -> other
    end
  end

  @doc """
  Single-transaction replacement of an awaited (or old) slot row that atomically
  inherits any concurrently appended `pending_multi_starts` from the deleted row
  (`DELETE ... RETURNING start`), merges them with incoming `start["pending_multi_starts"]`
  (dedup by slot, keeping max `answered`), and returns `{:ok, status, merged_pending}`.
  """
  def replace_awaited(
        %{
          tenant_id: tenant,
          group_id: group,
          conversation_id: conversation,
          device_id: device,
          session: old_session,
          agent_id: agent_id
        } = old_row,
        new_session,
        expected_run_id,
        start,
        answered
      )
      when is_binary(new_session) and new_session != @awaited do
    slot = slot_of(start) || slot_of(old_row[:start]) || "lead"

    fenced_start =
      if is_map(start),
        do: put_run_id(start, expected_run_id),
        else: start

    now = SystemsClock.system_time(:millisecond)

    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device) do
             case query(
                    """
                    DELETE FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                    RETURNING start
                    """,
                    [group, conversation, device, old_session]
                  ) do
               {:ok, %{num_rows: 1, rows: [[deleted_start]]}} ->
                 live_pending =
                   if is_map(deleted_start),
                     do: List.wrap(deleted_start["pending_multi_starts"]),
                     else: []

                 incoming_pending =
                   if is_map(fenced_start),
                     do: List.wrap(fenced_start["pending_multi_starts"]),
                     else: []

                 merged_pending = merge_pending_entries(live_pending, incoming_pending, %{})

                 merged_hwm =
                   merge_hwm_maps([
                     if(is_map(deleted_start), do: deleted_start["slot_seq_hwm"], else: nil),
                     if(is_map(fenced_start), do: fenced_start["slot_seq_hwm"], else: nil)
                   ])

                 merged_orphan_leaves =
                   merge_pending_orphan_leaves([
                     if(is_map(deleted_start),
                       do: deleted_start["pending_orphan_leaves"],
                       else: []
                     ),
                     if(is_map(fenced_start), do: fenced_start["pending_orphan_leaves"], else: [])
                   ])

                 final_start =
                   if is_map(fenced_start) do
                     fenced_start
                     |> then(fn st ->
                       if merged_hwm != nil,
                         do: Map.put(st, "slot_seq_hwm", merged_hwm),
                         else: st
                     end)
                     |> then(fn st ->
                       if merged_pending == [],
                         do: Map.delete(st, "pending_multi_starts"),
                         else: Map.put(st, "pending_multi_starts", merged_pending)
                     end)
                     |> then(fn st ->
                       if merged_orphan_leaves == [],
                         do: Map.delete(st, "pending_orphan_leaves"),
                         else: Map.put(st, "pending_orphan_leaves", merged_orphan_leaves)
                     end)
                   else
                     fenced_start
                   end

                 case query(
                        """
                        INSERT INTO station_task_sessions (#{@columns}, joined_at)
                        VALUES ($1, $2, $3, $4, $5, $6, 0, $7, $8, $9)
                        ON CONFLICT (group_id, conversation_id, device_id, session)
                        DO UPDATE SET sent = 0, start = EXCLUDED.start,
                          answered = GREATEST(COALESCE(station_task_sessions.answered, 0), EXCLUDED.answered)
                        """,
                        [
                          tenant,
                          group,
                          conversation,
                          device,
                          new_session,
                          agent_id,
                          final_start,
                          answered,
                          now
                        ]
                      ) do
                   {:ok, _} -> {:rejoined, merged_pending}
                   {:error, reason} -> Repo.rollback(reason)
                 end

               {:ok, %{num_rows: 0}} ->
                 case query(
                        """
                        SELECT session, start FROM station_task_sessions
                        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                          AND COALESCE(start->>'slot', 'lead') = $4
                        LIMIT 1
                        """,
                        [group, conversation, device, slot]
                      ) do
                   {:ok, %{rows: [[current_session, current_start]]}} ->
                     current_run = is_map(current_start) && current_start["connector_run_id"]

                     if current_session == new_session and current_run == expected_run_id do
                       {:already_current,
                        if(is_map(current_start),
                          do: List.wrap(current_start["pending_multi_starts"]),
                          else: []
                        )}
                     else
                       Repo.rollback(:stale)
                     end

                   {:ok, %{rows: []}} ->
                     Repo.rollback(:stale)

                   {:error, reason} ->
                     Repo.rollback(reason)
                 end

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, {status, pending}} -> {:ok, status, pending}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Single-transaction `FOR UPDATE` disk-loss recovery for a device's primary session:
  1. Locks all rows of `(group_id, conversation_id, device_id) FOR UPDATE`.
  2. Verifies `old_primary_row.session` is still present AND its `connector_run_id`
     still matches `expected_old_run_id` (if a newer connection already took over,
     rolls back `:stale`; if `new_session` + `used_run_id` is already current,
     returns `{:ok, :already_current}`).
  3. Merges live `answered` watermarks (`max(snapshot, live)`) for primary and
     secondaries, plus merges any concurrently appended `pending_multi_starts`.
  4. Deletes ONLY `old_primary_row.session` and exact `stale_secondary_sessions`
     (never touching any concurrently joined new secondary session).
  5. Inserts `new_session` with `connector_run_id = used_run_id`, merged
     `answered`, and merged `pending_multi_starts`.
  """
  def recover_device_primary(
        %{
          tenant_id: tenant,
          group_id: group,
          conversation_id: conversation,
          device_id: device,
          session: old_session,
          agent_id: agent_id
        } = old_row,
        new_session,
        used_run_id,
        start,
        primary_answered,
        stale_secondary_sessions,
        expected_old_run_id \\ nil
      )
      when is_binary(new_session) and new_session != @awaited and
             is_list(stale_secondary_sessions) do
    slot = slot_of(start) || slot_of(old_row[:start]) || "lead"
    now = SystemsClock.system_time(:millisecond)

    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device),
                {:ok, %{rows: locked_rows}} <-
                  query(
                    """
                    SELECT session, answered, start FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
             locked =
               Enum.map(locked_rows, fn [s, ans, st] ->
                 %{session: s, answered: ans || 0, start: st || %{}}
               end)

             live_primary = Enum.find(locked, &(&1.session == old_session))

             cond do
               is_nil(live_primary) ->
                 current =
                   Enum.find(locked, fn r ->
                     (slot_of(r.start) || "lead") == slot
                   end)

                 if current && current.session == new_session &&
                      current.start["connector_run_id"] == used_run_id do
                   {:already_current, List.wrap(current.start["pending_multi_starts"])}
                 else
                   Repo.rollback(:stale)
                 end

               is_binary(expected_old_run_id) and expected_old_run_id != "" and
                 is_binary(live_primary.start["connector_run_id"]) and
                 live_primary.start["connector_run_id"] != "" and
                   live_primary.start["connector_run_id"] != expected_old_run_id ->
                 Repo.rollback(:stale)

               true ->
                 live_primary_answered = max(primary_answered || 0, live_primary.answered)

                 live_answered_by_slot =
                   Map.new(locked, fn r -> {slot_of(r.start) || "lead", r.answered} end)

                 # Merge incoming pending_multi_starts with any concurrently appended live pending entries,
                 # preserving the max answered watermark for every secondary slot.
                 live_pending = List.wrap(live_primary.start["pending_multi_starts"])
                 incoming_pending = List.wrap(is_map(start) && start["pending_multi_starts"])

                 merged_pending =
                   merge_pending_entries(live_pending, incoming_pending, live_answered_by_slot)

                 merged_hwm =
                   merge_hwm_maps([
                     if(is_map(start), do: start["slot_seq_hwm"], else: nil)
                     | Enum.map(locked, & &1.start["slot_seq_hwm"])
                   ])

                 merged_orphan_leaves =
                   merge_pending_orphan_leaves([
                     if(is_map(start), do: start["pending_orphan_leaves"], else: [])
                     | Enum.map(locked, & &1.start["pending_orphan_leaves"])
                   ])

                 fenced_start =
                   if(is_map(start), do: start, else: %{})
                   |> put_run_id(used_run_id)
                   |> then(fn st ->
                     if merged_hwm != nil,
                       do: Map.put(st, "slot_seq_hwm", merged_hwm),
                       else: st
                   end)
                   |> then(fn st ->
                     if merged_pending == [],
                       do: Map.delete(st, "pending_multi_starts"),
                       else: Map.put(st, "pending_multi_starts", merged_pending)
                   end)
                   |> then(fn st ->
                     if merged_orphan_leaves == [],
                       do: Map.delete(st, "pending_orphan_leaves"),
                       else: Map.put(st, "pending_orphan_leaves", merged_orphan_leaves)
                   end)

                 sessions_to_delete = Enum.uniq([old_session | stale_secondary_sessions])

                 case query(
                        """
                        DELETE FROM station_task_sessions
                        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                          AND session = ANY($4::text[])
                        """,
                        [group, conversation, device, sessions_to_delete]
                      ) do
                   {:ok, _} -> :ok
                   {:error, reason} -> Repo.rollback(reason)
                 end

                 case query(
                        """
                        INSERT INTO station_task_sessions (#{@columns}, joined_at)
                        VALUES ($1, $2, $3, $4, $5, $6, 0, $7, $8, $9)
                        ON CONFLICT (group_id, conversation_id, device_id, session)
                        DO UPDATE SET sent = 0, start = EXCLUDED.start,
                          answered = GREATEST(COALESCE(station_task_sessions.answered, 0), EXCLUDED.answered)
                        """,
                        [
                          tenant,
                          group,
                          conversation,
                          device,
                          new_session,
                          agent_id,
                          fenced_start,
                          live_primary_answered,
                          now
                        ]
                      ) do
                   {:ok, _} -> {:rejoined, merged_pending}
                   {:error, reason} -> Repo.rollback(reason)
                 end
             end
           else
             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, {:rejoined, merged_pending}} -> {:ok, :rejoined, merged_pending}
      {:ok, {:already_current, current_pending}} -> {:ok, :already_current, current_pending}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slot_of(%{"slot" => slot}) when is_binary(slot) and slot != "", do: slot
  defp slot_of(_start), do: nil

  defp put_run_id(start, run_id) when is_map(start) and is_binary(run_id) and run_id != "",
    do: Map.put(start, "connector_run_id", run_id)

  defp put_run_id(start, _run_id), do: start

  @doc "The Sessions of other stations taking part in the Task."
  def of_task(group, conversation) do
    rows(
      "SELECT #{@columns} FROM station_task_sessions WHERE group_id = $1 AND conversation_id = $2 ORDER BY device_id ASC, session ASC",
      [group, conversation]
    )
  end

  @doc "The Sessions of the station `device` taking part in Tasks of its Group."
  def of_device(tenant, group, device) do
    rows(
      "SELECT #{@columns} FROM station_task_sessions WHERE tenant_id = $1 AND group_id = $2 AND device_id = $3",
      [tenant, group, device]
    )
  end

  @doc """
  At most `limit` Tasks of Group `group` that the station `device` takes part
  in, after Task `cursor` (nil: from the first), in id order: each as
  `%{conversation_id, agent_id}`, the Worker of its first Session.
  """
  def tasks_of_device(tenant, group, device, cursor, limit)
      when is_integer(limit) and limit > 0 do
    case query(
           """
           SELECT DISTINCT ON (conversation_id) conversation_id, agent_id
           FROM station_task_sessions
           WHERE tenant_id = $1 AND group_id = $2 AND device_id = $3 AND conversation_id > $4
           ORDER BY conversation_id, session
           LIMIT $5
           """,
           [tenant, group, device, cursor || "", limit]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [conversation, agent] ->
           %{conversation_id: conversation, agent_id: agent}
         end)}

      error ->
        error
    end
  end

  @doc "Every Session of another station taking part in a Task here: what Salix gives on starting."
  def all do
    rows("SELECT #{@columns} FROM station_task_sessions", [])
  end

  @doc """
  At most `limit` active Tasks (`salix_conversations`: kind `agent_task`,
  status `active`, not deleted) that a station takes part in, as
  `{group_id, conversation_id}` in key order after `cursor` (the last pair
  read, or nil from the first): what `SalixIM.StationTaskWatchRecovery`
  starts the owners of when a node starts. One page per call; a Task with
  several stations is one pair. `group: group_id` keeps to one Group.
  """
  def active_tasks(cursor, limit, opts \\ []) when is_integer(limit) and limit > 0 do
    {after_key, params} =
      case cursor do
        nil ->
          {"", [limit]}

        {group, conversation} ->
          {"AND (s.group_id, s.conversation_id) > ($2, $3)", [limit, group, conversation]}
      end

    {in_group, params} =
      case Keyword.get(opts, :group) do
        nil -> {"", params}
        group -> {"AND s.group_id = $#{length(params) + 1}", params ++ [group]}
      end

    case query(
           """
           SELECT DISTINCT s.group_id, s.conversation_id
           FROM station_task_sessions s
           JOIN salix_conversations c
             ON c.group_id = s.group_id AND c.conversation_id = s.conversation_id
           WHERE c.kind = 'agent_task' AND c.status = 'active' AND c.deleted_at IS NULL
             #{after_key} #{in_group}
           ORDER BY s.group_id, s.conversation_id
           LIMIT $1
           """,
           params
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [group, conversation] -> {group, conversation} end)}

      error ->
        error
    end
  end

  @doc """
  At most `limit` Sessions with no `start` kept, in key order after `cursor`
  (the key `{group_id, conversation_id, device_id, session}` of the last one
  read, or nil from the first).
  """
  def without_start(cursor, limit) when is_integer(limit) and limit > 0 do
    {after_key, params} =
      case cursor do
        nil ->
          {"", [limit]}

        {group, conversation, device, session} ->
          {"AND (group_id, conversation_id, device_id, session) > ($2, $3, $4, $5)",
           [limit, group, conversation, device, session]}
      end

    rows(
      """
      SELECT #{@columns} FROM station_task_sessions
      WHERE (start IS NULL OR (start - 'connector_run_id') = '{}'::jsonb) #{after_key}
      ORDER BY group_id, conversation_id, device_id, session
      LIMIT $1
      """,
      params
    )
  end

  @doc "Updates the stored `start` JSONB of a specific `(group, conversation, device, session)` row."
  def update_start(group, conversation, device, session, %{} = start) do
    query(
      """
      UPDATE station_task_sessions SET start = $5
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
      """,
      [group, conversation, device, session, start]
    )
    |> ok()
  end

  @doc """
  Keep `start` for a Session that has none: one kept since (it was invited
  again) stays. Whether it was kept now.
  """
  def keep_start(
        %{group_id: group, conversation_id: conversation, device_id: device, session: session},
        start
      ) do
    case query(
           """
           UPDATE station_task_sessions
           SET start = CASE
             WHEN start IS NOT NULL AND start ? 'connector_run_id'
               THEN jsonb_set($5::jsonb, '{connector_run_id}', start->'connector_run_id', true)
             ELSE $5::jsonb
           END
           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
             AND (start IS NULL OR (start - 'connector_run_id') = '{}'::jsonb)
           """,
           [group, conversation, device, session, start]
         ) do
      {:ok, %{num_rows: kept}} -> {:ok, kept == 1}
      error -> error
    end
  end

  @doc """
  `device`'s Sessions of the Task were given it through `seq`.
  When `expected_sent` is provided, only advances rows whose `sent >= expected_sent`
  (preventing a stale in-flight `task.put` from overwriting a `fetched` reset by a newer `hello`).
  """
  def sent(group, conversation, device, seq, opts \\ []) do
    case Keyword.get(opts, :expected_sent) do
      expected when is_integer(expected) ->
        case query(
               """
               UPDATE station_task_sessions SET sent = GREATEST(sent, $4)
               WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND sent >= $5
               """,
               [group, conversation, device, seq, expected]
             ) do
          {:ok, %{num_rows: 0}} -> :stale
          {:ok, _} -> :ok
          {:error, _} = err -> err
        end

      _ ->
        query(
          """
          UPDATE station_task_sessions SET sent = GREATEST(sent, $4)
          WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
          """,
          [group, conversation, device, seq]
        )
        |> ok()
    end
  end

  @doc """
  Advances `sent` ONLY on the exact snapshot `session_watermarks` (`[{session, expected_sent}]`),
  verifying both `sent >= expected_sent` and connection generation (`expected_run_id`).
  Any newly joined session not in `session_watermarks` keeps its `sent = 0` untouched.
  Rolls back and returns `:stale` if any snapshot session was concurrently reset, replaced, or
  fenced by a newer connection generation.
  """
  def sent_sessions(group, conversation, device, session_watermarks, seq, expected_run_id \\ nil)

  def sent_sessions(_group, _conversation, _device, [], _seq, _expected_run_id), do: :ok

  def sent_sessions(group, conversation, device, session_watermarks, seq, expected_run_id)
      when is_list(session_watermarks) and is_integer(seq) do
    run_id =
      if is_binary(expected_run_id) and expected_run_id != "", do: expected_run_id, else: nil

    case Repo.transaction(fn ->
           Enum.each(session_watermarks, fn {session, expected_sent} ->
             case query(
                    """
                    UPDATE station_task_sessions SET sent = GREATEST(sent, $5)
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                      AND sent >= $6
                      AND ($7::text IS NULL OR COALESCE(start->>'connector_run_id', '') = $7::text)
                    """,
                    [group, conversation, device, session, seq, expected_sent, run_id]
                  ) do
               {:ok, %{num_rows: 1}} -> :ok
               {:ok, %{num_rows: 0}} -> Repo.rollback(:stale)
               {:error, reason} -> Repo.rollback(reason)
             end
           end)

           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, :stale} -> :stale
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `device` has the Task only through `fetched` (it said so in its hello): what
  it was given after that is given again. When `run_id` is given, unconditionally
  refreshes `start["connector_run_id"]` on ALL non-awaited rows of `(group, conversation, device)`
  (including legacy single-session primary rows without `"slot"`) so any in-flight
  `task.put` or `gone` from a previous connection generation is strictly fenced.
  """
  def fetched(group, conversation, device, fetched, run_id \\ nil) do
    if is_binary(run_id) and run_id != "" do
      query(
        """
        UPDATE station_task_sessions
        SET sent = LEAST(sent, $4),
            start = jsonb_set(COALESCE(start, '{}'::jsonb), '{connector_run_id}', to_jsonb($5::text), true)
        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session <> $6
        """,
        [group, conversation, device, fetched, run_id, @awaited]
      )
      |> ok()
    else
      query(
        """
        UPDATE station_task_sessions SET sent = $4
        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND sent > $4
        """,
        [group, conversation, device, fetched]
      )
      |> ok()
    end
  end

  @doc """
  Handles `hello` from a legacy station that omits the `tasks` list (`had == nil`):
  preserves `sent` for rows already bound to the SAME `run_id`, while safely resetting
  `sent = 0` and stamping `run_id` on rows from an earlier or unknown generation so an
  unverified positive watermark is never bleached onto a new connection.
  """
  def reset_unconfirmed_hello(group, conversation, device, run_id)
      when is_binary(run_id) and run_id != "" do
    query(
      """
      UPDATE station_task_sessions
      SET sent = CASE WHEN COALESCE(start->>'connector_run_id', '') = $4 THEN sent ELSE 0 END,
          start = jsonb_set(COALESCE(start, '{}'::jsonb), '{connector_run_id}', to_jsonb($4::text), true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session <> $5
      """,
      [group, conversation, device, run_id, @awaited]
    )
    |> ok()
  end

  @doc """
  Safely resets legacy unstamped positive-watermark rows (`sent > 0` with empty/missing
  `connector_run_id`, e.g. upgraded PR 1 rows) to `sent = 0` and binds them to `run_id`,
  without touching rows already owned by another `connector_run_id`.
  """
  def reset_unstamped_sent(group, conversation, device, run_id)
      when is_binary(run_id) and run_id != "" do
    query(
      """
      UPDATE station_task_sessions
      SET sent = 0,
          start = jsonb_set(COALESCE(start, '{}'::jsonb), '{connector_run_id}', to_jsonb($4::text), true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        AND session <> $5
        AND sent > 0
        AND COALESCE(start->>'connector_run_id', '') = ''
      """,
      [group, conversation, device, run_id, @awaited]
    )
    |> ok()
  end

  @doc """
  Refreshes `start["connector_run_id"]` on all non-awaited rows of
  `(group, conversation, device)` (used on `hello` without `tasks` list).
  """
  def stamp_run_id(group, conversation, device, run_id)
      when is_binary(run_id) and run_id != "" do
    query(
      """
      UPDATE station_task_sessions
      SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{connector_run_id}', to_jsonb($4::text), true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session <> $5
      """,
      [group, conversation, device, run_id, @awaited]
    )
    |> ok()
  end

  @doc """
  Claims `connector_run_id` ONLY on snapshot `sessions` that currently have no
  `connector_run_id` recorded yet (e.g. joined while offline before first `hello`).
  Never overwrites an existing `connector_run_id`.
  """
  def claim_run_id(group, conversation, device, sessions, run_id)
      when is_list(sessions) and is_binary(run_id) and run_id != "" do
    if sessions == [] do
      :ok
    else
      query(
        """
        UPDATE station_task_sessions
        SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{connector_run_id}', to_jsonb($5::text), true)
        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
          AND session = ANY($4::text[])
          AND COALESCE(start->>'connector_run_id', '') = ''
        """,
        [group, conversation, device, sessions, run_id]
      )
      |> ok()
    end
  end

  @doc """
  Conditionally rebinds `session`'s `connector_run_id` from `expected_old_run_id`
  to `new_run_id` after verifying the session is alive on `new_run_id` (e.g. a
  late `joined` receipt carrying `run_A` that arrived after `hello(run_B)`).
  """
  def rebind_run_id(group, conversation, device, session, expected_old_run_id, new_run_id)
      when is_binary(session) and is_binary(expected_old_run_id) and is_binary(new_run_id) and
             new_run_id != "" do
    case query(
           """
           UPDATE station_task_sessions
           SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{connector_run_id}', to_jsonb($6::text), true)
           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
             AND COALESCE(start->>'connector_run_id', '') = $5
           """,
           [group, conversation, device, session, expected_old_run_id, new_run_id]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> :stale
      {:error, _} = err -> err
    end
  end

  @doc """
  Deletes ONLY the snapshot `sessions` of `(group, conversation, device)` whose
  connection generation strictly equals `expected_run_id` (when given; empty run_id
  never matches), so a stale `gone: true` from an older connection cannot wipe
  freshly joined or reconnected rows.
  """
  def leave_sessions(group, conversation, device, sessions, expected_run_id \\ nil)

  def leave_sessions(_group, _conversation, _device, [], _expected_run_id), do: :ok

  def leave_sessions(group, conversation, device, sessions, expected_run_id)
      when is_list(sessions) do
    run_id =
      if is_binary(expected_run_id) and expected_run_id != "", do: expected_run_id, else: nil

    query(
      """
      DELETE FROM station_task_sessions
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        AND session = ANY($4::text[])
        AND ($5::text IS NULL OR COALESCE(start->>'connector_run_id', '') = $5::text)
      """,
      [group, conversation, device, sessions, run_id]
    )
    |> ok()
  end

  @doc "Deletes all rows of `(group, conversation, device)` except `keep_session`."
  def delete_non_primary(group, conversation, device, keep_session)
      when is_binary(keep_session) do
    query(
      """
      DELETE FROM station_task_sessions
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session <> $4
      """,
      [group, conversation, device, keep_session]
    )
    |> ok()
  end

  @doc """
  Transactionally appends a secondary start entry to the primary row's
  `start["pending_multi_starts"]` using targeted Postgres JSONB `jsonb_set`
  (never overwriting `connector_run_id` or other keys in `start`).
  """
  def append_pending_multi_start(group, conversation, device, %{"slot" => slot} = entry)
      when is_binary(slot) and slot != "" do
    case Repo.transaction(fn ->
           case query(
                  """
                  SELECT session, COALESCE(start->'pending_multi_starts', '[]'::jsonb)
                  FROM station_task_sessions
                  WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                  ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                  LIMIT 1
                  FOR UPDATE
                  """,
                  [group, conversation, device]
                ) do
             {:ok, %{rows: [[session, current_pending]]}} ->
               existing = List.wrap(current_pending)

               {persisted_entry, next_pending, needs_write?} =
                 case Enum.find_index(existing, &(&1["slot"] == slot)) do
                   nil ->
                     entry_with_id = ensure_invite_id(entry)
                     {entry_with_id, existing ++ [entry_with_id], true}

                   idx ->
                     cur = Enum.at(existing, idx)

                     if pending_entry_matches?(cur, entry) do
                       if is_binary(cur["invite_id"]) and cur["invite_id"] != "" do
                         {cur, existing, false}
                       else
                         filled = ensure_invite_id(cur)
                         {filled, List.replace_at(existing, idx, filled), true}
                       end
                     else
                       Repo.rollback({:slot_already_pending, cur})
                     end
                 end

               if needs_write? do
                 case query(
                        """
                        UPDATE station_task_sessions
                        SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true)
                        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                        """,
                        [group, conversation, device, session, next_pending]
                      ) do
                   {:ok, _} -> persisted_entry
                   {:error, reason} -> Repo.rollback(reason)
                 end
               else
                 persisted_entry
               end

             {:ok, %{rows: []}} ->
               Repo.rollback(:not_found)

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, persisted_entry} -> {:ok, persisted_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ensures the pending multi-start entry for `slot` on `(group, conversation, device)` has
  a persisted `"invite_id"`, returning `{:ok, invite_id}` (or `{:error, reason}`).
  """
  def ensure_pending_invite_id(group, conversation, device, slot, expected_entry \\ nil)
      when is_binary(slot) and slot != "" do
    case Repo.transaction(fn ->
           case query(
                  """
                  SELECT session, COALESCE(start->'pending_multi_starts', '[]'::jsonb)
                  FROM station_task_sessions
                  WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                  ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                  LIMIT 1
                  FOR UPDATE
                  """,
                  [group, conversation, device]
                ) do
             {:ok, %{rows: [[session, current_pending]]}} ->
               existing = List.wrap(current_pending)

               case Enum.find_index(existing, &(&1["slot"] == slot)) do
                 nil ->
                   Repo.rollback(:not_found)

                 idx ->
                   cur = Enum.at(existing, idx)

                   if is_map(expected_entry) and not pending_entry_matches?(cur, expected_entry) do
                     Repo.rollback({:entry_changed, cur})
                   end

                   if is_binary(cur["invite_id"]) and cur["invite_id"] != "" do
                     cur
                   else
                     filled = ensure_invite_id(cur)
                     next_pending = List.replace_at(existing, idx, filled)

                     case query(
                            """
                            UPDATE station_task_sessions
                            SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true)
                            WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                            """,
                            [group, conversation, device, session, next_pending]
                          ) do
                       {:ok, _} -> filled
                       {:error, reason} -> Repo.rollback(reason)
                     end
                   end
               end

             {:ok, %{rows: []}} ->
               Repo.rollback(:not_found)

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, persisted_entry} -> {:ok, persisted_entry}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Single-transaction atomic demotion of absent secondary session rows:
  1. Locks all rows of `(group_id, conversation_id, device_id) FOR UPDATE`.
  2. Locates the live primary row (rolling back `:primary_missing` if absent).
  3. Reads each absent secondary's locked highest `answered` watermark and merges
     the recovery entry into the primary row's `start["pending_multi_starts"]`.
  4. Deletes ONLY those exact absent secondary session rows (never the primary).
  If any step fails, the entire transaction rolls back so no old row is ever deleted
  without its pending recovery entry safely committed.
  """
  def demote_missing_secondaries(
        group,
        conversation,
        device,
        missing_rows,
        expected_run_id \\ nil
      )

  def demote_missing_secondaries(_group, _conversation, _device, [], _expected_run_id), do: :ok

  def demote_missing_secondaries(group, conversation, device, missing_rows, expected_run_id)
      when is_list(missing_rows) do
    fence_run? = is_binary(expected_run_id) and expected_run_id != ""

    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device),
                {:ok, %{rows: locked_rows}} <-
                  query(
                    """
                    SELECT session, answered, start FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
             locked =
               Enum.map(locked_rows, fn [s, ans, st] ->
                 %{session: s, answered: ans || 0, start: st || %{}}
               end)

             live_primary =
               Enum.find(locked, fn r ->
                 case r.start["is_primary"] do
                   true -> true
                   false -> false
                   _ -> (slot_of(r.start) || "lead") == "lead"
                 end
               end)

             live_primary_run = live_primary && live_primary.start["connector_run_id"]

             cond do
               is_nil(live_primary) ->
                 Repo.rollback(:primary_missing)

               fence_run? and is_binary(live_primary_run) and live_primary_run != "" and
                   live_primary_run != expected_run_id ->
                 Repo.rollback(:stale)

               true ->
                 locked_by_session = Map.new(locked, &{&1.session, &1})

                 {entries_to_add, sessions_to_delete} =
                   Enum.reduce(missing_rows, {[], []}, fn r, {entries, dels} ->
                     case Map.get(locked_by_session, r.session) do
                       nil ->
                         {entries, dels}

                       live when live.session == live_primary.session ->
                         {entries, dels}

                       live ->
                         snap_slot = slot_of(r.start) || "lead"
                         live_slot = slot_of(live.start) || snap_slot
                         snap_old_run = get_in(r.start || %{}, ["connector_run_id"])
                         live_run = live.start["connector_run_id"]

                         # Fence against a stale generation's absence receipt deleting a session
                         # that a newer generation C already recovered/rebound!
                         if live_slot != snap_slot or
                              (fence_run? and is_binary(live_run) and live_run != "" and
                                 live_run != expected_run_id and live_run != snap_old_run) do
                           Repo.rollback(:stale)
                         end

                         ans = max(r.answered || 0, live.answered)

                         entry = %{
                           "slot" => live_slot,
                           "is_primary" => false,
                           "agent_id" => r.agent_id,
                           "answered" => ans,
                           "invite_id" => SalixStore.Ids.new_session_id(),
                           "demoted_session" => live.session,
                           "demoted_binding_token" => live.start["binding_token"] || live.session,
                           "participant_id" =>
                             get_in(live.start, ["participant_id"]) ||
                               get_in(r.start || %{}, ["participant_id"]),
                           "start" =>
                             Map.drop(live.start, [
                               "connector_run_id",
                               "binding_token",
                               "claim_token",
                               "claim_confirmed",
                               "invite_id",
                               "committed_invite_ids"
                             ])
                         }

                         {entries ++ [entry], [live.session | dels]}
                     end
                   end)

                 if sessions_to_delete == [] do
                   :ok
                 else
                   existing_pending = List.wrap(live_primary.start["pending_multi_starts"])

                   next_pending =
                     Enum.reduce(entries_to_add, existing_pending, fn entry, acc ->
                       eslot = entry["slot"]

                       case Enum.find_index(acc, &(&1["slot"] == eslot)) do
                         nil ->
                           acc ++ [entry]

                         idx ->
                           List.update_at(acc, idx, fn prev ->
                             prev_ans =
                               if is_integer(prev["answered"]), do: prev["answered"], else: 0

                             prev
                             |> Map.put("answered", max(prev_ans, entry["answered"]))
                             |> Map.put("demoted_session", entry["demoted_session"])
                             |> Map.put("demoted_binding_token", entry["demoted_binding_token"])
                           end)
                       end
                     end)

                   with {:ok, _} <-
                          query(
                            """
                            UPDATE station_task_sessions
                            SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true)
                            WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                            """,
                            [group, conversation, device, live_primary.session, next_pending]
                          ),
                        {:ok, _} <-
                          query(
                            """
                            DELETE FROM station_task_sessions
                            WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                              AND session = ANY($4::text[])
                            """,
                            [group, conversation, device, sessions_to_delete]
                          ) do
                     :ok
                   else
                     {:error, reason} -> Repo.rollback(reason)
                   end
                 end
             end
           else
             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs `fun.()` inside a `Repo.transaction` holding the device-level
  `pg_advisory_xact_lock(group:conversation, device)` so workload version allocation
  and `station_task_sessions` binding writes share one serialized lock order.
  """
  def with_device_lock(group, conversation, device, fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           case lock_device_tx(group, conversation, device) do
             {:ok, _} ->
               case fun.() do
                 {:ok, val} -> val
                 :ok -> :ok
                 {:error, reason} -> Repo.rollback(reason)
                 other -> other
               end

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:ok, val} -> {:ok, val}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Monotonically advances `start["slot_seq_hwm"][slot]` on the device's primary row
  to `max(existing, seq)`. Safe to call inside an existing `with_device_lock`
  transaction or standalone.
  """
  def advance_slot_seq_hwm(group, conversation, device, slot, seq)
      when is_binary(slot) and slot != "" and is_integer(seq) and seq > 0 do
    do_advance = fn ->
      case query(
             """
             SELECT session, COALESCE((start->'slot_seq_hwm'->>$4)::bigint, 0)
             FROM station_task_sessions
             WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
             ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
             LIMIT 1
             FOR UPDATE
             """,
             [group, conversation, device, slot]
           ) do
        {:ok, %{rows: [[session, cur_hwm]]}} ->
          next_hwm = max(cur_hwm || 0, seq)

          query(
            """
            UPDATE station_task_sessions
            SET start = jsonb_set(
              jsonb_set(COALESCE(start, '{}'::jsonb), '{slot_seq_hwm}', COALESCE(start->'slot_seq_hwm', '{}'::jsonb), true),
              ARRAY['slot_seq_hwm', $5],
              to_jsonb($6::bigint),
              true
            )
            WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
            """,
            [group, conversation, device, session, slot, next_hwm]
          )
          |> ok()

        {:ok, %{rows: []}} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end

    if Repo.in_transaction?() do
      do_advance.()
    else
      with_device_lock(group, conversation, device, do_advance)
    end
  end

  defp pending_entry_matches?(cur, incoming) when is_map(cur) and is_map(incoming) do
    cur["start"] == incoming["start"] and
      cur["participant_id"] == incoming["participant_id"] and
      cur["agent_id"] == incoming["agent_id"]
  end

  defp pending_entry_matches?(_, _), do: false

  # Authoritative merge of `pending_multi_starts` inside a locked transaction:
  # `live_pending` is the authoritative base for any slot present in both lists (preserving
  # live `invite_id`, `pending_deactivation`, `refusal_reason`, `demoted_binding_token`,
  # `demoted_session`, `participant_id`, `attempts`, `next_retry_at`, and `start`, filling
  # only missing keys from `incoming`), while `answered` takes the max of live, incoming,
  # and `live_answered_by_slot[slot]`.
  defp merge_pending_entries(live_pending, incoming_pending, live_answered_by_slot) do
    incoming_by_slot =
      incoming_pending
      |> Enum.reduce(%{}, fn entry, acc ->
        eslot = entry["slot"]
        if is_binary(eslot) and eslot != "", do: Map.put_new(acc, eslot, entry), else: acc
      end)

    live_merged =
      live_pending
      |> Enum.reduce([], fn live_entry, acc ->
        eslot = live_entry["slot"]

        if is_binary(eslot) and eslot != "" and not Enum.any?(acc, &(&1["slot"] == eslot)) do
          inc = Map.get(incoming_by_slot, eslot) || %{}

          base =
            Enum.reduce(inc, live_entry, fn {k, v}, m ->
              if is_nil(Map.get(m, k)) and not is_nil(v), do: Map.put(m, k, v), else: m
            end)

          live_ans = if is_integer(live_entry["answered"]), do: live_entry["answered"], else: 0
          inc_ans = if is_integer(inc["answered"]), do: inc["answered"], else: 0
          slot_ans = Map.get(live_answered_by_slot, eslot, 0)

          merged_entry =
            base
            |> ensure_invite_id()
            |> Map.put("answered", Enum.max([live_ans, inc_ans, slot_ans]))

          acc ++ [merged_entry]
        else
          acc
        end
      end)

    live_slots = MapSet.new(live_merged, & &1["slot"])

    extra_incoming =
      incoming_pending
      |> Enum.reduce([], fn inc_entry, acc ->
        eslot = inc_entry["slot"]

        if is_binary(eslot) and eslot != "" and not MapSet.member?(live_slots, eslot) and
             not Enum.any?(acc, &(&1["slot"] == eslot)) do
          inc_ans = if is_integer(inc_entry["answered"]), do: inc_entry["answered"], else: 0
          slot_ans = Map.get(live_answered_by_slot, eslot, 0)

          merged_entry =
            inc_entry
            |> ensure_invite_id()
            |> Map.put("answered", max(inc_ans, slot_ans))

          acc ++ [merged_entry]
        else
          acc
        end
      end)

    live_merged ++ extra_incoming
  end

  defp merge_hwm_maps(maps) do
    merged =
      Enum.reduce(maps, %{}, fn
        %{} = m, acc ->
          Enum.reduce(m, acc, fn
            {k, v}, a when is_binary(k) and is_integer(v) and v > 0 ->
              Map.update(a, k, v, &max(&1, v))

            _, a ->
              a
          end)

        _, acc ->
          acc
      end)

    if map_size(merged) == 0, do: nil, else: merged
  end

  defp merge_pending_orphan_leaves(lists) when is_list(lists) do
    lists
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.reduce({[], MapSet.new()}, fn
      %{"slot" => slot, "session" => session, "claim_token" => token} = item, {acc, seen}
      when is_binary(slot) and slot != "" and is_binary(session) and
             is_binary(token) and token != "" ->
        key = {slot, session, token}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {acc ++ [item], MapSet.put(seen, key)}
        end

      _, state ->
        state
    end)
    |> elem(0)
  end

  @doc """
  Transactionally records an uncommitted orphan session leave entry
  `%{"slot" => slot, "session" => session, "claim_token" => claim_token}` on the
  device primary row's `start["pending_orphan_leaves"]` (deduped by
  `{slot, session, claim_token}`) so offline / crashed orphan revocations are
  durably retried on reconnect BEFORE `invite_secondary_list` runs.
  `session` may be `""` when revoking by `(slot, claim_token)` before a session id is known.
  """
  def record_pending_orphan_leave(
        group,
        conversation,
        device,
        %{"slot" => slot, "session" => session, "claim_token" => claim_token} = entry
      )
      when is_binary(slot) and slot != "" and is_binary(session) and
             is_binary(claim_token) and claim_token != "" do
    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device) do
             case query(
                    """
                    SELECT session, COALESCE(start->'pending_orphan_leaves', '[]'::jsonb)
                    FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                    LIMIT 1
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
               {:ok, %{rows: [[primary_session, current_leaves]]}} ->
                 existing = List.wrap(current_leaves)
                 next_leaves = merge_pending_orphan_leaves([existing, [entry]])

                 if next_leaves == existing do
                   :ok
                 else
                   case query(
                          """
                          UPDATE station_task_sessions
                          SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_orphan_leaves}', $5::jsonb, true)
                          WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                          """,
                          [group, conversation, device, primary_session, next_leaves]
                        ) do
                     {:ok, _} -> :ok
                     {:error, reason} -> Repo.rollback(reason)
                   end
                 end

               {:ok, %{rows: []}} ->
                 Repo.rollback(:primary_missing)

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Marks `start["claim_confirmed"] = true` for the given `sessions` that carry a non-empty
  `claim_token`, after Station confirms `task.put` with `confirmed_claims`.
  """
  def mark_claims_confirmed(_group, _conversation, _device, []), do: :ok

  def mark_claims_confirmed(group, conversation, device, sessions, expected_run_id \\ nil)

  def mark_claims_confirmed(_group, _conversation, _device, [], _expected_run_id), do: :ok

  def mark_claims_confirmed(group, conversation, device, sessions, expected_run_id)
      when is_list(sessions) and is_binary(expected_run_id) and expected_run_id != "" do
    query(
      """
      UPDATE station_task_sessions
      SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{claim_confirmed}', 'true'::jsonb, true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        AND session = ANY($4::text[])
        AND COALESCE(start->>'connector_run_id', '') = $5
        AND COALESCE(start->>'claim_token', '') <> ''
        AND COALESCE((start->>'claim_confirmed')::boolean, false) = false
      """,
      [group, conversation, device, sessions, expected_run_id]
    )
    |> ok()
  end

  def mark_claims_confirmed(group, conversation, device, sessions, _expected_run_id)
      when is_list(sessions) do
    query(
      """
      UPDATE station_task_sessions
      SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{claim_confirmed}', 'true'::jsonb, true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        AND session = ANY($4::text[])
        AND COALESCE(start->>'claim_token', '') <> ''
        AND COALESCE((start->>'claim_confirmed')::boolean, false) = false
      """,
      [group, conversation, device, sessions]
    )
    |> ok()
  end

  @doc """
  Resets `start["claim_confirmed"] = false` for the given `sessions` that carry a non-empty
  `claim_token` when Station explicitly excludes them from `committed_slots` (e.g. after
  restoring a pre-confirmation snapshot), so the next `do_put` re-sends `confirmed_claims`.
  When `expected_run_id` is provided, only rows still fenced to that generation are updated.
  """
  def mark_claims_unconfirmed(group, conversation, device, sessions, expected_run_id \\ nil)

  def mark_claims_unconfirmed(_group, _conversation, _device, [], _expected_run_id), do: :ok

  def mark_claims_unconfirmed(group, conversation, device, sessions, expected_run_id)
      when is_list(sessions) and is_binary(expected_run_id) and expected_run_id != "" do
    query(
      """
      UPDATE station_task_sessions
      SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{claim_confirmed}', 'false'::jsonb, true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        AND session = ANY($4::text[])
        AND COALESCE(start->>'connector_run_id', '') = $5
        AND COALESCE(start->>'claim_token', '') <> ''
        AND COALESCE((start->>'claim_confirmed')::boolean, false) = true
      """,
      [group, conversation, device, sessions, expected_run_id]
    )
    |> ok()
  end

  def mark_claims_unconfirmed(group, conversation, device, sessions, _expected_run_id)
      when is_list(sessions) do
    query(
      """
      UPDATE station_task_sessions
      SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{claim_confirmed}', 'false'::jsonb, true)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
        AND session = ANY($4::text[])
        AND COALESCE(start->>'claim_token', '') <> ''
        AND COALESCE((start->>'claim_confirmed')::boolean, false) = true
      """,
      [group, conversation, device, sessions]
    )
    |> ok()
  end

  @doc """
  Transactionally marks `"dispatched" => true` on the matching `{slot, expected_invite_id}`
  entry in the primary row's `start["pending_multi_starts"]` BEFORE `ask_invite` is sent.
  Linearized under `lock_device_tx`: returns `{:error, :pending_invite_not_found}` if the
  exact entry was already removed/superseded, and `{:error, :pending_deactivation}` if it
  was already locked for permanent deactivation.
  """
  def mark_pending_multi_start_dispatched(group, conversation, device, slot, expected_invite_id)
      when is_binary(slot) and slot != "" and is_binary(expected_invite_id) and
             expected_invite_id != "" do
    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device) do
             case query(
                    """
                    SELECT session, COALESCE(start->'pending_multi_starts', '[]'::jsonb)
                    FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                    LIMIT 1
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
               {:ok, %{rows: [[primary_session, current_pending]]}} ->
                 existing = List.wrap(current_pending)

                 case Enum.find(
                        existing,
                        &(&1["slot"] == slot and &1["invite_id"] == expected_invite_id)
                      ) do
                   nil ->
                     Repo.rollback(:pending_invite_not_found)

                   %{"pending_deactivation" => true} ->
                     Repo.rollback(:pending_deactivation)

                   %{"dispatched" => true} ->
                     :ok

                   _found ->
                     next_pending =
                       Enum.map(existing, fn entry ->
                         if entry["slot"] == slot and entry["invite_id"] == expected_invite_id do
                           Map.put(entry, "dispatched", true)
                         else
                           entry
                         end
                       end)

                     case query(
                            """
                            UPDATE station_task_sessions
                            SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true)
                            WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                            """,
                            [group, conversation, device, primary_session, next_pending]
                          ) do
                       {:ok, _} -> :ok
                       {:error, reason} -> Repo.rollback(reason)
                     end
                 end

               {:ok, %{rows: []}} ->
                 Repo.rollback(:pending_invite_not_found)

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transactionally updates per-entry retry backoff (`attempts`, `next_retry_at`) on the
  matching `{slot, session, claim_token}` item in the primary row's `start["pending_orphan_leaves"]`.
  """
  def update_pending_orphan_leave_backoff(
        group,
        conversation,
        device,
        slot,
        session,
        claim_token,
        meta
      )
      when is_binary(slot) and is_binary(session) and is_binary(claim_token) and is_map(meta) do
    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device) do
             case query(
                    """
                    SELECT session, COALESCE(start->'pending_orphan_leaves', '[]'::jsonb)
                    FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                    LIMIT 1
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
               {:ok, %{rows: [[primary_session, current_leaves]]}} ->
                 existing = List.wrap(current_leaves)

                 next_leaves =
                   Enum.map(existing, fn item ->
                     if item["slot"] == slot and item["session"] == session and
                          item["claim_token"] == claim_token do
                       Map.merge(item, meta)
                     else
                       item
                     end
                   end)

                 case query(
                        """
                        UPDATE station_task_sessions
                        SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_orphan_leaves}', $5::jsonb, true)
                        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                        """,
                        [group, conversation, device, primary_session, next_leaves]
                      ) do
                   {:ok, _} -> :ok
                   {:error, reason} -> Repo.rollback(reason)
                 end

               {:ok, %{rows: []}} ->
                 :ok

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transactionally removes the exact `{slot, session, claim_token}` entry from the
  device primary row's `start["pending_orphan_leaves"]` once Station confirms
  `task.leave`.
  """
  def remove_pending_orphan_leave(group, conversation, device, slot, session, claim_token)
      when is_binary(slot) and is_binary(session) and is_binary(claim_token) do
    case Repo.transaction(fn ->
           with {:ok, _} <- lock_device_tx(group, conversation, device) do
             case query(
                    """
                    SELECT session, COALESCE(start->'pending_orphan_leaves', '[]'::jsonb)
                    FROM station_task_sessions
                    WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                    ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                    LIMIT 1
                    FOR UPDATE
                    """,
                    [group, conversation, device]
                  ) do
               {:ok, %{rows: [[primary_session, current_leaves]]}} ->
                 existing = List.wrap(current_leaves)

                 kept =
                   Enum.reject(existing, fn item ->
                     item["slot"] == slot and item["session"] == session and
                       item["claim_token"] == claim_token
                   end)

                 update_res =
                   if kept == [] do
                     query(
                       """
                       UPDATE station_task_sessions
                       SET start = COALESCE(start, '{}'::jsonb) - 'pending_orphan_leaves'
                       WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                       """,
                       [group, conversation, device, primary_session]
                     )
                   else
                     query(
                       """
                       UPDATE station_task_sessions
                       SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_orphan_leaves}', $5::jsonb, true)
                       WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                       """,
                       [group, conversation, device, primary_session, kept]
                     )
                   end

                 case update_res do
                   {:ok, _} -> :ok
                   {:error, reason} -> Repo.rollback(reason)
                 end

               {:ok, %{rows: []}} ->
                 :ok

               {:error, reason} ->
                 Repo.rollback(reason)
             end
           else
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_invite_id(%{"invite_id" => id} = entry) when is_binary(id) and id != "", do: entry
  defp ensure_invite_id(entry), do: Map.put(entry, "invite_id", SalixStore.Ids.new_session_id())

  defp lock_device_tx(group, conversation, device) do
    query(
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      ["#{group}:#{conversation}", device]
    )
  end

  @doc """
  Transactionally updates per-slot retry metadata (`attempts`, `next_retry_at`) on the
  primary row's `start["pending_multi_starts"]` without touching `connector_run_id` or
  other concurrently appended slots.
  """
  def update_pending_multi_starts_backoff(_group, _conversation, _device, updates)
      when map_size(updates) == 0,
      do: :ok

  def update_pending_multi_starts_backoff(group, conversation, device, updates)
      when is_map(updates) do
    case Repo.transaction(fn ->
           case query(
                  """
                  SELECT session, COALESCE(start->'pending_multi_starts', '[]'::jsonb)
                  FROM station_task_sessions
                  WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                  ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                  LIMIT 1
                  FOR UPDATE
                  """,
                  [group, conversation, device]
                ) do
             {:ok, %{rows: [[session, current_pending]]}} ->
               existing = List.wrap(current_pending)

               next_pending =
                 Enum.map(existing, fn entry ->
                   case Map.get(updates, entry["slot"]) do
                     %{} = meta ->
                       expected_id = Map.get(meta, "expected_invite_id")
                       clean_meta = Map.delete(meta, "expected_invite_id")

                       if is_binary(expected_id) and expected_id != "" and
                            entry["invite_id"] != expected_id do
                         entry
                       else
                         Map.merge(entry, clean_meta)
                       end

                     nil ->
                       entry
                   end
                 end)

               case query(
                      """
                      UPDATE station_task_sessions
                      SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true)
                      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                      """,
                      [group, conversation, device, session, next_pending]
                    ) do
                 {:ok, _} -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end

             {:ok, %{rows: []}} ->
               :ok

             {:error, reason} ->
               Repo.rollback(reason)
           end
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Transactionally removes `slots_to_remove` from the primary row's
  `start["pending_multi_starts"]` using targeted Postgres JSONB operations
  (`jsonb_set` / `start - 'pending_multi_starts'`), preserving `connector_run_id`
  and any concurrently appended slots. Returns `{:ok, removed_count}`.
  """
  def remove_pending_multi_starts(group, conversation, device, slots_to_remove, opts \\ [])
      when is_list(slots_to_remove) and is_list(opts) do
    if slots_to_remove == [] do
      {:ok, 0}
    else
      record_orphan_claim? = Keyword.get(opts, :record_orphan_claim?, false) == true

      case Repo.transaction(fn ->
             with {:ok, _} <- lock_device_tx(group, conversation, device) do
               case query(
                      """
                      SELECT session,
                             COALESCE(start->'pending_multi_starts', '[]'::jsonb),
                             COALESCE(start->'pending_orphan_leaves', '[]'::jsonb)
                      FROM station_task_sessions
                      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                      ORDER BY CASE WHEN COALESCE((start->>'is_primary')::boolean, COALESCE(start->>'slot', 'lead') = 'lead') THEN 0 ELSE 1 END, session
                      LIMIT 1
                      FOR UPDATE
                      """,
                      [group, conversation, device]
                    ) do
                 {:ok, %{rows: [[session, current_pending, current_orphans]]}} ->
                   existing = List.wrap(current_pending)

                   {removed_entries, kept} =
                     Enum.split_with(existing, fn entry ->
                       Enum.any?(slots_to_remove, fn
                         {target_slot, expected_id, mode}
                         when mode in [:record_orphan, :record_orphan_if_dispatched] and
                                is_binary(expected_id) and expected_id != "" ->
                           entry["slot"] == target_slot and entry["invite_id"] == expected_id

                         {target_slot, expected_id}
                         when is_binary(expected_id) and expected_id != "" ->
                           entry["slot"] == target_slot and entry["invite_id"] == expected_id

                         {target_slot, _} ->
                           entry["slot"] == target_slot

                         target_slot when is_binary(target_slot) ->
                           entry["slot"] == target_slot

                         _ ->
                           false
                       end)
                     end)

                   removed = length(removed_entries)

                   candidate_orphans =
                     Enum.filter(removed_entries, fn entry ->
                       entry_dispatched? =
                         entry["dispatched"] == true or
                           (is_integer(entry["attempts"]) and entry["attempts"] > 0)

                       record_orphan_claim? or
                         Enum.any?(slots_to_remove, fn
                           {target_slot, expected_id, :record_orphan}
                           when is_binary(expected_id) and expected_id != "" ->
                             entry["slot"] == target_slot and entry["invite_id"] == expected_id

                           {target_slot, expected_id, :record_orphan_if_dispatched}
                           when is_binary(expected_id) and expected_id != "" ->
                             entry["slot"] == target_slot and entry["invite_id"] == expected_id and
                               entry_dispatched?

                           _ ->
                             false
                         end)
                     end)

                   orphan_entries =
                     if candidate_orphans == [] do
                       []
                     else
                       case query(
                              """
                              SELECT COALESCE(start->>'slot', 'lead'),
                                     COALESCE(start->>'invite_id', ''),
                                     COALESCE(start->>'claim_token', ''),
                                     COALESCE(start->'committed_invite_ids', '[]'::jsonb)
                              FROM station_task_sessions
                              WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
                                AND session <> ''
                              """,
                              [group, conversation, device]
                            ) do
                         {:ok, %{rows: active_rows}} ->
                           committed_slot_ids =
                             Enum.reduce(active_rows, MapSet.new(), fn [
                                                                         aslot,
                                                                         ainvite,
                                                                         aclaim,
                                                                         acommitted
                                                                       ],
                                                                       acc ->
                               ids =
                                 [ainvite, aclaim | List.wrap(acommitted)]
                                 |> Enum.filter(&(is_binary(&1) and &1 != ""))

                               Enum.reduce(ids, acc, &MapSet.put(&2, {aslot, &1}))
                             end)

                           Enum.reject(candidate_orphans, fn entry ->
                             MapSet.member?(
                               committed_slot_ids,
                               {entry["slot"], entry["invite_id"]}
                             )
                           end)

                         {:error, reason} ->
                           Repo.rollback(reason)
                       end
                     end

                   new_orphans =
                     if orphan_entries != [] do
                       added =
                         for entry <- orphan_entries,
                             eslot = entry["slot"],
                             eid = entry["invite_id"],
                             is_binary(eslot) and eslot != "" and is_binary(eid) and eid != "" do
                           %{"slot" => eslot, "session" => "", "claim_token" => eid}
                         end

                       merge_pending_orphan_leaves([List.wrap(current_orphans), added])
                     else
                       nil
                     end

                   update_res =
                     cond do
                       kept == [] and is_list(new_orphans) and new_orphans != [] ->
                         query(
                           """
                           UPDATE station_task_sessions
                           SET start = jsonb_set(COALESCE(start, '{}'::jsonb) - 'pending_multi_starts', '{pending_orphan_leaves}', $5::jsonb, true)
                           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                           """,
                           [group, conversation, device, session, new_orphans]
                         )

                       kept == [] ->
                         query(
                           """
                           UPDATE station_task_sessions
                           SET start = COALESCE(start, '{}'::jsonb) - 'pending_multi_starts'
                           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                           """,
                           [group, conversation, device, session]
                         )

                       is_list(new_orphans) and new_orphans != [] ->
                         query(
                           """
                           UPDATE station_task_sessions
                           SET start = jsonb_set(
                             jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true),
                             '{pending_orphan_leaves}',
                             $6::jsonb,
                             true
                           )
                           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                           """,
                           [group, conversation, device, session, kept, new_orphans]
                         )

                       true ->
                         query(
                           """
                           UPDATE station_task_sessions
                           SET start = jsonb_set(COALESCE(start, '{}'::jsonb), '{pending_multi_starts}', $5::jsonb, true)
                           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
                           """,
                           [group, conversation, device, session, kept]
                         )
                     end

                   case update_res do
                     {:ok, _} -> removed
                     {:error, reason} -> Repo.rollback(reason)
                   end

                 {:ok, %{rows: []}} ->
                   0

                 {:error, reason} ->
                   Repo.rollback(reason)
               end
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
        {:ok, removed} -> {:ok, removed}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  A Session of `device` ended a turn with the Message `seq`: it answered what
  the station had been given by then (`sent`), no further than `seq`. A Message
  the station was not given yet is not answered by it.
  """
  def ended_turn(group, conversation, device, seq) do
    query(
      """
      UPDATE station_task_sessions SET answered = GREATEST(COALESCE(answered, 0), LEAST(sent, $4))
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
      """,
      [group, conversation, device, seq]
    )
    |> ok()
  end

  @doc """
  Updates ONLY the exact `(device, session)` row with
  `GREATEST(COALESCE(answered, 0), LEAST(post_seq, answered_through_seq))`
  (never capped by a lagging `sent` watermark).
  """
  def ended_turn(group, conversation, device, session, post_seq, answered_through_seq)
      when is_binary(session) and is_integer(post_seq) and is_integer(answered_through_seq) do
    query(
      """
      UPDATE station_task_sessions
      SET answered = GREATEST(COALESCE(answered, 0), LEAST($5::bigint, $6::bigint))
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
      """,
      [group, conversation, device, session, post_seq, answered_through_seq]
    )
    |> ok()
  end

  @doc "`device`'s Sessions of the Task from before `answered` was kept answered it through `seq`, as the Task says."
  def answered(group, conversation, device, seq) do
    query(
      """
      UPDATE station_task_sessions SET answered = $4
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND answered IS NULL
      """,
      [group, conversation, device, seq]
    )
    |> ok()
  end

  @doc "`device` no longer takes part in the Task: it is given nothing more of it."
  def leave(group, conversation, device) do
    query(
      "DELETE FROM station_task_sessions WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3",
      [group, conversation, device]
    )
    |> ok()
  end

  @doc """
  Deletes only the awaited placeholder row (`session = @awaited`) for `(group, conversation, device)`.
  Returns `{:ok, :deleted}` when removed or `{:ok, :stale}` when absent or already replaced by an
  active session, never touching active bindings.
  """
  def leave_awaited(group, conversation, device) do
    case query(
           """
           DELETE FROM station_task_sessions
           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
           """,
           [group, conversation, device, @awaited]
         ) do
      {:ok, %{num_rows: n}} when n > 0 -> {:ok, :deleted}
      {:ok, _} -> {:ok, :stale}
      {:error, _} = err -> err
    end
  end

  defp rows(sql, params) do
    case query(sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             tenant,
                             group,
                             conversation,
                             device,
                             session,
                             agent,
                             sent,
                             start,
                             answered
                           ] ->
           %{
             tenant_id: tenant,
             group_id: group,
             conversation_id: conversation,
             device_id: device,
             session: session,
             agent_id: agent,
             sent: sent,
             start: start,
             answered: answered
           }
         end)}

      error ->
        error
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(error), do: error

  defp query(sql, params), do: Repo.query(sql, params)
end
