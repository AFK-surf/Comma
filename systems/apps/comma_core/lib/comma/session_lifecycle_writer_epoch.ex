defmodule Comma.SessionLifecycleWriterEpoch do
  @moduledoc """
  Database-enforced release fence for the pre-launch Session lifecycle hard cut.

  The active row is a deployment-wide writer barrier. PostgreSQL triggers, not
  runtime flags, reject every statement that would mutate `comma_users` or
  `comma_auth_sessions`. Lease expiry permits a fenced coordinator takeover but
  deliberately does not reopen writes.
  """

  alias Ecto.Adapters.SQL

  @evidence_prefix "COMMA_SESSION_LIFECYCLE_EPOCH "
  @writer_rejected_sqlstate "P7501"
  @minimum_token_bytes 32
  @default_lease_seconds 300
  @maximum_lease_seconds 3_600

  @type epoch :: %{
          release_id: String.t(),
          generation: pos_integer(),
          token: String.t(),
          lease_expires_at: DateTime.t(),
          acquired_at: DateTime.t(),
          drained_at: DateTime.t()
        }

  def evidence_prefix, do: @evidence_prefix
  def writer_rejected_sqlstate, do: @writer_rejected_sqlstate

  @doc """
  Acquire or renew the epoch and prove all prior writers drained.

  `ACCESS EXCLUSIVE` locks wait behind every transaction already touching the
  guarded relations. The active epoch row is committed before those locks are
  released, so queued later writers can only resume into the trigger rejection.
  """
  @spec acquire(String.t(), String.t(), keyword()) :: {:ok, epoch()} | {:error, term()}
  def acquire(release_id, token, opts \\ []) do
    repo = Keyword.get(opts, :repo, Comma.Repo)
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)

    with :ok <- validate_release_id(release_id),
         :ok <- validate_token(token),
         :ok <- validate_lease_seconds(lease_seconds) do
      token_hash = token_hash(token)

      transact(repo, fn ->
        SQL.query!(repo, "LOCK TABLE comma_session_lifecycle_writer_epochs IN EXCLUSIVE MODE")
        SQL.query!(repo, "LOCK TABLE comma_users, comma_auth_sessions IN ACCESS EXCLUSIVE MODE")

        current = current_epoch(repo, "FOR UPDATE")
        token_epoch = current_token_epoch(repo, token_hash, "FOR UPDATE")
        now = database_now(repo)

        case {token_epoch, current} do
          {nil, nil} ->
            epoch = insert_active(repo, release_id, token_hash, 1, lease_seconds)
            insert_active_token(repo, epoch)
            epoch

          {nil, %{status: "released", generation: generation}} ->
            epoch =
              replace_active(repo, release_id, token_hash, generation + 1, lease_seconds)

            insert_active_token(repo, epoch)
            epoch

          {%{status: "active"} = token_facts,
           %{status: "active", release_id: ^release_id, token_hash: ^token_hash} = epoch} ->
            if token_facts.release_id == release_id and
                 token_facts.generation == epoch.generation do
              renew_active(repo, epoch.generation, lease_seconds)
            else
              repo.rollback(
                {:token_state_mismatch, token_facts.release_id, token_facts.generation}
              )
            end

          {%{status: status} = token_facts, _current}
          when status in ["released", "superseded"] ->
            repo.rollback(
              {:token_retired, status, token_facts.release_id, token_facts.generation}
            )

          {%{status: "active"} = token_facts, _current} ->
            repo.rollback({:token_state_mismatch, token_facts.release_id, token_facts.generation})

          {nil, %{status: "active", release_id: ^release_id, token_hash: ^token_hash}} ->
            repo.rollback(:token_ledger_missing)

          {nil,
           %{status: "active", release_id: ^release_id, lease_expires_at: expires_at} = epoch} ->
            if DateTime.compare(expires_at, now) in [:lt, :eq] do
              retire_active_token(repo, epoch, "superseded")

              successor =
                replace_active(
                  repo,
                  release_id,
                  token_hash,
                  epoch.generation + 1,
                  lease_seconds
                )

              insert_active_token(repo, successor)
              successor
            else
              repo.rollback({:lease_owned, epoch.generation, expires_at})
            end

          {nil, %{status: "active"} = epoch} ->
            repo.rollback(
              {:epoch_owned, epoch.release_id, epoch.generation, epoch.lease_expires_at}
            )
        end
      end)
      |> normalize_transaction()
      |> attach_token(token)
    end
  end

  @doc "Renew the exact current fence without changing its generation."
  def renew(release_id, generation, token, opts \\ []) do
    repo = Keyword.get(opts, :repo, Comma.Repo)
    lease_seconds = Keyword.get(opts, :lease_seconds, @default_lease_seconds)

    with :ok <- validate_identity(release_id, generation, token),
         :ok <- validate_lease_seconds(lease_seconds) do
      transact(repo, fn ->
        epoch = lock_and_assert!(repo, release_id, generation, token, "FOR UPDATE")
        renew_active(repo, epoch.generation, lease_seconds)
      end)
      |> normalize_transaction()
      |> attach_token(token)
    end
  end

  @doc "Assert that the caller still owns the exact active release fence."
  def assert_active(release_id, generation, token, opts \\ []) do
    repo = Keyword.get(opts, :repo, Comma.Repo)

    with :ok <- validate_identity(release_id, generation, token) do
      transact(repo, fn ->
        lock_and_assert!(repo, release_id, generation, token, "FOR SHARE")
      end)
      |> normalize_transaction()
      |> attach_token(token)
    end
  end

  @doc """
  Release the exact active generation.

  The operation is idempotent for the same release, generation, and token.
  A stale runner cannot release a generation acquired by its successor.
  """
  def release(release_id, generation, token, opts \\ []) do
    repo = Keyword.get(opts, :repo, Comma.Repo)

    with :ok <- validate_identity(release_id, generation, token) do
      transact(repo, fn ->
        epoch = current_epoch(repo, "FOR UPDATE")

        cond do
          matches_identity?(epoch, release_id, generation, token) and epoch.status == "active" ->
            %{rows: [row]} =
              SQL.query!(
                repo,
                """
                UPDATE comma_session_lifecycle_writer_epochs
                SET status = 'released',
                    released_at = clock_timestamp(),
                    updated_at = clock_timestamp()
                WHERE singleton_id = TRUE
                RETURNING release_id, generation, token_hash, status, lease_expires_at,
                          acquired_at, drained_at, released_at
                """
              )

            released = decode_epoch(row)
            retire_active_token(repo, released, "released")
            released

          matches_identity?(epoch, release_id, generation, token) and
              epoch.status == "released" ->
            epoch

          true ->
            repo.rollback(fence_error(epoch))
        end
      end)
      |> normalize_transaction()
      |> attach_token(token)
    end
  end

  @doc false
  def release_command!(action, release_id, token, generation, lease_seconds)
      when is_binary(action) do
    Application.load(:comma_core)

    {:ok, result, _started} =
      Ecto.Migrator.with_repo(Comma.Repo, fn repo ->
        opts = [repo: repo, lease_seconds: lease_seconds]

        case action do
          "acquire" -> acquire(release_id, token, opts)
          "renew" -> renew(release_id, generation, token, opts)
          "assert" -> assert_active(release_id, generation, token, repo: repo)
          "release" -> release(release_id, generation, token, repo: repo)
          _other -> {:error, :unsupported_action}
        end
      end)

    evidence =
      case result do
        {:ok, epoch} ->
          evidence(action, epoch)

        {:error, reason} ->
          raise "session lifecycle writer epoch #{action} failed: #{inspect(reason)}"
      end

    IO.puts(@evidence_prefix <> Jason.encode!(evidence))
    evidence
  end

  defp evidence(action, epoch) do
    base = %{
      "schema_version" => 1,
      "action" => action,
      "status" => epoch.status,
      "release_id" => epoch.release_id,
      "generation" => epoch.generation,
      "lease_expires_at" => DateTime.to_iso8601(epoch.lease_expires_at),
      "acquired_at" => DateTime.to_iso8601(epoch.acquired_at),
      "drained_at" => DateTime.to_iso8601(epoch.drained_at)
    }

    base
    |> maybe_put("released_at", epoch[:released_at])
    |> maybe_put("inventory", epoch[:inventory])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, %DateTime{} = value), do: Map.put(map, key, DateTime.to_iso8601(value))
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp transact(repo, fun) do
    repo.transaction(fun, timeout: :infinity)
  rescue
    error in Postgrex.Error -> {:error, {:postgres, error}}
  end

  defp normalize_transaction({:ok, result}), do: {:ok, result}
  defp normalize_transaction({:error, reason}), do: {:error, reason}
  defp normalize_transaction({:error, _operation, reason, _changes}), do: {:error, reason}

  defp attach_token({:ok, epoch}, token), do: {:ok, Map.put(epoch, :token, token)}
  defp attach_token({:error, _reason} = error, _token), do: error

  defp lock_and_assert!(repo, release_id, generation, token, lock) do
    epoch = current_epoch(repo, lock)

    if matches_identity?(epoch, release_id, generation, token) and epoch.status == "active" do
      epoch
    else
      repo.rollback(fence_error(epoch))
    end
  end

  defp matches_identity?(nil, _release_id, _generation, _token), do: false

  defp matches_identity?(epoch, release_id, generation, token) do
    epoch.release_id == release_id and epoch.generation == generation and
      secure_compare(epoch.token_hash, token_hash(token))
  end

  defp fence_error(nil), do: :epoch_missing

  defp fence_error(epoch) do
    {:fenced, epoch.status, epoch.release_id, epoch.generation, epoch.lease_expires_at}
  end

  defp current_epoch(repo, lock) do
    case SQL.query!(
           repo,
           """
           SELECT release_id, generation, token_hash, status, lease_expires_at,
                  acquired_at, drained_at, released_at
           FROM comma_session_lifecycle_writer_epochs
           WHERE singleton_id = TRUE
           #{lock}
           """
         ).rows do
      [] -> nil
      [row] -> decode_epoch(row)
    end
  end

  defp current_token_epoch(repo, token_hash, lock) do
    case SQL.query!(
           repo,
           """
           SELECT release_id, generation, status, retired_at
           FROM comma_session_lifecycle_writer_epoch_tokens
           WHERE token_hash = $1
           #{lock}
           """,
           [token_hash]
         ).rows do
      [] ->
        nil

      [[release_id, generation, status, retired_at]] ->
        %{
          release_id: release_id,
          generation: generation,
          status: status,
          retired_at: normalize_datetime(retired_at)
        }
    end
  end

  defp database_now(repo) do
    %{rows: [[now]]} = SQL.query!(repo, "SELECT clock_timestamp()")
    normalize_datetime(now)
  end

  defp insert_active(repo, release_id, token_hash, generation, lease_seconds) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        """
        INSERT INTO comma_session_lifecycle_writer_epochs (
          singleton_id, status, release_id, generation, token_hash,
          lease_expires_at, acquired_at, drained_at, updated_at
        )
        VALUES (
          TRUE, 'active', $1, $2, $3,
          clock_timestamp() + ($4::bigint * INTERVAL '1 second'),
          clock_timestamp(), clock_timestamp(), clock_timestamp()
        )
        RETURNING release_id, generation, token_hash, status, lease_expires_at,
                  acquired_at, drained_at, released_at
        """,
        [release_id, generation, token_hash, lease_seconds]
      )

    decode_epoch(row)
  end

  defp insert_active_token(repo, epoch) do
    SQL.query!(
      repo,
      """
      INSERT INTO comma_session_lifecycle_writer_epoch_tokens (
        token_hash, release_id, generation, status, created_at, updated_at
      )
      VALUES ($1, $2, $3, 'active', clock_timestamp(), clock_timestamp())
      """,
      [epoch.token_hash, epoch.release_id, epoch.generation]
    )

    :ok
  end

  defp retire_active_token(repo, epoch, status) when status in ["released", "superseded"] do
    result =
      SQL.query!(
        repo,
        """
        UPDATE comma_session_lifecycle_writer_epoch_tokens
        SET status = $4,
            retired_at = clock_timestamp(),
            updated_at = clock_timestamp()
        WHERE token_hash = $1
          AND release_id = $2
          AND generation = $3
          AND status = 'active'
        """,
        [epoch.token_hash, epoch.release_id, epoch.generation, status]
      )

    if result.num_rows != 1 do
      repo.rollback({:token_state_mismatch, epoch.release_id, epoch.generation})
    end

    :ok
  end

  defp replace_active(repo, release_id, token_hash, generation, lease_seconds) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        """
        UPDATE comma_session_lifecycle_writer_epochs
        SET status = 'active',
            release_id = $1,
            generation = $2,
            token_hash = $3,
            lease_expires_at = clock_timestamp() + ($4::bigint * INTERVAL '1 second'),
            acquired_at = clock_timestamp(),
            drained_at = clock_timestamp(),
            released_at = NULL,
            updated_at = clock_timestamp()
        WHERE singleton_id = TRUE
        RETURNING release_id, generation, token_hash, status, lease_expires_at,
                  acquired_at, drained_at, released_at
        """,
        [release_id, generation, token_hash, lease_seconds]
      )

    decode_epoch(row)
  end

  defp renew_active(repo, generation, lease_seconds) do
    %{rows: [row]} =
      SQL.query!(
        repo,
        """
        UPDATE comma_session_lifecycle_writer_epochs
        SET lease_expires_at = clock_timestamp() + ($2::bigint * INTERVAL '1 second'),
            updated_at = clock_timestamp()
        WHERE singleton_id = TRUE
          AND status = 'active'
          AND generation = $1
        RETURNING release_id, generation, token_hash, status, lease_expires_at,
                  acquired_at, drained_at, released_at
        """,
        [generation, lease_seconds]
      )

    decode_epoch(row)
  end

  defp decode_epoch([
         release_id,
         generation,
         token_hash,
         status,
         lease_expires_at,
         acquired_at,
         drained_at,
         released_at
       ]) do
    %{
      release_id: release_id,
      generation: generation,
      token_hash: token_hash,
      status: status,
      lease_expires_at: normalize_datetime(lease_expires_at),
      acquired_at: normalize_datetime(acquired_at),
      drained_at: normalize_datetime(drained_at),
      released_at: normalize_datetime(released_at)
    }
  end

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = value), do: value
  defp normalize_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")

  defp validate_identity(release_id, generation, token) do
    with :ok <- validate_release_id(release_id),
         true <- is_integer(generation) and generation > 0,
         :ok <- validate_token(token) do
      :ok
    else
      false -> {:error, :invalid_generation}
      {:error, _reason} = error -> error
    end
  end

  defp validate_release_id(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :invalid_release_id}, else: :ok
  end

  defp validate_release_id(_value), do: {:error, :invalid_release_id}

  defp validate_token(value) when is_binary(value) do
    if byte_size(value) >= @minimum_token_bytes, do: :ok, else: {:error, :invalid_token}
  end

  defp validate_token(_value), do: {:error, :invalid_token}

  defp validate_lease_seconds(value)
       when is_integer(value) and value > 0 and value <= @maximum_lease_seconds,
       do: :ok

  defp validate_lease_seconds(_value), do: {:error, :invalid_lease_seconds}

  defp token_hash(token), do: :crypto.hash(:sha256, token)

  defp secure_compare(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_compare(_left, _right), do: false
end
