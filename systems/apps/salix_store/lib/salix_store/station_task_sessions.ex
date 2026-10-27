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
  def join(
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
    with {:ok, _} <-
           query(
             """
             INSERT INTO station_task_sessions (#{@columns}, joined_at)
             VALUES ($1, $2, $3, $4, $5, $6, 0, $7, 0, $8)
             ON CONFLICT (group_id, conversation_id, device_id, session) DO NOTHING
             """,
             [
               tenant,
               group,
               conversation,
               device,
               session,
               agent,
               row[:start],
               SystemsClock.system_time(:millisecond)
             ]
           ) do
      query(
        """
        DELETE FROM station_task_sessions
        WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
        """,
        [group, conversation, device, @awaited]
      )
      |> ok()
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

  @doc "The Sessions of other stations taking part in the Task."
  def of_task(group, conversation) do
    rows(
      "SELECT #{@columns} FROM station_task_sessions WHERE group_id = $1 AND conversation_id = $2",
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

  @doc "Every Session of another station taking part in a Task here: what Salix gives on starting."
  def all do
    rows("SELECT #{@columns} FROM station_task_sessions", [])
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
      WHERE start IS NULL #{after_key}
      ORDER BY group_id, conversation_id, device_id, session
      LIMIT $1
      """,
      params
    )
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
           UPDATE station_task_sessions SET start = $5
           WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND session = $4
             AND start IS NULL
           """,
           [group, conversation, device, session, start]
         ) do
      {:ok, %{num_rows: kept}} -> {:ok, kept == 1}
      error -> error
    end
  end

  @doc "`device`'s Sessions of the Task were given it through `seq`."
  def sent(group, conversation, device, seq) do
    query(
      """
      UPDATE station_task_sessions SET sent = GREATEST(sent, $4)
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3
      """,
      [group, conversation, device, seq]
    )
    |> ok()
  end

  @doc """
  `device` has the Task only through `fetched` (it said so in its hello): what
  it was given after that is given again.
  """
  def fetched(group, conversation, device, fetched) do
    query(
      """
      UPDATE station_task_sessions SET sent = $4
      WHERE group_id = $1 AND conversation_id = $2 AND device_id = $3 AND sent > $4
      """,
      [group, conversation, device, fetched]
    )
    |> ok()
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
