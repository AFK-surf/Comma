defmodule SalixStore.Repo.Migrations.PreserveCommandDeliveryFact do
  use Ecto.Migration

  def up do
    alter table(:compute_commands) do
      add(:delivery_started_at, :utc_datetime_usec)
    end

    execute("""
    CREATE FUNCTION preserve_compute_command_delivery() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.delivery_started_at IS NOT NULL THEN
        NEW.delivery_started_at := OLD.delivery_started_at;
      ELSIF NEW.status IN ('admitted', 'executing', 'unknown_outcome') OR
        NEW.payload->'command_json'->>'sequence' IS NOT NULL THEN
        NEW.delivery_started_at := COALESCE(NEW.delivery_started_at, statement_timestamp());
      END IF;
      RETURN NEW;
    END $$;
    """)

    execute("""
    CREATE TRIGGER compute_command_delivery_fact BEFORE INSERT OR UPDATE ON compute_commands
    FOR EACH ROW EXECUTE FUNCTION preserve_compute_command_delivery();
    """)
  end

  def down do
    execute("DROP TRIGGER compute_command_delivery_fact ON compute_commands")
    execute("DROP FUNCTION preserve_compute_command_delivery()")
    alter(table(:compute_commands), do: remove(:delivery_started_at))
  end
end
