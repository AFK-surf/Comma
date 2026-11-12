defmodule SalixAgent.SessionHistory.Hot do
  @moduledoc "Transactional recent-history projection and continuous handoff positions."
  alias SalixStore.SessionHistoryRepo, as: Repo
  @states "agent_session_history_states"
  @docs "agent_session_history_documents"
  @first_window 128
  @min_window 16
  @max_window 8_192

  def state(agent, session) do
    case query(
           "SELECT indexed_through,cold_through,target_seq,checked_at<=now() FROM #{@states} WHERE agent_id=$1 AND session_id=$2",
           [agent, session]
         ).rows do
      [[indexed, cold, target, ready]] ->
        %{indexed: indexed, cold: cold, target: target, transfer_ready: ready}

      [] ->
        %{indexed: 0, cold: 0, target: 0, transfer_ready: false}
    end
  end

  def due(cursor \\ nil) do
    condition = if cursor, do: "AND (agent_id,session_id)>($1,$2)", else: ""

    candidates =
      query(
        """
        WITH candidates AS MATERIALIZED (
          SELECT agent_id,session_id,indexed_through,cold_through,target_seq,checked_at FROM #{@states}
          WHERE (target_seq>indexed_through OR cold_through<GREATEST(indexed_through-256,0))
            #{condition}
          ORDER BY agent_id,session_id LIMIT 128
        )
        SELECT c.agent_id,c.session_id,
          (c.target_seq>c.indexed_through OR (c.checked_at<=now() AND
           (first.seq IS NULL OR first.seq>c.cold_through+1 OR
           NOT EXISTS (SELECT 1 FROM #{@docs} d WHERE d.agent_id=c.agent_id AND d.session_id=c.session_id
             AND d.seq=first.seq AND d.part>=128 LIMIT 1)))) AS eligible
        FROM candidates c
        LEFT JOIN LATERAL (
          SELECT d.seq FROM #{@docs} d WHERE d.agent_id=c.agent_id AND d.session_id=c.session_id
            AND d.seq>c.cold_through AND d.seq<=GREATEST(c.indexed_through-256,0)
          ORDER BY d.seq,d.part LIMIT 1
        ) first ON true
        ORDER BY c.agent_id,c.session_id
        """,
        cursor || []
      ).rows

    work = for [agent, session, true] <- candidates, do: [agent, session]
    cursor = if length(candidates) == 128, do: Enum.take(List.last(candidates), 2)
    {work, cursor}
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

  def transfer_batch(agent, session) do
    transaction(fn ->
      lock(agent, session)
      position = state(agent, session)
      ceiling = max(position.cold, position.indexed - 256)

      if not position.transfer_ready or ceiling == position.cold do
        {position.cold, position.cold, []}
      else
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
      end
    end)
  end

  # A failed confirmation keeps the hot rows and shares its retry time across pods.
  # The captured frontier prevents an older failure from delaying newer progress.
  def defer_transfer(agent, session, expected) do
    query(
      "UPDATE #{@states} SET checked_at=now()+interval '5 seconds' WHERE agent_id=$1 AND session_id=$2 AND cold_through=$3",
      [agent, session, expected]
    )

    :ok
  end

  def release(agent, session, expected, through) do
    transaction(fn ->
      lock(agent, session)
      if state(agent, session).cold != expected, do: Repo.rollback(:stale)

      query(
        "UPDATE #{@states} SET cold_through=$3,checked_at=now() WHERE agent_id=$1 AND session_id=$2",
        [
          agent,
          session,
          through
        ]
      )

      query("DELETE FROM #{@docs} WHERE agent_id=$1 AND session_id=$2 AND seq<=$3", [
        agent,
        session,
        through
      ])
    end)
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
