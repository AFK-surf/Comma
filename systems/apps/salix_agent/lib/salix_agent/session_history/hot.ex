defmodule SalixAgent.SessionHistory.Hot do
  @moduledoc "Transactional recent-history projection and continuous handoff positions."
  alias SalixStore.SessionHistoryRepo, as: Repo
  @states "agent_session_history_states"
  @docs "agent_session_history_documents"

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

  def snapshot(agent, session, search, ceiling, before_seq, before_part, limit) do
    transaction(fn ->
      # The row lock also prevents cleanup between the boundary and document reads.
      lock(agent, session)
      position = state(agent, session)

      rows =
        query(
          """
          SELECT seq,part,text,kind,tool_name,label FROM #{@docs}
          WHERE agent_id=$1 AND session_id=$2 AND seq>$3 AND seq<=$4
            AND (seq,part)<($5,$6)
            AND (($7::text IS NULL AND part=0) OR text LIKE $7 ESCAPE '\\')
          ORDER BY seq DESC,part DESC LIMIT $8
          """,
          [
            agent,
            session,
            position.cold,
            ceiling,
            before_seq,
            before_part,
            pattern(search),
            limit
          ]
        ).rows

      {position, decode(rows)}
    end)
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
