defmodule SalixStore.MeetingPersonalPreparation do
  @moduledoc "Postgres records for fixed meeting recipients, private reports and personal choices."

  alias SalixStore.Repo

  @batch_size 20
  def batch_size, do: @batch_size

  def ensure_roster(identity, emails) when is_list(emails) do
    execute(
      """
      INSERT INTO meeting_personal_preparations
        (group_id, meeting_plan_id, dispatch_revision, roster, source_roster_count, group_scan_complete)
      VALUES ($1, $2, $3, $4, jsonb_array_length($4::jsonb), false)
      ON CONFLICT (group_id, meeting_plan_id, dispatch_revision) DO NOTHING
      """,
      identity ++ [emails]
    )
  end

  # The source returns one roster. Freeze it once; later tool calls read only
  # one bounded slice and never repeat all Slack identity lookups.
  def roster_page(identity, offset) when is_integer(offset) and offset >= 0 do
    case query(
           """
           SELECT ARRAY(
             SELECT roster->>n::integer
             FROM generate_series($4::bigint, LEAST($4::bigint + $5::integer, jsonb_array_length(roster)) - 1) AS indexes(n)
           ), jsonb_array_length(roster), group_scan_complete
           FROM meeting_personal_preparations
           WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
           """,
           identity ++ [offset, @batch_size]
         ) do
      {:ok, %{rows: [[emails, total, complete]]}} ->
        {:ok,
         %{
           "emails" => emails,
           "next_cursor" =>
             if(offset + @batch_size < total or not complete,
               do: min(offset + @batch_size, total)
             ),
           "total_attendees" => total,
           "group_scan_pending" => not complete and offset >= total
         }}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  # Scan only the original Calendar attendee slice. Appended group members are
  # recipients, never candidates for recursive expansion.
  def group_scan_page(identity) do
    case query(
           """
           SELECT ARRAY(
             SELECT roster->>n::integer
             FROM generate_series(group_scan_cursor::bigint,
               LEAST(group_scan_cursor::bigint + $4::integer, source_roster_count) - 1) AS indexes(n)
           ), group_scan_cursor, source_roster_count, group_scan_complete
           FROM meeting_personal_preparations
           WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
           """,
           identity ++ [@batch_size]
         ) do
      {:ok, %{rows: [[emails, cursor, total, false]]}} ->
        {:ok,
         %{
           "emails" => emails,
           "cursor" => cursor,
           "next_cursor" => min(cursor + @batch_size, total)
         }}

      {:ok, %{rows: [[_emails, _cursor, _total, true]]}} ->
        {:ok, :complete}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  def append_group_members(identity, cursor, next_cursor, members) when is_list(members) do
    case query(
           """
           WITH advanced AS (
             UPDATE meeting_personal_preparations p
             SET roster = p.roster || COALESCE((
               SELECT jsonb_agg(email ORDER BY first_ordinal)
               FROM (
                 SELECT DISTINCT ON (member->>'email')
                   member->>'email' AS email, ordinal AS first_ordinal
                 FROM jsonb_array_elements($6::jsonb) WITH ORDINALITY AS source(member, ordinal)
                 WHERE NOT p.roster ? (member->>'email')
                 ORDER BY member->>'email', ordinal
               ) additions
             ), '[]'::jsonb),
             group_scan_cursor = $5,
             group_scan_complete = $5 >= p.source_roster_count
             WHERE p.group_id = $1 AND p.meeting_plan_id = $2 AND p.dispatch_revision = $3
               AND p.group_scan_cursor = $4 AND NOT p.group_scan_complete
             RETURNING 1
           ), memberships AS (
             INSERT INTO meeting_personal_group_memberships
               (group_id, meeting_plan_id, dispatch_revision, email, group_email)
             SELECT $1, $2, $3, member->>'email', member->>'group_email'
             FROM jsonb_array_elements($6::jsonb) AS source(member), advanced
             ON CONFLICT DO NOTHING
             RETURNING 1
           ) SELECT EXISTS (SELECT 1 FROM advanced)
           """,
           identity ++ [cursor, next_cursor, members]
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, %{rows: [[false]]}} -> {:error, :personal_preparation_page_out_of_order}
      {:error, _} = error -> error
    end
  end

  def group_sources(identity, emails) when is_list(emails) and length(emails) <= @batch_size do
    case query(
           """
           SELECT email, group_email FROM meeting_personal_group_memberships
           WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
             AND email = ANY($4::text[])
           """,
           identity ++ [emails]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.group_by(rows, &hd/1, &List.last/1)}

      {:error, _} = error ->
        error
    end
  end

  def ensure(identity, recipients, offset)
      when is_list(recipients) and length(recipients) <= @batch_size do
    with {:ok, %{rows: [[true]]}} <-
           query(
             """
             WITH advanced AS (
               UPDATE meeting_personal_preparations
               SET resolved_count = GREATEST(resolved_count, LEAST($5 + $6, jsonb_array_length(roster)))
               WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
                 AND resolved_count >= $5 AND $5 <= jsonb_array_length(roster)
               RETURNING 1
             ), saved AS (
               INSERT INTO meeting_personal_recipients
                 (group_id, meeting_plan_id, dispatch_revision, user_id, recipient)
               SELECT $1, $2, $3, recipient->>'user_id', recipient
               FROM jsonb_array_elements($4::jsonb) AS source(recipient), advanced
               ON CONFLICT (group_id, meeting_plan_id, dispatch_revision, user_id) DO NOTHING
               RETURNING 1
             ) SELECT EXISTS (SELECT 1 FROM advanced)
             """,
             identity ++ [recipients, offset, @batch_size]
           ),
         {:ok, %{rows: rows}} <-
           query(
             """
             SELECT user_id, recipient FROM meeting_personal_recipients
             WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
               AND user_id = ANY($4::text[])
             """,
             identity ++ [Enum.map(recipients, & &1["user_id"])]
           ) do
      saved = Map.new(rows, fn [user_id, recipient] -> {user_id, recipient} end)
      {:ok, %{"recipients" => Enum.map(recipients, &Map.fetch!(saved, &1["user_id"]))}}
    else
      {:ok, %{rows: [[false]]}} -> {:error, :personal_preparation_page_out_of_order}
      {:error, _} = error -> error
    end
  end

  def discovery_cursor(identity) do
    case query(
           """
           SELECT CASE WHEN resolved_count < jsonb_array_length(roster) OR NOT group_scan_complete
             THEN resolved_count END
           FROM meeting_personal_preparations
           WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
           """,
           identity
         ) do
      {:ok, %{rows: []}} -> {:ok, 0}
      {:ok, %{rows: [[cursor]]}} -> {:ok, cursor}
      {:error, _} = error -> error
    end
  end

  # At reminder time, admit a bounded page even when research has no result.
  # Keep report NULL: reminder delivery does not establish completed research.
  def admit_reminders(identity) do
    execute(
      """
      UPDATE meeting_personal_recipients SET delivery_status = 'prepared'
      WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
        AND delivery_status = 'unprepared'
        AND user_id IN (
          SELECT user_id FROM meeting_personal_recipients
          WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
            AND delivery_status = 'unprepared'
          ORDER BY user_id LIMIT $4
        )
      """,
      identity ++ [@batch_size]
    )
  end

  def get_recipient(identity, user_id) do
    case query(
           """
           SELECT recipient, report, delivery_status FROM meeting_personal_recipients
           WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3 AND user_id = $4
           """,
           identity ++ [user_id]
         ) do
      {:ok, %{rows: [[recipient, report, status]]}} ->
        {:ok, with_report(recipient, report, status)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} = error ->
        error
    end
  end

  # The first body, source evidence and author become durable in one update.
  # Recipient identity is fixed before that update and never replaced by retries.
  def save_report(identity, user_id, report) do
    with :ok <-
           execute(
             """
             UPDATE meeting_personal_recipients
             SET report = $5::jsonb, delivery_status = $6
             WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3 AND user_id = $4
               AND report IS NULL AND delivery_status = 'unprepared'
             """,
             identity ++ [user_id, Map.delete(report, "status"), report["status"]]
           ),
         {:ok, recipient} <- get_recipient(identity, user_id) do
      {:ok, get_in(recipient, ["report", "status"])}
    end
  end

  # Discovery and preparation are separate from the delivery queue. An empty
  # queue cannot prove either was completed. Page progress advances atomically
  # with its recipients, including empty pages of opted-out or unmatched users.
  def research_complete?(identity) do
    case query(
           """
           SELECT EXISTS (
             SELECT 1 FROM meeting_personal_preparations p
             WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
               AND resolved_count = jsonb_array_length(roster) AND group_scan_complete
               AND NOT EXISTS (
                 SELECT 1 FROM meeting_personal_recipients r
                 WHERE r.group_id = p.group_id AND r.meeting_plan_id = p.meeting_plan_id
                   AND r.dispatch_revision = p.dispatch_revision AND r.report IS NULL
               )
           )
           """,
           identity
         ) do
      {:ok, %{rows: [[complete]]}} -> {:ok, complete}
      {:error, _} = error -> error
    end
  end

  def pending(identity, now) do
    with {:ok, %{rows: rows}} <-
           query(
             """
             SELECT recipient, report, delivery_status FROM meeting_personal_recipients
             WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
               AND delivery_status = 'prepared' AND next_attempt_at_ms <= $4
             ORDER BY next_attempt_at_ms, user_id LIMIT $5
             """,
             identity ++ [now, @batch_size]
           ) do
      {:ok,
       Enum.map(rows, fn [recipient, report, status] -> with_report(recipient, report, status) end)}
    end
  end

  def has_pending?(identity) do
    case query(
           """
           SELECT EXISTS (SELECT 1 FROM meeting_personal_recipients
           WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
             AND delivery_status IN ('unprepared', 'prepared'))
           """,
           identity
         ) do
      {:ok, %{rows: [[pending]]}} -> {:ok, pending}
      {:error, _} = error -> error
    end
  end

  def settle(identity, user_id, status) do
    execute(
      """
      UPDATE meeting_personal_recipients SET delivery_status = $5
      WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3 AND user_id = $4
        AND delivery_status = 'prepared'
      """,
      identity ++ [user_id, status]
    )
  end

  def defer(identity, user_id, retry_at, reason) do
    execute(
      """
      UPDATE meeting_personal_recipients SET next_attempt_at_ms = $5, delivery_error = $6
      WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3 AND user_id = $4
        AND delivery_status = 'prepared'
      """,
      identity ++ [user_id, retry_at, String.slice(inspect(reason), 0, 400)]
    )
  end

  def expire(identity) do
    execute(
      """
      UPDATE meeting_personal_recipients SET delivery_status = 'expired'
      WHERE group_id = $1 AND meeting_plan_id = $2 AND dispatch_revision = $3
        AND delivery_status IN ('unprepared', 'prepared')
      """,
      identity
    )
  end

  defp with_report(recipient, nil, _status), do: recipient

  defp with_report(recipient, report, status),
    do: Map.put(recipient, "report", Map.put(report, "status", status))

  def enabled?(group_id, connect_id, user_id) do
    case query(
           """
           SELECT enabled FROM meeting_personal_preferences
           WHERE group_id = $1 AND connect_id = $2 AND user_id = $3
           """,
           [group_id, connect_id, user_id]
         ) do
      {:ok, %{rows: [[enabled]]}} -> {:ok, enabled}
      {:ok, %{rows: []}} -> {:ok, true}
      {:error, _} = error -> error
    end
  end

  def set_preference(group_id, connect_id, user_id, enabled) do
    execute(
      """
      INSERT INTO meeting_personal_preferences (group_id, connect_id, user_id, enabled)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (group_id, connect_id, user_id) DO UPDATE SET enabled = EXCLUDED.enabled
      """,
      [group_id, connect_id, user_id, enabled]
    )
  end

  defp execute(sql, params) do
    case query(sql, params) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp query(sql, params) do
    case Repo.query(sql, params) do
      {:ok, _} = result -> result
      {:error, _} -> {:error, :personal_preparation_store_unavailable}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, :personal_preparation_store_unavailable}
  end
end
