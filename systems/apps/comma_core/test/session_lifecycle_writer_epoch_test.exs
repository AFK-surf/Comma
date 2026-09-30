defmodule Comma.SessionLifecycleWriterEpochTest do
  use ExUnit.Case, async: false

  alias Comma.SessionLifecycleWriterEpoch, as: Epoch
  alias Ecto.Adapters.SQL

  @migration_version 20_260_724_000_001
  @token_a String.duplicate("a", 64)
  @token_b String.duplicate("b", 64)
  @token_c String.duplicate("c", 64)

  defmodule EpochRepo do
    use Ecto.Repo,
      otp_app: :comma_core,
      adapter: Ecto.Adapters.Postgres
  end

  defmodule PeerRepo do
    use Ecto.Repo,
      otp_app: :comma_core,
      adapter: Ecto.Adapters.Postgres
  end

  setup_all do
    database = "comma_lifecycle_epoch_#{System.unique_integer([:positive])}"

    repo_config =
      Comma.Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    assert :ok = Ecto.Adapters.Postgres.storage_up(repo_config)
    {:ok, repo_pid} = EpochRepo.start_link(repo_config)
    {:ok, peer_pid} = PeerRepo.start_link(repo_config)
    Process.unlink(repo_pid)
    Process.unlink(peer_pid)

    SQL.query!(
      EpochRepo,
      """
      CREATE TABLE comma_users (
        id text PRIMARY KEY,
        normalized_email text
      )
      """
    )

    SQL.query!(
      EpochRepo,
      """
      CREATE TABLE comma_auth_sessions (
        id uuid PRIMARY KEY,
        user_id text REFERENCES comma_users(id)
      )
      """
    )

    migration =
      require_migration!(
        "../priv/repo/migrations/20260724000001_add_session_lifecycle_writer_epoch.exs",
        Comma.Repo.Migrations.AddSessionLifecycleWriterEpoch
      )

    assert :ok =
             Ecto.Migrator.up(EpochRepo, @migration_version, migration,
               strict_version_order: true,
               log: false
             )

    on_exit(fn ->
      Supervisor.stop(peer_pid, :normal)
      Supervisor.stop(repo_pid, :normal)

      case Ecto.Adapters.Postgres.storage_down(repo_config) do
        :ok -> :ok
        {:error, :already_down} -> :ok
      end
    end)

    :ok
  end

  setup do
    SQL.query!(
      EpochRepo,
      """
      UPDATE comma_session_lifecycle_writer_epochs
      SET status = 'released', released_at = clock_timestamp()
      """
    )

    SQL.query!(EpochRepo, "TRUNCATE comma_auth_sessions, comma_users")
    SQL.query!(EpochRepo, "DELETE FROM comma_session_lifecycle_writer_epoch_tokens")
    SQL.query!(EpochRepo, "DELETE FROM comma_session_lifecycle_writer_epochs")

    :ok
  end

  test "acquire drains an in-flight old replica then DB triggers reject old and background writers" do
    parent = self()

    old_writer =
      Task.async(fn ->
        PeerRepo.transaction(fn ->
          SQL.query!(PeerRepo, "INSERT INTO comma_users (id) VALUES ('old-in-flight')")
          send(parent, :old_writer_open)

          receive do
            :rollback_old_writer -> PeerRepo.rollback(:test_complete)
          end
        end)
      end)

    assert_receive :old_writer_open

    acquire =
      Task.async(fn ->
        Epoch.acquire("release-v1", @token_a, repo: EpochRepo, lease_seconds: 60)
      end)

    assert Task.yield(acquire, 100) == nil
    send(old_writer.pid, :rollback_old_writer)
    assert {:error, :test_complete} = Task.await(old_writer)
    assert {:ok, epoch} = Task.await(acquire)
    assert epoch.generation == 1
    assert DateTime.compare(epoch.drained_at, epoch.acquired_at) in [:eq, :gt]

    assert_writer_rejected(
      SQL.query(PeerRepo, "INSERT INTO comma_users (id) VALUES ('old-replica')")
    )

    assert_writer_rejected(
      SQL.query(
        EpochRepo,
        "UPDATE comma_auth_sessions SET user_id = user_id WHERE FALSE"
      )
    )

    assert {:ok, _released} =
             Epoch.release("release-v1", epoch.generation, @token_a, repo: EpochRepo)
  end

  test "existing terminal users and sessions remain while the epoch fences new writers" do
    SQL.query!(EpochRepo, "INSERT INTO comma_users (id) VALUES ('existing-user')")

    SQL.query!(
      EpochRepo,
      """
      INSERT INTO comma_auth_sessions (id, user_id)
      VALUES ('00000000-0000-0000-0000-000000000001', 'existing-user')
      """
    )

    assert {:ok, epoch} = Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert {:ok, _active} =
             Epoch.assert_active("release-v1", epoch.generation, @token_a, repo: EpochRepo)

    assert %{rows: [[1], [1]]} =
             SQL.query!(
               EpochRepo,
               """
               SELECT COUNT(*) FROM comma_users
               UNION ALL
               SELECT COUNT(*) FROM comma_auth_sessions
               """
             )

    assert_writer_rejected(
      SQL.query(PeerRepo, "INSERT INTO comma_users (id) VALUES ('new-writer')")
    )

    assert {:ok, _released} =
             Epoch.release("release-v1", epoch.generation, @token_a, repo: EpochRepo)
  end

  test "cutover assertions cannot cross a fencing generation" do
    assert {:ok, first} = Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert {:ok, _active} =
             Epoch.assert_active("release-v1", first.generation, @token_a, repo: EpochRepo)

    expire_lease!()

    assert {:ok, successor} =
             Epoch.acquire("release-v1", @token_b, repo: EpochRepo, lease_seconds: 60)

    assert successor.generation == first.generation + 1

    assert {:error, {:fenced, "active", "release-v1", generation, _expires_at}} =
             Epoch.assert_active("release-v1", first.generation, @token_a, repo: EpochRepo)

    assert generation == successor.generation

    assert {:error, {:fenced, "active", "release-v1", ^generation, _expires_at}} =
             Epoch.release("release-v1", first.generation, @token_a, repo: EpochRepo)

    assert {:ok, _active} =
             Epoch.assert_active(
               "release-v1",
               successor.generation,
               @token_b,
               repo: EpochRepo
             )
  end

  test "runner loss is recoverable by the same release but expiry never lets another release steal or reopen" do
    assert {:ok, first} = Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert {:ok, replayed} =
             Epoch.acquire("release-v1", @token_a, repo: EpochRepo, lease_seconds: 60)

    assert replayed.generation == first.generation
    expire_lease!()

    assert {:error, {:epoch_owned, "release-v1", generation, _expires_at}} =
             Epoch.acquire("release-v2", @token_b, repo: EpochRepo)

    assert generation == first.generation
    assert_writer_rejected(SQL.query(PeerRepo, "UPDATE comma_users SET id = id WHERE FALSE"))

    assert {:ok, recovered} =
             Epoch.acquire("release-v1", @token_c, repo: EpochRepo, lease_seconds: 60)

    assert recovered.generation == first.generation + 1

    assert {:error, {:fenced, "active", "release-v1", _, _}} =
             Epoch.release("release-v1", first.generation, @token_a, repo: EpochRepo)

    assert {:ok, released} =
             Epoch.release(
               "release-v1",
               recovered.generation,
               @token_c,
               repo: EpochRepo
             )

    assert released.status == "released"
    assert {:ok, next} = Epoch.acquire("release-v2", @token_b, repo: EpochRepo)
    assert next.generation == recovered.generation + 1
  end

  test "released token replay cannot reactivate its generation or a later release" do
    assert {:ok, first} = Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert {:ok, released} =
             Epoch.release("release-v1", first.generation, @token_a, repo: EpochRepo)

    assert {:error, {:token_retired, "released", "release-v1", generation}} =
             Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert generation == released.generation
    assert_epoch("release-v1", released.generation, "released")

    assert {:ok, second} = Epoch.acquire("release-v2", @token_b, repo: EpochRepo)

    assert {:ok, second_released} =
             Epoch.release("release-v2", second.generation, @token_b, repo: EpochRepo)

    assert {:error, {:token_retired, "released", "release-v1", ^generation}} =
             Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert_epoch("release-v2", second_released.generation, "released")
    assert %{num_rows: 1} = SQL.query!(PeerRepo, "INSERT INTO comma_users (id) VALUES ('open')")
  end

  test "expired-owner takeover permanently retires the superseded token" do
    assert {:ok, first} = Epoch.acquire("release-v1", @token_a, repo: EpochRepo)
    expire_lease!()
    assert {:ok, successor} = Epoch.acquire("release-v1", @token_b, repo: EpochRepo)

    assert {:error, {:token_retired, "superseded", "release-v1", generation}} =
             Epoch.acquire("release-v1", @token_a, repo: EpochRepo)

    assert generation == first.generation

    assert {:ok, _released} =
             Epoch.release(
               "release-v1",
               successor.generation,
               @token_b,
               repo: EpochRepo
             )
  end

  defp expire_lease! do
    SQL.query!(
      EpochRepo,
      """
      UPDATE comma_session_lifecycle_writer_epochs
      SET lease_expires_at = clock_timestamp() - INTERVAL '1 second'
      """
    )
  end

  defp assert_writer_rejected({:error, %Postgrex.Error{postgres: postgres}}) do
    assert postgres.pg_code == "P7501"
    assert postgres.code == nil
    assert postgres.message == "comma_session_lifecycle_writer_epoch_active"
  end

  defp assert_writer_rejected(other), do: flunk("writer was not rejected: #{inspect(other)}")

  defp assert_epoch(release_id, generation, status) do
    assert %{rows: [[^release_id, ^generation, ^status]]} =
             SQL.query!(
               EpochRepo,
               """
               SELECT release_id, generation, status
               FROM comma_session_lifecycle_writer_epochs
               WHERE singleton_id = TRUE
               """
             )
  end

  defp require_migration!(relative_path, module) do
    path = Path.expand(relative_path, __DIR__)
    Code.require_file(path)
    module
  end
end
