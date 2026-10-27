defmodule SalixAgent.SessionHistory.Hot do
  @moduledoc "Transactional recent-history projection and continuous handoff positions."
  alias SalixStore.SessionHistoryRepo, as: Repo
  @states "agent_session_history_states"
  @docs "agent_session_history_documents"
  @first_window 128
  @min_window 16
  @max_window 8_192

  def track(agent, session) do
    query("INSERT INTO #{@states} (agent_id, session_id) VALUES ($1,$2) ON CONFLICT DO NOTHING", [
      agent,
      session
    ])
  end

  def state(agent, session) do
    case query(
           "SELECT indexed_through,cold_through FROM #{@states} WHERE agent_id=$1 AND session_id=$2",
           [agent, session]
         ).rows do
      [[indexed, cold]] -> %{indexed: indexed, cold: cold}
      [] -> %{indexed: 0, cold: 0}
    end
  end

  def due do
    query(
      """
      UPDATE #{@states} SET checked_at=now() WHERE (agent_id,session_id) IN
        (SELECT agent_id,session_id FROM #{@states} ORDER BY checked_at LIMIT 1 FOR UPDATE SKIP LOCKED)
      RETURNING agent_id,session_id
      """,
      []
    ).rows
  end

  def pending_part(agent, session, seq) do
    [[part]] =
      query(
        "SELECT coalesce(max(part)+1,0) FROM #{@docs} WHERE agent_id=$1 AND session_id=$2 AND seq=$3",
        [agent, session, seq]
      ).rows

    part
  end

  def append(agent, session, expected, through, documents) do
    transaction(fn ->
      lock(agent, session)
      if state(agent, session).indexed != expected, do: Repo.rollback(:stale)

      insert(agent, session, documents)

      query("UPDATE #{@states} SET indexed_through=$3 WHERE agent_id=$1 AND session_id=$2", [
        agent,
        session,
        through
      ])
    end)
  end

  def recent(agent, session, documents) do
    transaction(fn ->
      lock(agent, session)
      cold = state(agent, session).cold
      insert(agent, session, Enum.filter(documents, &(&1["seq"] > cold)))
    end)
  end

  defp insert(agent, session, documents) do
    Enum.each(documents, fn doc ->
      query(
        "INSERT INTO #{@docs} (agent_id,session_id,seq,part,text,kind,tool_name,label) VALUES ($1,$2,$3,$4,$5,$6,$7,$8) ON CONFLICT DO NOTHING",
        [
          agent,
          session,
          doc["seq"],
          doc["part"],
          doc["text"],
          doc["kind"],
          doc["tool_name"],
          doc["label"]
        ]
      )
    end)
  end

  # Returns {position, rows, resume}. A text search scans seq windows newest
  # first until it has `limit` rows or spends its time budget. resume is the
  # {seq, part} to continue below, or nil when the hot range is exhausted.
  def snapshot(agent, session, search, ceiling, before_seq, before_part, limit) do
    transaction(fn ->
      # The row lock also prevents cleanup between the boundary and document reads.
      lock(agent, session)
      position = state(agent, session)
      deadline = SystemsClock.monotonic_time(:millisecond) + scan_budget_ms()
      scope = {agent, session, pattern(search), position.cold, ceiling, limit, deadline}
      {rows, resume} = scan(scope, {before_seq, before_part}, [], search && @first_window)
      {position, decode(rows), resume}
    end)
  end

  # A listing reads only part 0 in primary-key order, so one query stops early.
  defp scan({agent, session, nil, floor, ceiling, limit, _}, {seq, part}, [], nil),
    do: {window(agent, session, nil, floor, ceiling, {seq, part}, limit), nil}

  # A text match filters every row it reads, so each query covers a bounded seq
  # window that stays inside statement_timeout however large the session is.
  defp scan(scope, {seq, part}, acc, size) do
    {agent, session, pattern, floor, ceiling, limit, deadline} = scope
    low = max(floor, min(ceiling, seq) - size)
    started = SystemsClock.monotonic_time(:millisecond)
    rows = window(agent, session, pattern, low, ceiling, {seq, part}, limit - length(acc))
    now = SystemsClock.monotonic_time(:millisecond)
    acc = acc ++ rows

    cond do
      length(acc) >= limit or low <= floor -> {acc, nil}
      now >= deadline -> {acc, {low + 1, 0}}
      true -> scan(scope, {low + 1, 0}, acc, resize(size, now - started))
    end
  end

  defp scan_budget_ms,
    do: SystemsRuntime.get_env(:salix_agent, :session_history_scan_budget_ms, 1_500)

  defp resize(size, elapsed) when elapsed < 50, do: min(size * 2, @max_window)
  defp resize(size, elapsed) when elapsed > 150, do: max(div(size, 2), @min_window)
  defp resize(size, _elapsed), do: size

  defp window(agent, session, pattern, low, ceiling, {seq, part}, limit) do
    query(
      """
      SELECT seq,part,text,kind,tool_name,label FROM #{@docs}
      WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4
        AND (seq,part)<($5,$6)
        AND (($7::text IS NULL AND part=0) OR text LIKE $7 ESCAPE '\\')
      ORDER BY seq DESC,part DESC LIMIT $8
      """,
      [agent, session, low, ceiling, seq, part, pattern, limit]
    ).rows
  end

  # Moves a session that a lookup found behind to the front of maintenance.
  # Best effort: a lookup still answers if this write fails.
  def prioritize(agent, session) do
    query("UPDATE #{@states} SET checked_at='-infinity' WHERE agent_id=$1 AND session_id=$2", [
      agent,
      session
    ])

    :ok
  rescue
    _ -> :ok
  end

  def transfer_batch(agent, session) do
    transaction(fn ->
      lock(agent, session)
      position = state(agent, session)
      ceiling = max(position.cold, position.indexed - 256)

      rows =
        query(
          """
          SELECT seq,part,text,kind,tool_name,label FROM #{@docs}
          WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4
          ORDER BY seq,part LIMIT 129
          """,
          [agent, session, position.cold, ceiling]
        ).rows

      # Never hand off a partial record. A very large record stays in PG.
      through =
        if length(rows) > 128, do: max(position.cold, hd(List.last(rows)) - 1), else: ceiling

      {position.cold, through, rows |> Enum.filter(&(hd(&1) <= through)) |> decode()}
    end)
  end

  def release(agent, session, expected, through) do
    transaction(fn ->
      lock(agent, session)
      if state(agent, session).cold != expected, do: Repo.rollback(:stale)

      query("UPDATE #{@states} SET cold_through=$3 WHERE agent_id=$1 AND session_id=$2", [
        agent,
        session,
        through
      ])

      query("DELETE FROM #{@docs} WHERE agent_id=$1 AND session_id=$2 AND seq<=$3", [
        agent,
        session,
        through
      ])
    end)
  end

  def discovery_cursor do
    [[cursor]] = query("SELECT cursor FROM agent_session_history_discovery WHERE id=1", []).rows
    cursor
  end

  def advance_discovery(old, new) do
    query(
      "UPDATE agent_session_history_discovery SET cursor=$2 WHERE id=1 AND cursor IS NOT DISTINCT FROM $1",
      [old, new]
    )
  end

  defp lock(agent, session),
    do:
      query(
        "SELECT indexed_through FROM #{@states} WHERE agent_id=$1 AND session_id=$2 FOR UPDATE",
        [agent, session]
      )

  defp decode(rows),
    do: Enum.map(rows, &Map.new(Enum.zip(~w(seq part text kind tool_name label), &1)))

  defp pattern(nil), do: nil

  defp pattern(text),
    do:
      "%" <>
        (text
         |> String.replace("\\", "\\\\")
         |> String.replace("%", "\\%")
         |> String.replace("_", "\\_")) <> "%"

  def transaction(fun) do
    Repo.transaction(
      fn ->
        query("SET LOCAL statement_timeout='500ms'", [])
        query("SET LOCAL lock_timeout='100ms'", [])
        fun.()
      end,
      timeout: 5_000
    )
  end

  defp query(sql, params),
    do: Ecto.Adapters.SQL.query!(Repo, sql, params, timeout: 2_000, log: false)
end
