defmodule SalixStore.TriagePatrolCursors do
  @moduledoc """
  Durable per-channel ClickHouse patrol watermarks and fenced work claims.

  PostgreSQL owns only scheduling and settlement. Slack authority stays in the
  provider domain, ClickHouse SQL stays in analytics, and durable receipts
  remain the inbox truth.
  """

  alias SalixStore.{Repo, TriagePatrolScanState, ULID}

  @default_limit 10
  @max_limit 50
  @default_lease_ms 30_000
  @default_interval_ms 5_000
  @max_delay_ms 300_000
  @slack_ts ~r/\A[0-9]{1,12}\.[0-9]{6}\z/

  @type claim :: %{
          cursor_key: String.t(),
          tenant_id: String.t(),
          group_id: String.t(),
          connect_id: String.t(),
          channel_id: String.t(),
          channel_name: String.t(),
          channel_generation: String.t(),
          authority_generation: String.t(),
          last_message_ts: String.t(),
          scan_state: map(),
          revision: pos_integer(),
          claim_token: String.t(),
          lease_until: DateTime.t(),
          holder: String.t()
        }

  @doc "Creates a tail-start scan state or resets it when channel/authority generation rotates."
  def ensure(channel, authority, initial_state)
      when is_map(channel) and is_map(authority) and is_map(initial_state) do
    with :ok <- validate_channel_authority(channel, authority),
         true <- TriagePatrolScanState.valid?(initial_state) do
      cursor_key = cursor_key(channel)

      query_one(
        """
        INSERT INTO triage_patrol_cursors (
          cursor_key, tenant_id, group_id, connect_id, channel_id, channel_name,
          channel_generation, authority_generation, last_message_ts, scan_state,
          next_due_at, last_outcome
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, '0.000000', $9, statement_timestamp(), 'initialized')
        ON CONFLICT (tenant_id, group_id, connect_id, channel_id)
        DO UPDATE SET
          channel_name = EXCLUDED.channel_name,
          channel_generation = EXCLUDED.channel_generation,
          authority_generation = EXCLUDED.authority_generation,
          last_message_ts = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN '0.000000' ELSE triage_patrol_cursors.last_message_ts END,
          scan_state = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN EXCLUDED.scan_state ELSE triage_patrol_cursors.scan_state END,
          revision = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.last_outcome = 'inactive'
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN triage_patrol_cursors.revision + 1 ELSE triage_patrol_cursors.revision END,
          claim_token = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.last_outcome = 'inactive'
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN NULL ELSE triage_patrol_cursors.claim_token END,
          lease_until = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.last_outcome = 'inactive'
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN NULL ELSE triage_patrol_cursors.lease_until END,
          next_due_at = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.last_outcome = 'inactive'
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN statement_timestamp() ELSE triage_patrol_cursors.next_due_at END,
          last_outcome = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN 'reset'
            WHEN triage_patrol_cursors.last_outcome = 'inactive' THEN 'idle'
            ELSE triage_patrol_cursors.last_outcome END,
          last_error = CASE
            WHEN triage_patrol_cursors.channel_generation <> EXCLUDED.channel_generation
              OR triage_patrol_cursors.authority_generation <> EXCLUDED.authority_generation
              OR triage_patrol_cursors.last_outcome = 'inactive'
              OR triage_patrol_cursors.scan_state IS NULL
              OR triage_patrol_cursors.scan_state->>'schema' IN (
                'comma.triage-patrol-scan.v1',
                'comma.triage-clickhouse-scan-state.v1'
              )
            THEN NULL ELSE triage_patrol_cursors.last_error END,
          updated_at = statement_timestamp()
        RETURNING *
        """,
        [
          cursor_key,
          channel["tenant_id"],
          channel["group_id"],
          channel["connect_id"],
          channel["channel_id"],
          channel["channel_name"],
          channel["channel_generation"],
          authority["connect_generation"],
          initial_state
        ]
      )
    else
      false -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  def ensure(_channel, _authority, _initial_state), do: {:error, :invalid}

  @doc "Reads one exact cursor without claiming it."
  def get(tenant_id, group_id, connect_id, channel_id) do
    values = [tenant_id, group_id, connect_id, channel_id]

    if valid_strings?(values) do
      query_one(
        """
        SELECT * FROM triage_patrol_cursors
        WHERE tenant_id = $1 AND group_id = $2 AND connect_id = $3 AND channel_id = $4
        """,
        values
      )
    else
      {:error, :not_found}
    end
  end

  @doc "Claims a bounded oldest-due batch; expired holders are fenced and stealable."
  @spec claim_due(String.t(), keyword()) :: {:ok, [claim()]} | {:error, :invalid | :unavailable}
  def claim_due(holder, opts \\ [])

  def claim_due(holder, opts) when is_binary(holder) and is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    lease_ms = Keyword.get(opts, :lease_ms, @default_lease_ms)

    if valid_holder?(holder) and is_integer(limit) and limit in 1..@max_limit and
         valid_delay?(lease_ms, 1_000) do
      token = "triage-patrol-claim-" <> ULID.generate()

      case Repo.query(claim_sql(), [limit, token, lease_ms]) do
        {:ok, result} -> {:ok, Enum.map(result.rows, &claim_row(result.columns, &1, holder))}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:error, :invalid}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def claim_due(_holder, _opts), do: {:error, :invalid}

  @doc "Advances one exact claim only after its complete CH batch settled."
  def settle(claim, result, opts \\ [])

  def settle(%{} = claim, %{} = result, opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    catch_up_ms = Keyword.get(opts, :catch_up_ms, 100)

    with :ok <- validate_claim(claim),
         :ok <- validate_result(result),
         true <- valid_delay?(interval_ms, 100) and valid_delay?(catch_up_ms, 0) do
      delay_ms = if result.has_more?, do: catch_up_ms, else: interval_ms

      case Repo.query(
             """
             UPDATE triage_patrol_cursors
             SET last_message_ts = $4,
                 scan_state = $5,
                 revision = revision + 1,
                 claim_token = NULL,
                 lease_until = NULL,
                 next_due_at = statement_timestamp() + ($6::bigint * interval '1 millisecond'),
                 last_outcome = $7,
                 last_error = NULL,
                 last_result = $8,
                 last_completed_at = statement_timestamp(),
                 updated_at = statement_timestamp()
             WHERE cursor_key = $1 AND revision = $2 AND claim_token = $3
             RETURNING revision
             """,
             [
               claim.cursor_key,
               claim.revision,
               claim.claim_token,
               result.last_message_ts,
               result.scan_state,
               delay_ms,
               settlement_outcome(result),
               result_json(result)
             ]
           ) do
        {:ok, %{rows: [[revision]]}} -> {:ok, %{status: :settled, revision: revision}}
        {:ok, %{rows: []}} -> {:error, :conflict}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      false -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def settle(_claim, _result, _opts), do: {:error, :invalid}

  @doc "Releases one exact failed claim without advancing its watermark."
  def fail(claim, reason, backoff_ms \\ 1_000)

  def fail(%{} = claim, reason, backoff_ms) do
    with :ok <- validate_claim(claim),
         true <- valid_delay?(backoff_ms, 100) do
      case Repo.query(
             """
             UPDATE triage_patrol_cursors
             SET revision = revision + 1,
                 claim_token = NULL,
                 lease_until = NULL,
                 next_due_at = statement_timestamp() + ($4::bigint * interval '1 millisecond'),
                 last_outcome = 'failed',
                 last_error = $5,
                 last_completed_at = statement_timestamp(),
                 updated_at = statement_timestamp()
             WHERE cursor_key = $1 AND revision = $2 AND claim_token = $3
             RETURNING revision
             """,
             [
               claim.cursor_key,
               claim.revision,
               claim.claim_token,
               backoff_ms,
               safe_reason(reason)
             ]
           ) do
        {:ok, %{rows: [[revision]]}} -> {:ok, %{status: :failed, revision: revision}}
        {:ok, %{rows: []}} -> {:error, :conflict}
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      false -> {:error, :invalid}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def fail(_claim, _reason, _backoff_ms), do: {:error, :invalid}

  @doc "Suspends an exact ineligible claim until discovery validates its authority again."
  def deactivate(claim) when is_map(claim) do
    with :ok <- validate_claim(claim) do
      case Repo.query(
             """
             UPDATE triage_patrol_cursors
             SET revision = revision + 1,
                 claim_token = NULL,
                 lease_until = NULL,
                 last_outcome = 'inactive',
                 last_error = 'slack_triage_authority_ineligible',
                 last_completed_at = statement_timestamp(),
                 updated_at = statement_timestamp()
             WHERE cursor_key = $1 AND revision = $2 AND claim_token = $3
             RETURNING revision
             """,
             [claim.cursor_key, claim.revision, claim.claim_token]
           ) do
        {:ok, %{rows: [[revision]]}} -> {:ok, %{status: :inactive, revision: revision}}
        {:ok, %{rows: []}} -> {:error, :conflict}
        {:error, _reason} -> {:error, :unavailable}
      end
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  def deactivate(_claim), do: {:error, :invalid}

  defp claim_sql do
    """
    WITH candidates AS (
      SELECT cursor.cursor_key
      FROM triage_patrol_cursors AS cursor
      JOIN slack_triage_channels AS channel
        ON channel.tenant_id = cursor.tenant_id
       AND channel.group_id = cursor.group_id
       AND channel.connect_id = cursor.connect_id
       AND channel.channel_id = cursor.channel_id
       AND channel.channel_generation = cursor.channel_generation
       AND channel.enabled = TRUE
      WHERE cursor.next_due_at <= statement_timestamp()
        AND cursor.last_outcome <> 'inactive'
        AND cursor.scan_state IS NOT NULL
        AND cursor.scan_state->>'schema' = 'comma.triage-clickhouse-scan-state.v2'
        AND (cursor.claim_token IS NULL OR cursor.lease_until <= statement_timestamp())
      ORDER BY cursor.next_due_at, cursor.cursor_key
      LIMIT $1
      FOR UPDATE OF cursor SKIP LOCKED
    ), claimed AS (
      UPDATE triage_patrol_cursors AS cursor
      SET revision = cursor.revision + 1,
          claim_token = $2,
          lease_until = statement_timestamp() + ($3::bigint * interval '1 millisecond'),
          last_outcome = 'running',
          last_started_at = statement_timestamp(),
          updated_at = statement_timestamp()
      FROM candidates
      WHERE cursor.cursor_key = candidates.cursor_key
      RETURNING cursor.*
    )
    SELECT * FROM claimed ORDER BY cursor_key
    """
  end

  defp claim_row(columns, values, holder) do
    row = row(columns, values)

    %{
      cursor_key: row["cursor_key"],
      tenant_id: row["tenant_id"],
      group_id: row["group_id"],
      connect_id: row["connect_id"],
      channel_id: row["channel_id"],
      channel_name: row["channel_name"],
      channel_generation: row["channel_generation"],
      authority_generation: row["authority_generation"],
      last_message_ts: row["last_message_ts"],
      scan_state: row["scan_state"],
      revision: row["revision"],
      claim_token: row["claim_token"],
      lease_until: row["lease_until"],
      holder: holder
    }
  end

  defp validate_channel_authority(channel, authority) do
    channel_values =
      Enum.map(
        ~w(tenant_id group_id connect_id channel_id channel_name channel_generation),
        &channel[&1]
      )

    valid? =
      valid_strings?(channel_values) and
        Enum.all?(~w(tenant_id group_id connect_id), &(channel[&1] == authority[&1])) and
        channel["channel_id"] == authority["approved_channel_id"] and
        valid_strings?([authority["connect_generation"]])

    if valid?, do: :ok, else: {:error, :invalid}
  end

  defp validate_claim(claim) do
    valid? =
      valid_strings?([
        claim[:cursor_key],
        claim[:claim_token],
        claim[:authority_generation],
        claim[:channel_generation]
      ]) and is_integer(claim[:revision]) and claim[:revision] > 0 and
        TriagePatrolScanState.valid?(claim[:scan_state])

    if valid?, do: :ok, else: {:error, :invalid}
  end

  defp validate_result(result) do
    with true <- TriagePatrolScanState.valid?(result[:scan_state]),
         true <-
           is_binary(result[:last_message_ts]) and Regex.match?(@slack_ts, result.last_message_ts),
         true <- is_boolean(result[:has_more?]),
         true <-
           Enum.all?([:created, :duplicate, :ineligible], fn key ->
             is_integer(result[key]) and result[key] >= 0
           end) do
      :ok
    else
      _invalid -> {:error, :invalid}
    end
  end

  defp settlement_outcome(%{has_more?: true}), do: "partial"
  defp settlement_outcome(%{created: created}) when created > 0, do: "admitted"
  defp settlement_outcome(_result), do: "idle"

  defp result_json(result) do
    %{
      "created" => result.created,
      "duplicate" => result.duplicate,
      "ineligible" => result.ineligible,
      "has_more" => result.has_more?
    }
  end

  defp cursor_key(channel) do
    ~w(tenant_id group_id connect_id channel_id)
    |> Enum.map(&channel[&1])
    |> Enum.join("\0")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> then(&("triage-patrol:" <> &1))
  end

  defp query_one(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{num_rows: 1} = result} -> {:ok, row(result.columns, hd(result.rows))}
      {:ok, %{num_rows: 0}} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp row(columns, values), do: columns |> Enum.zip(values) |> Map.new()

  defp valid_holder?(holder), do: valid_strings?([holder]) and byte_size(holder) <= 200
  defp valid_delay?(value, min), do: is_integer(value) and value in min..@max_delay_ms

  defp valid_strings?(values),
    do: Enum.all?(values, &(is_binary(&1) and &1 != "" and &1 == String.trim(&1)))

  defp safe_reason(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.slice(0, 1_000)

  defp safe_reason({reason, _detail}) when is_atom(reason), do: safe_reason(reason)
  defp safe_reason(_reason), do: "patrol_unavailable"
end
