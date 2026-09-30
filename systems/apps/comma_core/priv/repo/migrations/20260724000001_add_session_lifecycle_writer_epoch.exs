defmodule Comma.Repo.Migrations.AddSessionLifecycleWriterEpoch do
  use Ecto.Migration

  def up do
    create table(:comma_session_lifecycle_writer_epochs, primary_key: false) do
      add(:singleton_id, :boolean, primary_key: true, null: false, default: true)
      add(:status, :text, null: false)
      add(:release_id, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:token_hash, :binary, null: false)
      add(:lease_expires_at, :utc_datetime_usec, null: false)
      add(:acquired_at, :utc_datetime_usec, null: false)
      add(:drained_at, :utc_datetime_usec, null: false)
      add(:released_at, :utc_datetime_usec)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(
        :comma_session_lifecycle_writer_epochs,
        :comma_session_lifecycle_writer_epochs_singleton,
        check: "singleton_id"
      )
    )

    create table(:comma_session_lifecycle_writer_epoch_tokens, primary_key: false) do
      add(:token_hash, :binary, primary_key: true, null: false)
      add(:release_id, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:status, :text, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
      add(:retired_at, :utc_datetime_usec)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(
        :comma_session_lifecycle_writer_epoch_tokens,
        :comma_session_lifecycle_writer_epoch_tokens_status,
        check: "status IN ('active', 'released', 'superseded')"
      )
    )

    create(
      constraint(
        :comma_session_lifecycle_writer_epoch_tokens,
        :comma_session_lifecycle_writer_epoch_tokens_generation,
        check: "generation > 0"
      )
    )

    create(
      unique_index(
        :comma_session_lifecycle_writer_epoch_tokens,
        [:generation],
        name: :comma_session_lifecycle_writer_epoch_tokens_generation_unique
      )
    )

    create(
      constraint(
        :comma_session_lifecycle_writer_epochs,
        :comma_session_lifecycle_writer_epochs_status,
        check: "status IN ('active', 'released')"
      )
    )

    create(
      constraint(
        :comma_session_lifecycle_writer_epochs,
        :comma_session_lifecycle_writer_epochs_generation,
        check: "generation > 0"
      )
    )

    execute("""
    CREATE FUNCTION comma_reject_session_lifecycle_epoch_write()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      active_release_id text;
      active_generation bigint;
    BEGIN
      SELECT release_id, generation
      INTO active_release_id, active_generation
      FROM comma_session_lifecycle_writer_epochs
      WHERE singleton_id = TRUE
        AND status = 'active';

      IF FOUND THEN
        RAISE EXCEPTION USING
          ERRCODE = 'P7501',
          MESSAGE = 'comma_session_lifecycle_writer_epoch_active',
          DETAIL = format(
            'release_id=%s generation=%s relation=%s operation=%s',
            active_release_id,
            active_generation,
            TG_TABLE_NAME,
            TG_OP
          ),
          HINT = 'retry only after the lifecycle-v1 release coordinator reopens writes';
      END IF;

      RETURN NULL;
    END
    $$;
    """)

    for table <- ~w(comma_users comma_auth_sessions) do
      execute("""
      CREATE TRIGGER #{table}_session_lifecycle_writer_epoch
      BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE
      ON #{table}
      FOR EACH STATEMENT
      EXECUTE FUNCTION comma_reject_session_lifecycle_epoch_write();
      """)
    end
  end

  def down do
    for table <- ~w(comma_auth_sessions comma_users) do
      execute("DROP TRIGGER IF EXISTS #{table}_session_lifecycle_writer_epoch ON #{table}")
    end

    execute("DROP FUNCTION IF EXISTS comma_reject_session_lifecycle_epoch_write()")
    drop(table(:comma_session_lifecycle_writer_epoch_tokens))
    drop(table(:comma_session_lifecycle_writer_epochs))
  end
end
