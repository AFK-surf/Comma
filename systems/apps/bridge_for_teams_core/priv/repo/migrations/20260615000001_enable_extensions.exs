defmodule BridgeForTeams.Repo.Migrations.EnableExtensions do
  @moduledoc """
  Enable the Postgres extensions BridgeForTeams relies on (design §5):

    * `citext`  — case-insensitive `users.email` (unique citext).
    * `pgcrypto` — `gen_random_uuid()` for the UUID v7 generator fallback.

  Also installs a `uuid_generate_v7()` SQL function used as the DB-side default
  for every `binary_id` primary key, so ids are time-ordered UUID v7 per design
  ("All ids UUID v7"). The function follows RFC 9562: 48-bit big-endian unix
  millisecond timestamp, version nibble 7, variant bits 0b10, the rest random.
  """
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      -- 48-bit big-endian millisecond timestamp.
      unix_ts_ms = substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
      -- 16 random bytes; overlay the timestamp into the first 6.
      uuid_bytes = uuid_send(gen_random_uuid());
      uuid_bytes = overlay(uuid_bytes PLACING unix_ts_ms FROM 1 FOR 6);
      -- Version 7 in the high nibble of byte 7 (0-indexed byte 6): (b & 0x0F) | 0x70.
      uuid_bytes = set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
      -- Variant 0b10 in the high bits of byte 9 (0-indexed byte 8): (b & 0x3F) | 0x80.
      uuid_bytes = set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
      RETURN encode(uuid_bytes, 'hex')::uuid;
    END;
    $$ LANGUAGE plpgsql VOLATILE;
    """)
  end

  def down do
    execute("DROP FUNCTION IF EXISTS uuid_generate_v7()")
    # Leave the extensions installed; they are harmless and may be shared.
  end
end
